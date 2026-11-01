#!/usr/bin/env python3
"""Адаптер cookbook: GUI диалоги и продолжение как безопасное действие по умолчанию."""
import os
import sys

args = sys.argv[1:]
if args[:1] == ["ask"] and (len(args) < 2 or args[1] not in ("result", "cancel")):
    if "--style" not in args:
        args.extend(["--style", "gui"])
    if os.environ.get("AGTERM_KIT_ACTION") == "finish-offer" and "--default" in args:
        args[args.index("--default") + 1] = "continue"
        if "--message" in args:
            pos = args.index("--message") + 1
            args[pos] += " Clear resets both split conversations; Close also closes companions."
# Дочерний end-of-task-offer наследует ACTION=finish-offer, поэтому политика действует
# и для отсоединённого диалога. Никаких команд из вывода страницы здесь не исполняем.
os.execvp(os.environ.get("AGTERM_KIT_CTL", "agtermctl"), [os.environ.get("AGTERM_KIT_CTL", "agtermctl"), *args])
