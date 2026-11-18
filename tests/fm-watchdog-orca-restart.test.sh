#!/usr/bin/env bash
# tests/fm-watchdog-orca-restart.test.sh - the fleet watchdog must bring an
# Orca-hosted worker back by itself, and must never put two agents on one task.
#
# Why this exists: measured 2026-11-17, 37 Orca lanes held a relaunch refusal
# reading "runs on the orca backend, whose in-place relaunch is not proven end
# to end", and three more lanes whose Orca terminal read `unreadable` had held
# no agent process since 04:10Z and sat unreplaced and unreported for 19 hours.
# Both shapes are the same hole: the watchdog had no sequence that both proves
# the old agent is gone and starts a new one.
#
# The three cases below are the three answers that hole needs:
#   1. an alive Orca lane at the relaunch rung is stopped, proven gone, then
#      replaced, and its carry-over note is delivered;
#   2. an Orca terminal reading `unreadable` is replaced when the live process
#      table positively shows no agent in the task's recorded worktree;
#   3. an Orca terminal reading `unreadable` is refused - zero launches, one
#      wake - when an agent is there or the proof is unavailable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-watchdog-worker.sh"
TMP_ROOT=$(fm_test_tmproot fm-watchdog-orca-restart)

# assert_eq <expected> <actual> <msg>
assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# make_home <name>: a private FM home for one test.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/fix" "$home/crew" \
    "$home/units" "$home/wt"
  printf '%s\n' "$home"
}

# fake_tools <home>: every external command the watchdog can reach, recorded in
# <home>/calls so a test can assert both what ran and in what order.
#
# fake-control answers `exit` the way bin/fm-control.sh does for an Orca lane -
# it proves the agent is gone and reports `stopped` - and refuses `relaunch`
# with the exact in-place-relaunch refusal Orca earns, so a test that sees a
# relaunch go through fm-control has caught the old broken sequence.
fake_tools() {  # <home>
  local home=$1
  cat > "$home/fakebin/fake-control" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$home/calls"
case "\$2" in
  exit)
    if [ -f "$home/units/exit-unconfirmed" ]; then
      printf 'error: exit-delivered to task %s but agent-state=alive exit=unconfirmed\n' "\$1" >&2
      exit 1
    fi
    printf 'dead\n' > "$home/fix/\$1.state"
    printf 'stopped\n'
    ;;
  relaunch)
    printf 'error: task %s runs on the orca backend, whose in-place relaunch is not proven end to end; exit the agent with'\''exit'\'' and respawn the task instead\n' "\$1" >&2
    exit 1
    ;;
esac
SH
  cat > "$home/fakebin/fake-spawn" <<SH
#!/usr/bin/env bash
printf 'spawn %s\n' "\$*" >> "$home/calls"
if [ -f "$home/units/spawn-refuses" ]; then
  printf "error: task %s's Orca terminal term-%s reads 'unreadable'; Orca relaunch replaces only a terminal that provably hosts no agent\n" "\$1" "\$1" >&2
  exit 2
fi
printf 'relaunched true task=%s\n' "\$1"
SH
  cat > "$home/fakebin/fake-send" <<SH
#!/usr/bin/env bash
printf 'send %s\n' "\$1" >> "$home/calls"
printf '%s\n' "\$*" >> "$home/steers"
SH
  cat > "$home/fakebin/fake-crew-state" <<SH
#!/usr/bin/env bash
if [ -f "$home/crew/\$1" ]; then cat "$home/crew/\$1"; else printf 'state: unknown · source: none · no record\n'; fi
SH
  cat > "$home/fakebin/fake-lane-switch" <<SH
#!/usr/bin/env bash
printf 'model-switch %s\n' "\$*" >> "$home/calls"
exit 0
SH
  cat > "$home/fakebin/systemctl" <<SH
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$home/calls"
exit 0
SH
  cat > "$home/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> "$home/calls"
exit 1
SH
  chmod +x "$home/fakebin"/*
}

# worker <home> <id> <state>: one recorded Orca task and its endpoint state.
worker() {  # <home> <id> <state>
  local home=$1 id=$2 state=$3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:$id" "endpoint_task_id=$id" "worktree=$home/wt/$id" \
    "project=p" "harness=pi" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "terminal=term-$id" "orca_worktree_id=wt-$id"
  printf '%s\n' "$state" > "$home/fix/$id.state"
}

# pane <home> <id> <busy> <text>: the pane the watchdog would capture.
pane() {  # <home> <id> <busy> <text>
  printf '%s\n' "$4" > "$1/fix/$2.cap"
  printf '%s\n' "$3" > "$1/fix/$2.busy"
}

# tick <home> <now>: one watchdog pass on the frozen clock.
tick() {  # <home> <now>
  local home=$1 now=$2
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_WATCHDOG_NOW="$now" \
    FM_WATCHDOG_BOOT_ID=off \
    FM_WATCHDOG_CONTROL_BIN="$home/fakebin/fake-control" \
    FM_WATCHDOG_SPAWN_BIN="$home/fakebin/fake-spawn" \
    FM_WATCHDOG_SEND_BIN="$home/fakebin/fake-send" \
    FM_WATCHDOG_CREW_STATE_BIN="$home/fakebin/fake-crew-state" \
    FM_WATCHDOG_SYSTEMCTL_BIN="$home/fakebin/systemctl" \
    FM_WATCHDOG_LANE_SWITCH_BIN="$home/fakebin/fake-lane-switch" \
    FM_WATCHDOG_AGENT_STATE_DIR="$home/fix" \
    FM_WATCHDOG_CAPTURE_DIR="$home/fix" \
    FM_WATCHDOG_CHAIR_TARGET=firstmate:chair \
    FM_WATCHDOG_BACKLOG=off \
    "$CHECK" 2>&1
}

# wakes <home>: the durable check wakes the watchdog queued.
wakes() {  # <home>
  awk -F'\t' '$3 == "check" { print $4 " " $5 }' "$1/state/.wake-queue" 2>/dev/null
}

# counter <home> <pattern>: how many recorded lines match.
counter() {  # <home> <pattern>
  local n
  n=$(grep -c "$2" "$1/calls" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

# gate <state> <worktree> [table]: the real replacement decision, asked of the
# one owner (bin/backends/orca.sh) with the terminal's reading supplied, so the
# answer is about the process table alone.
gate() {  # <state> <worktree> [table]
  local state=$1 wt=$2 table=${3-}
  env FM_AGENT_PROC_TABLE="${table:-/nonexistent/fm-agent-proc-table}" \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/orca.sh"; fm_backend_orca_replaceable "$2" "$3" "$4"' \
    _ "$ROOT" term-x "$wt" "$state"
}

# proc_table <path> <rows...>: a process table in bin/fm-agent-proc-lib.sh's
# four-column shape.
proc_table() {  # <path> <pid:comm:cwd:args>...
  local path=$1 row
  shift
  : > "$path"
  for row in "$@"; do
    printf '%s\n' "$row" | tr ':' '\t' >> "$path"
  done
}

test_an_alive_orca_lane_is_stopped_then_replaced() {
  local home now out
  home=$(make_home alive); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 busy 'a tool call that never returns'
  now=$(date +%s)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 1900))" >/dev/null
  out=$(tick "$home" "$((now + 2600))")
  assert_contains "$out" "stopped w1 before replacing its endpoint" \
    "an alive Orca lane at the relaunch rung was not stopped first"
  assert_eq "$(counter "$home" '^control w1 exit$')" "1" \
    "the watchdog did not prove the old Orca agent gone before replacing it"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" \
    "the watchdog still asked fm-control for the in-place relaunch Orca refuses"
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "1" \
    "an alive Orca lane was not replaced exactly once"
  # The stop must come before the replacement, or two agents share one task.
  assert_eq "$(grep -nE '^(control w1 exit|spawn w1 --relaunch)$' "$home/calls" \
    | cut -d: -f2 | tr '\n' '|')" "control w1 exit|spawn w1 --relaunch|" \
    "the replacement ran before the stop was proven"
  assert_contains "$(cat "$home/steers")" "Continue the task from where you left off" \
    "the replacement did not carry the lane's worktree-and-commits-intact note"
  pass "an alive Orca lane is stopped, proven gone, then replaced with its note delivered"
}

test_an_unreadable_orca_lane_with_no_agent_is_replaced() {
  local home now out table
  home=$(make_home unreadable); fake_tools "$home"
  worker "$home" w1 unreadable
  now=$(date +%s)
  out=$(tick "$home" "$now")
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "1" \
    "an Orca lane whose terminal read unreadable was never handed to the replacement"
  assert_eq "$(counter "$home" '^control ')" "0" \
    "an unreadable Orca lane was sent to fm-control, which cannot judge it"
  assert_eq "$(wakes "$home" | grep -c 'w1')" "0" \
    "a lane the watchdog could replace was escalated instead"
  # The replacement is licensed by the process table, not by the terminal read.
  table="$home/proc-table"
  proc_table "$table" "9001:zsh:$home/wt/w1:-zsh" "9002:bash:$home/wt/w1:-bash"
  gate unreadable "$home/wt/w1" "$table" \
    || fail "an unreadable terminal with only shells in the worktree was not replaceable"
  pass "an unreadable Orca terminal is replaced when the process table proves no agent"
}

test_an_unreadable_orca_lane_with_an_agent_or_no_proof_is_refused() {
  local home now out table
  home=$(make_home refused); fake_tools "$home"
  : > "$home/units/spawn-refuses"
  worker "$home" w1 unreadable
  now=$(date +%s)
  out=$(tick "$home" "$now")
  assert_contains "$out" "relaunch refused w1 after endpoint unreadable" \
    "a refused Orca replacement was not reported"
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "1" \
    "a refused Orca replacement was retried inside one pass"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a refused Orca replacement did not wake firstmate exactly once"
  assert_eq "$(jq -r '.tasks.w1.refusal_state' "$home/state/.watchdog-worker.json")" "unreadable" \
    "the refusal was not recorded against the state that earned it"
  # A second pass inside the retry window launches nothing and says nothing.
  out=$(tick "$home" "$((now + 60))")
  [ -z "$out" ] || fail "a recorded refusal was re-attempted inside its retry window: $out"
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "1" \
    "a recorded refusal was re-attempted inside its retry window"
  # And the gate itself refuses both shapes that are not proof of absence.
  table="$home/proc-table"
  proc_table "$table" "9001:pi:$home/wt/w1:pi"
  if gate unreadable "$home/wt/w1" "$table"; then
    fail "an unreadable terminal with a live agent in the worktree was replaceable"
  fi
  proc_table "$table" "9001:python3:$home/wt/w1:python3 worker.py"
  if gate unreadable "$home/wt/w1" "$table"; then
    fail "an unreadable terminal with an unclassifiable process was replaceable"
  fi
  if gate unreadable "$home/wt/w1" /nonexistent/fm-agent-proc-table; then
    fail "an unreadable terminal was replaceable with no process table at all"
  fi
  pass "an unreadable Orca terminal is refused, with one wake, when an agent or no proof is present"
}

test_an_unprovable_stop_launches_nothing() {
  local home now out
  home=$(make_home unconfirmed); fake_tools "$home"
  : > "$home/units/exit-unconfirmed"
  worker "$home" w1 alive
  pane "$home" w1 busy 'a tool call that never returns'
  now=$(date +%s)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 1900))" >/dev/null
  out=$(tick "$home" "$((now + 2600))")
  assert_eq "$(counter "$home" '^spawn ')" "0" \
    "the watchdog replaced an Orca lane whose stop it could not prove"
  assert_contains "$out" "could not stop w1 before replacing it" \
    "an unprovable stop was not reported"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "an unprovable stop did not wake firstmate exactly once"
  pass "an Orca lane whose stop cannot be proven is refused, never replaced"
}

test_an_alive_orca_lane_is_stopped_then_replaced
test_an_unreadable_orca_lane_with_no_agent_is_replaced
test_an_unreadable_orca_lane_with_an_agent_or_no_proof_is_refused
test_an_unprovable_stop_launches_nothing
