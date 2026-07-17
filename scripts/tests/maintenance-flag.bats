#!/usr/bin/env bats
# Tests scripts/lib/maintenance-flag.sh :: maintenance_active / maintenance_reason —
# the guard every fleet-health watchdog sources. FAIL-SAFE contract: ONLY a present +
# valid + UNEXPIRED flag reads as active; absent / malformed / no-expiry / expired all
# read as NOT active, so a broken or forgotten flag never leaves the fleet unguarded.
# Pure logic (jq + date real), hermetic via a temp flag path (no /run access).
bats_require_minimum_version 1.5.0

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/flag.json"
  # shellcheck source=/dev/null
  source "$HYDRA_REPO/scripts/lib/maintenance-flag.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# write_flag <expires_epoch> [reason]
write_flag() {
  jq -n --argjson exp "$1" --arg reason "${2:-test window}" \
    '{reason:$reason, operator:"tester@hydra-ops", started_at:"x", started_epoch:0,
      ttl_seconds:0, expires_at:"x", expires_epoch:$exp}' \
    > "$HYDRA_MAINTENANCE_FLAG"
}

@test "absent flag => NOT active (normal operation is the default)" {
  rm -f "$HYDRA_MAINTENANCE_FLAG"
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "present + unexpired flag => active, reason readable" {
  write_flag "$(( $(date -u +%s) + 3600 ))" "openclaw upgrade"
  run maintenance_active
  [ "$status" -eq 0 ]
  run maintenance_reason
  [ "$status" -eq 0 ]
  [ "$output" = "openclaw upgrade" ]
}

@test "expired flag => NOT active (TTL re-arms protection automatically)" {
  write_flag "$(( $(date -u +%s) - 60 ))"
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "malformed JSON => treated as absent (fail-safe)" {
  printf 'not json at all {{{' > "$HYDRA_MAINTENANCE_FLAG"
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "missing expires_epoch => NOT active (fail-safe)" {
  jq -n '{reason:"x"}' > "$HYDRA_MAINTENANCE_FLAG"
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "non-numeric expires_epoch => NOT active (fail-safe)" {
  jq -n '{reason:"x", expires_epoch:"soon"}' > "$HYDRA_MAINTENANCE_FLAG"
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "empty flag file => NOT active (fail-safe)" {
  : > "$HYDRA_MAINTENANCE_FLAG"
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "HYDRA_MAINTENANCE_FLAG env override is honored" {
  local other="$TEST_TMPDIR/other.json"
  jq -n --argjson exp "$(( $(date -u +%s) + 3600 ))" '{reason:"o", expires_epoch:$exp}' > "$other"
  # setup's default flag.json does not exist -> not active without the override
  run maintenance_active
  [ "$status" -eq 1 ]
  # override pointing at the active flag -> active
  HYDRA_MAINTENANCE_FLAG="$other" run maintenance_active
  [ "$status" -eq 0 ]
}

@test "maintenance_reason on an absent flag is empty and clean (exit 0)" {
  rm -f "$HYDRA_MAINTENANCE_FLAG"
  run maintenance_reason
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard does not trip the caller's set -e (sourced into a strict script)" {
  # A watchdog sources this under `set -euo pipefail`; a failing internal read
  # (malformed flag) must return 1, never abort the caller.
  printf 'garbage' > "$HYDRA_MAINTENANCE_FLAG"
  run bash -c 'set -euo pipefail
    source "'"$HYDRA_REPO"'/scripts/lib/maintenance-flag.sh"
    if maintenance_active; then echo ACTIVE; else echo INACTIVE; fi
    echo REACHED_END'
  [ "$status" -eq 0 ]
  [[ "$output" == *"INACTIVE"* ]]
  [[ "$output" == *"REACHED_END"* ]]
}
