#!/usr/bin/env bash
# tests/fm-fleet-stall-check.test.sh - the fleet-stall watcher check must wake
# firstmate when several live workers stall on the model gateway at once, page
# the captain when it persists, and report the local gateway's own health. The
# incident this pins: on 2026-10-18 fifteen workers sat dead for five hours on
# "503 ... auth_unavailable: no auth available ... Refresh token expired" and
# nothing woke firstmate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-fleet-stall-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-stall)

PI_503='Error: 503 {"type":"error","error":{"type":"api_error","message":"auth_unavailable: no auth available (providers=claude, model=claude-opus-5-5; last upstream error: Refresh token expired)"}}'

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/caps" "$home/fakebin" "$home/auth/logs"
  # The current-state reader answers from <home>/crew/<id>, else unknown.
  cat > "$home/fakebin/fake-crew-state" <<SH
#!/usr/bin/env bash
if [ -f "$home/crew/\$1" ]; then cat "$home/crew/\$1"; else printf 'state: unknown · source: none · fixture\n'; fi
SH
  chmod +x "$home/fakebin/fake-crew-state"
  mkdir -p "$home/crew"
  # No macOS banner from a test run; record that one was asked for instead.
  cat > "$home/fakebin/osascript" <<SH
#!/usr/bin/env bash
printf 'notified\n' >> "$home/notified"
SH
  chmod +x "$home/fakebin/osascript"
  printf '%s\n' "$home"
}

# worker <home> <id> <busy> <pane-text>
worker() {
  printf '%s\n' "$4" > "$1/caps/$2.cap"
  printf '%s\n' "$3" > "$1/caps/$2.busy"
}

pi_pane() {  # <body-line> <footer-tokens>
  printf '%s\n' \
    ' working on the task' \
    "$1" \
    '────────────────────────────────' \
    'orca/workspaces/x/fm-task (fm/task)' \
    "$2 R348M CH100.0% 43.7%/1.0M (auto)      (token-pool) claude"
}

# poll <home> <now> [extra env...]: run the check with the gateway probe pointed
# at the home's own fixtures, defaulting to a port nothing listens on.
poll() {
  local home=$1 now=$2
  shift 2
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FLEET_STALL_CAPTURE_DIR="$home/caps" \
    FM_FLEET_STALL_NOW="$now" FM_FLEET_STALL_PROXY_URL="http://127.0.0.1:9/" \
    FM_FLEET_STALL_CREW_STATE_BIN="$home/fakebin/fake-crew-state" \
    FM_FLEET_STALL_PROXY_AUTH_DIR="$home/no-inventory" \
    FM_FLEET_STALL_CCFLARE_DB="$home/no-ccflare.db" FM_FLEET_STALL_ACCESS_SYNC_LOG="$home/no-sync.log" \
    "$@" "$CHECK" check 2>&1
}

test_three_workers_on_a_gateway_error_wake_then_page_then_recover() {
  local home out
  home=$(make_home gateway-episode)
  printf 'FM_FLEET_STALL_PAGE_CMD=cat > "%s/paged"\n' "$home" > "$home/config/fleet-stall.env"
  worker "$home" w1 idle "$(pi_pane "$PI_503" '↑8.9M ↓786k')"
  worker "$home" w2 idle "$(pi_pane "$PI_503" '↑1.2M ↓100k')"
  worker "$home" w3 idle "$(pi_pane "$PI_503" '↑3.0M ↓9k')"
  worker "$home" w4 idle "$(pi_pane ' finished its turn cleanly' '↑5.0M ↓1k')"
  out=$(poll "$home" 10000)
  [ -z "$out" ] || fail "a gateway error seen on one poll already woke firstmate: $out"
  out=$(poll "$home" 10300)
  assert_contains "$out" "FLEET-STALL 3 of 4 live workers stalled" "three stalled workers did not open an episode"
  assert_contains "$out" "w1 (gateway-error: Error: 503" "the stall line did not name the worker and its error"
  assert_contains "$out" "auth_unavailable" "the stall line did not carry the gateway's own message"
  assert_contains "$out" "the captain is paged if it holds 15m" "the onset did not say when the captain is paged"
  assert_not_contains "$out" "w4" "a healthy idle worker was counted as stalled"
  out=$(poll "$home" 10600)
  [ -z "$out" ] || fail "a held episode printed again before its page or reminder: $out"
  [ ! -e "$home/paged" ] || fail "the captain was paged before the episode had held 15 minutes"
  out=$(poll "$home" 11200)
  assert_contains "$out" "FLEET-STALL paged the captain after 15m" "a 15-minute episode did not page"
  assert_present "$home/paged" "the page command did not run"
  assert_contains "$(cat "$home/paged")" "3 workers have been stuck for 15m (w1, w2, w3)" "the page text did not say what is stuck"
  # The notification is detached so the poll never waits on it; give it a moment.
  local i=0
  while [ ! -s "$home/notified" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  assert_present "$home/notified" "the page did not post a macOS notification"
  rm -f "$home/paged"
  out=$(poll "$home" 11500)
  [ -z "$out" ] || fail "the paged episode printed again: $out"
  [ ! -e "$home/paged" ] || fail "the captain was paged twice for one episode"
  worker "$home" w1 busy "$(pi_pane ' back at work' '↑9.0M ↓800k')"
  worker "$home" w2 busy "$(pi_pane ' back at work' '↑1.3M ↓110k')"
  out=$(poll "$home" 11800)
  assert_contains "$out" "FLEET-STALL recovered after 25m: 1 of 4 live workers still stalled" \
    "the episode did not report its recovery"
  pass "three workers on a gateway error wake firstmate on the second poll, page once at 15 minutes, and recover"
}

test_below_the_fleet_threshold_is_silent() {
  local home out
  home=$(make_home two-workers)
  worker "$home" w1 idle "$(pi_pane "$PI_503" '↑1M ↓1k')"
  worker "$home" w2 idle "$(pi_pane "$PI_503" '↑2M ↓2k')"
  worker "$home" w3 busy "$(pi_pane ' fine' '↑3M ↓3k')"
  poll "$home" 1000 >/dev/null
  out=$(poll "$home" 1300)
  [ -z "$out" ] || fail "two stalled workers opened a fleet episode: $out"
  out=$(poll "$home" 1600 FM_FLEET_STALL_MIN_WORKERS=2)
  assert_contains "$out" "FLEET-STALL 2 of 3 live workers stalled" "a configured lower threshold was not honored"
  pass "fewer stalled workers than the threshold stay silent, and the threshold is configurable"
}

test_prose_and_moving_panes_are_not_stalls() {
  local home out
  home=$(make_home prose)
  # Error words in prose, an error line whose text keeps changing, and a ticking
  # retry counter: only the counter is still a stall.
  worker "$home" p1 idle "$(pi_pane ' The 503 auth_unavailable refresh token incident is fixed.' '↑1M ↓1k')"
  worker "$home" p2 idle "$(pi_pane 'Error: 503 overloaded (first)' '↑2M ↓2k')"
  worker "$home" p3 busy "$(pi_pane 'Error: 529 overloaded - retrying in 5s (attempt 1/10)' '↑3M ↓3k')"
  poll "$home" 1000 FM_FLEET_STALL_MIN_WORKERS=1 >/dev/null
  worker "$home" p2 idle "$(pi_pane 'Error: 503 overloaded (second, different words)' '↑2M ↓2k')"
  worker "$home" p3 busy "$(pi_pane 'Error: 529 overloaded - retrying in 9s (attempt 2/10)' '↑3M ↓3k')"
  out=$(poll "$home" 1300 FM_FLEET_STALL_MIN_WORKERS=1)
  assert_contains "$out" "p3 (gateway-error" "a ticking retry counter broke the stall"
  assert_not_contains "$out" "p1" "an error sentence in prose was read as a stall"
  assert_not_contains "$out" "p2" "an error line whose text changed was read as the same stall"
  pass "prose mentions and changing error lines are not stalls, while a ticking retry counter is"
}

test_busy_without_token_movement_is_a_stall() {
  local home out
  home=$(make_home no-progress)
  worker "$home" n1 busy "$(pi_pane ' waiting' '↑1.0M ↓10k')"
  worker "$home" n2 busy "$(pi_pane ' waiting' '↑2.0M ↓20k')"
  worker "$home" n3 busy "$(pi_pane ' waiting' '↑3.0M ↓30k')"
  worker "$home" n4 idle "$(pi_pane ' done' '↑4.0M ↓40k')"
  worker "$home" n5 busy "$(pi_pane ' waiting' '↑5.0M ↓50k')"
  poll "$home" 1000 >/dev/null
  worker "$home" n5 busy "$(pi_pane ' waiting' '↑5.0M ↓51k')"
  out=$(poll "$home" 1600)
  [ -z "$out" ] || fail "ten minutes without movement was already a stall at the 15-minute default: $out"
  worker "$home" n5 busy "$(pi_pane ' waiting' '↑5.0M ↓52k')"
  out=$(poll "$home" 1900)
  assert_contains "$out" "FLEET-STALL 3 of 5 live workers stalled" "busy workers frozen for 15 minutes did not open an episode"
  assert_contains "$out" "n1 (no token movement for 15m while busy)" "the stall line did not give the no-progress reason"
  assert_not_contains "$out" "n4" "an idle worker was read as a busy one without progress"
  assert_not_contains "$out" "n5" "a worker whose token counter moves was read as stalled"
  pass "busy workers whose tokens and pane do not move for no_progress_secs are stalls; idle or moving ones are not"
}

# A local proxy the probe can reach, answering anything with 200.
start_proxy() {  # <home>
  local home=$1 i=0
  python3 - "$home/proxy.port" <<'PY' &
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"message":"CLI Proxy API Server"}')
    def log_message(self, *a): pass
s = socketserver.TCPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  PROXY_PID=$!
  while [ ! -s "$home/proxy.port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$home/proxy.port" ] || fail "the fixture proxy did not start"
}

auth_file() {  # <path> <expired-iso> [disabled]
  printf '{"type":"claude","refresh_token":"x","access_token":"y","disabled":%s,"expired":"%s","last_refresh":"2026-10-18T00:00:00Z"}\n' \
    "${3:-false}" "$2" > "$1"
}

log_line() {  # <epoch> <rest>
  printf '[%s] [0000] %s\n' "$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(sys.argv[1]))))' "$1")" "$2"
}

test_gateway_probe_reports_auth_errors_and_down() {
  local home out now port i
  home=$(make_home proxy)
  now=$(python3 -c 'import datetime; print(int(datetime.datetime(2026,10,18,12,0,tzinfo=datetime.timezone.utc).timestamp()))')
  start_proxy "$home"
  port=$(cat "$home/proxy.port")
  auth_file "$home/auth/claude-dead.json" 2026-10-18T11:00:00Z
  auth_file "$home/auth/claude-failing.json" 2026-10-18T12:20:00Z
  auth_file "$home/auth/claude-slow.json" 2026-10-18T12:25:00Z
  auth_file "$home/auth/claude-fine.json" 2026-10-18T18:00:00Z
  auth_file "$home/auth/claude-off.json" 2026-10-18T11:00:00Z true
  {
    log_line $((now - 60)) '[warn ] [conductor_refresh.go:585] credential refresh failed for claude (claude-failing.json): token refresh failed'
    i=0
    while [ "$i" -lt 40 ]; do
      log_line $((now - 30)) '[info ] [gin_logger.go:103] 503 |  1ms | 127.0.0.1 | POST "/v1/messages"'
      i=$((i + 1))
    done
    log_line $((now - 30)) '[info ] [gin_logger.go:103] 200 |  1ms | 127.0.0.1 | POST "/v1/messages"'
    log_line $((now - 900)) '[info ] [gin_logger.go:103] 200 |  1ms | 127.0.0.1 | POST "/v1/messages"'
  } > "$home/auth/logs/main.log"
  out=$(poll "$home" "$now" FM_FLEET_STALL_PROXY_URL="http://127.0.0.1:$port/" FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "gateway auth claude-dead expired 1h00m ago with no refresh" "an expired account was not reported"
  assert_contains "$out" "gateway auth claude-failing expires in 20m and its refresh is failing" "a failing refresh was not reported"
  assert_contains "$out" "gateway error rate 97% (40 of 41 requests in 5m were 5xx or 401)" "a high gateway error rate was not reported"
  assert_not_contains "$out" "claude-slow" "an account in its window was reported before the refresh grace passed"
  assert_not_contains "$out" "claude-fine" "an account far from expiry was reported"
  assert_not_contains "$out" "claude-off" "a disabled account was reported"
  assert_not_contains "$out" "gives no answer" "a reachable proxy was reported down"
  out=$(poll "$home" $((now + 900)) FM_FLEET_STALL_PROXY_URL="http://127.0.0.1:$port/" FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "gateway auth claude-slow expires in 10m and has not refreshed for 15m" \
    "an account that stayed in its window without refreshing was not reported"
  assert_contains "$out" "gateway recovered: errors" "the error rate leaving its window did not clear"
  assert_not_contains "$out" "claude-dead" "a held gateway condition was reported again"
  kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null
  out=$(poll "$home" $((now + 1200)) FM_FLEET_STALL_PROXY_URL="http://127.0.0.1:$port/" FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "gateway http://127.0.0.1:$port/ gives no answer" "a gateway with an inventory and no answer was not reported down"
  # The same unanswered URL on a home with no inventory runs no gateway at all.
  out=$(poll "$(make_home no-proxy)" "$now")
  [ -z "$out" ] || fail "a home with no gateway reported a gateway condition: $out"
  pass "the gateway probe reports expired, failing, and unrefreshed auth, a high error rate, and a gateway that does not answer"
}

# ccflare_db <path> <now> <name:expires-in-secs:requires_reauth:paused>...
ccflare_db() {
  local db=$1 now=$2 spec name left reauth paused
  shift 2
  sqlite3 "$db" "CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL, provider TEXT DEFAULT 'anthropic', expires_at INTEGER, requires_reauth INTEGER DEFAULT 0, paused INTEGER DEFAULT 0);"
  for spec in "$@"; do
    IFS=: read -r name left reauth paused <<< "$spec"
    sqlite3 "$db" "INSERT INTO accounts (id, name, expires_at, requires_reauth, paused) VALUES ('$name', '$name', $(( (now + left) * 1000 )), $reauth, $paused);"
  done
}

test_ccflare_owns_auth_health_when_present() {
  local home out now port
  home=$(make_home ccflare)
  now=$(python3 -c 'import datetime; print(int(datetime.datetime(2026,10,19,2,0,tzinfo=datetime.timezone.utc).timestamp()))')
  start_proxy "$home"
  port=$(cat "$home/proxy.port")
  # The 2026-10-19 false alarm: the inventory copy of brian expires in 27m and
  # CLIProxyAPI logs its own refresh failing, while ccflare (which owns refresh)
  # holds brian for 7.9h.
  auth_file "$home/auth/claude-brian_-_muso.json" 2026-10-19T02:27:00Z
  # An inventory file the access sync does not own keeps the file rule.
  auth_file "$home/auth/xai-other.json" 2026-10-19T01:00:00Z
  log_line $((now - 60)) '[warn ] [conductor_refresh.go:585] credential refresh failed for claude (claude-brian_-_muso.json): invalid_grant Refresh token expired' \
    > "$home/auth/logs/main.log"
  ccflare_db "$home/ccflare.db" "$now" brian_-_muso:28440:0:0 stale-me:-70000:1:0 soon:600:0:0 resting:-9000:1:1
  printf 'current brian_-_muso until later\ndone changed=0\n' > "$home/sync.log"
  : > "$home/sync.err"
  touch -t "$(python3 -c 'import sys,time; print(time.strftime("%Y%m%d%H%M.%S", time.localtime(int(sys.argv[1]))))' $((now - 60)))" "$home/sync.log" "$home/sync.err"
  set -- FM_FLEET_STALL_PROXY_URL="http://127.0.0.1:$port/" FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth" \
    FM_FLEET_STALL_CCFLARE_DB="$home/ccflare.db" FM_FLEET_STALL_ACCESS_SYNC_LOG="$home/sync.log"
  out=$(poll "$home" "$now" "$@")
  assert_not_contains "$out" "brian" "an inventory expiry or a CLIProxyAPI refresh warning was reported although ccflare owns refresh"
  assert_contains "$out" "gateway account stale-me needs re-authentication in better-ccflare" "a ccflare account needing re-authentication was not reported"
  assert_contains "$out" "gateway account soon expires in 10m in better-ccflare" "a ccflare account inside the expiry window was not reported"
  assert_not_contains "$out" "resting" "a paused ccflare account was reported"
  assert_contains "$out" "gateway auth xai-other expired 1h00m ago with no refresh" "an inventory file outside ccflare lost the file rule"
  assert_not_contains "$out" "access sync" "a fresh, error-free access sync was reported"
  # A failed sync run writes its error after the log.
  printf 'sync failed: RuntimeError: access token did not stick for brian_-_muso\n' > "$home/sync.err"
  touch -t "$(python3 -c 'import sys,time; print(time.strftime("%Y%m%d%H%M.%S", time.localtime(int(sys.argv[1]))))' $((now + 30)))" "$home/sync.err"
  out=$(poll "$home" $((now + 60)) "$@")
  assert_contains "$out" "ccflare access sync's last run failed: sync failed: RuntimeError: access token did not stick" "a failed access sync was not reported"
  # A sync that stopped running at all.
  out=$(poll "$home" $((now + 900)) "$@")
  assert_contains "$out" "ccflare access sync has not run for 16m" "a stopped access sync was not reported"
  # Every account unusable.
  sqlite3 "$home/ccflare.db" "UPDATE accounts SET paused = 1 WHERE requires_reauth = 0;"
  out=$(poll "$home" $((now + 960)) "$@")
  assert_contains "$out" "better-ccflare has no usable account" "a ccflare store with no usable account was not reported"
  kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null
  pass "when better-ccflare owns refresh, auth health comes from its store and the access sync, and CLIProxyAPI's refresh warnings are ignored"
}

test_stall_line_carries_the_gateway_cause_and_a_missing_page_command() {
  local home out
  home=$(make_home cause)
  mkdir -p "$home/auth"
  auth_file "$home/auth/claude-dead.json" 2026-01-01T00:00:00Z
  worker "$home" a idle "$(pi_pane "$PI_503" '↑1M ↓1k')"
  worker "$home" b idle "$(pi_pane "$PI_503" '↑2M ↓2k')"
  worker "$home" c idle "$(pi_pane "$PI_503" '↑3M ↓3k')"
  poll "$home" 1800000000 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth" >/dev/null
  out=$(poll "$home" 1800000300 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "likely cause: " "the stall line did not carry the gateway condition"
  assert_contains "$out" "gateway auth claude-dead expired" "the stall line's cause did not name the dead account"
  assert_contains "$out" "no FM_FLEET_STALL_PAGE_CMD in config/fleet-stall.env" "a missing page command was not stated"
  out=$(poll "$home" 1800001300 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "the captain page command did not run or failed" "an unconfigured page was reported as sent"
  pass "the stall line carries the gateway cause and says when no page command is configured"
}

# 2026-10-18: three "no token movement 23m while busy" stalls, two of them
# workers parked on a decision, while the gateway was fine; the line named an
# account that had expired hours earlier as the likely cause.
test_waiting_workers_are_not_stalled_and_old_auth_is_not_the_cause() {
  local home out
  home=$(make_home waiting)
  mkdir -p "$home/auth"
  auth_file "$home/auth/claude-old.json" 1970-01-01T00:05:00Z
  for w in v1 t02 r1 s1 s2 s3; do
    worker "$home" "$w" busy "$(pi_pane ' waiting' "↑1.0M ↓$w")"
  done
  # v1 is parked at a review gate; t02 declared a decision with a busy pane, so
  # its current-state reader says working; r1's pipeline is running.
  printf 'state: parked · source: run-step · awaiting_approval\n' > "$home/crew/v1"
  printf 'state: working · source: pane · harness busy (pi-ext)\n' > "$home/crew/t02"
  printf 'needs-decision [key=t02-scope]: which schema?\n' > "$home/state/t02.status"
  printf 'state: working · source: run-step · running review\n' > "$home/crew/r1"
  poll "$home" 1000 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth" >/dev/null
  out=$(poll "$home" 2400 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "FLEET-STALL 3 of 6 live workers stalled" "the three really stalled workers did not open an episode"
  assert_not_contains "$out" "v1 (" "a worker parked at a review gate was counted as stalled"
  assert_not_contains "$out" "t02 (" "a worker that declared a decision was counted as stalled"
  assert_not_contains "$out" "r1 (" "a worker waiting on its own running pipeline was counted as stalled"
  assert_not_contains "$out" "likely cause" "an old expired account was named as the cause of stalls with no gateway error"
  assert_contains "$(cat "$home/state/.fleet-stall.json")" "auth:claude-old" "the fixture's expired account was not observed at all"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FLEET_STALL_NOW=2400 "$CHECK" status)
  assert_contains "$out" "v1: quiet but waiting (current state parked), not counted" "status did not say why a parked worker was left out"
  assert_contains "$out" "t02: quiet but waiting (declared needs-decision), not counted" "status did not say why a declared wait was left out"
  # With all three waiting the episode ends, and a gateway error brings the
  # cause back.
  rm -f "$home/crew/s1"
  printf 'paused [key=await-ci]: waiting on CI\n' > "$home/state/s1.status"
  out=$(poll "$home" 2700 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "FLEET-STALL recovered" "a worker declaring a pause did not leave the stalled set"
  for w in g1 g2 g3; do worker "$home" "$w" idle "$(pi_pane "$PI_503" "↑2M ↓$w")"; done
  poll "$home" 3000 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth" >/dev/null
  out=$(poll "$home" 3300 FM_FLEET_STALL_PROXY_AUTH_DIR="$home/auth")
  assert_contains "$out" "likely cause: gateway auth claude-old expired" "a gateway error in the panes did not bring the gateway cause back"
  pass "parked, declared-waiting, and pipeline-owned workers are not stalls, and gateway conditions are a cause only when panes show gateway errors"
}

test_a_slow_current_state_reader_stays_inside_the_poll_budget() {
  local home out start secs
  home=$(make_home budget)
  for w in s1 s2 s3; do
    worker "$home" "$w" busy "$(pi_pane ' waiting' "↑1.0M ↓$w")"
  done
  # A current-state reader that hangs, as fm-crew-state does at Mac load.
  cat > "$home/fakebin/slow-crew-state" <<'SH'
#!/usr/bin/env bash
sleep 20
printf 'state: working · source: pane · slow\n'
SH
  chmod +x "$home/fakebin/slow-crew-state"
  poll "$home" 1000 FM_FLEET_STALL_CREW_STATE_BIN="$home/fakebin/slow-crew-state" >/dev/null
  start=$(date +%s)
  out=$(poll "$home" 2400 FM_FLEET_STALL_CREW_STATE_BIN="$home/fakebin/slow-crew-state" FM_CHECK_TIMEOUT=30)
  secs=$(( $(date +%s) - start ))
  [ "$secs" -le 10 ] || fail "the poll took ${secs}s with a hanging current-state reader; its budget is 15s of a 30s timeout and the reads get at most 4s"
  assert_contains "$out" "FLEET-STALL 3 of 3 live workers stalled" "a candidate whose state could not be read in time did not count as flagged"
  pass "a hanging current-state reader is cut off well inside the watcher's per-check timeout"
}

test_status_and_arm() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "no poll recorded yet" "status before any poll did not say so"
  worker "$home" a idle "$(pi_pane ' ok' '↑1M ↓1k')"
  poll "$home" 1000 >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FLEET_STALL_NOW=1060 "$CHECK" status)
  assert_contains "$out" "live workers: 1, stalled: 0" "status did not report the last poll"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/fleet-stall.check.sh" "arm wrote no shim"
  assert_present "$home/state/fleet-stall.check-trust" "arm bound no trust record"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/fleet-stall.check.sh" "disarm left the shim"
  assert_absent "$home/state/.fleet-stall.json" "disarm left the record"
  pass "status reports the last poll, and arm and disarm manage the registered shim"
}

# The live path: records whose Orca terminal is not listed cost no read, and the
# rest are read through the backend's own capture.
test_live_capture_skips_gone_orca_terminals() {
  local home out
  home=$(make_home live)
  cat > "$home/fakebin/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/orca.calls"
case "\$1 \$2" in
  'terminal list') printf '{"result":{"terminals":[{"handle":"term-live","lastOutputAt":"1"}]}}\n' ;;
  'terminal read') printf '{"result":{"terminal":{"tail":["Error: 503 overloaded_error","prompt"]}}}\n' ;;
esac
SH
  chmod +x "$home/fakebin/orca"
  printf 'backend=orca\nterminal=term-live\nharness=pi\nkind=ship\n' > "$home/state/live.meta"
  printf 'backend=orca\nterminal=term-gone\nharness=pi\nkind=ship\n' > "$home/state/gone.meta"
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FLEET_STALL_PROXY=off FM_FLEET_STALL_NOW=1000 "$CHECK" check 2>&1)
  [ -z "$out" ] || fail "a single live worker's first poll printed: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FLEET_STALL_NOW=1000 "$CHECK" status)
  assert_contains "$out" "live workers: 1," "the live capture did not count exactly the listed terminal"
  grep -q 'term-gone' "$home/orca.calls" && fail "a terminal Orca does not list was read"
  grep -q 'terminal read --terminal term-live' "$home/orca.calls" || fail "the listed terminal was not read"
  pass "the live capture reads listed Orca terminals and skips gone ones without a read"
}

test_three_workers_on_a_gateway_error_wake_then_page_then_recover
test_below_the_fleet_threshold_is_silent
test_prose_and_moving_panes_are_not_stalls
test_busy_without_token_movement_is_a_stall
test_gateway_probe_reports_auth_errors_and_down
test_ccflare_owns_auth_health_when_present
test_stall_line_carries_the_gateway_cause_and_a_missing_page_command
test_waiting_workers_are_not_stalled_and_old_auth_is_not_the_cause
test_a_slow_current_state_reader_stays_inside_the_poll_budget
test_status_and_arm
test_live_capture_skips_gone_orca_terminals
