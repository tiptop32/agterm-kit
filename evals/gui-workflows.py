#!/usr/bin/env python3
"""Платный eval инструкций cookbook через локальный Claude Code. Порог: 100%."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / "workflows"))
from run import config  # noqa: E402
from install import LOCK, cache_root  # noqa: E402
import hashlib


def main() -> int:
    root = cache_root()
    documents = []
    for recipe in ("annotate-document", "html-doc-overlay"):
        relative = f"cookbook/{recipe}/SKILL.md"
        data = (root / relative).read_bytes()
        if hashlib.sha256(data).hexdigest() != LOCK["files"][relative]:
            raise ValueError(f"Изменён skill: {relative}")
        documents.append(data.decode())
    cases = [
        ("question", "webrev note: '?? why is retry needed?'", "answer_only"),
        ("directive", "webrev note: 'Replace 3 retries with 5 retries'", "edit"),
        ("cancel", "webrev exited 2; user cancelled", "stop_unchanged"),
        ("pending", "webrev waiter timed out, backup says pending PAGE-ID", "recover_result"),
        ("private", "agdoc: create a brief about the local plan. No request to share", "local_overlay"),
        ("design", "agdoc: use classic design for this local document", "classic_no_question"),
    ]
    prompt = ("Evaluate these installed skill instructions. Do not use tools or execute actions. "
              "For each case choose the next action from this vocabulary: answer_only, edit, "
              "stop_unchanged, recover_result, local_overlay, classic_no_question. "
              "Return ONLY a JSON object mapping case id to action.\n\n" + "\n\n".join(documents)
              + "\n\nCASES:\n" + json.dumps([{ "id": key, "scenario": text } for key, text, _ in cases]))
    out = Path(tempfile.mkdtemp(prefix="agterm-gui-eval-"))
    print(f"Отчёт: {out}/report.json", flush=True)
    env = os.environ.copy()
    # Не наследуем сессию терминала: eval не открывает страницы поверх работы пользователя.
    for key in list(env):
        if key.startswith(("AGTERM_", "AGT_")) or key == "CLAUDECODE":
            env.pop(key)
    result = subprocess.run(
        ["claude", "-p", "--model", config()["model"], "--tools", "", "--setting-sources", "",
         "--output-format", "json", "--no-session-persistence"],
        input=prompt, capture_output=True, text=True, cwd=out, env=env, timeout=240)
    (out / "stdout.json").write_text(result.stdout)
    (out / "stderr.txt").write_text(result.stderr)
    if result.returncode:
        detail = result.stderr.strip()
        try:
            detail = json.loads(result.stdout).get("result", detail)
        except ValueError:
            pass
        raise RuntimeError(f"Claude завершился с кодом {result.returncode}: {detail}; логи: {out}")
    response = json.loads(result.stdout)
    raw = response["result"].strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1].rsplit("```", 1)[0]
    answers = json.loads(raw)
    results = [{"id": key, "expected": expected, "actual": answers.get(key),
                "pass": answers.get(key) == expected} for key, _, expected in cases]
    passed = sum(item["pass"] for item in results)
    report = {"model": config()["model"], "cases": results, "passed": passed,
              "total": len(cases), "threshold_percent": 100,
              "scope": "skill decision quality; UI and git are covered separately"}
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"{passed}/{len(cases)}, порог 100%")
    return 0 if passed == len(cases) and not response.get("is_error") else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as exc:
        print(f"eval: {exc}", file=sys.stderr)
        sys.exit(1)
