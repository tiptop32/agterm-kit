#!/usr/bin/env bash
# PreToolUse-хук Claude Code: вопрос AskUserQuestion показывается через agterm-ask
# в HTML-оверлее agterm, ответ возвращается агенту через updatedInput.answers.
#
# Любой сбой, закрытая страница или запуск вне agterm дают пустой вывод и код 0:
# тогда Claude Code задаёт вопрос как обычно, в терминале. Хук ничего не запрещает.
set -uo pipefail

kit_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

input=$(cat)

command -v jq >/dev/null || exit 0
[[ $(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null) == AskUserQuestion ]] || exit 0
[[ ${AGTERM_ENABLED:-} == 1 ]] || exit 0
tool_input=$(jq -c '.tool_input | select(type == "object")' <<<"$input" 2>/dev/null)
[[ -n $tool_input ]] || exit 0
project=$(jq -r '.cwd // "" | split("/") | map(select(. != "")) | last // ""' <<<"$input")

out=$(mktemp "${TMPDIR:-/tmp}/agterm-ask-hook.XXXXXX") || exit 0
child=
# Claude Code по таймауту убивает хук, а не всю группу: передаём сигнал ядру,
# чтобы оно закрыло свою страницу, и ждём, пока оно это сделает.
forward() {
    [[ -n $child ]] && kill -TERM "$child" 2>/dev/null && wait "$child"
    rm -f "$out"
    exit 0
}
trap forward TERM INT HUP

AGTERM_ASK_AGENT=${AGTERM_ASK_AGENT:-claude-code} \
    "$kit_dir/agterm-ask" --context "Claude Code${project:+ · $project}" <<<"$tool_input" >"$out" &
child=$!
wait "$child"
status=$?
child=
answer=$(cat "$out")
rm -f "$out"
((status == 0)) || exit 0

jq -n -c --argjson ti "$tool_input" --argjson a "$answer" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "ответ получен в оверлее agterm",
    updatedInput: ($ti + $a)
}}'
