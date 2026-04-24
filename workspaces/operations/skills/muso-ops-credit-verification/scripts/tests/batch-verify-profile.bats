#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for batch-verify-profile.sh — the per-profile evidence pre-flight
# dispatcher that R3 adds so the agent's workflow is structurally forced
# into per-profile browser-evidence gathering before approves reach the
# gate. Covers arg validation, contamination short-circuit, evidence quorum
# with remediation, and delegate wiring for approve + flag paths.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    WRAPPER="${BATS_TEST_DIRNAME}/../batch-verify-profile.sh"
    [[ -x "$WRAPPER" ]] || { echo "WRAPPER missing or not executable: $WRAPPER" >&2; return 1; }

    # Point session discovery at a test fixture via CV_SESSION_LOG_OVERRIDE.
    SESSION_LOG="$TEST_ROOT/session.jsonl"
    : > "$SESSION_LOG"
    export CV_SESSION_LOG_OVERRIDE="$SESSION_LOG"

    # Truth-floor path (prevents the wrapper's pre-flight-rejection writes
    # from touching /var/log in tests) and an RUN_ID so it doesn't log as
    # run_id=unknown.
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    : > "$CV_RESULTS_PATH"
    export OPS_RUN_ID="20260423-120000-aaaaaa"

    # Real session-evidence.sh (the wrapper shells it out for the
    # --check-tier1-webfetch step). It honors CV_SESSION_LOG_OVERRIDE too.
    export SESSION_EVIDENCE_SH="${BATS_TEST_DIRNAME}/../session-evidence.sh"

    # Stub delegates. Controlled by $APPROVE_MODE / $FLAG_MODE, with a log of
    # every invocation for later assertions.
    APPROVE_LOG="$TEST_ROOT/approve-invocations.log"
    FLAG_LOG="$TEST_ROOT/flag-invocations.log"
    export APPROVE_LOG FLAG_LOG

    export BATCH_APPROVE_SH="$TEST_ROOT/fake-batch-approve.sh"
    cat > "$BATCH_APPROVE_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n'; } >> "${APPROVE_LOG:-/dev/null}"
case "${APPROVE_MODE:-ok}" in
    ok)      echo '{"profile_id":"p1","requested":2,"outcome":"dry_run_intercept","http_status":200}'; exit 0 ;;
    gate)    echo "credit_approve_gate: insufficient grounded evidence" >&2; exit 1 ;;
    http5xx) echo '{"profile_id":"p1","requested":2,"outcome":"http_error","http_status":500}'; exit 1 ;;
    *)       echo "unknown APPROVE_MODE=${APPROVE_MODE}" >&2; exit 99 ;;
esac
STUB
    chmod +x "$BATCH_APPROVE_SH"

    export BATCH_FLAG_SH="$TEST_ROOT/fake-batch-flag.sh"
    cat > "$BATCH_FLAG_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n'; } >> "${FLAG_LOG:-/dev/null}"
case "${FLAG_MODE:-ok}" in
    ok)      echo '{"profile_id":"p1","requested":3,"succeeded":3,"failed":0,"failed_ids":[],"outcome":"ok"}'; exit 0 ;;
    partial) echo '{"profile_id":"p1","requested":3,"succeeded":2,"failed":1,"failed_ids":["cr_3"],"outcome":"partial_failure"}'; exit 1 ;;
    *)       echo "unknown FLAG_MODE=${FLAG_MODE}" >&2; exit 99 ;;
esac
STUB
    chmod +x "$BATCH_FLAG_SH"

    export CV_REQUIRED_LOADS=2
    export CV_SESSION_MAX_AGE_MIN=10
    unset OPS_RUNLOG_DIR CV_SESSION_RUN_STARTED_TS
}

teardown() { rm -rf "$TEST_ROOT"; }

# --- Fixture helpers ---------------------------------------------------------

seed_browser_toolcall_ok() {
    # args: call_id url result_text
    local id="$1" url="$2" text="$3"
    printf '%s\n' "$(jq -n -c --arg id "$id" --arg url "$url" \
        '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"browser",arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg id "$id" --arg text "$text" \
        '{message:{role:"toolResult",toolCallId:$id,isError:false,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

seed_webfetch_tier1() {
    # args: call_id url
    local id="$1" url="$2"
    printf '%s\n' "$(jq -n -c --arg id "$id" --arg url "$url" \
        '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"web_fetch",arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg id "$id" \
        '{message:{role:"toolResult",toolCallId:$id,isError:false,content:[{type:"text",text:"fetched"}]}}')" >> "$SESSION_LOG"
}

# --- Argument validation (exit 2, no side effects) ---------------------------

@test "missing --profile-id → exit 2" {
    run bash "$WRAPPER" --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--profile-id is required"* ]]
    [ ! -f "$APPROVE_LOG" ] && [ ! -f "$FLAG_LOG" ]
}

@test "missing --evidence-excerpt → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "--evidence-excerpt too short → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "short" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *">=8"* ]] || [[ "$output" == *">="* ]]
}

@test "--evidence-excerpt too long → exit 2" {
    local long_excerpt
    long_excerpt=$(printf 'x%.0s' {1..250})
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "$long_excerpt" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"<=200"* ]] || [[ "$output" == *"<="* ]]
}

@test "missing --ids → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Ben Smith bass" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ids is required"* ]]
}

@test "missing --decision → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--decision is required"* ]]
}

@test "invalid --decision value → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision escalate
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be 'approve' or 'flag'"* ]]
}

@test "--decision flag without --reason → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"--reason is required"* ]]
}

@test "--requester is refused → exit 2 with human-override guidance" {
    run bash "$WRAPPER" --requester aaron@muso.ai --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--requester is forbidden"* ]]
    [[ "$output" == *"muso-admin-api.sh"* ]]
}

@test "unknown flag → exit 2" {
    run bash "$WRAPPER" --nope foo --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

# --- Flag path — no evidence gate, delegate to batch-flag-credits.sh ---------

@test "flag decision delegates to batch-flag-credits.sh without evidence check" {
    # Even with an empty session log, flag should go through (UVN ungated).
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "placeholder text" \
        --ids "cr_1,cr_2,cr_3" --decision flag --reason "high_velocity"
    [ "$status" -eq 0 ]
    # Stdout: the wrapper's summary, not delegate's.
    echo "$output" | jq -e '.decision == "flag" and .pre_flight == "ok" and .delegate_exit == 0'
    echo "$output" | jq -e '(.ids | length) == 3'
    [ -f "$FLAG_LOG" ]
    [[ "$(cat "$FLAG_LOG")" == *"--profile-id"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"--reason"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"high_velocity"* ]]
    # Approve delegate must NOT be called.
    [ ! -f "$APPROVE_LOG" ]
}

@test "flag delegate failure → exit 1, pre_flight still 'ok'" {
    FLAG_MODE=partial run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "placeholder text" \
        --ids "cr_1,cr_2,cr_3" --decision flag --reason "unverifiable"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.decision == "flag" and .pre_flight == "ok" and .delegate_exit == 1'
}

# --- Approve path — contamination check ---------------------------------------

@test "approve: Tier-1 web_fetch in session → exit 3, pre_flight=web_fetch_tier1, no delegate" {
    seed_webfetch_tier1 "wf" "https://open.spotify.com/artist/bad"
    run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    # stderr surfaces the contamination message.
    [[ "$stderr" == *"open.spotify.com"* ]]
    echo "$output" | jq -e '.pre_flight == "web_fetch_tier1" and .delegate_exit == null'
    [ ! -f "$APPROVE_LOG" ]
}

# --- Approve path — evidence quorum + remediation -----------------------------

@test "approve: 0 Tier-1 hostnames match → exit 3 with remediation text" {
    # Empty session — no browser loads at all.
    run --separate-stderr bash "$WRAPPER" --profile-id abc-profile-123 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1,cr_2" --decision approve
    [ "$status" -eq 3 ]
    echo "$output" | jq -e '.pre_flight == "missing_evidence" and .delegate_exit == null'
    [[ "$stderr" == *"0/2"* ]]
    # Remediation text names suggested Tier-1 URLs.
    [[ "$stderr" == *"open.spotify.com/artist/abc-profile-123"* ]]
    [[ "$stderr" == *"allmusic.com"* ]]
    [[ "$stderr" == *"musicbrainz.org"* ]]
    # And shows the exact retry command.
    [[ "$stderr" == *"batch-verify-profile.sh --profile-id 'abc-profile-123'"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

@test "approve: 1 of 2 Tier-1 matches → exit 3, lists currently-matching host" {
    # Excerpt appears on Spotify only; allmusic has no matching text.
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass plays on the record"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"     "No results found for your query"
    run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
    [[ "$stderr" == *"open.spotify.com"* ]]
    echo "$output" | jq -e '.pre_flight == "missing_evidence"'
    [ ! -f "$APPROVE_LOG" ]
}

@test "approve: 2 Tier-1 hostnames match → delegate called, exit 0" {
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass credits"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on this record"
    run bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1,cr_2" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 0'
    [ -f "$APPROVE_LOG" ]
    [[ "$(cat "$APPROVE_LOG")" == *"--evidence-excerpt"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"Ben Smith bass"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"cr_1,cr_2"* ]]
}

@test "approve: case-insensitive excerpt match (upper/lower both count)" {
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "BEN SMITH is credited"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "ben smith discography"
    run bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.delegate_exit == 0'
}

@test "approve: non-Tier-1 browser load with excerpt does NOT count" {
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://hoborec.com/artist/x"        "Ben Smith bass credits"
    run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
}

@test "approve: two loads of the SAME Tier-1 hostname count as 1 (dedup)" {
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://open.spotify.com/artist/p2" "Ben Smith bass on record"
    run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
}

# --- Approve path — delegate propagation --------------------------------------

@test "approve: delegate gate rejection → exit 1, pre_flight='ok', delegate_exit=1" {
    # Pre-flight passes locally but delegate returns non-zero (e.g. the gate
    # tripped on run_started scoping after our pre-flight's snapshot). The
    # wrapper must propagate the failure honestly AND forward delegate stderr.
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    APPROVE_MODE=gate run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 1'
    # Delegate's stderr must surface to the agent transcript.
    [[ "$stderr" == *"credit_approve_gate"* ]]
}

@test "approve: delegate HTTP 5xx → exit 1" {
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    APPROVE_MODE=http5xx run bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.delegate_exit == 1'
}

# --- IDs + summary shape ------------------------------------------------------

@test "summary JSON: ids split correctly, whitespace-trimmed" {
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    run bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1, cr_2 , cr_3" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.ids == ["cr_1","cr_2","cr_3"]'
}

# --- R3-3 interaction: run_started scoping -----------------------------------

@test "approve: old Tier-1 load (pre-run_started) does NOT count toward quorum" {
    # Simulate yesterday's session still in the same file with a real ts,
    # alongside a single new Tier-1 load. Without scoping, agent has 2
    # matches and wrapper would approve; with scoping, only the new one
    # counts → 1/2 → exit 3.
    # Use timestamped fixtures (R3-3 filter).
    local old_ts="2026-04-22T10:00:00Z"
    local new_ts="2026-04-23T12:00:00Z"
    printf '%s\n' "$(jq -n -c --arg ts "$old_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"old-b",name:"browser",arguments:{url:"https://musicbrainz.org/artist/abc"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$old_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"old-b",isError:false,content:[{type:"text",text:"Ben Smith bass engineer credits"}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"new-b",name:"browser",arguments:{url:"https://open.spotify.com/artist/p1"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"new-b",isError:false,content:[{type:"text",text:"Ben Smith bass on record"}]}}')" >> "$SESSION_LOG"

    # Seed a runlog with run_started between the two timestamps.
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-23"
    local log_path="$OPS_RUNLOG_DIR/2026-04-23/20260423-120000-aaaaaa.jsonl"
    jq -n -c '{event:"run_started", run_id:"20260423-120000-aaaaaa", ts:"2026-04-23T11:00:00Z", fetch_size:500}' > "$log_path"
    echo "$log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

# --- R3-final: truth-floor writes for pre-flight rejections ------------------
#
# When pre-flight fails we short-circuit BEFORE muso-admin-api.sh runs, so the
# admin-api truth floor never sees the attempt. The wrapper writes its own
# rejected_pre_flight row into .results.jsonl so compute-run-summary.sh can
# bucket these separately from gate rejections in the batch reconciliation.

count_lines() { awk 'END{print NR}' "$1" 2>/dev/null || echo 0; }

@test "truth-floor: pre-flight missing_evidence writes rejected_pre_flight row" {
    run --separate-stderr bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_a,cr_b" --decision approve
    [ "$status" -eq 3 ]
    # Exactly one row, outcome=rejected_pre_flight, pre_flight=missing_evidence,
    # request_ids matches the --ids arg.
    [ "$(count_lines "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "rejected_pre_flight"' "$CV_RESULTS_PATH"
    jq -e '.pre_flight == "missing_evidence"' "$CV_RESULTS_PATH"
    jq -e '.request_ids == ["cr_a","cr_b"]' "$CV_RESULTS_PATH"
    jq -e '.intended_status == "approved"' "$CV_RESULTS_PATH"
    jq -e '.profile_id == "p1"' "$CV_RESULTS_PATH"
    jq -e '.run_id == "20260423-120000-aaaaaa"' "$CV_RESULTS_PATH"
}

@test "truth-floor: Tier-1 web_fetch contamination writes rejected_pre_flight row" {
    seed_webfetch_tier1 "wf" "https://open.spotify.com/artist/bad"
    run --separate-stderr bash "$WRAPPER" --profile-id p2 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_x" --decision approve
    [ "$status" -eq 3 ]
    jq -e '.outcome == "rejected_pre_flight"' "$CV_RESULTS_PATH"
    jq -e '.pre_flight == "web_fetch_tier1"' "$CV_RESULTS_PATH"
    jq -e '.profile_id == "p2"' "$CV_RESULTS_PATH"
}

@test "truth-floor: approve pass-through does NOT write a pre-flight row (delegate owns the write)" {
    # When pre-flight passes, the wrapper delegates to batch-approve-credits.sh,
    # which is what invokes muso-admin-api.sh's truth-floor writer. The wrapper
    # must not double-write — .results.jsonl stays untouched by the wrapper.
    seed_browser_toolcall_ok "b1" "https://open.spotify.com/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    run bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    # Test stub doesn't write to CV_RESULTS_PATH; wrapper must not either.
    [ "$(count_lines "$CV_RESULTS_PATH")" -eq 0 ]
}

@test "truth-floor: flag path does not write pre-flight row (ungated, no pre-flight)" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "placeholder text" \
        --ids "cr_1,cr_2" --decision flag --reason "high_velocity"
    [ "$status" -eq 0 ]
    [ "$(count_lines "$CV_RESULTS_PATH")" -eq 0 ]
}

@test "approve: run_started scoping ignores yesterday's Tier-1 web_fetch" {
    # Yesterday's contamination should not block today's pre-flight.
    local old_ts="2026-04-22T10:00:00Z"
    local new_ts="2026-04-23T12:00:00Z"
    printf '%s\n' "$(jq -n -c --arg ts "$old_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"old-wf",name:"web_fetch",arguments:{url:"https://open.spotify.com/artist/contaminated"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$old_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"old-wf",isError:false,content:[{type:"text",text:"yesterday"}]}}')" >> "$SESSION_LOG"
    # New Tier-1 browser loads that justify approve.
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"new-b1",name:"browser",arguments:{url:"https://open.spotify.com/artist/p1"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"new-b1",isError:false,content:[{type:"text",text:"Ben Smith bass"}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"new-b2",name:"browser",arguments:{url:"https://allmusic.com/artist/x"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"new-b2",isError:false,content:[{type:"text",text:"Ben Smith bass on record"}]}}')" >> "$SESSION_LOG"

    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-23"
    local log_path="$OPS_RUNLOG_DIR/2026-04-23/20260423-120000-bbbbbb.jsonl"
    jq -n -c '{event:"run_started", run_id:"20260423-120000-bbbbbb", ts:"2026-04-23T11:00:00Z", fetch_size:500}' > "$log_path"
    echo "$log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    run bash "$WRAPPER" --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok"'
    [ -f "$APPROVE_LOG" ]
}
