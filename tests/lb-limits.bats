#!/usr/bin/env bats
# lb-limits против поддельного agent-lb на 127.0.0.1: сеть наружу не нужна.
# Сервер отдаёт /api/pools только с cookie, выданной входом по паролю из $T/password.

load helpers

LB=$KIT_DIR/lb-limits/lb-limits

setup() {
    setup_env
    export XDG_CACHE_HOME=$HOME/.cache TZ=UTC NO_COLOR=1
    unset LB_LIMITS_CONFIG
    CACHE=$XDG_CACHE_HOME/agterm-kit/lb-limits
    echo 'secret pw' > "$T/password"
    : > "$T/lb.log"
    write_pools '{"fiveHourRemainingPercent": 79.4, "weeklyRemainingPercent": 82.5}'

    cat > "$T/server.py" <<'EOF'
import json, sys, http.server, pathlib
T = pathlib.Path(sys.argv[1])

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log(self):
        with open(T / "lb.log", "a") as f:
            f.write(f"{self.command} {self.path} {self.headers.get('Cookie', '-')}\n")
    def do_GET(self):
        self.log()
        valid = (T / "valid_cookie").read_text().strip() if (T / "valid_cookie").exists() else None
        if self.path == "/api/pools" and valid and self.headers.get("Cookie") == f"agent_lb_dashboard_session={valid}":
            return self.send(200, json.loads((T / "pools.json").read_text()))
        self.send(401, {"error": {"code": "authentication_required", "message": "x"}})
    def do_POST(self):
        self.log()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body.get("password") != (T / "password").read_text().strip():
            return self.send(401, {"error": {"code": "invalid_credentials"}})
        n = len((T / "lb.log").read_text().splitlines())
        (T / "valid_cookie").write_text(f"sess-{n}")
        self.send(200, {"authenticated": True},
                  [("Set-Cookie", f"agent_lb_dashboard_session=sess-{n}; HttpOnly; Path=/; SameSite=lax")])

s = http.server.HTTPServer(("127.0.0.1", 0), H)
(T / "port").write_text(str(s.server_port))
s.serve_forever()
EOF
    python3 "$T/server.py" "$T" 3>&- &
    SERVER_PID=$!
    for _ in $(seq 50); do [[ -s $T/port ]] && break; sleep 0.1; done
    write_conf "password_file=$T/env.local"
    printf '# пароль\nCODEX_LB_DASHBOARD_PASSWORD="secret pw"\n' > "$T/env.local"
}

teardown() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

write_conf() {
    mkdir -p "$XDG_CONFIG_HOME/agterm-kit"
    printf '%s\n' "url=http://127.0.0.1:$(cat "$T/port")" "$@" > "$XDG_CONFIG_HOME/agterm-kit/lb-limits.conf"
}

# write_pools <json-поля пула>: ответ /api/pools с пулом anthropic-general, сбросы через
# 2h39m (плюс 30 секунд на прогон теста) и в пятницу 2030-01-04 17:00 UTC.
write_pools() {
    python3 - "$T/pools.json" "$1" <<'EOF'
import json, sys, time
from datetime import datetime, timezone
five = datetime.fromtimestamp(time.time() + 2 * 3600 + 39 * 60 - 30, timezone.utc).isoformat()
pool = {"id": "anthropic-general", "provider": "anthropic", "kind": "pool", "accounts": 2,
        "eligibleAccounts": 1, "status": "ok", "fiveHourResetAt": five,
        "weeklyResetAt": "2030-01-04T17:00:00Z"}
pool.update(json.loads(sys.argv[2]))
json.dump({"generatedAt": "2030-01-01T00:00:00Z", "pools": [pool]}, open(sys.argv[1], "w"))
EOF
}

@test "refresh logs in with password from password_file and caches pool" {
    run "$LB" refresh
    [ "$status" -eq 0 ]
    run "$LB" </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "Claude 1/2 · 5h 79% 2h 39m · wk 83% Fri 17:00" ]
    # Без cookie 401, вход, повтор с выданной cookie.
    [ "$(cut -d' ' -f1,2 "$T/lb.log" | tr '\n' ,)" = "GET /api/pools,POST /api/dashboard-auth/password/login,GET /api/pools," ]
    [ "$(stat -f %Lp "$CACHE/cookie" 2>/dev/null || stat -c %a "$CACHE/cookie")" = 600 ]
}

@test "refresh reuses session cookie and logs in again after it expires" {
    "$LB" refresh
    : > "$T/lb.log"
    "$LB" refresh
    [ "$(grep -c login "$T/lb.log")" -eq 0 ]
    rm "$T/valid_cookie"
    "$LB" refresh
    [ "$(grep -c login "$T/lb.log")" -eq 1 ]
}

@test "wrong password shows short error and backs off further logins" {
    echo other > "$T/password"
    run "$LB" refresh
    [ "$status" -eq 1 ]
    run "$LB" </dev/null
    [ "$output" = "lb: вход не удался" ]
    : > "$T/lb.log"
    "$LB" </dev/null
    sleep 1
    [ ! -s "$T/lb.log" ]
}

@test "missing password_file is reported without touching the dashboard login" {
    write_conf
    run "$LB" refresh
    [ "$status" -eq 1 ]
    [ "$(grep -c login "$T/lb.log")" -eq 0 ]
    run "$LB" </dev/null
    [ "$output" = "lb: нужен password_file" ]
}

@test "stale cache prints old numbers at once and refreshes in background" {
    "$LB" refresh
    write_pools '{"fiveHourRemainingPercent": 10, "weeklyRemainingPercent": 50}'
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["fetchedAt"]-=120; json.dump(d,open(p,"w"))' "$CACHE/pools.json"
    run "$LB" </dev/null
    [[ $output == *"5h 79%"* ]]
    for _ in $(seq 50); do grep -q '"fiveHourRemainingPercent": 10' "$CACHE/pools.json" && break; sleep 0.1; done
    run "$LB" </dev/null
    [[ $output == *"5h 10%"* && $output == *"wk 50%"* ]]
}

@test "very old cache is marked with its age and the last error" {
    "$LB" refresh
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["fetchedAt"]-=1800; json.dump(d,open(p,"w"))' "$CACHE/pools.json"
    kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
    "$LB" refresh || true
    run "$LB" </dev/null
    [[ $output == *"5h 79%"*"(30m назад, нет связи)" ]]
}

@test "exhausted pool shows Out and colors follow dashboard thresholds" {
    write_pools '{"status": "exhausted", "fiveHourRemainingPercent": 25, "weeklyRemainingPercent": 0}'
    "$LB" refresh
    run "$LB" </dev/null
    [[ $output == *"5h 25% "*"wk Out" ]]
    [[ $output != *Fri* ]]
    unset NO_COLOR
    run "$LB" </dev/null
    [[ $output == *$'\e[33m5h 25%'* && $output == *$'\e[31mwk Out'* ]]
}

@test "half percent rounds up like the dashboard and month pools use mo" {
    write_pools '{"fiveHourRemainingPercent": 12.5, "weeklyRemainingPercent": null, "windowLabel": "month", "aggregateRemainingPercent": 40.5, "weeklyResetAt": null, "resetAt": "2030-01-07T09:05:00Z"}'
    "$LB" refresh
    run "$LB" </dev/null
    [[ $output == *"5h 13% "*"mo 41% Mon 09:05" ]]
}

@test "unknown pool id is named in the status line" {
    write_conf "password_file=$T/env.local" pool=nope
    "$LB" refresh
    run "$LB" </dev/null
    [ "$output" = "lb: нет пула nope" ]
}

@test "ccstatusline setup replaces account usage widgets and is idempotent" {
    mkdir -p "$XDG_CONFIG_HOME/ccstatusline"
    cat > "$XDG_CONFIG_HOME/ccstatusline/settings.json" <<'EOF'
{"version": 4, "lines": [
  [{"id": "1", "type": "model"}, {"id": "2", "type": "separator"}, {"id": "3", "type": "git-branch"}],
  [{"id": "10", "type": "session-usage"}, {"id": "10a", "type": "separator"}, {"id": "11", "type": "reset-timer"},
   {"id": "12", "type": "separator"}, {"id": "13", "type": "weekly-usage"}, {"id": "16", "type": "weekly-opus-usage"}],
  []
], "flexMode": "full-minus-40"}
EOF
    run "$LB" ccstatusline
    [ "$status" -eq 0 ]
    run jq -c '[.lines[] | [.[] | .type]], .lines[1][0].commandPath, .lines[1][0].preserveColors, .flexMode' \
        "$XDG_CONFIG_HOME/ccstatusline/settings.json"
    [ "${lines[0]}" = '[["model","separator","git-branch"],["custom-command"],[]]' ]
    [ "${lines[1]}" = "\"$LB\"" ]
    [ "${lines[2]}" = true ]
    [ "${lines[3]}" = '"full-minus-40"' ]
    ls "$XDG_CONFIG_HOME/ccstatusline/settings.json.bak."*
    run "$LB" ccstatusline
    [[ $output == ok:* ]]
}
