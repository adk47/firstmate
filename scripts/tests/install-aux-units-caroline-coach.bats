#!/usr/bin/env bats
# The SCHEDULER wiring for the Caroline coach reading (scripts/caroline_coach.py).
#
# A reading every 30 minutes is only that if something runs it. These tests EXECUTE the
# installer's own heredoc blocks with the target directory redirected into a temp dir, parse
# the rendered units, and run the installer's real wire_unit_failure_paging() over the rendered
# service (same method as install-aux-units-caroline-monitor.bats).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="caroline-coach"
SCRIPT="scripts/caroline_coach.py"

_render() {
  local snippet="$TEST_TMPDIR/render-$RANDOM.sh"
  awk -v dir="$1" -v name="$2" -v dest="$3/" '
    !on && index($0, "cat > " dir name) == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1
      print "cat > " dest substr($0, length("cat > " dir) + 1); next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="$HYDRA_REPO" cc_state="$STATE" bash "$snippet"
}

_kv() {
  awk '/^\[[^]]+\]$/ { sec = substr($0, 2, length($0) - 2); next }
       /^[A-Za-z][A-Za-z0-9]*=/ { i = index($0, "="); print sec "." substr($0, 1, i - 1) "=" substr($0, i + 1) }' "$1"
}

_values() {
  _kv "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  UNITS="$TEST_TMPDIR/units"; STATE="$TEST_TMPDIR/state"
  mkdir -p "$UNITS"
  _render /etc/systemd/system/ "$NAME." "$UNITS"
  SVC="$UNITS/$NAME.service"; TMR="$UNITS/$NAME.timer"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the installer renders exactly the .service and the .timer" {
  [ -s "$SVC" ]
  [ -s "$TMR" ]
  [ "$(ls "$UNITS" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "the service runs the real, executable script's tick and keeps the reading in the state directory" {
  [ "$(_values "$SVC" Service.Type)" = "oneshot" ]
  run _values "$SVC" Service.ExecStart
  [ "${#lines[@]}" -eq 1 ]
  read -r interp script verb flag dir extra <<< "${lines[0]}"
  [ "$interp" = "/usr/bin/python3" ]
  [ "$script" = "$HYDRA_REPO/$SCRIPT" ]
  [ "$verb" = "tick" ]
  [ "$flag" = "--out" ]
  [ "$dir" = "$STATE" ]
  [ -z "$extra" ]          # no --minutes: the window is the script's default, which the timer matches
  [ -x "$script" ]
}

@test "the window the script reads is the interval the timer runs" {
  [ "$(_values "$TMR" Timer.OnUnitActiveSec)" = "30min" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  [ "$(_values "$TMR" Install.WantedBy)" = "timers.target" ]
  run grep -c 'add_argument("--minutes", type=int, default=30)' "$HYDRA_REPO/$SCRIPT"
  [ "$output" -eq 1 ]
}

@test "the Intercom token comes from the env files, never from the unit" {
  run _values "$SVC" Service.EnvironmentFile
  [ "$output" = "-/etc/openclaw/shared.env
-/etc/openclaw/edge.env" ]
  run grep -E 'MUSOAI_INTERCOM_TOKEN=|xoxb-|SLACK_BOT_TOKEN' "$SVC" "$TMR"
  [ "$status" -eq 1 ]
}

@test "a reading that could not run is a recorded reading, and a crash still pages" {
  # Exit 2 = NOT MEASURED, already written to latest.json with no number in it. Exit 1 (a crash) is not in the list.
  [ "$(_values "$SVC" Service.SuccessExitStatus)" = "0 2" ]
  run grep -c 'Exit: 0 read · 2 could not read Intercom' "$HYDRA_REPO/$SCRIPT"
  [ "$output" -eq 1 ]
  local snippet="$TEST_TMPDIR/wire.sh"
  {
    echo 'log() { echo "$*"; }'
    echo 'systemctl() { return 0; }'
    sed -n '/^AUX_ONFAILURE_UNITS=(/,/^)/p' "$INSTALLER"
    sed -n '/^wire_unit_failure_paging() {/,/^}/p' "$INSTALLER"
  } > "$snippet"
  run env AUX_SYSTEMD_UNIT_DIR="$UNITS" bash -c ". '$snippet'; wire_unit_failure_paging"
  [ "$status" -eq 0 ]
  [ "$(_values "$SVC" Unit.OnFailure)" = "hydra-unit-failed@%n.service" ]
  run env AUX_SYSTEMD_UNIT_DIR="$UNITS" bash -c ". '$snippet'; wire_unit_failure_paging"
  [ "$(_values "$SVC" Unit.OnFailure | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the reading goes to the file, not to the journal" {
  [ "$(_values "$SVC" Service.StandardOutput)" = "null" ]
  [ "$(_values "$SVC" Service.TimeoutStartSec)" = "10min" ]
}

@test "the installer's state-directory step creates its root with mode 700, outside /opt/hydra" {
  local snippet="$TEST_TMPDIR/state.sh"
  local root="$TEST_TMPDIR/state root"
  sed -n '/^cc_state=/,/^install -d -m 700 "\$cc_state"$/p' "$INSTALLER" > "$snippet"
  [ -s "$snippet" ]
  run env CAROLINE_COACH_STATE_DIR="$root" bash "$snippet"
  [ "$status" -eq 0 ]
  [ -d "$root" ]
  [ "$(stat -c %a "$root")" = "700" ]
  run grep -c '^cc_state="${CAROLINE_COACH_STATE_DIR:-/var/lib/hydra/caroline-coach}"$' "$INSTALLER"
  [ "$output" -eq 1 ]
}

@test "the installer's preflight passes with the script and FAILS without it" {
  local guard="$TEST_TMPDIR/guard.sh"
  {
    echo 'fail() { echo "FATAL: $*"; exit 1; }'
    awk -v s="[[ -x \"\$HYDRA_ROOT/$SCRIPT\" ]]" 'index($0, s) == 1 { print; getline; print }' "$INSTALLER"
  } > "$guard"
  [ "$(wc -l < "$guard")" -eq 3 ]
  run env HYDRA_ROOT="$HYDRA_REPO" bash "$guard"
  [ "$status" -eq 0 ]
  run env HYDRA_ROOT="$TEST_TMPDIR/empty" bash "$guard"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"*"$SCRIPT"* ]]
}

@test "the timer is enabled and started by the installer" {
  run grep -c '^cc=caroline-coach.timer$' "$INSTALLER"
  [ "$output" -eq 1 ]
  run grep -cE '^systemctl (enable|start) "\$cc" ' "$INSTALLER"
  [ "$output" -eq 2 ]
}
