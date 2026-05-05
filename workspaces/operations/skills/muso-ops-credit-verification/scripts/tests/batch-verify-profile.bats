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

# --- Wrapper-invocation helper -----------------------------------------------
# Most tests don't care about the claim metadata args (--credited-name,
# --track-title, --role) introduced in PR #233. They want to test gates,
# delegate wiring, etc. — claim metadata defaults are fine. This helper
# prepends sensible defaults so existing test patterns survive the new
# required-arg validation. Tests that specifically exercise the new args'
# validation invoke `bash "$WRAPPER" ...` directly without the helper.
#
# Defaults are chosen so the existing "Ben Smith bass" excerpt structurally
# proves the claim under the approve rule (excerpt contains credited_name
# AND role token), keeping the bulk of the suite green without per-test
# rewrites.
DEFAULT_CREDITED_NAME="Ben Smith"
DEFAULT_TRACK_TITLE="The Test Track"
DEFAULT_ROLE="bass"

run_w() {
    bash "$WRAPPER" \
        --credited-name "${CREDITED_NAME_OVERRIDE:-$DEFAULT_CREDITED_NAME}" \
        --track-title  "${TRACK_TITLE_OVERRIDE:-$DEFAULT_TRACK_TITLE}" \
        --role         "${ROLE_OVERRIDE:-$DEFAULT_ROLE}" \
        "$@"
}

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
    run run_w --profile-id p1 --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "--evidence-excerpt too short → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "short" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *">=8"* ]] || [[ "$output" == *">="* ]]
}

@test "--evidence-excerpt too long → exit 2" {
    local long_excerpt
    long_excerpt=$(printf 'x%.0s' {1..250})
    run run_w --profile-id p1 --evidence-excerpt "$long_excerpt" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"<=200"* ]] || [[ "$output" == *"<="* ]]
}

@test "missing --ids → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ids is required"* ]]
}

@test "missing --decision → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--decision is required"* ]]
}

@test "invalid --decision value → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision escalate
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be 'approve' or 'flag'"* ]]
}

@test "--decision flag without --reason → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"--reason is required"* ]]
}

@test "--decision flag without --flag-reason → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision flag --reason "looks suspicious"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--flag-reason is required"* ]]
}

@test "--decision flag with invalid --flag-reason → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision flag --reason "x" --flag-reason looks_off
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a valid enum value"* ]]
}

@test "placeholder --evidence-excerpt rejected on flag (deny-list) → exit 2" {
    # The 2026-04-30 audit shape: agent passes --evidence-excerpt "batch
    # conservative review" with --decision flag. Now blocked at arg validation.
    run run_w --profile-id p1 --evidence-excerpt "batch conservative review" --ids "cr_1" --decision flag --reason "x" --flag-reason name_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *"placeholder deny-list"* ]]
    [ ! -f "$FLAG_LOG" ]
}

@test "placeholder --evidence-excerpt rejected on approve (deny-list) → exit 2" {
    run run_w --profile-id p1 --evidence-excerpt "no evidence" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"placeholder deny-list"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

@test "placeholder deny-list is case-insensitive + trim-tolerant" {
    # Mixed case with leading/trailing whitespace must still match.
    run run_w --profile-id p1 --evidence-excerpt "  BATCH CONSERVATIVE REVIEW  " --ids "cr_1" --decision flag --reason "x" --flag-reason name_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *"placeholder deny-list"* ]]
}

@test "placeholder deny-list does NOT false-positive on real artist names" {
    # 'Pau Romero' is a 2-token name from a real flagged credit on 2026-04-30.
    # Earlier draft considered a token-count<=2 heuristic; this test guards
    # against re-introducing it. Reframed as approve so the structural rule
    # passes (name + role both present in the excerpt).
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero songwriter credits"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Pau Romero songwriter on Yellow Submarine"
    CREDITED_NAME_OVERRIDE="Pau Romero" ROLE_OVERRIDE="songwriter" TRACK_TITLE_OVERRIDE="Yellow Submarine" \
        run run_w --profile-id p1 --evidence-excerpt "Pau Romero songwriter" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
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

# --- Browse-required gate (PR #232, applies to BOTH approve and flag) -------
# Why this gate: runs 20260430-111343-1605a8 + 20260430-130332-c1f8f9 each
# hit the API 460-500 times with exactly 1 browser call across the entire
# run. The agent applied a template decision per credit without browsing
# per profile. This gate makes ≥1 successful browser load whose URL
# contains the dispatched profile_id a hard prerequisite for any decision.

@test "browse-required: empty session → exit 5 (missing_profile_browse) on approve" {
    run --separate-stderr run_w --profile-id abc-profile-123 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 5 ]
    echo "$output" | jq -e '.pre_flight == "missing_profile_browse" and .delegate_exit == null'
    # Remediation suggests opening the profile's primary Tier-1 page.
    [[ "$stderr" == *"musicbrainz.org/search?query="* ]]
    [[ "$stderr" == *"BORDERLINE"* ]] || [[ "$stderr" == *"conservative batch review"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

@test "browse-required: empty session → exit 5 on flag too" {
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Pau Romero" --ids "cr_1" --decision flag \
        --reason "name not on Tier-1" --flag-reason name_mismatch
    [ "$status" -eq 5 ]
    echo "$output" | jq -e '.pre_flight == "missing_profile_browse" and .delegate_exit == null'
    [ ! -f "$FLAG_LOG" ]
}

@test "browse-required: load whose claim metadata mismatches the dispatch claim → exit 5" {
    # Most likely shortcut once the gate ships: agent browses one credit's
    # page, then dispatches a different credit reusing whatever excerpt
    # appeared. The new gate rejects when the response text doesn't mention
    # the dispatched credit's name+role/track. Here we seed a Tier-1 page
    # for a different person ("Other Person") and dispatch for "Pau Romero"
    # — the seed text doesn't match the dispatch claim, so per-profile
    # browse fails.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/abc-123" "Other Person songwriter credits"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id xyz-789 \
        --evidence-excerpt "Pau Romero songwriter" --ids "cr_1" --decision flag \
        --reason "name not on Tier-1 for xyz-789" --flag-reason name_mismatch
    [ "$status" -eq 5 ]
    echo "$output" | jq -e '.pre_flight == "missing_profile_browse"'
    [[ "$stderr" == *"xyz-789"* ]]
    [ ! -f "$FLAG_LOG" ]
}

@test "browse-required: non-Tier-1 load does NOT satisfy the gate" {
    # 2026-05-04 refactor: browse-required dropped the muso.ai/profile/<uuid>
    # anchor. Only Tier-1 hosts whose response text mentions credited_name +
    # (track or role) count toward the per-profile gate. A muso.ai load is
    # not Tier-1 and therefore doesn't count.
    seed_browser_toolcall_ok "b0" "https://muso.ai/profile/p1" "internal page text Pau Romero songwriter Yellow Submarine"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter section" --ids "cr_1" --decision flag \
        --reason "x" --flag-reason name_mismatch
    [ "$status" -eq 5 ]
    echo "$output" | jq -e '.pre_flight == "missing_profile_browse"'
}

@test "browse-required: failed browser load (isError=true) does NOT count" {
    # An errored toolResult means the page didn't actually load — agent
    # didn't see anything. Same definition as session-evidence.sh's count_ok.
    printf '%s\n' "$(jq -n -c '{message:{role:"assistant",content:[{type:"toolCall",id:"x",name:"browser",arguments:{url:"https://musicbrainz.org/artist/p1"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c '{message:{role:"toolResult",toolCallId:"x",isError:true,content:[{type:"text",text:"navigation timeout"}]}}')" >> "$SESSION_LOG"
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Pau Romero" --ids "cr_1" --decision flag \
        --reason "x" --flag-reason name_mismatch
    [ "$status" -eq 5 ]
    echo "$output" | jq -e '.pre_flight == "missing_profile_browse"'
}

@test "browse-required: env override CV_REQUIRED_PROFILE_BROWSE=0 disables gate" {
    # Empty session, but bypass via env — gate doesn't fire and we land on
    # the missing_evidence (excerpt-quorum) path with exit 3.
    CV_REQUIRED_PROFILE_BROWSE=0 run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    echo "$output" | jq -e '.pre_flight == "missing_evidence"'
}

@test "browse-required: pre-flight rejection writes rejected_pre_flight row" {
    # Truth-floor row with pre_flight=missing_profile_browse, intended_status
    # reflects the decision (approved here).
    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_a,cr_b" --decision approve
    [ "$status" -eq 5 ]
    [ "$(awk 'END{print NR}' "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "rejected_pre_flight"' "$CV_RESULTS_PATH"
    jq -e '.pre_flight == "missing_profile_browse"' "$CV_RESULTS_PATH"
    jq -e '.request_ids == ["cr_a","cr_b"]' "$CV_RESULTS_PATH"
    jq -e '.intended_status == "approved"' "$CV_RESULTS_PATH"
    jq -e '.profile_id == "p1"' "$CV_RESULTS_PATH"
}

@test "browse-required: 2 Tier-1 URLs satisfy browse-required + quorum + structural for flag" {
    # Common case: agent browses 2 distinct Tier-1 hosts. Page text mentions
    # Pau Romero in unrelated sections (per-profile-browse passes), the
    # excerpt is structurally valid for flag (track + role, no name).
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine songwriter Lennon McCartney. Pau Romero discography"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine songwriter section. Pau Romero — see also"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter" --ids "cr_1" --decision flag \
        --reason "name not credited on track" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 0'
    [ -f "$FLAG_LOG" ]
}

# --- Flag path — snapshot-match gate (>=1 Tier-1 host) + reason enum --------

@test "flag with matching Tier-1 snapshot + valid flag-reason → delegate called, exit 0" {
    # PR #233 contract: flag requires structural rule (excerpt has track/role,
    # NOT credited_name) AND >=2 Tier-1 quorum. Seed 2 Tier-1 loads whose
    # text mentions Pau Romero in unrelated sections (per-profile-browse
    # passes) and contains the excerpt (quorum passes).
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine songwriter Lennon. Pau Romero discography"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine songwriter section. Pau Romero — see also"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 --evidence-excerpt "Yellow Submarine songwriter" \
        --ids "cr_1,cr_2,cr_3" --decision flag --reason "name not credited on the track" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.decision == "flag" and .pre_flight == "ok" and .delegate_exit == 0'
    echo "$output" | jq -e '.flag_reason == "name_mismatch"'
    echo "$output" | jq -e '(.ids | length) == 3'
    [ -f "$FLAG_LOG" ]
    [[ "$(cat "$FLAG_LOG")" == *"--profile-id"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"--reason"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"--flag-reason"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"name_mismatch"* ]]
    # PR #233: dispatcher forwards claim metadata to the flag delegate.
    [[ "$(cat "$FLAG_LOG")" == *"--credited-name"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"--track-title"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"--role"* ]]
    [[ "$(cat "$FLAG_LOG")" == *"Pau Romero"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

@test "flag without matching Tier-1 snapshot → exit 3 (missing_flag_evidence)" {
    # Seed a Tier-1 browser load whose text mentions Pau Romero + role so
    # per-profile-browse passes; the quorum gate fails because the excerpt
    # "Yellow Submarine songwriter" is missing from this single host's text
    # (which doesn't include the track title) — only 0/2 hosts match the
    # excerpt.
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/p1" "Pau Romero songwriter overview discography"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter" --ids "cr_1" --decision flag \
        --reason "no Tier-1 source confirmed the credited name" --flag-reason no_tier1_match
    [ "$status" -eq 3 ]
    echo "$output" | jq -e '.pre_flight == "missing_flag_evidence" and .delegate_exit == null'
    # PR #233: flag quorum raised to >=CV_REQUIRED_LOADS (2 by default).
    [[ "$stderr" == *">=2 distinct Tier-1"* ]]
    [ ! -f "$FLAG_LOG" ]
}

@test "flag with --flag-reason evidence_quorum_failed REJECTED — bypass removed 2026-04-30" {
    # Run 20260430-111343-1605a8 used evidence_quorum_failed 460 times with
    # exactly 1 browser call across the run. Bypass removed; the dispatcher
    # now treats it as an invalid enum value.
    run run_w --profile-id p1 --evidence-excerpt "tried Spotify and MusicBrainz" \
        --ids "cr_1" --decision flag --reason "sources rate-limited" --flag-reason evidence_quorum_failed
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a valid enum value"* ]]
    [[ "$output" == *"removed 2026-04-30"* ]]
    [ ! -f "$FLAG_LOG" ]
}

@test "flag with --flag-reason human_review_requested REJECTED — bypass removed 2026-04-30" {
    # Same removal as evidence_quorum_failed; explicit human asks must go
    # through the existing escalation path (not bulk-flag).
    run run_w --profile-id p1 --evidence-excerpt "Aaron asked manually" \
        --ids "cr_1" --decision flag --reason "Aaron asked" --flag-reason human_review_requested
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a valid enum value"* ]]
    [ ! -f "$FLAG_LOG" ]
}

@test "flag delegate failure → exit 1, pre_flight still 'ok'" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine songwriter Lennon. Pau Romero discography"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine songwriter section. Pau Romero — see also"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    FLAG_MODE=partial run run_w --profile-id p1 --evidence-excerpt "Yellow Submarine songwriter" \
        --ids "cr_1,cr_2,cr_3" --decision flag --reason "unverifiable" --flag-reason no_tier1_match
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.decision == "flag" and .pre_flight == "ok" and .delegate_exit == 1'
}

# --- Approve path — contamination check ---------------------------------------

@test "approve: Tier-1 web_fetch in session → exit 3, pre_flight=web_fetch_tier1, no delegate" {
    # Seed a Tier-1 browser load with name+role so browse-required passes,
    # then add the contaminating web_fetch.
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/p1" "Ben Smith bass overview"
    seed_webfetch_tier1 "wf" "https://musicbrainz.org/artist/bad"
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    # stderr surfaces the contamination message.
    [[ "$stderr" == *"musicbrainz.org"* ]]
    echo "$output" | jq -e '.pre_flight == "web_fetch_tier1" and .delegate_exit == null'
    [ ! -f "$APPROVE_LOG" ]
}

# --- Approve path — evidence quorum + remediation -----------------------------

@test "approve: 0 Tier-1 hostnames match → exit 3 with remediation text" {
    # Seed ONE Tier-1 load whose text mentions name + role (so per-profile
    # browse passes) but doesn't contain the excerpt verbatim. The
    # excerpt-quorum check then fails with 0/2 Tier-1 hosts containing the
    # excerpt. (Browse-required passes at 1; excerpt-quorum fails at 0.)
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/abc-profile-123" "Ben Smith bass overview, no excerpt verbatim"
    run --separate-stderr run_w --profile-id abc-profile-123 \
        --evidence-excerpt "Ben Smith bass on Yellow Submarine" --ids "cr_1,cr_2" --decision approve
    [ "$status" -eq 3 ]
    echo "$output" | jq -e '.pre_flight == "missing_evidence" and .delegate_exit == null'
    [[ "$stderr" == *"0/2"* ]]
    # Remediation text names suggested Tier-1 URLs.
    [[ "$stderr" == *"musicbrainz.org/search?query="* ]]
    [[ "$stderr" == *"allmusic.com"* ]]
    [[ "$stderr" == *"musicbrainz.org"* ]]
    # And shows the exact retry command.
    [[ "$stderr" == *"batch-verify-profile.sh --profile-id 'abc-profile-123'"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

@test "approve: 1 of 2 Tier-1 matches → exit 3, lists currently-matching host" {
    # Excerpt appears on Spotify only; allmusic has no matching text.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass plays on the record"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"     "No results found for your query"
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
    [[ "$stderr" == *"musicbrainz.org"* ]]
    echo "$output" | jq -e '.pre_flight == "missing_evidence"'
    [ ! -f "$APPROVE_LOG" ]
}

@test "approve: 2 Tier-1 hostnames match → delegate called, exit 0" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass credits"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on this record"
    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1,cr_2" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 0'
    [ -f "$APPROVE_LOG" ]
    [[ "$(cat "$APPROVE_LOG")" == *"--evidence-excerpt"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"Ben Smith bass"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"cr_1,cr_2"* ]]
}

@test "approve: case-insensitive excerpt match (upper/lower both count)" {
    # Snapshots use mixed case; excerpt uses Title Case. Both must match
    # case-insensitively for approve. PR #233: structural rule also requires
    # role/track in the excerpt — included as "BASS" / "bass" in snapshots.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "BEN SMITH BASS is credited"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "ben smith bass discography"
    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.delegate_exit == 0'
}

@test "approve: non-Tier-1 browser load with excerpt does NOT count" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://hoborec.com/artist/x"        "Ben Smith bass credits"
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
}

@test "approve: two loads of the SAME Tier-1 hostname count as 1 (dedup)" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://musicbrainz.org/artist/p2" "Ben Smith bass on record"
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"1/2"* ]]
}

# --- Approve path — delegate propagation --------------------------------------

@test "approve: delegate gate rejection → exit 1, pre_flight='ok', delegate_exit=1" {
    # Pre-flight passes locally but delegate returns non-zero (e.g. the gate
    # tripped on run_started scoping after our pre-flight's snapshot). The
    # wrapper must propagate the failure honestly AND forward delegate stderr.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    APPROVE_MODE=gate run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 1'
    # Delegate's stderr must surface to the agent transcript.
    [[ "$stderr" == *"credit_approve_gate"* ]]
}

@test "approve: delegate HTTP 5xx → exit 1" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    APPROVE_MODE=http5xx run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.delegate_exit == 1'
}

# --- IDs + summary shape ------------------------------------------------------

@test "summary JSON: ids split correctly, whitespace-trimmed" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    run run_w --profile-id p1 \
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
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"new-b",name:"browser",arguments:{url:"https://musicbrainz.org/artist/p1"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"new-b",isError:false,content:[{type:"text",text:"Ben Smith bass on record"}]}}')" >> "$SESSION_LOG"

    # Seed a runlog with run_started between the two timestamps.
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-23"
    local log_path="$OPS_RUNLOG_DIR/2026-04-23/20260423-120000-aaaaaa.jsonl"
    jq -n -c '{event:"run_started", run_id:"20260423-120000-aaaaaa", ts:"2026-04-23T11:00:00Z", fetch_size:500}' > "$log_path"
    echo "$log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    run --separate-stderr run_w --profile-id p1 \
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
    # Seed ONE Tier-1 load that proves the claim (Ben Smith + bass) so
    # browse-required passes; the excerpt-quorum then fails because we have
    # only 1 host vs the >=2 required. The 2026-05-04 refactor requires
    # claim metadata to match in the response text — give the helper text
    # that contains both the credited name and a role token.
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/p1" "Ben Smith bass section"
    run --separate-stderr run_w --profile-id p1 \
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
    # Seed a Tier-1 browser load with claim-matching text so browse-required
    # passes; then the web_fetch contamination is what fails.
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/p2" "Ben Smith bass section"
    seed_webfetch_tier1 "wf" "https://musicbrainz.org/artist/bad"
    run --separate-stderr run_w --profile-id p2 \
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
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on record"
    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    # Test stub doesn't write to CV_RESULTS_PATH; wrapper must not either.
    [ "$(count_lines "$CV_RESULTS_PATH")" -eq 0 ]
}

@test "truth-floor: flag with passing snapshot does not write pre-flight row (delegate handles it)" {
    # Quorum + structural gate pass → no pre-flight row from the wrapper.
    # Downstream admin-api truth floor row (written by the delegate stub
    # here) is also absent because the stub is fake.
    # Seed text mentions Pau Romero in unrelated sections (per-profile gate
    # passes) and contains the excerpt verbatim (quorum passes); the EXCERPT
    # itself omits the name (flag's structural rule passes).
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine songwriter Lennon. Pau Romero discography listed below"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine songwriter section. Pau Romero — see also"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 --evidence-excerpt "Yellow Submarine songwriter" \
        --ids "cr_1,cr_2" --decision flag --reason "name not credited" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    [ "$(count_lines "$CV_RESULTS_PATH")" -eq 0 ]
}

@test "truth-floor: flag pre-flight failure writes rejected_pre_flight row with intended_status=user_verification_needed" {
    # Seed a Tier-1 load whose text matches the claim (Pau Romero + songwriter)
    # so browse-required passes; the quorum gate is what fails because the
    # excerpt "Yellow Submarine songwriter" only appears on 1/2 hosts (the
    # seed text has "songwriter" + the right person but doesn't include the
    # full excerpt phrase, and there's no second Tier-1 host).
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/p1" "Pau Romero songwriter on a different track"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 --evidence-excerpt "Yellow Submarine songwriter" \
        --ids "cr_1,cr_2" --decision flag --reason "name not on Tier-1" --flag-reason no_tier1_match
    [ "$status" -eq 3 ]
    [ "$(count_lines "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "rejected_pre_flight" and .pre_flight == "missing_flag_evidence" and .intended_status == "user_verification_needed" and .flag_reason == "no_tier1_match"' "$CV_RESULTS_PATH"
}

@test "approve: run_started scoping ignores yesterday's Tier-1 web_fetch" {
    # Yesterday's contamination should not block today's pre-flight.
    local old_ts="2026-04-22T10:00:00Z"
    local new_ts="2026-04-23T12:00:00Z"
    printf '%s\n' "$(jq -n -c --arg ts "$old_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"old-wf",name:"web_fetch",arguments:{url:"https://musicbrainz.org/artist/contaminated"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$old_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"old-wf",isError:false,content:[{type:"text",text:"yesterday"}]}}')" >> "$SESSION_LOG"
    # New Tier-1 browser loads that justify approve.
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"new-b1",name:"browser",arguments:{url:"https://musicbrainz.org/artist/p1"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"new-b1",isError:false,content:[{type:"text",text:"Ben Smith bass"}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"assistant",content:[{type:"toolCall",id:"new-b2",name:"browser",arguments:{url:"https://allmusic.com/artist/x"}}]}}')" >> "$SESSION_LOG"
    printf '%s\n' "$(jq -n -c --arg ts "$new_ts" '{type:"message",timestamp:$ts,message:{role:"toolResult",toolCallId:"new-b2",isError:false,content:[{type:"text",text:"Ben Smith bass on record"}]}}')" >> "$SESSION_LOG"

    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-23"
    local log_path="$OPS_RUNLOG_DIR/2026-04-23/20260423-120000-bbbbbb.jsonl"
    jq -n -c '{event:"run_started", run_id:"20260423-120000-bbbbbb", ts:"2026-04-23T11:00:00Z", fetch_size:500}' > "$log_path"
    echo "$log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok"'
    [ -f "$APPROVE_LOG" ]
}

# ============================================================================
# PR #233 — Per-profile claim verification (--credited-name / --track-title /
# --role) + structural excerpt rule + raised flag quorum.
# ============================================================================

# --- Required claim-metadata args (validated after the existing args) --------

@test "PR #233: missing --credited-name → exit 2" {
    # Pass all existing required args so the failure is specifically the
    # missing claim metadata, not one of the older validations.
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Ben Smith bass" \
        --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--credited-name is required"* ]]
}

@test "PR #233: missing --track-title → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --credited-name "Ben Smith" \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--track-title is required"* ]]
}

@test "PR #233: missing --role → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --credited-name "Ben Smith" \
        --track-title "The Test Track" --evidence-excerpt "Ben Smith bass" \
        --ids "cr_1" --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--role is required"* ]]
}

# --- Approve path: structural rule (name AND (track OR role)) ---------------

@test "PR #233 approve: name+track in excerpt → exit 0" {
    # Both Tier-1 snapshots must literally contain the excerpt for quorum.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero on Yellow Submarine credits"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Pau Romero on Yellow Submarine recording"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 \
        --evidence-excerpt "Pau Romero on Yellow Submarine" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 0'
}

@test "PR #233 approve: name+role in excerpt → exit 0 (track absent OK)" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero, songwriter, on multiple tracks"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Pau Romero, songwriter, MusicBrainz entry"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 \
        --evidence-excerpt "Pau Romero, songwriter" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
}

@test "PR #233 approve: name only (no role/track) → exit 6 (excerpt_does_not_prove_claim)" {
    # Excerpt has the name but no credit-context. Lazy substring — page might
    # be the wrong artist's profile. Structural rule rejects. Seed text
    # mentions name + role so per-profile-browse passes; failure is the
    # structural rule on the EXCERPT.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero songwriter overview"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Pau Romero songwriter discography"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Pau Romero artist page" --ids "cr_1" --decision approve
    [ "$status" -eq 6 ]
    echo "$output" | jq -e '.pre_flight == "excerpt_does_not_prove_claim"'
    [[ "$stderr" == *"track_or_role"* ]]
    [ ! -f "$APPROVE_LOG" ]
}

@test "PR #233 approve: role/track only (no name) → exit 6" {
    # Seed text mentions Pau Romero in another section so per-profile-browse
    # passes; the structural rule against the EXCERPT (which lacks the name)
    # is what fires.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine songwriter section. Pau Romero — see also"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine — songwriter Lennon. Pau Romero discography"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter" --ids "cr_1" --decision approve
    [ "$status" -eq 6 ]
    [[ "$stderr" == *"credited_name"* ]]
}

@test "PR #233 approve: structural rule is case-insensitive (name)" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "PAU ROMERO songwriter"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "PAU ROMERO songwriter section"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 \
        --evidence-excerpt "PAU ROMERO songwriter" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
}

@test "PR #233 approve: multi-role — any one role token satisfies has_context" {
    # ROLE = "Producer, Songwriter, Composer" — comma-separated. Excerpt with
    # any one token (e.g. "Producer") satisfies has_context.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero Producer credits on this album"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Pau Romero Producer credits MusicBrainz entry"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Some Album" ROLE_OVERRIDE="Producer, Songwriter, Composer" \
    run run_w --profile-id p1 \
        --evidence-excerpt "Pau Romero Producer credits" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
}

# --- Flag path: structural rule (track/role AND NOT name) -------------------

@test "PR #233 flag: track present, name absent on 2 hosts → exit 0" {
    # The page text mentions Pau Romero in unrelated sections (e.g. sidebar /
    # "you might also like") so the per-profile-browse gate passes — the
    # agent demonstrably loaded a Tier-1 page about this artist. The EXCERPT
    # picked from the credit-area shows track+role but NOT the name, proving
    # the negative for flag.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine songwriter — Lennon McCartney. Sidebar: Pau Romero"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine songwriter section listed. Discography: Pau Romero"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter" --ids "cr_1" --decision flag \
        --reason "Pau Romero not in songwriter credits" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 0'
}

@test "PR #233 flag: name PRESENT in excerpt → exit 6 (unexpected: credited_name)" {
    # Inverted rule: if credited_name appears in excerpt, agent should APPROVE
    # (or escalate), not flag. The excerpt here contains both track and name.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Yellow Submarine — Pau Romero songwriter"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Yellow Submarine — Pau Romero"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine — Pau Romero" --ids "cr_1" --decision flag \
        --reason "x" --flag-reason name_mismatch
    [ "$status" -eq 6 ]
    echo "$output" | jq -e '.pre_flight == "excerpt_does_not_prove_claim"'
    [[ "$stderr" == *"Unexpected"* ]] || [[ "$stderr" == *"credited_name"* ]]
    [[ "$stderr" == *"APPROVE"* ]]
    [ ! -f "$FLAG_LOG" ]
}

@test "PR #233 flag: track/role absent in excerpt → exit 6 (missing context)" {
    # Excerpt has neither track nor role token — agent didn't actually load
    # the credit area, so "name absent" can't be distinguished from "wrong
    # page entirely". Seed text contains name + track + role so the
    # per-profile-browse gate passes; the failure is purely on the
    # structural rule against the excerpt.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero songwriter Yellow Submarine page"
    seed_browser_toolcall_ok "b2" "https://music.apple.com/us/artist/p1" "Pau Romero songwriter Yellow Submarine entry"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "general page text content" --ids "cr_1" --decision flag \
        --reason "x" --flag-reason no_tier1_match
    [ "$status" -eq 6 ]
    [[ "$stderr" == *"track_or_role"* ]]
}

# --- Quorum: flag now requires >=CV_REQUIRED_LOADS (raised from >=1) --------

@test "PR #233 flag: 1 of 2 Tier-1 matches → exit 3 (raised quorum)" {
    # First seed contains the excerpt; second is irrelevant. The new gate
    # also requires the seed text to mention the credited name + role/track
    # (so per-profile-browse passes) — bake that in.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Pau Romero. Yellow Submarine songwriter section"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/p1" "Pau Romero songwriter discography listing"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run --separate-stderr run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter" --ids "cr_1" --decision flag \
        --reason "x" --flag-reason name_mismatch
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"only 1"* ]] || [[ "$stderr" == *"1/2"* ]]
}

# --- Delegate metadata propagation -------------------------------------------

@test "PR #233 approve: delegate receives --credited-name / --track-title / --role" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass credits"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on this record"
    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1,cr_2" --decision approve
    [ "$status" -eq 0 ]
    [[ "$(cat "$APPROVE_LOG")" == *"--credited-name"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"Ben Smith"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"--track-title"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"The Test Track"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"--role"* ]]
    [[ "$(cat "$APPROVE_LOG")" == *"bass"* ]]
}

# --- Summary JSON shape ------------------------------------------------------

@test "PR #233 summary JSON: includes credited_name/track_title/role echo" {
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass"
    run run_w --profile-id p1 --evidence-excerpt "Ben Smith bass" --ids "cr_1" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.credited_name == "Ben Smith" and .track_title == "The Test Track" and .role == "bass"'
}

# --- Truth-floor: pre-flight rejection row carries claim metadata -----------

@test "PR #233 truth-floor: exit-6 rejection row includes credited_name/track_title/role" {
    # Browse-required passes (Tier-1 + name + role), structural rule fires
    # against the excerpt (no name) → exit 6 → row written.
    seed_browser_toolcall_ok "b0" "https://musicbrainz.org/artist/p1" "Pau Romero songwriter overview"
    CREDITED_NAME_OVERRIDE="Pau Romero" TRACK_TITLE_OVERRIDE="Yellow Submarine" ROLE_OVERRIDE="songwriter" \
    run run_w --profile-id p1 \
        --evidence-excerpt "Yellow Submarine songwriter" --ids "cr_1" --decision approve
    [ "$status" -eq 6 ]
    [ "$(awk 'END{print NR}' "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "rejected_pre_flight"' "$CV_RESULTS_PATH"
    jq -e '.pre_flight == "excerpt_does_not_prove_claim"' "$CV_RESULTS_PATH"
    jq -e '.credited_name == "Pau Romero"' "$CV_RESULTS_PATH"
    jq -e '.track_title == "Yellow Submarine"' "$CV_RESULTS_PATH"
    jq -e '.role == "songwriter"' "$CV_RESULTS_PATH"
}
