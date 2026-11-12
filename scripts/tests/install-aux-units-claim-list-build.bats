#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/claim-list-build.py.
#
# scripts/tests/test_claim_list.py covers the builder, and every case there passes with the
# systemd block in scripts/install-aux-units.sh deleted: a tested program that never runs,
# which is exactly how the claim list went five days stale (2026-11-07 to 2026-11-12). The real
# installer writes to /etc/systemd/system and runs systemctl as root, so the unit heredocs are
# extracted, written to a temp dir and handed to systemd's own parser; the installer's enable
# loop and OnFailure table are evaluated as the shell declarations they are.
#
# Running the whole installer hermetically is not possible here: it requires root, writes
# /etc/systemd/system and /var/lib, and shells out to openclaw and a dozen host scripts. The
# enable step is therefore evaluated against a stub systemctl, and a separate check fails when
# that step is no longer a top-level statement of the installer (moved into a function, guarded
# by a condition, or deleted) - the "tested program that never runs" failure this file exists for.
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

# The control-structure depth at the enable loop, ignoring function bodies and heredoc bodies.
# Empty means the loop is not on the installer's top-level execution path at all.
enable_step_depth() {
  awk '
    heredoc != "" { if ($0 == heredoc) heredoc = ""; next }
    match($0, /<<-?[ ]*[\047\042]?[A-Za-z_][A-Za-z0-9_]*/) {
      tag = substr($0, RSTART, RLENGTH); sub(/^<<-?[ ]*[\047\042]?/, "", tag); heredoc = tag; next
    }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { if ($0 !~ /}[[:space:]]*$/) infunc = 1; next }
    infunc { if ($0 == "}") infunc = 0; next }
    /^for mon in .*claim-list-build\.timer/ { print depth; exit }
    /^if([[:space:]]|$)/ { if ($0 !~ /[;[:space:]]fi([[:space:];]|$)/) depth++ }
    /^fi([[:space:]]|$)/ { depth-- }
    /^(for|while|until)([[:space:]]|$)/ { if ($0 !~ /[;[:space:]]done([[:space:];]|$)/) depth++ }
    /^done([[:space:]]|$)/ { depth-- }
    /^case([[:space:]]|$)/ { if ($0 !~ /[;[:space:]]esac([[:space:];]|$)/) depth++ }
    /^esac([[:space:]]|$)/ { depth-- }
  ' "$INSTALLER"
}

# The installer's enable step, run for real against a stub systemctl. STUB_FAIL names one
# "<verb> <unit>" call that fails; STUB_INACTIVE names a unit that reports inactive.
run_enable_step() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
[ "$*" = "${STUB_FAIL:-}" ] && exit 1
if [ "$1" = is-active ]; then
  [ "$2" = "${STUB_INACTIVE:-}" ] && { echo inactive; exit 3; }
  echo active
fi
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  : > "$SYSTEMCTL_LOG"
  step="$(enable_step)"
  [ -n "$step" ]
  # log() and fail() are the installer's own two definitions (install-aux-units.sh), not copies.
  helpers="$(grep -E '^(log|fail)\(\) ' "$INSTALLER")"
  [ "$(grep -c . <<< "$helpers")" -eq 2 ]
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    STUB_FAIL="${STUB_FAIL:-}" STUB_INACTIVE="${STUB_INACTIVE:-}" \
    bash -c 'set -euo pipefail; eval "$1"; eval "$2"; echo STEP-COMPLETED' _ "$helpers" "$step"
}

@test "the enable step is a top-level statement of the installer" {
  run enable_step_depth
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "both triggers are enabled and started by the installer" {
  run_enable_step
  [ "$status" -eq 0 ]
  [[ "$output" == *STEP-COMPLETED* ]]
  for u in claim-list-build.timer claim-list-build.path; do
    grep -qx "enable $u" "$SYSTEMCTL_LOG"
    grep -qx "start $u" "$SYSTEMCTL_LOG"
  done
}

@test "a trigger that cannot be enabled stops the install" {
  STUB_FAIL="enable claim-list-build.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not enable claim-list-build.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a trigger that cannot be started stops the install" {
  STUB_FAIL="start claim-list-build.path" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not start claim-list-build.path"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a trigger that started but is not active stops the install" {
  STUB_INACTIVE="claim-list-build.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: claim-list-build.timer is not active after start"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
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
