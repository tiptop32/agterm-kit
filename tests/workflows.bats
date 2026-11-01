#!/usr/bin/env bats
# Контракт установки GUI: чужие настройки, отмена и повреждённые зависимости.
load helpers

setup() {
    setup_env
    export XDG_DATA_HOME=$HOME/.local/share
    unset AGTERM_COOKBOOK_SOURCE
}

# Изолированная копия кода с минимальным upstream: сеть тестам не нужна.
# Реальный digest считается только для входного fixture; ожидаемый результат установки
# проверяется по состоянию keymap/settings/skills, а не по устройству installer.
prepare_workflows() {
    export TEST_KIT=$T/kit
    mkdir -p "$TEST_KIT/workflows" "$T/source/cookbook/annotate-document" "$T/source/cookbook/html-doc-overlay"
    cp "$KIT_DIR/workflows/"*.py "$KIT_DIR/workflows/workflows.conf.example" "$TEST_KIT/workflows/"
    echo '# fixture skill' > "$T/source/cookbook/annotate-document/SKILL.md"
    echo '# fixture doc skill' > "$T/source/cookbook/html-doc-overlay/SKILL.md"
    python3 - "$T/source" "$TEST_KIT" <<'PY'
import hashlib,json,pathlib,sys
source,kit=map(pathlib.Path,sys.argv[1:])
files={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob('*') if p.is_file()}
(kit/'workflows/recipes.lock.json').write_text(json.dumps({'repository':'umputun/agterm','commit':'test','files':files}))
PY
}

@test "gui install preserves shortcuts hooks and symlinks and is idempotent" {
    prepare_workflows
    mkdir -p "$XDG_CONFIG_HOME/agterm" "$HOME/.claude" "$T/dotfiles"
    printf 'command "Mine" ctrl+a>m /my/command\ncommand "Claude Resume" ctrl+a>r ~/.local/bin/claude-pick-conversation.py\n' > "$T/dotfiles/keymap"
    ln -s "$T/dotfiles/keymap" "$XDG_CONFIG_HOME/agterm/keymap.conf"
    echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-status-hook"}]}]}}' > "$HOME/.claude/settings.json"
    chmod 600 "$HOME/.claude/settings.json"
    run python3 "$TEST_KIT/workflows/install.py" --source "$T/source"
    [ "$status" -eq 0 ]
    [ -L "$XDG_CONFIG_HOME/agterm/keymap.conf" ]
    grep -qx 'command "Mine" ctrl+a>m /my/command' "$T/dotfiles/keymap"
    grep -q '"Claude Resume" ctrl+a>r --error-hud .*resume$' "$T/dotfiles/keymap"
    [ "$(grep -c ' resume$' "$T/dotfiles/keymap")" -eq 1 ]
    jq -e '.model == "opus" and .hooks.Stop[0].hooks[0].command == "my-status-hook" and (.hooks.Stop|length)==2' "$HOME/.claude/settings.json"
    [ -L "$HOME/.claude/skills/webrev" ]
    [ "$(cat "$HOME/.claude/skills/agdoc/SKILL.md")" = '# fixture doc skill' ]
    cp "$T/dotfiles/keymap" "$T/keymap.first"
    cp "$HOME/.claude/settings.json" "$T/settings.first"
    run python3 "$TEST_KIT/workflows/install.py" --source "$T/source"
    [ "$status" -eq 0 ]
    cmp "$T/keymap.first" "$T/dotfiles/keymap"
    cmp "$T/settings.first" "$HOME/.claude/settings.json"
    [ "$(stat -c %a "$HOME/.claude/settings.json" 2>/dev/null || stat -f %Lp "$HOME/.claude/settings.json")" = 600 ]
}

@test "gui install rejects corrupted source before changing user settings" {
    prepare_workflows
    echo changed > "$T/source/cookbook/annotate-document/SKILL.md"
    run python3 "$TEST_KIT/workflows/install.py" --source "$T/source"
    [ "$status" -eq 1 ]
    [[ $output == *"SHA-256"* ]]
    [ ! -e "$XDG_CONFIG_HOME/agterm/keymap.conf" ]
    [ ! -e "$HOME/.claude/settings.json" ]
}

@test "gui install refuses broken markers and foreign skills" {
    prepare_workflows
    mkdir -p "$XDG_CONFIG_HOME/agterm"
    printf 'mine\n# agterm-kit:gui begin\n' > "$XDG_CONFIG_HOME/agterm/keymap.conf"
    cp "$XDG_CONFIG_HOME/agterm/keymap.conf" "$T/before"
    run python3 "$TEST_KIT/workflows/install.py" --source "$T/source"
    [ "$status" -eq 1 ]
    cmp "$T/before" "$XDG_CONFIG_HOME/agterm/keymap.conf"
    echo mine > "$XDG_CONFIG_HOME/agterm/keymap.conf"
    mkdir -p "$HOME/.claude/skills/webrev"
    echo custom > "$HOME/.claude/skills/webrev/SKILL.md"
    run python3 "$TEST_KIT/workflows/install.py" --source "$T/source"
    [ "$status" -eq 1 ]
    [ "$(cat "$HOME/.claude/skills/webrev/SKILL.md")" = custom ]
    [ ! -e "$HOME/.claude/settings.json" ]
}

@test "cookbook dialogs use GUI and finishing defaults to continue" {
    export AGTERM_KIT_CTL=$T/bin/agtermctl AGTERM_KIT_ACTION=finish-offer
    run python3 "$KIT_DIR/workflows/ctl.py" ask open finished --default clear --target SESSION-1
    [ "$status" -eq 0 ]
    grep -q 'ask open finished --default continue --target SESSION-1 --style gui' "$FAKE_AGTERM_LOG"
}

@test "gui install preserves settings when a later destination cannot be written" {
    prepare_workflows
    mkdir -p "$XDG_CONFIG_HOME/agterm" "$HOME/.claude"
    echo 'command "Mine" ctrl+a>m /my/command' > "$XDG_CONFIG_HOME/agterm/keymap.conf"
    echo '{"model":"opus"}' > "$HOME/.claude/settings.json"
    echo occupied > "$HOME/.claude/skills"
    cp "$XDG_CONFIG_HOME/agterm/keymap.conf" "$T/keymap.before"
    cp "$HOME/.claude/settings.json" "$T/settings.before"
    run python3 "$TEST_KIT/workflows/install.py" --source "$T/source"
    [ "$status" -eq 1 ]
    cmp "$T/keymap.before" "$XDG_CONFIG_HOME/agterm/keymap.conf"
    cmp "$T/settings.before" "$HOME/.claude/settings.json"
}
