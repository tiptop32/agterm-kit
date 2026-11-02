#!/usr/bin/env bash
# Ставит расширение статуса agterm в пользовательский каталог omp.
set -euo pipefail

kit_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
extension_dir=$HOME/.omp/agent/extensions
mkdir -p "$extension_dir"

link_file() {
    local source=$1 link=$2
    if [[ -L $link && $(readlink "$link") == "$source" ]]; then
        echo "ok: $link уже указывает на agterm-kit"
        return 0
    fi
    if [[ -e $link || -L $link ]]; then
        echo "ошибка: $link уже существует, не трогаю" >&2
        return 1
    fi
    ln -s "$source" "$link"
    echo "симлинк: $link -> $source"
}

link_file "$kit_dir/agterm-status.ts" "$extension_dir/agterm-status.ts"
link_file "$kit_dir/agterm-status.sh" "$extension_dir/agterm-status.sh"

# Каталог ~/.omp/agent/extensions omp подхватывает сам, config.yml не нужен.
