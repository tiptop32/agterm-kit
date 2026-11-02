#!/usr/bin/env bats
# Интеграция omp: установка расширения и безопасная передача статусов agterm.

load helpers

bats_require_minimum_version 1.5.0

setup() {
    setup_env
}

@test "omp install creates symlinks and is idempotent" {
    mkdir -p "$HOME/.omp/agent"

    run "$KIT_DIR/omp/install.sh"
    [ "$status" -eq 0 ]
    [ "$(readlink "$HOME/.omp/agent/extensions/agterm-status.ts")" = "$KIT_DIR/omp/agterm-status.ts" ]
    [ "$(readlink "$HOME/.omp/agent/extensions/agterm-status.sh")" = "$KIT_DIR/omp/agterm-status.sh" ]
    [[ $output != *"config.yml"* ]]

    run "$KIT_DIR/omp/install.sh"
    [ "$status" -eq 0 ]
    [[ $output == *"уже указывает на agterm-kit"* ]]
    [ "$(find "$HOME/.omp/agent/extensions" -type l | wc -l | tr -d ' ')" -eq 2 ]
}

@test "omp install does not touch config.yml" {
    mkdir -p "$HOME/.omp/agent"
    printf 'modelRoles: {}\n' > "$HOME/.omp/agent/config.yml"

    run "$KIT_DIR/omp/install.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.omp/agent/config.yml")" = "modelRoles: {}" ]
}

@test "omp status does nothing without AGTERM_ENABLED" {
    export AGTERM_CLAUDE_STATUS_SCRIPT=$T/status-recorder
    printf '#!/bin/sh\necho called >> "$T/status.log"\n' > "$AGTERM_CLAUDE_STATUS_SCRIPT"
    chmod +x "$AGTERM_CLAUDE_STATUS_SCRIPT"
    unset AGTERM_ENABLED

    run "$KIT_DIR/omp/agterm-status.sh" active --blink
    [ "$status" -eq 0 ]
    [ ! -e "$T/status.log" ]
}

@test "omp status forwards arguments and ignores adapter failures" {
    export AGTERM_CLAUDE_STATUS_SCRIPT=$T/status-recorder
    cat > "$AGTERM_CLAUDE_STATUS_SCRIPT" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$T/status.log"
exit 42
EOF
    chmod +x "$AGTERM_CLAUDE_STATUS_SCRIPT"

    run "$KIT_DIR/omp/agterm-status.sh" active --blink
    [ "$status" -eq 0 ]
    run "$KIT_DIR/omp/agterm-status.sh" completed
    [ "$status" -eq 0 ]
    [ "$(cat "$T/status.log")" = "$(printf 'active --blink\ncompleted')" ]
}
