#!/usr/bin/env bash
# Ручной интеграционный eval: живой agterm, устаревший ID, реальный ответ пользователя.
# Порог 100%: открытие и успешный ответ. Лог без текста вопроса/ответа в /tmp.
set -euo pipefail
kit_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
out=$(mktemp -d /tmp/agterm-ask-session-eval.XXXXXX)
echo "Отчёт: $out/result.txt"
export AGTERM_ENABLED=1 AGTERM_SESSION_ID=00000000-0000-0000-0000-000000000000
export AGTERM_ASK_LOG=$out/trace.log
# Вызывать из каталога с единственной соответствующей сессией agterm.
if "$kit_dir/ask/agterm-ask" --context 'Eval: восстановление диалога' \
    'Открылся диалог проверки привязки?' 'Да' 'Нет' >"$out/answer" 2>"$out/stderr"; then
    if [[ $(cat "$out/answer") == 'Да' ]]; then
        echo 'PASS: 1/1, threshold=100%' | tee "$out/result.txt"
        exit 0
    fi
fi
echo 'FAIL: 0/1, threshold=100%' | tee "$out/result.txt"
exit 1
