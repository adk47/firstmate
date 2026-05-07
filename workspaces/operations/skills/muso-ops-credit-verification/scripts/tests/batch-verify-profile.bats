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
    # 2026-05-07 cutover: existing tests assert legacy browser-mode
    # semantics (count_excerpt_matches over Tier-1 browser snapshots,
    # tier1_webfetch contamination check). Pin to browser so they
    # cover the rollback path. New api-mode behavior is exercised by
    # the gate suite + api-evidence.bats — adding equivalent cases
    # here would require rebuilding the entire fixture stack on the
    # api-evidence shape, which is out of scope.
    export CV_EVIDENCE_MODE=browser
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

# ============================================================================
# Tier-0 path — wire profile-audit.sh into the dispatcher so a real batch run
# actually exercises Tier-0. CLI: batch-verify-profile.sh --tier0 --profile-id <pid>
# ============================================================================

# Helper — install stubs for profile-audit.sh and muso-admin-api.sh that
# log every invocation. Each test sets MODE env vars to control behavior.
setup_tier0_stubs() {
    PROFILE_AUDIT_LOG="$TEST_ROOT/profile-audit-invocations.log"
    ADMIN_API_LOG="$TEST_ROOT/admin-api-invocations.log"
    export PROFILE_AUDIT_LOG ADMIN_API_LOG
    : > "$PROFILE_AUDIT_LOG"
    : > "$ADMIN_API_LOG"

    export PROFILE_AUDIT_SH="$TEST_ROOT/fake-profile-audit.sh"
    cat > "$PROFILE_AUDIT_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\nENV_OPS_TIER0_ENABLED=%s\n' "${OPS_TIER0_ENABLED:-}"; } >> "${PROFILE_AUDIT_LOG:-/dev/null}"
case "${TIER0_AUDIT_MODE:-pass}" in
    pass)     echo "profile_audit:cc=694,pop=68,batch=50,industry=0.96,only_vel=1.00,br_max=1/1,roles_ok=1,art=0.56,lbl=0.46"; exit 0 ;;
    skip)     echo "[fake-audit] skip" >&2; exit 1 ;;
    disabled) echo "Tier-0 disabled" >&2; exit 2 ;;
    bad_receipt) echo "garbled output without prefix"; exit 0 ;;
    *)        echo "unknown TIER0_AUDIT_MODE=${TIER0_AUDIT_MODE}" >&2; exit 99 ;;
esac
STUB
    chmod +x "$PROFILE_AUDIT_SH"

    export MUSO_ADMIN_API_SH="$TEST_ROOT/fake-admin-api.sh"
    cat > "$MUSO_ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n'; } >> "${ADMIN_API_LOG:-/dev/null}"

# Mode A: GET /admin/credit-requests?...status=unverified — return queue.
# Args layout: [--evidence-excerpt v --profile-audit-id v --requester v] call <METHOD> <PATH> [body]
# Find METHOD + PATH by scanning for "call".
method=""
path=""
body=""
i=1
while (( i <= $# )); do
    eval "tok=\${$i}"
    if [[ "$tok" == "call" ]]; then
        i=$((i+1)); eval "method=\${$i}"
        i=$((i+1)); eval "path=\${$i}"
        i=$((i+1)); eval "body=\${$i:-}"
        break
    fi
    i=$((i+1))
done

if [[ "$method" == "GET" && "$path" == /admin/credit-requests* && "$path" == *status=unverified* ]]; then
    case "${TIER0_QUEUE_MODE:-three}" in
        empty) echo '{"http_status":200,"body":{"result":"ok","data":{"items":[]}}}'; exit 0 ;;
        three) echo '{"http_status":200,"body":{"result":"ok","data":{"items":[{"id":"cr_a"},{"id":"cr_b"},{"id":"cr_c"}]}}}'; exit 0 ;;
        http500) echo '{"http_status":500,"body":{"error":"upstream"}}'; exit 0 ;;
        empty_resp) echo ""; exit 0 ;;
    esac
fi

if [[ "$method" == "PUT" && "$path" == "/admin/credit-requests" ]]; then
    case "${TIER0_PUT_MODE:-ok}" in
        ok)   echo '{"http_status":200,"body":{"result":"ok","approved":3}}'; exit 0 ;;
        fail) echo "admin-api: gate rejected" >&2; exit 1 ;;
    esac
fi

echo "fake-admin-api: unhandled invocation" >&2
exit 99
STUB
    chmod +x "$MUSO_ADMIN_API_SH"
}

@test "tier0: audit passes → dispatcher calls admin-api with receipt + profile-audit-id + requester" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=three TIER0_PUT_MODE=ok \
        run bash "$WRAPPER" --tier0 --profile-id pid-123
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier0: approved 3 credits for profile pid-123"* ]]
    [[ "$output" == *"profile_audit:cc=694"* ]]
    # profile-audit.sh was invoked with the profile id and OPS_TIER0_ENABLED=1.
    grep -q "pid-123" "$PROFILE_AUDIT_LOG"
    grep -q "ENV_OPS_TIER0_ENABLED=1" "$PROFILE_AUDIT_LOG"
    # admin-api was called twice (GET unverified, PUT approve).
    grep -q "GET" "$ADMIN_API_LOG"
    grep -q "PUT" "$ADMIN_API_LOG"
    grep -q -- "--evidence-excerpt" "$ADMIN_API_LOG"
    grep -q "profile_audit:cc=694" "$ADMIN_API_LOG"
    grep -q -- "--profile-audit-id" "$ADMIN_API_LOG"
    grep -q "pid-123" "$ADMIN_API_LOG"
    grep -q -- "--requester" "$ADMIN_API_LOG"
    grep -q "clio" "$ADMIN_API_LOG"
    grep -q "tier0_profile_audit" "$ADMIN_API_LOG"
    grep -q '"requestIds":\["cr_a","cr_b","cr_c"\]' "$ADMIN_API_LOG"
}

@test "tier0: audit skips → dispatcher exits 1 with fall-through message, no admin-api call" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=skip \
        run bash "$WRAPPER" --tier0 --profile-id pid-skip
    [ "$status" -eq 1 ]
    [[ "$output" == *"fall-through"* ]]
    [[ "$output" == *"pid-skip"* ]]
    # admin-api must not be invoked when audit skips.
    [ ! -s "$ADMIN_API_LOG" ]
}

@test "tier0: audit disabled → dispatcher exits 2" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=disabled \
        run bash "$WRAPPER" --tier0 --profile-id pid-disabled
    [ "$status" -eq 2 ]
    [[ "$output" == *"disabled"* ]] || [[ "$output" == *"profile-audit exit 2"* ]]
    [ ! -s "$ADMIN_API_LOG" ]
}

@test "tier0: audit pre-set OPS_TIER0_ENABLED=0 propagated (audit exits 2 → exit 2)" {
    setup_tier0_stubs
    # Caller explicitly disabled — dispatcher must not silently re-enable.
    OPS_TIER0_ENABLED=0 TIER0_AUDIT_MODE=disabled \
        run bash "$WRAPPER" --tier0 --profile-id pid-env-off
    [ "$status" -eq 2 ]
    grep -q "ENV_OPS_TIER0_ENABLED=0" "$PROFILE_AUDIT_LOG"
}

@test "tier0: empty unverified queue → audit passes but no admin-api PUT, exit 0" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=empty \
        run bash "$WRAPPER" --tier0 --profile-id pid-empty
    [ "$status" -eq 0 ]
    [[ "$output" == *"unverified queue is empty"* ]] || [[ "$output" == *"nothing to approve"* ]]
    # GET happened; PUT did not.
    grep -q "GET" "$ADMIN_API_LOG"
    ! grep -q "PUT" "$ADMIN_API_LOG"
}

@test "tier0: queue fetch HTTP 500 → exit 1, no PUT" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=http500 \
        run bash "$WRAPPER" --tier0 --profile-id pid-500
    [ "$status" -eq 1 ]
    [[ "$output" == *"HTTP 500"* ]]
    ! grep -q "PUT" "$ADMIN_API_LOG"
}

@test "tier0: admin-api PUT fails → exit 1" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=three TIER0_PUT_MODE=fail \
        run bash "$WRAPPER" --tier0 --profile-id pid-put-fail
    [ "$status" -eq 1 ]
    [[ "$output" == *"PUT failed"* ]]
    grep -q "PUT" "$ADMIN_API_LOG"
}

@test "tier0: profile-audit returns exit 0 but garbled receipt → exit 1, no PUT" {
    setup_tier0_stubs
    TIER0_AUDIT_MODE=bad_receipt \
        run bash "$WRAPPER" --tier0 --profile-id pid-bad-receipt
    [ "$status" -eq 1 ]
    [[ "$output" == *"no valid receipt"* ]]
    ! grep -q "PUT" "$ADMIN_API_LOG"
}

@test "tier0: dry-run mode passes through — OPS_DRY_RUN=1 forwarded to admin-api" {
    setup_tier0_stubs
    # The fake admin-api echoes the env back via its argv log; inspect that.
    # Easier: have the stub also dump OPS_DRY_RUN. We can patch the stub here.
    cat > "$MUSO_ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'OPS_DRY_RUN=%s ARGS:' "${OPS_DRY_RUN:-}"; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n'; } >> "${ADMIN_API_LOG:-/dev/null}"
method=""; path=""; body=""; i=1
while (( i <= $# )); do
    eval "tok=\${$i}"
    if [[ "$tok" == "call" ]]; then
        i=$((i+1)); eval "method=\${$i}"
        i=$((i+1)); eval "path=\${$i}"
        i=$((i+1)); eval "body=\${$i:-}"
        break
    fi
    i=$((i+1))
done
if [[ "$method" == "GET" ]]; then
    echo '{"http_status":200,"body":{"result":"ok","data":{"items":[{"id":"cr_a"}]}}}'
    exit 0
fi
echo '{"http_status":200,"body":{"result":"ok","approved":1}}'
exit 0
STUB
    chmod +x "$MUSO_ADMIN_API_SH"
    OPS_DRY_RUN=1 TIER0_AUDIT_MODE=pass \
        run bash "$WRAPPER" --tier0 --profile-id pid-dry
    [ "$status" -eq 0 ]
    grep -q "OPS_DRY_RUN=1" "$ADMIN_API_LOG"
}

@test "tier0: rejects per-credit args — --evidence-excerpt with --tier0 → exit 2" {
    setup_tier0_stubs
    run bash "$WRAPPER" --tier0 --profile-id pid-mix --evidence-excerpt "Ben Smith bass"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--evidence-excerpt is not allowed with --tier0"* ]]
    [ ! -s "$PROFILE_AUDIT_LOG" ]
}

@test "tier0: rejects per-credit args — --decision with --tier0 → exit 2" {
    setup_tier0_stubs
    run bash "$WRAPPER" --tier0 --profile-id pid-mix --decision approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"--decision is not allowed with --tier0"* ]]
}

@test "tier0: --tier0 without --profile-id → exit 2 (existing arg validation)" {
    setup_tier0_stubs
    run bash "$WRAPPER" --tier0
    [ "$status" -eq 2 ]
    [[ "$output" == *"--profile-id is required"* ]]
}

@test "regression: per-credit path still works without --tier0" {
    # The existing per-credit approve flow must remain unchanged. Mirrors the
    # canonical "2 Tier-1 hostnames match → exit 0" test, no --tier0 flag.
    seed_browser_toolcall_ok "b1" "https://musicbrainz.org/artist/p1" "Ben Smith bass credits"
    seed_browser_toolcall_ok "b2" "https://allmusic.com/artist/x"      "Ben Smith bass on this record"
    run run_w --profile-id p1 \
        --evidence-excerpt "Ben Smith bass" --ids "cr_1,cr_2" --decision approve
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pre_flight == "ok" and .delegate_exit == 0'
    [ -f "$APPROVE_LOG" ]
}

# ============================================================================
# Tier-0 action_attempted emit — fix for the post-batch summary refusing to
# post when a Tier-0 bulk-approve run had queue_depth_at_start > 0 but zero
# action_attempted events (Failure 1 shape). The dispatcher must emit one
# action_attempted event per successful Tier-0 PUT with the correct shape so
# downstream reconciliation + the in-flight gate recognize the work.
# ============================================================================

@test "tier0: emits action_attempted with tier0_profile_audit evidence_kind on success" {
    setup_tier0_stubs

    # Real runlog dir + RUN_ID + runlog.sh stub so the dispatcher can write
    # an action_attempted event. We use a stubbed runlog.sh so we can
    # assert on the exact arguments without depending on cookie-cutter /
    # verdict gate behavior in this test.
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlog"
    mkdir -p "$OPS_RUNLOG_DIR"
    export OPS_RUN_ID="20260506-180000-deadbe"

    RUNLOG_LOG="$TEST_ROOT/runlog-invocations.log"
    : > "$RUNLOG_LOG"
    export RUNLOG_LOG
    export RUNLOG_SH="$TEST_ROOT/fake-runlog.sh"
    cat > "$RUNLOG_SH" <<'STUB'
#!/usr/bin/env bash
# Capture invocation: subcommand + run_id + event_name + payload, plus the
# values of the gate-disable env vars (so the test can assert the dispatcher
# disabled them for tier0 emits).
{
    printf 'CV_DISABLE_COOKIE_CUTTER_GATE=%s\n' "${CV_DISABLE_COOKIE_CUTTER_GATE:-}"
    printf 'CV_DISABLE_VERDICT_GATE=%s\n' "${CV_DISABLE_VERDICT_GATE:-}"
    printf 'ARGS:'
    for a in "$@"; do printf '\n  %s' "$a"; done
    printf '\n---\n'
} >> "${RUNLOG_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$RUNLOG_SH"

    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=three TIER0_PUT_MODE=ok \
        run bash "$WRAPPER" --tier0 --profile-id pid-aa-emit
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved 3 credits"* ]]

    # Exactly one action_attempted call to runlog.sh.
    aa_count=$(grep -c 'action_attempted' "$RUNLOG_LOG" || true)
    [ "$aa_count" -eq 1 ]

    # Pull out the JSON payload from the runlog invocation. Walk the captured
    # ARGS to find the last positional arg (the payload).
    payload=$(awk '/^ARGS:/{p=1; next} /^---$/{p=0} p' "$RUNLOG_LOG" | tail -1 | sed 's/^  //')
    echo "captured payload: $payload" >&2

    # Assert shape: profile_id, action=approve, cr_ids=[cr_a,cr_b,cr_c],
    # count=3, evidence_kind=tier0_profile_audit, evidence_excerpt is the
    # receipt.
    echo "$payload" | jq -e '.profile_id == "pid-aa-emit"'
    echo "$payload" | jq -e '.action == "approve"'
    echo "$payload" | jq -e '.cr_ids == ["cr_a","cr_b","cr_c"]'
    echo "$payload" | jq -e '.count == 3'
    echo "$payload" | jq -e '.evidence_kind == "tier0_profile_audit"'
    echo "$payload" | jq -e '.evidence_excerpt | startswith("profile_audit:")'

    # Cookie-cutter + verdict gates must be disabled for the emit so Tier-0
    # bulk-approves do not trip the runlog gates (receipts are similar by
    # design and Tier-0 has no browser anchor).
    grep -q 'CV_DISABLE_COOKIE_CUTTER_GATE=1' "$RUNLOG_LOG"
    grep -q 'CV_DISABLE_VERDICT_GATE=1' "$RUNLOG_LOG"
}

@test "tier0: empty queue → no action_attempted emit (nothing to approve)" {
    setup_tier0_stubs
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlog"
    mkdir -p "$OPS_RUNLOG_DIR"
    export OPS_RUN_ID="20260506-180000-empty0"

    RUNLOG_LOG="$TEST_ROOT/runlog-invocations.log"
    : > "$RUNLOG_LOG"
    export RUNLOG_LOG
    export RUNLOG_SH="$TEST_ROOT/fake-runlog.sh"
    cat > "$RUNLOG_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n---\n'; } >> "${RUNLOG_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$RUNLOG_SH"

    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=empty \
        run bash "$WRAPPER" --tier0 --profile-id pid-empty
    [ "$status" -eq 0 ]
    # Empty queue means PUT did not run, so no action_attempted should be emitted.
    ! grep -q 'action_attempted' "$RUNLOG_LOG"
}

@test "tier0: PUT failure → no action_attempted emit (no work landed)" {
    setup_tier0_stubs
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlog"
    mkdir -p "$OPS_RUNLOG_DIR"
    export OPS_RUN_ID="20260506-180000-putf00"

    RUNLOG_LOG="$TEST_ROOT/runlog-invocations.log"
    : > "$RUNLOG_LOG"
    export RUNLOG_LOG
    export RUNLOG_SH="$TEST_ROOT/fake-runlog.sh"
    cat > "$RUNLOG_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n---\n'; } >> "${RUNLOG_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$RUNLOG_SH"

    TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=three TIER0_PUT_MODE=fail \
        run bash "$WRAPPER" --tier0 --profile-id pid-put-fail
    [ "$status" -eq 1 ]
    # PUT failed, so no action_attempted should be emitted.
    ! grep -q 'action_attempted' "$RUNLOG_LOG"
}

@test "tier0: cookie-cutter gate exempts evidence_kind=tier0_profile_audit (3 batches in same run)" {
    # Real runlog.sh (no stub) so we exercise the actual cookie-cutter path.
    # Three Tier-0 batches in one run produce 3 action_attempted events with
    # similar evidence_excerpts (profile_audit:cc=...). The cookie-cutter
    # detector would normally fire on the 3rd; the evidence_kind exemption
    # must allow all 3 through.
    setup_tier0_stubs
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlog"
    mkdir -p "$OPS_RUNLOG_DIR"
    export OPS_RUN_ID="20260506-180000-cookie"

    # Use the REAL runlog.sh — bare RUNLOG_SH unset → defaults to
    # $SCRIPT_DIR/runlog.sh in batch-verify-profile.sh.
    unset RUNLOG_SH

    # Pre-create the runlog file (runlog.sh event uses log_path_for_run).
    day="${OPS_RUN_ID:0:8}"
    runlog_file="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/$OPS_RUN_ID.jsonl"
    mkdir -p "$(dirname "$runlog_file")"
    : > "$runlog_file"

    # Run the dispatcher 3 times with different profile_ids — 3 distinct
    # tier0 PUTs, 3 action_attempted writes that the cookie-cutter detector
    # would normally collapse on byte-identical receipt text. The fake
    # profile-audit emits the exact same receipt every call (same fixture).
    for pid in pid-cc-1 pid-cc-2 pid-cc-3; do
        TIER0_AUDIT_MODE=pass TIER0_QUEUE_MODE=three TIER0_PUT_MODE=ok \
            bash "$WRAPPER" --tier0 --profile-id "$pid" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || { echo "iteration for $pid failed rc=$rc" >&2; cat "$runlog_file" >&2; return 1; }
    done

    # All 3 action_attempted events must have landed despite identical receipts.
    aa_count=$(grep -c '"event":"action_attempted"' "$runlog_file")
    [ "$aa_count" -eq 3 ]

    # Each must carry evidence_kind=tier0_profile_audit.
    kinds=$(jq -r 'select(.event=="action_attempted") | .evidence_kind' "$runlog_file" | sort -u)
    [ "$kinds" = "tier0_profile_audit" ]
}
