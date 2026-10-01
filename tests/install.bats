#!/usr/bin/env bats
# install.sh: симлинк на wt.zsh и конфиг из образца, без потери прежних файлов.

load helpers

bats_require_minimum_version 1.5.0

setup() {
    setup_env
}

@test "first install: symlink, config from example, .zshrc hint" {
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    [ "$(readlink "$XDG_CONFIG_HOME/zsh/wt.zsh")" = "$WT_ZSH" ]
    cmp "$KIT_DIR/wt/wt.conf.example" "$XDG_CONFIG_HOME/agterm-kit/wt.conf"
    [[ $output == *"добавьте в $HOME/.zshrc строку: source $XDG_CONFIG_HOME/zsh/wt.zsh"* ]]
}

@test "old wt.zsh is kept as .bak, existing config is not overwritten" {
    mkdir -p "$XDG_CONFIG_HOME/zsh" "$XDG_CONFIG_HOME/agterm-kit"
    echo old > "$XDG_CONFIG_HOME/zsh/wt.zsh"
    echo "root = ~/mine" > "$XDG_CONFIG_HOME/agterm-kit/wt.conf"
    echo "source ~/.config/zsh/wt.zsh" > "$HOME/.zshrc"

    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$XDG_CONFIG_HOME"/zsh/wt.zsh.bak.*)" = old ]
    [ "$(cat "$XDG_CONFIG_HOME/agterm-kit/wt.conf")" = "root = ~/mine" ]
    [[ $output != *"добавьте в"* ]]
}

@test "second run changes nothing" {
    "$KIT_DIR/install.sh" >/dev/null
    cp "$HOME/.claude/settings.json" "$T/settings.first"
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    [[ $output == *"уже указывает на agterm-kit"* ]]
    [[ $output == *"уже есть в"* ]]
    [ -z "$(ls "$XDG_CONFIG_HOME/zsh" | grep bak || true)" ]
    cmp "$T/settings.first" "$HOME/.claude/settings.json"
    [ "$(ls "$HOME/.claude" | grep -c bak)" -eq 1 ]
}

@test "ask: config from example and hook registered in fresh claude settings" {
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    cmp "$KIT_DIR/ask/ask.conf.example" "$XDG_CONFIG_HOME/agterm-kit/ask.conf"
    jq -e --arg cmd "$KIT_DIR/ask/ask-hook.sh" '.hooks.PreToolUse == [{matcher: "AskUserQuestion",
        hooks: [{type: "command", command: $cmd, timeout: 3600}]}]' "$HOME/.claude/settings.json"
}

@test "ask: existing settings and hooks are kept, symlinked settings stay a symlink" {
    mkdir -p "$HOME/.claude" "$T/dotfiles"
    echo '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"dcg"}]}],"Stop":[]}}' > "$T/dotfiles/settings.json"
    ln -s "$T/dotfiles/settings.json" "$HOME/.claude/settings.json"
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    [ -L "$HOME/.claude/settings.json" ]
    jq -e '.model == "opus" and .hooks.Stop == [] and (.hooks.PreToolUse | length) == 2
        and .hooks.PreToolUse[0].hooks[0].command == "dcg"
        and .hooks.PreToolUse[1].matcher == "AskUserQuestion"' "$T/dotfiles/settings.json"
}

@test "ask: CLAUDE_CONFIG_DIR picks the settings file" {
    export CLAUDE_CONFIG_DIR=$T/claude-alt
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    jq -e '.hooks.PreToolUse[0].matcher == "AskUserQuestion"' "$CLAUDE_CONFIG_DIR/settings.json"
    [ ! -e "$HOME/.claude/settings.json" ]
}

@test "ask: broken settings.json is left alone and install fails" {
    mkdir -p "$HOME/.claude"
    echo '{"model": ' > "$HOME/.claude/settings.json"
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 1 ]
    [ "$(cat "$HOME/.claude/settings.json")" = '{"model": ' ]
    [[ $output == *"не JSON-объект"* ]]
}

@test "ask: stale or duplicate hook entries collapse into one correct entry" {
    local cmd=$KIT_DIR/ask/ask-hook.sh
    mkdir -p "$HOME/.claude"
    jq -n --arg cmd "$cmd" '{hooks: {PreToolUse: [
        {matcher: "AskUserQuestion", hooks: [{type: "command", command: $cmd, timeout: 600}]},
        {matcher: "*", hooks: [{type: "command", command: "orca"}, {type: "command", command: $cmd}]},
        {matcher: "Bash", hooks: [{type: "command", command: "dcg"}]}
    ]}}' > "$HOME/.claude/settings.json"
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    jq -e --arg cmd "$cmd" '.hooks.PreToolUse == [
        {matcher: "*", hooks: [{type: "command", command: "orca"}]},
        {matcher: "Bash", hooks: [{type: "command", command: "dcg"}]},
        {matcher: "AskUserQuestion", hooks: [{type: "command", command: $cmd, timeout: 3600}]}
    ]' "$HOME/.claude/settings.json"
}

@test "ask: correct entry keeps its place, file mode 600 is kept on rewrite" {
    local cmd=$KIT_DIR/ask/ask-hook.sh
    mkdir -p "$HOME/.claude"
    jq -n --arg cmd "$cmd" '{hooks: {PreToolUse: [
        {matcher: "AskUserQuestion", hooks: [{type: "command", command: $cmd, timeout: 3600}]},
        {matcher: "Bash", hooks: [{type: "command", command: "dcg"}]}
    ]}}' > "$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$T/before.json"
    run "$KIT_DIR/install.sh"
    [[ $output == *"уже есть в"* ]]
    cmp "$T/before.json" "$HOME/.claude/settings.json"
    [ -z "$(ls "$HOME/.claude" | grep bak || true)" ]

    echo '{"model":"opus"}' > "$HOME/.claude/settings.json"
    chmod 600 "$HOME/.claude/settings.json"
    "$KIT_DIR/install.sh" >/dev/null
    [ "$(stat -c %a "$HOME/.claude/settings.json" 2>/dev/null || stat -f %Lp "$HOME/.claude/settings.json")" = 600 ]
}

@test "ask: codex gets the mcp server once, existing config is kept" {
    mkdir -p "$HOME/.codex"
    printf '%s\n' 'model = "gpt-6"' '' '[mcp_servers.other]' 'command = "x"' > "$HOME/.codex/config.toml"
    "$KIT_DIR/install.sh" >/dev/null
    run "$KIT_DIR/install.sh"
    [[ $output == *"agterm-ask для Codex уже есть в $HOME/.codex/config.toml"* ]]
    [ "$(grep -c '^\[mcp_servers\.agterm-ask\]' "$HOME/.codex/config.toml")" -eq 1 ]
    head -4 "$HOME/.codex/config.toml" | cmp - <(printf '%s\n' 'model = "gpt-6"' '' '[mcp_servers.other]' 'command = "x"')
    grep -qx "command = \"$KIT_DIR/ask/agterm-ask-mcp\"" "$HOME/.codex/config.toml"
    grep -qx 'tool_timeout_sec = 3600' "$HOME/.codex/config.toml"
    grep -q '^env_vars = \[.*"AGTERM_SESSION_ID".*"AGTERM_SOCKET"' "$HOME/.codex/config.toml"
    grep -A1 -x '\[mcp_servers.agterm-ask.tools.ask_user\]' "$HOME/.codex/config.toml" | grep -qx 'approval_mode = "approve"'
}

@test "ask: stale managed codex block is replaced, text around it is kept" {
    mkdir -p "$HOME/.codex"
    printf '%s\n' 'model = "gpt-6"' '# agterm-kit:ask begin' '[mcp_servers.agterm-ask]' 'command = "/old"' \
        '# agterm-kit:ask end' '' '[mcp_servers.after]' 'command = "y"' > "$HOME/.codex/config.toml"
    run "$KIT_DIR/install.sh"
    [[ $output == *"agterm-ask для Codex: записано"* ]]
    run ! grep -q '/old' "$HOME/.codex/config.toml"
    [ "$(grep -c '^\[mcp_servers\.agterm-ask\]' "$HOME/.codex/config.toml")" -eq 1 ]
    [ "$(head -1 "$HOME/.codex/config.toml")" = 'model = "gpt-6"' ]
    [ "$(tail -2 "$HOME/.codex/config.toml" | head -1)" = '[mcp_servers.after]' ]
    grep -q '^env_vars = ' "$HOME/.codex/config.toml"
}

@test "ask: AGENTS.md of codex and opencode get the ask_user rule once" {
    mkdir -p "$HOME/.codex" "$XDG_CONFIG_HOME/opencode"
    printf '# Мои правила\n\nПиши коротко.\n' > "$HOME/.codex/AGENTS.md"
    "$KIT_DIR/install.sh" >/dev/null
    cp "$HOME/.codex/AGENTS.md" "$T/first.md"
    run "$KIT_DIR/install.sh"
    [[ $output == *"инструкция ask_user уже есть в $HOME/.codex/AGENTS.md"* ]]
    cmp "$T/first.md" "$HOME/.codex/AGENTS.md"
    [ "$(head -3 "$HOME/.codex/AGENTS.md")" = "$(printf '# Мои правила\n\nПиши коротко.')" ]
    local f
    for f in "$HOME/.codex/AGENTS.md" "$XDG_CONFIG_HOME/opencode/AGENTS.md"; do
        [ "$(grep -c -- '<!-- agterm-kit:ask begin -->' "$f")" -eq 1 ]
        grep -q 'вызывай MCP-инструмент `ask_user`' "$f"
    done
}

@test "ask: broken markers stop the install and leave the file untouched" {
    mkdir -p "$HOME/.codex"
    local bad
    for bad in "$(printf 'model = "x"\n# agterm-kit:ask begin\n[mcp_servers.agterm-ask]\n\n[mcp_servers.after]\ncommand = "y"')" \
               "$(printf '# agterm-kit:ask end\nmodel = "x"\n# agterm-kit:ask begin')"; do
        printf '%s\n' "$bad" > "$HOME/.codex/config.toml"
        run "$KIT_DIR/install.sh"
        [ "$status" -eq 1 ]
        [[ $output == *"не образуют пару"* ]]
        [ "$(cat "$HOME/.codex/config.toml")" = "$bad" ]
    done
}

@test "ask: hand-written codex server without markers is left alone" {
    mkdir -p "$HOME/.codex"
    printf '%s\n' '[mcp_servers.agterm-ask]' 'command = "/mine"' > "$HOME/.codex/config.toml"
    run "$KIT_DIR/install.sh"
    [[ $output == *"прописан вручную, не трогаю"* ]]
    [ "$(cat "$HOME/.codex/config.toml")" = "$(printf '%s\n' '[mcp_servers.agterm-ask]' 'command = "/mine"')" ]
}

@test "ask: without codex or opencode installed nothing is created for them" {
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.codex" ]
    [ ! -e "$XDG_CONFIG_HOME/opencode" ]
}

@test "ask: opencode gets the mcp server, other servers and manual enabled flag are kept" {
    mkdir -p "$XDG_CONFIG_HOME/opencode"
    echo '{"$schema":"https://opencode.ai/config.json","mcp":{"other":{"type":"local","command":["x"]},
        "agterm-ask":{"type":"local","command":["/old/path"],"enabled":false}}}' > "$XDG_CONFIG_HOME/opencode/opencode.json"
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    jq -e --arg cmd "$KIT_DIR/ask/agterm-ask-mcp" '.mcp == {
        other: {type: "local", command: ["x"]},
        "agterm-ask": {type: "local", command: [$cmd], enabled: false}
    } and ."$schema" == "https://opencode.ai/config.json"' "$XDG_CONFIG_HOME/opencode/opencode.json"
}

@test "ask: opencode.jsonc stays untouched, the server goes into opencode.json beside it" {
    mkdir -p "$XDG_CONFIG_HOME/opencode"
    printf '// мой конфиг\n{"mcp": {"x": {"type": "local", "command": ["x"]}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.jsonc"
    cp "$XDG_CONFIG_HOME/opencode/opencode.jsonc" "$T/before.jsonc"
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    cmp "$T/before.jsonc" "$XDG_CONFIG_HOME/opencode/opencode.jsonc"
    jq -e --arg cmd "$KIT_DIR/ask/agterm-ask-mcp" '.mcp == {"agterm-ask": {type: "local", command: [$cmd]}}' \
        "$XDG_CONFIG_HOME/opencode/opencode.json"
}

@test "ask: agterm-ask written by hand in opencode.jsonc is left alone" {
    mkdir -p "$XDG_CONFIG_HOME/opencode"
    printf '// мой\n{"mcp": {"agterm-ask": {"type": "local", "command": ["/mine"]}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.jsonc"
    run "$KIT_DIR/install.sh"
    [[ $output == *"opencode.jsonc прописан вручную, не трогаю"* ]]
    [ ! -e "$XDG_CONFIG_HOME/opencode/opencode.json" ]
}
