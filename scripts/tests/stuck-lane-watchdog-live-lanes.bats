#!/usr/bin/env bats
# Tests for scan_wedged_lanes_live in scripts/stuck-lane-watchdog.sh — the
# LIVE-STATE lane-wedge detector.
#
# WHY THIS READS STATE AND NOT LOGS. An earlier revision parsed
# `lane wait exceeded` from the journal and treated `activeAhead=1 activeNow=0`
# as a phantom lane owner. That was wrong: in dist/command-queue-*.js the line is
# emitted inside `drainLane` AFTER the dequeue, as a queued task is being
# STARTED, so `activeNow` is the count immediately BEFORE that start and
# `activeAhead` is a snapshot from ENQUEUE time. It is a RECOVERY record, and
# 221 of 221 lines over 24h carried that pair because it is the ordinary shape.
# A detector built on it pages for lanes that already recovered and its remedy
# is a customer-visible restart. The old suite stayed green because its fixtures
# encoded the same misreading — which is the real lesson here: a suite proves
# nothing when the test and the code share one wrong premise.
#
# `diagnostics.lanes` is authoritative because it is current state. Session
# lanes are safe to read from it: `retireIdleScopedCommandLane` only removes a
# `session:` lane when it is not draining, has zero active tasks AND
# queue.length == 0 — so a lane with anything queued cannot be reaped.
#
# Every case feeds a pre-captured snapshot via STUCK_LANE_LIVE_SNAPSHOT_DIR, so
# nothing polls the real gateways, and runs --dry-run with muso PATH-stubbed.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/stuck-lane-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  SNAP="$TEST_TMPDIR/snap"; mkdir -p "$SNAP"
  LIVE_STATE="$TEST_TMPDIR/live-state.json"

  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"; : > "$STUB_CALLS"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # Edge detector pinned at an empty journal so only the live detector speaks.
  : > "$TEST_TMPDIR/edge-journal.txt"

  # A PRE-SEEDED live state file, because an ABSENT one means "first ever run",
  # which seeds silently and alerts on nothing. Production is in the seeded
  # state from its second tick onward, so that is the realistic default here;
  # the first-run case deletes it explicitly.
  printf '%s\n' '{"main\tsession:agent:unrelated:main":{"streak":0,"epoch":0}}' > "$LIVE_STATE"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# _lane <queued> <active> <maxConcurrent> [name] [draining] [blockedBy]
_lane() {
  printf '{"lane":"%s","queuedCount":%s,"activeCount":%s,"maxConcurrent":%s,"draining":%s,"generation":0,"blockedBy":%s}' \
    "${4:-session:agent:ops:main}" "$1" "$2" "$3" "${5:-false}" "${6:-null}"
}
# _snap <profile> <lane-json>...
_snap() {
  local profile="$1"; shift
  local IFS=,
  printf '{"ts":1,"lanes":[%s]}\n' "$*" > "$SNAP/$profile.json"
}
# Most cases only exercise main; edge needs a file or its profile is skipped.
_snap_edge_empty() { printf '%s\n' '{"ts":1,"lanes":[]}' > "$SNAP/edge.json"; }

# $1 min-ticks (default 3), $2 cooldown (default 21600)
run_wd() {
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_STATE_FILE="$TEST_TMPDIR/edge-state.json" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$SNAP" \
    STUCK_LANE_LIVE_STATE_FILE="$LIVE_STATE" \
    STUCK_LANE_LIVE_PROFILES="main edge" \
    STUCK_LANE_LIVE_MIN_TICKS="${1:-3}" \
    STUCK_LANE_COOLDOWN_SECONDS="${2:-21600}" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run
}

_alerted() { printf '%s\n' "$output" | grep -E '^• ' || true; }

# ── the streak threshold ────────────────────────────────────────────────────

@test "a wedged lane does NOT page on its first observation" {
  # A dequeue leaves a sub-millisecond window where queued>0 and active==0
  # legitimately. One sighting is not a wedge.
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 3
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
  [[ "$output" == *"no lane queued with nothing running"* ]]
}

@test "it pages on the Nth consecutive observation, naming profile, lane and queue depth" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 3; [ -z "$(_alerted)" ]      # 1
  run_wd 3; [ -z "$(_alerted)" ]      # 2
  run_wd 3                            # 3 -> fires
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wedged lane"* ]]
  [[ "$output" == *"*main*"* ]]
  [[ "$output" == *"session:agent:ops:main"* ]]
  [[ "$output" == *"queued=3 active=0"* ]]
  [[ "$output" == *"3 consecutive checks"* ]]
  [[ "$output" == *"Detection only"* ]]
  [[ "$output" == *"no auto-heal"* ]]
}

@test "a lane that recovers mid-streak resets it, so the count restarts" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 3; run_wd 3                  # streak 2
  _snap main "$(_lane 0 0 1)"         # recovered
  run_wd 3
  [ -z "$(_alerted)" ]
  _snap main "$(_lane 3 0 1)"         # wedged again
  run_wd 3; [ -z "$(_alerted)" ]      # streak restarted at 1, not 3
  run_wd 3; [ -z "$(_alerted)" ]      # 2
  run_wd 3                            # 3 -> fires
  [[ "$output" == *"Wedged lane"* ]]
}

@test "MIN_TICKS=1 pages immediately (the knob is honoured)" {
  _snap main "$(_lane 2 0 1)"; _snap_edge_empty
  run_wd 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wedged lane"* ]]
  [[ "$output" == *"1 consecutive checks"* ]]
}

# ── the discriminator ──────────────────────────────────────────────────────

@test "nothing queued is not a wedge, however idle the lane" {
  _snap main "$(_lane 0 0 1)"; _snap_edge_empty
  run_wd 1
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

@test "work ACTIVE is not a wedge, however deep the queue" {
  # This is ordinary contention: something is running, the queue will drain.
  _snap main "$(_lane 14 1 1)"; _snap_edge_empty
  run_wd 1
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

@test "maxConcurrent=0 is an administratively DISABLED lane, not a wedge" {
  # hook-dispatch reads q=0 a=0 max=0 blockedBy=lane on the live fleet. A lane
  # that can never run anything is a config question; paging would be permanent.
  _snap main "$(_lane 5 0 0 hook-dispatch false '"lane"')"; _snap_edge_empty
  run_wd 1
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

@test "a malformed lane row is skipped, never guessed at" {
  printf '%s\n' '{"ts":1,"lanes":[{"lane":"session:agent:ops:main","activeCount":0,"maxConcurrent":1}]}' > "$SNAP/main.json"
  _snap_edge_empty
  run_wd 1
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

@test "draining=true and blockedBy are reported as context when a lane does page" {
  _snap main "$(_lane 4 0 1 session:agent:ops:main true '"group"')"; _snap_edge_empty
  run_wd 1
  [[ "$output" == *"draining=true"* ]]
  [[ "$output" == *"blockedBy=group"* ]]
}

# ── dedupe ────────────────────────────────────────────────────────────────

@test "the same lane inside the cooldown window is suppressed after it pages" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 1 21600
  [[ "$output" == *"Wedged lane"* ]]
  run_wd 1 21600
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

@test "a DIFFERENT lane inside the same window still pages (dedupe is per-lane)" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 1 21600
  [[ "$output" == *"session:agent:ops:main"* ]]
  _snap main "$(_lane 3 0 1)" "$(_lane 8 0 1 session:agent:cto:main)"
  run_wd 1 21600
  [ "$status" -eq 0 ]
  [[ "$output" == *"session:agent:cto:main"* ]]
  [[ "$output" != *"session:agent:ops:main"* ]]
}

@test "past the cooldown window the same lane pages again" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 1 1
  [[ "$output" == *"Wedged lane"* ]]
  sleep 2
  run_wd 1 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wedged lane"* ]]
}

@test "first-ever run (no state file) seeds silently" {
  rm -f "$LIVE_STATE"
  [ ! -f "$LIVE_STATE" ]
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 1
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
  [ -s "$LIVE_STATE" ]
}

# ── both profiles, and ranking ─────────────────────────────────────────────

@test "an EDGE lane wedge pages too, labelled with its profile" {
  _snap main "$(_lane 0 0 1)"
  _snap edge "$(_lane 2 0 1 session:agent:support:intercom:direct:123)"
  run_wd 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"*edge*"* ]]
  [[ "$output" == *"session:agent:support:intercom:direct:123"* ]]
}

@test "several wedged lanes are ranked by queue depth, deepest first" {
  _snap main "$(_lane 2 0 1 session:agent:mild:main)" "$(_lane 11 0 1 session:agent:severe:main)"
  _snap_edge_empty
  run_wd 1
  [ "$(printf '%s\n' "$output" | grep -c '^• ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -n '^• ' | grep severe | cut -d: -f1)" -lt \
    "$(printf '%s\n' "$output" | grep -n '^• ' | grep mild | cut -d: -f1)" ]
}

@test "a missing snapshot for one profile does not reset the other's streaks" {
  # The caller refuses on a failed capture, so a snapshot absent HERE must not
  # silently mark that profile healthy and wipe its progress.
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 3; run_wd 3                          # main streak 2
  rm -f "$SNAP/main.json"
  run_wd 3
  [ "$status" -eq 0 ]
  [ "$(jq -r '."main\tsession:agent:ops:main".streak' "$LIVE_STATE")" = "2" ]
}

# ── the capture must not fail open ─────────────────────────────────────────

@test "a failing gateway call is CAPTURE-FAILED and non-zero, never 'nothing running'" {
  # No snapshot dir → the real capture path runs, with openclaw stubbed to fail.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_STATE_FILE="$TEST_TMPDIR/edge-state.json" \
    STUCK_LANE_LIVE_STATE_FILE="$LIVE_STATE" \
    STUCK_LANE_LIVE_PROFILES="main" \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"CAPTURE-FAILED[live-lanes]"* ]]
  [[ "$output" == *"observed NOTHING"* ]]
  [[ "$output" != *"no lane queued with nothing running"* ]]
  # The edge detector still ran — one capture failure must not silence it.
  [[ "$output" == *"no new stuck/discarded lanes"* ]]
}

@test "a failing gateway call does NOT advance live state" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 3                                     # seed + streak
  before="$(cat "$LIVE_STATE")"

  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_STATE_FILE="$TEST_TMPDIR/edge-state.json" \
    STUCK_LANE_LIVE_STATE_FILE="$LIVE_STATE" \
    STUCK_LANE_LIVE_PROFILES="main" \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run

  [ "$status" -ne 0 ]
  [ "$(cat "$LIVE_STATE")" = "$before" ]
}

@test "the alert never claims to have restarted anything" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 1
  [[ "$output" == *"human call"* ]]
  [[ "$output" != *"restarted"* ]]
  [[ "$output" != *"cleared the lane"* ]]
}

# ── --dry-run must not consume a PRODUCTION watermark (QA finding, #958) ────
# The old contract said "state IS advanced; redirect STUCK_LANE_STATE_FILE to
# rehearse safely" — which named only ONE of the two state files. With a lane at
# its streak threshold, the documented rehearsal wrote an alert epoch to the
# LIVE state while Slack received nothing, and the next real tick saw that epoch
# inside the 6h cooldown and stayed quiet. A rehearsal that silences the next
# genuine page is worse than no rehearsal.
#
# Now: a state path still at its DEFAULT is shadowed by a temp copy for the run.
# An EXPLICIT path is used as given and IS written, which is how every other
# case in this file rehearses multi-tick behaviour.

@test "dry-run with DEFAULT state paths does not write the production live watermark" {
  # No STUCK_LANE_LIVE_STATE_FILE and no STUCK_LANE_STATE_FILE: both default.
  # The defaults live under /var/lib/stuck-lane-watchdog/, which must be
  # untouched — assert via the log line and via the absence of any write.
  local before_live="/var/lib/stuck-lane-watchdog/live-lanes.json"
  local sig_before="absent"
  [ -f "$before_live" ] && sig_before="$(md5sum "$before_live" | awk '{print $1}')"

  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$SNAP" \
    STUCK_LANE_LIVE_PROFILES="main" \
    STUCK_LANE_LIVE_MIN_TICKS=1 \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"live-lane watermark shadowed"* ]]
  [[ "$output" == *"will NOT be mutated"* ]]

  local sig_after="absent"
  [ -f "$before_live" ] && sig_after="$(md5sum "$before_live" | awk '{print $1}')"
  [ "$sig_after" = "$sig_before" ]
}

@test "dry-run with an EXPLICIT state path still persists (the suites depend on it)" {
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run_wd 3                      # explicit LIVE_STATE via run_wd
  [ "$status" -eq 0 ]
  [[ "$output" != *"shadowed"* ]]
  [ "$(jq -r '."main\tsession:agent:ops:main".streak' "$LIVE_STATE")" = "1" ]
}

@test "a shadowed dry-run cannot suppress the next real tick" {
  # The finding's exact scenario end to end: rehearse at the threshold with
  # default paths, then run with the explicit test state — the alert must still
  # be available rather than having been consumed by the rehearsal.
  _snap main "$(_lane 3 0 1)"; _snap_edge_empty
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$SNAP" \
    STUCK_LANE_LIVE_PROFILES="main" \
    STUCK_LANE_LIVE_MIN_TICKS=1 \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run
  [[ "$output" == *"shadowed"* ]]

  run_wd 1                      # the "real" tick, explicit state
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wedged lane"* ]]
}
