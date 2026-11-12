#!/usr/bin/env bats
# The SCHEDULER wiring for the Caroline monitor (scripts/caroline-monitor.py).
#
# The monitor is only a monitor if something runs it and something pages when it
# cannot run. These tests EXECUTE the installer's own heredoc blocks with the
# target directory redirected into a temp dir, parse the rendered units, and run
# the installer's real wire_unit_failure_paging() over the rendered service
# (same method as install-aux-units-legal-unanswered.bats).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="caroline-monitor"
SCRIPT="scripts/$NAME.py"

_render() {
  local snippet="$TEST_TMPDIR/render-$RANDOM.sh"
  awk -v dir="$1" -v name="$2" -v dest="$3/" '
    !on && index($0, "cat > " dir name) == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1
      print "cat > " dest substr($0, length("cat > " dir) + 1); next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="$HYDRA_REPO" bash "$snippet"
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
  UNITS="$TEST_TMPDIR/units"
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

@test "the service runs the real, executable script's tick" {
  [ "$(_values "$SVC" Service.Type)" = "oneshot" ]
  run _values "$SVC" Service.ExecStart
  [ "${#lines[@]}" -eq 1 ]
  read -r interp script verb extra <<< "${lines[0]}"
  [ "$interp" = "/usr/bin/python3" ]
  [ "$script" = "$HYDRA_REPO/$SCRIPT" ]
  [ "$verb" = "tick" ]
  [ -z "$extra" ]          # no --dry-run, no --corpus: the unit runs the live tick
  [ -x "$script" ]
}

@test "the Intercom token comes from the env files, never from the unit" {
  run _values "$SVC" Service.EnvironmentFile
  [ "$output" = "-/etc/openclaw/shared.env
-/etc/openclaw/edge.env" ]
  run grep -E 'MUSOAI_INTERCOM_TOKEN=|xoxb-|SLACK_BOT_TOKEN' "$SVC" "$TMR"
  [ "$status" -eq 1 ]
}

@test "the cadence keeps support-backlog.json fresher than the 3h staleness check" {
  [ "$(_values "$TMR" Timer.OnUnitActiveSec)" = "2h" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  [ "$(_values "$TMR" Install.WantedBy)" = "timers.target" ]
  # the register tells the reader the same cadence the timer runs
  run python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['monitor']['cadence'])" \
    "$HYDRA_REPO/policies/caroline-shapes.json"
  [[ "$output" == "every 2 hours"* ]]
}

@test "the unit treats only exit 0 as success, so a delivered page is never paged twice" {
  # cli.py exits 0 for a measured run and for a blind run below the threshold; a page the
  # monitor already delivered must not also trigger OnFailure. Non-zero (1 undelivered,
  # 2 a broken register) reaches the unit pager as the backstop.
  [ "$(_values "$SVC" Service.SuccessExitStatus)" = "0" ]
}

@test "a full re-read fits inside the start timeout" {
  [ "$(_values "$SVC" Service.TimeoutStartSec)" = "45min" ]
}

@test "the installer's state-directory step creates its root with mode 700" {
  local snippet="$TEST_TMPDIR/state.sh"
  local root="$TEST_TMPDIR/state root"
  sed -n '/^cm_state=/,/^install -d -m 700 "\$cm_state"$/p' "$INSTALLER" > "$snippet"
  [ -s "$snippet" ]
  run env CAROLINE_MONITOR_STATE_DIR="$root" bash "$snippet"
  [ "$status" -eq 0 ]
  [ -d "$root" ]
  [ "$(stat -c %a "$root")" = "700" ]
}

@test "the installer's preflight passes with the script and FAILS without it" {
  local guard="$TEST_TMPDIR/guard.sh"
  {
    echo 'fail() { echo "FATAL: $*"; exit 1; }'
    awk -v s="[[ -x \"\$HYDRA_ROOT/$SCRIPT\" ]]" 'index($0, s) == 1 { print; getline; print }' "$INSTALLER"
  } > "$guard"
  run env HYDRA_ROOT="$HYDRA_REPO" bash "$guard"
  [ "$status" -eq 0 ]
  run env HYDRA_ROOT="$TEST_TMPDIR/empty" bash "$guard"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"*"$SCRIPT"* ]]
}

@test "a failing tick pages through the unit pager, once however often it is wired" {
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
