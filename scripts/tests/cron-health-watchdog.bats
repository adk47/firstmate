#!/usr/bin/env bats
# Tests for scripts/cron-health-watchdog.sh — the cron-failure alerter
# added after the 2026-06 b2b-reply-scanner stacked 17 silent failures.
#
# PATH-shadows curl + ssh so a real Slack POST / remote call during a test
# fails loudly instead of paging #clio_devops for real
# (see memory/feedback_bats_must_stub_openclaw.md). Behavioural assertions
# use --dry-run (never touches the network); the payload-escaping test runs
# the real post path against a stubbed curl that captures the JSON body.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/cron-health-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/runs" "$TEST_TMPDIR/bin"

  # Refuse real network: stub curl + ssh.
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  # curl stub: capture the --data-binary @<file> payload for inspection.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    @*) cp "${a#@}" "$CRON_HEALTH_TEST_CAPTURE" 2>/dev/null ;;
  esac
done
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/curl"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # jobs.json id->name/agent map shared by most tests.
  printf '%s\n' '{"jobs":[{"id":"jobA","name":"daily-churned-campaign-refresh","agentId":"cmo"},{"id":"jobB","name":"company-finder-daily","agentId":"cmo"}]}' \
    > "$TEST_TMPDIR/jobs.json"

  export CRON_HEALTH_RUNS_DIR="$TEST_TMPDIR/runs"
  export CRON_HEALTH_JOBS_FILE="$TEST_TMPDIR/jobs.json"
  export CRON_HEALTH_STATE_FILE="$TEST_TMPDIR/state.json"
  export CRON_HEALTH_LOCKFILE="$TEST_TMPDIR/wd.lock"
  export CRON_HEALTH_SKIP_HOST_GUARD=1
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

@test "error text with quotes/backticks → posts a VALID JSON payload (escaping guard)" {
  runfile jobA <<'EOF'
{"status":"error","ts":2000,"error":"failed `trino-query.sh \"SELECT a,b FROM t\"` with \\backslash"}
EOF
  printf '%s\n' '{"jobA":1500}' > "$CRON_HEALTH_STATE_FILE"
  # fake config so slack-notify reads a token and calls (stubbed) curl
  printf '%s\n' '{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test"}}}}}' \
    > "$TEST_TMPDIR/slack.json"
  export CRON_HEALTH_SLACK_CONFIG="$TEST_TMPDIR/slack.json"
  export CRON_HEALTH_TEST_CAPTURE="$TEST_TMPDIR/captured-payload.json"
  run bash "$WD"   # NOT dry-run → exercises slack_notify_payload_file → stubbed curl
  [ "$status" -eq 0 ]
  [ -f "$CRON_HEALTH_TEST_CAPTURE" ]
  # The captured body must be valid JSON (python-built, not naive bash interp)
  run python3 -m json.tool "$CRON_HEALTH_TEST_CAPTURE"
  [ "$status" -eq 0 ]
  # ...and must carry the channel + the failing job
  run python3 -c "import json,sys; d=json.load(open('$CRON_HEALTH_TEST_CAPTURE')); print(d['channel']); print('daily-churned-campaign-refresh' in d['text'])"
  [[ "$output" == *"C0ADV2W76G4"* ]]
  [[ "$output" == *"True"* ]]
}
