#!/usr/bin/env python3
"""Темы из установленного Rex: sRGB-экспорт и команды agterm. Только stdlib."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time

FIELDS = {"background": "background", "foreground": "foreground", "cursor": "cursor-color",
          "cursorText": "cursor-text", "selectionBackground": "selection-background",
          "selectionForeground": "selection-foreground"}
DEFAULT_SOURCE = Path("/Applications/Rex Beta.app/Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json")


def convert(source):
    """Весь вход проверяется до первой записи; имена не становятся shell-кодом."""
    themes = json.loads(source.read_text())
    result = {}
    if not isinstance(themes, list) or not themes:
        raise ValueError("Ожидается непустой список тем Rex")
    for theme in themes:
        identifier, name = theme["id"], theme["name"]
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identifier) or identifier in result:
            raise ValueError("Некорректный или повторный id темы")
        if not isinstance(name, str) or not name or any(c in name for c in '\n\r"{}'):
            raise ValueError("Некорректное имя темы")
        colors = theme["source"]
        ansi = colors["ansi"]
        if not isinstance(ansi, list) or len(ansi) != 16:
            raise ValueError(f"{identifier}: нужны 16 цветов ANSI")
        values = [colors[key] for key in FIELDS] + ansi
        if any(not isinstance(v, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", v) for v in values):
            raise ValueError(f"{identifier}: цвет должен быть #RRGGBB")
        lines = [f"{target} = {colors[key]}" for key, target in FIELDS.items()]
        lines += [f"palette = {i}={value}" for i, value in enumerate(ansi)]
        result[identifier] = {"name": name, "config": "\n".join(lines) + "\n"}
    return result


def block(text, body):
    begin, end = "# agterm-kit:rex begin", "# agterm-kit:rex end"
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == begin]
    ends = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == end]
    if len(starts) != len(ends) or len(starts) > 1 or (starts and starts[0] >= ends[0]):
        raise ValueError("Повреждены маркеры Rex; файл оставлен без изменений")
    replacement = f"{begin}\n{body}{end}\n" if body else ""
    if starts:
        return "".join(lines[:starts[0]]) + replacement + "".join(lines[ends[0] + 1:])
    return text + ("\n" if text and not text.endswith("\n") else "") + replacement


def write(path, text):
    target = path.resolve()
    if target.exists() and target.read_text() == text:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
    if target.exists():
        shutil.copy2(target, target.with_name(target.name + f".bak.{time.time_ns()}"))
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix=target.name + ".")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


def read(path):
    return path.read_text() if path.exists() else ""


def reload(area):
    reply = json.loads(subprocess.run(["agtermctl", area, "reload", "--json"], check=True,
                                      capture_output=True, text=True, timeout=10).stdout)
    if reply.get("ok") is False or reply["result"].get("count", 0):
        raise ValueError(f"agterm не принял {area}: {reply}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "list", "apply", "reset"])
    parser.add_argument("theme", nargs="?")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--no-reload", action="store_true", help="Только записать конфиг, без обращения к agterm")
    args = parser.parse_args()
    root = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    agterm = root / "agterm"
    data = root / "agterm-kit/rex"
    catalog = data / "catalog.json"
    if args.action == "install":
        themes = convert(args.source)
        command = shlex.join([sys.executable, str(Path(__file__).resolve())])
        body = "".join(f'command "Rex: {t["name"]}" --error-hud {command} apply {shlex.quote(i)}\n'
                       for i, t in themes.items())
        body += f'command "Rex: вернуть тему agterm" --error-hud {command} reset\n'
        keymap = agterm / "keymap.conf"
        updated = block(read(keymap), body)
        # Проверка маркеров и всех тем завершена до записи файлов.
        for identifier, theme in themes.items():
            write(data / "themes" / identifier, theme["config"])
        write(catalog, json.dumps({i: t["name"] for i, t in themes.items()}, ensure_ascii=False, indent=2) + "\n")
        write(keymap, updated)
        if not args.no_reload:
            reload("keymap")
        print(f"Импортировано тем Rex: {len(themes)}")
    elif args.action == "list":
        for identifier, name in json.loads(catalog.read_text()).items():
            print(f"{identifier}\t{name}")
    else:
        config = agterm / "ghostty.conf"
        body = ""
        if args.action == "apply":
            themes = json.loads(catalog.read_text())
            if args.theme not in themes:
                raise ValueError("Неизвестная тема Rex; выполните list")
            body = (data / "themes" / args.theme).read_text()
        write(config, block(read(config), body))
        if not args.no_reload:
            reload("config")
        print(f"Тема Rex: {args.theme}" if body else "Возвращены цвета agterm")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"rex: {error}", file=sys.stderr)
        sys.exit(1)
