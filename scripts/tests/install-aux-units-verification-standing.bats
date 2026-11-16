#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/verification-standing.py.
#
# scripts/tests/test_verification_standing.py covers the page and its `--save` exit codes, and
# every case there passes with the systemd block in scripts/install-aux-units.sh deleted: a
# page somebody has to remember to run. The real installer writes /etc/systemd/system and runs
# systemctl as root, so the unit heredocs are extracted and handed to systemd's own parser, the
# service's own command line is run against sources that are not there, and the installer's
# enable step and OnFailure table are evaluated as the shell declarations they are.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
SAVE_DIR=/var/lib/hydra/verification-standing

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

setup() {
  SVC="$BATS_TEST_TMPDIR/verification-standing.service"
  TMR="$BATS_TEST_TMPDIR/verification-standing.timer"
  unit_body 'cat > /etc/systemd/system/verification-standing.service' VERIFSTANDINGSVC > "$SVC"
  unit_body 'cat > /etc/systemd/system/verification-standing.timer' VERIFSTANDINGTMR > "$TMR"
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

@test "the service saves the page outside the deploy tree, in the directory the installer makes" {
  [ "$(unit_get "$SVC" Service ExecStart)" = "/usr/bin/python3 $HYDRA_REPO/scripts/verification-standing.py --save $SAVE_DIR" ]
  grep -qx "install -d -m 700 $SAVE_DIR" "$INSTALLER"
  [ -f "$HYDRA_REPO/scripts/verification-standing.py" ]
}

@test "the service is a oneshot whose timeout is under the timer period" {
  [ "$(unit_get "$SVC" Service Type)" = oneshot ]
  t="$(unit_get "$SVC" Service TimeoutStartSec)"
  [[ "$t" =~ ^[0-9]+$ ]]
  [ "$t" -lt 1800 ]
}

@test "no exit code is declared a success: an unmeasured number fails the unit" {
  [ -z "$(unit_get "$SVC" Service SuccessExitStatus)" ]
  [[ "$(unit_get "$SVC" Service ExecStart)" != -* ]]
}

# The service's own command line, with only the save directory moved into the test's temp dir.
run_service_command() {
  cmd="$(unit_get "$SVC" Service ExecStart)"
  [ -n "$cmd" ]
  cmd="${cmd/$SAVE_DIR/$BATS_TEST_TMPDIR/saved}"
  # shellcheck disable=SC2086  # the unit's ExecStart is a plain word list
  run --separate-stderr env CREDIT_REVIEW_LEDGER="$BATS_TEST_TMPDIR/no-ledger.sqlite3" \
    VQR_STATE="$BATS_TEST_TMPDIR/no-snapshot.json" CVO_OUT_ROOT="$BATS_TEST_TMPDIR/no-ticks" \
    VQR_KILL_SWITCH="$BATS_TEST_TMPDIR/no-kill" $cmd
}

@test "the service's command fails when its sources cannot be read, and still saves the page" {
  run_service_command
  [ "$status" -eq 3 ]
  [ -s "$BATS_TEST_TMPDIR/saved/latest.txt" ]
  [ -s "$BATS_TEST_TMPDIR/saved/latest.json" ]
  grep -q 'unmeasured' "$BATS_TEST_TMPDIR/saved/latest.txt"
  [[ "$stderr" == *"verification-standing: unmeasured (no snapshot at "*"): credits open, "* ]]
  [[ "$stderr" == *"verification-standing: unmeasured (no ledger at "*"): credits told_24h, "* ]]
  [ ! -e "$BATS_TEST_TMPDIR/no-ledger.sqlite3" ]
}

# scripts/notify-unit-failed.sh pages the unit's last 12 journal lines, cut to their last 1,500
# characters. systemd adds its own lines about the failed unit after ours, so the budget here is
# 8 lines and 1,000 bytes with every source unreadable at once, the longest the reasons get.
@test "the failure fits the pager: one line per reason, well inside the journal tail it sends" {
  run_service_command
  [ "$status" -eq 3 ]
  [ "$(grep -c . <<< "$stderr")" -le 8 ]
  [ "$(printf '%s' "$stderr" | wc -c)" -le 1000 ]
}

@test "the page is not written to the journal: stdout is discarded, the reasons are stderr" {
  [ "$(unit_get "$SVC" Service StandardOutput)" = null ]
  [ -z "$(unit_get "$SVC" Service StandardError)" ]
}

@test "the timer fires at :10 and :40, behind the queue snapshot's :00 and :30" {
  cal="$(unit_get "$TMR" Timer OnCalendar)"
  [ "$cal" = '*:10,40' ]
  [ "$(unit_get "$TMR" Timer Unit)" = verification-standing.service ]
  [ "$(unit_get "$TMR" Install WantedBy)" = timers.target ]
  grep -q '^\*/30 \* \* \* \* root flock -n /run/lock/verification-queue-report.lock ' "$INSTALLER"
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar --iterations=2 "$cal"
    [ "$status" -eq 0 ]
  fi
}

enable_step() {
  awk '
    /^mon=verification-standing\.timer$/ { on = 1 }
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
    /^mon=verification-standing\.timer$/ { print depth; exit }
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
  grep -qx "enable verification-standing.timer" "$SYSTEMCTL_LOG"
  grep -qx "start verification-standing.timer" "$SYSTEMCTL_LOG"
}

@test "a timer that cannot be enabled stops the install" {
  STUB_FAIL="enable verification-standing.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not enable verification-standing.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that cannot be started stops the install" {
  STUB_FAIL="start verification-standing.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not start verification-standing.timer"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a timer that started but is not active stops the install" {
  STUB_INACTIVE="verification-standing.timer" run_enable_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: verification-standing.timer is not active after start"* ]]
  [[ "$output" != *STEP-COMPLETED* ]]
}

@test "a failed run pages: the service is in the OnFailure table" {
  run bash -c 'eval "$(sed -n "/^AUX_ONFAILURE_UNITS=(/,/^)/p" "$1")"; printf "%s\n" "${AUX_ONFAILURE_UNITS[@]}"' _ "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'verification-standing.service' <<< "$output")" -eq 1 ]
}

@test "the installer refuses to run without the page's script" {
  grep -qF '[[ -f "$HYDRA_ROOT/scripts/verification-standing.py" ]]' "$INSTALLER"
}
