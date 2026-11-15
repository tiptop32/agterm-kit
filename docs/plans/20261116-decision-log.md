# Журнал решений: CLI и скилл (agterm-kit)

Часть плана `~/my_git_reps/agent-dispatch/docs/plans/20261115-decision-log.md` (три раунда
ревью 2026-11-15). Формат записи, критерии записи и prod-правило описаны там. Здесь — то,
что живёт в agterm-kit: CLI `agterm-decision`, golden-файл формата (единственный источник,
его читает и тест agent-dispatch) и исходник скилла `decisions`.

## Overview

Claude-сессия пишет в журнал свои решения, принятые без пользователя, и заданные вопросы.
Пользователь разбирает их потом: `open`, затем `mark` или `answer`. Демон agent-dispatch
пишет в тот же журнал записи исполнителей сам, без этого CLI.

## Context

- Правило «одна утилита, один каталог» (`AGENTS.md`), образцы `stages/agterm-stage` и
  `lb-limits/lb-limits` на системном `python3` (stdlib).
- `make lint` проверяет Python-утилиты через `ast.parse` (Makefile:12), `make test` запускает bats (Makefile:3).
- Переменная сессии Claude Code: `CLAUDE_CODE_SESSION_ID` (проверено в env 2026-11-15).
- PIPE_BUF к обычным файлам не относится. Запись идёт одним `write()` под `fcntl.flock`.
- Каталог журнала по умолчанию `~/.local/state/decisions`, переопределяется `DECISION_LOG_DIR`.

## Формат

Файл `<dir>/<repo>/<YYYY-MM-DD>.jsonl`, одна запись на строку, только дозапись:

```json
{"id":"<10 hex>","ts":"2026-11-15T14:02:11+03:00","repo":"agent-dispatch","session":"<id>","source":"claude","task_id":null,"kind":"decision|question|answer|verdict","text":"...","why":"...","ref":null}
```

- `id` = `secrets.token_hex(5)`.
- `repo` = basename каталога над `git rev-parse --path-format=absolute --git-common-dir`,
  вне git — basename `cwd`.
- `session` = `CLAUDE_CODE_SESSION_ID` или `--session`.
- `answer` и `verdict` ссылаются на запись через `ref`. У `verdict` поле `text` принимает
  `keep|change|revert`, а `why` содержит заметку.
- С флагом `--prod` пишется `text: "(prod)"`, `why: null`.

## Implementation Steps

### Task 1: CLI agterm-decision
**Depends on:** none
**Files:**
- Create: `decision/agterm-decision`
- Create: `decision/decision_log.example.jsonl`
- Create: `tests/decision.bats`

- [x] Python stdlib, команды: `add --kind --text --why [--ref] [--session] [--prod]`, `list [--repo] [--since 7d] [--kind]`, `show <id-prefix>`, `mark <id-prefix> keep|change|revert [--note]`, `answer <id-prefix> --text`, `open`
- [x] `open`: записи `decision` без `verdict` и `question` без `answer`, свежие сверху, по умолчанию за 14 дней
- [x] `show`/`mark`/`answer` принимают префикс id и отказывают, если он неоднозначен
- [x] Запись одним `write()` под `fcntl.flock`; битая строка при чтении пропускается с предупреждением в stderr
- [x] `decision_log.example.jsonl`: по одной строке каждого `kind`; формат меняется сначала здесь
- [x] `tests/decision.bats` (изолированный HOME, `DECISION_LOG_DIR` во временном каталоге, ASCII-имена тестов): каждая запись `add` проходит сверку с golden, append-only, фильтры `list`, префикс и неоднозначность, open/answer/mark, битая строка, два параллельных `add` (обе строки целые), два одинаковых `add` в одну секунду с разными id, `--prod`, `CLAUDE_CODE_SESSION_ID` → `session`, `repo` внутри worktree равен имени основной репы
- [x] Прогнать `bats tests/decision.bats`, должны пройти

### Task 2: скилл decisions
**Depends on:** Task 3
**Files:**
- Create: `decision/skill/SKILL.md`
- Modify: `README.md`

- [ ] Скилл: разбор через `agterm-decision open`, затем `mark` или `answer`. Для `change`/`revert` агент предлагает правку или follow-up через диспатчер. Вся логика в CLI, скилл только вызывает его
- [ ] README: установка скилла симлинком `~/.claude/skills/decisions` → `decision/skill` (ручной шаг пользователя, песочница не даёт агенту писать в `~/.claude`)
- [ ] Прогнать `make lint && make test`, должны пройти

### Task 3: установка, lint и README для agterm-decision
**Depends on:** Task 1
**Files:**
- Modify: `install.sh`
- Modify: `Makefile`
- Modify: `README.md`

- [x] `install.sh` ставит `decision/agterm-decision` в PATH, как остальные утилиты
- [x] `make lint` добавляет `decision/agterm-decision` в `ast.parse`-проверку
- [x] README: раздел про журнал решений (команды, каталог, `--prod`)
- [x] Прогнать `make lint && make test`, должны пройти
