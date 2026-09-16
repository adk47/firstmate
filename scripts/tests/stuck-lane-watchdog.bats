#!/usr/bin/env bats
# Tests for scripts/stuck-lane-watchdog.sh — alerts #clio_devops when the edge
# gateway force-aborts a wedged agent run WITHOUT releasing the lane
# (action=abort_embedded_run … released=0), the moment a customer's generated
# reply is discarded (upstream openclaw #97538).
#
# Each case feeds a captured journal fixture via STUCK_LANE_JOURNAL_FILE and runs
# in --dry-run so nothing posts to Slack. Belt-and-braces: muso is PATH-stubbed
# and MUSO_SLACK_ENV_FILE points at a fixture so the suite can never read the
# real main.env or page #clio_devops. SKIP_HOST_GUARD bypasses the ovh-node-8
# guard. Modeled on scripts/tests/fallback-swallow-watchdog.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/stuck-lane-watchdog.sh"

# released=0 → lane NOT freed → reply discarded → MUST fire.
ABORT_LINE='2026-06-30T18:25:52.812+00:00 ovh-node-8 node[1]: [diagnostic] stuck session recovery outcome: status=aborted action=abort_embedded_run sessionId=sess-A sessionKey=agent:support:intercom:direct:215474906522805 activeSessionId=x activeWorkKind=embedded_run lane=session:agent:support:intercom:direct:215474906522805 aborted=true drained=true forceCleared=false released=0'
# released=2 → lane freed → recovery succeeded → MUST NOT fire.
FREED_LINE='2026-06-30T18:26:52.000+00:00 ovh-node-8 node[1]: [diagnostic] stuck session recovery outcome: status=aborted action=abort_embedded_run sessionId=sess-B sessionKey=agent:support:intercom:direct:111111111111111 activeSessionId=y activeWorkKind=embedded_run lane=z aborted=true drained=true forceCleared=true released=2'
# a mere stall warning (no abort) → MUST NOT fire.
STALL_LINE='2026-06-30T18:27:00.000+00:00 ovh-node-8 node[1]: [diagnostic] stalled session: sessionKey=agent:support:intercom:direct:222222222222222 classification=stalled_agent_run'

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm this watchdog during CI (it runs on the live node-8 host). Pin the
  # flag at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  JNL="$TEST_TMPDIR/journal.txt"
  STATE="$TEST_TMPDIR/state.json"

  # Never touch the real Slack token source or binary.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# $1 (optional): override STUCK_LANE_COOLDOWN_SECONDS
run_wd() {
  # Pin the LIVE-lane detector at an empty snapshot dir. This is hermeticity,
  # not tidiness: unset, the script shells out to
  # `openclaw --profile <p> gateway call diagnostics.lanes`, and this suite runs
  # ON node-8 — it would poll the real gateways mid-test. Its own cases live in
  # stuck-lane-watchdog-live-lanes.bats.
  mkdir -p "$TEST_TMPDIR/snap-empty"
  printf '%s\n' '{"ts":1,"lanes":[]}' > "$TEST_TMPDIR/snap-empty/main.json"
  printf '%s\n' '{"ts":1,"lanes":[]}' > "$TEST_TMPDIR/snap-empty/edge.json"
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$JNL" \
    STUCK_LANE_STATE_FILE="$STATE" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$TEST_TMPDIR/snap-empty" \
    STUCK_LANE_LIVE_STATE_FILE="$TEST_TMPDIR/live-state.json" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    STUCK_LANE_INTERCOM_WORKSPACE="wkspc" \
    STUCK_LANE_COOLDOWN_SECONDS="${1:-21600}" \
    "$SCRIPT" --dry-run
}

@test "released=0 abort with seeded state fires an alert with the conv id" {
  printf '%s\n' "$ABORT_LINE" > "$JNL"
  printf '%s\n' '{"000000000000000":{"ts":"2026-06-01T00:00:00Z","epoch":1}}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stuck support lane"* ]]
  [[ "$output" == *"215474906522805"* ]]
  [[ "$output" == *"reply"* ]]
}

@test "released>0 (lane freed) does NOT alert" {
  printf '%s\n' "$FREED_LINE" > "$JNL"
  printf '%s\n' '{"000000000000000":{"ts":"2026-06-01T00:00:00Z","epoch":1}}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new stuck/discarded lanes"* ]]
}

@test "a stalled_agent_run warning without an abort does NOT alert" {
  printf '%s\n' "$STALL_LINE" > "$JNL"
  printf '%s\n' '{"000000000000000":{"ts":"2026-06-01T00:00:00Z","epoch":1}}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new stuck/discarded lanes"* ]]
}

@test "first-ever run (no state file) seeds without alerting" {
  printf '%s\n' "$ABORT_LINE" > "$JNL"
  [ ! -f "$STATE" ]
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new stuck/discarded lanes"* ]]
  # watermark now records the conv so a later run won't backfill-page
  grep -q "215474906522805" "$STATE"
}

@test "recently-alerted conv within cooldown does not re-alert" {
  printf '%s\n' "$ABORT_LINE" > "$JNL"
  # prev epoch tiny but a HUGE cooldown means (line_epoch - 1) < cooldown → suppress
  printf '%s\n' '{"215474906522805":{"ts":"2026-06-30T18:00:00Z","epoch":1}}' > "$STATE"
  run_wd 99999999999
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new stuck/discarded lanes"* ]]
}

@test "a re-wedge after the cooldown window re-alerts" {
  printf '%s\n' "$ABORT_LINE" > "$JNL"
  # prev epoch tiny and a TINY cooldown means (line_epoch - 1) > cooldown → re-alert
  printf '%s\n' '{"215474906522805":{"ts":"2026-06-30T18:00:00Z","epoch":1}}' > "$STATE"
  run_wd 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"215474906522805"* ]]
}

@test "groups multiple aborts of one wedge into a single per-conv bullet" {
  printf '%s\n%s\n' "$ABORT_LINE" "$ABORT_LINE" > "$JNL"
  printf '%s\n' '{"000000000000000":{"ts":"2026-06-01T00:00:00Z","epoch":1}}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  # exactly one bullet, reporting 2 aborts
  [ "$(printf '%s\n' "$output" | grep -c '^• ')" -eq 1 ]
  [[ "$output" == *"2 abort(s)"* ]]
}

# ── Delivery-confirmation contract (QA finding on PR #616 rebase) ──────────
# The watermark must advance ONLY after Slack confirms the post; otherwise a
# token/channel/CLI outage silently marks the wedge "seen" and the only
# out-of-process alert is never retried.

# Live-path runner (no --dry-run). $1 = extra env assignments via env(1) args.
run_wd_live() {
  # Same pin, and it matters MORE here: this is the live delivery path.
  mkdir -p "$TEST_TMPDIR/snap-empty-live"
  printf '%s\n' '{"ts":1,"lanes":[]}' > "$TEST_TMPDIR/snap-empty-live/main.json"
  printf '%s\n' '{"ts":1,"lanes":[]}' > "$TEST_TMPDIR/snap-empty-live/edge.json"
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$JNL" \
    STUCK_LANE_STATE_FILE="$STATE" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$TEST_TMPDIR/snap-empty-live" \
    STUCK_LANE_LIVE_STATE_FILE="$TEST_TMPDIR/live-state-live.json" \
    STUCK_LANE_LOCKFILE="$TEST_TMPDIR/lock" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    STUCK_LANE_INTERCOM_WORKSPACE="wkspc" \
    STUCK_LANE_COOLDOWN_SECONDS=21600 \
    "$SCRIPT"
}

@test "live: failed Slack delivery does NOT advance the watermark and exits nonzero" {
  printf '%s\n' "$ABORT_LINE" > "$JNL"
  printf '%s\n' '{"000000000000000":{"ts":"2026-06-01T00:00:00Z","epoch":1}}' > "$STATE"
  # setup() leaves MUSO_SLACK_ENV_FILE pointing at an absent fixture and unsets
  # the token var → slack_load_env fails → post NOT confirmed.
  run_wd_live
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT advanced"* ]]
  # the wedged conv must NOT be recorded as alerted
  ! grep -q "215474906522805" "$STATE"
}

@test "live: confirmed Slack delivery advances the watermark" {
  printf '%s\n' "$ABORT_LINE" > "$JNL"
  printf '%s\n' '{"000000000000000":{"ts":"2026-06-01T00:00:00Z","epoch":1}}' > "$STATE"
  printf '%s\n' 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test-token' > "$MUSO_SLACK_ENV_FILE"
  run_wd_live
  [ "$status" -eq 0 ]
  grep -q "215474906522805" "$STATE"
}
