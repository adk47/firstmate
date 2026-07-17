#!/usr/bin/env bats
# Tests the maintenance-window guard in scripts/intercom-intake-watchdog.py — the one
# fleet-health watchdog that is NOT bash. It shells out to `hydra-maintenance is-active`
# (invoked via `bash`, so it does not depend on the helper's exec bit) and must SKIP
# when a window is active but stay TRANSPARENT otherwise (absent/expired/malformed flag).
# Hermetic: real CLI + real lib against a TEMP flag path; no /run, no Intercom token, no
# network (the transparent-path assertions stop at the token check before any API call).
bats_require_minimum_version 1.5.0

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  PY="$HYDRA_REPO/scripts/intercom-intake-watchdog.py"
  TEST_TMPDIR="$(mktemp -d)"
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/flag.json"
  # Never reach real Intercom: the transparent-path cases stop at the token check.
  unset MUSOAI_INTERCOM_TOKEN
}
teardown() { rm -rf "$TEST_TMPDIR"; }

write_active() {
  printf '{"reason":"%s","expires_epoch":%s}' "${1:-win}" "$(( $(date -u +%s) + 3600 ))" \
    > "$HYDRA_MAINTENANCE_FLAG"
}

@test "ACTIVE window -> the .py skips (exit 0) before needing the Intercom token" {
  write_active "openclaw upgrade"
  run python3 "$PY" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance window active - skipping"* ]]
}

@test "no window -> guard is transparent (reaches the token check, exit 1)" {
  rm -f "$HYDRA_MAINTENANCE_FLAG"
  run python3 "$PY" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN not set"* ]]
}

@test "EXPIRED flag -> guard transparent, does NOT skip (fail-safe)" {
  printf '{"reason":"stale","expires_epoch":%s}' "$(( $(date -u +%s) - 60 ))" \
    > "$HYDRA_MAINTENANCE_FLAG"
  run python3 "$PY" --check
  [ "$status" -eq 1 ]
  [[ "$output" != *"maintenance window active"* ]]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN not set"* ]]
}

@test "malformed flag -> guard transparent (fail-safe; reaches token check)" {
  printf 'garbage{{{' > "$HYDRA_MAINTENANCE_FLAG"
  run python3 "$PY" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN not set"* ]]
}
