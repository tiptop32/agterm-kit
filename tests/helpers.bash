# Общие фикстуры: изолированный HOME, git без пользовательского конфига,
# поддельный agtermctl и настоящие репы с origin в каталоге теста.

KIT_DIR=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
WT_ZSH=$KIT_DIR/wt/wt.zsh

setup_env() {
    # pwd -P: на macOS $TMPDIR идёт через симлинк /var -> /private/var,
    # а git печатает пути без симлинков.
    T=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
    export T
    export HOME=$T/home
    export XDG_CONFIG_HOME=$HOME/.config
    mkdir -p "$HOME"

    # Из git-хука (pre-commit) приходят GIT_INDEX_FILE, GIT_DIR и прочие:
    # с ними git в тестах работал бы с индексом этого репозитория.
    local var
    for var in $(compgen -e | grep '^GIT_'); do
        unset "$var"
    done
    export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
    git config --global user.name test
    git config --global user.email test@example.com
    git config --global init.defaultBranch main
    git config --global advice.detachedHead false

    unset WT_ROOT WT_REPOS WT_CONFIG WT_AGENT WT_CLAUDE WT_NEW_SESSION WT_CLAUDE_CMD WT_CODEX_CMD ZDOTDIR CLAUDE_CONFIG_DIR CODEX_HOME

    # Поддельный agtermctl: пишет вызовы в лог и отдаёт дерево с одним воркспейсом.
    # Id в дереве в нижнем регистре, в окружении в верхнем: agterm сравнивает их без учёта регистра.
    mkdir -p "$T/bin"
    cat > "$T/bin/agtermctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_AGTERM_LOG"
if [ "$1 $2" = "tree --json" ]; then
    printf '{"result":{"tree":{"workspaces":[{"id":"ws-1","name":"%s"}]}}}\n' "$FAKE_WS_NAME"
fi
EOF
    chmod +x "$T/bin/agtermctl"
    export PATH=$T/bin:$PATH
    export FAKE_AGTERM_LOG=$T/agtermctl.log
    export AGTERM_ENABLED=1 AGTERM_WORKSPACE_ID=WS-1 AGTERM_SESSION_ID=SESSION-1

    # Агент вместо claude: запоминает каталог, в котором его запустили.
    export WT_CLAUDE_CMD="print -r -- \$PWD >> $T/agent.log"
}

# make_repo <каталог> <имя>: клон <каталог>/<имя> с origin в $T/origin/<имя>.git.
make_repo() {
    local dir=$1 name=$2 seed=$T/seed/$1/$2
    mkdir -p "$seed" "$dir" "$T/origin"
    git -C "$seed" init -q
    echo one > "$seed/README"
    git -C "$seed" add README
    git -C "$seed" commit -qm init
    rm -rf "$T/origin/$name.git"
    git clone -q --bare "$seed" "$T/origin/$name.git"
    git clone -q "$T/origin/$name.git" "$dir/$name"
}

# push_to_origin <имя> <файл>: новый коммит в origin мимо основного клона.
push_to_origin() {
    local name=$1 file=$2 tmp=$T/pusher-$1
    rm -rf "$tmp"
    git clone -q "$T/origin/$name.git" "$tmp"
    echo change > "$tmp/$file"
    git -C "$tmp" add "$file"
    git -C "$tmp" commit -qm "add $file"
    git -C "$tmp" push -q origin main
}

# setup_ask_env: окружение для agterm-ask, ask-hook.sh и agterm-ask-mcp поверх setup_env.
# Поддельный agtermctl для оверлея: open отдаёт pageID и сохраняет страницу в $T/page.html,
# result отдаёт исход из FAKE_OUTCOME (по умолчанию submitted) со значением FAKE_VALUE.
setup_ask_env() {
    unset AGTERM_SOCKET AGTERM_ASK_CONFIG AGTERM_ASK_AGENT AGTERM_ASK_PROGRESS
    unset FAKE_OPEN_FAIL FAKE_OUTCOME FAKE_VALUE
    export AGTERM_WINDOW_ID=WIN-1 AGTERM_ASK_POLL=0.05 AGTERM_ASK_LOG=$T/ask.log TMPDIR=$T/tmp
    mkdir -p "$TMPDIR"

    cat > "$T/bin/agtermctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_AGTERM_LOG"
case "$1 $2 $3" in
"session overlay open")
    if [ -n "$FAKE_OPEN_FAIL" ]; then echo "Error: overlay already open" >&2; exit 1; fi
    while [ $# -gt 0 ]; do
        [ "$1" = --html ] && cp "$2" "$T/page.html"
        shift
    done
    echo '{"result":{"pageID":"PAGE-1"}}'
    ;;
"session overlay result")
    jq -n --arg o "${FAKE_OUTCOME:-submitted}" --arg v "$FAKE_VALUE" \
        '{result: {pageOutcome: ({pageID: "PAGE-1", outcome: $o} + (if $o == "submitted" then {value: $v} else {} end))}}'
    ;;
"tree --json --window")
    echo '{"result":{"tree":{"htmlOverlays":[{"id":"PAGE-1","state":"loaded","file":"x"}]}}}'
    ;;
esac
EOF
    chmod +x "$T/bin/agtermctl"
}

# page_data: JSON-блок с вопросами со страницы, которую сохранил поддельный agtermctl.
page_data() {
    sed -n 's/.*<script type="application\/json" id="ask-data">\(.*\)<\/script>.*/\1/p' "$T/page.html"
}

write_config() {
    mkdir -p "$XDG_CONFIG_HOME/agterm-kit"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/agterm-kit/wt.conf"
}

# wtsh <команды zsh>: выполнить с загруженным wt.zsh в чистом zsh без rc-файлов.
# Стартуем из $HOME: он вне git, иначе wt взял бы репу из каталога, где запущен bats.
wtsh() {
    (cd "$HOME" && zsh -f -c "source '$WT_ZSH'; $1")
}
