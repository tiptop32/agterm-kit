#!/usr/bin/env zsh
# JSON-контракт GUI с существующим wt: конфиг и создание, без запуска агента в runner.
source "${0:A:h}/wt.zsh"

case ${1:-} in
    config)
        _wt_load_config || exit 1
        roots=$(printf '%s\0' "${_wt_repo_dirs[@]}" | jq -Rs 'split("\u0000")[:-1]')
        rows=$(_wt_repos)
        # Последний отсутствующий каталог не превращает полезный список в ошибку.
        printf '%s\n' "$rows" | jq -Rs --arg root "$_wt_root" --argjson roots "$roots" '
            {root: $root, roots: $roots, repos: [split("\n")[] | select(length > 0)
             | split("\t") | {name: .[0], path: .[1]}] | unique_by(.path)}'
        ;;
    create)
        (( $# == 3 )) || exit 2
        cd "$2" || exit 1
        # Не переименовываем сессию, из которой открыт GUI, и не запускаем агента в pipe.
        export AGTERM_ENABLED="" WT_NEW_SESSION=0
        wt -a none -- "$3" >&2 || exit 1
        jq -n --arg path "$PWD" '{path: $path}'
        ;;
    *) print -u2 'gui-bridge: ожидается config или create <репа> <ветка>'; exit 2 ;;
esac
