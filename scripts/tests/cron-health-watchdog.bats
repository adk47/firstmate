#!/usr/bin/env bats
# Tests for scripts/cron-health-watchdog.sh — the cron-failure alerter
# added after the 2026-06 b2b-reply-scanner stacked 17 silent failures.
#
# PATH-shadows muso + ssh so a real Slack send / remote call during a test
# fails loudly instead of paging #clio_devops for real
# (see memory/feedback_bats_must_stub_openclaw.md). Behavioural assertions
# use --dry-run (never touches the network); the payload-escaping test runs
# the real post path against a stubbed muso that captures the argv + text.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/cron-health-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm this watchdog during CI (it runs on the live node-8 host). Pin the
  # flag at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  mkdir -p "$TEST_TMPDIR/runs" "$TEST_TMPDIR/bin"

  # Refuse real network: stub muso + ssh; never read the real main.env.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  # muso stub: record argv, capture --text / --blocks-file for inspection.
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--blocks-file" ] && cp "$a" "$TEST_TMPDIR/last-blocks" 2>/dev/null
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  prev="$a"
done
# concurrent-producer seam: a second unit failure SPOOLED during delivery
[ -n "${STUB_MUSO_SPOOL_NEW:-}" ] && printf 'during-delivery\tcodex-edge-mirror.service\tSECOND failure spooled during delivery\n' > "$STUB_MUSO_SPOOL_NEW"
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
exit "${STUB_MUSO_RC:-0}"
STUB
  # flock shim: macOS has no flock(1); use the real one when present (Linux CI)
  # so single-run locking still behaves, otherwise no-op so real-run tests work.
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
for _f in /usr/bin/flock /opt/homebrew/bin/flock; do [ -x "$_f" ] && exec "$_f" "$@"; done
exit 0
STUB
  # mv stub: a storage-failure seam for the spool consumer — fails when the
  # DESTINATION matches STUB_MV_FAIL_PATTERN, otherwise the real mv. (root on
  # CI ignores permission bits, and mv onto a directory moves INTO it, so a
  # filesystem trick cannot force a deterministic rename failure.)
  cat > "$TEST_TMPDIR/bin/mv" <<'STUB'
#!/bin/bash
dest="${@: -1}"
if [ -n "${STUB_MV_FAIL_PATTERN:-}" ] && [[ "$dest" =~ $STUB_MV_FAIL_PATTERN ]]; then echo "mv: stubbed failure for $dest" >&2; exit 1; fi
exec /bin/mv "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock" "$TEST_TMPDIR/bin/mv"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # jobs.json id->name/agent map shared by most tests.
  printf '%s\n' '{"jobs":[{"id":"jobA","name":"daily-churned-campaign-refresh","agentId":"cmo"},{"id":"jobB","name":"company-finder-daily","agentId":"cmo"}]}' \
    > "$TEST_TMPDIR/jobs.json"

  export CRON_HEALTH_RUNS_DIR="$TEST_TMPDIR/runs"
  export CRON_HEALTH_JOBS_FILE="$TEST_TMPDIR/jobs.json"

  # Hermeticity for the session-budget headroom block: CI runs on the LIVE
  # node-8 host, where /root/.openclaw-main really exists. Left at its default
  # the block would query the live gateway and — worse — stamp the PRODUCTION
  # dedupe file, silently suppressing a real page for 6h. Disarm it by default
  # (absent path → the `[ -x ]` guard skips it) and sandbox the state file; the
  # tests that exercise the block point CRON_HEALTH_SESSION_BUDGET_CHECK at
  # their own stub.
  export CRON_HEALTH_SESSION_BUDGET_CHECK="$TEST_TMPDIR/no-session-budget-check"
  export CRON_HEALTH_SESSION_BUDGET_STATE="$TEST_TMPDIR/session-budget-last-alert"
  # Same hermeticity rule for the agent exec-posture block: CI runs on the LIVE node-8 host, where
  # /opt/hydra/scripts/check-agent-exec-policy.py and /root/.openclaw-*/openclaw.json really exist. Left at its
  # default the block would read the live posture every test AND stamp the production 24h dedupe file, silencing a
  # real page. Disarm by default with the EXPLICIT empty seam (an absent non-empty path is no longer a skip — it
  # pages as "checker MISSING", which is the point of the missing-checker test below); the tests that exercise the
  # block install their own stub.
  export CRON_HEALTH_EXEC_POLICY_CHECK=""
  export CRON_HEALTH_EXEC_POLICY_STATE="$TEST_TMPDIR/exec-policy-last-alert"
  # Hermeticity: never scan the LIVE /var/lib/hydra/unit-failed-unpaged on CI.
  export CRON_HEALTH_UNIT_FAILED_MARKER_DIR="$TEST_TMPDIR/unit-failed-unpaged"
  export CRON_HEALTH_STATE_FILE="$TEST_TMPDIR/state.json"
  export CRON_HEALTH_LOCKFILE="$TEST_TMPDIR/wd.lock"
  export CRON_HEALTH_SKIP_HOST_GUARD=1
  # Force the legacy JSONL source for the detector tests below (they inject runs
  # via runfile()). Without this the script defaults CRON_RUNS_DB to the live
  # /root/.openclaw-main/state/openclaw.sqlite — which EXISTS on the node-8 CI
  # runner — and would read real run logs instead of the fixtures. The 6.x
  # SQLite source has its own dedicated tests at the end of this file.
  export CRON_HEALTH_RUNS_DB=""
  # Most tests below exercise streak-INDEPENDENT mechanics (detection, dedup,
  # backlog seeding, JSON escaping) and predate the consecutive-error streak
  # gate, so they run at threshold 1 (alert on every error, the pre-gate
  # behaviour). The streak gate and the delivered-despite-error rule have their
  # own dedicated tests at the end that set the threshold explicitly.
  export CRON_HEALTH_MIN_STREAK=1
}

teardown() { if [ -n "${LOCK_HOLDER_PID:-}" ]; then pkill -P "$LOCK_HOLDER_PID" 2>/dev/null; kill "$LOCK_HOLDER_PID" 2>/dev/null; fi; rm -rf "$TEST_TMPDIR"; }

# Helper: write a runs file from stdin lines.
runfile() { cat > "$TEST_TMPDIR/runs/$1.jsonl"; }

# Helper: build a 6.x cron_run_logs SQLite DB. Args: <db> <store_key>. Reads one
# JSON record per stdin line; each record's "_jobId" field becomes the row's
# job_id and the rest becomes entry_json (mirrors the real table shape).
mkrunsdb() {
  # Capture the piped records to a file FIRST — `python3 - <<'PY'` claims stdin
  # for the script itself, so the records must reach python via argv, not stdin.
  local recfile; recfile="$(mktemp)"
  cat > "$recfile"
  python3 - "$1" "$2" "$recfile" <<'PY'
import sqlite3, json, sys
con = sqlite3.connect(sys.argv[1]); sk = sys.argv[2]
con.execute("CREATE TABLE cron_run_logs (store_key TEXT, job_id TEXT, seq INTEGER, entry_json TEXT)")
seq = {}
with open(sys.argv[3]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line); jid = rec.pop("_jobId")
        seq[jid] = seq.get(jid, 0) + 1
        con.execute("INSERT INTO cron_run_logs VALUES (?,?,?,?)", (sk, jid, seq[jid], json.dumps(rec)))
con.commit(); con.close()
PY
  rm -f "$recfile"
}

@test "no runs at all → reports OK, no alert, exits 0" {
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "new error past the watermark → alerts with job name + agent" {
  runfile jobA <<'EOF'
{"status":"ok","ts":1000}
{"status":"error","ts":2000,"error":"trino-query.sh failed"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cron failure(s) detected"* ]]
  [[ "$output" == *"daily-churned-campaign-refresh"* ]]
  [[ "$output" == *"(cmo)"* ]]
  [[ "$output" == *"trino-query.sh failed"* ]]
}

@test "ok-only runs newer than watermark → no alert" {
  runfile jobA <<'EOF'
{"status":"ok","ts":3000}
{"status":"ok","ts":4000}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "brand-new job with historical errors → seeded, NOT paged (no backlog storm)" {
  runfile jobB <<'EOF'
{"status":"error","ts":100}
{"status":"error","ts":200}
EOF
  # no state file → jobB is first-sight
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
  # watermark seeded to the latest seen ts so future errors DO alert
  run cat "$CRON_HEALTH_STATE_FILE"
  [[ "$output" == *'"jobB": 200'* ]]
}

@test "dedupe: a failure alerts once, not again on the next tick" {
  runfile jobA <<'EOF'
{"status":"error","ts":2000,"error":"boom"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [[ "$output" == *"boom"* ]]            # first tick alerts
  run bash "$WD" --dry-run
  [[ "$output" == *"no new cron failures"* ]]  # second tick is quiet
}

@test "a seeded job that later errors DOES alert" {
  runfile jobB <<'EOF'
{"status":"ok","ts":100}
EOF
  run bash "$WD" --dry-run          # seeds jobB at 100, no alert
  [[ "$output" == *"no new cron failures"* ]]
  printf '%s\n' '{"status":"error","ts":9000,"error":"second failure"}' >> "$TEST_TMPDIR/runs/jobB.jsonl"
  run bash "$WD" --dry-run
  [[ "$output" == *"company-finder-daily"* ]]
  [[ "$output" == *"second failure"* ]]
}

@test "unknown flag → exit 2" {
  run bash "$WD" --bogus
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────────────────────
# Consecutive-error streak gate + delivered-despite-error rule.
# These suppress the recovered-blip false alarms (openclaw flags a whole run
# "error" on any recovered tool error) while still paging on sustained breakage.
# ──────────────────────────────────────────────────────────────

@test "streak gate (default 2): a single fresh error does NOT alert" {
  unset CRON_HEALTH_MIN_STREAK   # exercise the production default (2)
  runfile jobA <<'EOF'
{"status":"ok","ts":1000}
{"status":"error","ts":2000,"error":"transient blip"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "streak gate: a lone error bracketed by ok runs → no alert (recovered blip)" {
  export CRON_HEALTH_MIN_STREAK=2
  runfile jobA <<'EOF'
{"status":"ok","ts":1000}
{"status":"error","ts":2000,"error":"guessed --body, recovered"}
{"status":"ok","ts":3000}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "streak gate: two consecutive errors → alerts (sustained breakage)" {
  export CRON_HEALTH_MIN_STREAK=2
  runfile jobA <<'EOF'
{"status":"ok","ts":1000}
{"status":"error","ts":1900,"error":"first failure"}
{"status":"error","ts":2000,"error":"second failure"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cron failure(s) detected"* ]]
  [[ "$output" == *"daily-churned-campaign-refresh"* ]]
}

@test "streak gate: only the streak-completing run fires (lone earlier error suppressed)" {
  export CRON_HEALTH_MIN_STREAK=2
  runfile jobA <<'EOF'
{"status":"ok","ts":1000}
{"status":"error","ts":1900,"error":"first failure"}
{"status":"error","ts":2000,"error":"second failure"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  bullets="$(printf '%s\n' "$output" | grep -c '^• ' || true)"
  [ "$bullets" -eq 1 ]
  [[ "$output" == *"second failure"* ]]
  [[ "$output" != *"first failure"* ]]
}

@test "delivered-despite-error: an errored run that delivered its output → no alert" {
  export CRON_HEALTH_MIN_STREAK=1   # isolate the delivered rule from the streak gate
  runfile jobA <<'EOF'
{"status":"error","ts":2000,"error":"trailing tool error","delivered":true}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "delivered-despite-error breaks the streak: ok, delivered-error, error → no alert" {
  export CRON_HEALTH_MIN_STREAK=2
  runfile jobA <<'EOF'
{"status":"error","ts":1900,"error":"delivered anyway","deliveryStatus":"delivered"}
{"status":"error","ts":2000,"error":"real failure"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  # The delivered run at 1900 is healthy → streak resets → the real error at 2000
  # is only streak length 1 → suppressed.
  [[ "$output" == *"no new cron failures"* ]]
}

# ──────────────────────────────────────────────────────────────
# Message-tool delivery rule. Under the codex runtime an agent that posts its
# report to Slack via the `message` tool is NOT credited as the cron delivery
# (record stays delivered:false / not-delivered), and a trailing non-fatal tool
# error flips the run to status:error — so a healthy self-posting cron
# (daily-dispute-handler) false-pages every day. A non-empty
# delivery.messageToolSentTo is the source-backed proof the agent reached Slack
# (openclaw only records a target there after a successful send).
# ──────────────────────────────────────────────────────────────

@test "message-tool delivery: an errored run that self-posted via the message tool → no alert" {
  export CRON_HEALTH_MIN_STREAK=1   # isolate the message-tool rule from the streak gate
  runfile jobA <<'EOF'
{"status":"error","ts":2000,"error":"⚠️ 🛠️ `stripe subscriptions list ...` failed","delivered":false,"deliveryStatus":"not-delivered","delivery":{"messageToolSentTo":[{"channel":"message"}]}}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "message-tool rule is tight: errored run with EMPTY messageToolSentTo still alerts" {
  export CRON_HEALTH_MIN_STREAK=1
  # A genuine non-delivery: delivery present but no message-tool target was ever
  # recorded → the agent never reached Slack → must still page.
  runfile jobA <<'EOF'
{"status":"error","ts":2000,"error":"genuine non-delivery","delivered":false,"deliveryStatus":"not-delivered","delivery":{"messageToolSentTo":[]}}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cron failure(s) detected"* ]]
  [[ "$output" == *"daily-churned-campaign-refresh"* ]]
}

@test "message-tool delivery breaks the streak: self-posted error then real error → no alert" {
  export CRON_HEALTH_MIN_STREAK=2
  runfile jobA <<'EOF'
{"status":"error","ts":1900,"error":"posted anyway","delivery":{"messageToolSentTo":[{"channel":"message"}]}}
{"status":"error","ts":2000,"error":"real failure"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  # The self-posted run at 1900 is healthy → streak resets → the real error at
  # 2000 is only streak length 1 → suppressed.
  [[ "$output" == *"no new cron failures"* ]]
}

@test "error text with quotes/backticks → posted text survives intact (escaping guard)" {
  runfile jobA <<'EOF'
{"status":"error","ts":2000,"error":"failed `trino-query.sh \"SELECT a,b FROM t\"` with \\backslash"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  # token fixture so slack-notify proceeds and calls the (stubbed) muso
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  run bash "$WD"   # NOT dry-run → exercises slack_notify_payload_file → stubbed muso
  [ "$status" -eq 0 ]
  # The send must target the right channel as the devops bot, with attribution.
  grep -q -- '--bot devops' "$STUB_CALLS"
  grep -q -- '--channel C0ADV2W76G4' "$STUB_CALLS"
  grep -q -- '--requester' "$STUB_CALLS"
  # The python-built payload (not naive bash interp) must carry the failing job
  # and the tricky characters verbatim in the posted text.
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'daily-churned-campaign-refresh' "$TEST_TMPDIR/last-text"
  grep -qF 'trino-query.sh "SELECT a,b FROM t"' "$TEST_TMPDIR/last-text"
}

# ── 6.x SQLite cron_run_logs source ──────────────────────────────────────────
# openclaw 2026.6.x moved cron run logs into the SQLite cron_run_logs table.
# These exercise the production reader (the cases above use the JSONL fallback).

@test "SQLite source: a 2-error streak in cron_run_logs → alerts" {
  local sk="$TEST_TMPDIR/sk-jobs.json"
  mkrunsdb "$TEST_TMPDIR/runs.sqlite" "$sk" <<'EOF'
{"_jobId":"jobA","status":"error","ts":2000,"error":"first boom"}
{"_jobId":"jobA","status":"error","ts":3000,"error":"trino-query.sh failed"}
EOF
  export CRON_HEALTH_RUNS_DB="$TEST_TMPDIR/runs.sqlite"
  export CRON_HEALTH_STORE_KEY="$sk"
  export CRON_HEALTH_MIN_STREAK=2
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cron failure(s) detected"* ]]
  [[ "$output" == *"daily-churned-campaign-refresh"* ]]
  [[ "$output" == *"trino-query.sh failed"* ]]
}

@test "SQLite source: ok-only runs newer than watermark → no alert" {
  local sk="$TEST_TMPDIR/sk-jobs.json"
  mkrunsdb "$TEST_TMPDIR/runs.sqlite" "$sk" <<'EOF'
{"_jobId":"jobA","status":"ok","ts":2000}
{"_jobId":"jobA","status":"ok","ts":3000}
EOF
  export CRON_HEALTH_RUNS_DB="$TEST_TMPDIR/runs.sqlite"
  export CRON_HEALTH_STORE_KEY="$sk"
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "SQLite source: store_key scopes the query — rows under another key are ignored" {
  local sk="$TEST_TMPDIR/sk-jobs.json"
  # Rows written under a DIFFERENT store_key than we query → must see zero runs.
  mkrunsdb "$TEST_TMPDIR/runs.sqlite" "/some/other/store.json" <<'EOF'
{"_jobId":"jobA","status":"error","ts":2000,"error":"boom"}
{"_jobId":"jobA","status":"error","ts":3000,"error":"boom2"}
EOF
  export CRON_HEALTH_RUNS_DB="$TEST_TMPDIR/runs.sqlite"
  export CRON_HEALTH_STORE_KEY="$sk"   # queries this key, which has no rows
  export CRON_HEALTH_MIN_STREAK=2
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new cron failures"* ]]
}

@test "blind guard: DB present but cron_run_logs table missing → pages BLIND once, then dedupes" {
  # A state DB that exists but has lost the cron_run_logs table (e.g. a future
  # cron-store relocation). The watchdog must NOT silently report OK.
  python3 - "$TEST_TMPDIR/runs.sqlite" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute("CREATE TABLE other (x)"); con.commit(); con.close()
PY
  export CRON_HEALTH_RUNS_DB="$TEST_TMPDIR/runs.sqlite"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" == *"cron_run_logs table missing"* ]]
  # Second run with the persisted sentinel must NOT re-page (avoid a page-storm).
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"BLIND"* ]]
}

# ──────────────────────────────────────────────────────────────
# Session-budget headroom block (scripts/lib/ensure-session-budget-headroom.sh)
#
# Guards the 2026-07-27 wedge: an agent over session.maintenance.maxDiskBytes
# makes openclaw's reaper delete that agent's cron SESSION entries, and every
# fire then claim-errors. scan_failures only notices after N failed fires and
# can't name the cause; this block pages on the capacity signal itself.
# ──────────────────────────────────────────────────────────────

# _stub_budget_check <exit-code> [output] — install a fake guard on the path the
# watchdog reads.
_stub_budget_check() {
  local rc="$1"
  local out="${2:-main/ops: over budget}"
  cat > "$CRON_HEALTH_SESSION_BUDGET_CHECK" <<STUB
#!/bin/bash
echo "$out"
exit $rc
STUB
  chmod +x "$CRON_HEALTH_SESSION_BUDGET_CHECK"
}

@test "session budget: a violation pages #clio_devops with the cause named" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_budget_check 1 "  - [CRITICAL] main/operations: 8 enabled cron(s) but ZERO"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "session-budget headroom alert" <<< "$output"
  # The page must actually reach the (stubbed) Slack sender, and must carry the
  # actionable cause rather than just "a cron failed".
  grep -q "maxDiskBytes" "$TEST_TMPDIR/last-text"
  grep -q "main/operations" "$TEST_TMPDIR/last-text"
}

@test "session budget: repeat ticks inside the interval do NOT re-page" {
  # The watchdog ticks every 5 min; an undeduped page would post ~288x/day.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_budget_check 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  local first
  first="$(grep -c . "$STUB_CALLS")"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "page suppressed" <<< "$output"
  [ "$(grep -c . "$STUB_CALLS")" -eq "$first" ]
}

@test "session budget: re-pages once the interval has elapsed" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_budget_check 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  # Backdate the stamp past the 6h window.
  printf '%s' "$(( $(date -u +%s) - 21601 ))" > "$CRON_HEALTH_SESSION_BUDGET_STATE"
  run bash "$WD"
  grep -q "Posting session-budget headroom alert" <<< "$output"
}

@test "session budget: a clean check pages nothing" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_budget_check 0 "clean"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "session budget: a read error (exit 2) warns but does not page" {
  # Exit 2 is "couldn't evaluate", not "all clear" and not "violation".
  # Paging on it would turn a gateway blip into a false CRITICAL.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_budget_check 2 "ERROR: cron list failed"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "could not evaluate" <<< "$output"
  [ ! -s "$STUB_CALLS" ]
}

@test "session budget: --dry-run never posts and never stamps the dedupe file" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_budget_check 1
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  grep -q "DRY-RUN: session budget" <<< "$output"
  [ ! -s "$STUB_CALLS" ]
  [ ! -f "$CRON_HEALTH_SESSION_BUDGET_STATE" ]
}

@test "session budget: the block is skipped entirely when the guard is absent" {
  # Deploy-order safety: the watchdog must not break on a host where the guard
  # script hasn't landed yet.
  rm -f "$CRON_HEALTH_SESSION_BUDGET_CHECK"
  run bash "$WD"
  [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# Agent exec posture (guardrails-1101 gap 2 / H1)
# deploy.sh checks the posture per deploy; an exception whose EXPIRY DATE has passed
# needs a clock instead, so this watchdog tick is that clock. One page per 24h.
# ──────────────────────────────────────────────────────────────

# _stub_policy_check <exit-code> [output] — the real check runs under `python3`, so the stub must be python.
_stub_policy_check() {
  local rc="$1"
  local out="${2:-FAIL openclaw-main.json:qa: posture=full EXPIRED on 2026-11-08 - deny exec, or renew with a new ruling}"
  export CRON_HEALTH_EXEC_POLICY_CHECK="$TEST_TMPDIR/exec-policy-check.py"   # the seam starts EMPTY (disarmed)
  cat > "$CRON_HEALTH_EXEC_POLICY_CHECK" <<STUB
import sys
print("""$out""")
sys.exit($rc)
STUB
}

@test "agent exec posture: a violation pages with the finding AND the fix named" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "agent exec posture alert" <<< "$output"
  # The page must reach the (stubbed) Slack sender and name the H1 cause + the lever, not just "something is wrong".
  grep -q "EXPIRED on 2026-11-08" "$TEST_TMPDIR/last-text"
  grep -q "ROOT on node-8" "$TEST_TMPDIR/last-text"
  grep -q "Posture rules" "$TEST_TMPDIR/last-text"
}

@test "agent exec posture: repeat ticks inside 24h do NOT re-page" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  local first
  first="$(grep -c . "$STUB_CALLS")"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "UNCHANGED and already paged" <<< "$output"
  [ "$(grep -c . "$STUB_CALLS")" -eq "$first" ]
}

@test "agent exec posture: a DIFFERENT violation inside 24h pages immediately (dedupe is keyed to the finding)" {
  # One alert must not buy silence for every other posture failure in the next 24h: a restored root shell is not
  # "the thing we already told you about".
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 1 "FAIL scout: posture=denied but tools.deny lacks ['exec']"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Posted agent exec posture alert" <<< "$output"
  # Same finding again: suppressed.
  run bash "$WD"
  grep -q "UNCHANGED and already paged" <<< "$output"
  # A DIFFERENT finding one tick later, well inside the 24h window: it must page.
  _stub_policy_check 1 "FAIL qa: posture=full EXPIRED on 2026-11-08"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Posted agent exec posture alert" <<< "$output"
  grep -q "EXPIRED on 2026-11-08" "$TEST_TMPDIR/last-text"
}

@test "agent exec posture: a CLEAN tick clears the dedupe stamp, so the next regression pages at once" {
  # alert -> clean -> regression inside 24h: inheriting the first alert's window would hide the regression.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 3 "MISSING CHECKER: /opt/hydra/scripts/check-agent-exec-policy.py"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]
  _stub_policy_check 0 "agent exec policy: clean"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "cleared the dedupe stamp" <<< "$output"
  [ ! -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]
  # The checker is back and a live deny was removed in the same day: this must page, not wait 23h.
  _stub_policy_check 1 "FAIL scout: posture=denied but tools.deny lacks ['exec']"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Posted agent exec posture alert" <<< "$output"
  grep -q "tools.deny lacks" "$TEST_TMPDIR/last-text"
}

@test "agent exec posture: re-pages once the 24h interval has elapsed (a quiet week still pages)" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  printf '%s' "$(( $(date -u +%s) - 86401 ))" > "$CRON_HEALTH_EXEC_POLICY_STATE"
  run bash "$WD"
  grep -q "Posted agent exec posture alert" <<< "$output"
}

@test "agent exec posture: a clean check pages nothing" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 0 "ok   openclaw-main.json:scout: denied (6 deny entries)
agent exec policy: clean"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_CALLS" ]
  [ ! -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]
}

@test "agent exec posture: an unreadable config (exit 2) pages as CANNOT EVALUATE, never as all-clear" {
  # Exit 2 = "could not evaluate". For the cron detector that is a don't-page (an unreachable gateway already pages
  # elsewhere), but an unreadable shell posture is exactly the state a bad edit leaves behind: silence would read
  # as "the fleet is locked down" when nobody knows.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 2 "cannot read /root/.openclaw-main/openclaw.json: No such file or directory"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "CANNOT EVALUATE" "$TEST_TMPDIR/last-text"
  grep -q "No such file or directory" "$TEST_TMPDIR/last-text"
}

@test "agent exec posture: the tick asks the checker for the pre-expiry window (--fail-on-expiring)" {
  # Paging only on rc 1 meant the first alarm about a lapsed exception fired AFTER deform already blocked deploys.
  # The tick must opt into rc 4, and the flag must be on the same invocation that carries --live.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  export CRON_HEALTH_EXEC_POLICY_CHECK="$TEST_TMPDIR/exec-policy-check.py"
  cat > "$CRON_HEALTH_EXEC_POLICY_CHECK" <<STUB
import sys
open("$TEST_TMPDIR/argv", "w").write(" ".join(sys.argv[1:]))
print("agent exec policy: clean")
sys.exit(0)
STUB
  run bash "$WD"
  [ "$status" -eq 0 ]
  # a CLEAN tick prints nothing, so the flag is observed from the stub's own argv record
  [ "$(cat "$TEST_TMPDIR/argv")" = "--live --fail-on-expiring" ]
}

@test "agent exec posture: an expiring exception (exit 4) pages a WARNING with the date and countdown" {
  # rc 4 = "nothing is violated yet". It must page EARLY and read as a deadline, never as a violation (that wording
  # sends people looking for a restored shell) and never as CANNOT EVALUATE.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 4 "::warning::openclaw-main.json:cto: full exception expires 2026-11-15 - in 6d (7-day window). Renew it with a new ruling, or deny exec, before that date."
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Posted agent exec posture alert" <<< "$output"
  grep -q "about to lapse" "$TEST_TMPDIR/last-text"
  grep -q "2026-11-15" "$TEST_TMPDIR/last-text"          # the DATE travels with the page
  grep -q "in 6d" "$TEST_TMPDIR/last-text"                # ...and so does the countdown
  grep -q "2026-11-09" "$TEST_TMPDIR/last-text"           # names the outage this avoids
  [[ "$(cat "$TEST_TMPDIR/last-text")" != *"posture violated"* ]]
  [[ "$(cat "$TEST_TMPDIR/last-text")" != *"CANNOT EVALUATE"* ]]
  [ -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]              # a delivered warning DOES stamp: one page, not 288/day
}

@test "agent exec posture: a warning does NOT hide a real violation inside the 24h window" {
  # Sharing the dedupe file is the point; sharing the SIGNATURE would let a six-day warning buy silence for a
  # restored root shell. The stamp is keyed to the finding, so the violation pages immediately.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 4 "::warning::openclaw-main.json:cto: full exception expires 2026-11-15 - in 6d (7-day window)."
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "about to lapse" "$TEST_TMPDIR/last-text"
  _stub_policy_check 1 "FAIL openclaw-main.json:scout: posture=denied but tools.deny lacks ['exec']"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Posted agent exec posture alert" <<< "$output"
  grep -q "ROOT on node-8" "$TEST_TMPDIR/last-text"      # the violation wording, not the deadline wording
}

@test "agent exec posture: --dry-run never posts and never stamps the dedupe file" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 1
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  grep -q "DRY-RUN: agent exec posture" <<< "$output"
  [ ! -s "$STUB_CALLS" ]
  [ ! -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]
}

@test "agent exec posture: the block is off only when the seam is EMPTY (there is no implicit skip)" {
  run bash "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent exec posture"* ]]
}

@test "agent exec posture: an ABSENT checker pages as CHECKER MISSING, never a silent skip" {
  # A partial sync (or a host edit) that removes scripts/check-agent-exec-policy.py used to disable the alarm
  # entirely: no page, no finding, forever, while the tick looked healthy. The absence itself is the finding.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  export CRON_HEALTH_EXEC_POLICY_CHECK="$TEST_TMPDIR/gone/check-agent-exec-policy.py"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "checker MISSING" "$TEST_TMPDIR/last-text"
  grep -q "CANNOT EVALUATE" "$TEST_TMPDIR/last-text"
  grep -q "gone/check-agent-exec-policy.py" "$TEST_TMPDIR/last-text"
  [ -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]        # a delivered page DOES stamp (the alert was real)
}

@test "agent exec posture: a page that could not be DELIVERED does not stamp the 24h window (retries next tick)" {
  # slack_notify_critical is best-effort and returns 0 when Slack is unreachable, so stamping on it would buy 24h of
  # silence for a page nobody received — on the H1 alert. The stamp is written only after Slack confirms delivery.
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_policy_check 1
  STUB_MUSO_RC=1 run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "page delivery FAILED" <<< "$output"
  [ ! -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]       # NOT stamped: the window did not advance
  # Next tick, Slack is back: the same finding pages again (a stamp from the failed attempt would have suppressed it).
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Posted agent exec posture alert" <<< "$output"
  grep -q "EXPIRED on 2026-11-08" "$TEST_TMPDIR/last-text"
  [ -f "$CRON_HEALTH_EXEC_POLICY_STATE" ]
}

# ──────────────────────────────────────────────────────────────
# Unpaged unit-failure SPOOL (notify-unit-failed.sh / codex-edge-mirror.sh
# write <unit>.<epoch>.<pid>.unpaged, one record per file, temp+rename;
# systemd ignores an OnFailure unit's rc, so this watchdog is the only
# consumer). It claims whole files by rename; no producer holds an fd on a
# claimable file, so there is no append surface to race on.
# ──────────────────────────────────────────────────────────────
_spool_record() {  # <unit> <epoch> <reason>
  mkdir -p "$CRON_HEALTH_UNIT_FAILED_MARKER_DIR"
  printf '2026-09-11T18:00:00Z\t%s\t%s\n' "$1" "$3" > "$CRON_HEALTH_UNIT_FAILED_MARKER_DIR/$1.$2.111.unpaged"
}
_stub_marker() { _spool_record "$1" 1000 "deploy-notify.sh exited 1 (Slack rejected or the CLI failed)"; }
_spool_ls() { ls "$CRON_HEALTH_UNIT_FAILED_MARKER_DIR" 2>/dev/null | sort | tr '\n' ' '; }

@test "unit-failed spool: present → pages critical naming the unit, record count + age + reason, then clears the claimed files" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  _spool_record codex-edge-mirror.service 1001 "second record"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "Paged unpaged unit failure codex-edge-mirror.service (2 record(s)" <<< "$output"
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 1 ]     # ONE page per unit, not per record
  grep -q "<@U" "$TEST_TMPDIR/last-text"
  grep -q "codex-edge-mirror.service" "$TEST_TMPDIR/last-text"
  grep -Eq "newest [0-9]+s old" "$TEST_TMPDIR/last-text"
  grep -q "second record" "$TEST_TMPDIR/last-text"
  [ -z "$(_spool_ls)" ]
}

@test "unit-failed spool: delivery fails again → every claim is renamed BACK to *.unpaged for the next tick" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  STUB_MUSO_RC=1 run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "page delivery FAILED again (rc=1) — 1/1 record(s) re-queued" <<< "$output"
  [ "$(_spool_ls)" = "codex-edge-mirror.service.1000.111.unpaged " ]
}

@test "unit-failed spool: no token → nothing sent, records KEPT (never cleared on a silent no-op)" {
  _stub_marker codex-edge-mirror.service
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_CALLS" ]
  [ "$(_spool_ls)" = "codex-edge-mirror.service.1000.111.unpaged " ]
}

@test "unit-failed spool: dry-run names it and claims nothing" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  grep -q "DRY-RUN: unpaged unit failure codex-edge-mirror.service" <<< "$output"
  [ ! -s "$STUB_CALLS" ]
  [ "$(_spool_ls)" = "codex-edge-mirror.service.1000.111.unpaged " ]
}

@test "unit-failed spool: a record spooled by the producer DURING delivery is untouched by this tick and delivered by the next" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  STUB_MUSO_SPOOL_NEW="$CRON_HEALTH_UNIT_FAILED_MARKER_DIR/codex-edge-mirror.service.2000.222.unpaged" run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "1 record(s)" "$TEST_TMPDIR/last-text"
  [ "$(_spool_ls)" = "codex-edge-mirror.service.2000.222.unpaged " ]
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "SECOND failure spooled during delivery" "$TEST_TMPDIR/last-text"
  [ -z "$(_spool_ls)" ]
}

@test "unit-failed spool: an ORPHANED claim (tick died after the rename) is renamed back on startup and delivered" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  mkdir -p "$CRON_HEALTH_UNIT_FAILED_MARKER_DIR"
  printf 'orphan\tcodex-edge-mirror.service\tstranded by a killed tick\n' > "$CRON_HEALTH_UNIT_FAILED_MARKER_DIR/codex-edge-mirror.service.1000.111.unpaged.claim.4242"
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "restored orphaned unit-failure claim" <<< "$output"
  grep -q "stranded by a killed tick" "$TEST_TMPDIR/last-text"
  [ -z "$(_spool_ls)" ]
}

@test "unit-failed spool: delivery fails AND the rename-back fails → the claim is KEPT for startup recovery (never lost)" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  STUB_MUSO_RC=1 STUB_MV_FAIL_PATTERN='[.]unpaged$' run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "could not restore claim" <<< "$output"
  [[ "$(_spool_ls)" == *"codex-edge-mirror.service.1000.111.unpaged.claim."* ]]
}

@test "unit-failed spool: two units → two pages, each cleared" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  _spool_record codex-edge-mirror@edge 1500 "pre-start structural failure"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 2 ]
  [ -z "$(_spool_ls)" ]
}

@test "overlapping ticks: a run that starts while another holds the tick lock exits WITHOUT touching the spool (no reclaim, no second page)" {
  real_flock=""; for _f in /usr/bin/flock /opt/homebrew/bin/flock; do [ -x "$_f" ] && real_flock="$_f"; done
  [ -n "$real_flock" ] || skip "no real flock(1) on this host"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  _stub_marker codex-edge-mirror.service
  printf 'orphan\tcodex-edge-mirror.service\tmid-delivery by tick A\n' > "$CRON_HEALTH_UNIT_FAILED_MARKER_DIR/codex-edge-mirror.service.1000.111.unpaged.claim.4242"
  # tick A holds the single-run lock (it is mid-delivery)
  "$real_flock" "$CRON_HEALTH_LOCKFILE" sleep 30 &
  LOCK_HOLDER_PID=$!; export LOCK_HOLDER_PID
  sleep 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "SKIP: another cron-health-watchdog run holds" <<< "$output"
  [ ! -s "$STUB_CALLS" ]
  [ "$(_spool_ls)" = "codex-edge-mirror.service.1000.111.unpaged codex-edge-mirror.service.1000.111.unpaged.claim.4242 " ]   # untouched: no reclaim, no claim
  # release: flock's `sleep` child inherits the lock fd, so it must die too
  pkill -P "$LOCK_HOLDER_PID" 2>/dev/null || true; kill "$LOCK_HOLDER_PID" 2>/dev/null || true
  wait "$LOCK_HOLDER_PID" 2>/dev/null || true; LOCK_HOLDER_PID=""; sleep 1
  run bash "$WD"
  [ "$status" -eq 0 ]
  grep -q "restored orphaned unit-failure claim" <<< "$output"
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 1 ]
  [ -z "$(_spool_ls)" ]
}
