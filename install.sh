#!/usr/bin/env bash
# Ставит обвязку agterm-kit: симлинк на wt.zsh и конфиг wt из образца.
# Повторный запуск безопасен: готовый симлинк и существующий конфиг не трогаются.
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
