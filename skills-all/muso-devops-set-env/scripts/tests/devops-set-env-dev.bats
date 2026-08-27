#!/usr/bin/env bats
# Tests for the DEV branch of devops-set-env.sh (--env dev). DEV is intentionally
# broad (Nick's directive 2026-07-17): a dev-authorized requester may set ANY dev
# env var — secret-shaped included — with NO green-light, but the secret VALUE is
# still redacted in the audit and the set is logged + rate-capped + rollback-hinted.
#
# These tests also PIN the prod path (regression): the looser dev rules must NEVER
# leak to prod, and --env defaults to prod (fail-safe). Backend is the `stub`.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../devops-set-env.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # --- prod fixtures (narrow — mirrors the prod test suite) ---
    export PROTECTED_KEYS_PATH="$TEST_ROOT/protected.txt"
    export TARGET_ALLOWLIST_PATH="$TEST_ROOT/targets.txt"
    export ENVSET_REQUESTERS_PATH="$TEST_ROOT/requesters.txt"
    export BLOCKLIST_OVERRIDE_APPROVERS_PATH="$TEST_ROOT/override-approvers.txt"
    printf '%s\n' '*SECRET*' '*PASSWORD*' '*TOKEN*' '*_KEY' 'DB_*' '*_URL' > "$PROTECTED_KEYS_PATH"
    printf '%s\n' 'core-backend' 'industry-data-processing' > "$TARGET_ALLOWLIST_PATH"
    printf '%s\n' 'aaron@muso.ai' 'nick' > "$ENVSET_REQUESTERS_PATH"
    printf '%s\n' 'nick' 'nick@muso.ai' > "$BLOCKLIST_OVERRIDE_APPROVERS_PATH"

    # --- dev fixtures (broad — the DEV authorities; permissive muso-dev glob) ---
    # Deliberately does NOT contain U0ACHTYUULT (Artem D, ex-DevOps Lead, departed
    # 2026-07-30) — the fixture mirrors the shipped allowlist so a revoked person
    # cannot pass here and silently look authorized.
    export DEV_ENVSET_REQUESTERS_PATH="$TEST_ROOT/dev-requesters.txt"
    export DEV_TARGET_ALLOWLIST_PATH="$TEST_ROOT/dev-targets.txt"
    printf '%s\n' 'nick' 'nick@muso.ai' 'aaron@muso.ai' 'serhii@muso.ai' 'U03TYGJF1N3' \
        'U02N2NP3H7F' 'artem@muso.ai' \
        > "$DEV_ENVSET_REQUESTERS_PATH"
    printf '%s\n' 'muso-dev/*' 'muso-chat-dev/*' > "$DEV_TARGET_ALLOWLIST_PATH"

    # State + audit + backend → all under tmp.
    export DEVOPS_ENVSET_STATE_DIR="$TEST_ROOT/state"
    export RATE_PATH="$TEST_ROOT/state/rate.jsonl"
    export AUDIT_PATH="$TEST_ROOT/state/audit.jsonl"
    export DEVOPS_ENVSET_BACKEND="stub"
    export DEVOPS_ENVSET_STUB_STORE="$TEST_ROOT/store.env"

    DEV_TARGET="muso-dev/core-backend-config"
    SECRET_KEY="TUWUNEL_REGISTRATION_TOKEN"
}

teardown() { rm -rf "$TEST_ROOT"; }

dev_set() { # dev_set <requester> <set-args...>
    bash "$SCRIPT" --requester "$1" --env dev set "${@:2}"
}

# --- DEV self-serve: secrets, no green-light ---

@test "dev: Serhii sets a secret-shaped key with NO green-light (exit 0)" {
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value abc123 --reason "tuwunel bootstrap"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✅ set ${SECRET_KEY}"* ]]
    [[ "$output" == *"env=dev"* ]]
    # The secret DID reach the backend (stub) even without a green-light.
    grep -q "^${SECRET_KEY}=abc123\$" "$DEVOPS_ENVSET_STUB_STORE"
}

# Artem D (Dolobanko, U0ACHTYUULT) was a DEV authority until he left the company
# on 2026-07-30. Revocation has to be enforced, not just documented: a departed
# person's UID reaching a dev-secret write is the whole risk.
@test "dev: departed Artem D (U0ACHTYUULT) is REFUSED (exit 3)" {
    run dev_set U0ACHTYUULT --target "$DEV_TARGET" --key "$SECRET_KEY" --value xyz
    [ "$status" -eq 3 ]
    [[ "$output" == *"DEVOPS_ENVSET_REQUESTER_DENIED"* ]]
    # And nothing reached the backend.
    [ ! -f "$DEVOPS_ENVSET_STUB_STORE" ] || ! grep -q "^${SECRET_KEY}=xyz\$" "$DEVOPS_ENVSET_STUB_STORE"
}

@test "dev: Artem (U02N2NP3H7F) is authorized and audits as artem@muso.ai" {
    run dev_set U02N2NP3H7F --target "$DEV_TARGET" --key "$SECRET_KEY" --value mval
    [ "$status" -eq 0 ]
    grep -q "^${SECRET_KEY}=mval\$" "$DEVOPS_ENVSET_STUB_STORE"
    # The UID must resolve to his email in the audit, not be left as a raw UID —
    # otherwise the audit trail cannot say who acted.
    run jq -r 'select(.key=="'"$SECRET_KEY"'") | .requester' "$AUDIT_PATH"
    [ "$output" = "artem@muso.ai" ]
}

# The tests above run against a synthetic fixture allowlist, which means they
# would still pass if the SHIPPED config were wrong. These assert the real file —
# the only check that the grant, and the revocation, reach production.
@test "dev: shipped dev-envset-requesters.txt authorizes exactly the DEV authorities" {
    local real="${BATS_TEST_DIRNAME}/../../config/dev-envset-requesters.txt"
    [ -f "$real" ]
    # Serhii (U03TYGJF1N3) was a DEV authority until he left the company on
    # 2026-08-26; the revocation is asserted in its own test below, alongside
    # Artem D's. Artem M is the remaining standing DEV authority.
    for id in U02N2NP3H7F; do
        grep -qx "$id" "$real" || { echo "missing DEV authority UID: $id" >&2; return 1; }
    done
    grep -qx 'artem@muso.ai' "$real"
}

@test "dev: shipped config does NOT authorize departed Serhii (revocation holds)" {
    local dev="${BATS_TEST_DIRNAME}/../../config/dev-envset-requesters.txt"
    local prod="${BATS_TEST_DIRNAME}/../../config/envset-requesters.txt"
    # Same shape as the Artem D test below: active (non-comment) lines only, and
    # capture-then-compare rather than `! cmd | grep -q`, which bats' errexit
    # exempts and which could therefore never fail. Serhii is still NAMED in
    # comments there on purpose ("do not re-add him"), so a plain grep would
    # match documentation and pass vacuously.
    local strip='s/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
    local dev_uid dev_handle dev_email prod_hit
    dev_uid="$(sed "$strip" "$dev" | grep -cx 'U03TYGJF1N3' || true)"
    dev_handle="$(sed "$strip" "$dev" | grep -cx 'serhii' || true)"
    dev_email="$(sed "$strip" "$dev" | grep -cx 'serhii@muso.ai' || true)"
    prod_hit="$(sed "$strip" "$prod" | grep -cx 'U03TYGJF1N3' || true)"
    [ "$dev_uid" -eq 0 ]
    [ "$dev_handle" -eq 0 ]
    [ "$dev_email" -eq 0 ]
    [ "$prod_hit" -eq 0 ]
}

@test "dev: shipped config does NOT authorize departed Artem D (revocation holds)" {
    local dev="${BATS_TEST_DIRNAME}/../../config/dev-envset-requesters.txt"
    local prod="${BATS_TEST_DIRNAME}/../../config/envset-requesters.txt"
    # Active (non-comment) lines only — a commented mention is documentation, an
    # active line is authority. NOTE: assertions here capture to a variable and
    # compare with [[ != ]] on purpose. A mid-test `! cmd | grep -q` is exempt
    # from bats' errexit and can NEVER fail, so it would be a vacuous assertion.
    local strip='s/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
    local dev_hit prod_hit
    dev_hit="$(sed "$strip" "$dev" | grep -cx 'U0ACHTYUULT' || true)"
    prod_hit="$(sed "$strip" "$prod" | grep -cx 'U0ACHTYUULT' || true)"
    [ "$dev_hit" -eq 0 ]
    [ "$prod_hit" -eq 0 ]
    # He must not have been silently remapped to the remaining Artem's address.
    run bash "$SCRIPT" --requester U0ACHTYUULT resolve-email
    [[ "$output" != "artem@muso.ai" ]]
}

@test "dev: a non-secret key is self-serve too (exit 0, not redacted)" {
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
    run jq -r 'select(.key=="LOG_LEVEL") | "\(.env)/\(.dev_self_serve)/\(.new_value)"' "$AUDIT_PATH"
    [[ "$output" == "dev/false/debug" ]]
}

# --- DEV audit: env + dev_self_serve + secret redaction ---

@test "dev: secret value is redacted in the audit, env=dev, dev_self_serve=true" {
    printf '%s=old\n' "$SECRET_KEY" > "$DEVOPS_ENVSET_STUB_STORE"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value new_secret_val
    [ "$status" -eq 0 ]
    run jq -r "select(.key==\"$SECRET_KEY\") | \"\(.env)/\(.dev_self_serve)/\(.blocklist_override)/\(.prev_value)/\(.new_value)\"" "$AUDIT_PATH"
    [[ "$output" == "dev/true/false/[REDACTED:secret-shaped]/[REDACTED:secret-shaped]" ]]
    # The raw secret material is NEVER persisted to the audit JSONL.
    ! grep -q 'new_secret_val' "$AUDIT_PATH"
    ! grep -q 'old' "$AUDIT_PATH"
}

@test "dev: secret rollback hint does not echo the value" {
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value topsecret
    [ "$status" -eq 0 ]
    [[ "$output" != *topsecret* ]]
    [[ "$output" == *"secret-management path"* ]]
}

@test "dev: dry-run reports would-execute, env=dev, writes nothing" {
    export OPS_DRY_RUN=1
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value v
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dryRun":true'* ]]
    [[ "$output" == *'"env":"dev"'* ]]
    [ ! -f "$DEVOPS_ENVSET_STUB_STORE" ]
}

# --- DEV requester gate (fail-closed) ---

@test "dev: a requester not on the dev list is refused (exit 3)" {
    run dev_set liza@muso.ai --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 3 ]
    [[ "$output" == *DEVOPS_ENVSET_REQUESTER_DENIED* ]]
    [[ "$output" == *"env=dev"* ]]
}

@test "dev: missing dev-requesters file fails closed (exit 3)" {
    rm -f "$DEV_ENVSET_REQUESTERS_PATH"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 3 ]
    [[ "$output" == *DEVOPS_ENVSET_CONFIG_MISSING* ]]
}

# --- DEV target gate (glob + fail-closed + scope containment) ---

@test "dev: target outside muso-dev glob is refused (exit 5)" {
    run dev_set U03TYGJF1N3 --target other-ns/svc --key LOG_LEVEL --value debug
    [ "$status" -eq 5 ]
    [[ "$output" == *DEVOPS_ENVSET_TARGET_DENIED* ]]
}

@test "dev: a PROD target name cannot be reached via --env dev (exit 5)" {
    # 'core-backend' is a prod allowlist entry; the dev allowlist only has
    # muso-dev/* — so --env dev can never touch a prod target.
    run dev_set U03TYGJF1N3 --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 5 ]
    [[ "$output" == *DEVOPS_ENVSET_TARGET_DENIED* ]]
}

@test "dev: missing dev-target-allowlist fails closed (exit 5)" {
    rm -f "$DEV_TARGET_ALLOWLIST_PATH"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 5 ]
    [[ "$output" == *DEVOPS_ENVSET_CONFIG_MISSING* ]]
}

# --- DEV rate cap: still bounded, dev requester can self-ack ---

@test "dev: rate cap still trips (burst safety, exit 6)" {
    export ENVSET_THRESHOLD=2
    dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key A_FLAG --value 1
    dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key B_FLAG --value 1
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key C_FLAG --value 1
    [ "$status" -eq 6 ]
    [[ "$output" == *DEVOPS_ENVSET_RATE_APPROVAL_REQUIRED* ]]
}

@test "dev: a dev requester can self-ack the rate cap (exit 0)" {
    export ENVSET_THRESHOLD=2
    dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key A_FLAG --value 1
    dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key B_FLAG --value 1
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key C_FLAG --value 1 \
        --confirmed-by U03TYGJF1N3 --approval-msg-id 1777.9
    [ "$status" -eq 0 ]
}

# --- Regression: dev rules must NOT leak to prod; --env defaults to prod ---

@test "regression: --env defaults to prod, so a dev-only requester is denied (exit 3)" {
    # No --env → prod path → Serhii is not in the prod requester list.
    run bash "$SCRIPT" --requester U03TYGJF1N3 set --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 3 ]
    [[ "$output" == *DEVOPS_ENVSET_REQUESTER_DENIED* ]]
    [[ "$output" == *"env=prod"* ]]
}

@test "regression: explicit --env prod keeps the prod secret green-light gate (exit 4)" {
    # Even though dev makes secrets self-serve, prod must still demand a green-light.
    run bash "$SCRIPT" --requester nick --env prod set --target core-backend --key DB_PASSWORD --value x
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_KEY_BLOCKED* ]]
}

@test "invalid --env value is rejected" {
    run bash "$SCRIPT" --requester nick --env staging set --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid --env"* ]]
}

# --- DEV Vault backend (KV v2 merge-patch via curl) ---

# Install a fake `curl` on PATH:
#  - $CURL_LOG    ← the argv (assert secrets do NOT appear here)
#  - $CURL_STDIN  ← stdin, captured whenever `--config` is present (the token +
#                   payload travel via `curl --config -`). Consuming stdin BEFORE
#                   the PATCH return also avoids SIGPIPE to the config writer.
# A PATCH (write, `-o /dev/null -w '%{http_code}'`) prints just $FAKE_HTTP; a GET
# (read, `-w '\n%{http_code}'`) prints a KV v2 body, a newline, then $FAKE_GET_HTTP.
# $FAKE_GET_BODY overrides the read body (e.g. to simulate a malformed response).
use_fake_curl() {
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "$@" >> "$CURL_LOG"
for a in "$@"; do [ "$a" = "--config" ] && { cat >> "$CURL_STDIN"; break; }; done
for a in "$@"; do [ "$a" = "PATCH" ] && { printf '%s' "${FAKE_HTTP:-200}"; exit 0; }; done
body="${FAKE_GET_BODY:-}"
[ -n "$body" ] || body='{"data":{"data":{}}}'
printf '%s\n%s' "$body" "${FAKE_GET_HTTP:-200}"
CURL
    chmod +x "$TEST_ROOT/bin/curl"
    export CURL_LOG="$TEST_ROOT/curl.log"; : > "$CURL_LOG"
    export CURL_STDIN="$TEST_ROOT/curl.stdin"; : > "$CURL_STDIN"
    export PATH="$TEST_ROOT/bin:$PATH"
}

@test "dev vault: unconfigured (no creds/endpoint) fails closed (exit 8)" {
    export DEVOPS_ENVSET_BACKEND=vault
    unset DEVOPS_DEV_VAULT_ADDR DEVOPS_DEV_VAULT_TOKEN VAULT_ADDR VAULT_TOKEN
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value v
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_VAULT_UNCONFIGURED* ]]
}

@test "dev vault: configured write is a KV v2 merge-patch to the muso-dev path (exit 0)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value abc
    [ "$status" -eq 0 ]
    grep -q 'PATCH' "$CURL_LOG"
    grep -q 'http://vault.example:8200/v1/secret/data/k8s/muso-dev/core-backend-config' "$CURL_LOG"
    grep -q 'application/merge-patch+json' "$CURL_LOG"
    # The payload (key + value) travels via stdin, NOT argv.
    grep -q "$SECRET_KEY" "$CURL_STDIN"
    grep -q 'abc' "$CURL_STDIN"
    # Secret value must NOT be persisted to the audit (redacted).
    ! grep -q 'abc' "$AUDIT_PATH"
}

@test "dev vault: PATCH curl config carries one compact KV v2 JSON body" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value abc
    [ "$status" -eq 0 ]

    # curl config is line-oriented. A pretty-printed JSON body would turn its
    # continuation lines into separate directives and send only "{" to Vault.
    [ "$(grep -c '^data-binary = ' "$CURL_STDIN")" -eq 1 ]
    grep -Fqx 'data-binary = "{\"data\":{\"TUWUNEL_REGISTRATION_TOKEN\":\"abc\"}}"' "$CURL_STDIN"
}

@test "dev vault: the token and secret payload NEVER appear in curl argv (exit 0)" {
    use_fake_curl
    export TMPDIR="$TEST_ROOT/tmp"; mkdir -p "$TMPDIR"
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.SUPERSECRET_TOKEN"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value topsecretvalue
    [ "$status" -eq 0 ]
    # argv (what shows in ps / /proc/<pid>/cmdline) must be free of both secrets…
    ! grep -q 'SUPERSECRET_TOKEN' "$CURL_LOG"
    ! grep -q 'topsecretvalue' "$CURL_LOG"
    # …both travel via the `curl --config -` stdin channel instead.
    grep -q 'X-Vault-Token: s.SUPERSECRET_TOKEN' "$CURL_STDIN"
    grep -q 'topsecretvalue' "$CURL_STDIN"
}

@test "dev vault: no token file is ever staged on disk (nothing to leak on a kill)" {
    use_fake_curl
    # Route any would-be temp file into an isolated TMPDIR, then prove none was
    # created — the token travels via `--config -`, so a mid-call kill cannot
    # orphan a header file on disk (regression for the subshell-trap flaw).
    export TMPDIR="$TEST_ROOT/tmp"; mkdir -p "$TMPDIR"
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key "$SECRET_KEY" --value abc
    [ "$status" -eq 0 ]
    run bash -c "ls -1 '$TMPDIR'/devenv-vault.* 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
    # And no file anywhere in TMPDIR carries the token.
    run bash -c "grep -rl 's.faketoken' '$TMPDIR' 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "dev vault: a 403 from Vault fails closed (exit 8)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=403
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *"HTTP 403"* ]]
}

@test "dev vault: backend hard-pins muso-dev even if the allowlist is wildcarded (exit 8)" {
    use_fake_curl
    printf '%s\n' '*' > "$DEV_TARGET_ALLOWLIST_PATH"   # deliberately too loose
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target prod-thing --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_SCOPE_VIOLATION* ]]
    ! grep -q 'PATCH' "$CURL_LOG"   # never reached Vault
}

# --- Read is fail-closed: an untrusted read must refuse, not fabricate empty prev ---

@test "dev vault: a 403 on the READ fails closed before any write (exit 8)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_GET_HTTP=403
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_VAULT_READ_FAILED* ]]
    [[ "$output" == *"HTTP 403"* ]]
    ! grep -q 'PATCH' "$CURL_LOG"   # never wrote — the read failure refused the set
    # We refuse BEFORE write_audit, so no audit line is emitted for this key.
    [ ! -f "$AUDIT_PATH" ] || ! grep -q 'LOG_LEVEL' "$AUDIT_PATH"
}

@test "dev vault: a malformed READ body (not JSON) fails closed (exit 8)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_GET_BODY='<html>bad gateway</html>'
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_VAULT_READ_FAILED* ]]
    ! grep -q 'PATCH' "$CURL_LOG"
}

@test "dev vault: a 200 with valid JSON but wrong KV v2 shape fails closed (exit 8)" {
    use_fake_curl
    # Valid JSON, HTTP 200, but NOT a KV v2 secret (no .data.data object). Must
    # fail closed — NOT be read as "no prior value" and then PATCH.
    export DEVOPS_ENVSET_BACKEND=vault FAKE_GET_BODY='{"data":{}}'
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_VAULT_READ_FAILED* ]]
    ! grep -q 'PATCH' "$CURL_LOG"   # never wrote
}

@test "dev vault: a well-formed KV v2 secret with the key absent is a legit empty prev (exit 0)" {
    use_fake_curl
    # Distinguish from the malformed case: `.data.data` IS an object, the key is
    # just not set yet → empty prev is CORRECT, so the write proceeds.
    export DEVOPS_ENVSET_BACKEND=vault FAKE_GET_BODY='{"data":{"data":{"OTHER":"x"}}}' FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
    grep -q 'PATCH' "$CURL_LOG"
}

@test "dev vault: a 404 READ (secret absent) is a legit empty prev, write proceeds (exit 0)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_GET_HTTP=404 FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
    grep -q 'PATCH' "$CURL_LOG"
}

# --- Scope guard rejects path traversal, not just a prefix glob ---

@test "dev vault: a path-traversal target is refused by the scope guard (exit 8)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    # Passes the loose allowlist glob (muso-dev/*) but must NOT pass the strict
    # backend scope guard: '..' segments could escape the muso-dev prefix.
    run dev_set U03TYGJF1N3 --target 'muso-dev/../../secret/data/k8s/prod' --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_SCOPE_VIOLATION* ]]
    ! grep -q 'PATCH' "$CURL_LOG"   # never reached Vault
}

@test "dev: a reserved-char target is refused by the scope guard (exit 8)" {
    use_fake_curl
    export DEVOPS_ENVSET_BACKEND=vault FAKE_HTTP=200
    export DEVOPS_DEV_VAULT_ADDR="http://vault.example:8200" DEVOPS_DEV_VAULT_TOKEN="s.faketoken"
    run dev_set U03TYGJF1N3 --target 'muso-dev/svc?x=1' --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_DEV_SCOPE_VIOLATION* ]]
    ! grep -q 'PATCH' "$CURL_LOG"
}

# --- Rollback hint is env-aware (a dev hint pasted as-is must not hit prod gates) ---

@test "dev: non-secret rollback hint includes --env dev (else prod gates refuse it)" {
    printf 'LOG_LEVEL=info\n' > "$DEVOPS_ENVSET_STUB_STORE"   # a prior value exists
    run dev_set U03TYGJF1N3 --target "$DEV_TARGET" --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
    [[ "$output" == *"↩ rollback:"* ]]
    [[ "$output" == *"--env dev"* ]]
    [[ "$output" == *"--value info"* ]]
    [[ "$output" == *"--target ${DEV_TARGET}"* ]]
}
