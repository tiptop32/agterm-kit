#!/usr/bin/env bats
# agterm-stage с поддельным agtermctl: вызовы пишутся в лог, tree берётся из $T/tree.json.

load helpers

STAGE=$KIT_DIR/stages/agterm-stage
SID=AAAA-1111

setup() {
    setup_env
    export XDG_STATE_HOME=$HOME/.local/state AGTERM_SESSION_ID=aaaa-1111
    unset AGTERMCTL
    STATE=$XDG_STATE_HOME/agterm-kit/stages
    echo '{"result":{"tree":{"workspaces":[]}}}' > "$T/tree.json"
    cat > "$T/bin/agtermctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_AGTERM_LOG"
case "$1 $2" in
"tree --json") cat "$T/tree.json" ;;
"session new") echo '{"result":{"id":"bbbb-2222"}}' ;;
esac
EOF
    chmod +x "$T/bin/agtermctl"
}

state() { jq -r "$1" "$STATE/$SID.json"; }
hook() { printf '%s' "$1" | "$STAGE" hook; }

@test "set stores stage and summary and draws the sidebar info line" {
    run "$STAGE" set plan 'раздаю задачи 3/7'
    [ "$status" -eq 0 ]
    [ "$(state .stage)/$(state .summary)/$(state .source)" = "plan/раздаю задачи 3/7/agent" ]
    grep -qxF 'session info --markdown ^[◈ План](color: "blue") · раздаю задачи 3/7 --target AAAA-1111' "$FAKE_AGTERM_LOG"
    run "$STAGE" get
    [ "$output" = "План · раздаю задачи 3/7" ]
}

@test "russian stage names are accepted and unknown ones are refused" {
    "$STAGE" set ревью
    [ "$(state .stage)" = review ]
    run "$STAGE" set somewhere
    [ "$status" -eq 2 ]
    [[ $output == *"неизвестная стадия"* ]]
    [ "$(state .stage)" = review ]
}

@test "note keeps the stage and its start time, a new stage resets it" {
    "$STAGE" set exec 'задача 1'
    since=$(state .since)
    sleep 1
    "$STAGE" note 'задача 2'
    [ "$(state .stage)/$(state .summary)/$(state .since)" = "exec/задача 2/$since" ]
    "$STAGE" set review
    [ "$(state .since)" != "$since" ]
    [ "$(state '.history | map(.stage) | join(",")')" = "exec,exec,review" ]
}

@test "markdown characters in the summary are escaped" {
    "$STAGE" set mr 'поправил *bold* и [ссылку]'
    grep -qF '· поправил \*bold\* и \[ссылку\] --target' "$FAKE_AGTERM_LOG"
}

@test "skill hook moves the stage and repeated skill keeps agent summary" {
    hook '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"planning:make"}}'
    [ "$(state .stage)/$(state .summary)/$(state .source)" = "plan//planning:make/skill:planning:make" ]
    "$STAGE" note 'шаги 1-5 готовы'
    hook '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"planning:make"}}'
    [ "$(state .summary)" = "шаги 1-5 готовы" ]
    hook '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"review-refactor"}}'
    [ "$(state .stage)" = review ]
}

@test "slash command in the prompt sets the stage, plain prompt does not" {
    hook '{"hook_event_name":"UserPromptSubmit","prompt":"посмотри код"}'
    [ ! -e "$STATE/$SID.json" ]
    hook '{"hook_event_name":"UserPromptSubmit","prompt":"/gitlab-mr создай мр"}'
    [ "$(state .stage)" = mr ]
}

@test "bash hook applies the agent command even when the agent runs it in a sandbox" {
    hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"/x/stages/agterm-stage set exec \"задача 2/5: тесты\" >/dev/null 2>&1 && echo ok"}}'
    [ "$(state .stage)/$(state .summary)/$(state .source)" = "exec/задача 2/5: тесты/agent" ]
    # Песочница: каталог состояния недоступен на запись. Команда не падает, хук уже всё сделал.
    chmod 500 "$STATE"
    run "$STAGE" note 'другое'
    chmod 700 "$STATE"
    [ "$status" -eq 0 ]
    [[ $output == *"применяет хук"* ]]
}

@test "bash hook recognizes MR creation and merge only after the command succeeded" {
    # PreToolUse: вызов ещё может быть отклонён пользователем или упасть.
    hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"glab mr create --fill"}}'
    [ ! -e "$STATE/$SID.json" ]
    hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"glab mr create --fill"}}'
    [ "$(state .stage)" = mr ]
    hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"glab mr merge 12"}}'
    [ "$(state .stage)/$(state .summary)" = "done/MR влит" ]
    hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
    [ "$(state .stage)" = done ]
}

post() { jq -n --arg c "$1" '{hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: $c}}' | "$STAGE" hook; }

@test "explicit command parsing ignores mentions, redirections and the rest of the script" {
    post $'agterm-stage set plan "шаги"\nmake test'
    [ "$(state .stage)/$(state .summary)" = "plan/шаги" ]
    post 'cd /x && stages/agterm-stage note "второй шаг" 2>/dev/null; echo hi'
    [ "$(state .summary)" = "второй шаг" ]
    post 'grep -rn agterm-stage note README.md'
    post 'echo agterm-stage set done'
    post 'stages/agterm-stage note "сборка `date`"'
    post 'stages/agterm-stage get --json'
    [ "$(state .stage)/$(state .summary)" = "plan/второй шаг" ]
}

@test "hook never fails: bad session id, odd payload, unwritable state" {
    run env AGTERM_SESSION_ID=session-1 "$STAGE" hook <<<'{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"planning:make"}}'
    [ "$status" -eq 0 ] && [ -z "$output" ]
    run "$STAGE" hook <<<'{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":"ls"}'
    [ "$status" -eq 0 ]
    mkdir -p "$(dirname "$STATE")" && : > "$STATE"
    run "$STAGE" hook <<<'{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"planning:make"}}'
    [ "$status" -eq 0 ]
}

@test "long summary is cut to the 512 byte limit of an info line" {
    long=$(python3 -c 'print("😀" * 140)')
    "$STAGE" set exec "$long"
    line=$(sed -n 's/^session info --markdown \(.*\) --target AAAA-1111$/\1/p' "$FAKE_AGTERM_LOG")
    (( $(printf '%s' "$line" | wc -c) <= 512 ))
    [[ $line == *"…" ]]
}

@test "session start restores the info line and tells the agent how to report" {
    "$STAGE" set review 'смотрю дифф'
    : > "$FAKE_AGTERM_LOG"
    run hook '{"hook_event_name":"SessionStart","source":"resume"}'
    [ "$status" -eq 0 ]
    [[ $output == *"agterm-stage"*" set <стадия>"* ]]
    grep -q '^session info --markdown ^\[◎ Ревью\]' "$FAKE_AGTERM_LOG"
}

@test "hook is a silent no-op outside agterm and on garbage input" {
    unset AGTERM_SESSION_ID
    run hook '{"hook_event_name":"SessionStart"}'
    [ "$status" -eq 0 ] && [ -z "$output" ]
    export AGTERM_SESSION_ID=aaaa-1111
    run hook 'not json'
    [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "restore pushes only lost lines of live sessions and drops stale records" {
    "$STAGE" set plan 'есть в дереве'
    AGTERM_SESSION_ID=cccc-3333 "$STAGE" set exec 'старая'
    jq '.updatedAt -= 30*86400' "$STATE/CCCC-3333.json" > "$T/x" && mv "$T/x" "$STATE/CCCC-3333.json"
    echo '{"result":{"tree":{"workspaces":[{"name":"w","sessions":[{"id":"aaaa-1111"},{"id":"dddd-4444"}]}]}}}' > "$T/tree.json"
    : > "$FAKE_AGTERM_LOG"
    run "$STAGE" restore
    [ "$output" = 1 ]
    grep -q 'session info --markdown .* --target AAAA-1111' "$FAKE_AGTERM_LOG"
    [ ! -e "$STATE/CCCC-3333.json" ]
    # Строка уже на месте: второй проход ничего не шлёт.
    line=$(jq -r '.' <<<'"^[◈ План](color: \"blue\") · есть в дереве"')
    jq --arg i "$line" '.result.tree.workspaces[0].sessions[0].info = $i' "$T/tree.json" > "$T/x" && mv "$T/x" "$T/tree.json"
    run "$STAGE" restore
    [ "$output" = 0 ]
}

@test "board creates the board session once and then just selects it" {
    run "$STAGE" board
    [ "$status" -eq 0 ]
    grep -q '^session new --name Доска --command .*agterm-stage board-host --json$' "$FAKE_AGTERM_LOG"
    grep -qx 'session select --target BBBB-2222' "$FAKE_AGTERM_LOG"
    echo '{"result":{"tree":{"workspaces":[{"name":"w","sessions":[{"id":"bbbb-2222","overlay":false}]}]}}}' > "$T/tree.json"
    : > "$FAKE_AGTERM_LOG"
    "$STAGE" board
    ! grep -q '^session new' "$FAKE_AGTERM_LOG"
    grep -q "^session overlay open --html $KIT_DIR/stages/board.html --js --chromeless --target BBBB-2222$" "$FAKE_AGTERM_LOG"
}

@test "board page parses exactly the info lines agterm-stage writes" {
    command -v node >/dev/null || skip "нет node"
    "$STAGE" set mr 'поправил *bold* и [ссылку]'
    line=$(sed -n 's/^session info --markdown \(.*\) --target AAAA-1111$/\1/p' "$FAKE_AGTERM_LOG")
    sed -n '/\/\/ parse:begin/,/\/\/ parse:end/p' "$KIT_DIR/stages/board.html" > "$T/parse.js"
    run node -e "$(cat "$T/parse.js")
        console.log(JSON.stringify([parseInfo(process.argv[1]), parseInfo('^[◇ Анализ](color: \"purple\")'), parseInfo('чужая строка')]))" "$line"
    [ "$output" = '[{"stage":"mr","summary":"поправил *bold* и [ссылку]"},{"stage":"analysis","summary":""},null]' ]
}
