#!/usr/bin/env bats
# scripts/install-aux-units.sh -> sysstat enablement
# This test extracts and runs the REAL sysstat block from the installer,
# following the pattern used in install-aux-units-gateway-heap.bats.
# The extraction ensures mutations to the installer (e.g., changing HISTORY=28 to 7)
# cause the test to fail, proving the code is actually being executed.
bats_require_minimum_version 1.5.0

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  ETC_DEFAULT_SYSSTAT_REAL="/etc/default/sysstat"
  ETC_SYSSTAT_SYSSTAT_REAL="/etc/sysstat/sysstat"
  ETC_DEFAULT_SYSSTAT="$TEST_TMPDIR/etc/default/sysstat"
  ETC_SYSSTAT_SYSSTAT="$TEST_TMPDIR/etc/sysstat/sysstat"
  SNIPPET="$TEST_TMPDIR/sysstat-block.sh"
  INSTALLER="${BATS_TEST_DIRNAME}/../install-aux-units.sh"
  LOG_FILE="$TEST_TMPDIR/test.log"
  SYSTEMCTL_CALLS="$TEST_TMPDIR/systemctl.calls"
  export LOG_FILE SYSTEMCTL_CALLS TEST_TMPDIR

  # Seed the config files FIRST, before extracting.
  # This ensures the extracted code operates on known state.
  mkdir -p "$TEST_TMPDIR/etc/default" "$TEST_TMPDIR/etc/sysstat"
  cat > "$ETC_DEFAULT_SYSSTAT" << 'CFGEOF'
ENABLED="false"
CFGEOF
  cat > "$ETC_SYSSTAT_SYSSTAT" << 'CFGEOF'
HISTORY=7
SA_DIR=/var/log/sysstat
CFGEOF

  # Extract the REAL sysstat block from the installer and run it with temp paths.
  # The block starts with "# ─── Enable sysstat" and ends with "systemctl enable --now sysstat".
  # Extract, replace absolute /etc paths with our temp paths, prepend helper functions,
  # and run via bash. This ensures the real code is executed and any mutations to it
  # (e.g., changing HISTORY=28 to 7) are caught.
  {
    cat << 'HELPERS'
log() { echo "$*" >> "$LOG_FILE"; }
systemctl() { echo "$*" >> "$SYSTEMCTL_CALLS"; return "${SC_RC:-0}"; }
HELPERS
    # Extract the sysstat block from the installer, starting from the header comment
    # through the final systemctl line. Substitute paths to temp dirs.
    sed -n '/^# ─── Enable sysstat/,/^systemctl enable --now sysstat/p' "$INSTALLER" \
      | sed -e "s|$ETC_DEFAULT_SYSSTAT_REAL|$ETC_DEFAULT_SYSSTAT|g" \
            -e "s|$ETC_SYSSTAT_SYSSTAT_REAL|$ETC_SYSSTAT_SYSSTAT|g"
  } > "$SNIPPET"

  # Verify extraction succeeded.
  [ "$(grep -c 'ETC_DEFAULT_SYSSTAT=' "$SNIPPET")" -ge 1 ]
  [ "$(grep -c 'ETC_SYSSTAT_SYSSTAT=' "$SNIPPET")" -ge 1 ]
  [ "$(grep -c 'systemctl enable --now sysstat' "$SNIPPET")" -eq 1 ]

  # Initialize the log and systemctl call files.
  touch "$LOG_FILE" "$SYSTEMCTL_CALLS"

  # Run the extracted block.
  run bash "$SNIPPET"
  # Capture status for later tests.
  SNIPPET_STATUS=$status
  SNIPPET_OUTPUT="$output"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "extraction: sysstat block found with both config paths" {
  [ -s "$SNIPPET" ]
  grep -q 'ETC_DEFAULT_SYSSTAT=' "$SNIPPET"
  grep -q 'ETC_SYSSTAT_SYSSTAT=' "$SNIPPET"
}

@test "execution: snippet ran without errors" {
  [ "$SNIPPET_STATUS" -eq 0 ]
}

@test "ENABLED flip: /etc/default/sysstat changed false → true" {
  [ -f "$ETC_DEFAULT_SYSSTAT" ]
  grep -q '^ENABLED="true"' "$ETC_DEFAULT_SYSSTAT"
  # Verify the false value is gone (not just appended)
  [ "$(grep -c '^ENABLED=' "$ETC_DEFAULT_SYSSTAT")" -eq 1 ]
}

@test "retention: /etc/sysstat/sysstat set to HISTORY=28" {
  [ -f "$ETC_SYSSTAT_SYSSTAT" ]
  grep -q '^HISTORY=28' "$ETC_SYSSTAT_SYSSTAT"
  # Verify only one HISTORY line exists (not duplicated).
  [ "$(grep -c '^HISTORY=' "$ETC_SYSSTAT_SYSSTAT")" -eq 1 ]
}

@test "retention: old HISTORY=7 value removed" {
  [ -f "$ETC_SYSSTAT_SYSSTAT" ]
  ! grep -q '^HISTORY=7' "$ETC_SYSSTAT_SYSSTAT"
}

@test "systemctl: stub was invoked with correct arguments" {
  # The systemctl stub records its calls to SYSTEMCTL_CALLS.
  # If this file doesn't exist or doesn't contain "enable --now sysstat",
  # the code didn't run the systemctl command.
  [ -f "$SYSTEMCTL_CALLS" ]
  [ "$(cat "$SYSTEMCTL_CALLS")" = "enable --now sysstat" ]
}

@test "logging: sysstat enabled message was logged on success" {
  # When systemctl succeeds (SC_RC defaults to 0), the success log should appear.
  [ -f "$LOG_FILE" ]
  grep -q "sysstat: enabled" "$LOG_FILE"
}

@test "failure handling: WARN logged when systemctl fails (SC_RC=1)" {
  # Test the failure branch: systemctl stub returns 1, installer logs WARN and continues.
  # Re-initialize log and systemctl calls for this test.
  rm -f "$LOG_FILE" "$SYSTEMCTL_CALLS"
  touch "$LOG_FILE" "$SYSTEMCTL_CALLS"

  # Run the snippet with SC_RC=1 (systemctl will return 1).
  SC_RC=1 run bash "$SNIPPET"

  # The installer should exit 0 even though systemctl failed (|| log WARN).
  [ "$status" -eq 0 ]

  # The WARN message should be logged.
  [ -f "$LOG_FILE" ]
  grep -q "WARN: could not enable sysstat" "$LOG_FILE"

  # The success message should NOT be logged.
  ! grep -q "sysstat: enabled" "$LOG_FILE"
}

@test "retention: append when HISTORY line is completely absent" {
  # Test the case where /etc/sysstat/sysstat exists but has NO HISTORY line.
  # This tests the fix for: "retention update silently no-ops when HISTORY is absent."

  # Create sysstat config WITHOUT a HISTORY line.
  mkdir -p "$TEST_TMPDIR/etc/sysstat"
  cat > "$ETC_SYSSTAT_SYSSTAT" << 'CFGEOF'
SA_DIR=/var/log/sysstat
CFGEOF

  rm -f "$LOG_FILE" "$SYSTEMCTL_CALLS"
  touch "$LOG_FILE" "$SYSTEMCTL_CALLS"

  # Extract and run snippet again with the new config.
  {
    cat << 'HELPERS'
log() { echo "$*" >> "$LOG_FILE"; }
systemctl() { echo "$*" >> "$SYSTEMCTL_CALLS"; return "${SC_RC:-0}"; }
HELPERS
    sed -n '/^# ─── Enable sysstat/,/^systemctl enable --now sysstat/p' "$INSTALLER" \
      | sed -e "s|$ETC_DEFAULT_SYSSTAT_REAL|$ETC_DEFAULT_SYSSTAT|g" \
            -e "s|$ETC_SYSSTAT_SYSSTAT_REAL|$ETC_SYSSTAT_SYSSTAT|g"
  } > "$SNIPPET"

  run bash "$SNIPPET"
  [ "$status" -eq 0 ]

  # HISTORY=28 should now exist in the file (appended).
  [ -f "$ETC_SYSSTAT_SYSSTAT" ]
  grep -q '^HISTORY=28$' "$ETC_SYSSTAT_SYSSTAT"

  # SA_DIR should still be there (file not truncated).
  grep -q '^SA_DIR=' "$ETC_SYSSTAT_SYSSTAT"

  # The retention log message should appear.
  [ -f "$LOG_FILE" ]
  grep -q "sysstat: set retention to 28 days" "$LOG_FILE"
}
