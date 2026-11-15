#!/usr/bin/env bats
# The SCHEDULER wiring for the Intercom unanswered-reply watchdog
# (scripts/intercom-unanswered-reply-watchdog.py, 2026-11-11). A check that is
# not scheduled, or whose failures page nobody, is a report: this file is what
# proves the check can FIRE.
#
# It is a systemd oneshot service + timer, NOT an /etc/cron.d entry: cron.d
# blocks pass env inline and are chmod 644 (a token there is world-readable),
# and wire_unit_failure_paging() only covers systemd units, so a failing
# cron.d watchdog would page nobody.
#
# The real installer writes to /etc as root, so these tests EXECUTE the
# installer's own heredoc blocks with the target directory redirected into a
# temp dir and HYDRA_ROOT set, then parse the rendered unit files into
# Section.Key=Value pairs and assert on that. OnFailure registration is proven
# by running the installer's real wire_unit_failure_paging() over the rendered
# service, as install-aux-units-onfailure.bats does.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="intercom-unanswered-reply-watchdog"
SCRIPT="scripts/$NAME.py"

# _render <installer-dir> <name-prefix> <dest-dir>: run every
# `cat > <installer-dir><name-prefix>... << TAG` heredoc of the installer with
# its target rewritten into <dest-dir>.
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

# _kv <unit-file>: one Section.Key=Value line per directive.
_kv() {
  awk '/^\[[^]]+\]$/ { sec = substr($0, 2, length($0) - 2); next }
       /^[A-Za-z][A-Za-z0-9]*=/ { i = index($0, "="); print sec "." substr($0, 1, i - 1) "=" substr($0, i + 1) }' "$1"
}

_values() {  # _values <unit-file> <Section.Key>
  _kv "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  UNITS="$TEST_TMPDIR/units"; CRON="$TEST_TMPDIR/cron.d"
  mkdir -p "$UNITS" "$CRON"
  _render /etc/systemd/system/ "$NAME." "$UNITS"
  SVC="$UNITS/$NAME.service"; TMR="$UNITS/$NAME.timer"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the installer renders exactly the .service and the .timer" {
  [ -s "$SVC" ]
  [ -s "$TMR" ]
  [ "$(ls "$UNITS" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "the service is a oneshot whose ExecStart runs the real, executable script" {
  [ "$(_values "$SVC" Service.Type)" = "oneshot" ]
  run _values "$SVC" Service.ExecStart
  [ "${#lines[@]}" -eq 1 ]
  read -r interp script extra <<< "${lines[0]}"
  [ "$interp" = "/usr/bin/python3" ]
  [ -z "$extra" ]
  [ "$script" = "$HYDRA_REPO/$SCRIPT" ]
  # A unit pointing at a renamed script is the same outage as no unit.
  [ -x "$script" ]
}

@test "both env files are loaded, optional (secret-safe path)" {
  run _values "$SVC" Service.EnvironmentFile
  [ "$output" = "-/etc/openclaw/shared.env
-/etc/openclaw/edge.env" ]
}

@test "the replica read can find its kubeconfig, and a hung tick is killed rather than left running" {
  # trino-query.sh shells to kubectl, which reads $HOME/.kube/config; a system unit has no HOME.
  # Without it the paid split is "unmeasured" on every tick.
  run _values "$SVC" Service.Environment
  [ "$output" = "HOME=/root" ]
  # the first tick reads every open thread (READ_BUDGET_S in the script); the unit must outlast it
  local budget
  budget="$(awk -F' = ' '$1 == "READ_BUDGET_S" { print $2 }' "$HYDRA_REPO/$SCRIPT")"
  [ -n "$budget" ]
  [ "$(_values "$SVC" Service.TimeoutStartSec)" -gt "$budget" ]
}

@test "SECURITY: no secret literal appears in the rendered units" {
  run grep -E 'MUSOAI_INTERCOM_TOKEN=|xoxb-|SLACK_BOT_TOKEN' "$SVC" "$TMR"
  [ "$status" -eq 1 ]
}

@test "cadence is hourly and the timer starts this service" {
  [ "$(_values "$TMR" Timer.OnUnitActiveSec)" = "60min" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  [ "$(_values "$TMR" Install.WantedBy)" = "timers.target" ]
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

@test "the rendered service gains OnFailure paging from the real wiring pass" {
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
  # a second deploy adds nothing
  run env AUX_SYSTEMD_UNIT_DIR="$UNITS" bash -c ". '$snippet'; wire_unit_failure_paging"
  [ "$(_values "$SVC" Unit.OnFailure | wc -l | tr -d ' ')" -eq 1 ]
}

@test "no rendered cron.d entry runs it" {
  _render /etc/cron.d/ "" "$CRON"
  [ "$(ls "$CRON" | wc -l | tr -d ' ')" -gt 0 ]
  run grep -rl "$NAME" "$CRON"
  [ "$status" -eq 1 ]
}
