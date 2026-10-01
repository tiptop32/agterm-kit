#!/usr/bin/env bash
# Ставит обвязку agterm-kit: симлинк на wt.zsh, конфиги из образцов
# и хук ask-hook.sh в настройках Claude Code.
# Повторный запуск безопасен: готовый симлинк, существующие конфиги и прописанный хук не трогаются.
set -euo pipefail

kit_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
link=$config_home/zsh/wt.zsh
target=$kit_dir/wt/wt.zsh
conf=$config_home/agterm-kit/wt.conf

mkdir -p "$(dirname "$link")" "$(dirname "$conf")"

if [[ -L $link && $(readlink "$link") == "$target" ]]; then
    echo "ok: $link уже указывает на agterm-kit"
else
    # Прежний файл не удаляем: в нём могли остаться локальные правки.
    if [[ -e $link || -L $link ]]; then
        backup=$link.bak.$(date +%Y%m%d%H%M%S)
        mv "$link" "$backup"
        echo "прежний $link сохранён в $backup"
    fi
    ln -s "$target" "$link"
    echo "симлинк: $link -> $target"
fi

if [[ -f $conf ]]; then
    echo "ok: конфиг $conf уже есть, не трогаю"
else
    cp "$kit_dir/wt/wt.conf.example" "$conf"
    echo "конфиг создан из образца: $conf. Пропишите в нём root и repos"
fi

rc=${ZDOTDIR:-$HOME}/.zshrc
if ! grep -qs 'wt\.zsh' "$rc"; then
    echo "добавьте в $rc строку: source $link"
fi

ask_conf=$config_home/agterm-kit/ask.conf
if [[ -f $ask_conf ]]; then
    echo "ok: конфиг $ask_conf уже есть, не трогаю"
else
    cp "$kit_dir/ask/ask.conf.example" "$ask_conf"
    echo "конфиг создан из образца: $ask_conf"
fi

# resolve <путь>: файл за цепочкой симлинков. settings.json бывает симлинком в репозиторий
# dotfiles: пишем в настоящий файл, а симлинк оставляем как есть.
resolve() {
    local path=$1 link
    while [[ -L $path ]]; do
        link=$(readlink "$path")
        if [[ $link == /* ]]; then path=$link; else path=$(dirname "$path")/$link; fi
    done
    printf '%s\n' "$path"
}

# commit_file <файл> <настоящий файл> <что> <временный файл>: заменить файл новым содержимым.
# Совпадает с прежним: ничего не трогаем. Иначе прежняя версия копируется в <файл>.bak.<время>,
# а новая, записанная во временный файл рядом, атомарно заменяет старую переименованием:
# прерванная установка не оставляет пустой или обрезанный файл.
commit_file() {
    local file=$1 target=$2 what=$3 tmp=$4 backup=
    if [[ -f $target ]] && cmp -s "$target" "$tmp"; then
        rm -f "$tmp"
        echo "ok: $what уже есть в $file"
        return 0
    fi
    if [[ -f $target ]]; then
        backup=$file.bak.$(date +%Y%m%d%H%M%S)
        cp "$target" "$backup"
        # Права как у прежнего файла: settings.json Claude Code бывает 600. Сначала GNU stat:
        # на Linux stat -f значит другое и не падает.
        chmod "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" "$tmp"
    fi
    mv "$tmp" "$target"
    echo "$what: записано в $file${backup:+, прежняя версия в $backup}"
}

# update_json <файл> <что> <jq-фильтр> [аргументы jq]: применить фильтр к JSON-объекту в файле.
# Равный по смыслу результат (другое форматирование) файл не меняет.
update_json() {
    local file=$1 what=$2 filter=$3 target tmp
    shift 3
    target=$(resolve "$file")
    mkdir -p "$(dirname "$target")"
    [[ -s $target ]] || echo '{}' > "$target"
    if ! jq -e 'type == "object"' "$target" >/dev/null 2>&1; then
        echo "ошибка: $file не JSON-объект, не записано: $what" >&2
        return 1
    fi
    tmp=$(mktemp "$target.XXXXXX")
    if ! jq "$@" "$filter" "$target" > "$tmp"; then
        rm -f "$tmp"
        echo "ошибка: не обновить $file" >&2
        return 1
    fi
    if jq -e -n --slurpfile a "$target" --slurpfile b "$tmp" '$a == $b' >/dev/null; then
        cp "$target" "$tmp"
    fi
    commit_file "$file" "$target" "$what" "$tmp"
}

# managed_block <файл> <что> <начало> <конец> <содержимое>: блок между строками-маркерами
# в текстовом файле. Блока нет: дописывается в конец. Есть: содержимое между маркерами
# заменяется, так обновления kit доходят до уже установленного конфига.
managed_block() {
    local file=$1 what=$2 begin=$3 end=$4 body=$5 target tmp
    target=$(resolve "$file")
    mkdir -p "$(dirname "$target")"
    # Маркеры либо отсутствуют оба, либо стоят по одному и по порядку. Иначе (блок правили
    # руками, конец потерян) замена съела бы хвост файла: останавливаемся, файл не трогаем.
    local nb ne
    nb=$(grep -csxF "$begin" "$target" || true)
    ne=$(grep -csxF "$end" "$target" || true)
    if [[ ${nb:-0}/${ne:-0} != 0/0 ]] && { [[ $nb/$ne != 1/1 ]] ||
        (($(grep -nxF "$begin" "$target" | cut -d: -f1) > $(grep -nxF "$end" "$target" | cut -d: -f1))); }; then
        echo "ошибка: в $file маркеры «$begin» и «$end» не образуют пару, не записано: $what" >&2
        return 1
    fi
    tmp=$(mktemp "$target.XXXXXX")
    if ((nb == 1)); then
        # Блок через ENVIRON, а не -v: awk -v раскрыл бы обратные слэши.
        BLOCK="$begin"$'\n'"$body"$'\n'"$end" BEGIN_MARK="$begin" END_MARK="$end" awk '
            $0 == ENVIRON["BEGIN_MARK"] { print ENVIRON["BLOCK"]; skip = 1; next }
            skip && $0 == ENVIRON["END_MARK"] { skip = 0; next }
            !skip { print }
        ' "$target" > "$tmp"
    else
        {
            [[ -f $target ]] && cat "$target"
            [[ -s $target ]] && echo
            printf '%s\n%s\n%s\n' "$begin" "$body" "$end"
        } > "$tmp"
    fi
    commit_file "$file" "$target" "$what" "$tmp"
}

# Claude Code: хук на AskUserQuestion. Таймаут час: пока хук ждёт, вопрос висит в оверлее,
# а по таймауту хук закрывает оверлей, и вопрос уходит в терминал.
# Запись с этой командой должна быть ровно одна и ровно такая. Иначе все записи с ней
# (другой matcher, другой таймаут, дубль) убираются и добавляется правильная.
# shellcheck disable=SC2016 # $cmd и $want раскрывает jq, а не shell
update_json "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "хук Claude Code на AskUserQuestion" '
    {matcher: "AskUserQuestion", hooks: [{type: "command", command: $cmd, timeout: 3600}]} as $want
    | if ([.hooks.PreToolUse[]?.hooks[]? | select(.command == $cmd)] | length) == 1
         and any(.hooks.PreToolUse[]?; . == $want)
      then .
      else .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select(.command != $cmd))
                                 | select(.hooks | length > 0)] + [$want])
      end
' --arg cmd "$kit_dir/ask/ask-hook.sh"

mcp=$kit_dir/ask/agterm-ask-mcp

# Codex: MCP-сервер в config.toml, если Codex установлен. TOML не разбираем, блоком
# управляют маркеры. Codex пускает к stdio-серверу только переменные из белого списка:
# без env_vars сервер не увидит AGTERM_* и решит, что он вне agterm.
codex_home=${CODEX_HOME:-$HOME/.codex}
if [[ -d $codex_home ]]; then
    if grep -qs '^\[mcp_servers\.agterm-ask\]' "$codex_home/config.toml" &&
        ! grep -qsxF '# agterm-kit:ask begin' "$codex_home/config.toml"; then
        echo "ok: MCP-сервер agterm-ask в $codex_home/config.toml прописан вручную, не трогаю"
    else
        managed_block "$codex_home/config.toml" "MCP-сервер agterm-ask для Codex" \
            '# agterm-kit:ask begin' '# agterm-kit:ask end' "$(cat <<EOF
[mcp_servers.agterm-ask]
command = $(jq -n --arg p "$mcp" '$p')
env_vars = ["AGTERM_ENABLED", "AGTERM_SESSION_ID", "AGTERM_WINDOW_ID", "AGTERM_WORKSPACE_ID", "AGTERM_SOCKET", "AGTERM_PANE", "AGTERM_PANE_ID"]
startup_timeout_sec = 20
tool_timeout_sec = 3600

[mcp_servers.agterm-ask.tools.ask_user]
approval_mode = "approve"
EOF
)"
    fi
fi

# OpenCode: MCP-сервер в opencode.json, если OpenCode установлен. Флаг enabled,
# выставленный вручную, сохраняется. opencode.jsonc с комментариями jq не разберёт, но OpenCode
# сливает opencode.json и opencode.jsonc из одного каталога (проверено на 1.18.31): запись
# ложится в opencode.json рядом, а .jsonc остаётся нетронутым.
opencode_dir=$config_home/opencode
if [[ -d $opencode_dir ]]; then
    if grep -qs '"agterm-ask"' "$opencode_dir/opencode.jsonc"; then
        echo "ok: MCP-сервер agterm-ask в $opencode_dir/opencode.jsonc прописан вручную, не трогаю"
    else
        # shellcheck disable=SC2016 # $cmd раскрывает jq
        update_json "$opencode_dir/opencode.json" "MCP-сервер agterm-ask для OpenCode" '
            if .mcp["agterm-ask"].command == [$cmd] and .mcp["agterm-ask"].type == "local" then .
            else .mcp["agterm-ask"] = ({type: "local", command: [$cmd]}
                + if (.mcp["agterm-ask"].enabled | type) == "boolean" then {enabled: .mcp["agterm-ask"].enabled} else {} end)
            end
        ' --arg cmd "$mcp"
    fi
fi

# Инструкция агенту в глобальном AGENTS.md. Описания инструмента Codex не хватает:
# без инструкции он видит ask_user, но спрашивает текстом в чате (evals/ask-agents.sh).
# shellcheck disable=SC2016 # обратные кавычки здесь markdown, а не подстановка
ask_rule='## Вопросы пользователю

Когда просишь пользователя выбрать между вариантами (подход, библиотека, имя, объём работ,
подтверждение рискованного шага), вызывай MCP-инструмент `ask_user` сервера `agterm-ask`,
а не перечисляй варианты в чате. Он показывает диалог в терминале agterm и возвращает ответ.
Если `ask_user` ответил, что диалог недоступен или закрыт, спроси в чате.'
for agents_md in "$codex_home/AGENTS.md" "$opencode_dir/AGENTS.md"; do
    [[ -d $(dirname "$agents_md") ]] || continue
    managed_block "$agents_md" "инструкция ask_user" \
        '<!-- agterm-kit:ask begin -->' '<!-- agterm-kit:ask end -->' "$ask_rule"
done
