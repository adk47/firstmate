#!/usr/bin/env bats
# scripts/install-aux-units.sh -> hydra-main-prune-restart.{service,timer} (MUS-1295)
#
# Runs the REAL "Main gateway session prune" block of the installer, redirected
# at a temp dir with a stubbed systemctl, and pins: the units it writes, that the
# hand-placed bridge (two /usr/local/sbin scripts + the transient timer) is
# retired BEFORE the managed timer is armed, and the pager/logrotate wiring.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  UNITS="$TEST_TMPDIR/units"; SBIN="$TEST_TMPDIR/sbin"; mkdir -p "$UNITS" "$SBIN"
  export CALLS="$TEST_TMPDIR/calls.log"; : > "$CALLS"
  export LEGACY_RUNNING_MARK="$TEST_TMPDIR/legacy-running"
  cat > "$TEST_TMPDIR/stub.sh" <<'STUB'
log() { echo "$*"; }
fail() { echo "FATAL: $*"; exit 1; }
sleep() { echo "sleep $*" >> "$CALLS"; rm -f "$LEGACY_RUNNING_MARK"; }
pgrep() { return 1; }
systemctl() {
  echo "systemctl $*" >> "$CALLS"
  case "$1" in
    is-active)
      if [ "$2" = hydra-main-nightly-reset.service ]; then
        [ -e "$LEGACY_RUNNING_MARK" ] && echo active || echo inactive
      else echo active; fi ;;
  esac
  return 0
}
STUB
  {
    cat "$TEST_TMPDIR/stub.sh"
    echo "HYDRA_ROOT='$HYDRA_REPO'"
    awk '/^# ─── Main gateway session prune/ { on = 1 }
         /^# ─── Twice-weekly codex OAuth token refresh/ { on = 0 }
         on' "$INSTALLER" \
      | sed -e "s|/etc/systemd/system|$UNITS|g" -e "s|/usr/local/sbin|$SBIN|g"
  } > "$TEST_TMPDIR/block.sh"
  # A moved/renamed block must fail the suite, not test nothing.
  grep -q 'retire_main_prune_bridge' "$TEST_TMPDIR/block.sh"
  grep -q 'MAINPRUNESVC' "$TEST_TMPDIR/block.sh"
  touch "$SBIN/hydra-main-prune-restart.sh" "$SBIN/hydra-main-nightly-reset.sh" "$SBIN/hydra-main-nightly-reset.sh.bak-20261005" "$SBIN/keep-me.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

_install() { run bash "$TEST_TMPDIR/block.sh"; }

@test "installs the service and a 02:30 UTC timer that targets it" {
  _install
  [ "$status" -eq 0 ]
  grep -q "^ExecStart=$HYDRA_REPO/scripts/main-prune-restart.sh nightly" "$UNITS/hydra-main-prune-restart.service"
  grep -q '^Type=oneshot' "$UNITS/hydra-main-prune-restart.service"
  grep -q '^Environment=HYDRA_MAIN_PRUNE_AFTER=24h' "$UNITS/hydra-main-prune-restart.service"
  grep -q '^Environment=HYDRA_MAIN_MIN_UPTIME_H=4' "$UNITS/hydra-main-prune-restart.service"
  grep -q '^OnCalendar=\*-\*-\* 02:30:00 UTC' "$UNITS/hydra-main-prune-restart.timer"
  grep -q '^Unit=hydra-main-prune-restart.service' "$UNITS/hydra-main-prune-restart.timer"
  grep -q 'systemctl enable hydra-main-prune-restart.timer' "$CALLS"
}

@test "never loops and never catches up: no Restart= and no Persistent=" {
  _install
  ! grep -qE '^(Restart|Persistent)=' "$UNITS/hydra-main-prune-restart.service" "$UNITS/hydra-main-prune-restart.timer"
}

@test "the service timeout outlasts prune (20m) + stable-health wait (45m)" {
  _install
  mins="$(sed -n 's/^TimeoutStartSec=\([0-9]*\)min/\1/p' "$UNITS/hydra-main-prune-restart.service")"
  [ -n "$mins" ]
  [ "$mins" -gt 65 ]
}

@test "retires the two hand-placed scripts (and the dated .bak) but nothing else" {
  _install
  [ "$status" -eq 0 ]
  [ ! -e "$SBIN/hydra-main-prune-restart.sh" ]
  [ ! -e "$SBIN/hydra-main-nightly-reset.sh" ]
  [ ! -e "$SBIN/hydra-main-nightly-reset.sh.bak-20261005" ]
  [ -e "$SBIN/keep-me.sh" ]
}

@test "stops the transient nightly-reset timer BEFORE arming the managed one" {
  _install
  stop_line="$(grep -n 'systemctl stop hydra-main-nightly-reset.timer' "$CALLS" | head -1 | cut -d: -f1)"
  arm_line="$(grep -n 'systemctl enable hydra-main-prune-restart.timer' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$stop_line" ] && [ -n "$arm_line" ]
  [ "$stop_line" -lt "$arm_line" ]
}

@test "a second run is idempotent" {
  _install; [ "$status" -eq 0 ]
  _install; [ "$status" -eq 0 ]
}

@test "the timer not coming active fails the install" {
  sed -i.bak 's/else echo active; fi ;;/else echo failed; fi ;;/' "$TEST_TMPDIR/block.sh"
  _install
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
}

@test "the service is wired to the failure pager and the logrotate list" {
  # the installer's real tables, not a copy
  awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)/' "$INSTALLER" | grep -qx '  hydra-main-prune-restart.service'
  grep -q '/var/log/hydra-main-prune-restart.log' "$INSTALLER"
}

@test "a legacy prune/restart still RUNNING is never stopped: the installer waits, then retires it" {
  touch "$LEGACY_RUNNING_MARK"          # the stubbed sleep clears it, i.e. the legacy run finishes
  _install
  [ "$status" -eq 0 ]
  grep -q '^sleep' "$CALLS"
  # argv match, not a literal: a combined `stop <timer> <service>` call must also be caught
  [ "$(grep -cE 'systemctl stop .*hydra-main-nightly-reset\.service' "$CALLS")" -eq 0 ]
  [ ! -e "$SBIN/hydra-main-nightly-reset.sh" ]
}

@test "a legacy run that never finishes fails the install with nothing removed or armed" {
  touch "$LEGACY_RUNNING_MARK"
  export AUX_BRIDGE_WAIT_SECS=0
  _install
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to kill it mid-flight"* ]]
  # argv match, not a literal: a combined `stop <timer> <service>` call must also be caught
  [ "$(grep -cE 'systemctl stop .*hydra-main-nightly-reset\.service' "$CALLS")" -eq 0 ]
  [ "$(grep -c 'enable hydra-main-prune-restart.timer' "$CALLS")" -eq 0 ]
  [ -e "$SBIN/hydra-main-nightly-reset.sh" ]
  [ -e "$SBIN/hydra-main-prune-restart.sh" ]
}

@test "a legacy script running by hand (no unit) also blocks the retirement" {
  sed -i.bak 's/^pgrep() .*/pgrep() { return 0; }/' "$TEST_TMPDIR/block.sh"
  export AUX_BRIDGE_WAIT_SECS=0
  _install
  [ "$status" -ne 0 ]
  [ -e "$SBIN/hydra-main-prune-restart.sh" ]
}
