#!/usr/bin/env bats
# Поведение wt / wtl / wtrm на настоящих git-репах с поддельным agtermctl.

load helpers

setup() {
    setup_env
    make_repo "$T/work" api
    make_repo "$T/personal" blog
    write_config \
        "# комментарий" \
        "root = ~/wt   # хвостовой комментарий" \
        "" \
        "repos = ~/../work" \
        "repos = $T/personal/"
    # ~/../work — это $T/work: проверяем раскрытие ~ в repos.
}

# --- конфиг ---------------------------------------------------------------

@test "wt finds repo in second repos dir and puts worktree under root" {
    export FAKE_WS_NAME=blog
    run wtsh 'wt feat-x && print -r -- "PWD=$PWD"'
    [ "$status" -eq 0 ]
    [[ $output == *"PWD=$HOME/wt/blog/feat-x"* ]]
    [ "$(git -C "$HOME/wt/blog/feat-x" branch --show-current)" = feat-x ]
    # Агент запущен внутри нового worktree.
    [ "$(cat "$T/agent.log")" = "$HOME/wt/blog/feat-x" ]
}

@test "missing config: wt names its path, wt -h still works" {
    rm "$XDG_CONFIG_HOME/agterm-kit/wt.conf"
    export FAKE_WS_NAME=api
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"нет конфига $XDG_CONFIG_HOME/agterm-kit/wt.conf"* ]]
    run wtsh 'wt -h'
    [ "$status" -eq 0 ]
    [[ $output == *"(не задан)"* ]]
}

@test "unknown key and line without = fail with line number" {
    write_config "root = ~/wt" "repo = ~/x"
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"wt.conf:2: неизвестный ключ «repo»"* ]]

    write_config "root ~/wt"
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"wt.conf:1: ожидается строка вида «ключ = значение»"* ]]
}

@test "config without repos is rejected" {
    write_config "root = ~/wt"
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"нужны ключи root и repos"* ]]
}

@test "WT_ROOT and WT_REPOS override config" {
    make_repo "$T/other" api
    export FAKE_WS_NAME=api WT_ROOT=$T/alt-root WT_REPOS="$T/nowhere:$T/other"
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [ -d "$T/alt-root/api/feat-x" ]
    # Worktree принадлежит репе из WT_REPOS, а не из конфига.
    [ "$(git -C "$T/alt-root/api/feat-x" rev-parse --git-common-dir)" = "$T/other/api/.git" ]
}

@test "same-named repo is taken from first repos dir" {
    make_repo "$T/personal" api
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [ "$(git -C "$HOME/wt/api/feat-x" rev-parse --git-common-dir)" = "$T/work/api/.git" ]
}

@test "workspace without matching repo fails" {
    export FAKE_WS_NAME=missing
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"воркспейс 'missing' не соответствует репе"* ]]
    [ ! -e "$HOME/wt/missing" ]
}

# --- создание worktree ----------------------------------------------------

@test "branch has no upstream, starts at fresh origin, local base fast-forwarded" {
    push_to_origin api fresh.txt
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    wt=$HOME/wt/api/feat-x
    [ -f "$wt/fresh.txt" ]
    run git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
    [ "$status" -ne 0 ]
    [ "$(git -C "$T/work/api" rev-parse main)" = "$(git -C "$T/work/api" rev-parse origin/main)" ]
    # Основной клон стоял на main, поэтому main перемотана вместе с его деревом.
    [ -f "$T/work/api/fresh.txt" ]
}

@test "main clone on another branch: base fast-forwarded without checkout" {
    git -C "$T/work/api" switch -q -c my-work
    echo wip > "$T/work/api/wip.txt"
    push_to_origin api fresh.txt
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [ -f "$HOME/wt/api/feat-x/fresh.txt" ]
    [ "$(git -C "$T/work/api" rev-parse main)" = "$(git -C "$T/work/api" rev-parse origin/main)" ]
    # Основной клон остался на своей ветке с незакоммиченной правкой.
    [ "$(git -C "$T/work/api" branch --show-current)" = my-work ]
    [ -f "$T/work/api/wip.txt" ] && [ ! -f "$T/work/api/fresh.txt" ]
}

@test "diverged local base: branch starts at origin/base with warning" {
    echo local > "$T/work/api/local.txt"
    git -C "$T/work/api" add local.txt
    git -C "$T/work/api" commit -qm local
    push_to_origin api remote.txt
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [[ $output == *"wt: беру origin/main"* ]]
    [ -f "$HOME/wt/api/feat-x/remote.txt" ]
    [ ! -f "$HOME/wt/api/feat-x/local.txt" ]
    # От origin/main git без --no-track прописал бы upstream=origin/main,
    # и git push из фичи пошёл бы прямо в main.
    run git -C "$HOME/wt/api/feat-x" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
    [ "$status" -ne 0 ]
}

@test "existing worktree: cd without recreating" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat-x' >/dev/null
    run wtsh 'wt feat-x && print -r -- "PWD=$PWD"'
    [ "$status" -eq 0 ]
    [[ $output == *"уже существует, перехожу"* ]]
    [[ $output == *"PWD=$HOME/wt/api/feat-x"* ]]
    [ ! -e "$T/agent.log" ]
}

@test "carries .venv, node_modules and settings.local.json" {
    mkdir -p "$T/work/api/.venv" "$T/work/api/node_modules" "$T/work/api/.claude"
    echo '{}' > "$T/work/api/.claude/settings.local.json"
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    wt=$HOME/wt/api/feat-x
    [ "$(readlink "$wt/.venv")" = "$T/work/api/.venv" ]
    [ "$(readlink "$wt/node_modules")" = "$T/work/api/node_modules" ]
    [ -f "$wt/.claude/settings.local.json" ] && [ ! -L "$wt/.claude/settings.local.json" ]
}

@test "renames current agterm session to suffix" {
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    grep -qx "session rename feat-x --target SESSION-1" "$FAKE_AGTERM_LOG"
}

@test "WT_NEW_SESSION=1 opens agent in a new session" {
    export FAKE_WS_NAME=api WT_NEW_SESSION=1
    run wtsh 'wt feat-x'
    [ "$status" -eq 0 ]
    grep -q "^session new --cwd $HOME/wt/api/feat-x --name feat-x --command zsh -lc" "$FAKE_AGTERM_LOG"
    [ ! -e "$T/agent.log" ]
}

@test "-a none runs no agent, unknown agent fails before git" {
    export FAKE_WS_NAME=api
    run wtsh 'wt feat-x -a none'
    [ "$status" -eq 0 ]
    [ ! -e "$T/agent.log" ]

    run wtsh 'wt -a vim feat-y'
    [ "$status" -eq 2 ]
    [[ $output == *"неизвестный агент 'vim'"* ]]
    [ ! -e "$HOME/wt/api/feat-y" ]
}

@test "wt refuses outside agterm" {
    unset AGTERM_ENABLED
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"не в agterm"* ]]
}

# --- wtl и wtrm -----------------------------------------------------------

@test "wtl lists worktrees from all repos dirs, not main clones" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat-a' >/dev/null
    export FAKE_WS_NAME=blog
    wtsh 'wt -a none feat-b' >/dev/null
    run wtsh 'wtl'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ ${lines[0]} == api*feat-a*"$HOME/wt/api/feat-a" ]]
    [[ ${lines[1]} == blog*feat-b*"$HOME/wt/blog/feat-b" ]]
}

@test "wtrm removes clean worktree, branch and empty repo dir" {
    export FAKE_WS_NAME=blog
    wtsh 'wt -a none feat-x' >/dev/null
    run wtsh 'wtrm blo feat-x'
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/wt/blog" ]
    run git -C "$T/personal/blog" show-ref --verify refs/heads/feat-x
    [ "$status" -ne 0 ]
}

@test "wtrm asks on uncommitted change and keeps everything on no" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat-x' >/dev/null
    echo dirty > "$HOME/wt/api/feat-x/dirty.txt"
    run zsh -f -c "source '$WT_ZSH'; print n | wtrm api feat-x"
    [ "$status" -eq 1 ]
    [[ $output == *"незакоммиченные правки"* ]]
    [[ $output == *"отменено"* ]]
    [ -f "$HOME/wt/api/feat-x/dirty.txt" ]
}

@test "wtrm with one arg takes repo from current worktree" {
    export FAKE_WS_NAME=blog
    wtsh 'wt -a none feat-x' >/dev/null
    run zsh -f -c "source '$WT_ZSH'; cd '$HOME/wt/blog/feat-x' && wtrm feat-x && print -r -- \"PWD=\$PWD\""
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/wt/blog/feat-x" ]
    # Стояли внутри удалённого каталога — wtrm уводит в основной клон.
    [[ $output == *"PWD=$T/personal/blog"* ]]
}
