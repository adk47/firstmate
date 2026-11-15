#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/credit_review/precedent_ledger.py reconcile.
#
# scripts/tests/test_precedent_ledger.py covers the claim, the reconcile and the backfill, and every
# case there passes with the systemd block in scripts/install-aux-units.sh deleted: a tested step
# that nothing runs, which is how reconcile_approved.py shipped and why no precedent approval had a
# row. Same method as install-aux-units-claim-doc-ladder.bats: the unit heredocs are extracted and
# handed to systemd's own parser, and the installer's enable step is evaluated against a stub
# systemctl.
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
  SVC="$BATS_TEST_TMPDIR/precedent-ledger-reconcile.service"
  TMR="$BATS_TEST_TMPDIR/precedent-ledger-reconcile.timer"
  unit_body 'cat > /etc/systemd/system/precedent-ledger-reconcile.service' PRECLEDGERSVC > "$SVC"
  unit_body 'cat > /etc/systemd/system/precedent-ledger-reconcile.timer' PRECLEDGERTMR > "$TMR"
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

@test "the service runs the reconcile over a window, and that module loads as a file" {
  [ "$(unit_get "$SVC" Service ExecStart)" = "/usr/bin/python3 $HYDRA_REPO/scripts/credit_review/precedent_ledger.py reconcile --since-hours 6" ]
  run python3 "$HYDRA_REPO/scripts/credit_review/precedent_ledger.py" reconcile --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--since-hours"* ]]
}

@test "the service never claims and never applies a backfill" {
  exec_line="$(unit_get "$SVC" Service ExecStart)"
  [[ "$exec_line" != *" claim"* ]]
  [[ "$exec_line" != *backfill* ]]
  [[ "$exec_line" != *--apply* ]]
}

@test "the window is wider than the period, so a pass that ran long or was missed loses nothing" {
  [[ "$(unit_get "$SVC" Service ExecStart)" =~ --since-hours\ ([0-9]+)$ ]]
  hours="${BASH_REMATCH[1]}"
  t="$(unit_get "$SVC" Service TimeoutStartSec)"
  [[ "$t" =~ ^[0-9]+$ ]]
  [ "$t" -lt "$((hours * 3600))" ]
}

@test "the service is a oneshot with the environment the replica read needs" {
  [ "$(unit_get "$SVC" Service Type)" = oneshot ]
  [ "$(unit_get "$SVC" Service Environment)" = "HOME=/root" ]
  [[ "$(unit_all "$SVC" Service Environment)" == *"PATH="*"/usr/local/bin"* ]]
  [[ "$(unit_all "$SVC" Service EnvironmentFile)" == *"/etc/openclaw/shared.env"* ]]
}

@test "the timer fires every 10 min" {
  cal="$(unit_get "$TMR" Timer OnCalendar)"
  [ "$cal" = '*:3/10' ]
  [ "$(unit_get "$TMR" Timer Unit)" = precedent-ledger-reconcile.service ]
  [ "$(unit_get "$TMR" Install WantedBy)" = timers.target ]
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar --iterations=2 "$cal"
    [ "$status" -eq 0 ]
  fi
}

@test "the stop switch the installer names is the one the code reads" {
  grep -q '/etc/hydra/precedent-ledger.disabled' "$INSTALLER"
  grep -q 'KILL_FILE = "/etc/hydra/precedent-ledger.disabled"' "$HYDRA_REPO/scripts/credit_review/precedent_ledger.py"
}

enable_step() {
  awk '
    /^mon=precedent-ledger-reconcile\.timer$/ { on = 1 }
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
    /^mon=precedent-ledger-reconcile\.timer$/ { print depth; exit }
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
  grep -qx "enable precedent-ledger-reconcile.timer" "$SYSTEMCTL_LOG"
  grep -qx "start precedent-ledger-reconcile.timer" "$SYSTEMCTL_LOG"
}

@test "a timer that cannot be enabled stops the install" {
  STUB_FAIL="enable precedent-ledger-reconcile.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not enable precedent-ledger-reconcile.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that started but is not active stops the install" {
  STUB_INACTIVE="precedent-ledger-reconcile.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: precedent-ledger-reconcile.timer is not active after start"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a pass that could not read core pages: the service is in the OnFailure table" {
  run bash -c 'eval "$(sed -n "/^AUX_ONFAILURE_UNITS=(/,/^)/p" "$1")"; printf "%s\n" "${AUX_ONFAILURE_UNITS[@]}"' _ "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'precedent-ledger-reconcile.service' <<< "$output")" -eq 1 ]
}

@test "the module and the one it builds on are present for the installer to check" {
  [ -f "$HYDRA_REPO/scripts/credit_review/precedent_ledger.py" ]
  [ -f "$HYDRA_REPO/scripts/credit_review/reconcile_approved.py" ]
  grep -q 'scripts/credit_review/precedent_ledger.py" && -f' "$INSTALLER"
}
