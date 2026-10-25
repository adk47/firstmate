#!/usr/bin/env bats
# Claim verify gate (2026-10-11). POST /admin/claiming/:id/verify makes the
# claimant the verified owner of a profile. Forensics: 2,424 claim verifies at a
# 0.44 s median gap since 09-01, including impostor claims. Now:
#   - it is a tier-2 endpoint (the SHIPPED config lists it): --confirmed-by +
#     --approval-msg-id, and a god-mode requester must still pass
#     --approval-msg-id (no self-approve off an auto-stamped --requester);
#   - at most one claim verify per 20 s host-wide (pace gate).

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    REAL_SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    # The shipped wrapper pins the state path (no env knob), so tests run a COPY
    # whose one hardcoded path points into the test dir.
    SCRIPT="$TEST_ROOT/muso-admin-api.sh"
    sed "s#^CLAIM_VERIFY_LAST=.*#CLAIM_VERIFY_LAST=\"$TEST_ROOT/claim-verify.last\"#" "$REAL_SCRIPT" > "$SCRIPT"
    export BULK_DESTRUCTIVE_EXCLUDE_PATH="${BATS_TEST_DIRNAME}/../../config/bulk-destructive-exclude.txt"
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"
    # The SHIPPED endpoint list: the point is that claim verify is in it.
    export TIER2_ENDPOINTS_PATH="${BATS_TEST_DIRNAME}/../../config/tier2-endpoints.txt"
    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    printf 'aaron\naaron@muso.ai\n' > "$TIER2_APPROVERS_PATH"
    export TIER2_GODMODE_PATH="$TEST_ROOT/godmode.txt"
    printf 'jan\njan@muso.ai\n' > "$TIER2_GODMODE_PATH"
    CLAIM_VERIFY_LAST_PATH="$TEST_ROOT/claim-verify.last"
    export CV_APPROVE_GATE_DISABLED=1
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/dry-run-audit.jsonl"
    export CV_RESULTS_PATH="$TEST_ROOT/credit-results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"
    unset OPS_DRY_RUN
}

teardown() { rm -rf "$TEST_ROOT"; }

@test "the shipped tier-2 list gates claim verify" {
    grep -qx 'POST /admin/claiming/:id/verify' "$TIER2_ENDPOINTS_PATH"
}

@test "claim verify without --confirmed-by is refused" {
    run bash "$SCRIPT" call POST /admin/claiming/1604460/verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
    [ ! -e "$CLAIM_VERIFY_LAST_PATH" ]
}

@test "a god-mode requester cannot self-approve a claim verify off --requester alone" {
    run bash "$SCRIPT" --requester jan@muso.ai call POST /admin/claiming/1604460/verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
}

@test "claim reject and revert stay outside the claim-verify gate" {
    run bash "$SCRIPT" call POST /admin/claiming/1604460/reject '{"reason":"x"}'
    [[ "$output" != *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
    [[ "$output" != *"MUSO_CLAIM_VERIFY"* ]]
}

@test "a second approved claim verify inside 20s is refused by the pace gate" {
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.1 call POST /admin/claiming/1/verify
    # Passes every gate, then fails at the closed test port (not a gate refusal).
    [[ "$output" != *"MUSO_CLAIM_VERIFY_TOO_FAST"* ]]
    [[ "$output" != *"MUSO_TIER2"* ]]
    [ -s "$CLAIM_VERIFY_LAST_PATH" ]
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.2 call POST /admin/claiming/2/verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_CLAIM_VERIFY_TOO_FAST"* ]]
}

@test "the pace interval cannot be lowered below 20s by env" {
    date +%s > "$CLAIM_VERIFY_LAST_PATH"
    CLAIM_VERIFY_MIN_INTERVAL=0 run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.3 call POST /admin/claiming/3/verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_CLAIM_VERIFY_TOO_FAST"* ]]
}

@test "a claim verify older than 20s ago does not block the next one" {
    echo $(( $(date +%s) - 25 )) > "$CLAIM_VERIFY_LAST_PATH"
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.4 call POST /admin/claiming/4/verify
    [[ "$output" != *"MUSO_CLAIM_VERIFY_TOO_FAST"* ]]
}

@test "a claim-verify timestamp that cannot be written fails closed" {
    # First use (no stamp yet), lock file already openable, directory read-only so the stamp write fails.
    [ "$(id -u)" -ne 0 ] || skip "root writes into read-only dirs"
    mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/pace"
    sed -i.bak "s#^CLAIM_VERIFY_LAST=.*#CLAIM_VERIFY_LAST=\"$TEST_ROOT/pace/claim-verify.last\"#" "$SCRIPT"
    : > "$TEST_ROOT/pace/claim-verify.last.lock"
    chmod 555 "$TEST_ROOT/pace"
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.5 call POST /admin/claiming/5/verify
    chmod 755 "$TEST_ROOT/pace"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot record the claim-verify timestamp"* ]]
}

@test "the wrapper requires flock for claim verifies (no unserialized fallback)" {
    grep -q 'flock is unavailable, so concurrent claim verifies cannot be serialized' "$REAL_SCRIPT"
    run grep -c 'command -v flock >/dev/null 2>&1 && ! flock' "$REAL_SCRIPT"
    [ "$output" = "0" ]
}

@test "a future-dated pace stamp is refused, not reset (clock stepped back)" {
    # QA on hydra#1140: `last > now` used to reset last to 0, so the very next verify passed.
    echo $(( $(date +%s) + 3600 )) > "$CLAIM_VERIFY_LAST_PATH"
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.6 call POST /admin/claiming/6/verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"in the future"* ]]
    [[ "$output" == *"clear $CLAIM_VERIFY_LAST_PATH as root"* ]]
    [ "$(cat "$CLAIM_VERIFY_LAST_PATH")" -gt "$(date +%s)" ]
}

@test "an empty or malformed pace stamp is refused, not reset to zero" {
    # QA bot on hydra#1140 (60431c18): a truncated stamp read as 0, so a verify right after another passed.
    for bad in "" "garbage" "12abc" "08" "0000000009"; do
        printf '%s' "$bad" > "$CLAIM_VERIFY_LAST_PATH"
        run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.6 call POST /admin/claiming/6/verify
        [ "$status" -eq 1 ]
        [[ "$output" == *"MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE"* ]]
        [[ "$output" == *"unreadable or malformed"* ]]
        [ "$(cat "$CLAIM_VERIFY_LAST_PATH")" = "$bad" ]
    done
}

@test "an unreadable pace stamp is refused" {
    [ "$(id -u)" -ne 0 ] || skip "root reads mode-000 files"
    echo "$(date +%s)" > "$CLAIM_VERIFY_LAST_PATH"
    chmod 000 "$CLAIM_VERIFY_LAST_PATH"
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.6 call POST /admin/claiming/6/verify
    chmod 600 "$CLAIM_VERIFY_LAST_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unreadable or malformed"* ]]
}

@test "the shipped wrapper pins the pace state path: CLAIM_VERIFY_LAST_PATH is ignored" {
    # QA on hydra#1140: a caller-chosen path gave each caller a fresh stamp and
    # bypassed the host-wide budget. Two different override paths must share one.
    ! grep -q 'CLAIM_VERIFY_LAST_PATH' "$REAL_SCRIPT"
    grep -qx 'CLAIM_VERIFY_LAST="/var/lib/hydra/claim-verify.last"' "$REAL_SCRIPT"
    export CLAIM_VERIFY_LAST_PATH="$TEST_ROOT/other-a.last"
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.7 call POST /admin/claiming/7/verify
    export CLAIM_VERIFY_LAST_PATH="$TEST_ROOT/other-b.last"
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1791.8 call POST /admin/claiming/8/verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_CLAIM_VERIFY_TOO_FAST"* ]]
    [ ! -e "$TEST_ROOT/other-a.last" ] && [ ! -e "$TEST_ROOT/other-b.last" ]
}

# QA bot Important on ba3e4cd: the tier-2 matcher was an exact match, the pace
# gate accepts /verify/, so the trailing-slash spelling skipped the human approval.
@test "claim verify with a trailing slash is gated like the bare spelling" {
    run bash "$SCRIPT" call POST /admin/claiming/1604460/verify/
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
    run bash "$SCRIPT" call POST "/admin/claiming/1604460/verify/?x=1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
}

@test "a god-mode requester cannot self-approve claim verify with a trailing slash either" {
    run bash "$SCRIPT" --requester jan@muso.ai call POST /admin/claiming/1604460/verify/
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
    run bash "$SCRIPT" --requester jan@muso.ai call POST "/admin/claiming/1604460/verify/?x=1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
}
