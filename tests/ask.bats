#!/usr/bin/env bats
# ask-hook.sh: вопрос AskUserQuestion уходит в HTML-оверлей, ответ возвращается в updatedInput.
# Любой сбой даёт пустой вывод, и Claude Code спрашивает в терминале.

load helpers

bats_require_minimum_version 1.5.0

HOOK=$KIT_DIR/ask/ask-hook.sh

setup() {
    setup_env
    setup_ask_env
}

# ask_input <вопрос> [multi]: вход хука с одним вопросом и вариантами A, B.
ask_input() {
    jq -n --arg q "$1" --argjson multi "${2:-false}" '{
        session_id: "s", cwd: "/work/agterm-kit", hook_event_name: "PreToolUse",
        tool_name: "AskUserQuestion",
        tool_input: {questions: [{question: $q, header: "Выбор", multiSelect: $multi,
            options: [{label: "A", description: "первый"}, {label: "B", preview: "код B"}]}]}
    }' > "$T/in.json"
}

answer() {
    FAKE_VALUE=$1
    export FAKE_VALUE
}

run_hook() {
    run --separate-stderr "$HOOK" < "$T/in.json"
}

@test "submitted answer: allow with questions echoed and answers added" {
    ask_input "Какой путь?"
    answer '{"answers":{"Какой путь?":"B"},"annotations":{"Какой путь?":{"preview":"код B"}}}'
    run_hook
    [ "$status" -eq 0 ]
    jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
        and .hookSpecificOutput.permissionDecision == "allow"' <<<"$output"
    jq -e --slurpfile in "$T/in.json" '.hookSpecificOutput.updatedInput.questions == $in[0].tool_input.questions' <<<"$output"
    jq -e '.hookSpecificOutput.updatedInput.answers == {"Какой путь?": "B"}' <<<"$output"
    jq -e '.hookSpecificOutput.updatedInput.annotations == {"Какой путь?": {"preview": "код B"}}' <<<"$output"
}

@test "overlay opens on own session with js, floating 80 percent, no follow" {
    ask_input "Q"
    answer '{"answers":{"Q":"A"}}'
    run_hook
    [ "$status" -eq 0 ]
    grep -q -- "session overlay open --html .*/ask.html --js --target SESSION-1 --json --size-percent 80$" "$FAKE_AGTERM_LOG"
    grep -q -- "session overlay result --page PAGE-1 --json" "$FAKE_AGTERM_LOG"
}

@test "socket from AGTERM_SOCKET is passed to every call" {
    ask_input "Q"
    answer '{"answers":{"Q":"A"}}'
    export AGTERM_SOCKET="$T/my sock"
    run_hook
    [ "$status" -eq 0 ]
    [ "$(grep -c -- "--socket $T/my sock$" "$FAKE_AGTERM_LOG")" -eq "$(wc -l < "$FAKE_AGTERM_LOG")" ]
}

@test "dismissed page: empty output, question falls back to terminal" {
    ask_input "Q"
    export FAKE_OUTCOME=dismissed
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "overlay that fails to open: empty output and a reason on stderr" {
    ask_input "Q"
    export FAKE_OPEN_FAIL=1
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ $stderr == *"overlay already open"* ]]
}

@test "outside agterm the hook does nothing and never calls agtermctl" {
    ask_input "Q"
    unset AGTERM_ENABLED
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "other tools pass through untouched" {
    jq -n '{tool_name: "Bash", tool_input: {command: "ls"}}' > "$T/in.json"
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "answer for a question that was not asked is rejected" {
    ask_input "Q"
    answer '{"answers":{"Другой":"A"}}'
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ $stderr == *"не на те вопросы"* ]]
}

@test "missing, empty or non-json answers are rejected" {
    ask_input "Q"
    local bad
    for bad in '{"answers":{}}' '{"answers":{"Q":""}}' '{"answers":{"Q":["A"]}}' 'A' ''; do
        answer "$bad"
        run_hook
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "multi-select answer and unknown annotation keys" {
    ask_input "Что включить?" true
    answer '{"answers":{"Что включить?":"A, B"},"annotations":{"чужой":{"notes":"x"}}}'
    run_hook
    [ "$status" -eq 0 ]
    jq -e '.hookSpecificOutput.updatedInput.answers == {"Что включить?": "A, B"}' <<<"$output"
    jq -e '.hookSpecificOutput.updatedInput | has("annotations") | not' <<<"$output"
}

@test "page embeds questions as json and markup in text cannot close the block" {
    ask_input 'Взять </script><img src=x onerror=alert(1)> или нет?'
    answer '{"answers":{"Взять </script><img src=x onerror=alert(1)> или нет?":"A"}}'
    run_hook
    [ "$status" -eq 0 ]
    run ! grep -q '@@ASK_DATA@@' "$T/page.html"
    run ! grep -q '<img src=x' "$T/page.html"
    # Блок данных разбирается как JSON и несёт исходный текст вопроса и имя проекта.
    sed -n 's/.*<script type="application\/json" id="ask-data">\(.*\)<\/script>.*/\1/p' "$T/page.html" > "$T/data.json"
    jq -e --slurpfile in "$T/in.json" '.questions == $in[0].tool_input.questions and .context == "Claude Code · agterm-kit"' "$T/data.json"
}

@test "config: enabled = no turns the hook off" {
    ask_input "Q"
    mkdir -p "$XDG_CONFIG_HOME/agterm-kit"
    echo "enabled = no   # выключено" > "$XDG_CONFIG_HOME/agterm-kit/ask.conf"
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "config: follow, full-size overlay and bad values" {
    ask_input "Q"
    answer '{"answers":{"Q":"A"}}'
    export AGTERM_ASK_CONFIG=$T/ask.conf
    printf '%s\n' "# комментарий" "follow = yes" "size = 0" "size = 300" "color = red" > "$AGTERM_ASK_CONFIG"
    run_hook
    [ "$status" -eq 0 ]
    jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<<"$output"
    [[ $stderr == *"size = 300"* ]]
    [[ $stderr == *"неизвестный ключ color"* ]]
    grep -q -- "--json --follow$" "$FAKE_AGTERM_LOG"
    run ! grep -q -- "--size-percent" "$FAKE_AGTERM_LOG"
}

@test "killed while waiting: closes its own page and exits quietly" {
    ask_input "Q"
    export FAKE_OUTCOME=pending
    "$HOOK" < "$T/in.json" > "$T/out" 2>&1 &
    local pid=$! i
    for i in $(seq 50); do
        grep -qs "overlay result" "$FAKE_AGTERM_LOG" && break
        sleep 0.1
    done
    kill -TERM "$pid"
    wait "$pid"
    grep -q "session overlay close --target SESSION-1" "$FAKE_AGTERM_LOG"
    [ ! -s "$T/out" ]
    [ -z "$(ls "$TMPDIR" | grep agterm-ask || true)" ]
}
