#!/usr/bin/env bats
# Tests for the bulk destructive-operation gate added to muso-admin-api.sh
# after incident 2026-05-26 (the ops agent autonomously issued ~285 DELETE
# /admin/track/:id/analytics-sources calls in one run, wiping the only Spotify
# link on 10 tracks).
#
# Gate contract:
# - Counts DELETE calls within the last BULK_DESTRUCTIVE_WINDOW_SECS (window-
#   only, NOT per-run). Once BULK_DESTRUCTIVE_THRESHOLD is reached, every
#   further destructive DELETE is refused unless --confirmed-by <approver> AND
#   --approval-msg-id <ts> are supplied.
# - A requester on the GOD-MODE allowlist (aaron/jan/nick) self-approves with
#   --approval-msg-id alone — their own request message is the decision, and no
#   second human is paged (policy 2026-08-26). Requester identity alone is
#   still not enough: the msg-id is the audit anchor, and everyone off that
#   list still needs --confirmed-by (the 2026-05-26 blast-radius cap).
# - A deny-list (config/bulk-destructive-exclude.txt) exempts harmless DELETEs
#   (e.g. profile cache). A MISSING exclude file means EVERYTHING counts.
# - Dry-run self-skips the gate and records nothing.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port so any real HTTP fails loudly. The gate short-circuits before
    # curl on every BLOCKED case; PASS cases fall through to curl (which fails),
    # so we assert on positive signals (audit row) not on the HTTP result.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"

    # Test-scoped state so we never write to /var/log/muso-ops.
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/state/destructive-ops.jsonl"
    export BULK_DESTRUCTIVE_AUDIT_PATH="$TEST_ROOT/state/bulk-destructive-audit.jsonl"
    export BULK_DESTRUCTIVE_THRESHOLD=3
    export BULK_DESTRUCTIVE_WINDOW_SECS=900

    # Test-scoped config so we aren't coupled to the canonical config dir.
    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    export TIER2_GODMODE_PATH="$TEST_ROOT/tier2-godmode-allowlist.txt"
    export BULK_DESTRUCTIVE_EXCLUDE_PATH="$TEST_ROOT/bulk-destructive-exclude.txt"
    cat > "$TIER2_APPROVERS_PATH" <<EOF
# test approvers
aaron
aaron@muso.ai
EOF
    cat > "$TIER2_ENDPOINTS_PATH" <<EOF
POST /admin/profiles/merge
POST /admin/profiles/unmerge
EOF
    # Seed god-mode WITH the requesters we test below — the self-approve cases
    # assert that being on this list is exactly what clears the gate, and the
    # non-god-mode case asserts that being off it is not survivable.
    cat > "$TIER2_GODMODE_PATH" <<EOF
aaron@muso.ai
jan@muso.ai
nick@muso.ai
EOF
    cat > "$BULK_DESTRUCTIVE_EXCLUDE_PATH" <<EOF
/admin/profile/*/cache
EOF

    # Disable the credit-approve gate (irrelevant here) and seed a token so any
    # PASS path that reaches get_token is satisfied.
    export CV_APPROVE_GATE_DISABLED=1
    # The codex model-health gate runs first on every write; it's covered by
    # scripts/tests/muso-admin-api-codex-health.bats. Point it at a healthy stub
    # so these downstream-gate tests stay hermetic (production has no bypass flag).
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/dry-run-audit.jsonl"
    export CV_RESULTS_PATH="$TEST_ROOT/credit-results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# Append N destructive-DELETE records to the rolling counter at a given epoch
# (default: now). Mirrors record_destructive_op's on-disk shape.
seed_destructive_ops() {
    local n="$1" epoch="${2:-$(date +%s)}" i
    mkdir -p "$(dirname "$BULK_DESTRUCTIVE_PATH")"
    for (( i = 0; i < n; i++ )); do
        jq -n -c --argjson epoch "$epoch" \
            '{ts:"seed", epoch:$epoch, method:"DELETE", path:"/admin/track/seed/analytics-sources", requester:"seed"}' \
            >> "$BULK_DESTRUCTIVE_PATH"
    done
}

# --- Under / at threshold ---

@test "destructive DELETE under threshold passes the gate" {
    seed_destructive_ops 2   # threshold is 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "destructive DELETE AT threshold without --confirmed-by is BLOCKED" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

# The refusal message is the text the agent actually reads at the moment it is
# blocked, so it outranks any SKILL.md prose. It previously said "each call past
# the threshold needs genuine approval ... hand it to a human to run", which
# contradicted the enumerated-requester rule and is exactly what made the agent
# page a human on delete 11.

@test "refusal message tells the agent an enumerated requester's own message IS the decision" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"enumerated the exact targets"* ]]
    [[ "$output" == *"their own request message IS that decision"* ]]
    [[ "$output" == *"should not page anyone"* ]]
}

@test "refusal message no longer carries the contradictory hand-it-to-a-human guidance" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" != *"hand it to a human to run"* ]]
    [[ "$output" != *"Each call past the threshold needs genuine approval"* ]]
}

@test "refusal message still scopes the decision to the enumerated set only" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"ONLY that set"* ]]
    [[ "$output" == *"a different set of rows is"* ]]
}

@test "AT threshold with --confirmed-by NOT in allowlist is rejected" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by jan --approval-msg-id 1.2 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID"* ]]
}

@test "AT threshold with approver but missing --approval-msg-id is refused" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by aaron \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--approval-msg-id"* ]]
}

@test "AT threshold with valid approver + msg-id passes AND audits" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1779999999.001 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_APPROVAL"* ]]
    [ -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
    grep -q '"confirmed_by":"aaron"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"approval_msg_id":"1779999999.001"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"count_at_trip":3' "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

# --- God-mode self-approval (policy 2026-08-26) ---
#
# Rationale lives with the code, in enforce_bulk_destructive_gate's branch
# comment. What matters for these tests: the god-mode branch still demands an
# AUDIT ANCHOR (--approval-msg-id), and the non-god-mode regression test below
# is the one that must never go green wrongly.

@test "god-mode requester (jan) self-approves the bulk gate with his own msg-id" {
    seed_destructive_ops 3
    # Precondition: jan is NOT in this harness's approver file (setup() seeds
    # aaron only), so passing here proves self-approval reads the GOD-MODE list
    # and not tier2-approvers.txt. Asserted via run/status because a bare
    # `! grep` is a no-op under bats' set -e unless it is the last line, and
    # `grep -v` would pass on any non-matching line.
    run grep -q jan "$TIER2_APPROVERS_PATH"
    [ "$status" -ne 0 ]
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.002222 --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_APPROVAL"* ]]
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE"* ]]
    [ -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
    grep -q '"bypass":"god_mode_self_approve"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"requester":"jan@muso.ai"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"confirmed_by":"jan@muso.ai"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"approval_msg_id":"1779999999.002222"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"count_at_trip":3' "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

@test "bulk gate: god-mode self-approve never covers a credit removal (firstmate 122)" {
    seed_destructive_ops 3
    # Precondition: jan is NOT in this harness's approver file (setup() seeds
    # aaron only), so passing here proves self-approval reads the GOD-MODE list
    # and not tier2-approvers.txt. Asserted via run/status because a bare
    # `! grep` is a no-op under bats' set -e unless it is the last line, and
    # `grep -v` would pass on any non-matching line.
    run grep -q jan "$TIER2_APPROVERS_PATH"
    [ "$status" -ne 0 ]
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.002222 --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/profile/p1/credits
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "god-mode requester (aaron) self-approves the bulk gate with his own msg-id" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester aaron@muso.ai --approval-msg-id 1779999999.004444 --approval-author-id U7RP6HKUZ \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_APPROVAL"* ]]
    grep -q '"bypass":"god_mode_self_approve"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"requester":"aaron@muso.ai"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

# The refusal an allowlisted requester hits must be SELF-SERVE. If it reads as
# "go find a human", the agent pages one — that is the whole bug this policy
# fixes, and the refusal text outranks any SKILL.md prose because it is what
# the agent reads at the moment it is blocked.
@test "god-mode requester without --approval-msg-id gets self-serve wording, never a page" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_MSG_REQUIRED"* ]]
    [[ "$output" == *"--approval-msg-id"* ]]
    [[ "$output" == *"You do not need anyone else"* ]]
    # Whole phrases, not substrings: a bare *"page"* also matches "pages" and
    # "paged", so an innocuous rewording would go red for no policy reason.
    [[ "$output" != *"page anyone"* ]]
    [[ "$output" != *"second human"* ]]
    [[ "$output" != *"get an approver"* ]]
}

# A god-mode requester does not need --confirmed-by, but a BOGUS one must still
# be refused rather than silently swapped for the requester's own name. Before
# this branch existed the same flag value was rejected outright; letting it
# through would put a name in the audit row that the caller never supplied.
@test "god-mode requester passing a BOGUS --confirmed-by is still refused" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --confirmed-by mallory \
        --approval-msg-id 1779999999.008888 --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
}

# A VALID --confirmed-by from a god-mode requester is honoured and recorded as
# given, so the audit says who the caller actually named.
@test "god-mode requester passing a VALID --confirmed-by has it recorded, not overwritten" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --confirmed-by aaron \
        --approval-msg-id 1779999999.009999 --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_APPROVAL"* ]]
    grep -q '"confirmed_by":"aaron"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"requester":"jan@muso.ai"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"bypass":"god_mode_self_approve"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

# THE regression test for incident 2026-05-26. An --approval-msg-id alone must
# never be a skeleton key: only membership of the god-mode list turns the
# requester's own message into the decision. If this ever goes green while the
# call succeeds, the blast-radius cap is gone for everyone.
@test "a NON-god-mode requester at threshold is still blocked, msg-id or not" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester notallowed@muso.ai --approval-msg-id 1779999999.006666 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
}

# Fail-closed: god-mode is opt-in via the allowlist file. A missing file must
# collapse every requester back to the --confirmed-by path, never open it up.
@test "missing god-mode allowlist file collapses jan back to the approver path" {
    seed_destructive_ops 3
    rm -f "$TIER2_GODMODE_PATH"
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.007777 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

# --- Scope: exclusions, non-DELETE, window ---

@test "excluded path (profile cache) does not count toward the budget" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/profile/123/cache
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "non-DELETE verb is never gated even at threshold" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call PATCH /admin/track/abc/analytics-sources \
        '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "records outside the window do not count" {
    seed_destructive_ops 3 1   # epoch=1, far before the cutoff
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "MISSING exclude file makes everything count (fail-safe-wide)" {
    rm -f "$BULK_DESTRUCTIVE_EXCLUDE_PATH"
    seed_destructive_ops 3
    # With no exclude file, even the normally-exempt cache delete counts.
    run bash "$SCRIPT" call DELETE /admin/profile/123/cache
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

# --- Dry-run ---

@test "dry-run self-skips the gate and records nothing" {
    # No seeding: prove dry-run neither enforces nor writes the counter.
    OPS_DRY_RUN=1 run bash "$SCRIPT" \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"http_status":200'* ]] || [[ "$output" == *'"http_status": 200'* ]]
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_PATH" ]
}

# --- Fail-closed counter persistence (QA, PR #390) ---

@test "counter that cannot be persisted FAILS CLOSED (DELETE refused)" {
    # Put a regular file where the counter's parent dir would go, so
    # record_destructive_op's mkdir -p fails and it cannot write.
    : > "$TEST_ROOT/blocker"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/blocker/destructive-ops.jsonl"
    # Under threshold (no seeding), this would normally pass — but an unwritable
    # counter must NOT silently disable the gate. Refuse instead.
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_COUNTER_UNWRITABLE"* ]]
}

@test "passing destructive DELETE records the ATTEMPT (not gated on a 2xx)" {
    # No seeding (count 0, under threshold). The gate persists this attempt
    # up-front, BEFORE the API call — so the counter advances even though the
    # closed-port curl then fails. Recording attempts (not just successes) is
    # what lets the gate fail closed on an unwritable counter.
    [ ! -f "$BULK_DESTRUCTIVE_PATH" ]
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
    [ -f "$BULK_DESTRUCTIVE_PATH" ]
    [ "$(grep -c '"method":"DELETE"' "$BULK_DESTRUCTIVE_PATH")" -eq 1 ]
}

# --- Forged / unusable provenance (QA #873, finding 2) ---------------------
#
# Nothing here authenticates -- every flag is caller-supplied, and that was
# equally true of the --confirmed-by path before this branch existed (clean HEAD
# accepted `--confirmed-by jan --approval-msg-id x`). What these assert is that
# self-approval cannot be CHEAPER to forge than that path: the citation has to
# be a real ts, authored by an allowlisted identity, so an auditor can open the
# exact message afterwards and see whether it named these rows.

@test "self-approve refuses a placeholder msg-id (the 'x' case)" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id x \
        --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_MSG_INVALID"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
}

@test "self-approve refuses a malformed timestamp (right shape, wrong digits)" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 123.456 \
        --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_MSG_INVALID"* ]]
}

@test "self-approve refuses a cited message with no author id" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.010101 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_REQUIRED"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
}

# The teeth: forging now requires naming a specific allowlisted person as the
# AUTHOR of the cited message, not merely stamping --requester (which the agent
# fills in automatically from whoever is in-thread).
@test "self-approve refuses an author who is not an allowlisted identity" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.111111 \
        --approval-author-id U0NOTAPERSON \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_INVALID"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
}

@test "self-approve records the cited author + channel so the row is checkable" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.121212 \
        --approval-author-id U038BM16T7W --approval-channel C0APB2CMM7C \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE"* ]]
    grep -q '"approval_author_id":"U038BM16T7W"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"approval_channel":"C0APB2CMM7C"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

# QA #873 finding 1: TIER2_GODMODE_PATH is an env override, as are every other
# path/threshold in this wrapper (BULK_DESTRUCTIVE_THRESHOLD=999999 disabled the
# gate outright long before this branch existed). That class cannot be closed
# from inside the gate. What it CAN do is leave evidence, so a self-approve
# granted by an unexpected allowlist is visible in the audit trail instead of
# looking like a routine one.
@test "self-approve records which allowlist granted it" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.131313 \
        --approval-author-id U038BM16T7W \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE"* ]]
    grep -q "\"godmode_allowlist\":\"$TIER2_GODMODE_PATH\"" "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

# The second-approver path is NOT a god-mode grant, so it must not carry the key.
@test "second-approver audit row carries no godmode_allowlist key" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1779999999.141414 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_APPROVAL"* ]]
    run grep -q godmode_allowlist "$BULK_DESTRUCTIVE_AUDIT_PATH"
    [ "$status" -ne 0 ]
}

# QA #873: an email is not a Slack identity. resolve_slack_to_email echoes an
# unrecognised input back unchanged, so without a shape check
# `--approval-author-id jan@muso.ai` would match the allowlist and the flag
# would prove nothing --requester does not already claim.
@test "self-approve refuses an email-shaped author id" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.151515 \
        --approval-author-id jan@muso.ai \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_INVALID"* ]]
    [[ "$output" == *"not a Slack user id"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
}

@test "self-approve refuses a lowercase/short pseudo-UID" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1779999999.161616 \
        --approval-author-id u038bm \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_INVALID"* ]]
}
