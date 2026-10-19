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

@test "non-JSON and empty status output fail" {
    echo 'gateway not reachable' > "$D/st.json"
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]
    : > "$D/st.json"
    run slack_probe_verdict "$D/cfg.json" "$D/st.json"
    [ "$status" -eq 1 ]
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
    [ "$status" -eq 1 ]
    [[ "$output" != *"cannot read slack accounts"* ]]
}

# ── wiring: the gate must be HARD in smoke-test.sh (Step 7 → deploy fail → rollback) ──

@test "smoke-test.sh runs slack_probe_run against the deployed main config and hard-fails" {
    S="${BATS_TEST_DIRNAME}/../smoke-test.sh"
    grep -q 'slack_probe_run /opt/hydra/openclaw-main.json' "$S"
    run grep -A5 'slack_probe_run /opt/hydra/openclaw-main.json' "$S"
    [[ "$output" == *"fail_check"* ]]
    [[ "$output" != *"warn_check"* ]]
}
