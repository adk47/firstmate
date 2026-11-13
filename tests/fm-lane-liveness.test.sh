#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-liveness-lib.sh - the ONE owner of "is a live
# agent process actually running in this lane's worktree?".
#
# The 2026-11-05 failure: state/<id>.busy-state is a durable record a harness
# hook writes, and nothing clears it when the agent is hard-killed, so a dead
# lane kept reporting working and the fleet was counted 11, then 15, then 27
# dead in three successive reads. This library is the missing half - a live
# process whose cwd is the recorded worktree and whose name classifies as an
# agent - and these cases pin all three verdicts in both directions:
#   live            a real agent-named process sits in the worktree
#   dead            the worktree holds only a shell, or nothing at all
#   undeterminable  the worktree holds a process the vocabulary cannot classify
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-lane-liveness-lib.sh
. "$ROOT/bin/fm-lane-liveness-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lane-liveness)

# A live process whose cwd is <dir> and whose process name is <name>. A copy of
# `sleep` under the wanted name is what makes `ps -o comm=` report that name, so
# the shared process vocabulary classifies it exactly as it would a real
# harness. fm_test_cleanup reaps it with the temp root.
spawn_named_process() {  # <dir> <name> <cwd>
  local dir=$1 name=$2 cwd=$3 bin="$1/$2"
  mkdir -p "$dir"
  cp "$(command -v sleep)" "$bin" || return 1
  chmod +x "$bin" || return 1
  # The child's stdio is detached: a background process holding the caller's
  # stdout pipe would make a `$(...)` capture wait for its whole lifetime.
  ( cd "$cwd" && exec "$bin" 300 ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# A live process shaped like the Gemini CLI: an interpreter whose comm and
# argv[0] say node, while only the script argument names gemini (measured shape
# in bin/fm-gemini-lib.sh). A copy of `bash` running a blocking script keeps the
# process name `node` while the command line carries the gemini path.
spawn_gemini_process() {  # <dir> <cwd>
  local dir=$1 cwd=$2 bin="$1/node" script="$1/gemini"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$bin" || return 1
  chmod +x "$bin" || return 1
  printf 'read -r -t 300 _ < /dev/zero\n' >"$script" || return 1
  ( cd "$cwd" && exec "$bin" "$script" -y ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# A live shell whose cwd is <dir>: the shape a hard-killed agent leaves behind,
# because fm-spawn creates the pane with -c <worktree>.
spawn_shell_in() {  # <cwd>
  # A builtin `read` with a timeout blocks the shell itself, so the fixture is
  # a bare shell with NO child process - the exact shape a hard-killed agent
  # leaves behind. A `sleep` child would inherit the worktree cwd and be
  # classified as an unclassifiable process instead.
  ( cd "$1" && exec bash -c 'read -r -t 300 _ < /dev/zero' ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

wait_for_process() {  # <pid>
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -d "/proc/$1" ] && return 0
    i=$((i + 1))
    sleep 0.02
  done
  return 0
}

# --- live -------------------------------------------------------------------

test_live_agent_in_worktree() {
  local d wt pid rc
  d="$TMP_ROOT/live"
  wt="$d/wt"
  mkdir -p "$wt"
  pid=$(spawn_named_process "$d/bin" pi "$wt") || fail "could not spawn the agent fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a live agent process in the worktree must read live (got $rc)"
  pass "a live agent process in the worktree reads live"
}

test_live_agent_in_subdirectory_counts() {
  local d wt pid rc
  d="$TMP_ROOT/live-sub"
  wt="$d/wt"
  mkdir -p "$wt/pkg"
  pid=$(spawn_named_process "$d/bin" claude "$wt/pkg") || fail "could not spawn the agent fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 0 ] || fail "an agent working in a worktree subdirectory must read live (got $rc)"
  pass "an agent working in a worktree subdirectory reads live"
}

# --- dead -------------------------------------------------------------------

test_shell_only_worktree_is_dead() {
  local d wt pid rc
  d="$TMP_ROOT/shell-only"
  wt="$d/wt"
  mkdir -p "$wt"
  pid=$(spawn_shell_in "$wt") || fail "could not spawn the shell fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a worktree holding only a shell must read dead, not live (got $rc)"
  pass "a worktree holding only a shell reads dead - the hard-kill shape"
}

test_gemini_shaped_agent_in_worktree() {
  local d wt pid rc
  d="$TMP_ROOT/gemini"
  wt="$d/wt"
  mkdir -p "$wt"
  pid=$(spawn_gemini_process "$d/bin" "$wt") || fail "could not spawn the gemini fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a live gemini-shaped node process in the worktree must read live (got $rc)"
  pass "a live gemini-shaped node process reads live from its arguments"
}

test_empty_worktree_is_dead() {
  local d wt rc
  d="$TMP_ROOT/empty"
  wt="$d/wt"
  mkdir -p "$wt"
  fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 1 ] || fail "a worktree holding nothing at all must read dead (got $rc)"
  pass "a worktree holding nothing at all reads dead"
}

# --- undeterminable ---------------------------------------------------------

test_unclassifiable_process_is_undeterminable() {
  local d wt pid rc
  d="$TMP_ROOT/other"
  wt="$d/wt"
  mkdir -p "$wt"
  # A name the shared vocabulary classifies as neither an agent nor a shell.
  pid=$(spawn_named_process "$d/bin" fm-not-a-harness "$wt") \
    || fail "could not spawn the unclassifiable fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 2 ] \
    || fail "a worktree holding an unclassifiable process must read undeterminable, never dead (got $rc)"
  pass "a worktree holding an unclassifiable process reads undeterminable, never dead"
}

test_missing_lsof_is_undeterminable() {
  local d wt rc toolbin tool real
  d="$TMP_ROOT/no-lsof"
  wt="$d/wt"
  toolbin="$d/toolbin"
  mkdir -p "$wt" "$toolbin"
  # A PATH with the tools the probe needs but deliberately no lsof.
  for tool in bash ps grep sed awk cat; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || continue
    ln -s "$real" "$toolbin/$tool"
  done
  PATH="$toolbin" fm_lane_agent_live_in_worktree "$wt"
  rc=$?
  [ "$rc" -eq 2 ] \
    || fail "a missing lsof must read undeterminable, never dead (got $rc)"
  pass "a missing lsof reads undeterminable, never dead"
}

# --- path forms -------------------------------------------------------------

# bin/fm-spawn.sh records the worktree with bash's LOGICAL pwd, so a project
# reached through a symlinked component is recorded logically while the agent's
# kernel cwd is the physical path. The liveness match must still see it live.
test_live_agent_through_symlinked_record_reads_live() {
  local d real link pid rc out
  d="$TMP_ROOT/symlink-live"
  real="$d/real"
  link="$d/link"
  mkdir -p "$real/wt"
  ln -s "$real" "$link" || fail "could not create the symlinked component"
  pid=$(spawn_named_process "$d/bin" pi "$real/wt") || fail "could not spawn the agent fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$link/wt"
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a live agent whose physical cwd is a symlinked record's target must read live (got $rc)"
  out=$(fm_lane_dead_worktrees "$link/wt") || fail "the fleet scan must succeed"
  assert_not_contains "$out" "$link/wt" "a live symlinked lane must not be reported dead"
  pass "a live agent in a symlinked-record worktree reads live"
}

# /x/fm-a must never claim the process that actually sits in /x/fm-ab: a bare
# string prefix is not a path-component boundary.
test_sibling_path_prefix_is_not_live() {
  local d a ab pid rc out
  d="$TMP_ROOT/prefix-sibling"
  a="$d/fm-a"
  ab="$d/fm-ab"
  mkdir -p "$a" "$ab"
  pid=$(spawn_named_process "$d/bin" pi "$ab") || fail "could not spawn the agent fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$a"
  rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a sibling whose path only starts with the recorded path must not read live (got $rc)"
  out=$(fm_lane_dead_worktrees "$a" "$ab") || fail "the fleet scan must succeed"
  assert_contains "$out" "$a" "the empty sibling worktree must be reported dead"
  assert_not_contains "$out" "$ab" "the worktree holding the live agent must not be reported dead"
  pass "a bare path prefix does not make a sibling worktree live"
}

# A symlinked record pointing at a worktree with only a leftover shell is still
# provably dead; canonicalising the record must not turn that into unknown.
test_dead_lane_with_symlinked_record_reads_dead() {
  local d real link pid rc
  d="$TMP_ROOT/symlink-dead"
  real="$d/real"
  link="$d/link"
  mkdir -p "$real/wt"
  ln -s "$real" "$link" || fail "could not create the symlinked component"
  pid=$(spawn_shell_in "$real/wt") || fail "could not spawn the shell fixture"
  wait_for_process "$pid"
  fm_lane_agent_live_in_worktree "$link/wt"
  rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a shell-only worktree reached through a symlinked record must read dead (got $rc)"
  pass "a dead lane with a symlinked record still reads dead"
}

# --- the fleet view ---------------------------------------------------------

test_dead_worktrees_names_only_the_dead_ones() {
  local d live dead empty out
  d="$TMP_ROOT/fleet"
  live="$d/live"
  dead="$d/dead"
  empty="$d/empty"
  mkdir -p "$live" "$dead" "$empty"
  spawn_named_process "$d/bin" pi "$live" >/dev/null || fail "could not spawn the agent fixture"
  spawn_shell_in "$dead" >/dev/null || fail "could not spawn the shell fixture"
  sleep 0.2
  out=$(fm_lane_dead_worktrees "$live" "$dead" "$empty") \
    || fail "the fleet scan must succeed"
  assert_not_contains "$out" "$live" "a live lane must not be reported dead"
  assert_contains "$out" "$dead" "a shell-only lane must be reported dead"
  assert_contains "$out" "$empty" "an empty lane must be reported dead"
  pass "the fleet view names only the provably dead worktrees"
}

test_dead_worktrees_never_names_an_unknown_class_dead() {
  local d live dead toolbin real ps_real pid out
  d="$TMP_ROOT/fleet-unknown"
  live="$d/live"
  dead="$d/dead"
  toolbin="$d/toolbin"
  mkdir -p "$live" "$dead" "$toolbin"
  pid=$(spawn_named_process "$d/bin" pi "$live") || fail "could not spawn the agent fixture"
  spawn_shell_in "$dead" >/dev/null || fail "could not spawn the shell fixture"
  sleep 0.2
  for tool in lsof cut grep sort paste awk sed cat bash; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || continue
    ln -s "$real" "$toolbin/$tool"
  done
  # A pid that exits between the lsof scan and the ps snapshot is unknown, not
  # dead. Drop only the live pid from the snapshot so the shell-only worktree
  # still classifies normally.
  ps_real=$(command -v ps)
  cat >"$toolbin/ps" <<EOF
#!/bin/bash
"$ps_real" "\$@" | grep -v '^ *$pid '
EOF
  chmod +x "$toolbin/ps"
  out=$(PATH="$toolbin" fm_lane_dead_worktrees "$live" "$dead") \
    || fail "the fleet scan must succeed"
  assert_not_contains "$out" "$live" \
    "a worktree whose process cannot be classified must never be reported dead"
  assert_contains "$out" "$dead" "a genuinely dead worktree must still be reported dead"
  pass "the fleet view never names an unknown-class worktree dead"
}

test_live_agent_in_worktree
test_live_agent_in_subdirectory_counts
test_gemini_shaped_agent_in_worktree
test_shell_only_worktree_is_dead
test_empty_worktree_is_dead
test_unclassifiable_process_is_undeterminable
test_missing_lsof_is_undeterminable
test_live_agent_through_symlinked_record_reads_live
test_sibling_path_prefix_is_not_live
test_dead_lane_with_symlinked_record_reads_dead
test_dead_worktrees_names_only_the_dead_ones
test_dead_worktrees_never_names_an_unknown_class_dead

echo "all fm-lane-liveness tests passed"
