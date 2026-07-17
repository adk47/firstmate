#!/usr/bin/env bats
# Tests scripts/hydra-maintenance.sh — the start/stop/status/is-active CLI that
# opens and closes a maintenance window. Hermetic: HYDRA_MAINTENANCE_FLAG at a temp
# path (no /run access); `muso` PATH-stubbed and MUSO_SLACK_ENV_FILE absent so no
# real Slack post can fire (a lockfile test once paged nine real alerts — never run
# the real slack path in bats).
bats_require_minimum_version 1.5.0

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CLI="$HYDRA_REPO/scripts/hydra-maintenance.sh"
  TEST_TMPDIR="$(mktemp -d)"
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/flag.json"
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/absent.env"   # no token -> slack_notify no-ops
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "start writes a valid flag: reason, ttl_seconds, and expires = started + ttl" {
  run "$CLI" start "openclaw 7.1 upgrade" --ttl 2h
  [ "$status" -eq 0 ]
  [ -f "$HYDRA_MAINTENANCE_FLAG" ]
  [ "$(jq -r '.reason' "$HYDRA_MAINTENANCE_FLAG")" = "openclaw 7.1 upgrade" ]
  [ "$(jq -r '.ttl_seconds' "$HYDRA_MAINTENANCE_FLAG")" = "7200" ]
  local s e
  s="$(jq -r '.started_epoch' "$HYDRA_MAINTENANCE_FLAG")"
  e="$(jq -r '.expires_epoch' "$HYDRA_MAINTENANCE_FLAG")"
  [ "$(( e - s ))" -eq 7200 ]
}

@test "is-active tracks the window: 0 after start, 1 after stop (flag removed)" {
  "$CLI" start "win" --ttl 1h
  run "$CLI" is-active
  [ "$status" -eq 0 ]
  "$CLI" stop
  run "$CLI" is-active
  [ "$status" -eq 1 ]
  [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]
}

@test "ttl units parse: 30s, 15m, 2h, 1d" {
  "$CLI" start w --ttl 30s; [ "$(jq -r .ttl_seconds "$HYDRA_MAINTENANCE_FLAG")" = "30" ]
  "$CLI" start w --ttl 15m; [ "$(jq -r .ttl_seconds "$HYDRA_MAINTENANCE_FLAG")" = "900" ]
  "$CLI" start w --ttl 2h;  [ "$(jq -r .ttl_seconds "$HYDRA_MAINTENANCE_FLAG")" = "7200" ]
  "$CLI" start w --ttl 1d;  [ "$(jq -r .ttl_seconds "$HYDRA_MAINTENANCE_FLAG")" = "86400" ]
}

@test "invalid --ttl fails loud (exit 2) and writes no flag" {
  run "$CLI" start "win" --ttl 2x
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --ttl"* ]]
  [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]
}

@test "zero TTL is rejected (exit 2, no flag) — else it announces an already-expired window" {
  for z in 0s 0m 0h 0d; do
    run "$CLI" start "win" --ttl "$z"
    [ "$status" -eq 2 ]
    [[ "$output" == *"greater than zero"* ]]
    [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]
  done
}

@test "TTL beyond the 24h cap is rejected; exactly 24h is allowed" {
  run "$CLI" start "win" --ttl 25h
  [ "$status" -eq 2 ]
  [[ "$output" == *"24h cap"* ]]
  [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]
  run "$CLI" start "win" --ttl 24h
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ttl_seconds' "$HYDRA_MAINTENANCE_FLAG")" = "86400" ]
}

@test "an int64-overflowing all-digit TTL is rejected before arithmetic (no phantom window)" {
  # 18446744073709551617 = 2^64+1: $((n)) would wrap to 1 and slip past the cap,
  # writing a phantom ~1s window. The lexical magnitude bound must catch it first.
  run "$CLI" start "win" --ttl 18446744073709551617s
  [ "$status" -eq 2 ]
  [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]
}

@test "leading zeros are base-10, not octal (010m == 600s, 08h doesn't error)" {
  "$CLI" start "win" --ttl 010m
  [ "$(jq -r '.ttl_seconds' "$HYDRA_MAINTENANCE_FLAG")" = "600" ]   # 10 min, not octal 8
  "$CLI" start "win" --ttl 08h
  [ "$(jq -r '.ttl_seconds' "$HYDRA_MAINTENANCE_FLAG")" = "28800" ] # 8h, and 08 doesn't abort
}

@test "start with no reason fails loud (exit 2), no flag" {
  run "$CLI" start --ttl 2h
  [ "$status" -eq 2 ]
  [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]
}

@test "missing --ttl uses the default (2h)" {
  run "$CLI" start "win"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ttl_seconds' "$HYDRA_MAINTENANCE_FLAG")" = "7200" ]
}

@test "explicit --operator is recorded verbatim" {
  "$CLI" start "win" --operator "nick@example"
  [ "$(jq -r '.operator' "$HYDRA_MAINTENANCE_FLAG")" = "nick@example" ]
}

@test "default operator falls back to <user>@hydra-ops" {
  "$CLI" start "win"
  [[ "$(jq -r '.operator' "$HYDRA_MAINTENANCE_FLAG")" == *"@hydra-ops" ]]
}

@test "unknown subcommand fails loud (exit 2)" {
  run "$CLI" frobnicate
  [ "$status" -eq 2 ]
}

@test "unknown flag to start fails loud (exit 2)" {
  run "$CLI" start "win" --bogus
  [ "$status" -eq 2 ]
}

@test "status on an absent flag is clean (exit 0)" {
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no maintenance window"* ]]
}

@test "status on an active window reports ACTIVE + reason" {
  "$CLI" start "state surgery" --ttl 1h
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTIVE"* ]]
  [[ "$output" == *"state surgery"* ]]
}

@test "an EXPIRED flag: is-active is false and status says EXPIRED" {
  jq -n --argjson exp "$(( $(date -u +%s) - 10 ))" \
    '{reason:"old", operator:"x", started_at:"x", started_epoch:0, ttl_seconds:1,
      expires_at:"x", expires_epoch:$exp}' > "$HYDRA_MAINTENANCE_FLAG"
  run "$CLI" is-active
  [ "$status" -eq 1 ]
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRED"* ]]
}

@test "stop with no active flag is a clean no-op (exit 0)" {
  run "$CLI" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to stop"* ]]
}
