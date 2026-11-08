#!/usr/bin/env bats

# Jan's daily proof list (FirstMate ruling 1, 3 Nov): the 07:00Z tray build, then one DM to Jan.

bats_require_minimum_version 1.5.0

setup() {
    T="$(mktemp -d)"; export T
    SCRIPT="$BATS_TEST_DIRNAME/../credit-jan-tray-dm.sh"
    mkdir -p "$T/root"
    export JAN_TRAY_KILL_SWITCH="$T/root/disabled" JAN_TRAY_STATE_DIR="$T/root/state" JAN_TRAY_OUT_DIR="$T/root/out"
    export JAN_TRAY_PYTHON="$T/python" JAN_TRAY_VERIFY="$T/verify.py" JAN_TRAY_SLACK_LIB="$T/slack.sh"
    # python stub: records argv, writes STUB_ROWS (a count) rows into the proves file, or fails.
    cat > "$T/python" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$T/tray-calls"
[ "${STUB_TRAY_RC:-0}" = "0" ] || exit "$STUB_TRAY_RC"
out=""; batch=""
while [ $# -gt 0 ]; do case "$1" in --out-dir) out="$2"; shift ;; --batch) batch="$2"; shift ;; esac; shift; done
mkdir -p "$out"
jq -n --argjson n "${STUB_ROWS:-0}" --argjson new "${STUB_NEW:-0}" '[range(0; $new) | {user_id: 900, request_id: ("req-new" + tostring), role: "Producer", track: "New track", contributor: "New person", doc_type: "contract", issuer: "Label X", link: null, source_ref: null, intake_id: "intake-new"}] + [range(0; $n) | {user_id: (. + 100), request_id: ("req-" + tostring), role: "Producer", track: ("Track " + tostring), contributor: ("Person " + tostring), doc_type: "contract", issuer: "Label X", link: (if . % 2 == 0 then "https://docs.test/" + tostring else null end), source_ref: null, intake_id: ("intake-" + tostring)}]' > "$out/jan-proves-b$batch.json"
STUB
    chmod +x "$T/python"
    cat > "$T/slack.sh" <<'STUB'
slack_notify_payload_file_status() { n=0; [ ! -e "$T/sends" ] || n=$(wc -l < "$T/sends"); [ "$((n + 1))" != "${STUB_SLACK_FAIL_AT:-0}" ] || return 1; cp "$1" "$T/sent-$((n + 1)).json"; echo "$SLACK_NOTIFY_BOT" > "$T/bot"; echo x >> "$T/sends"; return "${STUB_SLACK_RC:-0}"; }
STUB
}
teardown() { rm -rf "$T"; }

sends() { if [ -e "$T/sends" ]; then wc -l < "$T/sends" | tr -d ' '; else echo 0; fi; }

@test "3 rows: one DM to Jan as the operations bot naming track, contributor, role and link" {
    STUB_ROWS=3 run -0 bash "$SCRIPT"
    [ "$output" = "NO_REPLY" ]
    [ "$(sends)" = "1" ]
    [ "$(jq -r .channel "$T/sent-1.json")" = "U038BM16T7W" ]
    [ "$(cat "$T/bot")" = "operations" ]
    txt="$(jq -r .text "$T/sent-1.json")"
    [[ "$txt" == *"Claims where the document proves it"*": 3."* ]]
    [[ "$txt" == *"decide it yourself in Muso admin, one at a time"* ]]
    for i in 0 1 2; do
        [[ "$txt" == *"Track $i"* && "$txt" == *"Person $i"* && "$txt" == *"req-$i"* ]]
    done
    [[ "$txt" == *"Producer"* && "$txt" == *"contract"* && "$txt" == *"Label X"* ]]
    [[ "$txt" == *"<https://docs.test/0|document>"* ]]
    [[ "$txt" == *"intake-1"* ]]   # no link: the filing id stands in
    grep -q -- "--batch $(date -u +%Y%m%d)" "$T/tray-calls"
    grep -q -- "--out-dir $JAN_TRAY_OUT_DIR" "$T/tray-calls"
}

@test "45 rows: 3 messages of at most 20 rows" {
    STUB_ROWS=45 run -0 bash "$SCRIPT"
    [ "$(sends)" = "3" ]
    [ "$(jq -r .text "$T/sent-1.json" | grep -c 'req-')" = "20" ]
    [ "$(jq -r .text "$T/sent-3.json" | grep -c 'req-')" = "5" ]
}

@test "more than 100 rows: first 100 sent, the rest counted" {
    STUB_ROWS=130 run -0 bash "$SCRIPT"
    [ "$(sends)" = "5" ]
    [[ "$(jq -r .text "$T/sent-5.json")" == *"30 more"* ]]
}

@test "more than 100 rows over two days: day two leads with the rows Jan has not been sent" {
    JAN_TRAY_DAY=20261101 STUB_ROWS=130 run -0 bash "$SCRIPT"
    [ "$(sends)" = "5" ]
    JAN_TRAY_DAY=20261102 STUB_ROWS=130 run -0 bash "$SCRIPT"
    [ "$(sends)" = "10" ]
    day2="$(for i in 6 7 8 9 10; do jq -r .text "$T/sent-$i.json"; done)"
    [[ "$day2" == *"req-100"* && "$day2" == *"req-129"* ]]
    first="$(jq -r .text "$T/sent-6.json")"
    [[ "$first" == *"req-100"* ]]
}

@test "retry after a half-delivered list resumes the same list; a claim added meanwhile comes next day" {
    STUB_ROWS=45 STUB_SLACK_FAIL_AT=2 run -1 bash "$SCRIPT"
    [ "$(sends)" = "1" ]
    STUB_ROWS=45 STUB_NEW=1 run -0 bash "$SCRIPT"
    [ "$(sends)" = "3" ]
    [ "$(wc -l < "$T/tray-calls" | tr -d ' ')" = "1" ]
    rest="$(jq -r .text "$T/sent-2.json"; jq -r .text "$T/sent-3.json")"
    [[ "$rest" == *"req-20"* && "$rest" == *"req-44"* && "$rest" != *"req-new0"* ]]
    JAN_TRAY_DAY=20991231 STUB_ROWS=45 STUB_NEW=1 run -0 bash "$SCRIPT"
    [[ "$(jq -r .text "$T/sent-4.json")" == *"req-new0"* ]]
}

@test "0 rows: one short nothing-to-review DM so Jan knows the list ran" {
    STUB_ROWS=0 run -0 bash "$SCRIPT"
    [ "$(sends)" = "1" ]
    [[ "$(jq -r .text "$T/sent-1.json")" == *"nothing to review today"* ]]
}

@test "tray build fails: no DM, exit 1, one line, no empty nothing-today" {
    STUB_TRAY_RC=3 run -1 bash "$SCRIPT"
    [ "$(sends)" = "0" ]
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
    [[ "$output" == *"NOT sent"* ]]
}

@test "unreadable list after a good build is a failure, not nothing-today" {
    cat > "$T/python" <<'STUB'
#!/usr/bin/env bash
out=""; batch=""
while [ $# -gt 0 ]; do case "$1" in --out-dir) out="$2"; shift ;; --batch) batch="$2"; shift ;; esac; shift; done
echo 'not json' > "$out/jan-proves-b$batch.json"
STUB
    run -1 bash "$SCRIPT"
    [ "$(sends)" = "0" ]
    [[ "$output" == *"cannot be read"* ]]
}

@test "a failed Slack send is loud and is retried (no marker)" {
    STUB_ROWS=2 STUB_SLACK_RC=1 run -1 bash "$SCRIPT"
    [[ "$output" == *"Slack did not confirm"* ]]
    STUB_ROWS=2 run -0 bash "$SCRIPT"
    [ "$(sends)" = "2" ]
}

@test "second run the same UTC day sends nothing and does not rebuild" {
    STUB_ROWS=3 run -0 bash "$SCRIPT"
    STUB_ROWS=3 run -0 bash "$SCRIPT"
    [ "$output" = "NO_REPLY" ]
    [ "$(sends)" = "1" ]
    [ "$(wc -l < "$T/tray-calls" | tr -d ' ')" = "1" ]
}

@test "overlapping runs send exactly one DM" {
    STUB_ROWS=3 bash "$SCRIPT" > "$T/o1" & p1=$!
    STUB_ROWS=3 bash "$SCRIPT" > "$T/o2" & p2=$!
    # Explicit pids, never a bare `wait` (bats' BATS_TEST_TIMEOUT watchdog is a child too).
    wait "$p1" "$p2" || true   # asserts on files, not the child's status
    [ "$(sends)" = "1" ]
}

@test "kill switch: tray not run, nothing sent" {
    : > "$JAN_TRAY_KILL_SWITCH"
    STUB_ROWS=3 run -0 bash "$SCRIPT"
    [ "$output" = "NO_REPLY" ]
    [ ! -e "$T/tray-calls" ]
    [ "$(sends)" = "0" ]
}

@test "writes only inside the out dir and the state dir" {
    mkdir -p "$T/root"; touch "$T/root/keep"
    before="$(find "$T" -not -path "$T/root/out*" -not -path "$T/root/state*" | sort)"
    STUB_ROWS=3 run -0 bash "$SCRIPT"
    after="$(find "$T" -not -path "$T/root/out*" -not -path "$T/root/state*" -not -name 'sent-*.json' -not -name sends -not -name bot -not -name tray-calls -not -name 'o[12]' | sort)"
    [ "$before" = "$after" ]
    [ -e "$JAN_TRAY_OUT_DIR/jan-proves-b$(date -u +%Y%m%d).json" ] && [ -d "$JAN_TRAY_STATE_DIR" ]
}

@test "the DM never claims anything was approved and uses no tool words" {
    STUB_ROWS=3 run -0 bash "$SCRIPT"
    txt="$(jq -r .text "$T/sent-1.json")"
    [[ "$txt" != *"approved"* ]]
    ! grep -qiE 'tray|sqlite|script|api|error|ticket' <<< "$txt"
}

@test "cron-jobs.json: 07:00 UTC entry runs the script, read-only wording, runbook linked" {
    J="$BATS_TEST_DIRNAME/../../cron-jobs.json"
    run -0 jq -e '.jobs[] | select(.name == "credit-jan-tray-0700")
        | .schedule.expr == "0 7 * * *" and .schedule.tz == "UTC" and .enabled == true
        and .agentId == "operations" and .delivery.mode == "none" and .payload.kind == "command"
        and .payload.argv == ["bash", "/opt/hydra/scripts/credit-jan-tray-dm.sh"]
        and (.description | test("credit-jan-tray-dm.disabled") and test("docs/credit-verification/jan-daily-proof-list.md"))' "$J"
    [ "$(jq '[.jobs[].id] | length - (unique | length)' "$J")" = "0" ]
}
