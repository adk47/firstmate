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

# This file's lanes are real processes under the temp root, so the check must
# read the real process table; tests/lib.sh's suite-wide unreadable-table seam
# would turn every poll silent. The fixture paths are unique, so no host agent
# can match a lane.
unset FM_AGENT_PROC_TABLE

CHECK="$ROOT/bin/fm-fleet-integrity-check.sh"
assert_present "$CHECK" "bin/fm-fleet-integrity-check.sh is missing"
[ -x "$CHECK" ] || fail "bin/fm-fleet-integrity-check.sh must be executable"

TMP_ROOT=$(fm_test_tmproot fm-fleet-integrity)

# A live process whose cwd is <dir> and whose process name is <name>, so the
# shared process vocabulary classifies it as an agent.
spawn_named_process() {  # <dir> <name> <cwd>
  fm_spawn_live_agent_fixture "$1" "$2" "$3"
}

# A bare shell in <dir> with no child process: the shape a hard-killed agent
# leaves behind, because fm-spawn creates the pane with -c <worktree>.
spawn_shell_in() {  # <cwd>
  ( cd "$1" && exec bash -c 'read -r -t 300 _ < /dev/zero' ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# A home with one IN-FLIGHT lane per <id>:<worktree> pair - a task record plus a
# busy-state record - plus a stamp that is already due so the self-throttle does
# not swallow the poll. The busy-state record is a claim, not the lane filter.
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
# record. It is still walked, because a lane between turns can still be dead.
make_idle_lane() {  # <case-dir> <id> <worktree>
  local d=$1 id=$2 wt=$3 gen
  fm_write_meta "$d/state/$id.meta" "window=fm:fm-$id" "worktree=$wt" "kind=ship" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# A worktree holding one commit and no remote, so its commits are unpushed.
git_worktree_with_unlanded_commit() {  # <dir>
  mkdir -p "$1" || return 1
  git -C "$1" init -q || return 1
  git -C "$1" -c user.name=fm -c user.email=fm@example.invalid commit -q --allow-empty -m unlanded || return 1
}

run_check() {  # <case-dir>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CHECK" check
}

# A repo whose default branch main holds one commit.
init_branch_repo() {  # <dir>
  mkdir -p "$1" || return 1
  git -C "$1" init -q || return 1
  git -C "$1" symbolic-ref HEAD refs/heads/main || return 1
  git -C "$1" -c user.name=fm -c user.email=fm@example.invalid commit -q --allow-empty -m base || return 1
}

commit_file() {  # <dir> <name> <content>
  printf '%s\n' "$3" >"$1/$2" || return 1
  git -C "$1" add "$2" || return 1
  git -C "$1" -c user.name=fm -c user.email=fm@example.invalid commit -q -m "$2" || return 1
}

# A home with one lane whose last status-log line is <status-line>, its worktree
# ready, and a live agent in that worktree so the dead-lane line never fires.
make_terminal_lane() {  # <case-dir> <worktree> <status-line>
  local d=$1 wt=$2 status=$3
  make_home "$d" "lane-a:$wt"
  printf '%s\n' "$status" >"$d/state/lane-a.status"
  spawn_named_process "$d/bin" pi "$wt" >/dev/null || return 1
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

# --- a lane between turns is still walked ----------------------------------

test_idle_lane_is_walked() {
  local d out
  d="$TMP_ROOT/idle"
  mkdir -p "$d/idle-a"
  mkdir -p "$d/state"
  make_idle_lane "$d" "lane-idle" "$d/idle-a"
  spawn_shell_in "$d/idle-a" >/dev/null || fail "could not spawn lane-idle's shell"
  printf '0\n' > "$d/state/.fleet-integrity.last"
  sleep 0.2
  out=$(run_check "$d")
  assert_contains "$out" "lane-idle" \
    "a lane whose busy record reads idle is still walked and its dead worktree is reported"
  pass "a lane between turns is still walked"
}

# --- a non-working claim that disagrees with the worktree is reported ------

test_done_claim_with_uncommitted_work_is_reported() {
  local d out
  d="$TMP_ROOT/done-dirty"
  mkdir -p "$d/done-a"
  make_home "$d" "lane-done:$d/done-a"
  git -C "$d/done-a" init -q || fail "could not init the lane worktree"
  printf 'uncommitted\n' > "$d/done-a/leftover.txt"
  printf 'done: finished the task\n' > "$d/state/lane-done.status"
  spawn_named_process "$d/bin" pi "$d/done-a" >/dev/null || fail "could not spawn lane-done's agent"
  sleep 0.2
  out=$(run_check "$d")
  assert_contains "$out" "lane-done" "a done lane still holding uncommitted work must be reported"
  assert_contains "$out" "claims done" "the report names the lane's claim"
  assert_contains "$out" "uncommitted" "the report names the worktree's uncommitted work"
  pass "a non-working claim that disagrees with the worktree is reported"
}

# --- only a terminal claim is compared with the worktree -------------------

# A freshly spawned lane writes no status line until its crew reports one, so it
# has no claim at all. That is not a disagreeing claim, and a dirty worktree at
# that moment is expected.
test_lane_without_a_claim_is_silent() {
  local d out
  d="$TMP_ROOT/no-claim"
  mkdir -p "$d/fresh-a"
  make_home "$d" "lane-fresh:$d/fresh-a"
  git -C "$d/fresh-a" init -q || fail "could not init the lane worktree"
  printf 'uncommitted\n' > "$d/fresh-a/wip.txt"
  spawn_named_process "$d/bin" pi "$d/fresh-a" >/dev/null || fail "could not spawn lane-fresh's agent"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a lane with no status line is not a disagreeing claim, got: $out"
  pass "a freshly spawned lane with a dirty worktree and no claim is silent"
}

# `resolved:` is a decision-closing event that bin/fm-classify-lib.sh
# deliberately keeps out of run-state, so a lane whose last line is `resolved:`
# has no claim either.
test_lane_whose_last_line_is_resolved_is_silent() {
  local d out
  d="$TMP_ROOT/resolved-claim"
  mkdir -p "$d/resolved-a"
  make_home "$d" "lane-resolved:$d/resolved-a"
  git -C "$d/resolved-a" init -q || fail "could not init the lane worktree"
  printf 'uncommitted\n' > "$d/resolved-a/wip.txt"
  printf 'resolved: the decision was closed\n' > "$d/state/lane-resolved.status"
  spawn_named_process "$d/bin" pi "$d/resolved-a" >/dev/null || fail "could not spawn lane-resolved's agent"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a trailing resolved: is not a claim, got: $out"
  pass "a lane whose last status line is resolved: is silent"
}

# A waiting lane (parked, paused, blocked) is not finished with its worktree, so
# unlanded commits there are expected rather than a disagreement.
test_parked_lane_with_unlanded_commits_is_silent() {
  local d out
  d="$TMP_ROOT/parked-claim"
  make_home "$d" "lane-parked:$d/parked-a"
  git_worktree_with_unlanded_commit "$d/parked-a" || fail "could not prepare the lane worktree"
  printf 'needs-decision: which option?\n' > "$d/state/lane-parked.status"
  spawn_named_process "$d/bin" pi "$d/parked-a" >/dev/null || fail "could not spawn lane-parked's agent"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a parked lane is not a finished claim, got: $out"
  pass "a parked lane with unlanded commits is silent"
}

# --- a cleared condition clears the recorded verdict -----------------------

test_cleared_condition_clears_the_record() {
  local d out
  d="$TMP_ROOT/cleared"
  mkdir -p "$d/dead-a"
  make_home "$d" "lane-a:$d/dead-a"
  spawn_shell_in "$d/dead-a" >/dev/null || fail "could not spawn lane-a's shell"
  sleep 0.2
  out=$(run_check "$d")
  assert_contains "$out" "lane-a" "the dead lane is reported first"
  assert_present "$d/state/.fleet-integrity" "the verdict is recorded"
  rm -rf -- "$d/dead-a"
  printf '0\n' > "$d/state/.fleet-integrity.last"
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a cleared lane set must be silent, got: $out"
  assert_absent "$d/state/.fleet-integrity" "a cleared condition must clear the recorded verdict"
  pass "a cleared condition clears the recorded verdict"
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
test_idle_lane_is_walked
test_done_claim_with_uncommitted_work_is_reported
test_lane_without_a_claim_is_silent
test_lane_whose_last_line_is_resolved_is_silent
test_parked_lane_with_unlanded_commits_is_silent
test_cleared_condition_clears_the_record
test_remote_secondmate_is_skipped
test_torn_down_worktree_is_skipped
test_self_throttles_on_the_stamp
test_arm_writes_and_binds_the_shim

# --- the terminal-claim comparison uses the shared landed-work rule --------

# --- the required dead-lane line is never starved by optional probes ---------

# A git wrapper whose merge-tree (only the landed-work content probe runs it)
# blocks far longer than the check's bound, so every terminal lane that needs a
# landed test spends its whole cap.
make_slow_landed_git() {  # <dir>
  local toolbin=$1 real_git
  real_git=$(command -v git) || return 1
  mkdir -p "$toolbin" || return 1
  cat >"$toolbin/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  [ "\$a" != merge-tree ] || sleep 30
done
exec "$real_git" "\$@"
EOF
  chmod +x "$toolbin/git" || return 1
}

test_dead_lane_is_reported_inside_the_timeout_despite_slow_landed_probes() {
  local d start elapsed out
  d="$TMP_ROOT/slow-landed-dead"
  mkdir -p "$d/dead-a" "$d/done-b" "$d/done-c"
  make_home "$d" "lane-dead:$d/dead-a" "lane-b:$d/done-b" "lane-c:$d/done-c"
  spawn_shell_in "$d/dead-a" >/dev/null || fail "could not spawn the dead lane's shell"
  git_worktree_with_unlanded_commit "$d/done-b" || fail "could not prepare lane-b's worktree"
  git_worktree_with_unlanded_commit "$d/done-c" || fail "could not prepare lane-c's worktree"
  printf 'done: shipped\n' >"$d/state/lane-b.status"
  printf 'done: shipped\n' >"$d/state/lane-c.status"
  spawn_named_process "$d/bin" pi "$d/done-b" >/dev/null || fail "could not spawn lane-b's agent"
  spawn_named_process "$d/bin" claude "$d/done-c" >/dev/null || fail "could not spawn lane-c's agent"
  make_slow_landed_git "$d/toolbin" || fail "could not build the slow git wrapper"
  sleep 0.2
  start=$(date +%s)
  out=$(PATH="$d/toolbin:$PATH" FM_CHECK_TIMEOUT=6 run_check "$d")
  elapsed=$(($(date +%s) - start))
  [ "$elapsed" -lt 6 ] \
    || fail "the poll must finish inside FM_CHECK_TIMEOUT, took ${elapsed}s"
  assert_contains "$out" "lane-dead" \
    "the required dead-lane line must be printed even when every optional landed probe is slow"
  pass "a slow landed probe cannot starve the dead-lane line or overrun the timeout"
}

test_all_live_fleet_is_silent_despite_slow_landed_probes() {
  local d out
  d="$TMP_ROOT/slow-landed-live"
  mkdir -p "$d/done-a"
  make_home "$d" "lane-a:$d/done-a"
  git_worktree_with_unlanded_commit "$d/done-a" || fail "could not prepare lane-a's worktree"
  printf 'done: shipped\n' >"$d/state/lane-a.status"
  spawn_named_process "$d/bin" pi "$d/done-a" >/dev/null || fail "could not spawn lane-a's agent"
  make_slow_landed_git "$d/toolbin" || fail "could not build the slow git wrapper"
  sleep 0.2
  out=$(PATH="$d/toolbin:$PATH" FM_CHECK_TIMEOUT=6 run_check "$d")
  [ -z "$out" ] || fail "a fleet with every lane live must stay silent, got: $out"
  pass "a live fleet is silent even when the optional landed probes are slow"
}

# A squash merge whose head branch was deleted must not read as a disagreement.
test_squash_merged_and_deleted_lane_is_silent() {
  local d out
  d="$TMP_ROOT/done-squash"
  mkdir -p "$d"
  git init -q --bare "$d/remote.git" || fail "could not create the remote"
  init_branch_repo "$d/seed" || fail "could not seed the project"
  git -C "$d/seed" remote add origin "$d/remote.git" || fail "could not add the remote"
  git -C "$d/seed" push -q -u origin main || fail "could not push main"
  git -C "$d/remote.git" symbolic-ref HEAD refs/heads/main || fail "could not point the remote HEAD at main"
  git clone -q "$d/remote.git" "$d/lane" || fail "could not clone the lane"
  git -C "$d/lane" checkout -q -b feat || fail "could not branch the lane"
  commit_file "$d/lane" feature.txt feature || fail "could not commit the lane work"
  commit_file "$d/seed" feature.txt feature || fail "could not squash the work"
  git -C "$d/seed" push -q origin main || fail "could not push the squash"
  make_terminal_lane "$d" "$d/lane" "done: shipped" || fail "could not prepare the lane"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a squash-merged lane whose head branch is gone must be silent, got: $out"
  pass "a squash-merged-then-deleted lane is not reported as unlanded"
}

# A local-only project whose work is merged into its local default branch must
# not read as a disagreement.
test_local_only_merged_lane_is_silent() {
  local d out
  d="$TMP_ROOT/done-local-only"
  init_branch_repo "$d/lane" || fail "could not build the local-only repo"
  git -C "$d/lane" checkout -q -b feat || fail "could not branch the local repo"
  commit_file "$d/lane" feature.txt feature || fail "could not commit the local work"
  git -C "$d/lane" checkout -q main || fail "could not return to main"
  git -C "$d/lane" -c user.name=fm -c user.email=fm@example.invalid merge -q --no-ff -m merge feat || fail "could not merge locally"
  make_terminal_lane "$d" "$d/lane" "done: shipped" || fail "could not prepare the lane"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "local-only work merged into the local default branch must be silent, got: $out"
  pass "local-only merged work is not reported as unlanded"
}

# Work that exists nowhere and is not in the default branch is a real
# disagreement and must be reported.
test_genuinely_unlanded_lane_is_reported() {
  local d out
  d="$TMP_ROOT/done-unlanded"
  init_branch_repo "$d/lane" || fail "could not build the unlanded repo"
  git -C "$d/lane" checkout -q -b feat || fail "could not branch the unlanded repo"
  commit_file "$d/lane" lost.txt "only here" || fail "could not commit the unlanded work"
  make_terminal_lane "$d" "$d/lane" "done: shipped" || fail "could not prepare the lane"
  sleep 0.2
  out=$(run_check "$d")
  case "$out" in
    *"lane lane-a claims done"*) ;;
    *) fail "a done lane holding provably unlanded work must be reported, got: $out" ;;
  esac
  case "$out" in
    *"not landed"*) ;;
    *) fail "the report must say the work is not landed, got: $out" ;;
  esac
  pass "a done lane whose work exists nowhere and is not in the default branch is reported"
}

# A repo the landed test cannot read proves nothing, so it stays silent.
test_unprovable_landing_is_silent() {
  local d out
  d="$TMP_ROOT/done-unprovable"
  init_branch_repo "$d/lane" || fail "could not build the unprovable repo"
  git -C "$d/lane" checkout -q -b feat || fail "could not branch the unprovable repo"
  git -C "$d/lane" -c user.name=fm -c user.email=fm@example.invalid commit -q --allow-empty -m work || fail "could not commit the unprovable work"
  git -C "$d/lane" remote add origin "$d/does-not-exist.git" || fail "could not add the dead remote"
  make_terminal_lane "$d" "$d/lane" "done: shipped" || fail "could not prepare the lane"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a lane whose landing cannot be proven must be silent, got: $out"
  pass "a lane whose landing cannot be proven is not reported"
}

# --- the shared process-table owner supplies the verdicts -------------------

test_lane_whose_record_is_symlinked_still_reads_live() {
  local d out
  d="$TMP_ROOT/symlinked-record"
  mkdir -p "$d/real/wt"
  ln -s "$d/real" "$d/link" || fail "could not create the symlinked component"
  make_home "$d" "lane-sym:$d/link/wt"
  spawn_named_process "$d/bin" pi "$d/real/wt" >/dev/null || fail "could not spawn lane-sym's agent"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a live agent whose physical cwd is the symlinked record's target must be silent, got: $out"
  pass "a live agent in a symlinked-record worktree is not reported dead"
}

test_sibling_path_prefix_is_not_live() {
  local d out
  d="$TMP_ROOT/prefix-sibling"
  mkdir -p "$d/fm-a" "$d/fm-ab"
  make_home "$d" "lane-a:$d/fm-a"
  spawn_named_process "$d/bin" pi "$d/fm-ab" >/dev/null || fail "could not spawn the sibling's agent"
  sleep 0.2
  out=$(run_check "$d")
  assert_contains "$out" "lane-a" \
    "a worktree whose path is only a string prefix of a live sibling must still be reported dead"
  pass "a bare path prefix does not make a sibling worktree live"
}

test_unclassifiable_process_is_not_reported() {
  local d out
  d="$TMP_ROOT/unclassifiable"
  mkdir -p "$d/wt"
  make_home "$d" "lane-odd:$d/wt"
  spawn_named_process "$d/bin" fm-not-a-harness "$d/wt" >/dev/null \
    || fail "could not spawn the unclassifiable fixture"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] || fail "a worktree holding only an unclassifiable process must be silent, got: $out"
  pass "an unclassifiable process is never reported as a dead lane"
}

test_lane_whose_harness_vocabulary_cannot_name_is_not_reported() {
  local d out
  d="$TMP_ROOT/unnamed-harness"
  mkdir -p "$d/wt"
  make_home "$d" "lane-weird:$d/wt"
  printf 'harness=not-a-known-harness\n' >>"$d/state/lane-weird.meta"
  spawn_shell_in "$d/wt" >/dev/null || fail "could not spawn the lane's shell"
  sleep 0.2
  out=$(run_check "$d")
  [ -z "$out" ] \
    || fail "a lane whose harness the vocabulary cannot name is not provably dead, got: $out"
  pass "a lane whose harness cannot be recognized is never reported dead"
}

test_unreadable_process_table_is_silent() {
  local d out
  d="$TMP_ROOT/unreadable-table"
  mkdir -p "$d/wt"
  make_home "$d" "lane-a:$d/wt"
  spawn_shell_in "$d/wt" >/dev/null || fail "could not spawn the lane's shell"
  out=$(FM_AGENT_PROC_TABLE=/nonexistent/fm-fleet-integrity-table \
    FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$CHECK" check)
  [ -z "$out" ] || fail "an unreadable process table is no evidence of death, got: $out"
  [ "$(cat "$d/state/.fleet-integrity.last")" = 0 ] \
    || fail "a poll that could not read the table must not write its throttle stamp"
  pass "an unreadable process table is silent and does not consume the interval"
}

# A process-table read that hangs must be cut at the check's bound, leave the
# stamp untouched, and be retried by the next poll.
test_hung_process_table_is_bounded_and_retried() {
  local d start elapsed out toolbin
  d="$TMP_ROOT/hung-table"
  mkdir -p "$d/wt"
  make_home "$d" "lane-a:$d/wt"
  spawn_shell_in "$d/wt" >/dev/null || fail "could not spawn the lane's shell"
  toolbin="$d/toolbin"
  mkdir -p "$toolbin"
  printf '#!/bin/bash\nsleep 30\n' >"$toolbin/ps"
  chmod +x "$toolbin/ps"
  start=$(date +%s)
  out=$(PATH="$toolbin:$PATH" FM_CHECK_TIMEOUT=4 run_check "$d")
  elapsed=$(($(date +%s) - start))
  [ "$elapsed" -lt 4 ] || fail "a hung table read must be bounded, took ${elapsed}s"
  [ -z "$out" ] || fail "a hung table read is no evidence of death, got: $out"
  [ "$(cat "$d/state/.fleet-integrity.last")" = 0 ] \
    || fail "a poll that could not finish its scan must not write its throttle stamp"
  out=$(run_check "$d")
  assert_contains "$out" "lane-a" "the next poll must retry the scan and report the dead lane"
  pass "a hung process-table read is bounded, silent, and retried on the next poll"
}

# A per-lane worktree resolve that wedges must be cut at the check's bound too,
# leave the stamp untouched, and be retried by the next poll.
test_wedged_worktree_resolution_is_bounded_and_retried() {
  local d start elapsed out
  d="$TMP_ROOT/wedged-resolve"
  mkdir -p "$d/wt"
  make_home "$d" "lane-a:$d/wt"
  pwd() {
    if [ -n "${FM_TEST_WEDGE_DIR:-}" ] && [ "$PWD" = "$FM_TEST_WEDGE_DIR" ]; then
      sleep 300
    fi
    builtin pwd "$@"
  }
  export -f pwd
  export FM_TEST_WEDGE_DIR="$d/wt"
  start=$(date +%s)
  out=$(FM_CHECK_TIMEOUT=4 run_check "$d")
  elapsed=$(($(date +%s) - start))
  unset -f pwd
  unset FM_TEST_WEDGE_DIR
  [ "$elapsed" -le 4 ] || fail "a wedged worktree resolve must be bounded, took ${elapsed}s"
  [ -z "$out" ] || fail "a wedged worktree resolve is no evidence of death, got: $out"
  [ "$(cat "$d/state/.fleet-integrity.last")" = 0 ] \
    || fail "a poll that could not finish its verdict loop must not write its throttle stamp"
  out=$(run_check "$d")
  assert_contains "$out" "lane-a" "the next poll must retry the verdict and report the dead lane"
  pass "a wedged worktree resolve is bounded, silent, and retried on the next poll"
}

test_lane_whose_record_is_symlinked_still_reads_live
test_sibling_path_prefix_is_not_live
test_unclassifiable_process_is_not_reported
test_lane_whose_harness_vocabulary_cannot_name_is_not_reported
test_unreadable_process_table_is_silent
test_hung_process_table_is_bounded_and_retried
test_wedged_worktree_resolution_is_bounded_and_retried
test_squash_merged_and_deleted_lane_is_silent
test_local_only_merged_lane_is_silent
test_genuinely_unlanded_lane_is_reported
test_unprovable_landing_is_silent
test_dead_lane_is_reported_inside_the_timeout_despite_slow_landed_probes
test_all_live_fleet_is_silent_despite_slow_landed_probes

echo "all fm-fleet-integrity-check tests passed"
