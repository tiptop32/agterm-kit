#!/usr/bin/env bats
# install.sh: симлинк на wt.zsh и конфиг из образца, без потери прежних файлов.

load helpers

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
    run "$KIT_DIR/install.sh"
    [ "$status" -eq 0 ]
    [[ $output == *"уже указывает на agterm-kit"* ]]
    [ -z "$(ls "$XDG_CONFIG_HOME/zsh" | grep bak || true)" ]
}
