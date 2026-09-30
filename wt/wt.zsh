#!/usr/bin/env zsh
# wt — git worktree + агент в текущей сессии agterm
#
#   wt <постфикс>          создать worktree, ветку и запустить Claude
#   wt -a codex <постфикс> то же, но запустить Codex
#   wtl                    список всех worktree по всем репам
#   wtrm <репа> <постфикс>  удалить worktree с проверками
#
# Пути берутся из конфига ~/.config/agterm-kit/wt.conf. Подробности: wt -h

# Какой агент запускать. WT_CLAUDE=0 оставлен для обратной совместимости
# и эквивалентен WT_AGENT=none, если агент не указан аргументом wt.
WT_AGENT="${WT_AGENT:-claude}"
WT_CLAUDE="${WT_CLAUDE:-1}"
# --continue подхватывает прошлую сессию в этом каталоге; для свежего
# worktree истории нет и claude падает — тогда стартуем с чистого листа.
WT_CLAUDE_CMD="${WT_CLAUDE_CMD:-claude --continue || claude}"
WT_CODEX_CMD="${WT_CODEX_CMD:-codex}"

_wt_config_path() {
    print -r -- "${WT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agterm-kit/wt.conf}"
}

# Раскрывает ~ и $HOME в начале пути. eval не используем: конфиг — данные, а не код.
_wt_expand() {
    local p=$1
    case $p in
        '~')        p=$HOME ;;
        '~/'*)      p=$HOME/${p#\~/} ;;
        '$HOME')    p=$HOME ;;
        '$HOME/'*)  p=$HOME/${p#\$HOME/} ;;
    esac
    # :a делает путь абсолютным и убирает . и .., симлинки не раскрывает.
    print -r -- "${p:a}"
}

# Читает конфиг в _wt_root (куда класть worktree) и _wt_repo_dirs (где искать репы).
# Конфиг читается при каждом вызове, поэтому правка файла действует без перезапуска шелла.
# WT_ROOT и WT_REPOS (через двоеточие, как PATH) перекрывают ключи конфига.
_wt_load_config() {
    setopt localoptions extendedglob
    typeset -g _wt_root=""
    typeset -ga _wt_repo_dirs
    _wt_repo_dirs=()

    local cfg line key value n=0 p
    cfg=$(_wt_config_path)

    if [[ -f $cfg ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            (( n++ ))
            [[ $line == [[:space:]]#(\#*|) ]] && continue
            if [[ $line != *=* ]]; then
                print -u2 "wt: $cfg:$n: ожидается строка вида «ключ = значение»"
                return 1
            fi
            key=${${line%%=*}//[[:space:]]/}
            value=${${line#*=}##[[:space:]]#}
            # Комментарий в хвосте строки начинается с пробела и #: «root = ~/wt  # заметка».
            value=${value%%[[:space:]]##\#*}
            value=${value%%[[:space:]]#}
            if [[ -z $value ]]; then
                print -u2 "wt: $cfg:$n: у ключа «$key» пустое значение"
                return 1
            fi
            case $key in
                root)  _wt_root=$(_wt_expand "$value") ;;
                repos) _wt_repo_dirs+=("$(_wt_expand "$value")") ;;
                *)
                    print -u2 "wt: $cfg:$n: неизвестный ключ «$key», допустимы root и repos"
                    return 1
                    ;;
            esac
        done < "$cfg"
    fi

    [[ -n $WT_ROOT ]] && _wt_root=$(_wt_expand "$WT_ROOT")
    if [[ -n $WT_REPOS ]]; then
        _wt_repo_dirs=()
        for p in "${(@s.:.)WT_REPOS}"; do
            [[ -n $p ]] && _wt_repo_dirs+=("$(_wt_expand "$p")")
        done
    fi

    if [[ -z $_wt_root || ${#_wt_repo_dirs} -eq 0 ]]; then
        if [[ -f $cfg ]]; then
            print -u2 "wt: в $cfg нужны ключи root и repos"
        else
            print -u2 "wt: нет конфига $cfg. Создайте его по образцу wt.conf.example из agterm-kit"
        fi
        return 1
    fi
}

# Цвета только когда вывод идёт в терминал, иначе экранирование мусорит в пайпах.
_wt_help() {
    local b="" d="" n=""
    if [[ -t 1 ]]; then
        b=$'\e[1m'; d=$'\e[2m'; n=$'\e[0m'
    fi

    # Справка должна открываться и без конфига: показываем, что удалось прочитать.
    local root="(не задан)" repos="(не заданы)"
    if _wt_load_config 2>/dev/null; then
        root=$_wt_root
        repos=${(j:, :)_wt_repo_dirs}
    fi

    cat <<EOF
${b}wt${n} — git worktree для реп из каталогов конфига

${b}КОМАНДЫ${n}
  ${b}wt${n} [-a <агент>] <постфикс>
                            worktree + ветка + агент в текущей вкладке
  ${b}wtl${n}                      список всех worktree по всем репам
  ${b}wtrm${n} <репа> <постфикс>   удалить worktree, ветку и каталог
  ${b}wtrm${n} <постфикс>          то же, репа из текущего каталога

${b}КОНФИГ${n} $(_wt_config_path)
  root  = ~/wt              ${d}# куда класть worktree: <root>/<репа>/<постфикс>${n}
  repos = ~/git             ${d}# где искать репы; ключ можно повторять${n}
  repos = ~/work/git

  Сейчас: root ${root}
          repos ${repos}

${b}КАК РАБОТАЕТ wt${n}
  Репа берётся из ${b}имени воркспейса agterm${n} ${d}(воркспейс qa-tools → репа qa-tools)${n},
  поэтому аргумент — только постфикс (имя ветки). Каталоги repos просматриваются
  по порядку, при одинаковых именах выигрывает первый. Вне agterm или если репы
  с таким именем нет ни в одном каталоге — ошибка.

  Агент запускается в ${b}текущей${n} вкладке; WT_NEW_SESSION=1 — в отдельной.
  По умолчанию это claude. Выбрать codex: ${b}--agent codex${n} или ${b}-a codex${n}.
  Флаг можно поставить как до, так и после постфикса. ${b}--agent none${n} оставит только шелл.

  Сначала fetch и перемотка ${b}локальной <базы>${n} на origin/<базу>, затем ветка
  создаётся от неё. База берётся из origin/HEAD ${d}(main / master / static-dev —${n}
  ${d}у разных реп по-разному)${n}. Если локальная база разошлась с origin или её дерево
  грязное — перемотки не будет, ветка пойдёт от origin/<базы> с предупреждением.

  Если основной клон стоит на другой ветке, его рабочее дерево не трогается: база
  перематывается без checkout. Если на самой базе, она перематывается там же через
  ${b}merge --ff-only${n}. Незавершённую работу wt не коммитит ни в одном случае.

  Upstream у новой ветки ${b}не ставится${n} (--no-track): иначе git считал бы её
  продолжением <базы> и первый же ${b}git push${n} звал запушить фичу прямо туда.

  В новый worktree переносятся: симлинки .venv и node_modules на основной клон
  и копия .claude/settings.local.json.

${b}ПЕРЕМЕННЫЕ${n}
  ${b}WT_CONFIG${n}=<файл>        другой путь к конфигу
  ${b}WT_ROOT${n}=<путь>          перекрывает root из конфига
  ${b}WT_REPOS${n}=<путь:путь>    перекрывает repos из конфига ${d}(через двоеточие)${n}
  ${b}WT_AGENT${n}=<агент>        агент по умолчанию: claude, codex или none
  ${b}WT_CLAUDE_CMD${n}=<команда> команда запуска Claude ${d}(claude --continue || claude)${n}
  ${b}WT_CODEX_CMD${n}=<команда>  команда запуска Codex ${d}(codex)${n}
  ${b}WT_CLAUDE${n}=0             не запускать агента ${d}(устаревший вариант WT_AGENT=none)${n}
  ${b}WT_NEW_SESSION${n}=1        агент в ОТДЕЛЬНОЙ вкладке agterm ${d}(по умолчанию — в текущей)${n}

${b}ПРИМЕРЫ${n}
  ${d}# в воркспейсе qa-tools: worktree с веткой fix-login, сразу с claude${n}
  wt fix-login

  ${d}# тот же сценарий, но запустить Codex${n}
  wt --agent codex fix-login

  ${d}# без агента, просто шелл${n}
  wt --agent none quick-look

  ${d}# агент в отдельной вкладке agterm${n}
  WT_NEW_SESSION=1 wt experiment

  ${d}# посмотреть всё и удалить ненужное${n}
  wtl
  wtrm qa-tools fix-login

${b}УДАЛЕНИЕ${n}
  wtrm проверяет незакоммиченные правки и незапушенные коммиты, показывает их
  и спрашивает подтверждение. Затем удаляет worktree, ветку и пустой каталог репы.
EOF
}

# Все репы из каталогов repos, по строке «имя<TAB>путь», в порядке конфига.
_wt_repos() {
    local dir d
    for dir in $_wt_repo_dirs; do
        for d in "$dir"/*(/N); do
            [[ -d $d/.git ]] && print -r -- "${d:t}"$'\t'"$d"
        done
    done
}

# Путь репы по точному имени: первый каталог из repos, где она есть.
_wt_repo_path() {
    local dir
    for dir in $_wt_repo_dirs; do
        [[ -d $dir/$1/.git ]] && { print -r -- "$dir/$1"; return 0 }
    done
    return 1
}

# Базовая ветка репы: origin/HEAD, с фолбэком на первую существующую из main/master/static-dev.
# Хардкодить main нельзя — у части реп это master или static-dev.
_wt_base() {
    local repo=$1 base
    base=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
    if [[ -n $base ]]; then
        print -r -- "${base#origin/}"
        return 0
    fi
    local b
    for b in main master static-dev develop; do
        if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
            print -r -- "$b"
            return 0
        fi
    done
    return 1
}

# Путь worktree, в котором ветка сейчас в checkout (пусто — ветка свободна).
_wt_branch_worktree() {
    local src=$1 branch=$2
    git -C "$src" worktree list --porcelain 2>/dev/null | awk -v br="refs/heads/$branch" '
        /^worktree / { path = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == br) { print path; exit } }
    '
}

# Подтягиваем локальную <base> к origin/<base>, чтобы ветку можно было создать от неё.
# 0 — локальная base совпала с origin/base, 2 — не вышло (звать от origin/base), 1 — фатально.
_wt_sync_base() {
    local src=$1 base=$2

    git -C "$src" fetch --quiet origin "$base" || {
        print -u2 "wt: fetch origin $base не удался"
        return 1
    }

    # Локальной ветки ещё нет — просто заводим её на origin/<base>.
    if ! git -C "$src" show-ref --verify --quiet "refs/heads/$base"; then
        git -C "$src" branch --quiet --no-track "$base" "origin/$base" || return 2
        return 0
    fi

    [[ $(git -C "$src" rev-parse "$base") == $(git -C "$src" rev-parse "origin/$base") ]] && return 0

    # Ветка занята каким-то worktree — обновить её можно только изнутри него.
    local holder
    holder=$(_wt_branch_worktree "$src" "$base")
    if [[ -n $holder ]]; then
        git -C "$holder" merge --ff-only --quiet "origin/$base" 2>/dev/null && return 0
        print -u2 "wt: локальная $base в $holder не перематывается (расхождение или грязное дерево)"
        return 2
    fi

    # Ветка свободна — перематываем без checkout. fetch из самой репы делает ту же
    # проверку на fast-forward, что и обычный pull, но не трогает рабочее дерево.
    # Фигурные скобки обязательны: "$base:refs/..." zsh читает как модификатор :r.
    git -C "$src" fetch --quiet . "refs/remotes/origin/${base}:refs/heads/${base}" 2>/dev/null && return 0
    print -u2 "wt: локальная $base разошлась с origin/$base"
    return 2
}

# Путь репы по имени или его части. Несколько совпадений — выбор через fzf.
_wt_resolve() {
    local query=$1 line name i
    local -a names paths
    for line in "${(@f)$(_wt_repos)}"; do
        [[ -n $line ]] || continue
        name=${line%%$'\t'*}
        [[ $name == *"$query"* ]] || continue
        # Одноимённая репа из следующего каталога не видна: первый каталог выигрывает.
        (( ${names[(Ie)$name]} )) && continue
        names+=("$name")
        paths+=("${line#*$'\t'}")
    done

    (( ${#names} == 0 )) && return 1
    (( ${#names} == 1 )) && { print -r -- "${paths[1]}"; return 0; }

    # Точное совпадение выигрывает у частичного
    i=${names[(Ie)$query]}
    (( i )) && { print -r -- "${paths[i]}"; return 0; }

    if (( $+commands[fzf] )); then
        local picked
        picked=$(print -l -- $names | fzf --height 40% --reverse --prompt="репа> ")
        i=${names[(Ie)$picked]}
        (( i )) && { print -r -- "${paths[i]}"; return 0; }
        return 1
    fi

    print -u2 "wt: неоднозначно — ${(j:, :)names}"
    return 1
}

# Путь репы из текущего воркспейса agterm. Воркспейсы названы по репам (qa-tools, ...),
# поэтому первый аргумент не нужен. Без agterm или если репы с именем воркспейса нет
# ни в одном каталоге repos — ошибка (осознанно, без фолбэка по git-каталогу).
_wt_workspace_repo() {
    [[ -n $AGTERM_ENABLED && -n $AGTERM_WORKSPACE_ID ]] || {
        print -u2 "wt: не в agterm — репу беру из имени воркспейса, иначе никак"
        return 1
    }
    (( $+commands[agtermctl] )) || { print -u2 "wt: agtermctl не найден"; return 1 }
    (( $+commands[jq] ))        || { print -u2 "wt: нужен jq для чтения имени воркспейса"; return 1 }

    local name
    name=$(agtermctl tree --json 2>/dev/null \
        | jq -r --arg wid "$AGTERM_WORKSPACE_ID" \
            '.result.tree.workspaces[] | select((.id|ascii_downcase)==($wid|ascii_downcase)) | .name')
    [[ -n $name && $name != null ]] || {
        print -u2 "wt: не удалось получить имя воркспейса agterm"
        return 1
    }

    _wt_repo_path "$name" || {
        print -u2 "wt: воркспейс '$name' не соответствует репе ни в одном из каталогов: ${(j:, :)_wt_repo_dirs}"
        return 1
    }
}

wt() {
    [[ $1 == -h || $1 == --help || $1 == help ]] && { _wt_help; return 0 }

    local agent="$WT_AGENT" suffix=""
    [[ $WT_CLAUDE == 0 ]] && agent=none

    while (( $# > 0 )); do
        case $1 in
            -a|--agent)
                (( $# >= 2 )) || {
                    print -u2 "wt: после $1 укажите агента: claude, codex или none"
                    return 2
                }
                agent=$2
                shift 2
                ;;
            --agent=*)
                agent=${1#--agent=}
                shift
                ;;
            --)
                shift
                if (( $# != 1 )) || [[ -n $suffix ]]; then
                    print -u2 "usage: wt [-a claude|codex|none] <постфикс>"
                    return 2
                fi
                suffix=$1
                shift
                ;;
            -*)
                print -u2 "wt: неизвестный аргумент: $1"
                print -u2 "usage: wt [-a claude|codex|none] <постфикс>"
                return 2
                ;;
            *)
                if [[ -n $suffix ]]; then
                    print -u2 "wt: лишний аргумент: $1"
                    print -u2 "usage: wt [-a claude|codex|none] <постфикс>"
                    return 2
                fi
                suffix=$1
                shift
                ;;
        esac
    done

    if [[ -z $suffix ]]; then
        print -u2 "usage: wt [-a claude|codex|none] <постфикс>   (репа — из воркспейса agterm; wt -h — подробнее)"
        return 2
    fi

    local agent_cmd=""
    case $agent in
        claude) agent_cmd=$WT_CLAUDE_CMD ;;
        codex)  agent_cmd=$WT_CODEX_CMD ;;
        none)   ;;
        *)
            print -u2 "wt: неизвестный агент '$agent' (доступны: claude, codex, none)"
            return 2
            ;;
    esac

    _wt_load_config || return 1

    # Репа определяется по имени воркспейса agterm, а не аргументом.
    local src
    src=$(_wt_workspace_repo) || return 1

    local repo=${src:t}
    local dest="$_wt_root/$repo/$suffix"

    if [[ -e $dest ]]; then
        print "wt: $dest уже существует, перехожу"
        cd "$dest"
        return 0
    fi

    local base
    base=$(_wt_base "$src") || { print -u2 "wt: не определить базовую ветку для $repo"; return 1 }

    print "wt: $repo — обновляю $base"
    local start="$base"
    _wt_sync_base "$src" "$base"
    case $? in
        0) ;;
        2) start="origin/$base"; print -u2 "wt: беру $start" ;;
        *) return 1 ;;
    esac

    # Без upstream `git push` требует явный --set-upstream; autoSetupRemote делает это
    # сам и всегда в одноимённую ветку origin. Глобальную настройку не трогаем.
    git -C "$src" config --get push.autoSetupRemote >/dev/null 2>&1 \
        || git -C "$src" config --local push.autoSetupRemote true

    # --no-track обязателен: от origin/<base> git иначе пропишет upstream=origin/<base>,
    # и потом `git push` предлагает запушить фичу прямо в <base>.
    mkdir -p "${dest:h}"
    git -C "$src" worktree add --quiet --no-track -b "$suffix" "$dest" "$start" || return 1

    # Локальные файлы вне git
    local link
    for link in .venv node_modules; do
        [[ -e "$src/$link" && ! -e "$dest/$link" ]] && ln -s "$src/$link" "$dest/$link"
    done
    if [[ -f "$src/.claude/settings.local.json" ]]; then
        mkdir -p "$dest/.claude"
        cp "$src/.claude/settings.local.json" "$dest/.claude/settings.local.json"
    fi

    cd "$dest"

    # Прежнее поведение: агент в ОТДЕЛЬНОЙ вкладке agterm. Включается WT_NEW_SESSION=1.
    if [[ $WT_NEW_SESSION == 1 && -n $AGTERM_ENABLED ]] && (( $+commands[agtermctl] )); then
        if [[ $agent != none ]]; then
            # --command идёт argv-style мимо шелла и с GUI-шным PATH (без /opt/homebrew/bin),
            # поэтому оборачиваем в login-shell. Хвост `exec zsh -l` нужен, чтобы сессия
            # пережила выход из агента: иначе agterm закрывает её вместе с процессом.
            agtermctl session new --cwd "$dest" --name "$suffix" \
                --command "zsh -lc '${agent_cmd}; exec zsh -l'" >/dev/null
        else
            agtermctl session new --cwd "$dest" --name "$suffix" >/dev/null
        fi
        print "wt: $repo/$suffix готов (от $start)"
        return 0
    fi

    # По умолчанию агент запускается в ТЕКУЩЕЙ вкладке (где вызван wt): переименовываем
    # её под worktree, а сам агент стартуем ниже прямо в этом шелле.
    if [[ -n $AGTERM_ENABLED ]] && (( $+commands[agtermctl] )); then
        agtermctl session rename "$suffix" --target "${AGTERM_SESSION_ID:-active}" >/dev/null 2>&1
    fi

    print "wt: $repo/$suffix готов (от $start)"

    # Агент занимает текущую вкладку; по выходу из него мы вернёмся в prompt внутри
    # worktree (шелл не завершается, exec не нужен). none — только шелл, без агента.
    if [[ $agent != none ]]; then
        eval "$agent_cmd"
    fi
}

wtl() {
    [[ $1 == -h || $1 == --help ]] && { _wt_help; return 0 }
    _wt_load_config || return 1

    local line repo d
    for line in "${(@f)$(_wt_repos)}"; do
        [[ -n $line ]] || continue
        repo=${line%%$'\t'*}
        d=${line#*$'\t'}
        # git печатает путь основного клона без симлинков, поэтому сравниваем с ${d:A}.
        git -C "$d" worktree list --porcelain 2>/dev/null | awk -v repo="$repo" -v main="${d:A}" '
            /^worktree /  { path = substr($0, 10) }
            /^branch /    { br = substr($0, 8); sub("refs/heads/", "", br)
                            if (path != main) printf "%-22s %-24s %s\n", repo, br, path }
            /^detached/   { if (path != main) printf "%-22s %-24s %s\n", repo, "(detached)", path }
        '
    done
}

wtrm() {
    [[ $1 == -h || $1 == --help ]] && { _wt_help; return 0 }

    if (( $# < 1 || $# > 2 )); then
        print -u2 "usage: wtrm [<репа>] <постфикс>   (wtrm -h — подробнее)"
        return 2
    fi

    _wt_load_config || return 1

    local src suffix
    if (( $# == 2 )); then
        src=$(_wt_resolve "$1") || { print -u2 "wtrm: репа не найдена: $1"; return 1 }
        suffix=$2
    else
        # Из worktree common-dir указывает на .git основного клона, его родитель и есть репа.
        src=${$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null):h}
        [[ -n $src && $src != . ]] || { print -u2 "wtrm: не в git-репозитории — укажите репу явно: wtrm <репа> <постфикс>"; return 1 }
        suffix=$1
    fi

    local repo=${src:t}
    local dest="$_wt_root/$repo/$suffix"
    [[ -d $dest ]] || { print -u2 "wtrm: нет такого worktree: $dest"; return 1 }

    # Не удаляем молча: сначала показываем, что будет потеряно.
    local changes unpushed
    changes=$(git -C "$dest" status --porcelain 2>/dev/null)
    unpushed=$(git -C "$dest" log --oneline "@{upstream}.." 2>/dev/null \
               || git -C "$dest" log --oneline "origin/$(_wt_base "$src")".. 2>/dev/null)

    if [[ -n $changes || -n $unpushed ]]; then
        print "wtrm: в $repo/$suffix есть несохранённая работа:"
        [[ -n $changes  ]] && { print "  незакоммиченные правки:"; print -r -- "$changes" | sed 's/^/    /' }
        [[ -n $unpushed ]] && { print "  незапушенные коммиты:";   print -r -- "$unpushed" | sed 's/^/    /' }
        print -n "Всё равно удалить? [y/N] "
        local reply; read -r reply
        [[ $reply == [yY] ]] || { print "отменено"; return 1 }
    fi

    # Уходим из каталога, если стоим внутри него
    [[ $PWD == $dest* || $PWD:A == $dest:A* ]] && cd "$src"

    git -C "$src" worktree remove --force "$dest" || return 1
    git -C "$src" branch -D "$suffix" >/dev/null 2>&1
    rmdir "${dest:h}" 2>/dev/null
    print "wtrm: $repo/$suffix удалён"
}

# Для wt дополняем только выбор агента: имя ветки остаётся свободным.
_wt_complete() {
    _arguments \
        '(-a --agent)'{-a,--agent}'[агент в новом worktree]:агент:(claude codex none)' \
        '1:постфикс ветки'
}

# wtrm: первый аргумент — репа (каталог в root), второй — постфикс worktree.
_wtrm_complete() {
    _wt_load_config 2>/dev/null || return 1
    if (( CURRENT == 2 )); then
        local repos=("$_wt_root"/*(/N:t))
        compadd -a repos
    elif (( CURRENT == 3 )); then
        local wts=("$_wt_root/${words[2]}"/*(/N:t))
        compadd -a wts
    fi
}
(( $+functions[compdef] )) && {
    compdef _wt_complete wt
    compdef _wtrm_complete wtrm
}
