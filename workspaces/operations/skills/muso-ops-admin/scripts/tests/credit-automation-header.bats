#!/usr/bin/env bats

# X-Credit-Automation-Id (T12 header contract): core-backend binds the
# credit-trust-decide grant to this header, so muso-admin-api.sh sends it on
# the decider's calls and on nobody else's. curl is PATH-shadowed and records
# its argv; nothing touches the network.

bats_require_minimum_version 1.5.0

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"

    export MUSO_API_URL="https://example.invalid"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"
    export OPS_DRY_RUN=0
    export CV_APPROVE_GATE_DISABLED=1
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/token-cache"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    unset CREDIT_TRUST_DECIDE CREDIT_TRUST_SCORE_APPROVE UVN_POPULARITY_CRON REQUESTER_EMAIL

    mkdir -p "$TEST_ROOT/bin"
    export CURL_ARGV="$TEST_ROOT/curl.argv"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGV"
printf '{"ok":true,"data":{"updatedIds":["11111111-1111-4111-8111-111111111111"],"skippedIds":[],"skipped":[]}}\n200'
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

BODY='{"expectedStatus":"unverified","requestIds":["11111111-1111-4111-8111-111111111111"],"status":"approved"}'

conditional_put() {
    # $1 = CREDIT_TRUST_DECIDE value ("" = unset), $2 = requester ("" = none)
    local -a args=()
    [[ -n "$2" ]] && args+=(--requester "$2")
    if [[ -n "$1" ]]; then
        run --separate-stderr env CREDIT_TRUST_DECIDE="$1" \
            bash "$SCRIPT" "${args[@]}" call PUT /admin/credit-requests/conditional-status "$BODY"
    else
        run --separate-stderr bash "$SCRIPT" "${args[@]}" call PUT /admin/credit-requests/conditional-status "$BODY"
    fi
}

header_count() {
    grep -cx "X-Credit-Automation-Id: credit-trust-decide" "$CURL_ARGV" || true
}

@test "the decider's call carries X-Credit-Automation-Id and still sends Requester" {
    conditional_put 1 "credit-trust-decide@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(header_count)" -eq 1 ]
    grep -qx "Requester: credit-trust-decide@hydra-ops" "$CURL_ARGV"
}

@test "no other caller carries X-Credit-Automation-Id" {
    conditional_put 0 "credit-trust-decide@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(header_count)" -eq 0 ]

    conditional_put "" "credit-trust-decide@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(header_count)" -eq 0 ]

    conditional_put 1 "uvn-popularity-cron@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(header_count)" -eq 0 ]

    conditional_put 1 "credit-review@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(header_count)" -eq 0 ]

    conditional_put 1 ""
    [ "$status" -eq 0 ]
    [ "$(header_count)" -eq 0 ]
}

score_put() {
    # $1 = CREDIT_TRUST_SCORE_APPROVE value, $2 = requester
    run --separate-stderr env CREDIT_TRUST_SCORE_APPROVE="$1" \
        bash "$SCRIPT" --requester "$2" call PUT /admin/credit-requests/conditional-status "$BODY"
}

score_header_count() {
    grep -cx "X-Credit-Automation-Id: credit-trust-score-approve" "$CURL_ARGV" || true
}

@test "score-approve's call carries its own X-Credit-Automation-Id, never the decider's" {
    score_put 1 "credit-trust-score-approve@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(score_header_count)" -eq 1 ]
    [ "$(header_count)" -eq 0 ]
    grep -qx "Requester: credit-trust-score-approve@hydra-ops" "$CURL_ARGV"
}

@test "the score-approve header needs both its flag and its requester" {
    score_put 0 "credit-trust-score-approve@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(score_header_count)" -eq 0 ]
    score_put 1 "credit-trust-decide@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(score_header_count)" -eq 0 ]
    conditional_put 1 "credit-trust-score-approve@hydra-ops"
    [ "$status" -eq 0 ]
    [ "$(score_header_count)" -eq 0 ]
    [ "$(header_count)" -eq 0 ]
}

anchor_post() {
    # $1 = DSP_ANCHOR_WRITER value, $2 = requester, $3 = path
    run --separate-stderr env DSP_ANCHOR_WRITER="$1" \
        bash "$SCRIPT" --requester "$2" call POST "$3" '{"records":[]}'
}

anchor_header_count() {
    grep -cx "X-Credit-Automation-Id: dsp-evidence-verifier" "$CURL_ARGV" || true
}

@test "the DSP verifier's anchor upload carries its own X-Credit-Automation-Id, only on the anchor route" {
    anchor_post 1 "dsp-evidence-verifier@hydra-ops" /admin/credit-anchors
    [ "$status" -eq 0 ]
    [ "$(anchor_header_count)" -eq 1 ]
    [ "$(header_count)" -eq 0 ]
    grep -qx "Requester: dsp-evidence-verifier@hydra-ops" "$CURL_ARGV"
}

@test "the anchor-writer header needs its flag, its requester AND the anchor route" {
    anchor_post 0 "dsp-evidence-verifier@hydra-ops" /admin/credit-anchors
    [ "$(anchor_header_count)" -eq 0 ]
    anchor_post 1 "fable-decider@hydra-ops" /admin/credit-anchors
    [ "$(anchor_header_count)" -eq 0 ]
    anchor_post 1 "dsp-evidence-verifier@hydra-ops" /admin/credit-requests/conditional-status
    [ "$(anchor_header_count)" -eq 0 ]
}

drain_put() {
    # $1 = SCALE_DRAIN value, $2 = requester, $3 = MUSO_ADMIN_IDENTITY ("" = unset), $4 = method, $5 = path
    mkdir -p "$TEST_ROOT/identities"
    for id in scale-drain credit-decider; do
        printf 'MUSO_ADMIN_EMAIL=%s@example.com\nMUSO_ADMIN_PASSWORD=unused\n' "$id" > "$TEST_ROOT/identities/$id.env"
        printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH.$id"
    done
    local -a ident=()
    [[ -n "$3" ]] && ident=(MUSO_ADMIN_IDENTITY="$3")
    run --separate-stderr env SCALE_DRAIN="$1" MUSO_ADMIN_IDENTITY_DIR="$TEST_ROOT/identities" "${ident[@]}" \
        bash "$SCRIPT" --requester "$2" call "$4" "$5" \
        '{"requestIds":["11111111-1111-4111-8111-111111111111"],"status":"approved"}'
}

drain_header_count() {
    grep -cx "X-Credit-Automation-Id: verification-scale-drain" "$CURL_ARGV" || true
}

any_automation_header_count() {
    grep -c "^X-Credit-Automation-Id: " "$CURL_ARGV" || true
}

@test "the drain's approve carries its own X-Credit-Automation-Id on its own account" {
    drain_put 1 "scale-drain@hydra-ops" scale-drain PUT /admin/credit-requests
    [ "$status" -eq 0 ]
    [ "$(drain_header_count)" -eq 1 ]
    [ "$(any_automation_header_count)" -eq 1 ]
    grep -qx "Requester: scale-drain@hydra-ops" "$CURL_ARGV"
}

@test "the drain header needs its flag, its requester, its OWN account and the approve route" {
    drain_put 0 "scale-drain@hydra-ops" scale-drain PUT /admin/credit-requests
    [ "$(drain_header_count)" -eq 0 ]
    drain_put 1 "credit-trust-decide@hydra-ops" scale-drain PUT /admin/credit-requests
    [ "$(drain_header_count)" -eq 0 ]
    # Never under the shared login or another automation's account: no borrowed identity.
    drain_put 1 "scale-drain@hydra-ops" "" PUT /admin/credit-requests
    [ "$status" -eq 0 ]
    [ "$(any_automation_header_count)" -eq 0 ]
    drain_put 1 "scale-drain@hydra-ops" credit-decider PUT /admin/credit-requests
    [ "$status" -eq 0 ]
    [ "$(any_automation_header_count)" -eq 0 ]
    drain_put 1 "scale-drain@hydra-ops" scale-drain PUT /admin/credit-requests/conditional-status
    [ "$(drain_header_count)" -eq 0 ]
    drain_put 1 "scale-drain@hydra-ops" scale-drain GET /admin/credit-requests
    [ "$(drain_header_count)" -eq 0 ]
}
