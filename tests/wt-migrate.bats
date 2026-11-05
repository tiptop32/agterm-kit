#!/usr/bin/env bats
# wt-migrate: перенос worktree из прежнего общего root к их репам.

load helpers

setup() {
    setup_env
    make_repo "$T/work" api
    make_repo "$T/personal" blog
    write_config "repos = $T/work" "repos = $T/personal"
    # Прежняя раскладка: <root>/<репа>/<постфикс>, в постфиксе бывает /.
    git -C "$T/work/api" worktree add -q -b feat-a "$T/old/api/feat-a"
    git -C "$T/work/api" worktree add -q -b feature/x "$T/old/api/feature/x"
    git -C "$T/personal/blog" worktree add -q -b feat-b "$T/old/blog/feat-b"
    mkdir -p "$T/work/api/.venv"
    ln -s "$T/work/api/.venv" "$T/old/api/feat-a/.venv"
    echo wip > "$T/old/api/feat-a/wip.txt"
}

worktree_paths() {
    git -C "$1" worktree list --porcelain | sed -n 's/^worktree //p'
}

@test "dry run prints the plan and changes nothing" {
    run wtsh "wt-migrate '$T/old'"
    [ "$status" -eq 0 ]
    [[ $output == *"$T/old/api/feat-a → $T/work/worktrees/api/feat-a"* ]]
    [[ $output == *"$T/old/api/feature/x → $T/work/worktrees/api/feature/x"* ]]
    [[ $output == *"$T/old/blog/feat-b → $T/personal/worktrees/blog/feat-b"* ]]
    [[ $output == *"перенесу 3, пропущу 0"* ]]
    [ -d "$T/old/api/feat-a" ]
    [ ! -e "$T/work/worktrees" ] && [ ! -e "$T/personal/worktrees" ]
}

@test "apply moves worktrees next to their repos and keeps their contents" {
    run wtsh "wt-migrate --apply '$T/old'"
    [ "$status" -eq 0 ]
    [[ $output == *"перенесено 3, не удалось 0, пропущено 0"* ]]
    run worktree_paths "$T/work/api"
    [[ $output == *"$T/work/worktrees/api/feat-a"* ]]
    [[ $output == *"$T/work/worktrees/api/feature/x"* ]]
    [[ $output != *"$T/old"* ]]
    [ "$(git -C "$T/personal/worktrees/blog/feat-b" branch --show-current)" = feat-b ]
    # Незакоммиченная правка и симлинк на основной клон переехали вместе с worktree.
    [ "$(cat "$T/work/worktrees/api/feat-a/wip.txt")" = wip ]
    [ -d "$T/work/worktrees/api/feat-a/.venv" ]
    # Опустевший старый root удалён целиком.
    [ ! -e "$T/old" ]
    # После переноса wtrm находит worktree на новом месте.
    run wtsh 'print y | wtrm api feat-a'
    [ "$status" -eq 0 ]
}

@test "worktrees outside the old root and unknown dirs stay in place" {
    git -C "$T/work/api" worktree add -q -b side "$T/elsewhere/side"
    mkdir -p "$T/old/ghost/thing"
    run wtsh "wt-migrate --apply '$T/old'"
    [ "$status" -eq 0 ]
    [[ $output == *"не worktree реп из repos, не трогаю: $T/old/ghost/thing"* ]]
    [ "$(git -C "$T/elsewhere/side" branch --show-current)" = side ]
    [ -d "$T/old/ghost/thing" ]
    [ ! -e "$T/old/api" ]
}

@test "unknown dir at repo level is reported as a whole" {
    mkdir -p "$T/old/notes/a" "$T/old/notes/b"
    run wtsh "wt-migrate '$T/old'"
    [[ $output == *"не трогаю: $T/old/notes"$'\n'* ]]
    [[ $output != *"$T/old/notes/a"* ]]
}

@test "worktrees already in the new layout are not moved again" {
    run wtsh "cd '$T/work/api' && wt -a none fresh"
    [ "$status" -eq 0 ]
    run wtsh "wt-migrate --apply '$T/work'"
    [ "$status" -eq 0 ]
    [[ $output == *"пропуск: $T/work/worktrees/api/fresh: уже на новом месте"* ]]
    [[ $output == *"перенесено 0"* ]]
    [ "$(git -C "$T/work/worktrees/api/fresh" branch --show-current)" = fresh ]
    [ ! -e "$T/work/worktrees/api/api" ]
}

@test "old root given one level too deep is skipped instead of losing the suffix" {
    run wtsh "wt-migrate --apply '$T/old/api'"
    [ "$status" -eq 0 ]
    [[ $output == *"пропуск: $T/old/api/feature/x: путь не по схеме"* ]]
    [[ $output == *"перенесено 0"* ]]
    [ -d "$T/old/api/feature/x" ] && [ ! -e "$T/work/worktrees" ]
}

@test "failed git move is reported, cleaned up, and the rest still moves" {
    mkdir -p "$T/work/worktrees"
    # Файл на месте каталога репы: mkdir и git worktree move для api не пройдут.
    echo blocker > "$T/work/worktrees/api"
    run wtsh "wt-migrate --apply '$T/old'"
    [ "$status" -eq 1 ]
    [[ $output == *"не перенесён $T/old/api/feat-a"* ]]
    [[ $output == *"перенесено 1, не удалось 2"* ]]
    [ -f "$T/old/api/feat-a/wip.txt" ]
    [ -d "$T/personal/worktrees/blog/feat-b" ]
    [ "$(cat "$T/work/worktrees/api")" = blocker ]
}

@test "symlinked old root: worktrees move, the link and its target stay" {
    ln -s "$T/old" "$T/old-link"
    run wtsh "wt-migrate --apply '$T/old-link'"
    [ "$status" -eq 0 ]
    [[ $output == *"перенесено 3"* ]]
    [ -L "$T/old-link" ] && [ -d "$T/old" ]
    [ -d "$T/work/worktrees/api/feat-a" ]
}

@test "occupied destination and locked worktree are skipped, the rest moves" {
    mkdir -p "$T/work/worktrees/api/feat-a"
    git -C "$T/work/api" worktree lock "$T/old/api/feature/x"
    run wtsh "wt-migrate --apply '$T/old'"
    [ "$status" -eq 0 ]
    [[ $output == *"пропуск: $T/old/api/feat-a: место занято"* ]]
    [[ $output == *"пропуск: $T/old/api/feature/x: заблокирован"* ]]
    [[ $output == *"перенесено 1, не удалось 0, пропущено 2"* ]]
    [ -f "$T/old/api/feat-a/wip.txt" ]
    [ -d "$T/personal/worktrees/blog/feat-b" ]
}

@test "apply refuses while an agterm session is open inside a worktree" {
    cat > "$T/bin/agtermctl" <<'EOF'
#!/bin/sh
case "$1 $2" in
'window list') echo '{"result":{"windows":[{"id":"WIN-1","open":true},{"id":"WIN-2","open":false}]}}' ;;
'tree --json') jq -n --arg cwd "$FAKE_CWD" '{result:{tree:{workspaces:[{sessions:[{cwd:"/elsewhere",splitCwd:$cwd}]}]}}}' ;;
esac
EOF
    export FAKE_CWD=$T/old/blog/feat-b/sub
    run wtsh "wt-migrate --apply '$T/old'"
    [ "$status" -eq 1 ]
    [[ $output == *"открыты сессии agterm"* ]]
    [[ $output == *"$T/old/blog/feat-b/sub"* ]]
    [ -d "$T/old/api/feat-a" ] && [ ! -e "$T/work/worktrees" ]
}

@test "apply refuses when agterm does not answer" {
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/agtermctl"
    run wtsh "wt-migrate --apply '$T/old'"
    [ "$status" -eq 1 ]
    [[ $output == *"agterm не ответил"* ]]
    [ -d "$T/old/api/feat-a" ]
}

@test "apply refuses while the shell stands inside a worktree" {
    run zsh -f -c "source '$WT_ZSH'; cd '$T/old/api/feat-a' && wt-migrate --apply '$T/old'"
    [ "$status" -eq 1 ]
    [[ $output == *"шелл стоит в $T/old/api/feat-a"* ]]
    [ -d "$T/old/api/feat-a" ]
}

@test "missing old root and bad arguments fail" {
    run wtsh "wt-migrate '$T/nowhere'"
    [ "$status" -eq 1 ]
    [[ $output == *"нет каталога $T/nowhere"* ]]
    run wtsh 'wt-migrate'
    [ "$status" -eq 2 ]
}
