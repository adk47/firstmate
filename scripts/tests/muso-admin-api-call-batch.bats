#!/usr/bin/env bats

# The scale drain's hoist (data/verification-scale-plan.md, change 1). The measured
# ceiling was three round trips per user at 1.4 minutes per user end to end, which caps
# even perfect batching near 1,000/day. `call-batch` is ONE process, ONE token resolve,
# N requests, with the same gate chain every single `call` runs.
#
# What this pins:
#   * ONE token resolve for the whole batch (a stale cache logs in exactly once, not N).
#   * one output line per input line, in input order, carrying the id back.
#   * a per-item failure is reported on its own line and never aborts the batch.
#   * reads run in a bounded pool; WRITES are serialised (the destructive counters and
#     the pace gate are shared state, so a concurrent write batch would race them).
#   * the gate chain still runs: a batch is not a way around a gate.

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
    mkdir -p "$TEST_ROOT/bin" "$MUSO_OPS_STATE_DIR"
    # A STALE cache: every get_token that is not memoised would log in again, so the
    # login count is exactly the number of token resolves the batch performed.
    printf '%s\ndummy-token\n' "$(( $(date +%s) - 999999 ))" > "$ADMIN_TOKEN_CACHE_PATH"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
    # login is called WITHOUT -w, so it must emit the body only
    *"/admin/user/login"*) printf '{"data":{"authentication":{"accessToken":"fresh-token"}}}' ;;
    *"/admin/boom"*)       printf '{"error":"nope"}\n500' ;;
    *)                     printf '{"data":{"ok":true}}\n200' ;;
esac
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

login_count() {
    grep -c '/admin/user/login' "$CURL_LOG" 2>/dev/null || true
}

@test "call-batch resolves the token ONCE for the whole batch" {
    for w in "${WRAPPERS[@]}"; do
        : > "$CURL_LOG"
        # reset the STALE cache each round: the first wrapper's run refreshes it, and a
        # fresh cache would make the second round's zero logins look like a pass
        printf '%s\ndummy-token\n' "$(( $(date +%s) - 999999 ))" > "$ADMIN_TOKEN_CACHE_PATH"
        printf '%s\n' \
            '{"id":"a","method":"GET","path":"/admin/one"}' \
            '{"id":"b","method":"GET","path":"/admin/two"}' \
            '{"id":"c","method":"GET","path":"/admin/three"}' \
            '{"id":"d","method":"GET","path":"/admin/four"}' \
            | bash "$w" --requester credit-review@hydra-ops call-batch --pool 4 > "$TEST_ROOT/out.jsonl"
        [ "$(login_count)" -eq 1 ]
        [ "$(wc -l < "$TEST_ROOT/out.jsonl")" -eq 4 ]
    done
}

@test "call-batch returns one line per input, in input order, carrying the id" {
    for w in "${WRAPPERS[@]}"; do
        printf '%s\n' \
            '{"id":"first","method":"GET","path":"/admin/one"}' \
            '{"id":"second","method":"GET","path":"/admin/two"}' \
            '{"id":"third","method":"GET","path":"/admin/three"}' \
            | bash "$w" --requester credit-review@hydra-ops call-batch --pool 3 > "$TEST_ROOT/out.jsonl"
        run python3 - "$TEST_ROOT/out.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert [r["id"] for r in rows] == ["first", "second", "third"], rows
assert all(r["http_status"] == 200 for r in rows), rows
assert all(r["body"] == {"data": {"ok": True}} for r in rows), rows
PY
        [ "$status" -eq 0 ]
    done
}

@test "call-batch reports a per-item failure on its own line and never aborts the batch" {
    for w in "${WRAPPERS[@]}"; do
        printf '%s\n' \
            '{"id":"ok1","method":"GET","path":"/admin/one"}' \
            '{"id":"bad","method":"GET","path":"/admin/boom"}' \
            '{"id":"ok2","method":"GET","path":"/admin/two"}' \
            | bash "$w" --requester credit-review@hydra-ops call-batch --pool 3 > "$TEST_ROOT/out.jsonl"
        run python3 - "$TEST_ROOT/out.jsonl" <<'PY'
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert set(rows) == {"ok1", "bad", "ok2"}, rows
assert rows["ok1"]["http_status"] == 200
assert rows["ok2"]["http_status"] == 200
assert rows["bad"]["http_status"] == 500
PY
        [ "$status" -eq 0 ]
    done
}

@test "call-batch serialises writes and parallelises reads" {
    # A write batch must not race the shared destructive counters / pace gate. The
    # observable proof: every write item is dispatched after every read item, and the
    # writes are dispatched one at a time. We assert the ordering property that is
    # checkable from the curl log: all reads appear before all writes.
    for w in "${WRAPPERS[@]}"; do
        : > "$CURL_LOG"
        printf '%s\n' \
            '{"id":"w1","method":"POST","path":"/admin/write-one","body":"{}"}' \
            '{"id":"r1","method":"GET","path":"/admin/read-one"}' \
            '{"id":"w2","method":"POST","path":"/admin/write-two","body":"{}"}' \
            '{"id":"r2","method":"GET","path":"/admin/read-two"}' \
            | bash "$w" --requester credit-review@hydra-ops call-batch --pool 4 > "$TEST_ROOT/out.jsonl"
        run python3 - "$CURL_LOG" <<'PY'
import sys
lines = [l for l in open(sys.argv[1]) if l.strip()]
reads = [i for i, l in enumerate(lines) if "/admin/read-" in l]
writes = [i for i, l in enumerate(lines) if "/admin/write-" in l]
assert len(reads) == 2 and len(writes) == 2, lines
assert max(reads) < min(writes), (reads, writes)
PY
        [ "$status" -eq 0 ]
    done
}

@test "call-batch refuses a non-positive pool" {
    for w in "${WRAPPERS[@]}"; do
        run bash -c "printf '%s\n' '{\"id\":\"a\",\"method\":\"GET\",\"path\":\"/admin/one\"}' | bash '$w' call-batch --pool 0"
        [ "$status" -ne 0 ]
        [[ "$output" == *"positive integer"* ]]
    done
}

@test "call-batch still runs the gate chain (a batch is not a way around a gate)" {
    # The credit-approve gate refuses an approve with no evidence excerpt. A batch item
    # that would be refused by `call` must be refused by `call-batch` too.
    for w in "${WRAPPERS[@]}"; do
        unset CV_APPROVE_GATE_DISABLED
        run bash -c "printf '%s\n' '{\"id\":\"a\",\"method\":\"POST\",\"path\":\"/admin/credit-requests/abc/approve\",\"body\":\"{}\"}' | bash '$w' --requester credit-review@hydra-ops call-batch --pool 1"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"rc":1'* || "$output" == *'"rc": 1'* || "$output" == *'error'* ]]
        export CV_APPROVE_GATE_DISABLED=1
    done
}
