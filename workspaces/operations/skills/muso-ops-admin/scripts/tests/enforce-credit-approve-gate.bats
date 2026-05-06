#!/usr/bin/env bats
# Tests for enforce_credit_approve_gate() in muso-admin-api.sh.
# Browser-only + content-match flavor (Phase 2).

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    mkdir -p "$TEST_ROOT/.openclaw-main/agents/operations/sessions"

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    WRAPPED="$TEST_ROOT/muso-admin-api.sh"
    sed "s|/root/.openclaw-main/agents|$TEST_ROOT/.openclaw-main/agents|g" "$SCRIPT" > "$WRAPPED"
    chmod +x "$WRAPPED"

    # Hermetic env: sandbox OPS_RUNLOG_DIR (and any other CV gate env the
    # host may have set) to a fresh empty TEST_ROOT subdir. Without this,
    # resolve_run_started_ts() picks up the host's runlog and scopes out
    # fixture rows that have no .timestamp — a 2026-05-05 review of PR #237
    # caught the host-state leak on a hydra dev box where OPS_RUNLOG_DIR
    # was inherited from /var/log/openclaw/credit-batch-runs.
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    unset REQUESTER_EMAIL CV_APPROVE_GATE_DISABLED EVIDENCE_EXCERPT \
          CV_SESSION_LOG_OVERRIDE CV_SESSION_RUN_STARTED_TS
    export CV_REQUIRED_LOADS=2
    export CV_SESSION_MAX_AGE_MIN=10
    export CV_EVIDENCE_EXCERPT_MIN=8
    export CV_EVIDENCE_EXCERPT_MAX=200
    # All cases below assert legacy browser-evidence semantics (Tier-1
    # browser quorum, web_fetch contamination block). The default mode
    # flipped to "api" with the 2026-05-06 cutover; pin to "browser" here
    # so this suite continues to cover the rollback path. New api-mode
    # cases live at the bottom of this file with their own override.
    export CV_EVIDENCE_MODE=browser
}

teardown() {
    rm -rf "$TEST_ROOT"
}

source_gate() {
    # shellcheck disable=SC1090
    source "$WRAPPED"
}

write_session_log() {
    local f="$TEST_ROOT/.openclaw-main/agents/operations/sessions/$1"
    printf '%s\n' "$2" > "$f"
    touch "$f"
}

# --- Passthrough cases (gate returns 0 without checking) ---

@test "passthrough: GET method" {
    source_gate
    run enforce_credit_approve_gate GET /admin/credit-requests '{"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: POST method (not an approve verb)" {
    source_gate
    run enforce_credit_approve_gate POST /admin/credit-requests '{"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: DELETE method (not an approve verb)" {
    source_gate
    run enforce_credit_approve_gate DELETE /admin/credit-requests/cr_1 ''
    [ "$status" -eq 0 ]
}

# --- PATCH is gated (same as PUT). This is the fix for the 2026-04-22
# --- live-test finding: the Ops bot uses PATCH /admin/credit-requests/<id>
# --- for individual approves, which completely bypassed the gate's old
# --- PUT-only check. Browser-evidence enforcement now covers both verbs.

@test "block: PATCH /admin/credit-requests/<id> status=approved requires evidence-excerpt" {
    source_gate
    write_session_log "s.jsonl" '{}'
    run enforce_credit_approve_gate PATCH /admin/credit-requests/0c1afd71-211f-499b-8a18-dc8d4b63d2de '{"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "passthrough: PATCH but non-approved status (e.g. user_verification_needed)" {
    source_gate
    run enforce_credit_approve_gate PATCH /admin/credit-requests/cr_1 '{"status":"user_verification_needed","reason":"x"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: PATCH + --requester aaron@muso.ai bypasses gate (same human override as PUT)" {
    source_gate
    REQUESTER_EMAIL="aaron@muso.ai" run enforce_credit_approve_gate PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "allow: PATCH approve with valid 2-Tier-1 evidence passes gate" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer credits list"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig appears on the Disaia record"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "block: PATCH with web_fetch-only evidence still fails (browser-only enforcement holds under PATCH)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"web_fetch","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"web_fetch","content":[{"type":"text","text":"Jose Roig engineer credits list"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"web_fetch","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"web_fetch","content":[{"type":"text","text":"Jose Roig appears on the Disaia record"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 1 ]
    # Now caught by the Tier 1 web_fetch block (earlier check, same semantic)
    [[ "$output" == *"web_fetch"* ]]
}

@test "passthrough: lower-case 'patch' is case-normalized and gated too" {
    # Defensive: if any caller passes method as 'patch' instead of 'PATCH',
    # the gate must still fire. Matches the method-case handling in the
    # fail-closed dry-run intercept.
    source_gate
    write_session_log "s.jsonl" '{}'
    run enforce_credit_approve_gate patch /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "passthrough: non-credit-requests path" {
    source_gate
    run enforce_credit_approve_gate PUT /admin/users '{"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: PUT but non-approved status" {
    source_gate
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"status":"user_verification_needed","reason":"x"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: --requester aaron@muso.ai bypasses gate (per-credit human verification)" {
    source_gate
    REQUESTER_EMAIL="aaron@muso.ai" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: --requester jan@muso.ai bypasses gate" {
    source_gate
    REQUESTER_EMAIL="jan@muso.ai" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "Nick's --requester does NOT bypass (batch trigger != per-credit verification)" {
    source_gate
    write_session_log "s.jsonl" '{}'
    REQUESTER_EMAIL="nick@muso.ai" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "arbitrary --requester does NOT bypass (security)" {
    source_gate
    write_session_log "s.jsonl" '{}'
    REQUESTER_EMAIL="someone@evil.com" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
}

@test "passthrough: CV_APPROVE_GATE_DISABLED=1" {
    source_gate
    CV_APPROVE_GATE_DISABLED=1 run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

# --- Per-ID path also gated ---

@test "block: PUT /admin/credit-requests/<id> is gated too (not just batch path)" {
    source_gate
    write_session_log "s.jsonl" '{}'
    run enforce_credit_approve_gate PUT /admin/credit-requests/0c1afd71-211f-499b-8a18-dc8d4b63d2de '{"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

# --- Evidence-excerpt validation ---

@test "block: --evidence-excerpt missing" {
    source_gate
    write_session_log "s.jsonl" '{}'
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "block: --evidence-excerpt too short" {
    source_gate
    write_session_log "s.jsonl" '{}'
    EVIDENCE_EXCERPT="abc" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *">=8 chars"* ]]
}

@test "block: --evidence-excerpt too long" {
    source_gate
    write_session_log "s.jsonl" '{}'
    EVIDENCE_EXCERPT=$(printf 'x%.0s' {1..201}) run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<=200"* ]]
}

# --- Session log + browser-only + content-match ---

@test "block: no session log found" {
    source_gate
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"no active openclaw session log"* ]]
}

@test "allow: 2 distinct Tier 1 browser results with excerpt in both" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig, Spanish engineer, credits include mixing"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig appears on the Disaia record"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "block: 2 Tier 1 browser loads but excerpt not in either result" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"No results found for this query"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"No matching artists"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "block: excerpt found but only on ONE Tier 1 host (second load missing excerpt)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig, Spanish engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"no results"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"1/2"* ]]
}

@test "block: excerpt found via web_fetch does NOT count (browser-only)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"web_fetch","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"web_fetch","content":[{"type":"text","text":"Jose Roig, Spanish engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"web_fetch","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"web_fetch","content":[{"type":"text","text":"Jose Roig appears"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    # Caught by the Tier 1 web_fetch block (earlier check); semantic unchanged
    [[ "$output" == *"web_fetch"* ]]
}

@test "block: excerpt found but only on non-Tier-1 browser load" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://hoborec.com"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Ulf Blomberg mastering engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://linkedin.com/in/ulf"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Ulf Blomberg profile"}]}}'
    EVIDENCE_EXCERPT="Ulf Blomberg" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "www.allmusic.com counts the same as allmusic.com (hostname normalized)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://www.allmusic.com/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig biography"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://www.discogs.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig discography"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "dedup: two loads of same Tier 1 hostname count as 1 (not 2)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig appears"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig also appears"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"1/2"* ]]
}

@test "case-insensitive excerpt match" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"JOSE ROIG is credited as engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"jose roig discography"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "Apple Music + Discogs count as Tier 1 (Tidal is Tier-2 for quorum)" {
    # Tidal browser loads do NOT count toward the >=2 quorum (it stays
    # supporting/Tier-2). Apple + Discogs together satisfy the bar.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://music.apple.com/us/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig artist page"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://discogs.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig credits"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "Tidal browser load does NOT count toward Tier-1 quorum (supporting only)" {
    # Two Tidal loads cannot satisfy the >=2 quorum — Tidal is Tier-2 (used
    # only as a backend album-credits URL). The web_fetch contamination check
    # still treats Tidal as JS-rendered (separate variable).
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://tidal.com/album/123/credits"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig songwriter"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://tidal.com/album/456/credits"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig producer"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "Jaxsta (Tier 3) browser load does NOT count" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://jaxsta.com/profile/foo"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://jaxsta.com/recording/bar"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "per-approve freshness: different excerpt requires new evidence" {
    source_gate
    # Session has Jose Roig evidence only; approving a Kevin Moon credit with
    # excerpt "Kevin Moon" must block because Kevin Moon isn't in any browser
    # result. Proves per-approve binding via the excerpt (different cr_id →
    # different excerpt → different evidence required).
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}'
    EVIDENCE_EXCERPT="Kevin Moon" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-2"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "block: Spotify is NOT Tier 1 (login-gated, dropped 2026-05-05)" {
    # Spotify credits dialog is login-gated for headless browsers. A single
    # spotify load + 1 musicbrainz load is only 1 quorum-counting host.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://open.spotify.com/artist/6gKqRTREnE0NInWDiBhEzY"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig - Artist page on Spotify"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig, Spanish engineer"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"1/2"* ]]
}

@test "block: jq crash on corrupt session log still blocks (fail-closed)" {
    source_gate
    write_session_log "s.jsonl" 'NOT-JSON-AT-ALL binary garbage
more garbage here'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "block: web_fetch to a Tier 1 host fails the approve (even with valid browser evidence)" {
    # Tier 1 substitution block: if the bot loaded ANY Tier 1 hostname via
    # web_fetch in this session, refuse the approve regardless of what browser
    # evidence also exists. Tier 1 pages are JS-rendered; web_fetch returns the
    # non-rendered HTML, which is a different (and often wrong) data surface.
    # Belt + braces: the operations agent's toolDenyList blocks web_fetch
    # entirely, but if that's ever misconfigured, this gate backstop catches it.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer credits on Spanish records"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig appears on Disaia records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-1","name":"web_fetch","arguments":{"url":"https://musicbrainz.org/search?query=foo"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-1","toolName":"web_fetch","content":[{"type":"text","text":"HTML snapshot"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"web_fetch"* ]]
}

@test "block: web_fetch to Tier 1 also blocks PATCH approve (not just PUT)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-1","name":"web_fetch","arguments":{"url":"https://tidal.com/album/123"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-1","toolName":"web_fetch","content":[{"type":"text","text":"page body"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"web_fetch"* ]]
}

@test "allow: web_fetch to a NON-Tier-1 host does NOT block (gate only cares about T1 substitution)" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer credits"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-1","name":"web_fetch","arguments":{"url":"https://jaxsta.com/profile/x"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-1","toolName":"web_fetch","content":[{"type":"text","text":"jaxsta page"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "allow: multiple browsers to Tier 1 + zero web_fetch calls still passes" {
    # Non-regression of the happy path.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer credits"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "session-age: stale log (>10 min) is ignored" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}'
    local backdate
    if date -v -20M +'%Y%m%d%H%M.%S' >/dev/null 2>&1; then
        backdate=$(date -v -20M +'%Y%m%d%H%M.%S')
        touch -t "$backdate" "$TEST_ROOT/.openclaw-main/agents/operations/sessions/s.jsonl"
    else
        touch -d '20 minutes ago' "$TEST_ROOT/.openclaw-main/agents/operations/sessions/s.jsonl"
    fi
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"no active openclaw session log"* ]]
}

# --- R3-3: run_started.ts scope filter -----------------------------------
#
# The gate scans session logs that openclaw channel-keys across runs. Without
# scoping, yesterday's web_fetch to Tier-1 or stale browser loads still count
# toward today's approve gate — today's run gets blocked for another run's
# sins. resolve_run_started_ts reads OPS_RUNLOG_DIR/latest.txt → runlog →
# first run_started event's .ts, and both gate jq pipelines filter session
# entries by (.timestamp >= that value).

seed_runlog_with_run_started() {
    # args: run_id run_started_ts [run_header_dryrun]
    local run_id="$1" ts="$2" dry="${3:-false}"
    local day="${run_id:0:8}"
    local log_dir="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
    mkdir -p "$log_dir"
    local log_path="$log_dir/${run_id}.jsonl"
    : > "$log_path"
    jq -n -c --arg rid "$run_id" --arg ts "$ts" --argjson dry "$dry" \
        '{event:"run_header", run_id:$rid, ts:$ts, dryRun:$dry}' >> "$log_path"
    jq -n -c --arg rid "$run_id" --arg ts "$ts" \
        '{event:"run_started", run_id:$rid, ts:$ts, fetch_size:500}' >> "$log_path"
    echo "$log_path" > "$OPS_RUNLOG_DIR/latest.txt"
}

@test "R3-3: old web_fetch to Tier-1 (pre-run_started) does NOT block current run" {
    # The exact yesterday-contamination-blocks-today-approves scenario that
    # forced us to manually archive the session file on 2026-04-23.
    source_gate
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    seed_runlog_with_run_started "20260423-120000-aaaaaa" "2026-04-23T12:00:00Z"

    write_session_log "s.jsonl" '{"type":"message","timestamp":"2026-04-22T10:00:00Z","message":{"content":[{"type":"toolCall","id":"old-wf","name":"web_fetch","arguments":{"url":"https://tidal.com/album/123/credits"}}]}}
{"type":"message","timestamp":"2026-04-22T10:00:01Z","message":{"role":"toolResult","toolCallId":"old-wf","toolName":"web_fetch","content":[{"type":"text","text":"yesterday contamination"}]}}
{"type":"message","timestamp":"2026-04-23T12:05:00Z","message":{"content":[{"type":"toolCall","id":"new-b1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"type":"message","timestamp":"2026-04-23T12:05:01Z","message":{"role":"toolResult","toolCallId":"new-b1","toolName":"browser","content":[{"type":"text","text":"Ben Smith bass credits"}]}}
{"type":"message","timestamp":"2026-04-23T12:06:00Z","message":{"content":[{"type":"toolCall","id":"new-b2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"type":"message","timestamp":"2026-04-23T12:06:01Z","message":{"role":"toolResult","toolCallId":"new-b2","toolName":"browser","content":[{"type":"text","text":"Ben Smith discography"}]}}'
    EVIDENCE_EXCERPT="Ben Smith" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "R3-3: new web_fetch to Tier-1 (post-run_started) still blocks" {
    source_gate
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    seed_runlog_with_run_started "20260423-120000-aaaaaa" "2026-04-23T12:00:00Z"

    write_session_log "s.jsonl" '{"type":"message","timestamp":"2026-04-23T12:05:00Z","message":{"content":[{"type":"toolCall","id":"new-wf","name":"web_fetch","arguments":{"url":"https://tidal.com/album/456"}}]}}
{"type":"message","timestamp":"2026-04-23T12:05:01Z","message":{"role":"toolResult","toolCallId":"new-wf","toolName":"web_fetch","content":[{"type":"text","text":"within-run contamination"}]}}'
    EVIDENCE_EXCERPT="Ben Smith" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"web_fetch"* ]]
}

@test "R3-3: old browser loads (pre-run_started) do NOT count toward evidence quorum" {
    # Agent must load evidence WITHIN this run. Past browser loads can't
    # satisfy today's quorum — otherwise a session with 2 stale Tier-1 loads
    # would let ANY excerpt through today.
    source_gate
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    seed_runlog_with_run_started "20260423-120000-aaaaaa" "2026-04-23T12:00:00Z"

    write_session_log "s.jsonl" '{"type":"message","timestamp":"2026-04-22T10:00:00Z","message":{"content":[{"type":"toolCall","id":"old-b1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"type":"message","timestamp":"2026-04-22T10:00:01Z","message":{"role":"toolResult","toolCallId":"old-b1","toolName":"browser","content":[{"type":"text","text":"Ben Smith engineer credits"}]}}
{"type":"message","timestamp":"2026-04-22T10:01:00Z","message":{"content":[{"type":"toolCall","id":"old-b2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"type":"message","timestamp":"2026-04-22T10:01:01Z","message":{"role":"toolResult","toolCallId":"old-b2","toolName":"browser","content":[{"type":"text","text":"Ben Smith records"}]}}'
    EVIDENCE_EXCERPT="Ben Smith" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"0/2"* ]]
}

@test "R3-3: mix of old + new loads → only new count" {
    source_gate
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    seed_runlog_with_run_started "20260423-120000-aaaaaa" "2026-04-23T12:00:00Z"

    write_session_log "s.jsonl" '{"type":"message","timestamp":"2026-04-22T10:00:00Z","message":{"content":[{"type":"toolCall","id":"old-b","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"type":"message","timestamp":"2026-04-22T10:00:01Z","message":{"role":"toolResult","toolCallId":"old-b","toolName":"browser","content":[{"type":"text","text":"Ben Smith engineer"}]}}
{"type":"message","timestamp":"2026-04-23T12:05:00Z","message":{"content":[{"type":"toolCall","id":"new-b","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"type":"message","timestamp":"2026-04-23T12:05:01Z","message":{"role":"toolResult","toolCallId":"new-b","toolName":"browser","content":[{"type":"text","text":"Ben Smith records"}]}}'
    # Only 1 new Tier-1 hostname has the excerpt — not enough for CV_REQUIRED_LOADS=2.
    EVIDENCE_EXCERPT="Ben Smith" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"1/2"* ]]
}

@test "R3-3: no OPS_RUNLOG_DIR → gate still works (backward-compat)" {
    # Ad-hoc / single-turn approves (non-batch) don't have a runlog. The gate
    # must still function with mtime-only bounding, as before.
    source_gate
    unset OPS_RUNLOG_DIR
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "R3-3: runlog exists but no run_started event → backward-compat (no scope)" {
    # Just a run_header (dry-run marker), no run_started yet — gate should
    # fall back to mtime-only so early-batch approves can still pass.
    source_gate
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-23"
    local log_path="$OPS_RUNLOG_DIR/2026-04-23/20260423-120000-bbbbbb.jsonl"
    jq -n -c '{event:"run_header", run_id:"20260423-120000-bbbbbb", ts:"2026-04-23T12:00:00Z", dryRun:true}' > "$log_path"
    echo "$log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

# --- R4-1: plugin-blocked / errored web_fetch is NOT contamination -----------
#
# The enforcer plugin blocks web_fetch to Tier 1 hosts at the tool layer by
# returning an error-shaped toolResult (details.status=error, no content text).
# The gate must distinguish this from a successful web_fetch that actually
# returned Tier 1 data. Counting blocked attempts as contamination is a
# false positive that rejects every downstream approve (2026-04-23 14:20 UTC).

@test "R4-1: plugin-blocked web_fetch does NOT flag as Tier-1 contamination" {
    # Shape observed in the 2026-04-23 session log: plugin returns isError:false
    # + details.status:error + content text containing the block reason. No
    # Tier-1 data leaked → the gate must not flag this as a substitution event.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer credits"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-blocked","name":"web_fetch","arguments":{"url":"https://tidal.com/album/drake"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-blocked","toolName":"web_fetch","content":[{"type":"text","text":"{\"status\":\"error\",\"tool\":\"web_fetch\",\"error\":\"web_fetch is disabled on Tier 1 music-data hosts during credit verification.\"}"}],"details":{"status":"error","tool":"web_fetch","error":"web_fetch is disabled on Tier 1 music-data hosts during credit verification."},"isError":false}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    # Must NOT see the contamination message.
    [[ "$output" != *"web_fetch call(s) to Tier 1"* ]]
}

@test "R4-1: successful web_fetch to Tier-1 host STILL blocks (no regression)" {
    # The classic substitution case: web_fetch actually returned Tier-1 HTML.
    # This is the real contamination the gate was designed to catch.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer credits"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-real","name":"web_fetch","arguments":{"url":"https://tidal.com/album/drake"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-real","toolName":"web_fetch","content":[{"type":"text","text":"<html>Drake - Artist page on Spotify - 80M monthly listeners</html>"}],"isError":false}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"web_fetch call(s) to Tier 1"* ]]
    [[ "$output" == *"tidal.com"* ]]
}

@test "R4-1: errored web_fetch (network/404) is NOT contamination either" {
    # Semantic consistency: any web_fetch that didn't return Tier-1 data
    # can't have leaked it. isError:true means the tool crashed or the HTTP
    # layer failed — same outcome as the plugin block.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-404","name":"web_fetch","arguments":{"url":"https://allmusic.com/gone"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-404","toolName":"web_fetch","content":[{"type":"text","text":"HTTP 404 Not Found"}],"isError":true}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"web_fetch call(s) to Tier 1"* ]]
}

@test "R4-1: empty-content web_fetch result is NOT contamination" {
    # Edge case: web_fetch returned a toolResult but no text. Maybe an upstream
    # bug, maybe a timeout-with-empty-body. Either way, no data.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-empty","name":"web_fetch","arguments":{"url":"https://discogs.com/artist/x"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-empty","toolName":"web_fetch","content":[],"isError":false}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"web_fetch call(s) to Tier 1"* ]]
}

@test "R4-1: mix of blocked and successful web_fetch → still blocks on the successful one" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"bc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig"}]}}
{"message":{"content":[{"type":"toolCall","id":"bc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"bc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}
{"message":{"content":[{"type":"toolCall","id":"wf-blocked","name":"web_fetch","arguments":{"url":"https://tidal.com/album/drake"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-blocked","toolName":"web_fetch","content":[{"type":"text","text":"blocked"}],"details":{"status":"error"},"isError":false}}
{"message":{"content":[{"type":"toolCall","id":"wf-real","name":"web_fetch","arguments":{"url":"https://musicbrainz.org/search?query=x"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-real","toolName":"web_fetch","content":[{"type":"text","text":"<html>MusicBrainz search results with real data</html>"}],"isError":false}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    # Should only name the successful host (musicbrainz.org), not spotify.
    [[ "$output" == *"musicbrainz.org"* ]]
    [[ "$output" != *"tidal.com"* ]]
}

# =====================================================================
# Tier-0 profile-audit evidence path
# =====================================================================
# When --evidence-excerpt starts with `profile_audit:`, the gate hands off
# to _tier0_audit_recompute_gate, which re-fetches the admin API and
# independently re-runs the 8-gate audit (defense-in-depth: never trust
# the receipt alone). These tests stub the admin API via ADMIN_API_SCRIPT
# pointing at a small canned-response shell script.

# Build a fake admin-api.sh stub. The stub reads path from "$3" (since the
# real gate calls `bash $ADMIN_API_SCRIPT call GET <path>`) and returns
# JSON from files keyed by status= query param. Setting STUB_FAIL_HTTP
# makes it return that http_status (e.g. 404 for profile-not-found).
write_stub_admin_api() {
    cat > "$TEST_ROOT/stub-admin-api.sh" <<'STUB_EOF'
#!/usr/bin/env bash
# Test stub: returns canned JSON envelopes matching the {http_status, body}
# shape produced by cmd_call. Routing rule: pick fixture by status= in path.
# verb = "$1" (call), method = "$2" (GET), path = "$3"
verb="${1:-}"; method="${2:-}"; path="${3:-}"
if [[ "${STUB_FAIL_HTTP:-}" != "" ]]; then
    printf '{"http_status": %s, "body": {"error": "stub_forced_fail"}}\n' "${STUB_FAIL_HTTP}"
    exit 0
fi
fixture=""
case "$path" in
    *status=unverified*) fixture="${STUB_UNV_FILE:-}" ;;
    *status=approved*)   fixture="${STUB_AP_FILE:-}" ;;
esac
if [[ -n "$fixture" && -f "$fixture" ]]; then
    items_json=$(cat "$fixture")
else
    items_json='[]'
fi
printf '{"http_status": 200, "body": {"data": {"items": %s}}}\n' "$items_json"
STUB_EOF
    chmod +x "$TEST_ROOT/stub-admin-api.sh"
    export ADMIN_API_SCRIPT="$TEST_ROOT/stub-admin-api.sh"
}

# Build a "Bram Fidder"-shaped unverified queue: 50 industry-source rows,
# all only-velocity, breadth=1, role=engineer, all carry artist "drake" +
# label "republic". cc/pop on .[0].profile come from args.
write_unv_fixture() {
    local file="$1" cc="$2" pop="$3" n="${4:-50}"
    jq -n -c \
        --argjson cc "$cc" --argjson pop "$pop" --argjson n "$n" '
        [range(0; $n) | {
            metadata: {source: "industry", label: "republic"},
            credits: ["engineer"],
            spotifyTrackArtists: [{name: "drake"}],
            verificationData: {rule_risk_percent: {reject_high_velocity_profile: 80}},
            profile: (if . == 0 then {creditCount: $cc, popularity: $pop} else {} end)
        }]' > "$file"
}

# Approved corpus that matches: same role, label, artist set
write_ap_fixture() {
    local file="$1" n="${2:-100}"
    jq -n -c --argjson n "$n" '
        [range(0; $n) | {
            metadata: {label: "republic"},
            credits: ["engineer"],
            spotifyTrackArtists: [{name: "drake"}]
        }]' > "$file"
}

@test "tier0: receipt matches live data → approve" {
    source_gate
    write_stub_admin_api
    export STUB_UNV_FILE="$TEST_ROOT/unv.json"
    export STUB_AP_FILE="$TEST_ROOT/ap.json"
    write_unv_fixture "$STUB_UNV_FILE" 694 68 50
    write_ap_fixture "$STUB_AP_FILE" 100
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    PROFILE_AUDIT_ID="bram-fidder-pid" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier0_audit_verified"* ]]
}

@test "tier0: receipt creditCount lies (says 694, live=10) → reject cc_mismatch" {
    source_gate
    write_stub_admin_api
    export STUB_UNV_FILE="$TEST_ROOT/unv.json"
    export STUB_AP_FILE="$TEST_ROOT/ap.json"
    # Live data: only 10 cc — receipt is forged
    write_unv_fixture "$STUB_UNV_FILE" 10 68 50
    write_ap_fixture "$STUB_AP_FILE" 100
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    PROFILE_AUDIT_ID="bram-fidder-pid" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"cc_mismatch"* ]]
}

@test "tier0: G1 fails on live recompute (cc=50 below threshold) → reject g1_creditCount" {
    source_gate
    write_stub_admin_api
    export STUB_UNV_FILE="$TEST_ROOT/unv.json"
    export STUB_AP_FILE="$TEST_ROOT/ap.json"
    # Receipt + live both say cc=50 (no mismatch), but G1 threshold is 100
    write_unv_fixture "$STUB_UNV_FILE" 50 68 50
    write_ap_fixture "$STUB_AP_FILE" 100
    EVIDENCE_EXCERPT="profile_audit:cc=50,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    PROFILE_AUDIT_ID="low-cc-pid" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"g1_creditCount"* ]]
}

@test "tier0: G7 fails on live recompute (artist overlap actually 0%) → reject g7_artist_overlap" {
    source_gate
    write_stub_admin_api
    export STUB_UNV_FILE="$TEST_ROOT/unv.json"
    export STUB_AP_FILE="$TEST_ROOT/ap.json"
    # Receipt claims art=0.56, but live unverified credits have artist "drake"
    # while approved corpus has artist "different_artist" → 0% overlap.
    write_unv_fixture "$STUB_UNV_FILE" 694 68 50
    jq -n -c '[range(0;100) | {
        metadata:{label:"republic"}, credits:["engineer"],
        spotifyTrackArtists:[{name:"different_artist"}]
    }]' > "$STUB_AP_FILE"
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=0.56,lbl=1.00" \
    PROFILE_AUDIT_ID="liar-pid" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"g7_artist_overlap"* ]]
}

@test "tier0: minor popularity drift within ±5% tolerance → approve" {
    source_gate
    write_stub_admin_api
    export STUB_UNV_FILE="$TEST_ROOT/unv.json"
    export STUB_AP_FILE="$TEST_ROOT/ap.json"
    # Receipt says pop=68, live=70 → 2/68 = 2.9% drift, under 5%
    write_unv_fixture "$STUB_UNV_FILE" 694 70 50
    write_ap_fixture "$STUB_AP_FILE" 100
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    PROFILE_AUDIT_ID="drift-pid" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier0_audit_verified"* ]]
}

@test "tier0: profile_id 404s in admin API → reject profile_not_found_or_admin_error" {
    source_gate
    write_stub_admin_api
    export STUB_FAIL_HTTP=404
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    PROFILE_AUDIT_ID="ghost-pid" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"profile_not_found_or_admin_error"* ]]
}

@test "tier0: missing --profile-audit-id → reject" {
    source_gate
    write_stub_admin_api
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--profile-audit-id"* ]]
}

@test "tier0: flag/UVN paths unaffected (non-approve still passes through gate)" {
    # Sanity: a flag/UVN call (status != approved) bypasses the entire gate
    # regardless of receipt presence. Tier-0 added no new behavior here.
    source_gate
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=1.00,only_vel=1.00,br_max=1/1,roles_ok=1,art=1.00,lbl=1.00" \
    PROFILE_AUDIT_ID="any-pid" \
    run enforce_credit_approve_gate PATCH /admin/credit-requests/cr-1 '{"status":"user_verification_needed","reason":"x"}'
    [ "$status" -eq 0 ]
}

@test "tier0: browser-evidence excerpt (no profile_audit: prefix) still uses old path" {
    # Regression guard: presence of the new branch must NOT change browser
    # evidence behavior — a normal excerpt still hits the session-log scan.
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig engineer"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://allmusic.com/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig records"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

# --- resolve_slack_to_email + --requester parser robustness ---
# 2026-05-06: the global-options parser captured resolve_slack_to_email's
# return value via command substitution. For unknown inputs the function
# returns 1, and `set -e` then silently aborted the entire script — every
# bot self-approve via `--requester clio` hit this path. Two fixes:
#   1) Whitelist 'clio' as a recognized synthetic identity (return 0).
#   2) Add `|| REQUESTER_EMAIL="$2"` fallback so any future synthetic value
#      doesn't re-trigger the silent-exit failure mode.

@test "resolve_slack_to_email: 'clio' is a recognized synthetic identity" {
    source_gate
    run resolve_slack_to_email clio
    [ "$status" -eq 0 ]
    [ "$output" = "clio" ]
}

@test "resolve_slack_to_email: already-an-email passes through unchanged" {
    source_gate
    run resolve_slack_to_email jan@muso.ai
    [ "$status" -eq 0 ]
    [ "$output" = "jan@muso.ai" ]
}

@test "resolve_slack_to_email: known Slack ID resolves to email" {
    source_gate
    run resolve_slack_to_email U7RP6HKUZ
    [ "$status" -eq 0 ]
    [ "$output" = "aaron@muso.ai" ]
}

@test "resolve_slack_to_email: unknown bare value returns 1 (caller must handle)" {
    # Documents the failure mode the parser fallback defends against.
    source_gate
    run resolve_slack_to_email some_unknown_value
    [ "$status" -eq 1 ]
    [ "$output" = "some_unknown_value" ]
}

@test "--requester clio does NOT silently exit (regression for 2026-05-06 set -e bug)" {
    # Exercise the actual parser via subprocess. With the bug, the script
    # would abort silently mid-parse when resolve_slack_to_email returned 1
    # under `set -e`, producing no output and a non-zero exit. The
    # resolve-email dispatch command lets us test the parser without
    # touching MUSO_API_URL / admin creds.
    run bash "$WRAPPED" --requester clio resolve-email U7RP6HKUZ
    [ "$status" -eq 0 ]
    [ "$output" = "aaron@muso.ai" ]
}

@test "--requester unknown_value falls back to raw value (defense in depth)" {
    # Even if a future synthetic identity isn't whitelisted, the parser must
    # not silent-exit. The `|| REQUESTER_EMAIL=\"\$2\"` fallback handles
    # this: the gate's bypass case only matches jan@/aaron@, so an
    # unknown value is safe to carry through as-is.
    run bash "$WRAPPED" --requester some_future_bot resolve-email U7RP6HKUZ
    [ "$status" -eq 0 ]
    [ "$output" = "aaron@muso.ai" ]
}

# ===========================================================================
# CV_EVIDENCE_MODE=api — post-cutover default (2026-05-06)
# ===========================================================================
#
# These cases exercise the api-evidence path via lib/api-evidence.sh.
# CV_API_EVIDENCE_LIB points at the real lib in the source tree (the suite's
# wrapped-script trick rewrites /root/.openclaw-main paths but doesn't
# relocate the lib). count_profile_evidence_sources is the public function
# the gate calls; the lib has its own dedicated test suite — here we only
# verify the gate's plumbing is correct.

api_setup() {
    export CV_EVIDENCE_MODE=api
    export CV_API_EVIDENCE_LIB="${BATS_TEST_DIRNAME}/../../../muso-ops-credit-verification/scripts/lib/api-evidence.sh"
    [[ -f "$CV_API_EVIDENCE_LIB" ]] || { echo "api-evidence lib not found: $CV_API_EVIDENCE_LIB" >&2; return 1; }
    # Point the lib at the test session log via override so it scans the
    # same fixture write_session_log creates.
    export CV_SESSION_LOG_OVERRIDE="$TEST_ROOT/.openclaw-main/agents/operations/sessions/s.jsonl"
}

@test "api-mode: 2 distinct API helpers matching excerpt → approve" {
    api_setup
    source_gate
    write_session_log "s.jsonl" '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1 --credited-name Bram"}}]}}
{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder mastering for Yellow Submarine"}]}}
{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"bash discogs-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"c2","content":[{"type":"text","text":"Bram Fidder mastering credit on Discogs"}]}}'
    EVIDENCE_EXCERPT="Bram Fidder mastering" run enforce_credit_approve_gate \
        PUT /admin/credit-requests '{"requestIds":["cr_a"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "api-mode: 1 API helper + 1 AllMusic browser load → approve" {
    api_setup
    source_gate
    write_session_log "s.jsonl" '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder mastering for Yellow Submarine"}]}}
{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"b1","name":"browser","arguments":{"url":"https://www.allmusic.com/album/x"}}]}}
{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"b1","content":[{"type":"text","text":"AllMusic credits Bram Fidder mastering"}]}}'
    EVIDENCE_EXCERPT="Bram Fidder mastering" run enforce_credit_approve_gate \
        PUT /admin/credit-requests '{"requestIds":["cr_a"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "api-mode: 1 source only (under quorum) → reject with api-mode message" {
    api_setup
    source_gate
    write_session_log "s.jsonl" '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder mastering"}]}}'
    EVIDENCE_EXCERPT="Bram Fidder mastering" run enforce_credit_approve_gate \
        PUT /admin/credit-requests '{"requestIds":["cr_a"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"insufficient api-evidence"* ]]
    [[ "$output" == *"1/2"* ]]
    # Rollback hint mentioned so the operator knows the escape hatch.
    [[ "$output" == *"CV_EVIDENCE_MODE=browser"* ]]
}

@test "api-mode: web_fetch to Tier-1 host is NOT a contamination block (mode-irrelevant)" {
    # Under api-mode the gate doesn't care about web_fetch — that check was
    # browser-mode legacy. As long as the api evidence count is met, we're good.
    api_setup
    source_gate
    write_session_log "s.jsonl" '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"w1","name":"web_fetch","arguments":{"url":"https://musicbrainz.org/recording/x"}}]}}
{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"w1","content":[{"type":"text","text":"some JS shell"}]}}
{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder mastering"}]}}
{"timestamp":"2026-05-06T18:00:04Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"bash discogs-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:05Z","message":{"role":"toolResult","toolCallId":"c2","content":[{"type":"text","text":"Bram Fidder mastering Discogs"}]}}'
    EVIDENCE_EXCERPT="Bram Fidder mastering" run enforce_credit_approve_gate \
        PUT /admin/credit-requests '{"requestIds":["cr_a"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "api-mode: --evidence-excerpt is still required" {
    api_setup
    source_gate
    write_session_log "s.jsonl" '{}'
    EVIDENCE_EXCERPT="" run enforce_credit_approve_gate \
        PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "api-mode: Tier-0 profile_audit: receipt path still works under api default" {
    # Tier-0 receipt detection happens BEFORE the evidence-mode dispatch, so
    # it should remain fully functional under any CV_EVIDENCE_MODE. We don't
    # actually re-verify against admin API here (that's Tier-0 suite), only
    # confirm the gate routes the receipt to the tier0 path rather than the
    # api-evidence path.
    api_setup
    source_gate
    PROFILE_AUDIT_ID="pid-1" \
    EVIDENCE_EXCERPT="profile_audit:cc=694,pop=68,batch=50,industry=0.96,only_vel=1.00,br_max=1/1,roles_ok=1,art=0.56,lbl=0.46" \
        run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr_a"],"status":"approved"}'
    # We expect failure (no admin API in tests), but the failure should be
    # tier0-shaped (admin_api_unverified_failed or profile_not_found),
    # NOT api-evidence-shaped.
    [ "$status" -eq 1 ]
    [[ "$output" != *"insufficient api-evidence"* ]]
    [[ "$output" == *"tier0"* ]]
}

@test "api-mode: missing api-evidence lib → fail-fast with clear error" {
    api_setup
    source_gate
    export CV_API_EVIDENCE_LIB="/nonexistent/path/api-evidence.sh"
    write_session_log "s.jsonl" '{}'
    EVIDENCE_EXCERPT="anything" run enforce_credit_approve_gate \
        PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"lib/api-evidence.sh not found"* ]]
}

@test "both-mode: api passes → approve (browser path skipped)" {
    api_setup
    export CV_EVIDENCE_MODE=both
    source_gate
    write_session_log "s.jsonl" '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder mastering"}]}}
{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"bash discogs-isrc-lookup.sh USXX1"}}]}}
{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"c2","content":[{"type":"text","text":"Bram Fidder mastering Discogs"}]}}'
    EVIDENCE_EXCERPT="Bram Fidder mastering" run enforce_credit_approve_gate \
        PUT /admin/credit-requests '{"requestIds":["cr_a"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "both-mode: api fails → falls through to browser path (which also fails) → reject" {
    # Under both, api short-circuit wasn't met; we expect the legacy browser
    # path to run and (here) also fail because there are no Tier-1 browser
    # loads either. The combined gate refuses the approve.
    api_setup
    export CV_EVIDENCE_MODE=both
    source_gate
    write_session_log "s.jsonl" '{}'
    EVIDENCE_EXCERPT="anything goes" run enforce_credit_approve_gate \
        PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
    [ "$status" -eq 1 ]
}

@test "CV_EVIDENCE_MODE invalid value → fatal at script source time" {
    export CV_EVIDENCE_MODE=banana
    run bash -c "source '$WRAPPED'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CV_EVIDENCE_MODE must be one of"* ]]
}
