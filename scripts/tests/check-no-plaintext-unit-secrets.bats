#!/usr/bin/env bats
# Tests for scripts/check-no-plaintext-unit-secrets.sh.
#
# The gate protects one invariant: a systemd unit that ships from this repo may
# NAME a secret (EnvironmentFile=/path) and must never HOLD one
# (Environment=INTERCOM_TOKEN=…). T13 found exactly that in
# intercom-webhook.service.d/env.conf on node-8 — Intercom token, webhook
# signing secret, OpenClaw gateway token and a Notion token — and its sibling
# `env.conf.bak.prod`. install-aux-units.sh writes ~40 units on every deploy, so
# the same paste one line into a heredoc would be live within the hour and in
# git forever.
#
# Everything runs against a THROWAWAY tree: a test that had to plant a real
# credential in the repo to prove the gate works would be one crash away from
# committing it.

# Token-shaped fixtures are BUILT AT RUNTIME, never written as literals: a
# scanner that reads this file (the nightly secret scan does) must not see a
# credential shape in the tests that exist to catch credential shapes. The shapes
# are still exactly what the gate matches.
fixture_notion()   { printf 'ntn_%s'   "$(printf 'a%.0s' {1..24})"; }
fixture_slack()    { printf 'xoxb-%s-%s' "$(printf '1%.0s' {1..10})" "$(printf 'b%.0s' {1..12})"; }
fixture_github()   { printf 'ghp_%s'   "$(printf 'c%.0s' {1..30})"; }
fixture_openai()   { printf 'sk-%s'    "$(printf 'd%.0s' {1..24})"; }
fixture_pem()      { printf -- '-----BEGIN %s PRIVATE KEY-----' 'RSA'; }

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    REAL_SCRIPT="${BATS_TEST_DIRNAME}/../check-no-plaintext-unit-secrets.sh"
    [[ -f "$REAL_SCRIPT" ]] || { echo "gate not found: $REAL_SCRIPT" >&2; return 1; }

    mkdir -p "$TEST_ROOT/scripts/aux-units" "$TEST_ROOT/scripts/lib"
    cp "$REAL_SCRIPT" "$TEST_ROOT/scripts/"
    # The gate refuses to run without its assignment parser, so the fixture tree
    # must carry the real one (a stubbed parser would test nothing).
    cp "${BATS_TEST_DIRNAME}/../lib/systemd-env-assignments.sh" "$TEST_ROOT/scripts/lib/"
    GATE="$TEST_ROOT/scripts/check-no-plaintext-unit-secrets.sh"
    # A NEUTRAL fixture name on purpose: `intercom-webhook.service` carries an extra
    # POSITIVE allow-list (its own test below), so using it here would route every
    # heuristic case through that rule instead of the heuristic under test.
    UNIT="$TEST_ROOT/scripts/aux-units/sample.service"

    # A correct unit: names the secret's file, holds no secret.
    cat > "$UNIT" <<'EOF'
[Service]
EnvironmentFile=-/etc/hydra/intercom-webhook.env
Environment=INTERCOM_WEBHOOK_PORT=18792
Environment=OPENCLAW_URL=http://localhost:18789
ExecStart=/usr/bin/node /app/scripts/intercom-webhook.js
EOF
}

teardown() {
    rm -rf "$TEST_ROOT"
}

run_gate() {
    SECRET_SCAN_ROOT="$TEST_ROOT" run bash "$GATE" scripts/aux-units
}

@test "passes on a unit that only names the EnvironmentFile" {
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"no plaintext secrets"* ]]
}

@test "FAILS on an inline token in an Environment= line" {
    cat >> "$UNIT" <<'EOF'
Environment=INTERCOM_TOKEN=tok_live_fixture_value_0123456789
EOF
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for INTERCOM_TOKEN"* ]]
    # The gate must never echo the value into a CI log.
    [[ "$output" != *"tok_live_fixture_value_0123456789"* ]]
}

@test "FAILS on an inline secret, webhook-secret and API-key name alike" {
    for name in INTERCOM_WEBHOOK_SECRET OPENCLAW_TOKEN NOTION_API_TOKEN \
                CLIENT_SECRET ADMIN_PASSWORD SERVICE_CREDENTIAL PROD_DSN \
                PRIVATE_KEY; do
        printf 'Environment=%s=abcdefghijklmnop\n' "$name" >> "$UNIT"
    done
    run_gate
    [ "$status" -eq 1 ]
    for name in INTERCOM_WEBHOOK_SECRET OPENCLAW_TOKEN NOTION_API_TOKEN \
                CLIENT_SECRET ADMIN_PASSWORD SERVICE_CREDENTIAL PROD_DSN PRIVATE_KEY; do
        [[ "$output" == *"for $name"* ]] || { echo "missed $name"; return 1; }
    done
}

@test "FAILS on a credential SHAPE even when the variable name looks innocent" {
    printf 'Environment=SUPPORT_INBOX=%s\n' "$(fixture_notion)" >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"literal credential shape"* ]]
    [[ "$output" != *"$(fixture_notion)"* ]]
}

@test "FAILS on a Slack / GitHub / OpenAI style token and a PEM header" {
    for value in "$(fixture_slack)" "$(fixture_github)" "$(fixture_openai)" "$(fixture_pem)"; do
        mkdir -p "$TEST_ROOT/fixtures"
        printf '# %s\n' "$value" > "$TEST_ROOT/fixtures/leak.txt"
        SECRET_SCAN_ROOT="$TEST_ROOT" run bash "$GATE" fixtures
        [ "$status" -eq 1 ]
    done
}

@test "does NOT flag a non-secret name, an empty value, or a systemd expansion" {
    cat >> "$UNIT" <<'EOF'
Environment=DISPATCH_TIMEOUT_MS=30000
Environment=INTERCOM_WORKSPACE_ID=
Environment=QUARANTINE_PATH=${HOME}/quarantine.json
Environment=SLACK_CS_CHATS_WEBHOOK=
EOF
    run_gate
    [ "$status" -eq 0 ]
}

@test "honours 'secret-ok:' on the same line and on the comment line above" {
    cat >> "$UNIT" <<'EOF'
# secret-ok: fixture-shaped placeholder, not a credential
Environment=NOTION_API_TOKEN=fixture-placeholder-value
Environment=OPENCLAW_TOKEN=fixture-placeholder-value-2  # secret-ok: same-line exemption
EOF
    run_gate
    [ "$status" -eq 0 ]
}

@test "reports ONE finding per offending line (no duplicate rule hits)" {
    cat >> "$UNIT" <<'EOF'
Environment=INTERCOM_TOKEN=two-rules-apply-to-this-value
EOF
    run_gate
    [ "$status" -eq 1 ]
    run grep -c "inline secret value for INTERCOM_TOKEN" <<<"$output"
    [ "$output" = "1" ]
}

@test "refuses to pass vacuously when a scan target is missing" {
    SECRET_SCAN_ROOT="$TEST_ROOT" run bash "$GATE" scripts/does-not-exist
    [ "$status" -eq 2 ]
    [[ "$output" == *"not found"* ]]
}

@test "the real repo is clean (this PR's whole point)" {
    run bash "$REAL_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no plaintext secrets"* ]]
}

@test "the real install-aux-units.sh heredocs carry no unit secret" {
    run bash "$REAL_SCRIPT" scripts/install-aux-units.sh
    [ "$status" -eq 0 ]
}

@test "refuses to pass vacuously when no *.service is in the scan set" {
    # A gate that scans nothing is the failure mode it exists to prevent: assert
    # the refusal explicitly rather than trusting the find to keep working. This
    # guard only applies to the DEFAULT target set (CI), so stage that set.
    printf '# no units here\n' > "$TEST_ROOT/scripts/install-aux-units.sh"
    rm -f "$TEST_ROOT"/scripts/aux-units/*.service
    printf 'not a unit\n' > "$TEST_ROOT/scripts/aux-units/intercom-webhook.timer"
    SECRET_SCAN_ROOT="$TEST_ROOT" run bash "$GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not one *.service"* ]]
}

# ── the one-space bypass (Fable r5 / QA Critical) ─────────────────────────────
# systemd applies SEVERAL assignments on one `Environment=` line. A guard that
# parses only the first pair certifies `Environment=PORT=1 OPENCLAW_TOKEN=abc…`
# as clean — a hole you can walk through by typing a space.

@test "FAILS when the secret is the SECOND assignment on the line (one-space bypass)" {
    cat >> "$UNIT" <<'EOF'
Environment=INTERCOM_WEBHOOK_PORT=18792 OPENCLAW_TOKEN=fixture-openclaw-token-9f8e
EOF
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for OPENCLAW_TOKEN"* ]]
    [[ "$output" != *"fixture-openclaw-token-9f8e"* ]]
}

@test "FAILS on any position: first, middle, last of a multi-assignment line" {
    for line in \
      'Environment=OPENCLAW_TOKEN=fixture-token-aaaa A=1 B=2' \
      'Environment=A=1 OPENCLAW_TOKEN=fixture-token-bbbb B=2' \
      'Environment=A=1 B=2 OPENCLAW_TOKEN=fixture-token-cccc'; do
        printf '%s\n' "$line" >> "$UNIT"
    done
    run_gate
    [ "$status" -eq 1 ]
    for n in OPENCLAW_TOKEN; do
        [[ "$output" == *"for $n"* ]] || { echo "missed $n"; return 1; }
    done
    run grep -c 'inline secret value for OPENCLAW_TOKEN' <<<"$output"
    [ "$output" = "3" ]
}

@test "FAILS when a quoted value hides the secret behind spaces" {
    cat >> "$UNIT" <<'EOF'
Environment="NOTION_API_TOKEN=has spaces in it" OPENCLAW_URL=http://x
EOF
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for NOTION_API_TOKEN"* ]]
    [[ "$output" != *"has spaces in it"* ]]
}

@test "FAILS when the whole assignment is quoted (quote before the name)" {
    cat >> "$UNIT" <<'EOF'
Environment="INTERCOM_TOKEN=quote-wrapped-fixture-value"
EOF
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for INTERCOM_TOKEN"* ]]
}

@test "still passes a multi-assignment line whose names are not secret" {
    cat >> "$UNIT" <<'EOF'
Environment=INTERCOM_WEBHOOK_PORT=18792 DISPATCH_TIMEOUT_MS=30000 OPENCLAW_URL=http://localhost:18789
EOF
    run_gate
    [ "$status" -eq 0 ]
}

@test "FAILS LOUD (rc 2) when the assignment parser is missing, never a silent pass" {
    # Without the parser rule 1 sees no assignments, so every multi-assignment
    # secret would look clean. Refusing to run is the only honest behaviour.
    rm -f "$TEST_ROOT/scripts/lib/systemd-env-assignments.sh"
    run_gate
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not load"* ]]
}

@test "FAILS when a quoted value contains a TAB (the field-split bypass)" {
    # QA's second bypass: a tab inside a legal quoted value used to truncate the
    # inspected value to its first field, so the gate saw "ab" while systemd
    # received the whole credential.
    printf 'Environment="OPENCLAW_TOKEN=ab\tcdefghijklmnop"\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for OPENCLAW_TOKEN"* ]]
    [[ "$output" != *"cdefghijklmnop"* ]]
}

@test "FAILS when a tab splits TWO assignments on one quoted line" {
    printf 'Environment="NOTION_API_TOKEN=xy\tzzzzzzzzzz" INTERCOM_WEBHOOK_PORT=18792\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for NOTION_API_TOKEN"* ]]
}

@test "FAILS on a secret assigned a shell expansion (heredoc-expanded at deploy)" {
    # QA new finding 1: install-aux-units.sh heredocs are expanded by the shell,
    # so `Environment=OPENCLAW_TOKEN=$OPENCLAW_TOKEN` writes plaintext into the
    # INSTALLED unit while the gate only saw a `$`.
    printf 'Environment=OPENCLAW_TOKEN=$OPENCLAW_TOKEN\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"shell expansion"* ]]
}

# ── round 5: escaped percent, value logging, extra secret names ───────────────

@test "FAILS on a literal value containing an ESCAPED percent (%% is a real value)" {
    # `Environment=FOO_SECRET=Abc12345%%xyz` loads a literal %; the old
    # literal-value test exempted anything containing %, so the gate passed.
    printf 'Environment=FOO_SECRET=Abc12345%%%%xyz\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for FOO_SECRET"* ]]
    [[ "$output" != *"Abc12345"* ]]
}

@test "NEVER prints the value, even when the value is a shell expansion" {
    printf 'Environment=FOO_SECRET=Abc12345$PART\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"shell expansion"* ]]
    [[ "$output" != *"Abc12345"* ]]
    [[ "$output" != *'$PART'* ]]
}

@test "FAILS on API_KEY / _KEY / _DSN, with and without the underscore" {
    for n in INTERCOM_API_KEY STRIPE_APIKEY PROVIDER_DSN PRIVATE_KEY; do
        printf 'Environment=%s=literal-looking-value\n' "$n" >> "$UNIT"
    done
    run_gate
    [ "$status" -eq 1 ]
    for n in INTERCOM_API_KEY STRIPE_APIKEY PROVIDER_DSN PRIVATE_KEY; do
        [[ "$output" == *"for $n"* ]] || { echo "missed $n"; return 1; }
    done
}

@test "an empty value or the systemd reset '-' is not a finding" {
    printf 'Environment=FOO_SECRET=\nEnvironment=BAR_TOKEN=-\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 0 ]
}

@test "FAILS on a CONTINUED Environment= line (backslash-newline join)" {
    # QA round 5: systemd joins `Environment=\` + the next line; a line-by-line
    # parser certifies it clean. Reproduced against the real gate before the fix.
    printf 'Environment=\\\nFOO_SECRET=Abc12345X\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for FOO_SECRET"* ]]
    [[ "$output" != *"Abc12345X"* ]]
}

@test "FAILS on a continuation inside an installer-heredoc style block" {
    printf '[Service]\nEnvironment=\\\n  OPENCLAW_TOKEN=fixture-continued-token\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"OPENCLAW_TOKEN"* ]]
    [[ "$output" != *"fixture-continued-token"* ]]
}

@test "an EVEN run of trailing backslashes is not a continuation" {
    # `\\` at end of line is an escaped backslash, not a line join. The parser must
    # not treat the following line as part of this one.
    printf 'Environment=INTERCOM_WEBHOOK_PORT=18792\\\\\nFOO_SECRET=Abc12345X\n' >> "$UNIT"
    run_gate
    # the FOO_SECRET line is a standalone line with no `Environment=` prefix, so
    # it is not an assignment and must NOT be reported
    [ "$status" -eq 0 ]
}

@test "FAILS when a continuation SEPARATES a non-secret and a secret assignment" {
    # QA round 7 fixture: systemd turns the trailing backslash into a space, so
    # this is two assignments (PORT, FOO_SECRET). Joining the lines directly made
    # it look like one PORT assignment with a junk value — a clean verdict on a
    # unit that loads a plaintext secret.
    printf 'Environment=INTERCOM_WEBHOOK_PORT=1\\\nFOO_SECRET=Abc12345X\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"FOO_SECRET"* ]]
    [[ "$output" != *"Abc12345X"* ]]
}

@test "FAILS when whitespace precedes the directive separator (Environment = ...)" {
    # QA round 8 Critical: valid systemd that used to emit no assignment at all.
    printf 'Environment = FOO_SECRET=fixturevalue123\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"FOO_SECRET"* ]]
    [[ "$output" != *"fixturevalue123"* ]]
}

@test "FAILS when a continuation spans a comment line" {
    printf 'Environment=INTERCOM_WEBHOOK_PORT=1\\\n# comment inside the continuation\nFOO_SECRET=fixturevalue123\n' >> "$UNIT"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"FOO_SECRET"* ]]
    [[ "$output" != *"fixturevalue123"* ]]
}

@test "the intercom-webhook unit obeys a POSITIVE allow-list, not just a secret heuristic" {
    # The endgame for nine rounds of parser evasions: a name outside the three
    # non-secret knobs is refused whatever the value looks like, so no parser
    # semantic (join, quote, continuation, whitespace) can manufacture a pass.
    local allowlisted="$TEST_ROOT/scripts/aux-units/intercom-webhook.service"
    cat > "$allowlisted" <<'EOF'
[Service]
EnvironmentFile=-/etc/hydra/intercom-webhook.env
Environment=INTERCOM_WEBHOOK_PORT=18792
Environment=OPENCLAW_URL=http://localhost:18789
EOF
    run_gate
    [ "$status" -eq 0 ]

    printf 'Environment=PROMPTGUARD_URL=http://localhost:18793\n' >> "$allowlisted"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"allow-list"* ]]
}
