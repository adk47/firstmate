#!/usr/bin/env bats
# Tests for scripts/intercom-webhook-env.sh — render + check.
#
# T13: intercom-webhook.service carried its Intercom token, webhook signing
# secret, OpenClaw gateway token and Notion token as plaintext `Environment=`
# lines in a systemd drop-in. The renderer builds the root-only
# EnvironmentFile that replaces them; `check` is the acceptance proof the deploy
# gates on (no installed unit file holds an inline secret, the file is root-only,
# every required key resolves).
#
# These tests use FIXTURE values only — never a real credential — and always a
# throwaway tree. The one root-only assertion runs only as root (CI is root on
# node-8; a laptop is not), so it skips instead of failing there.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../intercom-webhook-env.sh"
    [[ -f "$SCRIPT" ]] || { echo "renderer not found: $SCRIPT" >&2; return 1; }

    export INTERCOM_WEBHOOK_ENV_FILE="$TEST_ROOT/etc-hydra/intercom-webhook.env"
    export INTERCOM_WEBHOOK_UNIT_DIR="$TEST_ROOT/systemd"
    export INTERCOM_WEBHOOK_LEGACY_ENV_FILE="$TEST_ROOT/systemd/intercom-webhook.service.d/env.conf"
    export INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL=1
    mkdir -p "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d"

    UNIT="$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service"
    cat > "$UNIT" <<'EOF'
[Service]
EnvironmentFile=-/etc/hydra/intercom-webhook.env
Environment=INTERCOM_WEBHOOK_PORT=18792
ExecStart=/usr/bin/node /app/scripts/intercom-webhook.js
EOF

    # The legacy plaintext drop-in, exactly the shape found live on 2026-10-27.
    cat > "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" <<'EOF'
[Service]
Environment=INTERCOM_WEBHOOK_SECRET=fixture-webhook-secret-0001
Environment=INTERCOM_TOKEN=fixture-intercom-token-0002
Environment=INTERCOM_BOT_ADMIN_ID=10206197
Environment=INTERCOM_WORKSPACE_ID=gnvwt2nr
Environment=OPENCLAW_TOKEN=fixture-openclaw-token-0003
Environment=OPENCLAW_URL=http://localhost:18789
Environment=NOTION_API_TOKEN=fixture-notion-token-0004
Environment=NOTION_VERIFICATION_DB_ID=90dd692e17c442d082fa4a4f1a6250a3
Environment=DISPATCH_TIMEOUT_MS=30000
EOF
}

teardown() {
    rm -rf "$TEST_ROOT"
}

@test "render migrates every managed key out of the legacy drop-in" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    [ -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    run grep -c '^[A-Z_]*=' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$output" = "7" ]
    run grep '^OPENCLAW_TOKEN=fixture-openclaw-token-0003$' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$status" -eq 0 ]
    # Non-managed keys from the drop-in must not be blindly copied in.
    run grep 'DISPATCH_TIMEOUT_MS' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$status" -ne 0 ]
}

@test "render reports the keys that still need rotating (rotation debt)" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    [[ "$output" == *"ROTATION DEBT"* ]]
    [[ "$output" == *"OPENCLAW_TOKEN"* ]]
}

@test "render never prints a secret VALUE" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    [[ "$output" != *"fixture-openclaw-token-0003"* ]]
    [[ "$output" != *"fixture-webhook-secret-0001"* ]]
    # It does print a sha256 prefix, which is the auditable-but-safe bit.
    [[ "$output" == *"sha256:"* ]]
}

@test "render writes the EnvironmentFile 0600" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    # GNU (CI) and BSD (laptop) stat disagree on flags; accept either
    local mode
    mode="$(stat -c '%a' "$INTERCOM_WEBHOOK_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$INTERCOM_WEBHOOK_ENV_FILE")"
    [ "$mode" = "600" ]
}

@test "the ESO-synced Secret WINS over the legacy drop-in for keys it carries" {
    # Fake kubectl: the ExternalSecret target's real shape (hydra/intercom-webhook
    # carries INTERCOM_WEBHOOK_SECRET, INTERCOM_BOT_ADMIN_ID,
    # INTERCOM_WORKSPACE_ID — and, once the captain rotates into Vault, the rest).
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/kubectl" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{"data":{"INTERCOM_WEBHOOK_SECRET":"$(printf 'eso-webhook-secret-9999' | base64)","INTERCOM_BOT_ADMIN_ID":"$(printf '10206197' | base64)","INTERCOM_WORKSPACE_ID":"$(printf 'gnvwt2nr' | base64)","type":"$(printf 'Opaque' | base64)"}}
JSON
EOF
    chmod +x "$TEST_ROOT/bin/kubectl"
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    run grep '^INTERCOM_WEBHOOK_SECRET=eso-webhook-secret-9999$' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$status" -eq 0 ]
    # `type` is not a managed key and must never reach a file systemd reads.
    run grep -c '^type=' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$output" = "0" ]
    # Keys the Secret does not carry still come from the drop-in.
    run grep '^OPENCLAW_TOKEN=fixture-openclaw-token-0003$' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$status" -eq 0 ]
}

@test "render REFUSES (rc 3) when a required key is nowhere, and writes nothing" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    cat > "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" <<'EOF'
[Service]
Environment=INTERCOM_WEBHOOK_SECRET=fixture-webhook-secret-0001
Environment=INTERCOM_BOT_ADMIN_ID=10206197
EOF
    run bash "$SCRIPT" render
    [ "$status" -eq 3 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"INTERCOM_TOKEN"* ]]
    [ ! -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
}

@test "render keeps already-rendered values when the drop-in is gone and kubectl fails" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    run grep '^OPENCLAW_TOKEN=fixture-openclaw-token-0003$' "$INTERCOM_WEBHOOK_ENV_FILE"
    [ "$status" -eq 0 ]
}

@test "--dry-run renders nothing" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would write"* ]]
    [ ! -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
}

@test "check passes after the cutover (file rendered AND legacy drop-in retired)" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    # install-aux-units.sh retires the drop-in as part of the cutover; check is
    # what proves it happened.
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    run bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"carries no inline tokens"* ]]
}

@test "check FAILS while the legacy plaintext drop-in is still installed" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"carries an inline secret value"* ]]
}

@test "check FAILS when an installed unit file still holds an inline token" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    printf 'Environment=OPENCLAW_TOKEN=fixture-openclaw-token-0003\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/env.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for OPENCLAW_TOKEN"* ]]
    # Never echo the value.
    [[ "$output" != *"fixture-openclaw-token-0003"* ]]
}

@test "check FAILS when the EnvironmentFile is group/other readable" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    chmod 644 "$INTERCOM_WEBHOOK_ENV_FILE"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"mode is 644"* ]]
}

@test "check FAILS when a required key is missing from the file" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    grep -v '^OPENCLAW_TOKEN=' "$INTERCOM_WEBHOOK_ENV_FILE" > "$TEST_ROOT/trimmed"
    cat "$TEST_ROOT/trimmed" > "$INTERCOM_WEBHOOK_ENV_FILE"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"no non-empty OPENCLAW_TOKEN"* ]]
}

@test "check FAILS when the unit file is not installed at all" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$UNIT"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"not installed"* ]]
}

@test "check FAILS when the EnvironmentFile does not exist" {
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing"* ]]
}

@test "the shipped unit template names the EnvironmentFile and holds no secret" {
    run bash "${BATS_TEST_DIRNAME}/../check-no-plaintext-unit-secrets.sh" scripts/aux-units
    [ "$status" -eq 0 ]
    run grep '^EnvironmentFile=-/etc/hydra/intercom-webhook.env$' \
        "${BATS_TEST_DIRNAME}/../aux-units/intercom-webhook.service"
    [ "$status" -eq 0 ]
}

# ── the one-space bypass in the INSTALLED-unit check (Fable r5) ───────────────
# Same hole as the CI gate had, in the deploy-time half: `check` used to read
# only the first `NAME=value` after `Environment=`, so the secret could hide as
# the second assignment on the line.

@test "check FAILS on a multi-assignment line whose SECOND name is a secret" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment=INTERCOM_WEBHOOK_PORT=18792 OPENCLAW_TOKEN=fixture-openclaw-token-0003\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/env.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for OPENCLAW_TOKEN"* ]]
    [[ "$output" != *"fixture-openclaw-token-0003"* ]]
}

@test "check FAILS on a quoted multi-assignment secret in an installed unit" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment="NOTION_API_TOKEN=hidden in quotes here" OPENCLAW_URL=http://x\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/env.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for NOTION_API_TOKEN"* ]]
}

@test "check passes a multi-assignment line whose names are all non-secret" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment=INTERCOM_WEBHOOK_PORT=18792 OPENCLAW_URL=http://localhost:18789 DISPATCH_TIMEOUT_MS=30000\n' \
        >> "$UNIT"
    run bash "$SCRIPT" check
    [ "$status" -eq 0 ]
}

@test "check FAILS on a tab inside a quoted secret in an installed unit" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment="OPENCLAW_TOKEN=ab\tcdefghijklmnop"\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/env.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"inline secret value for OPENCLAW_TOKEN"* ]]
}

# ── the loaded-unit proof must not be skippable (QA new finding 2) ────────────

@test "check FAILS CLOSED when systemctl cannot read the unit" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_ROOT/bin/systemctl"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNVERIFIED"* ]]
}

@test "check FAILS when systemd does not reference the EnvironmentFile" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cat "*) exit 0 ;;
  *"-p EnvironmentFiles"*) echo /somewhere/else.env ;;
  *"-p Environment"*) echo "" ;;
esac
exit 0
STUB
    chmod +x "$TEST_ROOT/bin/systemctl"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not load"* ]]
}

# ── round 5: the DEPLOY check must use the same predicate as CI ───────────────

@test "check FAILS on an API_KEY / _DSN / _KEY literal in an installed drop-in" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    # QA: a host-side secrets.conf drop-in the cutover does not retire
    printf 'Environment=INTERCOM_API_KEY=a-literal-looking-value\nEnvironment=PROVIDER_DSN=pgsql://user:pw@host/db\nEnvironment=PRIVATE_KEY=another-literal\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/secrets.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    for n in INTERCOM_API_KEY PROVIDER_DSN PRIVATE_KEY; do
        [[ "$output" == *"for $n"* ]] || { echo "missed $n"; return 1; }
    done
}

@test "check FAILS on an escaped-percent secret value" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment=FOO_SECRET=Abc12345%%%%xyz\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/secrets.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"FOO_SECRET"* ]]
    [[ "$output" != *"Abc12345"* ]]
}

@test "check FAILS CLOSED when systemctl cannot report the loaded Environment" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cat "*) exit 0 ;;
  *"-p EnvironmentFiles"*) echo "$INTERCOM_WEBHOOK_ENV_FILE" ;;
  *"-p Environment"*) exit 1 ;;   # the query fails; must NOT read as clean
esac
exit 0
STUB
    chmod +x "$TEST_ROOT/bin/systemctl"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not report the loaded Environment"* ]]
}

@test "check FAILS on a CONTINUED secret line in an installed drop-in" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment=\\\nFOO_SECRET=Abc12345X\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/env.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"for FOO_SECRET"* ]]
    [[ "$output" != *"Abc12345X"* ]]
}

@test "check FAILS when systemd loads a PREFIX-matching but different EnvironmentFile" {
    # QA round 6: `<expected>.old` contains the expected path, so a substring test
    # certified a unit still loading the PREVIOUS file — after a token rotation
    # the receiver would keep the old token and 401 while deploy claimed success.
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cat "*) exit 0 ;;
  *"-p EnvironmentFiles"*) printf '%s.old (ignore_errors=no)\n' "$INTERCOM_WEBHOOK_ENV_FILE" ;;
  *"-p Environment"*) echo "INTERCOM_WEBHOOK_PORT=18792" ;;
esac
exit 0
STUB
    chmod +x "$TEST_ROOT/bin/systemctl"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not load"* ]]
}

@test "check PASSES when EnvironmentFiles carries the ignore_errors annotation on the exact path" {
    # The real systemctl prints `<path> (ignore_errors=no)`; the exact-path match
    # must strip that annotation, or a correct unit would fail.
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cat "*) exit 0 ;;
  *"-p EnvironmentFiles"*) printf '/some/other.env (ignore_errors=yes) %s (ignore_errors=no)\n' "$INTERCOM_WEBHOOK_ENV_FILE" ;;
  *"-p Environment"*) echo "INTERCOM_WEBHOOK_PORT=18792 OPENCLAW_URL=http://localhost:18789" ;;
esac
exit 0
STUB
    chmod +x "$TEST_ROOT/bin/systemctl"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"carries no inline tokens"* ]]
}

@test "check FAILS CLOSED when systemctl cannot report EnvironmentFiles" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cat "*) exit 0 ;;
  *"-p EnvironmentFiles"*) exit 1 ;;
  *"-p Environment"*) echo "" ;;
esac
exit 0
STUB
    chmod +x "$TEST_ROOT/bin/systemctl"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
    PATH="$TEST_ROOT/bin:$PATH" run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not report EnvironmentFiles"* ]]
}

@test "check FAILS when a continuation separates a secret assignment in an installed drop-in" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment=INTERCOM_WEBHOOK_PORT=1\\\nFOO_SECRET=Abc12345X\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/env.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"FOO_SECRET"* ]]
    [[ "$output" != *"Abc12345X"* ]]
}

@test "check FAILS on whitespace-around-= and on a comment inside a continuation" {
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment = FOO_SECRET=fixturevalue123\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/secrets.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"FOO_SECRET"* ]]
    [[ "$output" != *"fixturevalue123"* ]]

    printf 'Environment=INTERCOM_WEBHOOK_PORT=1\\\n# comment\nBAR_SECRET=fixturevalue456\n' \
        > "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d/secrets.conf"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"BAR_SECRET"* ]]
    [[ "$output" != *"fixturevalue456"* ]]
}

@test "check REFUSES an unknown knob in the installed unit even when it looks harmless" {
    # Deliberate: widening what a production unit may load from its own file is a
    # reviewable one-line change to the allow-list, not an ops-time surprise.
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1
    run bash "$SCRIPT" render
    [ "$status" -eq 0 ]
    rm -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    printf 'Environment=PROMPTGUARD_URL=http://localhost:18793\n' >> "$UNIT"
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"allow-list"* ]]
}
