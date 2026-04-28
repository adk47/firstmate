#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for fetch-queue.sh — the canonical B1 fetcher.
#
# Root-cause context: 2026-04-27 10:06 UTC dry-run posted a green
# "Queue clear" summary while the live API had 13891 unverified credits
# in the queue. The agent's improvised B1 bash used `.body.items` /
# `.body.count` jq paths that silently fell through to `[]` / `0`
# because the real envelope nests one level deeper (`.body.data.items` /
# `.body.data[0].count`). This script locks those paths and fails loud
# on every drift; these tests pin the contract.

setup() {
    setup_tmp_env
    SCRIPT="$SCRIPTS_DIR/fetch-queue.sh"
    [[ -x "$SCRIPT" ]] || { echo "fetch-queue.sh missing or not executable: $SCRIPT" >&2; return 1; }

    # Stub muso-admin-api.sh. Behavior is selected per test by exporting
    # STUB_LIST_MODE / STUB_COUNTS_MODE before invoking the script.
    # Records each invocation's args to $ADMIN_LOG so we can assert
    # things like "list got called with limit=25".
    ADMIN_LOG="$TEST_TMPDIR/admin-invocations.log"
    export ADMIN_LOG

    ADMIN_API_SH="$TEST_TMPDIR/fake-muso-admin-api.sh"
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
# Stub. Two endpoints, two modes per endpoint, selected via env:
#   STUB_LIST_MODE   = real_with_items | real_empty | shape_drift_legacy | http_500
#   STUB_COUNTS_MODE = real_nonzero | real_zero | shape_drift | http_500
# STUB_COUNT_VALUE selects the count for real_nonzero (default 13891).
{
    printf 'ARGS:'
    for a in "$@"; do printf '\n  %s' "$a"; done
    printf '\n'
} >> "${ADMIN_LOG:-/dev/null}"

# Last positional arg is the path. `call GET <path>` → $3.
url="${3:-}"

if [[ "$url" == *"/admin/credit-requests/counts"* ]]; then
    case "${STUB_COUNTS_MODE:-real_nonzero}" in
        real_nonzero)
            count="${STUB_COUNT_VALUE:-13891}"
            printf '%s\n' "{\"http_status\":200,\"body\":{\"result\":\"ok\",\"code\":200,\"data\":[{\"status\":\"unverified\",\"count\":$count}]}}"
            ;;
        real_zero)
            printf '%s\n' '{"http_status":200,"body":{"result":"ok","code":200,"data":[{"status":"unverified","count":0}]}}'
            ;;
        shape_drift)
            # Old/wrong shape — no body.data wrap.
            printf '%s\n' '{"http_status":200,"body":{"result":"ok","code":200,"count":42}}'
            ;;
        http_500)
            printf '%s\n' '{"http_status":500,"body":{"error":"counts boom"}}'
            ;;
        *)
            echo "stub: unknown STUB_COUNTS_MODE=${STUB_COUNTS_MODE}" >&2; exit 99 ;;
    esac
    exit 0
fi

if [[ "$url" == *"/admin/credit-requests"* ]]; then
    case "${STUB_LIST_MODE:-real_with_items}" in
        real_with_items)
            # Real envelope: body.data.items[]. Default shape is minimal —
            # the script only counts items, not validates them.
            #
            # STUB_LIST_REALISTIC=1 pads each item to ~300 bytes (mirroring
            # the production hashKey/targetUrl fields). This is what makes
            # the ARG_MAX regression test exercise the actual bug: at 500
            # × ~300 bytes = ~150KB, a reverted `--argjson items "$ITEMS"`
            # would now overflow Linux MAX_ARG_STRLEN (~128KB).
            n="${STUB_LIST_COUNT:-5}"
            if [[ "${STUB_LIST_REALISTIC:-0}" == "1" ]]; then
                # 64-char hash + ~140-char URL ≈ 300 bytes serialized per item.
                hash="0000000000000000000000000000000000000000000000000000000000000000"
                url_pad="https://api.muso.ai/admin/credit-requests/decoy?param=value&padding=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                ids=$(seq 1 "$n" | awk -v h="$hash" -v u="$url_pad" -v N="$n" '{printf "{\"id\":\"cr_%d\",\"profileId\":\"p_%d\",\"userId\":1,\"hashKey\":\"%s\",\"targetUrl\":\"%s\"}%s", $1, $1, h, u, (NR<N?",":"")}')
            else
                ids=$(seq 1 "$n" | awk -v N="$n" '{printf "{\"id\":\"cr_%d\",\"profileId\":\"p_%d\",\"userId\":1}%s", $1, $1, (NR<N?",":"")}')
            fi
            printf '%s\n' "{\"http_status\":200,\"body\":{\"result\":\"ok\",\"code\":200,\"data\":{\"items\":[$ids]}}}"
            ;;
        real_empty)
            printf '%s\n' '{"http_status":200,"body":{"result":"ok","code":200,"data":{"items":[]}}}'
            ;;
        shape_drift_legacy)
            # The shape the agent's improvised jq paths assumed:
            # body.items at top level, no body.data wrap.
            printf '%s\n' '{"http_status":200,"body":{"result":"ok","items":[{"id":"cr_1","profileId":"p_1"}]}}'
            ;;
        http_500)
            printf '%s\n' '{"http_status":500,"body":{"error":"list boom"}}'
            ;;
        *)
            echo "stub: unknown STUB_LIST_MODE=${STUB_LIST_MODE}" >&2; exit 99 ;;
    esac
    exit 0
fi

echo "stub: unrecognized URL: $url" >&2
exit 98
STUB
    chmod +x "$ADMIN_API_SH"
    export ADMIN_API_SH
}

teardown() { teardown_tmp_env; }

# --- Happy path --------------------------------------------------------

@test "happy path: real envelope, items present → exit 0 with normalized JSON" {
    STUB_LIST_MODE=real_with_items STUB_LIST_COUNT=5 \
    STUB_COUNTS_MODE=real_nonzero  STUB_COUNT_VALUE=5 \
        run bash "$SCRIPT" 5
    [ "$status" -eq 0 ]
    # stdout is one JSON line
    echo "$output" | jq -e '.queue_depth == 5 and (.items | length == 5) and .fetch_size == 5' >/dev/null
}

@test "ARG_MAX REGRESSION: 500-item batch does not overflow jq arg list" {
    # 2026-04-27 16:31 UTC real run: ITEMS at 500 items overflowed jq's
    # `--argjson items "$ITEMS"` arg list with "Argument list too long".
    # Agent fell back to improvised B1, dropped the run_started_queue
    # event, and posted a misleading run_finished. Envelope assembly now
    # uses printf to bypass argv. Pin the size that broke prod into CI.
    #
    # STUB_LIST_REALISTIC=1 pads items to production shape (~300 B/item):
    # 500 × ~300 = ~150 KB serialized. A reverted `--argjson items "$ITEMS"`
    # would exceed Linux MAX_ARG_STRLEN (~128 KB) and trip "Argument list
    # too long" — closing the gap noted in the original PR review (small
    # fixtures wouldn't have caught a regression to argv).
    STUB_LIST_MODE=real_with_items STUB_LIST_COUNT=500 STUB_LIST_REALISTIC=1 \
    STUB_COUNTS_MODE=real_nonzero  STUB_COUNT_VALUE=500 \
        run bash "$SCRIPT" 500
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.queue_depth == 500 and (.items | length == 500) and .fetch_size == 500' >/dev/null
    # Last item must round-trip intact (catches printf-format quoting bugs)
    echo "$output" | jq -e '.items[-1].id == "cr_500"' >/dev/null
    # Pin the realistic shape so a future stub edit can't silently shrink it.
    echo "$output" | jq -e '.items[-1].hashKey | length == 64' >/dev/null
}

@test "happy path with default fetch_size from env" {
    OPS_BATCH_FETCH_SIZE=10 \
    STUB_LIST_MODE=real_with_items STUB_LIST_COUNT=10 \
    STUB_COUNTS_MODE=real_nonzero  STUB_COUNT_VALUE=200 \
        run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.fetch_size == 10 and .queue_depth == 200 and (.items | length == 10)' >/dev/null
}

# --- Genuinely empty queue --------------------------------------------

@test "genuinely empty queue: items==[] AND count==0 → exit 0" {
    STUB_LIST_MODE=real_empty \
    STUB_COUNTS_MODE=real_zero \
        run bash "$SCRIPT" 500
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.queue_depth == 0 and (.items | length == 0) and .fetch_size == 500' >/dev/null
}

# --- The bug we're fixing: silent-zero --------------------------------

@test "silent-zero: count>0 but items==[] → exit 11, no stdout JSON" {
    STUB_LIST_MODE=real_empty \
    STUB_COUNTS_MODE=real_nonzero STUB_COUNT_VALUE=13891 \
        run bash "$SCRIPT" 500
    [ "$status" -eq 11 ]
    [[ "$stderr$output" == *"unverified_count_items_mismatch"* ]]
    [[ "$stderr$output" == *"count=13891"* ]]
    [[ "$stderr$output" == *"items=0"* ]]
}

# --- Envelope shape drift --------------------------------------------

@test "list shape drift (legacy body.items, no data wrap) → exit 5" {
    STUB_LIST_MODE=shape_drift_legacy \
    STUB_COUNTS_MODE=real_nonzero \
        run bash "$SCRIPT" 5
    [ "$status" -eq 5 ]
    [[ "$stderr$output" == *"envelope_shape_drift"* ]]
    [[ "$stderr$output" == *".body.data.items"* ]]
}

@test "counts shape drift (no body.data wrap) → exit 6" {
    STUB_LIST_MODE=real_with_items \
    STUB_COUNTS_MODE=shape_drift \
        run bash "$SCRIPT" 5
    [ "$status" -eq 6 ]
    [[ "$stderr$output" == *"envelope_shape_drift"* ]]
    [[ "$stderr$output" == *".body.data[0].count"* ]]
}

# --- HTTP errors ------------------------------------------------------

@test "list HTTP 500 → exit 3" {
    STUB_LIST_MODE=http_500 \
    STUB_COUNTS_MODE=real_nonzero \
        run bash "$SCRIPT" 5
    [ "$status" -eq 3 ]
    [[ "$stderr$output" == *"list endpoint HTTP 500"* ]]
}

@test "counts HTTP 500 → exit 4" {
    STUB_LIST_MODE=real_with_items \
    STUB_COUNTS_MODE=http_500 \
        run bash "$SCRIPT" 5
    [ "$status" -eq 4 ]
    [[ "$stderr$output" == *"counts endpoint HTTP 500"* ]]
}

# --- Wrapper missing -------------------------------------------------

@test "wrapper missing → exit 2" {
    ADMIN_API_SH=/nonexistent/path-to-muso-admin-api.sh \
        run --separate-stderr bash "$SCRIPT" 5
    [ "$status" -eq 2 ]
    # Message lands on stderr (not stdout): downstream cron parses stdout JSON
    # and would silently mis-parse a "wrapper not found" string as success.
    [[ "$stderr" == *"admin-API wrapper not found"* ]]
    [ -z "$output" ]
}

@test "wrapper path is a directory → exit 2" {
    # Pins the `! -f` half of the readability guard. A path that is
    # readable but not a regular file (directory, broken symlink) would
    # pass `[[ -r ]]` alone — but `bash <dir>` fails with a confusing
    # error. This case is deterministic across UIDs (chmod-based tests
    # are bypassed by root, which is what most CI runners use).
    ADMIN_API_SH="$TEST_TMPDIR" \
        run --separate-stderr bash "$SCRIPT" 5
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"admin-API wrapper not found or not readable"* ]]
    [ -z "$output" ]
}

@test "non-numeric fetch_size → exit 2" {
    run --separate-stderr bash "$SCRIPT" "abc"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"fetch_size must be a positive integer"* ]]
    [ -z "$output" ]
}

@test "fetch_size=0 → exit 2 (zero is not positive)" {
    run --separate-stderr bash "$SCRIPT" "0"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"fetch_size must be a positive integer"* ]]
    [ -z "$output" ]
}

# --- fetch_size respected --------------------------------------------

@test "fetch_size is forwarded to the list URL as limit=" {
    STUB_LIST_MODE=real_with_items STUB_LIST_COUNT=25 \
    STUB_COUNTS_MODE=real_nonzero  STUB_COUNT_VALUE=999 \
        run bash "$SCRIPT" 25
    [ "$status" -eq 0 ]
    # Anchor: don't accidentally match limit=250, limit=2500, etc.
    grep -qE 'limit=25($|[^0-9])' "$ADMIN_LOG"
}
