#!/usr/bin/env bats
# Tests for enforce_credit_approve_gate() in muso-admin-api.sh.
# Browser-only + content-match flavor (Phase 2).

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    mkdir -p "$TEST_ROOT/.openclaw-main/agents/operations/sessions"
    mkdir -p "$TEST_ROOT/.openclaw-dev/agents/operations-dev/sessions"

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    WRAPPED="$TEST_ROOT/muso-admin-api.sh"
    sed "s|/root/.openclaw-main/agents|$TEST_ROOT/.openclaw-main/agents|g; s|/root/.openclaw-dev/agents|$TEST_ROOT/.openclaw-dev/agents|g" "$SCRIPT" > "$WRAPPED"
    chmod +x "$WRAPPED"

    unset REQUESTER_EMAIL CV_APPROVE_GATE_DISABLED EVIDENCE_EXCERPT
    export CV_REQUIRED_LOADS=2
    export CV_SESSION_MAX_AGE_MIN=10
    export CV_EVIDENCE_EXCERPT_MIN=8
    export CV_EVIDENCE_EXCERPT_MAX=200
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

@test "Apple Music + TIDAL count as Tier 1" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://music.apple.com/us/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig artist page"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://tidal.com/browse/artist/xyz"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig credits"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
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

@test "allow: Spotify (open.spotify.com) counts as Tier 1" {
    source_gate
    write_session_log "s.jsonl" '{"message":{"content":[{"type":"toolCall","id":"tc-1","name":"browser","arguments":{"url":"https://open.spotify.com/artist/6gKqRTREnE0NInWDiBhEzY"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-1","toolName":"browser","content":[{"type":"text","text":"Jose Roig - Artist page on Spotify"}]}}
{"message":{"content":[{"type":"toolCall","id":"tc-2","name":"browser","arguments":{"url":"https://musicbrainz.org/artist/abc"}}]}}
{"message":{"role":"toolResult","toolCallId":"tc-2","toolName":"browser","content":[{"type":"text","text":"Jose Roig, Spanish engineer"}]}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 0 ]
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
{"message":{"content":[{"type":"toolCall","id":"wf-1","name":"web_fetch","arguments":{"url":"https://open.spotify.com/artist/xyz"}}]}}
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

    write_session_log "s.jsonl" '{"type":"message","timestamp":"2026-04-22T10:00:00Z","message":{"content":[{"type":"toolCall","id":"old-wf","name":"web_fetch","arguments":{"url":"https://open.spotify.com/artist/contaminated"}}]}}
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

    write_session_log "s.jsonl" '{"type":"message","timestamp":"2026-04-23T12:05:00Z","message":{"content":[{"type":"toolCall","id":"new-wf","name":"web_fetch","arguments":{"url":"https://open.spotify.com/artist/bad"}}]}}
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
{"message":{"content":[{"type":"toolCall","id":"wf-blocked","name":"web_fetch","arguments":{"url":"https://open.spotify.com/artist/drake"}}]}}
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
{"message":{"content":[{"type":"toolCall","id":"wf-real","name":"web_fetch","arguments":{"url":"https://open.spotify.com/artist/drake"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-real","toolName":"web_fetch","content":[{"type":"text","text":"<html>Drake - Artist page on Spotify - 80M monthly listeners</html>"}],"isError":false}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"web_fetch call(s) to Tier 1"* ]]
    [[ "$output" == *"open.spotify.com"* ]]
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
{"message":{"content":[{"type":"toolCall","id":"wf-blocked","name":"web_fetch","arguments":{"url":"https://open.spotify.com/artist/drake"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-blocked","toolName":"web_fetch","content":[{"type":"text","text":"blocked"}],"details":{"status":"error"},"isError":false}}
{"message":{"content":[{"type":"toolCall","id":"wf-real","name":"web_fetch","arguments":{"url":"https://musicbrainz.org/search?query=x"}}]}}
{"message":{"role":"toolResult","toolCallId":"wf-real","toolName":"web_fetch","content":[{"type":"text","text":"<html>MusicBrainz search results with real data</html>"}],"isError":false}}'
    EVIDENCE_EXCERPT="Jose Roig" run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr-1"],"status":"approved"}'
    [ "$status" -eq 1 ]
    # Should only name the successful host (musicbrainz.org), not spotify.
    [[ "$output" == *"musicbrainz.org"* ]]
    [[ "$output" != *"open.spotify.com"* ]]
}
