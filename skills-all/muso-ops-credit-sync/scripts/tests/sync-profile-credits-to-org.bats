#!/usr/bin/env bats
# Tests for sync-profile-credits-to-org.sh against a mocked muso-admin-api.sh.
#
# Intent encoded here (not just behavior):
#  - the sync is ADDITIVE-ONLY: a DELETE reaching the admin API is a policy
#    violation (removal semantics were left undecided on the 2026-06-09 call)
#  - re-running a completed sync must be a no-op (idempotency is what makes
#    the recurring cron safe)
#  - unknown response shapes and missing profiles must fail LOUD, never be
#    read as "no credits to sync" (silent-empty is how credits would quietly
#    stop syncing after a backend contract change)

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../sync-profile-credits-to-org.sh"
    WORK="$(mktemp -d)"
    export FIXTURES="$WORK/fixtures"
    export CALL_LOG="$WORK/calls.log"
    mkdir -p "$FIXTURES"
    export ADMIN_API_SCRIPT="$WORK/mock-admin-api.sh"
    export SYNC_PAGE_LIMIT=2
    export SYNC_SLEEP_SECS=0
    export ALLOWED_ROLES_FILE="$WORK/allowed-org-roles.txt"
    printf 'Studio\n' > "$ALLOWED_ROLES_FILE"

    # Mock admin API: logs every call, serves fixture files keyed by
    # "<METHOD> <path>" (slashes/?&= mapped to _). Mirrors the real
    # muso-admin-api.sh contract: ALWAYS exits 0 and wraps the response in
    # {"http_status": N, "body": ...}; a fixture named FAIL yields a 500
    # envelope (the wrapper never signals API errors via exit code).
    cat > "$ADMIN_API_SCRIPT" <<'MOCK'
#!/usr/bin/env bash
# strip global flags the way the real wrapper accepts them
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --requester) shift 2 ;;
        call) shift; args+=("$@"); break ;;
        *) shift ;;
    esac
done
method="${args[0]}" path="${args[1]}"
echo "$method $path" >> "$CALL_LOG"
key="$(echo "$method $path" | tr '/?&=' '____')"
f="$FIXTURES/$key"
if [[ -f "$f.FAIL" ]]; then echo '{"http_status": 500, "body": {"error":"simulated failure"}}'; exit 0; fi
if [[ -f "$f.RAW" ]]; then cat "$f.RAW"; exit 0; fi
if [[ -f "$f" ]]; then printf '{"http_status": 200, "body": %s}' "$(cat "$f")"; exit 0; fi
if [[ "$method" == "POST" ]]; then echo '{"http_status": 200, "body": {"ok":true}}'; exit 0; fi
echo "mock: no fixture for: $method $path" >&2
exit 22
MOCK
    chmod +x "$ADMIN_API_SCRIPT"

    # default profiles
    profile_fixture P1 "Colin Leonard" 3
    profile_fixture ORG "Sing Mastering" 0
}

teardown() { rm -rf "$WORK"; }

# Map "<METHOD> <path>" to the mock's fixture filename — keep in lockstep
# with the tr set inside the mock above.
fixture_path() {
    echo "$FIXTURES/$(echo "$1" | tr '/?&=' '____')"
}

profile_fixture() {
    local id="$1" name="$2" count="$3"
    printf '{"id":"%s","name":"%s","creditCount":%s}' "$id" "$name" "$count" \
        > "$(fixture_path "GET /admin/profile/$id")"
}

# credits page fixture mirroring the live contract (verified 2026-06-10):
# {result, code, data:{items, limit, offset, total}}, items[].id = trackId,
# items[].credits = list of role strings. Pagination is `page` (1-based) —
# the live endpoint IGNORES `offset`.
# args = profile_id page json_items [total (defaults to item count)]
credits_fixture() {
    local id="$1" page="$2" items="$3" total="${4:-}"
    if [[ -z "$total" ]]; then
        total="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$items")"
    fi
    printf '{"result":"success","code":200,"data":{"items":%s,"limit":2,"offset":%s,"total":%s}}' \
        "$items" "$(( (page - 1) * 2 ))" "$total" \
        > "$(fixture_path "GET /admin/profile/$id/credits?limit=2&page=$page")"
}

@test "dry-run reports planned adds and issues zero writes" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering Engineer"]}]'
    credits_fixture ORG 1 '[]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"dry_run": true'
    echo "$output" | grep -q '"missing_on_org": 1'
    echo "$output" | grep -q '"trackId": "t1"'
    ! grep -q '^POST' "$CALL_LOG"
    ! grep -q '^DELETE' "$CALL_LOG"
}

@test "real run POSTs exactly the missing (track, role) pairs" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering Engineer"]},{"id":"t2","credits":["Producer"]}]'
    # org already has t1/Mastering Engineer -> only t2 must be added
    credits_fixture ORG 1 '[{"id":"t1","credits":["Mastering Engineer"]}]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"added": 1'
    grep -q '^POST /admin/track/t2/profile/ORG/credits' "$CALL_LOG"
    ! grep -q '^POST /admin/track/t1/' "$CALL_LOG"
}

@test "idempotent: in-sync profiles produce zero adds" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]}]'
    credits_fixture ORG 1 '[{"id":"t1","credits":["Producer"]}]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"added": 0'
    echo "$output" | grep -q '"missing_on_org": 0'
    ! grep -q '^POST' "$CALL_LOG"
}

@test "additive-only: org extras are reported, never DELETEd" {
    credits_fixture P1 1 '[]'
    credits_fixture ORG 1 '[{"id":"tX","credits":["Mixer"]}]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"org_only_extras": 1'
    ! grep -q '^DELETE' "$CALL_LOG"
    ! grep -q '^POST' "$CALL_LOG"
}

@test "pagination: a full page triggers the next offset" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]},{"id":"t2","credits":["Producer"]}]' 3
    credits_fixture P1 2 '[{"id":"t3","credits":["Producer"]}]' 3
    credits_fixture ORG 1 '[]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"missing_on_org": 3'
    grep -q 'page=2' "$CALL_LOG"
}

@test "fails loud when a profile GET fails (no silent empty sync)" {
    touch "$(fixture_path "GET /admin/profile/P1").FAIL"

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'failed to resolve profile'
    ! grep -q '^POST' "$CALL_LOG"
}

@test "fails loud on merged-away profile" {
    printf '{"id":"P1","name":"Colin","mergedTo":"OTHER"}' \
        > "$(fixture_path "GET /admin/profile/P1")"

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'merged into OTHER'
}

@test "fails loud on unrecognized credits response shape" {
    printf '{"weird":{"nested":1}}' \
        > "$(fixture_path "GET /admin/profile/P1/credits?limit=2&page=1")"

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'unrecognized response shape'
    ! grep -q '^POST' "$CALL_LOG"
}

@test "fails loud on credit items that are not role-string lists" {
    # dict-shaped credit entries are NOT the verified contract — must refuse,
    # not half-parse (strict-parser guarantee)
    credits_fixture P1 1 '[{"id":"t1","credits":[{"role":"Producer"}]}]'
    credits_fixture ORG 1 '[]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'not a non-empty list of role strings'
    ! grep -q '^POST' "$CALL_LOG"
}

@test "single-pair mode without --as-role fails loud" {
    run bash "$SCRIPT" --from P1 --to ORG
    [ "$status" -eq 1 ]
    echo "$output" | grep -q -- '--as-role is required'
}

@test "refuses to sync a profile onto itself" {
    run bash "$SCRIPT" --from P1 --to P1 --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'same profile'
}

@test "failed POST is counted, run continues, exit code 2" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]},{"id":"t2","credits":["Producer"]}]'
    credits_fixture ORG 1 '[]'
    touch "$(fixture_path "POST /admin/track/t1/profile/ORG/credits").FAIL"

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"added": 1'
    echo "$output" | grep -q '"failed": 1'
    echo "$output" | grep -q 't1:Producer'
}

@test "pairs-file mode syncs each listed pair and skips comments" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]}]'
    credits_fixture ORG 1 '[]'
    cat > "$WORK/pairs.txt" <<EOF
# person org role label
P1 ORG verbatim Colin -> Sing Mastering
EOF

    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"label": "Colin -> Sing Mastering"'
    echo "$output" | grep -q '"missing_on_org": 1'
}

@test "empty pairs file fails loud" {
    printf '# nothing here\n' > "$WORK/pairs.txt"
    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'no sync pairs'
}

@test "as-role maps every credit to one org role and dedupes multi-role tracks" {
    # t1 has TWO roles on the person -> exactly ONE Studio credit expected
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering","Engineer"]}]'
    credits_fixture ORG 1 '[]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role Studio
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"as_role": "Studio"'
    echo "$output" | grep -q '"added": 1'
    [ "$(grep -c '^POST /admin/track/t1/profile/ORG/credits' "$CALL_LOG")" -eq 1 ]
}

@test "as-role is idempotent and reports wrong-role org credits as extras (no DELETE)" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering"]}]'
    # org already has the Studio credit plus a stray verbatim Mastering credit
    credits_fixture ORG 1 '[{"id":"t1","credits":["Studio","Mastering"]}]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role Studio
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"added": 0'
    echo "$output" | grep -q '"org_only_extras": 1'
    ! grep -q '^POST' "$CALL_LOG"
    ! grep -q '^DELETE' "$CALL_LOG"
}

@test "pairs file without role column fails loud" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering"]}]'
    credits_fixture ORG 1 '[]'
    printf 'P1 ORG\n' > "$WORK/pairs.txt"

    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'missing the role column'
}

@test "as-role is rejected together with pairs-file" {
    printf 'P1 ORG Studio x\n' > "$WORK/pairs.txt"
    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt" --as-role Studio
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'mutually exclusive'
}

@test "truncated credits list (empty page before total) fails loud" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]},{"id":"t2","credits":["Producer"]}]' 5
    credits_fixture P1 2 '[]' 5
    credits_fixture ORG 1 '[]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'truncated'
    ! grep -q '^POST' "$CALL_LOG"
}

@test "negative data.total is rejected as a shape violation" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]}]' -1
    credits_fixture ORG 1 '[]'

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'unrecognized response shape'
}

@test "pairs-file role outside the allowlist is refused (mis-parsed label guard)" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering"]}]'
    credits_fixture ORG 1 '[]'
    # the classic mistake: role column forgotten, label first word becomes role
    printf 'P1 ORG Colin Leonard -> SING Mastering\n' > "$WORK/pairs.txt"

    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "not in"
    ! grep -q '^POST' "$CALL_LOG"
}

@test "pairs-file allowlisted role runs; allowlist missing fails loud" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Mastering"]}]'
    credits_fixture ORG 1 '[]'
    printf 'P1 ORG Studio Colin -> SING\n' > "$WORK/pairs.txt"

    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"as_role": "Studio"'

    rm "$ALLOWED_ROLES_FILE"
    run bash "$SCRIPT" --pairs-file "$WORK/pairs.txt" --dry-run
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'allowed-org-roles file missing'
}

@test "2xx envelope without a JSON body is not treated as success" {
    credits_fixture P1 1 '[{"id":"t1","credits":["Producer"]}]'
    credits_fixture ORG 1 '[]'
    printf '{"http_status": 200, "raw": "<html>proxy page</html>"}' \
        > "$(fixture_path "POST /admin/track/t1/profile/ORG/credits").RAW"

    run bash "$SCRIPT" --from P1 --to ORG --as-role verbatim
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"failed": 1'
}
