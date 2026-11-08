#!/usr/bin/env bats
# muso-prewrite-hook.sh claim-verify pace gate (2026-10-11): at most one
# POST .../claiming/<id>/verify per 20 s host-wide, for every muso caller.
# The hook has no env knobs by design, so tests run a COPY whose hardcoded
# state path points into the test dir, next to a healthy codex-health stub.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REAL_HOOK="$HYDRA_REPO/scripts/muso-prewrite-hook.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  sed "s#^CLAIM_VERIFY_LAST=.*#CLAIM_VERIFY_LAST=\"$TEST_TMPDIR/claim-verify.last\"#" "$REAL_HOOK" > "$TEST_TMPDIR/scripts/muso-prewrite-hook.sh"
  chmod +x "$TEST_TMPDIR/scripts/muso-prewrite-hook.sh"
  printf '%s\n' 'codex_health_gate() { return 0; }' > "$TEST_TMPDIR/scripts/lib/codex-health.sh"
  HOOK="$TEST_TMPDIR/scripts/muso-prewrite-hook.sh"
  unset MUSO_HOOK_PROVIDER
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the real hook hardcodes a 20s interval and a /var/lib/hydra state file" {
  grep -qx 'CLAIM_VERIFY_MIN_INTERVAL=20' "$REAL_HOOK"
  grep -qx 'CLAIM_VERIFY_LAST="/var/lib/hydra/claim-verify.last"' "$REAL_HOOK"
}

@test "first claim verify passes, a second within 20s is refused (exit 3)" {
  run "$HOOK" POST /admin/claiming/1/verify prod
  [ "$status" -eq 0 ]
  run --separate-stderr "$HOOK" POST /admin/claiming/2/verify prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"one per 20s"* ]]
}

@test "the gate matches muso's path spellings and lowercase methods" {
  run "$HOOK" post /claiming/9/verify prod
  [ "$status" -eq 0 ]
  run "$HOOK" POST "/api/v3/admin/claiming/10/verify?x=1" prod
  [ "$status" -eq 3 ]
}

@test "other writes are not paced" {
  date +%s > "$TEST_TMPDIR/claim-verify.last"
  run "$HOOK" POST /admin/claiming/1/reject prod
  [ "$status" -eq 0 ]
  run "$HOOK" PUT /admin/credit-requests prod
  [ "$status" -eq 0 ]
}

@test "no provider label exempts a claim verify (the pace gate runs before the slack branch)" {
  date +%s > "$TEST_TMPDIR/claim-verify.last"
  MUSO_HOOK_PROVIDER=slack run "$HOOK" POST /admin/claiming/1/verify prod
  [ "$status" -eq 3 ]
  MUSO_HOOK_PROVIDER=slack run "$HOOK" POST /chat.postMessage prod
  [ "$status" -eq 0 ]
}

@test "an unwritable state dir fails closed for claim verifies" {
  sed -i.bak "s#^CLAIM_VERIFY_LAST=.*#CLAIM_VERIFY_LAST=\"/proc/nope/claim-verify.last\"#" "$HOOK"
  run --separate-stderr "$HOOK" POST /admin/claiming/1/verify prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"fail closed"* ]]
}

@test "a timestamp that cannot be written fails closed (state directory is read-only)" {
  # QA on hydra#1140: the lock could open but the stamp write fail, and the gate
  # still returned 0. An unrecorded verify would let the next one through.
  # First use (no stamp yet), lock file already openable, directory read-only so the stamp write fails.
  [ "$(id -u)" -ne 0 ] || skip "root writes into read-only dirs"
  : > "$TEST_TMPDIR/claim-verify.last.lock"
  chmod 555 "$TEST_TMPDIR"
  run --separate-stderr "$HOOK" POST /admin/claiming/1/verify prod
  chmod 755 "$TEST_TMPDIR"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"cannot record the claim-verify timestamp"* ]]
}

@test "without flock the gate refuses instead of running unserialized" {
  # QA on hydra#1140: a missing flock used to fall through, so concurrent
  # callers could all read the same old stamp and pass. Build a PATH with only
  # the tools the hook needs, and no flock.
  mkdir -p "$TEST_TMPDIR/nolock-bin"
  for t in bash env dirname tr mkdir date cat; do
    ln -s "$(command -v "$t")" "$TEST_TMPDIR/nolock-bin/$t"
  done
  run --separate-stderr env PATH="$TEST_TMPDIR/nolock-bin" bash "$HOOK" POST /admin/claiming/1/verify prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"flock is unavailable"* ]]
  [ ! -e "$TEST_TMPDIR/claim-verify.last" ]
  # Two concurrent callers without flock: both refused, none slips through.
  env PATH="$TEST_TMPDIR/nolock-bin" bash "$HOOK" POST /admin/claiming/2/verify prod 2>/dev/null & p1=$!
  env PATH="$TEST_TMPDIR/nolock-bin" bash "$HOOK" POST /admin/claiming/3/verify prod 2>/dev/null & p2=$!
  rc1=0; wait "$p1" || rc1=$?
  rc2=0; wait "$p2" || rc2=$?
  [ "$rc1" -eq 3 ] && [ "$rc2" -eq 3 ]
}

@test "with flock, concurrent callers: exactly one claim verify passes" {
  pids=()
  for i in 1 2 3 4 5 6; do
    ( "$HOOK" POST "/admin/claiming/$i/verify" prod >/dev/null 2>&1; echo $? > "$TEST_TMPDIR/rc.$i" ) &
    pids+=("$!")
  done
  # Explicit pids, never a bare `wait` (bats' BATS_TEST_TIMEOUT watchdog is a child too).
  wait "${pids[@]}" || true   # asserts on files, not the child's status
  passed=$(grep -lx 0 "$TEST_TMPDIR"/rc.* | wc -l | tr -d ' ')
  [ "$passed" -eq 1 ]
}

@test "an empty or malformed stamp is refused, not reset to zero" {
  # QA bot on hydra#1140 (60431c18): a truncated stamp read as 0, so a verify right after another passed.
  for bad in "" "garbage" "12abc" "08" "0000000009"; do
    printf '%s' "$bad" > "$TEST_TMPDIR/claim-verify.last"
    run --separate-stderr "$HOOK" POST /admin/claiming/1/verify prod
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"unreadable or malformed"* ]]
    [ "$(cat "$TEST_TMPDIR/claim-verify.last")" = "$bad" ]
  done
}

@test "an unreadable stamp is refused" {
  [ "$(id -u)" -ne 0 ] || skip "root reads mode-000 files"
  echo "$(date +%s)" > "$TEST_TMPDIR/claim-verify.last"
  chmod 000 "$TEST_TMPDIR/claim-verify.last"
  run --separate-stderr "$HOOK" POST /admin/claiming/1/verify prod
  chmod 600 "$TEST_TMPDIR/claim-verify.last"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"unreadable or malformed"* ]]
}

@test "a future-dated stamp is refused, not reset (clock stepped back)" {
  # QA on hydra#1140: `last > now` reset last to 0 and the next verify passed.
  future=$(( $(date +%s) + 3600 ))
  echo "$future" > "$TEST_TMPDIR/claim-verify.last"
  run --separate-stderr "$HOOK" POST /admin/claiming/1/verify prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in the future"* ]]
  [[ "$stderr" == *"clear $TEST_TMPDIR/claim-verify.last as root"* ]]
  [ "$(cat "$TEST_TMPDIR/claim-verify.last")" = "$future" ]
}
