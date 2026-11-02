#!/usr/bin/env python3
"""Восстановление адреса после перезапуска agterm, без выбора active."""
import json
import os
from pathlib import Path
import subprocess
import sys


def ctl(*args):
    command = ["agtermctl", *args, "--json"]
    if os.environ.get("AGTERM_SOCKET"):
        command += ["--socket", os.environ["AGTERM_SOCKET"]]
    reply = json.loads(subprocess.run(command, check=True, capture_output=True,
                                      text=True, timeout=5).stdout)
    if reply.get("ok") is False:
        raise ValueError(reply.get("error", "agtermctl failed"))
    return reply["result"]


def resolve():
    sessions = []
    for window in ctl("window", "list")["windows"]:
        if not window.get("open", True):
            continue
        tree = ctl("tree", "--window", window["id"])["tree"]
        for workspace in tree["workspaces"]:
            sessions += [(window["id"], s) for s in workspace["sessions"]]
    pane = os.environ.get("AGTERM_PANE_ID", "").lower()
    matches = [(w, s) for w, s in sessions if pane and any(
        p.get("paneID", "").lower() == pane for p in s.get("surfaces", []))]
    if not matches:
        cwd = Path.cwd().resolve()
        matches = [(w, s) for w, s in sessions
                   if not s.get("remoteHost") and s.get("cwd")
                   and Path(s["cwd"]).resolve() == cwd]
    if len(matches) != 1:
        raise ValueError(f"неоднозначная привязка: найдено сессий {len(matches)}")
    window, session = matches[0]
    # Вывод читается bash через read, без eval.
    if any(c.isspace() for c in window + session["id"]):
        raise ValueError("некорректный ID сессии")
    print(window, session["id"])


if __name__ == "__main__":
    try:
        resolve()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"agterm-ask: {error}", file=sys.stderr)
        sys.exit(1)
