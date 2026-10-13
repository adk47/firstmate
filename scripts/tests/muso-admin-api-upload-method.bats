#!/usr/bin/env bats

# Multipart upload method contract for both deployed muso-admin-api.sh copies.

bats_require_minimum_version 1.5.0

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WRAPPERS=(
        "$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
        "$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
    )

    export MUSO_API_URL="https://example.invalid"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"
    export OPS_DRY_RUN=0
    export CV_APPROVE_GATE_DISABLED=1
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/token-cache"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health.sh"
    export CURL_ARGS="$TEST_ROOT/curl.args"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    printf 'jpeg fixture\n' > "$TEST_ROOT/avatar.jpg"

    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS"
printf '{"ok":true}\n200'
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

recorded_method() {
    awk '$0 == "-X" { getline; print; exit }' "$CURL_ARGS"
}

@test "explicit PUT upload reaches curl as PUT in both wrappers" {
    local wrapper
    for wrapper in "${WRAPPERS[@]}"; do
        rm -f "$CURL_ARGS"
        run bash "$wrapper" upload PUT /admin/profile/profile-id/image "$TEST_ROOT/avatar.jpg"
        [ "$status" -eq 0 ]
        [ "$(recorded_method)" = "PUT" ]
    done
}

@test "legacy upload syntax remains POST in both wrappers" {
    local wrapper
    for wrapper in "${WRAPPERS[@]}"; do
        rm -f "$CURL_ARGS"
        run bash "$wrapper" upload /admin/files "$TEST_ROOT/avatar.jpg"
        [ "$status" -eq 0 ]
        [ "$(recorded_method)" = "POST" ]
    done
}

@test "dry-run audit records the explicit upload method" {
    local wrapper audit
    for wrapper in "${WRAPPERS[@]}"; do
        audit="$TEST_ROOT/$(basename "$(dirname "$(dirname "$wrapper")")").jsonl"
        rm -f "$audit" "$CURL_ARGS"
        run env OPS_DRY_RUN=1 OPS_DRY_RUN_AUDIT_PATH="$audit" \
            bash "$wrapper" upload PUT /admin/profile/profile-id/image "$TEST_ROOT/avatar.jpg"
        [ "$status" -eq 0 ]
        jq -e '.kind == "upload" and .method == "PUT"' "$audit" >/dev/null
        [ ! -e "$CURL_ARGS" ]
    done
}

@test "unsupported explicit upload method fails before curl" {
    local wrapper
    for wrapper in "${WRAPPERS[@]}"; do
        rm -f "$CURL_ARGS"
        run bash "$wrapper" upload DELETE /admin/profile/profile-id/image "$TEST_ROOT/avatar.jpg"
        [ "$status" -ne 0 ]
        [[ "$output" == *"Unsupported upload method: DELETE"* ]]
        [ ! -e "$CURL_ARGS" ]
    done
}

@test "image-upload playbooks select PUT explicitly" {
    grep -F 'upload PUT "/admin/profile/<profile_id>/image"' \
        "$REPO_ROOT/skills-all/muso-ops-profiles/SKILL.md"
    grep -F 'upload PUT "/admin/user/<user_id>/image"' \
        "$REPO_ROOT/skills-all/muso-ops-users/SKILL.md"
    grep -F 'upload PUT "/admin/team/<id>/image"' \
        "$REPO_ROOT/skills-all/muso-ops-workspaces/SKILL.md"
}
