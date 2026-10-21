#!/usr/bin/env bats

# credit gate #7 (firstmate 081): the 08:00 NY DM of the board's digest to Jan.

bats_require_minimum_version 1.5.0

setup() {
    T="$(mktemp -d)"; export T
    SCRIPT="$BATS_TEST_DIRNAME/../credit-digest-dm.sh"
    export CREDIT_DIGEST_ENV="$T/board.env" CREDIT_DIGEST_KILL_SWITCH="$T/disabled" CREDIT_DIGEST_STATE_DIR="$T/state"
    export CREDIT_DIGEST_BOARD_HOST="board.test" CREDIT_DIGEST_BOARD_IP="127.0.0.1" CREDIT_DIGEST_CURL="$T/curl" CREDIT_DIGEST_SLACK_LIB="$T/slack.sh"
    printf 'CREDIT_TRUST_BOARD_AGENT_TOKEN=s3cret-token\n' > "$CREDIT_DIGEST_ENV"
    # curl stub: writes STUB_BODY to -o, prints STUB_CODE, records its args (never the token value).
    cat > "$T/curl" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -H) cat "${2#@}" >> "$T/hdrs" ;; http*) echo "$1" >> "$T/urls" ;; esac; shift; done
printf '%s' "${STUB_BODY:-}" > "$out"; printf '%s' "${STUB_CODE:-200}"
STUB
    chmod +x "$T/curl"
    cat > "$T/slack.sh" <<'STUB'
slack_notify_payload_file_status() { sleep "${STUB_SLACK_DELAY:-0}"; cp "$1" "$T/sent.json"; echo "$SLACK_NOTIFY_BOT" > "$T/bot"; echo x >> "$T/sends"; return "${STUB_SLACK_RC:-0}"; }
STUB
}
teardown() { rm -rf "$T"; }

DIGEST='{"text":"Ops-agent credit decisions: 3 approvals","blocks":[{"type":"section","text":{"type":"mrkdwn","text":"x"}}]}'

@test "a digest is DMed to Jan as the operations bot, once per New York day" {
    STUB_BODY="$DIGEST" run -0 bash "$SCRIPT"
    [ "$output" = "NO_REPLY" ]
    [ "$(jq -r .channel "$T/sent.json")" = "U038BM16T7W" ]
    [ "$(jq -r '.blocks | length' "$T/sent.json")" = "1" ]
    [ "$(cat "$T/bot")" = "operations" ]
    grep -q '^X-Credit-Trust-Token: s3cret-token$' "$T/hdrs"
    grep -q '/api/digest/slack?date=' "$T/urls"
    rm -f "$T/sent.json"
    STUB_BODY="$DIGEST" run -0 bash "$SCRIPT"
    [ ! -e "$T/sent.json" ]
}

@test "waiting_for_data (no ledger yet) sends nothing and is not a failure" {
    STUB_CODE=503 STUB_BODY='{"error":"waiting_for_data"}' run -0 bash "$SCRIPT"
    [ "$output" = "NO_REPLY" ]
    [ ! -e "$T/sent.json" ]
    [ -z "$(ls "$T/state")" ]
}

@test "failures are loud and never leak the token; a failed DM is retried next run" {
    STUB_CODE=500 STUB_BODY='{}' run -1 bash "$SCRIPT"
    [[ "$output" == *"NOT sent: board answered HTTP 500"* ]]
    STUB_BODY='{"text":"x","blocks":[]}' run -1 bash "$SCRIPT"
    [[ "$output" == *"no text/blocks"* ]]
    STUB_SLACK_RC=1 STUB_BODY="$DIGEST" run -1 bash "$SCRIPT"
    [[ "$output" == *"Slack did not confirm"* ]]
    [ -z "$(ls "$T/state")" ]
    : > "$CREDIT_DIGEST_ENV"
    run -1 bash "$SCRIPT"
    [[ "$output" == *"CREDIT_TRUST_BOARD_AGENT_TOKEN is empty"* ]]
    [[ "$output" != *"s3cret"* ]]
    rm -f "$CREDIT_DIGEST_ENV"
    run -1 bash "$SCRIPT"
    [[ "$output" == *"token file"*"missing"* ]]
}

@test "kill switch: nothing fetched, nothing sent" {
    : > "$CREDIT_DIGEST_KILL_SWITCH"
    STUB_BODY="$DIGEST" run -0 bash "$SCRIPT"
    [ "$output" = "NO_REPLY" ]
    [ ! -e "$T/urls" ]
}

@test "overlapping runs send exactly one DM for the day" {
    STUB_BODY="$DIGEST" STUB_SLACK_DELAY=2 bash "$SCRIPT" > "$T/o1" &
    STUB_BODY="$DIGEST" STUB_SLACK_DELAY=2 bash "$SCRIPT" > "$T/o2" &
    wait
    [ "$(wc -l < "$T/sends" | tr -d ' ')" = "1" ]
    [ "$(cat "$T/o1")" = "NO_REPLY" ] && [ "$(cat "$T/o2")" = "NO_REPLY" ]
}
