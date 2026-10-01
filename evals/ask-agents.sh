#!/usr/bin/env bash
# Периодический eval agterm-ask на настоящих агентах: задаёт ли агент вопрос через оверлей
# и доходит ли до него ответ. Платный (вызовы моделей), медленный, нужен запущенный agterm.
#
#   evals/ask-agents.sh [-n ПРОГОНОВ] [-t ПОРОГ%] [codex] [opencode]
#   ASK_EVAL_DELAY=75 evals/ask-agents.sh opencode   # ответ через 75 с: таймауты агента
#   ASK_EVAL_PROMPT="..." evals/ask-agents.sh codex  # свой промпт
#
# Каждый прогон: агент получает задачу, в которой надо спросить пользователя о выборе.
# Фоновый «пользователь» ждёт страницу agterm-ask в этой сессии, выбирает в каждом вопросе
# ВТОРОЙ вариант (чтобы агент не угадал ответ по умолчанию) и отправляет его через
# agtermctl session overlay submit. Прогон засчитан, если страница появилась и агент
# напечатал строку ВЫБРАНО: <выбранный вариант>.
#
# Отчёт и логи: /tmp/agterm-ask-eval/<время>/. Код выхода 0, если доля успехов не ниже порога.
set -uo pipefail

runs=2 threshold=100
while getopts n:t: opt; do
    case $opt in
        n) runs=$OPTARG ;;
        t) threshold=$OPTARG ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
agents=("$@")
[[ ${#agents[@]} -gt 0 ]] || agents=(codex opencode)

[[ ${AGTERM_ENABLED:-} == 1 && -n ${AGTERM_SESSION_ID:-} ]] || { echo "запустите внутри agterm" >&2; exit 2; }

ctl() { agtermctl "$@" ${AGTERM_SOCKET:+--socket "$AGTERM_SOCKET"}; }

out=/tmp/agterm-ask-eval/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
echo "логи: $out"

prompt=${ASK_EVAL_PROMPT:-'Я выбираю формат конфига для нового маленького CLI-сервиса: YAML, TOML или JSON. Не выбирай за меня: спроси меня, какой формат взять, с вариантами ответа. Когда я отвечу, напиши последней строкой ровно: ВЫБРАНО: <формат, который я выбрал>. Файлы не создавай и команды не запускай.'}

# answer_page <файл-ответа>: дождаться страницы agterm-ask в своей сессии (до 240 с),
# ответить вторым вариантом каждого вопроса, записать выбранную метку.
answer_page() {
    local note=$1 file data value
    for _ in $(seq 480); do
        file=$(ctl tree --json --window "${AGTERM_WINDOW_ID:-active}" 2>/dev/null |
            jq -r '[.. | objects | select(has("htmlOverlays")) | .htmlOverlays[]? | .file // empty
                    | select(test("agterm-ask\\.[^/]+/ask\\.html$"))] | first // empty')
        if [[ -n $file && -r $file ]]; then
            data=$(sed -n 's/.*<script type="application\/json" id="ask-data">\(.*\)<\/script>.*/\1/p' "$file")
            value=$(jq -c '{answers: (.questions | map({key: .question, value: (.options[1] // .options[0]).label}) | from_entries)}' <<<"$data")
            jq -r '.answers | to_entries[0].value' <<<"$value" > "$note"
            # Пауза перед ответом: страница успевает прорисоваться, а ASK_EVAL_DELAY проверяет,
            # что агент не обрывает долгое ожидание (OpenCode держит его прогрессом).
            sleep "${ASK_EVAL_DELAY:-1.5}"
            ctl session overlay submit --value "$value" --target "$AGTERM_SESSION_ID" >/dev/null
            return 0
        fi
        sleep 0.5
    done
    return 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

run_agent() {
    local agent=$1 dir=$2
    case $agent in
        # stdin из /dev/null: без терминала codex exec дочитывает stdin и ждёт EOF.
        codex) (cd "$dir" && codex exec --skip-git-repo-check "$prompt" < /dev/null) ;;
        opencode) (cd "$dir" && opencode run "$prompt" < /dev/null) ;;
        *) echo "неизвестный агент $agent" >&2; return 2 ;;
    esac
}

pass=0 total=0
report=$out/report.tsv
printf 'agent\trun\tpage\tchosen\tagent_said\tresult\n' > "$report"
for agent in "${agents[@]}"; do
    for n in $(seq "$runs"); do
        total=$((total + 1))
        dir=$out/$agent-$n
        mkdir -p "$dir/work"
        answer_page "$dir/chosen" & user=$!
        run_agent "$agent" "$dir/work" > "$dir/stdout" 2> "$dir/stderr"
        if kill -0 "$user" 2>/dev/null; then
            kill "$user" 2>/dev/null
            wait "$user" 2>/dev/null
        else
            wait "$user"
        fi
        chosen=$(cat "$dir/chosen" 2>/dev/null)
        said=$(grep -o 'ВЫБРАНО: *[^ *`]*' "$dir/stdout" | tail -1 | sed 's/ВЫБРАНО: *//')
        if [[ -n $chosen ]] && [[ $(lower "$said") == "$(lower "$chosen")" ]]; then
            result=pass pass=$((pass + 1))
        else
            result=fail
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$agent" "$n" "$([[ -n $chosen ]] && echo yes || echo no)" \
            "${chosen:--}" "${said:--}" "$result" | tee -a "$report"
    done
done

score=$((100 * pass / total))
echo "итог: $pass из $total ($score%), порог $threshold%"
((score >= threshold))
