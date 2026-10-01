#!/usr/bin/env bats
# agterm-ask: ядро вопросов в оверлее. Коды выхода: 0 ответ, 1 ошибка, 2 закрыли, 3 недоступно.

load helpers

bats_require_minimum_version 1.5.0

ASK=$KIT_DIR/ask/agterm-ask

setup() {
    setup_env
    setup_ask_env
}

questions() {
    jq -n -c '{questions: [{question: "Куда?", options: [{label: "Влево"}, {label: "Вправо"}]}]}'
}

@test "json mode prints answers for the questions on stdin" {
    export FAKE_VALUE='{"answers":{"Куда?":"Вправо"}}'
    run --separate-stderr "$ASK" < <(questions)
    [ "$status" -eq 0 ]
    [ "$output" = '{"answers":{"Куда?":"Вправо"}}' ]
}

@test "file argument is read like stdin" {
    questions > "$T/q.json"
    export FAKE_VALUE='{"answers":{"Куда?":"Влево"}}'
    run --separate-stderr "$ASK" "$T/q.json"
    [ "$status" -eq 0 ]
    [ "$output" = '{"answers":{"Куда?":"Влево"}}' ]
}

@test "short mode: question and options as arguments, plain answer out" {
    export FAKE_VALUE='{"answers":{"Пушить?":"Нет, сначала PR"}}'
    run --separate-stderr "$ASK" --context "deploy" "Пушить?" "Да" "Нет, сначала PR"
    [ "$status" -eq 0 ]
    [ "$output" = "Нет, сначала PR" ]
    page_data | jq -e '.context == "deploy" and .questions == [{question: "Пушить?", options: [{label: "Да"}, {label: "Нет, сначала PR"}]}]'
}

@test "dismissed page exits 2, unavailable overlay exits 3" {
    export FAKE_OUTCOME=dismissed
    run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 2 ]
    [ -z "$output" ]

    unset FAKE_OUTCOME
    export FAKE_OPEN_FAIL=1
    run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 3 ]
    [[ $stderr == *"overlay already open"* ]]
}

@test "outside agterm exits 3 without calling agtermctl" {
    unset AGTERM_ENABLED
    run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 3 ]
    [[ $stderr == *"не внутри agterm"* ]]
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "invalid input exits 1 with a message naming the problem" {
    local input expected
    while IFS='|' read -r input expected; do
        run --separate-stderr "$ASK" <<<"$input"
        [ "$status" -eq 1 ] || { echo "status $status for $input"; false; }
        [[ $stderr == *"$expected"* ]] || { echo "stderr '$stderr' for $input"; false; }
    done <<'EOF'
not json|input is not valid JSON
[]|input must be
{"questions":[]}|from 1 to 4
{"questions":[{"question":"","options":[{"label":"A"}]}]}|non-empty "question"
{"questions":[{"question":"Q","options":[{"label":"A"}]},{"question":"Q","options":[{"label":"B"}]}]}|unique
{"questions":[{"question":"Q","options":[]}]}|from 1 to 9
{"questions":[{"question":"Q","options":[{"label":""}]}]}|non-empty "label"
{"questions":[{"question":"Q","multiSelect":"yes","options":[{"label":"A"}]}]}|boolean
EOF
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "config agents: only listed agents get the overlay" {
    export AGTERM_ASK_CONFIG=$T/ask.conf FAKE_VALUE='{"answers":{"Q?":"A"}}'
    echo "agents = codex,  opencode   # только они" > "$AGTERM_ASK_CONFIG"

    AGTERM_ASK_AGENT=claude-code run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 3 ]
    [[ $stderr == *"оверлей выключен для агента claude"* ]]
    [ ! -e "$FAKE_AGTERM_LOG" ]

    AGTERM_ASK_AGENT=codex-mcp-client run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 0 ]
    [ "$output" = A ]

    echo "agents = all" > "$AGTERM_ASK_CONFIG"
    AGTERM_ASK_AGENT=claude-code run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 0 ]
}

@test "config agents: a bad value is reported and ignored" {
    export AGTERM_ASK_CONFIG=$T/ask.conf FAKE_VALUE='{"answers":{"Q?":"A"}}'
    echo 'agents = codex; rm -rf /' > "$AGTERM_ASK_CONFIG"
    AGTERM_ASK_AGENT=claude-code run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 0 ]
    [[ $stderr == *"agents = codex; rm -rf /: ожидается all"* ]]
}

@test "broken result after open closes its own page and exits 3" {
    export FAKE_OUTCOME=broken
    run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 3 ]
    [[ $stderr == *"не прочитать ответ страницы"* ]]
    grep -q "session overlay close --target SESSION-1" "$FAKE_AGTERM_LOG"
}

@test "page answer for the wrong question exits 1" {
    export FAKE_VALUE='{"answers":{"Другой":"A"}}'
    run --separate-stderr "$ASK" "Q?" A B
    [ "$status" -eq 1 ]
    [[ $stderr == *"не на те вопросы"* ]]
}

@test "every run leaves a trace line without question text" {
    export FAKE_VALUE='{"answers":{"Секретный вопрос?":"A"}}' AGTERM_ASK_AGENT=codex
    "$ASK" "Секретный вопрос?" A B >/dev/null
    export FAKE_OUTCOME=dismissed
    "$ASK" "Секретный вопрос?" A B || true
    [ "$(wc -l < "$AGTERM_ASK_LOG")" -eq 2 ]
    awk -F'\t' 'NR == 1 && $2 == "codex" && $3 == "answered" && $5 == 1 { ok++ }
                NR == 2 && $3 == "dismissed" { ok++ } END { exit ok != 2 }' "$AGTERM_ASK_LOG"
    run ! grep -q "Секретный" "$AGTERM_ASK_LOG"
}

@test "help exits 0 and leaves no trace" {
    run "$ASK" --help
    [ "$status" -eq 0 ]
    [[ $output == *"Коды выхода"* ]]
    [ ! -e "$AGTERM_ASK_LOG" ]
}
