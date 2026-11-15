#!/usr/bin/env bats

load helpers

setup() {
    setup_env
    export DECISION=$KIT_DIR/decision/agterm-decision
    export GOLDEN=$KIT_DIR/decision/decision_log.example.jsonl
    export DECISION_LOG_DIR=$T/decisions
    unset CLAUDE_CODE_SESSION_ID
    mkdir -p "$T/agterm-kit"
    cd "$T/agterm-kit"
}

# Фикстуры используют golden как формат, но ожидаемые id и результаты задаёт тест.
seed_log() {
    python3 - "$1" <<'PY'
import json, os
from datetime import datetime, timedelta
from pathlib import Path
base = json.loads(Path(os.environ['GOLDEN']).read_text().splitlines()[0])
now = datetime.now().astimezone()
for changes in json.loads(__import__('sys').argv[1]):
    age = changes.pop('age', 0)
    record = dict(base, ts=(now - timedelta(days=age)).isoformat())
    record.update(changes)
    path = Path(os.environ['DECISION_LOG_DIR']) / record['repo'] / (record['ts'][:10] + '.jsonl')
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + '\n')
PY
}

assert_ids() {
    printf '%s' "$output" | python3 -c '
import json, sys
actual = [json.loads(line)["id"] for line in sys.stdin.read().splitlines()]
assert actual == sys.argv[1:], (actual, sys.argv[1:])
' "$@"
}

@test "add matches golden for every kind and persists one complete line" {
    python3 - <<'PY'
import json, os, re, subprocess
from datetime import datetime
from pathlib import Path
examples = [json.loads(line) for line in Path(os.environ['GOLDEN']).read_text().splitlines()]
assert sorted(row['kind'] for row in examples) == ['answer', 'decision', 'question', 'verdict']
ids = set()
stored = []
for example in examples:
    args = [os.environ['DECISION'], 'add', '--kind', example['kind'],
            '--text', example['text'], '--why', example['why'], '--session', example['session']]
    if example['ref'] is not None:
        args += ['--ref', example['ref']]
    before = datetime.now().astimezone()
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    after = datetime.now().astimezone()
    assert result.stderr == '', result.stderr
    assert len(result.stdout.splitlines()) == 1
    actual = json.loads(result.stdout)
    assert re.fullmatch('[0-9a-f]{10}', actual['id'])
    assert actual['id'] not in ids
    ids.add(actual['id'])
    moment = datetime.fromisoformat(actual['ts'])
    assert moment.utcoffset() is not None
    assert before <= moment <= after
    path = Path(os.environ['DECISION_LOG_DIR']) / 'agterm-kit' / (actual['ts'][:10] + '.jsonl')
    stored.append(actual)
    assert [json.loads(line) for line in path.read_text().splitlines()] == stored
    normalized = dict(actual, id=example['id'], ts=example['ts'])
    assert normalized == example, (normalized, example)
PY
}

@test "mark and answer append without changing existing bytes across repositories" {
    seed_log '[{"id":"a100000001"},{"id":"b200000002","kind":"question"}]'
    cat "$DECISION_LOG_DIR"/agterm-kit/*.jsonl > "$T/before"
    mkdir -p "$T/elsewhere"
    cd "$T/elsewhere"
    run "$DECISION" mark a100 keep --note 'Оставить как есть'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$T/verdict"
    run "$DECISION" answer b200 --text 'Да, делать'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$T/answer"
    python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['T'])
data = b''.join(p.read_bytes() for p in sorted((Path(os.environ['DECISION_LOG_DIR']) / 'agterm-kit').glob('*.jsonl')))
assert data.startswith((root / 'before').read_bytes())
rows = [json.loads(line) for line in data.splitlines()]
verdict, answer = (json.loads((root / name).read_text()) for name in ('verdict', 'answer'))
assert rows[-2:] == [verdict, answer]
assert (verdict['kind'], verdict['text'], verdict['why'], verdict['ref']) == ('verdict', 'keep', 'Оставить как есть', 'a100000001')
assert (answer['kind'], answer['text'], answer['why'], answer['ref']) == ('answer', 'Да, делать', None, 'b200000002')
assert verdict['repo'] == answer['repo'] == 'agterm-kit'
assert not (Path(os.environ['DECISION_LOG_DIR']) / 'elsewhere').exists()
PY
}

@test "list filters repository age and kind and sorts by timezone aware timestamp" {
    seed_log '[{"id":"a000000001","age":2},{"id":"b000000002","kind":"question","age":1},{"id":"c000000003","repo":"other","age":3},{"id":"d000000004","age":20}]'
    run "$DECISION" list
    [ "$status" -eq 0 ]
    assert_ids b000000002 a000000001 c000000003 d000000004
    run "$DECISION" list --repo agterm-kit --since 7d --kind decision
    [ "$status" -eq 0 ]
    assert_ids a000000001
    run "$DECISION" list --repo other
    [ "$status" -eq 0 ]
    assert_ids c000000003
    run "$DECISION" list --kind question
    [ "$status" -eq 0 ]
    assert_ids b000000002
    run "$DECISION" list --since 1w
    [ "$status" -ne 0 ]
    seed_log '[{"id":"e000000005","ts":"2026-11-10T03:00:00+03:00"},{"id":"f000000006","ts":"2026-11-10T01:00:00+00:00"}]'
    run "$DECISION" list --kind decision
    [ "$status" -eq 0 ]
    # Сравнение строк поставило бы 03:00+03:00 перед 01:00+00:00.
    printf '%s' "$output" | python3 -c 'import json,sys; ids=[json.loads(x)["id"] for x in sys.stdin]; assert ids.index("f000000006") < ids.index("e000000005")'
}

@test "show resolves a unique prefix and full id without age or repo restriction" {
    seed_log '[{"id":"abc0000001","repo":"other","age":40}]'
    run "$DECISION" show abc
    [ "$status" -eq 0 ]
    assert_ids abc0000001
    first=$output
    run "$DECISION" show abc0000001
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
}

@test "ambiguous missing and invalid prefixes fail without appending" {
    seed_log '[{"id":"aa00000001"},{"id":"aa00000002","kind":"question"}]'
    cat "$DECISION_LOG_DIR"/agterm-kit/*.jsonl > "$T/before"
    for prefix in aa fffff / ''; do
        run "$DECISION" show "$prefix"
        [ "$status" -ne 0 ]
        [[ "$output" != *Traceback* ]]
        run "$DECISION" mark "$prefix" keep
        [ "$status" -ne 0 ]
        run "$DECISION" answer "$prefix" --text 'Ответ'
        [ "$status" -ne 0 ]
    done
    run "$DECISION" show aa
    [[ "$output" == *неоднозначный* ]]
    cat "$DECISION_LOG_DIR"/agterm-kit/*.jsonl > "$T/after"
    cmp "$T/before" "$T/after"
}

@test "open shows unresolved decisions and questions for fourteen days newest first" {
    seed_log '[{"id":"a000000001","age":15},{"id":"b000000002","age":10},{"id":"c000000003","kind":"question","age":5},{"id":"d000000004","age":1},{"id":"e000000005","kind":"question","repo":"other","age":2}]'
    run "$DECISION" open
    [ "$status" -eq 0 ]
    assert_ids d000000004 e000000005 c000000003 b000000002
    run "$DECISION" mark d000 change --note 'Нужна правка'
    [ "$status" -eq 0 ]
    run "$DECISION" answer c000 --text 'Нет'
    [ "$status" -eq 0 ]
    run "$DECISION" open
    [ "$status" -eq 0 ]
    assert_ids e000000005 b000000002
    run "$DECISION" open --repo agterm-kit --since 30d
    [ "$status" -eq 0 ]
    assert_ids b000000002 a000000001
    run "$DECISION" mark b000 revert
    [ "$status" -eq 0 ]
    run "$DECISION" open --repo agterm-kit
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "only matching response kind and repository close an open item" {
    seed_log '[{"id":"a000000001"},{"id":"b000000002","kind":"question"},{"id":"c000000003","kind":"answer","ref":"a000000001"},{"id":"d000000004","kind":"verdict","text":"keep","ref":"b000000002"},{"id":"e000000005","repo":"other","kind":"verdict","text":"keep","ref":"a000000001"}]'
    run "$DECISION" open
    [ "$status" -eq 0 ]
    assert_ids a000000001 b000000002
}

@test "mark and answer reject incompatible targets and invalid verdicts" {
    seed_log '[{"id":"a000000001"},{"id":"b000000002","kind":"question"}]'
    cat "$DECISION_LOG_DIR"/agterm-kit/*.jsonl > "$T/before"
    run "$DECISION" mark b000 keep
    [ "$status" -ne 0 ]
    run "$DECISION" answer a000 --text 'Нет'
    [ "$status" -ne 0 ]
    run "$DECISION" mark a000 invalid
    [ "$status" -ne 0 ]
    cat "$DECISION_LOG_DIR"/agterm-kit/*.jsonl > "$T/after"
    cmp "$T/before" "$T/after"
}

@test "corrupt JSON UTF8 and invalid records warn on stderr and preserve valid rows" {
    seed_log '[{"id":"a000000001"}]'
    python3 - <<'PY'
import os
from pathlib import Path
path = next(Path(os.environ['DECISION_LOG_DIR']).glob('*/*.jsonl'))
with path.open('ab') as stream:
    stream.write(b'broken\n\xff\nnull\n{}\n')
PY
    seed_log '[{"id":"b000000002","age":1}]'
    "$DECISION" list > "$T/stdout" 2> "$T/stderr"
    python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['T'])
assert [json.loads(x)['id'] for x in (root / 'stdout').read_text().splitlines()] == ['a000000001', 'b000000002']
warnings = (root / 'stderr').read_text().splitlines()
assert len(warnings) == 4, warnings
assert all('предупреждение' in line and '.jsonl:' in line for line in warnings)
PY
}

@test "parallel adds keep both large unicode records complete" {
    text=$(python3 -c 'print("Решение\n" * 4000 + "конец", end="")')
    "$DECISION" add --kind decision --text "$text" --why first > "$T/first" &
    first=$!
    "$DECISION" add --kind question --text "$text" --why second > "$T/second" &
    second=$!
    wait "$first"
    wait "$second"
    python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['T'])
files = list(Path(os.environ['DECISION_LOG_DIR']).glob('*/*.jsonl'))
assert len(files) == 1
raw = files[0].read_bytes()
assert raw.endswith(b'\n')
rows = [json.loads(line) for line in raw.splitlines()]
expected = [json.loads((root / name).read_text()) for name in ('first', 'second')]
assert sorted(rows, key=lambda x: x['id']) == sorted(expected, key=lambda x: x['id'])
assert len({r['id'] for r in rows}) == 2
assert {r['why'] for r in rows} == {'first', 'second'}
assert all(r['text'] == 'Решение\n' * 4000 + 'конец' for r in rows)
PY
}

@test "identical adds in the same second have distinct ids" {
    # Фиксируем только часы: CLI, secrets и файловая запись остаются настоящими.
    python3 - <<'PY'
import contextlib, io, json, os, runpy, sys
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
class Frozen(datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 11, 16, 12, 0, 0, tzinfo=timezone.utc)
results = []
for _ in range(2):
    output = io.StringIO()
    with patch('datetime.datetime', Frozen), patch.object(sys, 'argv', [os.environ['DECISION'], 'add', '--kind', 'decision', '--text', 'same', '--why', 'same']), contextlib.redirect_stdout(output):
        try:
            runpy.run_path(os.environ['DECISION'], run_name='__main__')
        except SystemExit as exc:
            assert exc.code == 0
    results.append(json.loads(output.getvalue()))
assert results[0]['ts'] == results[1]['ts']
assert results[0]['id'] != results[1]['id']
files = list(Path(os.environ['DECISION_LOG_DIR']).glob('*/*.jsonl'))
assert len(files) == 1
assert [json.loads(line) for line in files[0].read_text().splitlines()] == results
PY
}

@test "prod omits sensitive text and why and allows no sensitive arguments" {
    run "$DECISION" add --kind decision --text 'Секрет' --why 'Пароль' --prod
    [ "$status" -eq 0 ]
    run "$DECISION" add --kind question --prod
    [ "$status" -eq 0 ]
    python3 - <<'PY'
import json, os
from pathlib import Path
raw = ''.join(p.read_text() for p in Path(os.environ['DECISION_LOG_DIR']).glob('*/*.jsonl'))
rows = [json.loads(line) for line in raw.splitlines()]
assert len(rows) == 2
assert all(r['text'] == '(prod)' and r['why'] is None for r in rows)
assert 'Секрет' not in raw and 'Пароль' not in raw
PY
}

@test "session uses Claude environment with explicit override and null when absent" {
    export CLAUDE_CODE_SESSION_ID=env-session
    "$DECISION" add --kind decision --text one --why one > "$T/env"
    "$DECISION" add --kind decision --text two --why two --session explicit > "$T/explicit"
    unset CLAUDE_CODE_SESSION_ID
    "$DECISION" add --kind decision --text three --why three > "$T/none"
    python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['T'])
assert [json.loads((root / name).read_text())['session'] for name in ('env', 'explicit', 'none')] == ['env-session', 'explicit', None]
PY
}

@test "worktree repo is the main repository name even from a nested directory" {
    mkdir -p "$T/main-repo"
    git -C "$T/main-repo" init -q
    git -C "$T/main-repo" -c core.hooksPath=/dev/null commit --allow-empty -qm initial
    git -C "$T/main-repo" worktree add -q -b branch "$T/different-worktree"
    mkdir -p "$T/different-worktree/nested"
    cd "$T/different-worktree/nested"
    run "$DECISION" add --kind decision --text 'Worktree' --why 'Main repo'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["repo"] == "main-repo"'
    [ -d "$DECISION_LOG_DIR/main-repo" ]
    [ ! -e "$DECISION_LOG_DIR/different-worktree" ]
}

@test "default storage stays under isolated HOME and empty journal is read only" {
    unset DECISION_LOG_DIR
    run "$DECISION" list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run "$DECISION" open
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$HOME/.local/state/decisions" ]
    run "$DECISION" add --kind decision --text 'Default' --why 'No override'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["repo"] == "agterm-kit"'
    [ -d "$HOME/.local/state/decisions/agterm-kit" ]
}

@test "invalid add arguments fail without creating storage" {
    run "$DECISION" add --kind decision --text missing-why
    [ "$status" -ne 0 ]
    run "$DECISION" add --kind unknown --text x --why y
    [ "$status" -ne 0 ]
    run "$DECISION" add --kind verdict --text unknown --why y
    [ "$status" -ne 0 ]
    [ ! -e "$DECISION_LOG_DIR" ]
}
