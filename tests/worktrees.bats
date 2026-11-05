#!/usr/bin/env bats
# GUI-контракт на настоящих git-репах: создание и удаление, чужая сессия не меняется.
load helpers

setup() {
    setup_env
    make_repo "$T/projects with space" api
    write_config "repos = $T/projects with space"
    export AGT_SESSION_ID=SESSION-1 AGT_WINDOW_ID=WIN-1 AGTERM_GUI_LOG=$T/gui.jsonl
    cat > "$T/bin/agtermctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_AGTERM_LOG"
case "$1 $2" in
'session new')
    [ -z "$FAKE_OPEN_FAIL" ] || { echo 'socket unavailable' >&2; exit 1; }
    printf '{"ok":true,"result":{"id":"NEW-1"}}\n' ;;
'window list') printf '{"result":{"windows":[{"id":"WIN-1","open":true}]}}\n' ;;
'tree --json') jq -n --arg cwd "${FAKE_CWD:-/outside}" '{result:{tree:{workspaces:[{sessions:[{cwd:$cwd}]}]}}}' ;;
esac
EOF
    chmod +x "$T/bin/agtermctl"
    unset FAKE_CWD FAKE_OPEN_FAIL
}

request() {
    printf '%s' "$1" | python3 "$KIT_DIR/wt/gui.py" request
}

create_task() {
    request "$(jq -n --arg repo "$T/projects with space/api" --arg branch "${1:-feat-x}" '{action:"create",repo:$repo,branch:$branch}')"
}

@test "GUI creates a worktree and binds Claude Opus to a new session in the invoking window" {
    run create_task
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/projects with space/worktrees/api/feat-x" branch --show-current)" = feat-x ]
    grep -q 'session new .*--window WIN-1 .*claude --model opus' "$FAKE_AGTERM_LOG"
    ! grep -q 'session type\|session rename' "$FAKE_AGTERM_LOG"
    run git -C "$T/projects with space/worktrees/api/feat-x" rev-parse --abbrev-ref '@{upstream}'
    [ "$status" -ne 0 ]
    jq -e 'select(.action=="create" and .outcome=="success")' "$T/gui.jsonl"
}

@test "GUI rejects traversal shell fragments and unregistered existing directories" {
    for branch in '../escape' '-evil' 'bad name'; do
        run create_task "$branch"
        [ "$status" -eq 1 ]
    done
    mkdir -p "$T/projects with space/worktrees/api/feat-x"
    echo keep > "$T/projects with space/worktrees/api/feat-x/valuable.txt"
    run create_task
    [ "$status" -eq 1 ]
    [ "$(cat "$T/projects with space/worktrees/api/feat-x/valuable.txt")" = keep ]
    [ ! -e "$FAKE_AGTERM_LOG" ]
}

@test "GUI leaves a created worktree recoverable when agterm refuses the session" {
    export FAKE_OPEN_FAIL=1
    run create_task
    [ "$status" -eq 1 ]
    [[ $output == *"Worktree сохранён"* ]]
    [ -d "$T/projects with space/worktrees/api/feat-x" ]
    unset FAKE_OPEN_FAIL
    run create_task
    [ "$status" -eq 0 ]
}

delete_task() {
    request "$(jq -n --arg repo "$T/projects with space/api" --arg path "$T/projects with space/worktrees/api/feat-x" --arg confirm "${1:-feat-x}" '{action:"delete",repo:$repo,path:$path,confirmation:$confirm}')"
}

@test "GUI deletion requires exact confirmation and refuses dirty or open worktrees" {
    create_task >/dev/null
    run delete_task wrong
    [ "$status" -eq 1 ]
    echo valuable > "$T/projects with space/worktrees/api/feat-x/work.txt"
    run delete_task
    [ "$status" -eq 1 ]
    [ -f "$T/projects with space/worktrees/api/feat-x/work.txt" ]
    rm "$T/projects with space/worktrees/api/feat-x/work.txt"
    export FAKE_CWD="$T/projects with space/worktrees/api/feat-x/subdir"
    run delete_task
    [ "$status" -eq 1 ]
    [[ $output == *"открыта сессия"* ]]
    [ -d "$T/projects with space/worktrees/api/feat-x" ]
}

@test "GUI refuses local commits and removes a clean saved worktree while retaining its branch" {
    create_task >/dev/null
    echo work > "$T/projects with space/worktrees/api/feat-x/work.txt"
    git -C "$T/projects with space/worktrees/api/feat-x" add work.txt
    git -C "$T/projects with space/worktrees/api/feat-x" commit -qm work
    run delete_task
    [ "$status" -eq 1 ]
    [[ $output == *"не сохранён в origin"* ]]
    git -C "$T/projects with space/worktrees/api/feat-x" push -q origin feat-x
    run delete_task
    [ "$status" -eq 0 ]
    [ ! -d "$T/projects with space/worktrees/api/feat-x" ]
    git -C "$T/projects with space/api" show-ref --verify refs/heads/feat-x
}

@test "GUI creates worktrees for same-named repos from different dirs next to each clone" {
    make_repo "$T/second" api
    write_config "repos = $T/projects with space" "repos = $T/second"
    run create_task
    [ "$status" -eq 0 ]
    run request "$(jq -n --arg repo "$T/second/api" '{action:"create",repo:$repo,branch:"feat-x"}')"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/projects with space/worktrees/api/feat-x" rev-parse --git-common-dir)" = "$T/projects with space/api/.git" ]
    [ "$(git -C "$T/second/worktrees/api/feat-x" rev-parse --git-common-dir)" = "$T/second/api/.git" ]
}

@test "GUI refuses to delete a worktree outside the repo worktrees dir" {
    git -C "$T/projects with space/api" worktree add -q -b feat-y "$T/manual/feat-y"
    git -C "$T/manual/feat-y" push -q origin feat-y
    run request "$(jq -n --arg repo "$T/projects with space/api" --arg path "$T/manual/feat-y" '{action:"delete",repo:$repo,path:$path,confirmation:"feat-y"}')"
    [ "$status" -eq 1 ]
    [[ $output == *"вне каталога worktrees"* ]]
    [ -d "$T/manual/feat-y" ]
}

@test "GUI reports successful creation even when the trace destination is unavailable" {
    export AGTERM_GUI_LOG=$T/missing-parent/log.jsonl
    echo occupied > "$T/missing-parent"
    run create_task
    [ "$status" -eq 0 ]
    [[ $output == *"не записать журнал"* ]]
    [ -d "$T/projects with space/worktrees/api/feat-x" ]
    grep -q 'session new' "$FAKE_AGTERM_LOG"
}

@test "GUI refuses ignored unique data while allowing dependencies inherited by wt" {
    mkdir -p "$T/projects with space/api/.venv" "$T/projects with space/api/.claude"
    printf '.venv\n.claude/settings.local.json\nprivate.data\n' > "$T/projects with space/api/.gitignore"
    git -C "$T/projects with space/api" add .gitignore
    git -C "$T/projects with space/api" commit -qm ignore
    git -C "$T/projects with space/api" push -q origin main
    echo '{}' > "$T/projects with space/api/.claude/settings.local.json"
    create_task >/dev/null
    echo irreplaceable > "$T/projects with space/worktrees/api/feat-x/private.data"
    run delete_task
    [ "$status" -eq 1 ]
    [[ $output == *"игнорируемые данные"* ]]
    [ -f "$T/projects with space/worktrees/api/feat-x/private.data" ]
    rm "$T/projects with space/worktrees/api/feat-x/private.data"
    run delete_task
    [ "$status" -eq 0 ]
    [ -d "$T/projects with space/api/.venv" ]
    [ -f "$T/projects with space/api/.claude/settings.local.json" ]
}

@test "GUI renders untrusted project labels as JSON data without creating HTML elements" {
    run python3 - "$KIT_DIR" <<'PY'
import importlib.util,json,sys
from html.parser import HTMLParser
from pathlib import Path
spec=importlib.util.spec_from_file_location('gui',Path(sys.argv[1])/'wt/gui.py')
gui=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gui)
label='</script><img src=x onerror=alert(1)>'
class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.tags=[]; self.payload=''; self.in_data=False
    def handle_starttag(self,tag,attrs):
        self.tags.append(tag)
        self.in_data=tag=='script' and dict(attrs).get('id')=='worktree-data'
    def handle_endtag(self,tag):
        if tag=='script': self.in_data=False
    def handle_data(self,data):
        if self.in_data: self.payload+=data
page=Page()
page.feed(gui.render({'projects':[{'name':label,'path':'/repo','worktrees':[]}]}))
assert 'img' not in page.tags
assert json.loads(page.payload)['projects'][0]['name']==label
PY
    [ "$status" -eq 0 ]
}
