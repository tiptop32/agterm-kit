#!/usr/bin/env python3
"""Полный детерминированный eval экспорта реальной установленной палитры Rex."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from rex import DEFAULT_SOURCE

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
args = parser.parse_args()
report = Path(tempfile.mkdtemp(prefix="rex-eval-", dir="/tmp"))
env = {**os.environ, "XDG_CONFIG_HOME": str(report / "config")}
cli = Path(__file__).with_name("rex.py")


def run(*words):
    subprocess.run([sys.executable, str(cli), *words, "--no-reload"],
                   env=env, check=True, capture_output=True, text=True)


run("install", "--source", str(args.source))
results = []
# Ожидаемые значения берём из оригинала, проверяем конечный пользовательский файл.
for theme in json.loads(args.source.read_text()):
    run("apply", theme["id"])
    text = (report / "config/agterm/ghostty.conf").read_text()
    pairs = [line.split(" = ", 1) for line in text.splitlines() if " = " in line]
    actual = dict(pairs)
    src = theme["source"]
    expected = {"background": src["background"], "foreground": src["foreground"],
                "cursor-color": src["cursor"], "cursor-text": src["cursorText"],
                "selection-background": src["selectionBackground"],
                "selection-foreground": src["selectionForeground"]}
    palette = [value for key, value in pairs if key == "palette"]
    passed = all(actual.get(k) == v for k, v in expected.items()) and palette == [
        f"{i}={value}" for i, value in enumerate(src["ansi"])]
    results.append({"theme": theme["id"], "pass": passed})
run("reset")
passed = sum(case["pass"] for case in results)
summary = {"cases": results, "passed": passed, "total": len(results), "threshold_percent": 100,
           "reset": (report / "config/agterm/ghostty.conf").read_text() == ""}
(report / "report.json").write_text(json.dumps(summary, indent=2))
print(f'{passed}/{len(results)}, reset={summary["reset"]}; {report}/report.json')
sys.exit(0 if passed == len(results) and summary["reset"] else 1)
