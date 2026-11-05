#!/usr/bin/env bats
# Поведение wt / wtl / wtrm на настоящих git-репах с поддельным agtermctl.

load helpers

setup() {
    setup_env
    make_repo "$T/work" api
    make_repo "$T/personal" blog
    write_config \
        "# комментарий" \
        "repos = ~/../work   # хвостовой комментарий" \
        "" \
        "repos = $T/personal/"
    # ~/../work — это $T/work: проверяем раскрытие ~ в repos.
}

# --- конфиг ---------------------------------------------------------------

@test "wt finds repo in second repos dir and puts worktree next to it" {
    export FAKE_WS_NAME=blog
    run wtsh 'wt feat-x && print -r -- "PWD=$PWD"'
    [ "$status" -eq 0 ]
    [[ $output == *"PWD=$T/personal/worktrees/blog/feat-x"* ]]
    [ "$(git -C "$T/personal/worktrees/blog/feat-x" branch --show-current)" = feat-x ]
    # Агент запущен внутри нового worktree.
    [ "$(cat "$T/agent.log")" = "$T/personal/worktrees/blog/feat-x" ]
}

@test "missing config: wt names its path, wt -h still works" {
    rm "$XDG_CONFIG_HOME/agterm-kit/wt.conf"
    export FAKE_WS_NAME=api
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"нет конфига $XDG_CONFIG_HOME/agterm-kit/wt.conf"* ]]
    run wtsh 'wt -h'
    [ "$status" -eq 0 ]
    [[ $output == *"(не заданы)"* ]]
}

@test "unknown key and line without = fail with line number" {
    write_config "repos = ~/x" "repo = ~/x"
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"wt.conf:2: неизвестный ключ «repo»"* ]]

    write_config "repos ~/x"
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"wt.conf:1: ожидается строка вида «ключ = значение»"* ]]
}

@test "config without repos is rejected" {
    write_config "# только комментарий"
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"нужен ключ repos"* ]]
}

@test "WT_REPOS overrides config" {
    make_repo "$T/other" api
    export FAKE_WS_NAME=api WT_REPOS="$T/nowhere:$T/other"
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    # Worktree принадлежит репе из WT_REPOS, а не из конфига, и лежит рядом с ней.
    [ "$(git -C "$T/other/worktrees/api/feat-x" rev-parse --git-common-dir)" = "$T/other/api/.git" ]
    [ ! -e "$T/work/worktrees" ]
}

@test "legacy root key and WT_ROOT warn but do not move worktrees there" {
    write_config "root = ~/wt" "repos = $T/work"
    export FAKE_WS_NAME=api WT_ROOT=$T/alt-root
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [[ $output == *"wt.conf:1: ключ root устарел"* ]]
    [[ $output == *"WT_ROOT устарела"* ]]
    [ -d "$T/work/worktrees/api/feat-x" ]
    [ ! -e "$HOME/wt" ] && [ ! -e "$T/alt-root" ]
}

@test "same-named clones in different parents get separate worktrees dirs" {
    make_repo "$T/other" api
    run wtsh "cd '$T/work/api' && wt -a none feat-x"
    [ "$status" -eq 0 ]
    run wtsh "cd '$T/other/api' && wt -a none feat-x"
    [ "$status" -eq 0 ]
    # Общий root свёл бы обе в <root>/api/feat-x, и вторая только перешла бы в первую.
    [[ $output != *"уже существует"* ]]
    [ "$(git -C "$T/work/worktrees/api/feat-x" rev-parse --git-common-dir)" = "$T/work/api/.git" ]
    [ "$(git -C "$T/other/worktrees/api/feat-x" rev-parse --git-common-dir)" = "$T/other/api/.git" ]
}

@test "worktrees dir is not listed as a repo" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat-x' >/dev/null
    [ -d "$T/work/worktrees/api/feat-x" ]
    run wtsh '_wt_load_config && _wt_repos'
    [ "$status" -eq 0 ]
    [[ $output != *worktrees* ]]
}

@test "symlinked clone resolves to the real clone location" {
    make_repo "$T/elsewhere" warp
    ln -s "$T/elsewhere/warp" "$T/clone-link"
    write_config "repos = $T/clone-link"
    export FAKE_WS_NAME=clone-link
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    # Через воркспейс клон приходит путём из конфига, через cwd — путём от git.
    # Место одно и то же: рядом с настоящим клоном, и wt из cwd находит готовый worktree.
    [ -d "$T/elsewhere/worktrees/warp/feat-x" ]
    [ ! -e "$T/worktrees" ]
    run wtsh "cd '$T/clone-link' && wt -a none feat-x"
    [[ $output == *"уже существует, перехожу"* ]]
    run wtsh 'wtrm clone-link feat-x'
    [ "$status" -eq 0 ]
    [ ! -e "$T/elsewhere/worktrees" ]
}

@test "same-named repo is taken from first repos dir" {
    make_repo "$T/personal" api
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/work/worktrees/api/feat-x" rev-parse --git-common-dir)" = "$T/work/api/.git" ]
}

@test "workspace without matching repo fails" {
    export FAKE_WS_NAME=missing
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"воркспейс 'missing' не соответствует репе"* ]]
    [ ! -e "$T/work/worktrees" ] && [ ! -e "$T/personal/worktrees" ]
}

# --- создание worktree ----------------------------------------------------

@test "branch has no upstream, starts at fresh origin, local base fast-forwarded" {
    push_to_origin api fresh.txt
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    wt=$T/work/worktrees/api/feat-x
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
    [ -f "$T/work/worktrees/api/feat-x/fresh.txt" ]
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
    [ -f "$T/work/worktrees/api/feat-x/remote.txt" ]
    [ ! -f "$T/work/worktrees/api/feat-x/local.txt" ]
    # От origin/main git без --no-track прописал бы upstream=origin/main,
    # и git push из фичи пошёл бы прямо в main.
    run git -C "$T/work/worktrees/api/feat-x" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
    [ "$status" -ne 0 ]
}

@test "existing worktree: cd without recreating" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat-x' >/dev/null
    run wtsh 'wt feat-x && print -r -- "PWD=$PWD"'
    [ "$status" -eq 0 ]
    [[ $output == *"уже существует, перехожу"* ]]
    [[ $output == *"PWD=$T/work/worktrees/api/feat-x"* ]]
    [ ! -e "$T/agent.log" ]
}

@test "carries .venv, node_modules and settings.local.json" {
    mkdir -p "$T/work/api/.venv" "$T/work/api/node_modules" "$T/work/api/.claude"
    echo '{}' > "$T/work/api/.claude/settings.local.json"
    export FAKE_WS_NAME=api
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    wt=$T/work/worktrees/api/feat-x
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
    grep -q "^session new --cwd $T/work/worktrees/api/feat-x --name feat-x --command zsh -lc" "$FAKE_AGTERM_LOG"
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
    [ ! -e "$T/work/worktrees/api/feat-y" ]
}

@test "wt refuses outside git repo and outside agterm" {
    unset AGTERM_ENABLED
    run wtsh 'wt feat-x'
    [ "$status" -eq 1 ]
    [[ $output == *"не в git-репе, а вне agterm"* ]]
}

# --- репа из текущего каталога --------------------------------------------

@test "wt in a repo outside repos dirs uses it, not the workspace repo" {
    make_repo "$T/elsewhere" warp
    # Воркспейс называется иначе и указывает на другую репу: текущий каталог главнее.
    export FAKE_WS_NAME=api
    mkdir -p "$T/elsewhere/warp/sub"
    run wtsh "cd '$T/elsewhere/warp/sub' && wt -a none feat-x"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/elsewhere/worktrees/warp/feat-x" rev-parse --git-common-dir)" = "$T/elsewhere/warp/.git" ]
    [ ! -e "$T/work/worktrees/api" ]
}

@test "wt inside a worktree makes a sibling from the main clone" {
    export FAKE_WS_NAME=blog
    wtsh 'wt -a none feat-a' >/dev/null
    export FAKE_WS_NAME=api
    run wtsh "cd '$T/personal/worktrees/blog/feat-a' && wt -a none feat-b && print -r -- \"PWD=\$PWD\""
    [ "$status" -eq 0 ]
    [[ $output == *"PWD=$T/personal/worktrees/blog/feat-b"* ]]
    [ "$(git -C "$T/personal/worktrees/blog/feat-b" rev-parse --git-common-dir)" = "$T/personal/blog/.git" ]
}

@test "wt works in a repo outside agterm" {
    unset AGTERM_ENABLED AGTERM_WORKSPACE_ID
    run wtsh "cd '$T/work/api' && wt -a none feat-x"
    [ "$status" -eq 0 ]
    [ -d "$T/work/worktrees/api/feat-x" ]
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "repos entry may point at a repo itself" {
    make_repo "$T/elsewhere" warp
    write_config "repos = $T/work" "repos = $T/elsewhere/warp"
    export FAKE_WS_NAME=warp
    run wtsh 'wt -a none feat-x'
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/elsewhere/worktrees/warp/feat-x" rev-parse --git-common-dir)" = "$T/elsewhere/warp/.git" ]
    run wtsh 'wtl'
    [[ $output == *"warp"*"feat-x"* ]]
    run wtsh 'wtrm warp feat-x'
    [ "$status" -eq 0 ]
    [ ! -e "$T/elsewhere/worktrees" ]
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
    [[ ${lines[0]} == api*feat-a*"$T/work/worktrees/api/feat-a" ]]
    [[ ${lines[1]} == blog*feat-b*"$T/personal/worktrees/blog/feat-b" ]]
}

@test "wtrm removes clean worktree, branch and empty repo dir" {
    export FAKE_WS_NAME=blog
    wtsh 'wt -a none feat-x' >/dev/null
    run wtsh 'wtrm blo feat-x'
    [ "$status" -eq 0 ]
    [ ! -e "$T/personal/worktrees" ]
    run git -C "$T/personal/blog" show-ref --verify refs/heads/feat-x
    [ "$status" -ne 0 ]
}

@test "wtrm with a slash in suffix removes all emptied dirs up to worktrees" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat/x' >/dev/null
    [ -d "$T/work/worktrees/api/feat/x" ]
    run wtsh 'wtrm api feat/x'
    [ "$status" -eq 0 ]
    [ ! -e "$T/work/worktrees" ]
    # Подъём остановился на worktrees/ и не дошёл до каталога с клонами.
    [ -d "$T/work/api" ]
}

@test "wtrm asks on uncommitted change and keeps everything on no" {
    export FAKE_WS_NAME=api
    wtsh 'wt -a none feat-x' >/dev/null
    echo dirty > "$T/work/worktrees/api/feat-x/dirty.txt"
    run zsh -f -c "source '$WT_ZSH'; print n | wtrm api feat-x"
    [ "$status" -eq 1 ]
    [[ $output == *"незакоммиченные правки"* ]]
    [[ $output == *"отменено"* ]]
    [ -f "$T/work/worktrees/api/feat-x/dirty.txt" ]
}

@test "wtrm with one arg takes repo from current worktree" {
    export FAKE_WS_NAME=blog
    wtsh 'wt -a none feat-x' >/dev/null
    run zsh -f -c "source '$WT_ZSH'; cd '$T/personal/worktrees/blog/feat-x' && wtrm feat-x && print -r -- \"PWD=\$PWD\""
    [ "$status" -eq 0 ]
    [ ! -e "$T/personal/worktrees/blog/feat-x" ]
    # Стояли внутри удалённого каталога — wtrm уводит в основной клон.
    [[ $output == *"PWD=$T/personal/blog"* ]]
}
