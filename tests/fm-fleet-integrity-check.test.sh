#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-integrity-check.sh - the registered watcher
# check that notices a lane whose agent process is gone while its worktree and
# records remain.
#
# The 2026-11-05 failure: the default tmux server was lost and the fleet lost
# roughly 27 lanes, but the health read trusted a state/<id>.busy-state record
# that never settles when an agent is hard-killed, so dead lanes kept reporting
# working and the fleet was counted 11, then 15, then 27 dead in three
# successive reads. This check is the fleet-wide backstop: one bounded scan,
# one line only when the dead set is non-empty, silence otherwise.
#
# Both directions are pinned: silent when every lane has a live agent, one line
# naming exactly the dead lanes when some do not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-fleet-integrity-check.sh"
assert_present "$CHECK" "bin/fm-fleet-integrity-check.sh is missing"
[ -x "$CHECK" ] || fail "bin/fm-fleet-integrity-check.sh must be executable"

TMP_ROOT=$(fm_test_tmproot fm-fleet-integrity)

# A live process whose cwd is <dir> and whose process name is <name>. A copy of
# `sleep` under the wanted name is what makes `ps -o comm=` report that name, so
# the shared process vocabulary classifies it as an agent.
spawn_named_process() {  # <dir> <name> <cwd>
  local dir=$1 name=$2 cwd=$3 bin="$1/$2"
  mkdir -p "$dir"
  cp "$(command -v sleep)" "$bin" || return 1
  chmod +x "$bin" || return 1
  ( cd "$cwd" && exec "$bin" 300 ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# A bare shell in <dir> with no child process: the shape a hard-killed agent
# leaves behind, because fm-spawn creates the pane with -c <worktree>.
spawn_shell_in() {  # <cwd>
  ( cd "$1" && exec bash -c 'read -r -t 300 _ < /dev/zero' ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# A home with one IN-FLIGHT lane per <id>:<worktree> pair - a task record plus a
# busy-state record that claims the lane is working, which is what puts it in
# the check's lane set - plus a stamp that is already due so the self-throttle
# does not swallow the poll.
make_home() {  # <case-dir> <id>:<worktree>...
  local d=$1 spec id wt gen
  shift
  mkdir -p "$d/state"
  for spec in "$@"; do
    id=${spec%%:*}
    wt=${spec#*:}
    fm_write_meta "$d/state/$id.meta" "window=fm:fm-$id" "worktree=$wt" "kind=ship" "harness=claude"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" "$id")
    "$ROOT/bin/fm-busy-event.sh" apply "$d/state" "$id" busy --gen "$gen" \
      --source claude-hook --event user-prompt-submit
  done
  printf '0\n' > "$d/state/.fleet-integrity.last"
}

# A lane that is NOT claiming to be working: a task record with an idle busy
# record. It must never be walked, however dead its worktree looks.
make_idle_lane() {  # <case-dir> <id> <worktree>
  local d=$1 id=$2 wt=$3 gen
  fm_write_meta "$d/state/$id.meta" "window=fm:fm-$id" "worktree=$wt" "kind=ship" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

run_check() {  # <case-dir>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CHECK" check
}

# --- silent when every lane is live ----------------------------------------

test_silent_when_every_lane_is_live() {
  local d out
  d="$TMP_ROOT/all-live"
  mkdir -p "$d/live-a" "$d/live-b"
  make_home "$d" "lane-a:$d/live-a" "lane-b:$d/live-b"
  spawn_named_process "$d/bin" pi "$d/live-a" >/dev/null || fail "could not spawn lane-a's agent"
  spawn_named_process "$d/bin" claude "$d/live-b" >/dev/null || fail "could not spawn lane-b's agent"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a fleet with every lane live must be silent, got: $out"
  pass "the check is silent when every lane has a live agent"
}

# --- one line naming exactly the dead lanes --------------------------------

test_names_exactly_the_dead_lanes() {
  local d out
  d="$TMP_ROOT/some-dead"
  mkdir -p "$d/live-a" "$d/dead-b" "$d/dead-c"
  make_home "$d" "lane-a:$d/live-a" "lane-b:$d/dead-b" "lane-c:$d/dead-c"
  spawn_named_process "$d/bin" pi "$d/live-a" >/dev/null || fail "could not spawn lane-a's agent"
  spawn_shell_in "$d/dead-b" >/dev/null || fail "could not spawn lane-b's shell"
  sleep 0.2
  out=$(run_check "$d")
  [ -n "$out" ] || fail "a fleet with dead lanes must wake firstmate"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the check must print exactly ONE line, got: $out"
  assert_contains "$out" "fleet-integrity:" "the line names the check"
  assert_contains "$out" "lane-b" "the line names the shell-only lane"
  assert_contains "$out" "lane-c" "the line names the empty lane"
  assert_not_contains "$out" "lane-a" "the line must not name a live lane"
  pass "the check prints one line naming exactly the dead lanes"
}

# --- a lane that is not claiming to be working is not walked ---------------

test_idle_lane_is_not_walked() {
  local d out
  d="$TMP_ROOT/idle"
  mkdir -p "$d/idle-a"
  mkdir -p "$d/state"
  make_idle_lane "$d" "lane-idle" "$d/idle-a"
  printf '0\n' > "$d/state/.fleet-integrity.last"
  out=$(run_check "$d")
  [ -z "$out" ] \
    || fail "a lane whose record reads idle is not claiming to be working and must not be walked, got: $out"
  pass "a lane that is not claiming to be working is not walked"
}

# --- a remote secondmate is not probed locally -----------------------------

test_remote_secondmate_is_skipped() {
  local d out
  d="$TMP_ROOT/remote"
  mkdir -p "$d/remote-wt"
  make_home "$d" "mate-r:$d/remote-wt"
  printf 'remote_host=node-2\n' >> "$d/state/mate-r.meta"
  out=$(run_check "$d")
  [ -z "$out" ] \
    || fail "a remote secondmate's worktree path names another host and must not be probed, got: $out"
  pass "a remote secondmate is skipped rather than probed locally"
}

# --- a torn-down worktree is not a lane ------------------------------------

test_torn_down_worktree_is_skipped() {
  local d out
  d="$TMP_ROOT/torn-down"
  mkdir -p "$d"
  make_home "$d" "gone-a:$d/no-such-worktree"
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a lane whose worktree is gone is not a dead lane, got: $out"
  pass "a lane whose worktree is gone is skipped"
}

# --- self-throttle ---------------------------------------------------------

test_self_throttles_on_the_stamp() {
  local d out now
  d="$TMP_ROOT/throttle"
  mkdir -p "$d/dead-a"
  make_home "$d" "lane-a:$d/dead-a"
  now=$(date +%s)
  printf '%s\n' "$now" > "$d/state/.fleet-integrity.last"
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a poll inside the throttle window must be silent, got: $out"
  # Once the stamp is old enough the same home reports.
  printf '%s\n' "$((now - 100000))" > "$d/state/.fleet-integrity.last"
  out=$(run_check "$d")
  assert_contains "$out" "lane-a" "a due poll reports the dead lane"
  pass "the check self-throttles on its stamp file"
}

# --- arm / disarm ----------------------------------------------------------

test_arm_writes_and_binds_the_shim() {
  local d out
  d="$TMP_ROOT/arm"
  mkdir -p "$d/state"
  out=$(FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$CHECK" arm) \
    || fail "arm failed: $out"
  assert_contains "$out" "armed: state/fleet-integrity.check.sh" "arm reports the shim"
  assert_present "$d/state/fleet-integrity.check.sh" "the shim exists"
  assert_present "$d/state/fleet-integrity.check-trust" "the shim's bytes are bound"
  [ "$(stat -c %a "$d/state/fleet-integrity.check.sh" 2>/dev/null || stat -f %Lp "$d/state/fleet-integrity.check.sh")" = 700 ] \
    || fail "the shim must be mode 0700"
  out=$(FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$CHECK" disarm) \
    || fail "disarm failed: $out"
  assert_absent "$d/state/fleet-integrity.check.sh" "disarm removes the shim"
  assert_absent "$d/state/fleet-integrity.check-trust" "disarm removes the trust binding"
  pass "arm writes and binds the shim; disarm retires it"
}

test_silent_when_every_lane_is_live
test_names_exactly_the_dead_lanes
test_idle_lane_is_not_walked
test_remote_secondmate_is_skipped
test_torn_down_worktree_is_skipped
test_self_throttles_on_the_stamp
test_arm_writes_and_binds_the_shim

echo "all fm-fleet-integrity-check tests passed"
