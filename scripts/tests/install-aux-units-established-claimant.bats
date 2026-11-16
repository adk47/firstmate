#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/established-claimant.py.
#
# scripts/tests/test_established_claimant.py covers the rule and the scheduled pass, and every
# case there passes with the systemd block in scripts/install-aux-units.sh deleted: a tested
# program nobody runs, which is what this rule was for its first two days (measured by hand on
# 2026-11-14 and 2026-11-15, and true only on those days). Same method as
# install-aux-units-claim-doc-ladder.bats: the unit heredocs are extracted and handed to
# systemd's own parser, and the installer's enable step is evaluated against a stub systemctl.
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
  SVC="$BATS_TEST_TMPDIR/established-claimant.service"
  TMR="$BATS_TEST_TMPDIR/established-claimant.timer"
  unit_body 'cat > /etc/systemd/system/established-claimant.service' ESTCLAIMSVC > "$SVC"
  unit_body 'cat > /etc/systemd/system/established-claimant.timer' ESTCLAIMTMR > "$TMR"
  export SVC TMR
}

@test "a service and a timer are declared" {
  [ -s "$SVC" ]
  [ -s "$TMR" ]
}

@test "systemd's own parser accepts both units" {
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    skip "systemd-analyze is not installed"
  fi
  run systemd-analyze verify "$SVC" "$TMR"
  [ "$status" -eq 0 ]
}

@test "the service runs the scheduled pass with no flags, and that script loads as a file" {
  [ "$(unit_get "$SVC" Service ExecStart)" = "/usr/bin/python3 $HYDRA_REPO/scripts/established-claimant.py" ]
  [ -x "$HYDRA_REPO/scripts/established-claimant.py" ]
  run python3 "$HYDRA_REPO/scripts/established-claimant.py" --help
  [ "$status" -eq 0 ]
}

@test "the scheduled pass the entry script runs is the publishing pass" {
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from credit_review import established_claimant as e; assert e._cmd_tick and e.tick' "$HYDRA_REPO/scripts"
  [ "$status" -eq 0 ]
}

@test "the service is a oneshot whose timeout is under the timer period" {
  [ "$(unit_get "$SVC" Service Type)" = oneshot ]
  t="$(unit_get "$SVC" Service TimeoutStartSec)"
  [[ "$t" =~ ^[0-9]+$ ]]
  [ "$t" -lt 86400 ]
  # a pass measured about 20 minutes on 2026-11-15: the timeout leaves it room
  [ "$t" -ge 3600 ]
}

@test "the service is memory-capped and cannot starve the gateway" {
  [ "$(unit_get "$SVC" Service MemoryMax)" = 2G ]
  [ "$(unit_get "$SVC" Service CPUQuota)" = "100%" ]
  [ "$(unit_get "$SVC" Service Nice)" = 10 ]
}

@test "the service has the environment the reads need" {
  [ "$(unit_get "$SVC" Service Environment)" = "HOME=/root" ]
  [[ "$(unit_all "$SVC" Service Environment)" == *"PATH="*"/usr/local/bin"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/shared.env"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/main.env"* ]]
}

@test "the timer fires once a day and catches up a missed run" {
  cal="$(unit_get "$TMR" Timer OnCalendar)"
  [ "$cal" = '*-*-* 03:20:00 UTC' ]
  [ "$(unit_get "$TMR" Timer Persistent)" = true ]
  [ "$(unit_get "$TMR" Timer Unit)" = established-claimant.service ]
  [ "$(unit_get "$TMR" Install WantedBy)" = timers.target ]
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar --iterations=2 "$cal"
    [ "$status" -eq 0 ]
  fi
}

@test "the installer creates the state directory the module publishes to, mode 700, with both units" {
  run module_paths
  [ "$status" -eq 0 ]
  state_dir="$(sed -n 1p <<< "$output")"
  run_established_install
  [ "$status" -eq 0 ]
  [[ "$output" == *STEP-COMPLETED* ]]
  [ -d "$ROOT$state_dir" ]
  [ "$(stat -c %a "$ROOT$state_dir")" = 700 ]
  [ -f "$ROOT/etc/systemd/system/established-claimant.service" ]
  [ -f "$ROOT/etc/systemd/system/established-claimant.timer" ]
}

@test "the stop switch the module reads is the one the installer names, and the install creates nothing" {
  run module_paths
  [ "$status" -eq 0 ]
  kill_file="$(sed -n 2p <<< "$output")"
  installer_kill="$(established_section | grep -oE '/etc/hydra/[A-Za-z0-9._-]+\.disabled' | sort -u)"
  [ "$installer_kill" = "$kill_file" ]
  run_established_install
  [ "$status" -eq 0 ]
  [[ "$output" == *STEP-COMPLETED* ]]
  # a pass that waits on a file being removed is not a pass that runs by itself
  [ ! -e "$ROOT$kill_file" ]
  [ -z "$(find "$ROOT" -name "$(basename "$kill_file")" -print -quit)" ]
}

enable_step() {
  awk '
    /^mon=established-claimant\.timer$/ { on = 1 }
    on { print }
    on && /^log "  \$mon: active"$/ { exit }
  ' "$INSTALLER"
}

# The control-structure depth at the enable step, ignoring function bodies and heredoc bodies.
# Empty means the step is not on the installer's top-level execution path at all.
enable_step_depth() {
  awk '
    heredoc != "" { if ($0 == heredoc) heredoc = ""; next }
    match($0, /<<-?[ ]*[\047\042]?[A-Za-z_][A-Za-z0-9_]*/) {
      tag = substr($0, RSTART, RLENGTH); sub(/^<<-?[ ]*[\047\042]?/, "", tag); heredoc = tag; next
    }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { if ($0 !~ /}[[:space:]]*$/) infunc = 1; next }
    infunc { if ($0 == "}") infunc = 0; next }
    /^mon=established-claimant\.timer$/ { print depth; exit }
    /^if([[:space:]]|$)/ { if ($0 !~ /[;[:space:]]fi([[:space:];]|$)/) depth++ }
    /^fi([[:space:]]|$)/ { depth-- }
    /^(for|while|until)([[:space:]]|$)/ { if ($0 !~ /[;[:space:]]done([[:space:];]|$)/) depth++ }
    /^done([[:space:]]|$)/ { depth-- }
    /^case([[:space:]]|$)/ { if ($0 !~ /[;[:space:]]esac([[:space:];]|$)/) depth++ }
    /^esac([[:space:]]|$)/ { depth-- }
  ' "$INSTALLER"
}

module_paths() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from credit_review import established_claimant as e; print(e.STATE_DIR); print(e.KILL_FILE)' \
    "$HYDRA_REPO/scripts"
}

# The installer's established-claimant section, from its section comment through its enable step.
established_section() {
  awk '
    index($0, "# ─── Established-claimant rule:") == 1 { on = 1 }
    on { print }
    on && /^log "  \$mon: active"$/ { exit }
  ' "$INSTALLER"
}

# A stub systemctl. STUB_FAIL names one "<verb> <unit>" call that fails; STUB_INACTIVE names a
# unit that reports inactive.
systemctl_stub() {
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
}

installer_helpers() {
  grep -E '^(log|fail)\(\) ' "$INSTALLER"
}

# The installer's established-claimant section, run for real with its absolute /etc/ and
# /var/lib/ paths rewritten under the test tmpdir. Sets ROOT to that rewritten prefix.
run_established_install() {
  ROOT="$BATS_TEST_TMPDIR/root"
  rm -rf "$ROOT"
  mkdir -p "$ROOT/etc/systemd/system" "$ROOT/var/lib/hydra"
  systemctl_stub
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  : > "$SYSTEMCTL_LOG"
  section="$(established_section | sed "s|/etc/|$ROOT/etc/|g; s|/var/lib/|$ROOT/var/lib/|g")"
  [ -n "$section" ]
  helpers="$(installer_helpers)"
  [ "$(grep -c . <<< "$helpers")" -eq 2 ]
  run env HYDRA_ROOT="$HYDRA_REPO" PATH="$BATS_TEST_TMPDIR/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    STUB_FAIL="${STUB_FAIL:-}" STUB_INACTIVE="${STUB_INACTIVE:-}" \
    bash -c 'set -euo pipefail; eval "$1"; eval "$2"; echo STEP-COMPLETED' _ "$helpers" "$section"
}

# The installer's enable step, run for real against a stub systemctl.
run_enable_step() {
  systemctl_stub
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  : > "$SYSTEMCTL_LOG"
  step="$(enable_step)"
  [ -n "$step" ]
  # log() and fail() are the installer's own two definitions (install-aux-units.sh), not copies.
  helpers="$(installer_helpers)"
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

@test "the timer is enabled and started by the installer" {
  run_enable_step
  [ "$status" -eq 0 ]
  [[ "$output" == *STEP-COMPLETED* ]]
  grep -qx "enable established-claimant.timer" "$SYSTEMCTL_LOG"
  grep -qx "start established-claimant.timer" "$SYSTEMCTL_LOG"
}

@test "a timer that cannot be enabled stops the install" {
  STUB_FAIL="enable established-claimant.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not enable established-claimant.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that cannot be started stops the install" {
  STUB_FAIL="start established-claimant.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not start established-claimant.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that started but is not active stops the install" {
  STUB_INACTIVE="established-claimant.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: established-claimant.timer is not active after start"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a failed pass pages: the service is in the OnFailure table" {
  run bash -c 'eval "$(sed -n "/^AUX_ONFAILURE_UNITS=(/,/^)/p" "$1")"; printf "%s\n" "${AUX_ONFAILURE_UNITS[@]}"' _ "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'established-claimant.service' <<< "$output")" -eq 1 ]
}

@test "the script, its module and its policy are present for the installer to check" {
  [ -f "$HYDRA_REPO/scripts/established-claimant.py" ]
  [ -f "$HYDRA_REPO/scripts/credit_review/established_claimant.py" ]
  [ -f "$HYDRA_REPO/policies/established-claimant.json" ]
  grep -q 'scripts/established-claimant.py, its credit_review module or its policy is missing' "$INSTALLER"
}
