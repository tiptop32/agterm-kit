#!/bin/sh
# Передаёт статус omp штатному адаптеру agterm. Вне agterm ничего не делает.

[ "${AGTERM_ENABLED:-}" = 1 ] || exit 0

default_status_script=${HOME:+$HOME/.config/agterm/agent-status/agterm-claude-status.sh}
status_script=${AGTERM_CLAUDE_STATUS_SCRIPT:-$default_status_script}
[ -n "$status_script" ] || exit 0
"$status_script" "$@" >/dev/null 2>&1 || :
exit 0
