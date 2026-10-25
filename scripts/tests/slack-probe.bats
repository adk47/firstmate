#!/usr/bin/env bats
# Tests for scripts/lib/slack-probe.sh — smoke-test.sh's post-restart gate that
# every Slack account in openclaw-main.json came up with a resolved botToken.
# Origin: hydra#974 moved the plaintext tokens to SecretRefs; a ref that fails to
# resolve leaves the account with botTokenSource != "config".

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/slack-probe.sh"
    D="$BATS_TEST_TMPDIR"
    echo '{"channels":{"slack":{"accounts":{"ceo":{},"cto":{}}}}}' > "$D/cfg.json"
}

status() { # status <ceo-src> <ceo-ok> <cto-src> <cto-ok>
    printf '{"channelAccounts":{"slack":[{"accountId":"ceo","botTokenSource":"%s","probe":{"ok":%s}},{"accountId":"cto","botTokenSource":"%s","probe":{"ok":%s}}]}}' "$1" "$2" "$3" "$4" > "$D/st.json"
}

@test "all accounts config+probe ok passes" {
    status config true config true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 0 ]; [ "${lines[-1]}" = "pass" ]
}

@test "MUTATION CONTROL: one account botTokenSource=none fails and names it" {
    status config true none true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]; [ "${lines[-1]}" = "fail" ]
    [[ "$output" == *"BAD: cto: botTokenSource=none"* ]]
}

@test "probe.ok=false fails even when the token source is config" {
    status config false config true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: ceo"* ]]
}

@test "account in config but missing from status fails" {
    echo '{"channelAccounts":{"slack":[{"accountId":"ceo","botTokenSource":"config","probe":{"ok":true}}]}}' > "$D/st.json"
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: cto: missing"* ]]
}

@test "account list comes from the config, not a hard-coded list" {
    echo '{"channels":{"slack":{"accounts":{"ceo":{},"cto":{},"newbot":{}}}}}' > "$D/cfg.json"
    status config true config true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: newbot: missing"* ]]
}

@test "empty status file is unreachable (2), not a resolution failure" {
    : > "$D/st.json"
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 2 ]; [ "${lines[-1]}" = "unreachable" ]
}

@test "non-JSON garbage is unreachable (2)" {
    echo 'gateway not reachable' > "$D/st.json"
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 2 ]; [ "${lines[-1]}" = "unreachable" ]
}

@test "botTokenSource=env stays a hard fail (1)" {
    status config true env true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]; [ "${lines[-1]}" = "fail" ]
}

@test "config with zero slack accounts fails rather than passing vacuously" {
    echo '{"channels":{"slack":{"accounts":{}}}}' > "$D/cfg.json"
    status config true config true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]
}

@test "output never contains token-looking values" {
    status config true none true
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [[ "$output" != *xoxb-* ]]
}

@test "real head config: every account id is covered by the check" {
    run slack_probe_verdict "${BATS_TEST_DIRNAME}/../../openclaw-main.json" /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" != *"cannot read slack accounts"* ]]
}

# ── dispatch: rc 0 pass / rc 1 fail / rc 2 warn (never a pass) ──

gate_with_rc() { # gate_with_rc <rc>
    pass_check() { echo "PASS:$*"; }
    warn_check() { echo "WARN:$*"; }
    fail_check() { echo "FAIL:$*"; }
    eval "slack_probe_run() { echo 'attempt 1: timeout after 30s'; return $1; }"
    slack_probe_gate /x
}

@test "gate: rc0 -> pass_check" {
    run gate_with_rc 0; [[ "${lines[0]}" == PASS:* ]]
}

@test "gate: rc1 -> fail_check (hard, rollback path), never warn" {
    run gate_with_rc 1; [[ "${lines[0]}" == FAIL:* ]]; [[ "$output" != *WARN:* ]]
}

@test "gate: rc2 -> warn_check naming the cause and that resolution was NOT verified" {
    run gate_with_rc 2
    [[ "${lines[0]}" == WARN:* ]]
    [[ "$output" == *"NOT verified"* ]]; [[ "$output" == *"timeout after 30s"* ]]
}

# ── wiring: smoke-test.sh must go through the three-arm gate ──

@test "smoke-test.sh calls slack_probe_gate against the deployed main config" {
    grep -q 'slack_probe_gate /opt/hydra/openclaw-main.json' "${BATS_TEST_DIRNAME}/../smoke-test.sh"
}

# ── slack_probe_run retries only a run that returned no JSON (2026-10-20) ──
fake_openclaw() { # fake_openclaw <answer-file-1> [<answer-file-2> ...]: one answer per call, last one repeats
    mkdir -p "$D/bin"; : > "$D/calls"
    local i=1 f
    for f in "$@"; do cp "$f" "$D/answer.$i"; i=$((i + 1)); done
    cat > "$D/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
n=$(( $(wc -l < "$D_DIR/calls") + 1 )); echo x >> "$D_DIR/calls"
f="$D_DIR/answer.$n"; [ -f "$f" ] || f=$(ls "$D_DIR"/answer.* | sort -t. -k2 -n | tail -1)
cat "$f"
STUB
    chmod +x "$D/bin/openclaw"
    export PATH="$D/bin:$PATH" D_DIR="$D" SLACK_PROBE_WAIT_SECS=0
}

@test "a gateway still restarting (no JSON) is retried until the probe answers, then passes" {
    echo 'Error: Opening handshake has timed out' > "$D/junk"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/junk" "$D/junk" "$D/good"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 0 ]; [ "${lines[-1]}" = "pass" ]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 3 ]
}

@test "MUTATION CONTROL: a real SecretRef failure (valid JSON, BAD row) is final at once, never retried" {
    status config true none true; cp "$D/st.json" "$D/bad"
    fake_openclaw "$D/bad"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: cto: botTokenSource=none"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 1 ]
}

@test "no JSON on every attempt is unreachable (2) after the budget, one cause line per attempt" {
    echo 'Error: Opening handshake has timed out' > "$D/junk"
    fake_openclaw "$D/junk"
    SLACK_PROBE_ATTEMPTS=3 run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 2 ]; [ "${lines[-1]}" = "unreachable" ]
    [[ "$output" == *"attempt 1: non-JSON (39 bytes)"* ]]; [[ "$output" == *"attempt 3:"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 3 ]
}

@test "stderr never leaks into the parsed stdout" {
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/good"
    printf '#!/usr/bin/env bash\necho "Config warnings: x" >&2\ncat "%s"\n' "$D/good" > "$D/bin/openclaw"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 0 ]; [ "${lines[-1]}" = "pass" ]
}

@test "empty probe output is retried" {
    : > "$D/empty"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/empty" "$D/good"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 0 ]; [ "${lines[-1]}" = "pass" ]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 2 ]
}

@test "JSON without Slack rows yet (gateway still registering Slack) is retried until rows appear" {
    echo '{"channelAccounts":{}}' > "$D/noslack"
    echo '{"channelAccounts":{"slack":[]}}' > "$D/emptyslack"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/noslack" "$D/emptyslack" "$D/good"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 0 ]; [ "${lines[-1]}" = "pass" ]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 3 ]
}

@test "JSON that never gets Slack rows still fails after the attempt budget" {
    echo '{"error":"x"}' > "$D/err"
    fake_openclaw "$D/err"
    SLACK_PROBE_ATTEMPTS=3 run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"no Slack accounts yet"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 3 ]
}

@test "MUTATION CONTROL: a malformed Slack row is final at once, never retried" {
    echo '{"channelAccounts":{"slack":[{"botTokenSource":"config"}]}}' > "$D/badrow"
    fake_openclaw "$D/badrow"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"not the expected JSON (KeyError)"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 1 ]
}

@test "18:36Z replay: 4 no-JSON answers, then JSON with no slack key, then rows -> passes" {
    echo 'Error: Opening handshake has timed out' > "$D/junk"
    echo '{"channelAccounts":{"telegram":[]}}' > "$D/noslackkey"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/junk" "$D/junk" "$D/junk" "$D/junk" "$D/noslackkey" "$D/good"
    unset SLACK_PROBE_ATTEMPTS
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 0 ]; [ "${lines[-1]}" = "pass" ]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 6 ]
}

@test "default attempt budget is 12 when SLACK_PROBE_ATTEMPTS is unset" {
    echo '{"channelAccounts":{}}' > "$D/noslack"
    fake_openclaw "$D/noslack"
    unset SLACK_PROBE_ATTEMPTS
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"no Slack accounts yet"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 12 ]
}

@test "MUTATION CONTROL: probe.ok=false row is final at once, never retried" {
    status config true config false; cp "$D/st.json" "$D/bad"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/bad" "$D/good"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: cto: botTokenSource=config probe.ok=False"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 1 ]
}

@test "MUTATION CONTROL: rows present but an account missing is final at once, never retried" {
    echo '{"channelAccounts":{"slack":[{"accountId":"ceo","botTokenSource":"config","probe":{"ok":true}}]}}' > "$D/partial"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/partial" "$D/good"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: cto: missing"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 1 ]
}

@test "MUTATION CONTROL: dropped token on a later attempt (after no-rows answers) is final" {
    echo '{"channelAccounts":{"slack":[]}}' > "$D/emptyslack"
    status config true none true; cp "$D/st.json" "$D/bad"
    status config true config true; cp "$D/st.json" "$D/good"
    fake_openclaw "$D/emptyslack" "$D/bad" "$D/good"
    run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [[ "$output" == *"BAD: cto: botTokenSource=none"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 2 ]
}

@test "MIXED SEQUENCE: no Slack rows, then the gateway goes unreachable -> hard fail (1), never a warn" {
    echo '{"error":"x"}' > "$D/noslack"
    echo 'Error: Opening handshake has timed out' > "$D/junk"
    fake_openclaw "$D/noslack" "$D/junk"
    SLACK_PROBE_ATTEMPTS=2 run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [ "${lines[-1]}" = "fail" ]
    [[ "$output" == *"no Slack accounts yet"* ]]; [[ "$output" == *"attempt 2: non-JSON"* ]]
    [ "$(wc -l < "$D/calls" | tr -d ' ')" -eq 2 ]
}

@test "MIXED SEQUENCE: unreachable, then no Slack rows -> hard fail (1) too (the verdict is order-independent)" {
    echo '{"error":"x"}' > "$D/noslack"
    echo 'Error: Opening handshake has timed out' > "$D/junk"
    fake_openclaw "$D/junk" "$D/noslack"
    SLACK_PROBE_ATTEMPTS=2 run slack_probe_run "$D/cfg.json"
    [ "$status" -eq 1 ]; [ "${lines[-1]}" = "fail" ]
}
