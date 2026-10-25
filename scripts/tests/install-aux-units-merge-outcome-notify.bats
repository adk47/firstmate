#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/merge-outcome-notify.py.
#
# scripts/tests/test_merge_outcome_notify.py covers the notifier's behaviour, and
# every case passes with the systemd block in scripts/install-aux-units.sh
# deleted: a tested program that never runs. Same rationale and shape as
# install-aux-units-clickup-dedupe.bats. The real installer writes to
# /etc/systemd/system and runs systemctl as root, so the unit heredocs are
# extracted and parsed into key=value pairs here; this pins that the wiring is
# DECLARED, not that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

unit_keys() {
  awk -v start="$1" -v stop="$2" '
    index($0, start) == 1 { on = 1; next }
    $0 == stop { on = 0 }
    on && /^[A-Za-z]+=/ { print }
  ' "$INSTALLER"
}

setup() {
  SVC="$(unit_keys 'cat > /etc/systemd/system/merge-outcome-notify.service' MERGEOUTCOMESVC)"
  TMR="$(unit_keys 'cat > /etc/systemd/system/merge-outcome-notify.timer' MERGEOUTCOMETMR)"
  export SVC TMR
}

@test "a service and a timer unit are declared" {
  [ -n "$SVC" ]
  [ -n "$TMR" ]
}

@test "the service runs the notifier with --apply, and that script loads" {
  exec_start="$(grep '^ExecStart=' <<< "$SVC" | cut -d= -f2-)"
  [ "$exec_start" = '/usr/bin/python3 $HYDRA_ROOT/scripts/merge-outcome-notify.py --apply' ]
  run python3 "$HYDRA_REPO/scripts/merge-outcome-notify.py" --help
  [ "$status" -eq 0 ]
}

@test "the service is a oneshot with an explicit start timeout" {
  grep -qx 'Type=oneshot' <<< "$SVC"
  grep -qE '^TimeoutStartSec=[0-9]+$' <<< "$SVC"
}

@test "the per-run cap and the state path are set, and the notifier creates that state dir itself" {
  grep -qx 'Environment=MERGE_OUTCOME_MAX=25' <<< "$SVC"
  state="$(grep '^Environment=MERGE_OUTCOME_STATE=' <<< "$SVC" | cut -d= -f3-)"
  [ "$state" = /var/lib/merge-outcome-notify/notified.json ]
  root="$BATS_TEST_TMPDIR/root"
  run python3 - "$HYDRA_REPO/scripts/merge-outcome-notify.py" "$root$state" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mon", sys.argv[1])
mon = importlib.util.module_from_spec(spec); spec.loader.exec_module(mon)
st = mon.State()
st.done, st.flagged = {"t1": mon.SENT}, {"t2"}
mon.save_state(sys.argv[2], st)
got = mon.load_state(sys.argv[2])
print(got.done, got.flagged)
PY
  [ "$status" -eq 0 ]
  [ "$output" = "{'t1': 'sent'} {'t2'}" ]
  [ -d "$root/var/lib/merge-outcome-notify" ]
}

@test "the service loads shared.env and main.env (ClickUp key + Intercom token)" {
  [ "$(grep '^EnvironmentFile=' <<< "$SVC")" = "$(printf '%s\n' \
    'EnvironmentFile=-/etc/openclaw/shared.env' 'EnvironmentFile=-/etc/openclaw/main.env')" ]
}

@test "the timer fires every 15 minutes, persistently, and drives the service" {
  on_calendar="$(grep '^OnCalendar=' <<< "$TMR" | cut -d= -f2-)"
  [ "$on_calendar" = '*:0/15' ]
  grep -qx 'Persistent=true' <<< "$TMR"
  grep -qx 'Unit=merge-outcome-notify.service' <<< "$TMR"
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar --iterations=2 "$on_calendar"
    [ "$status" -eq 0 ]
    grep -q ':00:00\|:15:00\|:30:00\|:45:00' <<< "$output"
  fi
}

@test "a failing run pages (the service is in the OnFailure table)" {
  run bash -c "$(sed -n '/^AUX_ONFAILURE_UNITS=(/,/^)/p' "$INSTALLER"); printf '%s\n' \"\${AUX_ONFAILURE_UNITS[@]}\""
  [ "$status" -eq 0 ]
  grep -qx 'merge-outcome-notify.service' <<< "$output"
}
