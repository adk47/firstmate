#!/usr/bin/env bats
# Tests for scan_lane_latency in scripts/stuck-lane-watchdog.sh — the LATENCY
# detector, which reports waits that have ALREADY ENDED.
#
# This is the one thing `lane wait exceeded` IS authoritative for. The line is
# emitted as a queued task STARTS, so it cannot prove a lane is stuck now —
# `scan_wedged_lanes_live` answers that from live gateway state. But `waitedMs`
# is a real, finished measurement, and nothing watched it: on 2026-09-16 five
# messages to `cto` waited 107, 102, 91, 86 and 22 minutes and the only reason
# anyone noticed was a person asking why Ops had not replied.
#
# Floor measured over 24h on node-8 (2026-09-17, main gateway):
#   170 lines  p50=79s  p90=508s  p99=1013s  max=1271s
#   >=5min -> 8 lanes   >=10min -> 4 lanes   >=15min -> 3   >=30min -> 0
# 600000ms (10 min) is the default: 4 lanes/day is a sane page rate for
# something already resolved.
#
# Fixtures are fed via STUCK_LANE_LATENCY_JOURNAL_DIR so nothing reads the live
# journal, and the other two detectors are pinned inert.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/stuck-lane-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  LATJ="$TEST_TMPDIR/latj"; mkdir -p "$LATJ"
  LAT_STATE="$TEST_TMPDIR/lat-state.json"

  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # Other two detectors inert: empty edge journal, empty lane snapshots.
  : > "$TEST_TMPDIR/edge-journal.txt"
  mkdir -p "$TEST_TMPDIR/snap"
  printf '%s\n' '{"ts":1,"lanes":[]}' > "$TEST_TMPDIR/snap/main.json"
  printf '%s\n' '{"ts":1,"lanes":[]}' > "$TEST_TMPDIR/snap/edge.json"

  # Pre-seeded: an ABSENT state file means "first ever run", which seeds
  # silently. Production is seeded from its second tick on.
  printf '%s\n' '{"session:agent:unrelated:main":{"ts":"2026-01-01T00:00:00Z","epoch":1}}' > "$LAT_STATE"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# _wait <ts> <lane> <waitedMs> [unit]
_wait() {
  printf '%s node[1]: [diagnostic] lane wait exceeded: lane=%s waitedMs=%s queueAhead=0 activeAhead=1 activeNow=0 queueBehind=0\n' \
    "$1" "$2" "$3" >> "$LATJ/${4:-openclaw-gateway-main}.txt"
}
_reset_journal() { rm -f "$LATJ"/*.txt; : > "$LATJ/openclaw-gateway-main.txt"; }

# $1 floor ms (default 600000), $2 cooldown (default 21600)
run_wd() {
  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_STATE_FILE="$TEST_TMPDIR/edge-state.json" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$TEST_TMPDIR/snap" \
    STUCK_LANE_LIVE_STATE_FILE="$TEST_TMPDIR/live-state.json" \
    STUCK_LANE_LATENCY_JOURNAL_DIR="$LATJ" \
    STUCK_LANE_LATENCY_STATE_FILE="$LAT_STATE" \
    STUCK_LANE_LATENCY_UNITS="openclaw-gateway-main openclaw-gateway-edge" \
    STUCK_LANE_LATENCY_MIN_MS="${1:-600000}" \
    STUCK_LANE_COOLDOWN_SECONDS="${2:-21600}" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run
}
_alerted() { printf '%s\n' "$output" | grep -E '^• ' || true; }

# ── the floor ───────────────────────────────────────────────────────────────

@test "a wait over the floor is reported with agent, lane and minutes" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slow agent replies"* ]]
  [[ "$output" == *"operations"* ]]
  [[ "$output" == *"session:agent:operations:main"* ]]
  [[ "$output" == *"15.0 min"* ]]
  # It must say the wait is over, so nobody restarts a gateway over it.
  [[ "$output" == *"ALREADY ENDED"* ]]
  [[ "$output" == *"not a live wedge"* ]]
  [[ "$output" == *"no action implied"* ]]
}

@test "a wait UNDER the floor is not reported" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 300000
  run_wd
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
  [[ "$output" == *"no lane waited past the floor"* ]]
}

@test "the floor is inclusive at exactly the threshold and excludes one ms below" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:atfloor:main" 600000
  run_wd
  [[ "$output" == *"atfloor"* ]]

  printf '%s\n' '{"session:agent:unrelated:main":{"ts":"2026-01-01T00:00:00Z","epoch":1}}' > "$LAT_STATE"
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:belowfloor:main" 599999
  run_wd
  [[ "$output" != *"belowfloor"* ]]
}

@test "the floor is configurable" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:mid:main" 400000
  run_wd 300000
  [[ "$output" == *"mid"* ]]
  [[ "$output" == *"over 5 minutes"* ]]
}

@test "a malformed line missing waitedMs is skipped, never guessed at" {
  _reset_journal
  printf '%s node[1]: [diagnostic] lane wait exceeded: lane=session:agent:bad:main queueAhead=0\n' \
    "2026-09-17T01:00:00.000+00:00" >> "$LATJ/openclaw-gateway-main.txt"
  run_wd
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

# ── reporting ───────────────────────────────────────────────────────────────

@test "multiple waits on one lane report the WORST and count the slow starts" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:cto:slack:direct:u7rp" 1320000
  _wait "2026-09-17T01:01:00.000+00:00" "session:agent:cto:slack:direct:u7rp" 6433382
  _wait "2026-09-17T01:02:00.000+00:00" "session:agent:cto:slack:direct:u7rp" 900000
  run_wd
  [[ "$output" == *"107.2 min"* ]]          # the worst, not the first or last
  [[ "$output" == *"3 slow starts"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^• ')" -eq 1 ]
}

@test "lanes are ranked slowest first" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:mild:main" 700000
  _wait "2026-09-17T01:01:00.000+00:00" "session:agent:severe:main" 2000000
  run_wd
  [ "$(printf '%s\n' "$output" | grep -c '^• ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -n '^• ' | grep severe | cut -d: -f1)" -lt \
    "$(printf '%s\n' "$output" | grep -n '^• ' | grep mild | cut -d: -f1)" ]
}

@test "an EDGE-unit wait is reported and labelled by profile" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:support:intercom:direct:99" 800000 openclaw-gateway-edge
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(edge)"* ]]
  [[ "$output" == *"intercom:direct:99"* ]]
}

# ── dedupe ──────────────────────────────────────────────────────────────────

@test "the same lane inside the cooldown window is suppressed" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  run_wd
  [[ "$output" == *"operations"* ]]
  run_wd
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
}

@test "a DIFFERENT lane inside the same window still reports" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  run_wd
  [[ "$output" == *"operations"* ]]
  _reset_journal
  _wait "2026-09-17T01:05:00.000+00:00" "session:agent:devops:main" 900000
  run_wd
  [[ "$output" == *"devops"* ]]
}

@test "suppressed ticks do NOT slide the cooldown window" {
  # Same defect class as the sibling detectors: the watermark is last-ALERT, so
  # advancing it on a suppressed tick would make the lane report once and never
  # again.
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  run_wd 600000 600
  [[ "$output" == *"operations"* ]]

  for t in 01:02:00 01:04:00 01:06:00; do
    _reset_journal
    _wait "2026-09-17T${t}.000+00:00" "session:agent:operations:main" 950000
    run_wd 600000 600
    [ -z "$(_alerted)" ]
  done

  _reset_journal
  _wait "2026-09-17T01:11:00.000+00:00" "session:agent:operations:main" 990000
  run_wd 600000 600
  [[ "$output" == *"operations"* ]]
}

@test "a FUTURE-dated watermark does not suppress a real report" {
  printf '%s\n' '{"session:agent:operations:main":{"ts":"2036-01-01T00:00:00Z","epoch":2082758400}}' > "$LAT_STATE"
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"operations"* ]]
}

@test "first-ever run (no state file) seeds silently" {
  rm -f "$LAT_STATE"
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  run_wd
  [ "$status" -eq 0 ]
  [ -z "$(_alerted)" ]
  [ -s "$LAT_STATE" ]
}

# ── capture must not fail open ──────────────────────────────────────────────

@test "a missing per-unit journal file does not read as 'no slow lanes' for that unit" {
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000
  rm -f "$LATJ/openclaw-gateway-edge.txt"     # edge file absent
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"operations"* ]]            # main still reported
}

@test "a failing journalctl is CAPTURE-FAILED and non-zero, never 'past the floor'" {
  # No fixture dir -> the real capture path runs, with journalctl stubbed to fail.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_TMPDIR/bin/journalctl"
  chmod +x "$TEST_TMPDIR/bin/journalctl"

  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_STATE_FILE="$TEST_TMPDIR/edge-state.json" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$TEST_TMPDIR/snap" \
    STUCK_LANE_LIVE_STATE_FILE="$TEST_TMPDIR/live-state.json" \
    STUCK_LANE_LATENCY_STATE_FILE="$LAT_STATE" \
    STUCK_LANE_LATENCY_UNITS="openclaw-gateway-main" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"CAPTURE-FAILED[lane-latency]"* ]]
  [[ "$output" != *"no lane waited past the floor"* ]]
  # the sibling detectors still ran
  [[ "$output" == *"no new stuck/discarded lanes"* ]]
}

@test "dry-run with the DEFAULT latency state path shadows it" {
  local prod="/var/lib/stuck-lane-watchdog/lane-latency.json"
  local before="absent"; [ -f "$prod" ] && before="$(md5sum "$prod" | awk '{print $1}')"
  _reset_journal
  _wait "2026-09-17T01:00:00.000+00:00" "session:agent:operations:main" 900000

  run env \
    STUCK_LANE_SKIP_HOST_GUARD=1 \
    STUCK_LANE_JOURNAL_FILE="$TEST_TMPDIR/edge-journal.txt" \
    STUCK_LANE_LIVE_SNAPSHOT_DIR="$TEST_TMPDIR/snap" \
    STUCK_LANE_LATENCY_JOURNAL_DIR="$LATJ" \
    STUCK_LANE_LATENCY_UNITS="openclaw-gateway-main" \
    STUCK_LANE_EDGE_CONFIG="$TEST_TMPDIR/absent.json" \
    "$SCRIPT" --dry-run

  [[ "$output" == *"lane-latency watermark shadowed"* ]]
  local after="absent"; [ -f "$prod" ] && after="$(md5sum "$prod" | awk '{print $1}')"
  [ "$after" = "$before" ]
}
