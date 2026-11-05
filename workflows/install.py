#!/usr/bin/env python3
"""Установка закреплённых cookbook-рецептов и действий agterm, без внешних библиотек."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
KIT = HERE.parent
LOCK = json.loads((HERE / "recipes.lock.json").read_text())


def managed(text: str, name: str, body: str) -> str:
    begin, end = f"# agterm-kit:{name} begin", f"# agterm-kit:{name} end"
    lines = text.splitlines()
    if lines.count(begin) != lines.count(end) or lines.count(begin) > 1:
        raise ValueError(f"Повреждены маркеры {name}; файл оставлен без изменений")
    if begin in lines:
        first, last = lines.index(begin), lines.index(end)
        if first >= last:
            raise ValueError(f"Перепутаны маркеры {name}")
        lines[first:last + 1] = [begin, *body.splitlines(), end]
        return "\n".join(lines) + "\n"
    return text.rstrip() + ("\n\n" if text.strip() else "") + begin + "\n" + body + "\n" + end + "\n"


def write(path: Path, text: str) -> None:
    """Сохраняет симлинк, права и старое содержимое, заменяет файл атомарно."""
    target = path.resolve()
    if target.exists() and target.read_text() == text:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
    if target.exists():
        backup = path.with_name(path.name + ".bak." + str(time.time_ns()))
        shutil.copy2(target, backup)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=target.name + ".")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    finally:
        Path(tmp).unlink(missing_ok=True)


def cache_root() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "agterm-kit/cookbook" / LOCK["commit"]


def fetch(source: Path | None, destination: Path) -> None:
    """Хеш проверяется до записи; изменённый кеш не исполняется."""
    for relative, digest in LOCK["files"].items():
        dest = destination / relative
        if dest.is_file():
            data = dest.read_bytes()
        elif source:
            data = (source / relative).read_bytes()
        else:
            url = f"https://raw.githubusercontent.com/{LOCK['repository']}/{LOCK['commit']}/{relative}"
            data = subprocess.run(["curl", "-fsSL", "--max-time", "60", url], check=True, capture_output=True).stdout
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"SHA-256 не совпал: {relative}. Установка остановлена")
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            if dest.suffix in (".sh", ".py"):
                dest.chmod(0o700)


def keymap_body() -> str:
    runner = shlex.quote(str(HERE / "run.py"))
    python = shlex.quote(shutil.which("python3") or "python3")
    commands = [
        ("Проект: открыть с Claude", "", "project"),
        ("Задачи и worktree", "ctrl+shift+w", "worktrees"),
        ("Недавние агенты", "", "recent"),
        ("Flagged dashboard", "", "dashboard"),
        ("Claude Resume", "", "resume"),
        ("Выбрать каталог", "", "directory"),
        ("Новый компаньон", "", "companion"),
        ("Доска стадий", "ctrl+shift+k", "board"),
    ]
    return "\n".join(f'command "{name}" {chord} --error-hud {python} {runner} {action}' for name, chord, action in commands)


def migrate_keymap(text: str) -> str:
    # Два прежних cookbook-действия уже были установлены вручную. Сохраняем их клавиши,
    # меняем только узнаваемый исполняемый файл; произвольные одноимённые команды не трогаем.
    old = {"claude-pick-conversation.py": "resume", "agt-flagged-dashboard.sh": "dashboard"}
    # Сначала проверяем маркеры. Старое управляемое тело будет сформировано заново.
    checked = managed(text, "gui", "")
    before, after = checked.split("# agterm-kit:gui begin", 1)
    _, after = after.split("# agterm-kit:gui end", 1)
    outside = before.rstrip() + ("\n" + after.lstrip() if after.strip() else "")
    lines, replaced = [], set()
    for line in outside.splitlines():
        match = next((action for filename, action in old.items() if line.lstrip().startswith('command "') and filename in line), None)
        if str(HERE / "run.py") in line and line.rsplit(" ", 1)[-1] in old.values():
            replaced.add(line.rsplit(" ", 1)[-1])
        if match:
            parts = shlex.split(line)
            chord = parts[2] if len(parts) > 3 and "+" in parts[2] else ""
            title = parts[1]
            lines.append(f'command "{title}" {chord} --error-hud {shlex.quote(shutil.which("python3") or "python3")} {shlex.quote(str(HERE / "run.py"))} {match}')
            replaced.add(match)
        else:
            lines.append(line)
    body = "\n".join(line for line in keymap_body().splitlines() if line.rsplit(" ", 1)[-1] not in replaced)
    return managed("\n".join(lines) + ("\n" if lines else ""), "gui", body)


def hook_settings(original: dict) -> dict:
    hooks = original.setdefault("hooks", {})
    python = shlex.quote(shutil.which("python3") or "python3")
    runner = f"{python} {shlex.quote(str(HERE / 'run.py'))}"
    # `|| true`: если kit переехал и скрипта нет, python завершится с кодом 2, а код 2
    # в PreToolUse запретил бы агенту каждый вызов Skill.
    stage = f"{python} {shlex.quote(str(HERE.parent / 'stages/agterm-stage'))} hook || true"
    # Стадии работы (stages/): скилы в PreToolUse, успешные команды Bash (явная команда
    # агента, glab mr create/merge) в PostToolUse, слэш-команды в UserPromptSubmit,
    # инструкция агенту и возврат строки в сайдбар в SessionStart.
    commands = [
        ("UserPromptSubmit", f"{runner} context", ""),
        ("PostToolUse", f"{runner} finish-arm", "Bash"),
        ("Stop", f"{runner} finish-offer", ""),
        ("PreToolUse", stage, "Skill"),
        ("PostToolUse", stage, "Bash"),
        ("UserPromptSubmit", stage, ""),
        ("SessionStart", stage, ""),
    ]
    for event, cmd, matcher in commands:
        # Удаляем лишь прежние записи нашего runner с этим действием.
        groups = []
        for group in hooks.get(event, []):
            remaining = [h for h in group.get("hooks", []) if h.get("command") != cmd]
            if remaining:
                groups.append({**group, "hooks": remaining})
        entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
        if matcher:
            entry["matcher"] = matcher
        groups.append(entry)
        hooks[event] = groups
    return original


def install(source: Path | None) -> None:
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(home / ".config")))
    claude = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude")))
    keymap, settings = config / "agterm/keymap.conf", claude / "settings.json"
    # Все структурные проверки до изменений пользовательских настроек.
    new_keymap = migrate_keymap(keymap.read_text() if keymap.exists() else "")
    data = json.loads(settings.read_text()) if settings.exists() else {}
    if not isinstance(data, dict):
        raise ValueError(f"{settings}: ожидается JSON-объект")
    new_settings = hook_settings(data)
    root = cache_root()
    skills = {"webrev": "annotate-document", "agdoc": "html-doc-overlay"}
    for name, recipe in skills.items():
        link, expected = claude / "skills" / name, root / "cookbook" / recipe
        if (link.exists() or link.is_symlink()) and (not link.is_symlink() or link.resolve() != expected):
            raise ValueError(f"{link}: уже есть чужой skill. Автоматически не заменяю")
    conf = config / "agterm-kit/workflows.conf"
    changes = {keymap: new_keymap, settings: json.dumps(new_settings, ensure_ascii=False, indent=2) + "\n"}
    if not conf.exists():
        changes[conf] = (HERE / "workflows.conf.example").read_text()
    for path in [*changes, *(claude / "skills" / name for name in skills)]:
        parent = path.resolve().parent
        while not parent.exists():
            parent = parent.parent
        if not parent.is_dir() or not os.access(parent, os.W_OK):
            raise ValueError(f"Недоступен каталог назначения: {parent}")
        if path.exists() and not path.is_file() and not path.is_symlink():
            raise ValueError(f"Ожидается файл: {path}")
    fetch(source, root)
    # Несколько файлов не заменить атомарно одним rename. При ошибке возвращаем
    # уже изменённые настройки, бэкапы write() остаются дополнительной страховкой.
    originals = {path: path.read_text() if path.exists() else None for path in changes}
    changed, linked = [], []
    try:
        for path, text in changes.items():
            write(path, text)
            changed.append(path)
        for name, recipe in skills.items():
            link = claude / "skills" / name
            link.parent.mkdir(parents=True, exist_ok=True)
            if not link.is_symlink():
                link.symlink_to(root / "cookbook" / recipe, target_is_directory=True)
                linked.append(link)
    except OSError:
        for link in linked:
            link.unlink()
        for path in reversed(changed):
            if originals[path] is None:
                path.resolve().unlink(missing_ok=True)
            else:
                write(path, originals[path])
        raise
    print(f"GUI установлен. Cookbook: {LOCK['commit'][:12]}; навыки: webrev, agdoc")
    print("Применить клавиши: agtermctl keymap reload. Новые хуки проверяйте в новой сессии Claude.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="локальный checkout upstream для установки без сети")
    args = parser.parse_args()
    try:
        install(args.source)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"Установка GUI: {exc}\n")
