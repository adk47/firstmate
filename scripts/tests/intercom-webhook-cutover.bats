#!/usr/bin/env bats
# Tests for the intercom-webhook cutover block inside install-aux-units.sh.
#
# T13 replaces a live systemd unit on node-8 on the next deploy. The unit is
# idle (loopback :18792; the customer path is Ingress → edge gateway) but it is
# still a live service, so the cutover has to be exercised BEFORE it ships:
# rendered file → new unit → plaintext drop-ins retired → restart → `check`
# proves the invariant, with the old unit and drop-ins preserved for a revert.
#
# The block is EXTRACTED from install-aux-units.sh and run against a throwaway
# tree with a `systemctl` stub, so these tests prove the real shipped block and
# never touch /etc or systemd. Path knobs (INTERCOM_WEBHOOK_*) are what make that
# possible; production sets none of them.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    INSTALLER="${BATS_TEST_DIRNAME}/../install-aux-units.sh"
    [[ -f "$INSTALLER" ]] || { echo "installer not found: $INSTALLER" >&2; return 1; }

    # Extract the cutover block: from its banner to the next banner.
    BLOCK="$TEST_ROOT/block.sh"
    awk '/^# ─── intercom-webhook: secrets OUT of the unit/ {f=1}
         f && /^# ─── Retire the keyword Intercom data-complaint watchdog/ {exit}
         f {print}' "$INSTALLER" > "$BLOCK"
    [ -s "$BLOCK" ] || { echo "cutover block not found in install-aux-units.sh" >&2; return 1; }

    mkdir -p "$TEST_ROOT/systemd/intercom-webhook.service.d" \
             "$TEST_ROOT/bin" "$TEST_ROOT/var" "$TEST_ROOT/etc"

    export HYDRA_ROOT="${BATS_TEST_DIRNAME}/../.."
    export INTERCOM_WEBHOOK_ENV_FILE="$TEST_ROOT/etc/intercom-webhook.env"
    export INTERCOM_WEBHOOK_UNIT_DIR="$TEST_ROOT/systemd"
    export INTERCOM_WEBHOOK_UNIT_PATH="$TEST_ROOT/systemd/intercom-webhook.service"
    export INTERCOM_WEBHOOK_DROPIN_DIR="$TEST_ROOT/systemd/intercom-webhook.service.d"
    export INTERCOM_WEBHOOK_LEGACY_ENV_FILE="$TEST_ROOT/systemd/intercom-webhook.service.d/env.conf"
    export INTERCOM_WEBHOOK_RETIRE_DIR="$TEST_ROOT/var/intercom-webhook"
    export INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL=1
    export INTERCOM_WEBHOOK_ENV_NO_KUBECTL=1

    # The pre-T13 state exactly as found on node-8 (fixture values).
    cat > "$INTERCOM_WEBHOOK_UNIT_PATH" <<'EOF'
[Unit]
Description=Intercom Webhook Receiver
After=network.target openclaw-gateway.service

[Service]
Type=simple
ExecStart=/usr/bin/node /opt/hydra/scripts/intercom-webhook.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
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
    cp "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf.bak.prod"

    # systemctl stub: records calls, always "active", and answers `show` the way
    # the real one does for a correctly-wired unit (EnvironmentFiles names the
    # rendered file; Environment carries only the non-secret knobs).
    # the live receiver is RUNNING; `stop` (only the retire path calls it) flips it
    printf 'active' > "$TEST_ROOT/active_state"
    cat > "$TEST_ROOT/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TEST_ROOT/systemctl.log"
case "\$1" in
  is-active) cat "$TEST_ROOT/active_state"; echo ;;
  is-enabled) echo disabled; exit 1 ;;
  stop) printf 'inactive' > "$TEST_ROOT/active_state"; exit 0 ;;
  disable) exit 0 ;;
  show) case "\$*" in
          *"-p EnvironmentFiles"*) echo "$INTERCOM_WEBHOOK_ENV_FILE" ;;
          *"-p Environment"*)      echo "INTERCOM_WEBHOOK_PORT=18792 OPENCLAW_URL=http://localhost:18792" ;;
          *)                       echo "" ;;
        esac ;;
esac
exit 0
EOF
    chmod +x "$TEST_ROOT/bin/systemctl"

    # Harness: the installer's helpers + the extracted block.
    cat > "$TEST_ROOT/run-block.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
log()  { echo "[log] \$*"; }
fail() { echo "[FATAL] \$*" >&2; exit 1; }
source "$BLOCK"
EOF
    chmod +x "$TEST_ROOT/run-block.sh"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

run_block() {
    PATH="$TEST_ROOT/bin:$PATH" run bash "$TEST_ROOT/run-block.sh"
}

@test "cutover renders the env file, installs the secret-free unit and restarts" {
    run_block
    [ "$status" -eq 0 ]
    # env file rendered, root-only
    [ -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    local mode
    mode="$(stat -c '%a' "$INTERCOM_WEBHOOK_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$INTERCOM_WEBHOOK_ENV_FILE")"
    [ "$mode" = "600" ]
    # unit now names the EnvironmentFile and carries no secret
    run grep '^EnvironmentFile=-' "$INTERCOM_WEBHOOK_UNIT_PATH"
    [ "$status" -eq 0 ]
    run grep -c 'TOKEN=' "$INTERCOM_WEBHOOK_UNIT_PATH"
    [ "$output" = "0" ]
    # restart happened
    run grep -q 'restart intercom-webhook' "$TEST_ROOT/systemctl.log"
    [ "$status" -eq 0 ]
    [[ "$output" == "" ]]
    # the check ran and passed
    [[ "$output" != *"FAIL"* ]]
}

@test "cutover RETIRES both plaintext drop-ins out of the drop-in dir" {
    run_block
    [ "$status" -eq 0 ]
    [ ! -f "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf" ]
    [ ! -f "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf.bak.prod" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/ | grep -c 'env.conf'"
    [ "$output" = "2" ]
    # ... preserved 0600, outside systemd's scan path
    run bash -c "grep -l INTERCOM_TOKEN '$INTERCOM_WEBHOOK_RETIRE_DIR'/env.conf.retired-* >/dev/null"
    [ "$status" -eq 0 ]
}

@test "cutover backs up the hand-placed unit before replacing it (revert path)" {
    run_block
    [ "$status" -eq 0 ]
    [ -f "$INTERCOM_WEBHOOK_RETIRE_DIR/intercom-webhook.service.pre-t13" ]
    run grep -c 'openclaw-gateway.service' "$INTERCOM_WEBHOOK_RETIRE_DIR/intercom-webhook.service.pre-t13"
    [ "$output" = "1" ]
}

@test "cutover ABORTS before writing the unit when the pre-T13 backup fails" {
    # QA round 9: the backup used to be `install ... || log "WARN"`, so a full or
    # unwritable retire dir let the heredoc overwrite the ONLY hand-placed
    # pre-T13 unit — destroying the revert the RUNBOOK documents, exactly when a
    # rollback may be needed. The backup must be a precondition of the write.
    REAL_INSTALL="$(command -v install)"
    cat > "$TEST_ROOT/bin/install" <<EOF
#!/usr/bin/env bash
# Simulate an unwritable backup destination: fail ONLY the pre-T13 backup,
# delegate every other install call to the real one.
for a in "\$@"; do
  case "\$a" in
    *intercom-webhook.service.pre-t13*)
      echo "install: cannot create regular file '\$a': Permission denied" >&2
      exit 1 ;;
  esac
done
exec "$REAL_INSTALL" "\$@"
EOF
    chmod +x "$TEST_ROOT/bin/install"
    cp "$INTERCOM_WEBHOOK_UNIT_PATH" "$TEST_ROOT/unit.before"
    cp "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" "$TEST_ROOT/dropin.before"

    run_block
    [ "$status" -ne 0 ]                              # NOT a false success
    [[ "$output" == *"refusing to overwrite the live unit without a revert copy"* ]]
    [[ "$output" == *"LEFT AS THEY WERE"* ]]
    # The original unit and the plaintext drop-ins are byte-identical.
    run diff "$TEST_ROOT/unit.before" "$INTERCOM_WEBHOOK_UNIT_PATH"
    [ "$status" -eq 0 ]
    [ -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" ]
    run diff "$TEST_ROOT/dropin.before" "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE"
    [ "$status" -eq 0 ]
    [ -f "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf.bak.prod" ]   # not retired
    # Nothing was reloaded or restarted.
    run bash -c "grep -c 'restart intercom-webhook' '$TEST_ROOT/systemctl.log' 2>/dev/null | head -1"
    [ "${output:-0}" = "0" ]
    run bash -c "grep -c 'daemon-reload' '$TEST_ROOT/systemctl.log' 2>/dev/null | head -1"
    [ "${output:-0}" = "0" ]
}

@test "a SECOND run is a no-op: no re-restart when nothing changed" {
    run_block
    [ "$status" -eq 0 ]
    cp "$TEST_ROOT/systemctl.log" "$TEST_ROOT/first.log"
    run_block
    [ "$status" -eq 0 ]
    # only the first run restarted the receiver
    run bash -c "grep -c 'restart intercom-webhook' '$TEST_ROOT/systemctl.log'"
    [ "$output" = "1" ]
    run bash -c "grep -c 'restart intercom-webhook' '$TEST_ROOT/first.log'"
    [ "$output" = "1" ]
}

@test "unresolved required keys leave the legacy drop-in in place and change nothing" {
    cat > "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" <<'EOF'
[Service]
Environment=INTERCOM_WEBHOOK_SECRET=fixture-webhook-secret-0001
EOF
    cp "$INTERCOM_WEBHOOK_UNIT_PATH" "$TEST_ROOT/unit.before"
    run_block
    [ "$status" -eq 0 ]            # a WARN, not a deploy failure
    [[ "$output" == *"LEFT AS THEY WERE"* ]]
    [ -f "$INTERCOM_WEBHOOK_LEGACY_ENV_FILE" ]      # not retired
    run diff "$TEST_ROOT/unit.before" "$INTERCOM_WEBHOOK_UNIT_PATH"
    [ "$status" -eq 0 ]                             # unit not replaced
    # nothing restarted: `run grep -q` swallows the match either way, so grep
    # the log directly (bash -c) and require a ZERO count.
    run bash -c "grep -c 'restart intercom-webhook' '$TEST_ROOT/systemctl.log' 2>/dev/null | head -1"
    [ "${output:-0}" = "0" ]                             # nothing restarted
}

# ── retirement wiring (plan step 6) ───────────────────────────────────────────
# The cutover block must (a) never resurrect a retired receiver and (b) retire on
# a deploy only when the proof holds. Both are switches, not code paths a human
# triggers by hand — and "could not measure" is not "0 hits".

stage_retirement_stubs() {
    # journalctl stub: startup lines only (0 inbound events) AND history that
    # reaches back past the window, so the coverage proof can actually pass —
    # a truncated journal is deliberately NOT "0 hits".
    cat > "$TEST_ROOT/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--until*) printf '{"__REALTIME_TIMESTAMP":"1700000000000000"}\n' ;;
  *"-o json"*) printf '{"__REALTIME_TIMESTAMP":"1600000000000000"}\n' ;;
  *) printf '[intercom-webhook] listening on 127.0.0.1:18792\n[intercom-webhook] OpenClaw: x\n' ;;
esac
STUB
    chmod +x "$TEST_ROOT/bin/journalctl"
    # id -u → 0 so the retire script's root guard passes; every path it touches
    # is inside $TEST_ROOT, so this grants no real privilege.
    cat > "$TEST_ROOT/bin/id" <<'STUB'
#!/usr/bin/env bash
case "$1" in -u) echo 0 ;; *) /usr/bin/id "$@" ;; esac
STUB
    chmod +x "$TEST_ROOT/bin/id"
    export INTERCOM_WEBHOOK_RETIRE_REQUEST="$TEST_ROOT/retire-requested"
    : > "$INTERCOM_WEBHOOK_RETIRE_REQUEST"
    # The retire script measures THROUGH journalctl; the harness-wide
    # NO_SYSTEMCTL knob exists for the env-file checks, so lift it here.
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL
}

@test "retirement request + proven 0 hits retires the receiver during the deploy" {
    stage_retirement_stubs
    run_block
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAIL:"* ]]
    [ ! -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]          # retired, not just cleaned
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "1" ]
}

@test "retirement request with traffic present does NOT retire" {
    stage_retirement_stubs
    cat > "$TEST_ROOT/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '[intercom-webhook] listening on 127.0.0.1:18792\n[intercom-webhook] conversation.user.replied conv=abc event=e1\n'
STUB
    chmod +x "$TEST_ROOT/bin/journalctl"
    run_block
    [ "$status" -eq 0 ]
    [[ "$output" == *"still taking traffic"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
}

@test "retirement request that CANNOT be measured does NOT retire" {
    stage_retirement_stubs
    cat > "$TEST_ROOT/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_ROOT/bin/journalctl"
    run_block
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot measure the receiver's traffic"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
}

@test "an existing RETIRED marker stops the deploy from reinstalling the unit" {
    stage_retirement_stubs
    mkdir -p "$INTERCOM_WEBHOOK_RETIRE_DIR"
    printf '{"retired_at":"2026-01-01T00:00:00Z","inbound_events":0}\n' \
        > "$INTERCOM_WEBHOOK_RETIRE_DIR/RETIRED-20260101T000000Z.json"
    rm -f "$INTERCOM_WEBHOOK_UNIT_PATH"
    run_block
    [ "$status" -eq 0 ]
    [[ "$output" == *"RETIRED"* ]]
    [ ! -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]           # not resurrected
    run bash -c "grep -c 'restart intercom-webhook' '$TEST_ROOT/systemctl.log' 2>/dev/null | head -1"
    [ "${output:-0}" = "0" ]
}
