#!/usr/bin/env bash
# tests/fm-roster.test.sh - behavior tests for bin/fm-roster.sh.
#
# The contract under test is the captain-facing roster: one row per supervised
# task with a plain-words "doing now", the model string, and an estimate whose
# basis is stated; then the unsupervised surfaces; then a totals line. The other
# half is the bounded read: a 5 MB status log must not slow the report or hide
# its newest line. Every source that would touch the live host (pane reads,
# process scan, Orca terminal list) is disabled in these fixtures, so the suite
# is deterministic and read-only.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROSTER="$ROOT/bin/fm-roster.sh"
TMP_ROOT=$(fm_test_tmproot fm-roster)
NOW=1790033000

build_home() {
  local home="$TMP_ROOT/home"
  mkdir -p "$home/state" "$home/data/cmux-takeover/status" \
    "$home/projects/alpha" "$home/projects/beta" "$home/claude-projects" \
    "$home/grok-sessions" "$home/data/scout"

  fm_write_meta "$home/state/ship-working.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca" "spawn_gen=s$((NOW - 3600)).1.1"
  fm_write_meta "$home/state/ship-done-pr.meta" \
    "project=$home/projects/alpha" "harness=claude" "model=opus[1m]" \
    "effort=high" "kind=ship" "backend=orca"
  fm_write_meta "$home/state/ship-done-merged.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=fireworks-us/accounts/fireworks/models/deepseek-v4p1-flash" \
    "effort=default" "kind=ship" "backend=orca"
  fm_write_meta "$home/state/ship-blocked.meta" \
    "project=$home/projects/beta" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca"
  fm_write_meta "$home/state/lane.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca"
  fm_write_meta "$home/state/scout.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=scout" "backend=orca"
  fm_write_meta "$home/state/scout-noreport.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=scout" "backend=orca"
  fm_write_meta "$home/state/ship-nostatus.meta" \
    "harness=pi" "model=openrouter-named/deepseek/deepseek-v4.1-flash" \
    "effort=high" "kind=ship" "backend=orca"
  fm_write_meta "$home/state/big.meta" \
    "project=$home/projects/beta" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca" "spawn_gen=s$((NOW - 3600)).2.2"

  printf 'working: implementing the parser\n' > "$home/state/ship-working.status"
  printf 'done: PR https://example.invalid/alpha/pull/1 checks green\n' \
    > "$home/state/ship-done-pr.status"
  printf 'done: PR https://example.invalid/alpha/pull/2 checks green\n' \
    > "$home/state/ship-done-merged.status"
  printf 'blocked: waiting on the captain to supply the API credential\n' \
    > "$home/state/ship-blocked.status"
  printf 'paused [key=await-tick]: idle until next tick at 07:15Z - nothing in flight\n' \
    > "$home/state/lane.status"
  printf 'working: triaging the crash cluster\n' > "$home/state/scout.status"
  printf 'working: triaging the second cluster\n' > "$home/state/scout-noreport.status"

  printf '# scout report\n' > "$home/data/scout/report.md"

  # Three recent Done ship tasks whose retained data dirs give a 4h median:
  # duration is the dispatch brief mtime to the directory's last write.
  python3 - "$home" "$NOW" <<'PY'
import os
import sys

home, now = sys.argv[1], float(sys.argv[2])
for task_id, hours in (("done-a", 3), ("done-b", 4), ("done-c", 6)):
    path = os.path.join(home, "data", task_id)
    os.makedirs(path, exist_ok=True)
    brief = os.path.join(path, "launch-brief.md")
    with open(brief, "w") as handle:
        handle.write("brief\n")
    start = now - hours * 3600 - 10
    os.utime(brief, (start, start))
    os.utime(path, (now, now))

# The 5 MB synthetic status log: its newest line must be found and the report
# must stay fast, which only holds if the reader takes a tail, not the file.
path = os.path.join(home, "state", "big.status")
line = b"working: filler line that must never be the newest\n"
target = 5 * 1024 * 1024
with open(path, "wb") as handle:
    written = 0
    while written < target - len(line):
        handle.write(line)
        written += len(line)
    handle.write(b"working: the big-log newest line\n")
PY

  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] ship-working - alpha: implement the parser (repo: alpha) (kind: ship) (since 2026-09-21)
- [ ] lane - alpha lane takeover: keep the lane alive (repo: alpha) (kind: ship) (since 2026-09-01)
- [ ] scout - mobile crash triage (repo: alpha) (kind: scout) (since 2026-09-21)
- [ ] cmux-surfaces-rehome-as-firstmate-tasks-v5 - Relaunch the migrated surfaces (repo: firstmate) (kind: ship) (since 2026-09-09)

## Done
- [x] done-a - alpha work a (repo: alpha) (kind: ship) (merged 2026-09-20)
- [x] done-b - alpha work b (repo: alpha) (kind: ship) (merged 2026-09-20)
- [x] done-c - alpha work c (repo: alpha) (kind: ship) (merged 2026-09-20)
- [x] ship-done-merged - alpha shipped (repo: alpha) (kind: ship) (merged 2026-09-21)
MD

  cat > "$home/data/cmux-takeover/expected-loops.json" <<'JSON'
{
  "schema": "fixture",
  "surfaces": {
    "aaaa": {"surface": "zzz-supervised-by-task", "term": "term_live", "slug": "live-surface", "firstmate_task": "ship-working"},
    "bbbb": {"surface": "zzz-supervised-by-substring", "term": "term_none", "slug": "big", "firstmate_task": null},
    "cccc": {"surface": "V3 AK", "term": "term_dead", "slug": "v3-ak", "firstmate_task": null},
    "dddd": {"surface": "Orphan surface", "term": "term_orphan", "slug": "orphan", "firstmate_task": null}
  }
}
JSON
  python3 - "$home" "$NOW" <<'PY'
import os
import sys

home, now = sys.argv[1], float(sys.argv[2])
heartbeat = os.path.join(home, "data", "cmux-takeover", "status", "v3-ak.json")
with open(heartbeat, "w") as handle:
    handle.write("{}\n")
os.utime(heartbeat, (now - 7200, now - 7200))
PY

  printf '%s\n' "$home"
}

run_roster() {  # <home>
  local home=$1
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_ROSTER_PEEK_CMD="" \
    FM_ROSTER_ORCA_CMD="" \
    FM_ROSTER_PS_CMD="" \
    FM_ROSTER_NOW_EPOCH="$NOW" \
    FM_ROSTER_CLAUDE_PROJECTS="$home/claude-projects" \
    FM_ROSTER_GROK_SESSIONS="$home/grok-sessions" \
    "$ROSTER"
}

HOME_DIR=$(build_home)

# A read-only report must not create, remove, or rewrite anything under the home.
before=$(find "$HOME_DIR" -type f | sort)
start=$(date +%s)
out=$(run_roster "$HOME_DIR") || fail "fm-roster.sh exited non-zero"
elapsed=$(( $(date +%s) - start ))
after=$(find "$HOME_DIR" -type f | sort)

[ "$before" = "$after" ] || fail "fm-roster.sh changed files under the home"

assert_contains "$out" "UNDER FIRSTMATE SUPERVISION" "the supervised table is missing"
assert_contains "$out" "NOT UNDER SUPERVISION" "the unsupervised table is missing"
assert_contains "$out" "Totals:" "the totals line is missing"

# Supervised rows.
assert_contains "$out" "working: implementing the parser" "the working task's doing-now line is missing"
assert_contains "$out" "pi / deepseek-v4.1-flash / high" "the model column is not harness/model/effort"
assert_contains "$out" "implementing (~3h" "the working ship estimate is missing"
assert_contains "$out" "median 4h of 3 done" "the estimate does not state its basis"
assert_contains "$out" "claude / opus[1m] / high" "the Claude model string is wrong"
assert_contains "$out" "idle until 07:15Z" "the standing lane's doing-now line is wrong"
assert_contains "$out" "standing - no end; next tick 07:15Z" "the standing lane has no estimate"
assert_contains "$out" "waiting on firstmate: waiting on the captain to supply the API credential" \
  "the blocked task is not mapped to waiting on firstmate"
assert_contains "$out" "blocked on firstmate" "the blocked task's estimate is missing"
assert_contains "$out" "PR open, awaiting merge" "the open PR is not reported as awaiting merge"
assert_contains "$out" "awaiting cleanup" "the merged task is not reported as awaiting cleanup"
assert_contains "$out" "report written" "the scout with a report is not marked written"
assert_contains "$out" "report due" "the scout without a report is not marked due"
assert_contains "$out" "setting up" "the no-status task is not reported as setting up"
assert_contains "$out" "(no status yet)" "the no-status task has no doing-now placeholder"
assert_contains "$out" "the big-log newest line" "the 5 MB status log's newest line was not read"

# The bounded read is the point of the 5 MB fixture.
[ "$elapsed" -le 20 ] || fail "the report took ${elapsed}s on a 5 MB status log"

# Unsupervised rows: only the surfaces with no live task appear.
assert_contains "$out" "migrated" "the migrated surface source is missing"
assert_contains "$out" "V3 AK" "the migrated surface with no task is missing"
assert_contains "$out" "Orphan surface" "the unmatched expected-loop entry is missing"
assert_contains "$out" "cmux-surfaces-rehome-as-firstmate-tasks-v5" "the relaunch backlog item is missing"
assert_contains "$out" "2.0h" "the migrated surface heartbeat age is missing"
assert_not_contains "$out" "zzz-supervised-by-task" "a surface linked to a live task was listed as unsupervised"
assert_not_contains "$out" "zzz-supervised-by-substring" "a surface matched by task-id token was listed as unsupervised"

# A clean Home with nothing running still renders both empty tables and exits 0.
empty_home="$TMP_ROOT/empty"
mkdir -p "$empty_home/state" "$empty_home/data"
empty_out=$(FM_HOME="$empty_home" FM_STATE_OVERRIDE="$empty_home/state" \
  FM_DATA_OVERRIDE="$empty_home/data" FM_ROSTER_PEEK_CMD="" FM_ROSTER_ORCA_CMD="" \
  FM_ROSTER_PS_CMD="" FM_ROSTER_NOW_EPOCH="$NOW" "$ROSTER") \
  || fail "fm-roster.sh failed on an empty home"
assert_contains "$empty_out" "(no supervised tasks in this home)" "the empty supervised table has no placeholder"
assert_contains "$empty_out" "(nothing outside firstmate's supervision is running)" \
  "the empty unsupervised table has no placeholder"

"$ROSTER" --help >/dev/null 2>&1 || fail "fm-roster.sh --help exited non-zero"
pass "the fleet roster reports supervised and unsupervised work, states its estimate basis, bounds its reads, and stays read-only"