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
  export HYDRA_DEPLOY_WINDOW_FLAG="$TEST_TMPDIR/window.json"
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

# ── deploy_window_active (MUS-5175): separate flag, same fail-safe ──────────

write_window() { jq -n --argjson e "$1" '{reason:"deploy gateway warm-up",expires_epoch:$e}' > "$HYDRA_DEPLOY_WINDOW_FLAG"; }

@test "deploy window: unexpired => active, reason readable" {
  write_window "$(( $(date -u +%s) + 600 ))"
  run deploy_window_active
  [ "$status" -eq 0 ]
  run deploy_window_reason
  [ "$output" = "deploy gateway warm-up" ]
}

@test "deploy window: absent => NOT active" {
  run deploy_window_active
  [ "$status" -eq 1 ]
}

@test "deploy window: expired => NOT active (the TTL is the window)" {
  write_window "$(( $(date -u +%s) - 1 ))"
  run deploy_window_active
  [ "$status" -eq 1 ]
}

@test "deploy window: malformed JSON => NOT active" {
  printf 'not json {{{' > "$HYDRA_DEPLOY_WINDOW_FLAG"
  run deploy_window_active
  [ "$status" -eq 1 ]
}

@test "deploy window: non-numeric expires_epoch => NOT active" {
  jq -n '{reason:"x",expires_epoch:"soon"}' > "$HYDRA_DEPLOY_WINDOW_FLAG"
  run deploy_window_active
  [ "$status" -eq 1 ]
}

@test "an open deploy window does not change maintenance_active's verdict" {
  write_window "$(( $(date -u +%s) + 600 ))"
  run maintenance_active
  [ "$status" -eq 1 ]
  write_flag "$(( $(date -u +%s) + 600 ))"
  rm -f "$HYDRA_DEPLOY_WINDOW_FLAG"
  run deploy_window_active
  [ "$status" -eq 1 ]
}

@test "deploy_window_arm writes only the window flag, with a future numeric expiry" {
  run deploy_window_arm 900 "deploy gateway warm-up"
  [ "$status" -eq 0 ]
  [ ! -e "$HYDRA_MAINTENANCE_FLAG" ]
  exp=$(jq -r .expires_epoch "$HYDRA_DEPLOY_WINDOW_FLAG")
  [[ "$exp" =~ ^[0-9]+$ ]]
  [ "$exp" -gt "$(date -u +%s)" ]
  run deploy_window_active
  [ "$status" -eq 0 ]
  run maintenance_active
  [ "$status" -eq 1 ]
}

@test "deploy_window_arm refuses a non-numeric or zero ttl and writes nothing" {
  run deploy_window_arm abc x
  [ "$status" -eq 1 ]
  run deploy_window_arm 0 x
  [ "$status" -eq 1 ]
  [ ! -e "$HYDRA_DEPLOY_WINDOW_FLAG" ]
}

@test "deploy.sh's Step 6 arm lines, executed, open the window with a future numeric expiry" {
  d="$HYDRA_REPO/scripts/deploy.sh"
  # Extract the REAL arm statement (default assignment + run_on_node8 call + its
  # `|| log` continuation) and run it, so deleting or breaking it goes red.
  lines=$(sed -n '/^  HYDRA_DEPLOY_WINDOW_SECS=/,/^    || log /p' "$d")
  [[ "$lines" == *deploy_window_arm* ]]
  # armed INSIDE the `if gateway_restart_needed` branch (a no-restart deploy must
  # not open a window), before Phase A requests the restart
  gate=$(grep -n '^if gateway_restart_needed; then' "$d" | head -1 | cut -d: -f1)
  arm=$(grep -n '^  run_on_node8 ".*deploy_window_arm' "$d" | head -1 | cut -d: -f1)
  phase=$(grep -n '^  # Phase A: request the safe restarts' "$d" | head -1 | cut -d: -f1)
  close=$(awk -v g="$gate" 'NR>g && /^(fi|else)/ {print NR; exit}' "$d")
  [ -n "$gate" ]; [ -n "$arm" ]; [ -n "$phase" ]; [ -n "$close" ]
  [ "$gate" -lt "$arm" ]; [ "$arm" -lt "$phase" ]; [ "$arm" -lt "$close" ]
  # and exactly one arm call, so a second unconditional one cannot hide
  [ "$(grep -c 'deploy_window_arm' "$d")" -eq 1 ]
  rm -f "$HYDRA_DEPLOY_WINDOW_FLAG"
  before=$(date -u +%s)
  HYDRA_LOCAL=true DEPLOY_PATH="$HYDRA_REPO" HYDRA_DEPLOY_WINDOW_FLAG="$HYDRA_DEPLOY_WINDOW_FLAG" \
    HYDRA_MAINTENANCE_FLAG="$HYDRA_MAINTENANCE_FLAG" \
    bash -c 'log() { echo "$*"; }; run_on_node8() { bash -c "$1"; }; '"$lines"
  exp=$(jq -r .expires_epoch "$HYDRA_DEPLOY_WINDOW_FLAG")
  [[ "$exp" =~ ^[0-9]+$ ]]
  [ "$exp" -ge $(( before + 900 )) ]
  [ "$exp" -le $(( $(date -u +%s) + 900 )) ]
  # decision 1: deploy.sh never writes the maintenance flag
  [ ! -e "$HYDRA_MAINTENANCE_FLAG" ]
  run grep -nE 'hydra-maintenance|HYDRA_MAINTENANCE_FLAG' "$d"
  [[ "$output" != *"/run/hydra-maintenance"* ]]
  [[ "$output" != *"HYDRA_MAINTENANCE_FLAG"* ]]
}

@test "the window's DEFAULT path is its own file, never the maintenance flag's" {
  # Pins the load-bearing decision: the untracked gateway guard ignores the
  # maintenance flag's TTL, so arming that path would muzzle it. Env unset on
  # purpose; the other tests override the path and cannot see a collapse.
  run env -u HYDRA_DEPLOY_WINDOW_FLAG -u HYDRA_MAINTENANCE_FLAG bash -c \
    'source "'"$HYDRA_REPO"'/scripts/lib/maintenance-flag.sh"; echo "$HYDRA_DEPLOY_WINDOW_FLAG $HYDRA_MAINTENANCE_FLAG"'
  [ "$status" -eq 0 ]
  [ "$output" = "/run/hydra-deploy-window /run/hydra-maintenance" ]
}
