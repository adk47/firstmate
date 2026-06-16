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
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  # flock shim: macOS has no flock(1); use the real one when present (Linux CI)
  # so single-run locking still behaves, otherwise no-op so real-run tests work.
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # jobs.json id->name/agent map shared by most tests.
  printf '%s\n' '{"jobs":[{"id":"jobA","name":"daily-churned-campaign-refresh","agentId":"cmo"},{"id":"jobB","name":"company-finder-daily","agentId":"cmo"}]}' \
    > "$TEST_TMPDIR/jobs.json"

  export CRON_HEALTH_RUNS_DIR="$TEST_TMPDIR/runs"
  export CRON_HEALTH_JOBS_FILE="$TEST_TMPDIR/jobs.json"
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

teardown() { rm -rf "$TEST_TMPDIR"; }

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
