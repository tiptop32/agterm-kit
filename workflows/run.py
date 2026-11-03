#!/usr/bin/env python3
"""Входы палитры и Claude hooks: конфиг как данные, cookbook с проверкой хешей."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / "recipes.lock.json").read_text())
RECIPES = {
    "recent": ("flag-recent-agents/agt-flag-recent.sh", []),
    "dashboard": ("flagged-dashboard/agt-flagged-dashboard.sh", []),
    "resume": ("claude-conversation-picker/claude-pick-conversation.py", []),
    "directory": ("native-dir-picker/pick-dir.sh", []),
    "companion": ("named-companion/companion.py", []),
    "context": ("session-context-nudge/context-nudge.sh", []),
    "finish-arm": ("end-of-task-offer/end-of-task-offer.sh", ["arm"]),
    "finish-offer": ("end-of-task-offer/end-of-task-offer.sh", ["offer"]),
}


def config() -> dict:
    path = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "agterm-kit/workflows.conf"
    result = {"model": "opus", "recent_minutes": "30"}
    if path.exists():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            line = line.split(" #", 1)[0].strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if not sep or key not in result or not value:
                raise ValueError(f"{path}:{number}: неверная настройка")
            result[key] = value
    if not result["recent_minutes"].isdigit() or not 1 <= int(result["recent_minutes"]) <= 10080:
        raise ValueError("recent_minutes должен быть от 1 до 10080")
    return result


def asks_user(stop_payload: str) -> bool:
    """Ход Claude закончился вопросом пользователю: работа не кончилась.

    Последняя непустая строка `last_assistant_message` из Stop hook, без markdown
    и кавычек в конце, оканчивается на «?». Агент снимает контекст и после
    промежуточного пункта, а затем спрашивает, браться ли за следующий.
    """
    try:
        payload = json.loads(stop_payload)
    except ValueError:
        return False
    message = payload.get("last_assistant_message") if isinstance(payload, dict) else None
    lines = [line for line in str(message or "").splitlines() if line.strip()]
    return bool(lines) and lines[-1].rstrip(" \t*_`'\"»)").endswith("?")


def main() -> int:
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    if action in ("project", "worktrees"):
        os.execv(sys.executable, [sys.executable, str(HERE.parent / "wt/gui.py"), action])
    if action not in RECIPES:
        raise ValueError("Неизвестное действие")
    if action == "finish-offer" and asks_user(sys.stdin.read()):
        # Тот же маркер, что взводит `end-of-task-offer.sh arm`: без него следующий
        # конец хода снова показал бы попап за уже пройденный пункт.
        pane = os.environ.get("AGTERM_PANE_ID", "")
        if pane:
            marker = Path(os.environ.get("TMPDIR") or "/tmp") / "agterm-end-of-task" / pane
            marker.unlink(missing_ok=True)
        return 0
    cfg = config()
    root = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "agterm-kit/cookbook" / LOCK["commit"]
    relative, args = RECIPES[action]
    script = root / "cookbook" / relative
    data = script.read_bytes()
    if hashlib.sha256(data).hexdigest() != LOCK["files"]["cookbook/" + relative]:
        raise ValueError(f"Изменён cookbook-скрипт: {script}; запуск отменён")
    env = os.environ.copy()
    env["CLAUDE_RESUME_MODEL"] = cfg["model"]
    env["FLAG_RECENT_MINUTES"] = cfg["recent_minutes"]
    # GUI стиль для диалогов cookbook; защитная политика завершения ниже в ctl.py.
    env["AGTERM_KIT_CTL"] = env.get("AGTERMCTL", "agtermctl")
    env["AGTERMCTL"] = str(HERE / "ctl.py")
    env["AGTERM_KIT_ACTION"] = action
    env["PATH"] = os.pathsep.join([str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", "")])
    if action == "directory":
        result = subprocess.run(["zsh", "-f", str(HERE.parent / "wt/gui-bridge.zsh"), "config"], capture_output=True, text=True, check=True)
        env["AGT_PICK_ROOTS"] = ":".join(json.loads(result.stdout)["roots"])
    interpreter = sys.executable if script.suffix == ".py" else ("/bin/bash" if action != "directory" else "/bin/sh")
    os.execve(interpreter, [interpreter, str(script), *args], env)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"agterm-kit: {exc}", file=sys.stderr)
        # Не ломаем отправку промпта Claude из-за неисправной необязательной интеграции.
        sys.exit(0 if len(sys.argv) > 1 and sys.argv[1] in ("context", "finish-arm", "finish-offer") else 1)
