#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/claim-list-build.py.
#
# scripts/tests/test_claim_list.py covers the builder, and every case there passes with the
# systemd block in scripts/install-aux-units.sh deleted: a tested program that never runs,
# which is exactly how the claim list went five days stale (2026-11-07 to 2026-11-12). The real
# installer writes to /etc/systemd/system and runs systemctl as root, so the unit heredocs are
# extracted, written to a temp dir and handed to systemd's own parser; the installer's enable
# loop and OnFailure table are evaluated as the shell declarations they are.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

unit_body() {
  awk -v start="$1" -v stop="$2" '
    index($0, start) == 1 { on = 1; next }
    $0 == stop { on = 0 }
    on { print }
  ' "$INSTALLER" | sed "s|\$HYDRA_ROOT|$HYDRA_REPO|g"
}

unit_get() {
  awk -v want="[$2]" -v key="$3" '
    /^\[/ { sec = $0; next }
    sec == want && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1"
}

unit_all() {
  awk -v want="[$2]" -v key="$3" '
    /^\[/ { sec = $0; next }
    sec == want && index($0, key "=") == 1 { print substr($0, length(key) + 2) }
  ' "$1"
}

setup() {
  SVC="$BATS_TEST_TMPDIR/claim-list-build.service"
  TMR="$BATS_TEST_TMPDIR/claim-list-build.timer"
  PTH="$BATS_TEST_TMPDIR/claim-list-build.path"
  unit_body 'cat > /etc/systemd/system/claim-list-build.service' CLAIMLISTSVC > "$SVC"
  unit_body 'cat > /etc/systemd/system/claim-list-build.timer' CLAIMLISTTMR > "$TMR"
  unit_body 'cat > /etc/systemd/system/claim-list-build.path' CLAIMLISTPATH > "$PTH"
  export SVC TMR PTH
}

@test "a service, a timer and a path unit are declared" {
  [ -s "$SVC" ]
  [ -s "$TMR" ]
  [ -s "$PTH" ]
}

@test "systemd's own parser accepts all three units" {
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    skip "systemd-analyze is not installed"
  fi
  run systemd-analyze verify "$SVC" "$TMR" "$PTH"
  [ "$status" -eq 0 ]
}

@test "the service runs the builder with no flags, and that script loads as a file" {
  [ "$(unit_get "$SVC" Service ExecStart)" = "/usr/bin/python3 $HYDRA_REPO/scripts/claim-list-build.py" ]
  [ -x "$HYDRA_REPO/scripts/claim-list-build.py" ]
  run python3 "$HYDRA_REPO/scripts/claim-list-build.py" --help
  [ "$status" -eq 0 ]
}

@test "the scheduled run is never a dry run" {
  [[ "$(unit_get "$SVC" Service ExecStart)" != *--dry-run* ]]
}

@test "the service is a oneshot whose timeout is under the timer period" {
  [ "$(unit_get "$SVC" Service Type)" = oneshot ]
  t="$(unit_get "$SVC" Service TimeoutStartSec)"
  [[ "$t" =~ ^[0-9]+$ ]]
  [ "$t" -lt 7200 ]
}

@test "the service has the environment the reads need" {
  [ "$(unit_get "$SVC" Service Environment)" = "HOME=/root" ]
  [[ "$(unit_all "$SVC" Service Environment)" == *"PATH="*"/usr/local/bin"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/shared.env"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/main.env"* ]]
}

@test "the timer fires every 2 h at :20, ahead of the outbound tick at :00" {
  cal="$(unit_get "$TMR" Timer OnCalendar)"
  [ "$cal" = '*-*-* 1/2:20:00' ]
  [ "$(unit_get "$TMR" Timer Persistent)" = true ]
  [ "$(unit_get "$TMR" Timer Unit)" = claim-list-build.service ]
  [ "$(unit_get "$TMR" Install WantedBy)" = timers.target ]
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar --iterations=2 "$cal"
    [ "$status" -eq 0 ]
  fi
}

@test "a deploy triggers a rebuild: the path unit watches the deploy record" {
  [ "$(unit_get "$PTH" Path PathChanged)" = "$HYDRA_REPO/.deployed-sha" ]
  [ "$(unit_get "$PTH" Path Unit)" = claim-list-build.service ]
  [ "$(unit_get "$PTH" Install WantedBy)" = multi-user.target ]
}

enable_step() {
  awk '
    /^for mon in .*claim-list-build\.timer/ { on = 1 }
    on { print }
    on && /^done$/ { exit }
  ' "$INSTALLER"
}

@test "both triggers are enabled and started by the installer" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
[ "$1" = is-active ] && echo active
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  step="$(enable_step)"
  [ -n "$step" ]
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    bash -c 'log() { :; }; eval "$1"' _ "$step"
  [ "$status" -eq 0 ]
  for u in claim-list-build.timer claim-list-build.path; do
    grep -qx "enable $u" "$SYSTEMCTL_LOG"
    grep -qx "start $u" "$SYSTEMCTL_LOG"
  done
}

@test "a failed build pages: the service is in the OnFailure table" {
  run bash -c 'eval "$(sed -n "/^AUX_ONFAILURE_UNITS=(/,/^)/p" "$1")"; printf "%s\n" "${AUX_ONFAILURE_UNITS[@]}"' _ "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'claim-list-build.service' <<< "$output")" -eq 1 ]
}

@test "the builder and its modules are present for the installer to check" {
  [ -f "$HYDRA_REPO/scripts/claim-list-build.py" ]
  [ -f "$HYDRA_REPO/scripts/credit_review/claim_list.py" ]
  [ -f "$HYDRA_REPO/scripts/credit_review/claim_audience.py" ]
}
