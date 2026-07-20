#!/usr/bin/env bats
# Tests for scripts/cto-nightly-driver.sh — the deterministic overnight
# supervisor for the nightly CTO issue-fixer's open PR.
#
# PATH-shadows `gh`, `openclaw`, and `muso` (the slack-notify.sh lib's send
# path) so the suite NEVER touches GitHub, the gateway, or Slack for real
# (memory: bats must stub openclaw/gh — an unstubbed test once fired real
# writes to prod).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/cto-nightly-driver.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"

  export CTO_NIGHTLY_STATE_DIR="$TEST_TMPDIR/state"
  mkdir -p "$CTO_NIGHTLY_STATE_DIR"
  STATE_FILE="$CTO_NIGHTLY_STATE_DIR/current.json"

  # Pin the maintenance flag to an absent tmp path so a REAL window on the CI
  # host can never leak into these tests (absent flag = not active).
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/maintenance-flag.json"

  export STUB_GH_ARGV="$TEST_TMPDIR/gh-argv"; : > "$STUB_GH_ARGV"
  export STUB_OPENCLAW_ARGV="$TEST_TMPDIR/openclaw-argv"; : > "$STUB_OPENCLAW_ARGV"
  export STUB_OPENCLAW_CALLS="$TEST_TMPDIR/openclaw-calls"; : > "$STUB_OPENCLAW_CALLS"
  export STUB_MUSO_ARGV="$TEST_TMPDIR/muso-argv"; : > "$STUB_MUSO_ARGV"

  export STUB_PR_JSON="$TEST_TMPDIR/pr.json"
  export STUB_THREADS_JSON="$TEST_TMPDIR/threads.json"
  export STUB_RUN_LIST_JSON="$TEST_TMPDIR/runlist.json"
  export STUB_CRON_LIST_JSON="$TEST_TMPDIR/cronlist.json"
  echo '{"jobs":[]}' > "$STUB_CRON_LIST_JSON"

  export STUB_PR_VIEW_FAIL=""
  export STUB_GRAPHQL_FAIL=""
  export STUB_CRON_ADD_FAIL=""
  export STUB_CRON_LIST_FAIL=""
  export STUB_SLACK_FAIL=""

  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ -n "${STUB_PR_VIEW_FAIL:-}" ]; then
    echo "stub: gh pr view transport error" >&2
    exit 1
  fi
  cat "$STUB_PR_JSON"
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if [ -n "${STUB_GRAPHQL_FAIL:-}" ]; then
    echo "stub: gh api graphql transport error" >&2
    exit 1
  fi
  cat "$STUB_THREADS_JSON"
  exit 0
fi

if [ "$1" = "run" ] && [ "$2" = "list" ]; then
  cat "$STUB_RUN_LIST_JSON"
  exit 0
fi

if [ "$1" = "run" ] && [ "$2" = "rerun" ]; then
  echo "run-rerun $3" >> "$STUB_OPENCLAW_CALLS"
  exit 0
fi

echo "stub gh: unhandled invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUBBIN/gh"

  cat > "$STUBBIN/openclaw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_OPENCLAW_ARGV"
sub=""
prev=""
for a in "$@"; do
  if [ "$prev" = "cron" ]; then sub="$a"; break; fi
  prev="$a"
done
case "$sub" in
  add)
    if [ -n "${STUB_CRON_ADD_FAIL:-}" ]; then
      echo "stub: cron add failed" >&2
      exit 1
    fi
    echo "cron-add" >> "$STUB_OPENCLAW_CALLS"
    echo '{"ok":true}'
    ;;
  list)
    if [ -n "${STUB_CRON_LIST_FAIL:-}" ]; then
      echo "stub: cron list failed" >&2
      exit 1
    fi
    cat "$STUB_CRON_LIST_JSON"
    ;;
  rm) echo "cron-rm $*" >> "$STUB_OPENCLAW_CALLS" ;;
esac
STUB
  chmod +x "$STUBBIN/openclaw"

  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_MUSO_ARGV"
if [ -n "${STUB_SLACK_FAIL:-}" ]; then
  exit 1
fi
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  chmod +x "$STUBBIN/muso"

  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_CTO=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  unset MUSO_SLACK_BOT_TOKEN_CTO

  PATH="$STUBBIN:$PATH"; export PATH
  export GH="gh" OPENCLAW="openclaw" MUSO_BIN="muso"

  NOW=1781222400   # fixed "now" — 2026-06-12T00:00:00Z
  export CTO_NIGHTLY_NOW="$NOW"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

write_state() {  # write_state <fix_turns> [opened_at_iso]
  local fix_turns="$1" opened_at="${2:-2026-06-12T00:00:00Z}"
  cat > "$STATE_FILE" <<JSON
{"issue":42,"pr":100,"journey_ts":"1717000000.000100","fix_turns":${fix_turns},"opened_at":"${opened_at}"}
JSON
}

pr_json() {  # pr_json <state> <mergeable> <checks-json-array>
  local state="$1" mergeable="$2" checks="$3"
  cat > "$STUB_PR_JSON" <<JSON
{"state":"${state}","mergeable":"${mergeable}","headRefOid":"abc1234abc1234abc1234abc1234abc1234abc1","statusCheckRollup":${checks}}
JSON
}

threads_json() {  # threads_json <nodes-json-array>
  cat > "$STUB_THREADS_JSON" <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":${1}}}}}}
JSON
}

# Real gh statusCheckRollup shapes (verified live): CheckRun rows carry
# status/conclusion/completedAt + name; the qa-review row is a StatusContext
# carrying state + context (and NO completedAt). completedAt is 10 min before
# the fixed NOW so the recover path never misfires in green fixtures.
green_checks='[{"__typename":"CheckRun","name":"ci-1","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-11T23:50:00Z"},{"__typename":"StatusContext","context":"qa-review","state":"SUCCESS"}]'
pending_check='[{"__typename":"CheckRun","name":"ci-1","status":"IN_PROGRESS","conclusion":"","completedAt":null}]'

@test "(1) no state file -> exit 0, no dispatch" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  [ ! -s "$STUB_GH_ARGV" ]
}

@test "(2) unparseable state -> exit 1 loud" {
  echo 'not json' > "$STATE_FILE"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -f "$STATE_FILE" ]
  [[ "$stderr" == *"unparseable"* ]]
}

@test "(3) PR merged -> wrap-up post + state cleared" {
  write_state 0
  pr_json "MERGED" "UNKNOWN" '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_FILE" ]
  grep -q '1717000000.000100' "$STUB_MUSO_ARGV"
  grep -qi 'merged' "$STUB_MUSO_ARGV"
}

@test "(4) stop-state met -> final post with mention + state cleared" {
  write_state 1
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_FILE" ]
  grep -q 'U0AL36NADEY' "$STUB_MUSO_ARGV"
  grep -q '1717000000.000100' "$STUB_MUSO_ARGV"
  # the journey thread lives in #cto-nightly — NOT slack-notify.sh's
  # #clio_devops default (regression guard: SLACK_CHANNEL must be pinned
  # before the lib is sourced)
  grep -q 'C0BJ5JBH4P3' "$STUB_MUSO_ARGV"
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
}

@test "(5) stop-state met but slack post fails -> state NOT cleared" {
  write_state 1
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[]'
  export STUB_SLACK_FAIL=1
  run "$SCRIPT"
  [ -f "$STATE_FILE" ]
}

@test "(6) unresolved red thread + fix_turns 0 -> exactly one dispatch, fix_turns becomes 1" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_OPENCLAW_CALLS")" -eq 1 ]
  [ -f "$STATE_FILE" ]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "1" ]
  grep -q 'FIX PASS' "$STUB_OPENCLAW_ARGV"
}

@test "(7) delta at fix_turns==MAX -> blocked post + state cleared + no dispatch" {
  write_state 3
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 still broken","author":{"login":"adk47"}}]}}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_FILE" ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  grep -qi 'pausing' "$STUB_MUSO_ARGV"
  run ! grep -q 'U0AL36NADEY' "$STUB_MUSO_ARGV"
}

@test "(8) CI pending, no findings -> exit 0, no dispatch" {
  write_state 0
  pr_json "OPEN" "UNKNOWN" "$pending_check"
  threads_json '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  [ ! -s "$STUB_MUSO_ARGV" ]
  [ -f "$STATE_FILE" ]
}

@test "(9) empty check rollup -> NOT treated as green (no final post)" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" '[]'
  threads_json '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$STATE_FILE" ]
  run ! grep -q 'U0AL36NADEY' "$STUB_MUSO_ARGV"
}

@test "(10) missing qa-review after CI done +30min -> gh run rerun called, no agent dispatch" {
  write_state 0 "2026-06-11T23:00:00Z"
  pr_json "OPEN" "MERGEABLE" '[{"__typename":"CheckRun","name":"ci-1","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-11T23:00:00Z"}]'
  threads_json '[]'
  cat > "$STUB_RUN_LIST_JSON" <<'JSON'
[{"databaseId":555,"status":"completed","conclusion":"success"}]
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'run-rerun 555' "$STUB_OPENCLAW_CALLS"
  # the sweep (cron list) runs every tick, but no FIX PASS agent dispatch.
  [ "$(grep -c '^cron-add$' "$STUB_OPENCLAW_CALLS")" -eq 0 ]
  [ -f "$STATE_FILE" ]
}

@test "(11) gh read failure -> exit 1, state intact" {
  write_state 0
  export STUB_PR_VIEW_FAIL=1
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -f "$STATE_FILE" ]
}

@test "(12) stale fixpass cron sweep removes only >6h jobs" {
  write_state 0
  pr_json "OPEN" "UNKNOWN" "$pending_check"
  threads_json '[]'
  now_ms=$(( CTO_NIGHTLY_NOW * 1000 ))
  stale_ms=$(( now_ms - 7*3600*1000 ))
  fresh_ms=$(( now_ms - 3600*1000 ))
  cat > "$STUB_CRON_LIST_JSON" <<JSON
{"jobs":[
  {"id":"STALEFIX","name":"cto-nightly-fixpass-1","createdAtMs":$stale_ms},
  {"id":"FRESHFIX","name":"cto-nightly-fixpass-2","createdAtMs":$fresh_ms},
  {"id":"OTHERCRON","name":"some-other-cron","createdAtMs":$stale_ms}
]}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'STALEFIX' "$STUB_OPENCLAW_ARGV"
  run ! grep -q 'FRESHFIX' "$STUB_OPENCLAW_ARGV"
  run ! grep -q 'OTHERCRON' "$STUB_OPENCLAW_ARGV"
}

@test "(13) active maintenance window -> stand down: exit 0, no dispatch, state intact" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" '[{"__typename":"CheckRun","name":"ci-1","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-06-11T23:50:00Z"}]'
  threads_json '[]'
  # unexpired flag = active window (same shape hydra-maintenance.sh writes)
  jq -n --argjson exp "$(( $(date -u +%s) + 3600 ))" \
    '{reason:"test window", operator:"tester@hydra-ops", expires_epoch:$exp}' \
    > "$HYDRA_MAINTENANCE_FLAG"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance"* ]]
  [ -f "$STATE_FILE" ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  [ ! -s "$STUB_MUSO_ARGV" ]
}

@test "(14) cron add dispatch failure -> fix_turns still incremented, warning threaded, exit 0" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  export STUB_CRON_ADD_FAIL=1
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  # round is recorded BEFORE dispatch (accepted lost round, never double-dispatch)
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "1" ]
  [[ "$stderr" == *"dispatch failed"* ]]
  grep -q 'Could not dispatch' "$STUB_MUSO_ARGV"
}

@test "(15) ACTION_REQUIRED conclusion is red (complement rule) -> delta -> dispatch" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" '[{"__typename":"CheckRun","name":"ci-1","status":"COMPLETED","conclusion":"ACTION_REQUIRED","completedAt":"2026-06-11T23:50:00Z"},{"__typename":"StatusContext","context":"qa-review","state":"SUCCESS"}]'
  threads_json '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_OPENCLAW_CALLS")" -eq 1 ]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "1" ]
}

@test "(16) fresh fixpass job in flight -> delta does NOT dispatch (clone race guard)" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  now_ms=$(( CTO_NIGHTLY_NOW * 1000 ))
  fresh_ms=$(( now_ms - 600000 ))   # 10 min old — in flight
  cat > "$STUB_CRON_LIST_JSON" <<JSON
{"jobs":[{"id":"INFLIGHT","name":"cto-nightly-fixpass-9","createdAtMs":$fresh_ms}]}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run ! grep -q '^cron-add$' "$STUB_OPENCLAW_CALLS"
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "0" ]
}

@test "(17) CI done recently + qa-review absent -> NOT a dead dispatch (no rerun, no dispatch)" {
  write_state 0
  # completedAt 10 min before NOW — QA review is still in its window
  pr_json "OPEN" "MERGEABLE" '[{"__typename":"CheckRun","name":"ci-1","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-11T23:50:00Z"}]'
  threads_json '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  [ -f "$STATE_FILE" ]
}

@test "(18) fresh fixpass job with lastStatus=error is NOT in flight -> dispatch proceeds" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  now_ms=$(( CTO_NIGHTLY_NOW * 1000 ))
  failed_ms=$(( now_ms - 600000 ))   # 10 min old but FAILED — must not block the night
  cat > "$STUB_CRON_LIST_JSON" <<JSON
{"jobs":[{"id":"DEADFIX","name":"cto-nightly-fixpass-8","createdAtMs":$failed_ms,"state":{"lastStatus":"error","consecutiveErrors":1}}]}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_OPENCLAW_CALLS")" -eq 1 ]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "1" ]
}

@test "(19) cron list failure -> in-flight UNKNOWN -> fail safe: no dispatch, round not burned" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  export STUB_CRON_LIST_FAIL=1
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  # assert on $stderr BEFORE any further `run` — run resets $stderr
  [[ "$stderr" == *"treating fix-pass state as in-flight"* ]]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "0" ]
  run ! grep -q '^cron-add$' "$STUB_OPENCLAW_CALLS"
}

@test "(20) cron list succeeds with malformed JSON -> in-flight UNKNOWN -> no dispatch" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  echo 'not json at all' > "$STUB_CRON_LIST_JSON"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"unexpected shape"* ]]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "0" ]
  run ! grep -q '^cron-add$' "$STUB_OPENCLAW_CALLS"
}

@test "(21) state replaced mid-tick (new night) -> CAS drops the write, no dispatch, new state intact" {
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[{"isResolved":false,"comments":{"nodes":[{"body":"🔴 real bug here","author":{"login":"adk47"}}]}}]'
  # Simulate the OPEN turn replacing current.json between this tick's read and
  # its write: the gh stub is the last read before the increment path, so swap
  # the state under the script via a wrapper that rewrites it on 'api graphql'.
  cat > "$STUBBIN/gh" <<'SWAP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then cat "$STUB_PR_JSON"; exit 0; fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  # a NEW night's OPEN turn lands while this tick is mid-flight
  echo '{"issue":77,"pr":200,"journey_ts":"1717999999.000200","fix_turns":0,"opened_at":"2026-06-12T00:00:00Z"}' > "$CTO_NIGHTLY_STATE_DIR/current.json"
  cat "$STUB_THREADS_JSON"; exit 0
fi
if [ "$1" = "run" ]; then echo "[]"; exit 0; fi
exit 1
SWAP
  chmod +x "$STUBBIN/gh"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"replaced mid-tick"* ]]
  [ "$(jq -r '.pr' "$STATE_FILE")" = "200" ]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "0" ]
  run ! grep -q '^cron-add$' "$STUB_OPENCLAW_CALLS"
}

@test "(22) state lock held by another process -> tick refuses loud, no reads, no dispatch" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host (Linux-only serialization; CAS guards still covered)"
  write_state 0
  pr_json "OPEN" "MERGEABLE" "$green_checks"
  threads_json '[]'
  # hold the exclusive lock from a background process for longer than the
  # driver's 30s acquisition window is NOT viable in a test — instead hold it
  # and rely on the driver's flock -w timeout by shrinking the wait via a
  # subshell race: acquire first, run driver, assert it dies on the lock.
  exec 7>"$CTO_NIGHTLY_STATE_DIR/.lock"
  flock 7
  # driver must give up after -w 30 … too slow for a test; run it with a
  # 5s timeout and accept either its own exit-1 or the timeout kill — both
  # prove it did NOT proceed to dispatch while the lock was held.
  run timeout 5 "$SCRIPT"
  exec 7>&-
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  [ "$(jq -r '.fix_turns' "$STATE_FILE")" = "0" ]
}
