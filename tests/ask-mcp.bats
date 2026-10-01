#!/usr/bin/env bats
# agterm-ask-mcp: stdio MCP-сервер с инструментом ask_user поверх agterm-ask.
# Сценарий клиента подаётся на stdin с паузами, ответы сервера собираются в $T/out.

load helpers

bats_require_minimum_version 1.5.0

MCP=$KIT_DIR/ask/agterm-ask-mcp

setup() {
    setup_env
    setup_ask_env
    mkdir -p "$T/proj"
    cd "$T/proj"
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"codex"},"capabilities":{}}}'

# call <id> [meta-json]: tools/call ask_user с одним вопросом "Q?" и вариантами A, B.
call() {
    jq -n -c --argjson id "$1" --argjson meta "${2:-null}" '{jsonrpc: "2.0", id: $id, method: "tools/call",
        params: ({name: "ask_user", arguments: {questions: [{question: "Q?", options: [{label: "A"}, {label: "B"}]}]}}
            + (if $meta then {_meta: $meta} else {} end))}'
}

# mcp <строка|sleep N|until ID>...: отправить строки по порядку, держа stdin открытым.
# until ID ждёт до 5 секунд, пока в $T/out не появится ответ на запрос ID.
mcp() {
    local step i
    : > "$T/out"
    for step in "$@"; do
        if [[ $step == sleep\ * ]]; then
            ${step}
        elif [[ $step == until\ * ]]; then
            for i in $(seq 50); do
                grep -q "\"id\":${step#until }[,}]" "$T/out" && break
                sleep 0.1
            done
        else
            printf '%s\n' "$step"
        fi
    done | "$MCP" > "$T/out" 2> "$T/err"
}

# reply <id>: ответ сервера на запрос с этим id.
reply() {
    jq -c --argjson id "$1" 'select(.id == $id)' "$T/out"
}

@test "initialize echoes a known protocol version and lists ask_user" {
    mcp "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'
    [ "$(wc -l < "$T/out")" -eq 3 ]
    reply 1 | jq -e '.result.protocolVersion == "2025-06-18" and .result.serverInfo.name == "agterm-ask"
        and .result.capabilities.tools != null and (.result.instructions | test("ask_user"))'
    reply 2 | jq -e '.result.tools | length == 1 and .[0].name == "ask_user"
        and .[0].inputSchema.properties.questions.maxItems == 4 and .[0].annotations.readOnlyHint == true'
    reply 3 | jq -e '.result.protocolVersion == "2025-06-18"'
}

@test "answered call returns readable text plus json, page names the client and project" {
    export FAKE_VALUE='{"answers":{"Q?":"B"}}'
    mcp "$INIT" "$(call 2)" "until 2" '{"jsonrpc":"2.0","id":3,"method":"ping"}' "until 3"
    # Сервер жив после ответа: завершение наблюдателя не обрывает цикл чтения.
    reply 3 | jq -e '.result == {}'
    reply 2 | jq -e '.result.isError == false
        and (.result.content[0].text | startswith("The user answered:\n- Q? -> B\n\n"))
        and (.result.content[0].text | split("\n\n")[1] | fromjson) == {answers: {"Q?": "B"}}'
    page_data | jq -e '.context == "Codex · proj"'
    cut -f2,3 "$AGTERM_ASK_LOG" | grep -qx "codex	answered"
}

@test "dismissed, unavailable and invalid calls map to distinct results" {
    export FAKE_OUTCOME=dismissed
    mcp "$INIT" "$(call 2)" "until 2"
    reply 2 | jq -e '.result.isError == false and (.result.content[0].text | test("closed the dialog"))'

    unset AGTERM_ENABLED
    mcp "$INIT" "$(call 2)" "until 2"
    reply 2 | jq -e '.result.isError == false and (.result.content[0].text | test("unavailable \\(не внутри agterm\\)"))'

    export AGTERM_ENABLED=1
    mcp "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_user","arguments":{"questions":[]}}}' "until 2"
    reply 2 | jq -e '.result.isError == true and (.result.content[0].text | test("from 1 to 4"))'
}

@test "while waiting: ping is answered and progress is sent with the client token" {
    export FAKE_OUTCOME=pending AGTERM_ASK_PROGRESS=1
    mcp "$INIT" "$(call 2 '{"progressToken":"tok-7"}')" "sleep 0.5" \
        '{"jsonrpc":"2.0","id":3,"method":"ping"}' "sleep 1.6"
    reply 3 | jq -e '.result == {}'
    jq -s -e '[.[] | select(.method == "notifications/progress")] | length >= 1
        and all(.params.progressToken == "tok-7")
        and (map(.params.progress) | . == (sort | unique))' "$T/out"
    # Пользователь не ответил: результата вызова нет, а stdin закрылся, и страница закрыта.
    [ -z "$(reply 2)" ]
    grep -q "session overlay close --target SESSION-1" "$FAKE_AGTERM_LOG"
}

@test "no progress without a progress token" {
    export FAKE_OUTCOME=pending AGTERM_ASK_PROGRESS=1
    mcp "$INIT" "$(call 2)" "sleep 1.6"
    run ! grep -q "notifications/progress" "$T/out"
}

@test "cancellation closes the page and sends no result" {
    export FAKE_OUTCOME=pending
    mcp "$INIT" "$(call 2)" "sleep 0.7" \
        '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}' "sleep 0.8"
    grep -q "session overlay close --target SESSION-1" "$FAKE_AGTERM_LOG"
    [ -z "$(reply 2)" ]
    cut -f3 "$AGTERM_ASK_LOG" | grep -qx cancelled
}

@test "cancel right after the call leaves no running question and no open page" {
    export FAKE_OUTCOME=pending
    mcp "$INIT" "$(call 2)" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}' "sleep 0.5"
    sleep 0.5
    run ! pgrep -f "$KIT_DIR/ask/agterm-ask --context"
    if grep -qs "session overlay open" "$FAKE_AGTERM_LOG"; then
        grep -q "session overlay close --target SESSION-1" "$FAKE_AGTERM_LOG"
    fi
    [ -z "$(reply 2)" ]
}

@test "second question while one is open is refused" {
    export FAKE_OUTCOME=pending
    mcp "$INIT" "$(call 2)" "sleep 0.5" "$(call 3)" "until 3"
    reply 3 | jq -e '.result.isError == true and (.result.content[0].text | test("still open"))'
}

@test "unknown method, unknown tool and broken json get json-rpc errors" {
    mcp "$INIT" '{"jsonrpc":"2.0","id":2,"method":"resources/list"}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rm_rf"}}' \
        '{not json' '{"jsonrpc":"2.0","id":9,"result":{}}'
    reply 2 | jq -e '.error.code == -32601'
    reply 3 | jq -e '.error.code == -32602'
    jq -s -e 'map(select(.id == null and .error.code == -32700)) | length == 1' "$T/out"
    [ "$(wc -l < "$T/out")" -eq 4 ]
}
