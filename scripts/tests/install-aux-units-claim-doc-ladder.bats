#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/claim-doc-ladder.py.
#
# scripts/tests/test_claim_doc_ladder.py covers the ladder, and every case there passes with the
# systemd block in scripts/install-aux-units.sh deleted: a tested program that never runs, which is
# the state this ladder exists to end (a claimant's document on file and no rule reading it). Same
# method as install-aux-units-claim-list-build.bats: the unit heredocs are extracted and handed to
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
  SVC="$BATS_TEST_TMPDIR/claim-doc-ladder.service"
  TMR="$BATS_TEST_TMPDIR/claim-doc-ladder.timer"
  unit_body 'cat > /etc/systemd/system/claim-doc-ladder.service' CLAIMDOCSVC > "$SVC"
  unit_body 'cat > /etc/systemd/system/claim-doc-ladder.timer' CLAIMDOCTMR > "$TMR"
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
  [ "$(unit_get "$SVC" Service ExecStart)" = "/usr/bin/python3 $HYDRA_REPO/scripts/claim-doc-ladder.py" ]
  [ -x "$HYDRA_REPO/scripts/claim-doc-ladder.py" ]
  run python3 "$HYDRA_REPO/scripts/claim-doc-ladder.py" --help
  [ "$status" -eq 0 ]
}

@test "the service is a oneshot whose timeout is under the timer period" {
  [ "$(unit_get "$SVC" Service Type)" = oneshot ]
  t="$(unit_get "$SVC" Service TimeoutStartSec)"
  [[ "$t" =~ ^[0-9]+$ ]]
  [ "$t" -lt 14400 ]
}

@test "the service has the environment the reads need" {
  [ "$(unit_get "$SVC" Service Environment)" = "HOME=/root" ]
  [[ "$(unit_all "$SVC" Service Environment)" == *"PATH="*"/usr/local/bin"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/shared.env"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/main.env"* ]]
}

@test "the timer fires every 4 h and catches up a missed run" {
  cal="$(unit_get "$TMR" Timer OnCalendar)"
  [ "$cal" = '*-*-* 0/4:40:00' ]
  [ "$(unit_get "$TMR" Timer Persistent)" = true ]
  [ "$(unit_get "$TMR" Timer Unit)" = claim-doc-ladder.service ]
  [ "$(unit_get "$TMR" Install WantedBy)" = timers.target ]
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar --iterations=2 "$cal"
    [ "$status" -eq 0 ]
  fi
}

@test "the state directory is created outside the deploy tree" {
  grep -qx 'install -d -m 700 /var/lib/hydra/claim-doc-ladder' "$INSTALLER"
  grep -q 'STATE_DIR = "/var/lib/hydra/claim-doc-ladder"' "$HYDRA_REPO/scripts/claim_verify/doc_sources.py"
}

@test "the stop switch the installer names is the one the code reads" {
  grep -q '/etc/hydra/claim-doc-ladder.disabled' "$INSTALLER"
  grep -q 'KILL_FILE = "/etc/hydra/claim-doc-ladder.disabled"' "$HYDRA_REPO/scripts/claim_verify/doc_ladder.py"
}

enable_step() {
  awk '
    /^mon=claim-doc-ladder\.timer$/ { on = 1 }
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
    /^mon=claim-doc-ladder\.timer$/ { print depth; exit }
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

@test "the timer is enabled and started by the installer" {
  run_enable_step
  [ "$status" -eq 0 ]
  [[ "$output" == *STEP-COMPLETED* ]]
  grep -qx "enable claim-doc-ladder.timer" "$SYSTEMCTL_LOG"
  grep -qx "start claim-doc-ladder.timer" "$SYSTEMCTL_LOG"
}

@test "a timer that cannot be enabled stops the install" {
  STUB_FAIL="enable claim-doc-ladder.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not enable claim-doc-ladder.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that cannot be started stops the install" {
  STUB_FAIL="start claim-doc-ladder.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not start claim-doc-ladder.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that started but is not active stops the install" {
  STUB_INACTIVE="claim-doc-ladder.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: claim-doc-ladder.timer is not active after start"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a failed pass pages: the service is in the OnFailure table" {
  run bash -c 'eval "$(sed -n "/^AUX_ONFAILURE_UNITS=(/,/^)/p" "$1")"; printf "%s\n" "${AUX_ONFAILURE_UNITS[@]}"' _ "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'claim-doc-ladder.service' <<< "$output")" -eq 1 ]
}

@test "the ladder, its modules and its policy are present for the installer to check" {
  [ -f "$HYDRA_REPO/scripts/claim-doc-ladder.py" ]
  [ -f "$HYDRA_REPO/scripts/claim_verify/doc_ladder.py" ]
  [ -f "$HYDRA_REPO/scripts/claim_verify/doc_sources.py" ]
  [ -f "$HYDRA_REPO/scripts/lib/page_identity.py" ]
  [ -f "$HYDRA_REPO/policies/claim-doc-ladder.json" ]
}
