#!/usr/bin/env bats

# Incident 2026-10-19 05:38-05:50Z (firstmate 066-069): an ad-hoc script paged
# GET /admin/credit-requests?status=approved&limit=500&page=1..800 through this wrapper as
# the shared operations identity and slowed the whole site. Both deployed copies refuse
# unfiltered big or deep credit-request list pulls, allow filtered and normal reads, and
# pace list calls per identity.

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
    export CURL_LOG="$TEST_ROOT/curl.log"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    unset MUSO_ADMIN_IDENTITY
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '{"ok":true}\n200'
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() { rm -rf "$TEST_ROOT"; }

calls() { [ -f "$CURL_LOG" ] && wc -l < "$CURL_LOG" | tr -d ' ' || echo 0; }

@test "unfiltered credit-request lists above 200 rows are refused before any request" {
    local w
    for w in "${WRAPPERS[@]}"; do
        rm -f "$CURL_LOG"
        run bash "$w" call GET "/admin/credit-requests?status=approved&limit=500&page=1"
        [ "$status" -eq 2 ]
        [[ "$output" == *"limit=500 and no profilesIds/trackId"* ]]
        run bash "$w" call GET "/admin/credit-requests/profiles?limit=1000"
        [ "$status" -eq 2 ]
        [ "$(calls)" -eq 0 ]
    done
}

@test "deep unfiltered paging is refused; filtered and normal reads pass" {
    local w
    for w in "${WRAPPERS[@]}"; do
        rm -f "$CURL_LOG"
        run bash "$w" call GET "/admin/credit-requests?status=approved&limit=200&page=102"
        [ "$status" -eq 2 ]
        [[ "$output" == *"deep unfiltered paging"* ]]
        run bash "$w" call GET "/admin/credit-requests?status=unverified&limit=200&page=40"
        [ "$status" -eq 0 ]
        run bash "$w" call GET "/admin/credit-requests?status=approved&limit=500&page=3&profilesIds=11111111-2222-3333-4444-555555555555"
        [ "$status" -eq 0 ]
        run bash "$w" call GET "/admin/credit-requests?status=approved&limit=500&trackId=t1&page=900"
        [ "$status" -eq 0 ]
        run bash "$w" call GET "/admin/profile/p1"
        [ "$status" -eq 0 ]
        [ "$(calls)" -eq 4 ]
    done
}

@test "list calls are paced to at most 2 per second per identity" {
    local w="${WRAPPERS[1]}" i start end
    start="$(date +%s)"
    for i in 1 2 3 4 5; do
        run bash "$w" call GET "/admin/credit-requests?status=unverified&limit=10&page=$i"
        [ "$status" -eq 0 ]
    done
    end="$(date +%s)"
    # 5 calls at <= 2/s span at least 2 whole seconds.
    [ $(( end - start )) -ge 2 ]
    [ -f "$MUSO_OPS_STATE_DIR/admin-list-pace.default" ]
}

# QA + Fable NO-GO on hydra#1270 r1: the raw query was read, so these slipped past.
@test "encoded, leading-zero, junk-suffixed, case and slash variants are read like core reads them" {
    local w p
    for w in "${WRAPPERS[@]}"; do
        rm -f "$CURL_LOG"
        for p in \
            "/admin/credit-requests?status=approved&limit=%35%30%30" \
            "/admin/credit-requests?status=approved&%6C%69%6D%69%74=500" \
            "/admin/credit-requests?status=approved&limit=0500" \
            "/admin/credit-requests?status=approved&limit=500abc" \
            "/admin/credit-requests?status=approved&limit=+500" \
            "/admin/credit-requests?status=approved&limit=%20500" \
            "/Admin/Credit-Requests?status=approved&limit=500" \
            "//admin//credit-requests/?status=approved&limit=500" \
            "/admin/credit%2Drequests?status=approved&limit=500" \
            "/admin/credit-requests?status=approved&limit=200&page=0102" \
            "/admin/credit-requests?status=approved&profilesIds=&limit=500" \
            "/admin/credit-requests?status=approved&profilesIds=%20&limit=500" ; do
            run bash "$w" call GET "$p"
            [ "$status" -eq 2 ] || { echo "not refused: $p"; false; }
        done
        [ "$(calls)" -eq 0 ]
    done
}

@test "duplicated or bracketed limit/page/profilesIds/trackId params are refused as ambiguous" {
    local w p
    for w in "${WRAPPERS[@]}"; do
        rm -f "$CURL_LOG"
        for p in \
            "/admin/credit-requests?status=approved&limit=10&limit=500" \
            "/admin/credit-requests?status=approved&limit[]=500" \
            "/admin/credit-requests?status=approved&limit%5B0%5D=500" \
            "/admin/credit-requests?status=approved&page=1&page=900" \
            "/admin/credit-requests?status=approved&limit=500&profilesIds=a&profilesIds=b" \
            "/admin/credit-requests?status=approved&limit=500&trackId[x]=t1" ; do
            run bash "$w" call GET "$p"
            [ "$status" -eq 2 ] || { echo "not refused: $p"; false; }
            [[ "$output" == *"ambiguous"* ]]
        done
        [ "$(calls)" -eq 0 ]
    done
}

@test "pacing fails CLOSED when its state dir or state file cannot be written or read" {
    local w="${WRAPPERS[0]}"
    # state dir is a file -> cannot create
    printf x > "$TEST_ROOT/notadir"
    MUSO_OPS_STATE_DIR="$TEST_ROOT/notadir" run bash "$w" call GET "/admin/credit-requests?status=unverified&limit=10"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pacing state dir"* ]]
    # corrupt state file
    mkdir -p "$MUSO_OPS_STATE_DIR"
    printf 'garbage here\n' > "$MUSO_OPS_STATE_DIR/admin-list-pace.default"
    run bash "$w" call GET "/admin/credit-requests?status=unverified&limit=10"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unreadable or corrupt"* ]]
    rm -f "$MUSO_OPS_STATE_DIR/admin-list-pace.default"
    # state file not writable (directory in its place)
    mkdir -p "$MUSO_OPS_STATE_DIR/admin-list-pace.default.tmp"
    run bash "$w" call GET "/admin/credit-requests?status=unverified&limit=10"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot be written"* ]]
    [ "$(calls)" -eq 0 ]
    # a non-list read is never paced or refused
    run bash "$w" call GET "/admin/profile/p1"
    [ "$status" -eq 0 ]
}

@test "a busy (fresh) pacing lock refuses instead of proceeding unpaced" {
    local w="${WRAPPERS[1]}"
    mkdir -p "$MUSO_OPS_STATE_DIR/admin-list-pace.default.lockdir"
    ADMIN_LIST_LOCK_TRIES=2 run bash "$w" call GET "/admin/credit-requests?status=unverified&limit=10"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pacing lock"*"busy"* ]]
    [ "$(calls)" -eq 0 ]
}

# QA r2: /admin/credit-requests/profiles ignores profilesIds/trackId (core listProfiles.js
# always runs the unfiltered grouped query), so a filter param must not unlock it.
@test "/profiles is bounded even when profilesIds or trackId are supplied" {
    local w p
    for w in "${WRAPPERS[@]}"; do
        rm -f "$CURL_LOG"
        for p in \
            "/admin/credit-requests/profiles?limit=500&page=800&trackId=x" \
            "/admin/credit-requests/profiles?limit=500&profilesIds=11111111-2222-3333-4444-555555555555" \
            "/admin/credit-requests/profiles?limit=200&page=102&profilesIds=a" ; do
            run bash "$w" call GET "$p"
            [ "$status" -eq 2 ] || { echo "not refused: $p"; false; }
        done
        run bash "$w" call GET "/admin/credit-requests/profiles?limit=50&page=2"
        [ "$status" -eq 0 ]
        [ "$(calls)" -eq 1 ]
    done
}

@test "HEAD is bounded and paced like GET (core serves HEAD through the GET list handler)" {
    local w
    for w in "${WRAPPERS[@]}"; do
        rm -f "$CURL_LOG"
        run bash "$w" call HEAD "/admin/credit-requests?status=approved&limit=500&page=800"
        [ "$status" -eq 2 ]
        [[ "$output" == *"refusing HEAD"* ]]
        run bash "$w" call head "/admin/credit-requests?status=approved&limit=200&page=102"
        [ "$status" -eq 2 ]
        [[ "$output" == *"deep unfiltered paging"* ]]
        run bash "$w" call HEAD "/admin/credit-requests/profiles?limit=1000"
        [ "$status" -eq 2 ]
        [ "$(calls)" -eq 0 ]
        run bash "$w" call HEAD "/admin/credit-requests?status=unverified&limit=200&page=40"
        [ "$status" -eq 0 ]
        [ "$(calls)" -eq 1 ]
    done
}
