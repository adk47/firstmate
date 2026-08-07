#!/usr/bin/env bats
# Tests for the profile-enrich link gate added to muso-admin-api.sh after
# incident 2026-08-05 (third recurrence): ops created profile ylsvoid
# (15bb7a07-...), fired a Spotify capture, got {accepted:true, captureId:...},
# and the source never attached — because nothing in the request named the
# profile.
#
# Gate contract:
# - POST /admin/profile/enrichByUrl REQUIRES profileId in the body. A capture
#   binds to a muso profile only via extra_data.profile_id; without it the IDP
#   match cascade (sync_profile.py:486-504) has no name-matching rung and falls
#   through to _sync_new, minting a SEPARATE profile.
# - POST /admin/artist/<spotifyId>/enrich is refused outright — that route has
#   no profileId parameter at all, so no body shape makes it attach.
# - MUSO_ENRICH_STANDALONE=1 is the explicit opt-out for a genuinely standalone
#   catalog capture.
# - Fails CLOSED on an empty or unparseable body.
# - Runs even in dry-run: the defect is the request SHAPE, so a dry-run must not
#   report success for a call that can never work.
#
# Every BLOCKED (discrimination) case below is paired with an ALLOWED
# (stability) case — a gate that refuses everything passes a one-sided suite.
#
# NOTE on assertions: `run` captures stdout+stderr into $output and never
# trips set -e. Bare `! cmd` is a NO-OP in bats unless it is the final line,
# so blocked cases assert on $status explicitly.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port so any real HTTP fails loudly. Blocked cases short-circuit
    # before curl; allowed cases fall through to curl (which fails), so the
    # ALLOWED assertions check for the ABSENCE of a gate token rather than a
    # successful HTTP result.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"

    # Test-scoped state so we never write to /var/log/muso-ops.
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/state/destructive-ops.jsonl"
    export BULK_DESTRUCTIVE_AUDIT_PATH="$TEST_ROOT/state/bulk-destructive-audit.jsonl"

    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    export BULK_DESTRUCTIVE_EXCLUDE_PATH="$TEST_ROOT/bulk-destructive-exclude.txt"
    printf '%s\n' "# test approvers" "aaron@muso.ai" > "$TIER2_APPROVERS_PATH"
    printf '%s\n' "POST /admin/profiles/merge" > "$TIER2_ENDPOINTS_PATH"
    printf '%s\n' "/admin/profile/*/cache" > "$BULK_DESTRUCTIVE_EXCLUDE_PATH"

    export CV_APPROVE_GATE_DISABLED=1
    # The codex model-health gate runs first on every write; stub it healthy so
    # these downstream-gate tests stay hermetic (production has no bypass flag).
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/dry-run-audit.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

URL='https://open.spotify.com/artist/4kYSro6naA4h99UJvo89HB'
PID='15bb7a07-7249-4405-a37a-7255d1cb9321'

# --- enrichByUrl: the profileId requirement ---

@test "enrichByUrl WITH profileId passes the gate" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "enrichByUrl WITHOUT profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "enrichByUrl with profileId null is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":null}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "enrichByUrl with profileId empty-string is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

# The gate parses the body the way core-backend's JSON.parse does. A
# \uXXXX-escaped key is invisible to a line-oriented grep (verified: grep -c
# '"profileId"' returns 0 on this body) but resolves correctly for jq — so a
# grep-based gate would refuse a VALID call.
@test "enrichByUrl with a unicode-escaped profileId key passes (structural parse, not grep)" {
    local esc_key
    esc_key="$(printf '\\u0070')rofileId"
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"${esc_key}\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- Fail-closed on bodies the gate cannot read ---

@test "enrichByUrl with a non-JSON body is BLOCKED (fail closed)" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl 'not json at all'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_BODY_UNPARSEABLE"* ]]
}

@test "enrichByUrl with an empty body is BLOCKED (fail closed)" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl ''
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_BODY_UNPARSEABLE"* ]]
}

# --- The artist route can never link ---

@test "POST /admin/artist/<id>/enrich is BLOCKED outright" {
    run bash "$SCRIPT" call POST /admin/artist/4kYSro6naA4h99UJvo89HB/enrich
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_CANNOT_LINK"* ]]
}

@test "the artist-route refusal names the correct replacement call" {
    run bash "$SCRIPT" call POST /admin/artist/4kYSro6naA4h99UJvo89HB/enrich
    [ "$status" -eq 1 ]
    [[ "$output" == *"/admin/profile/enrichByUrl"* ]]
    [[ "$output" == *"profileId"* ]]
}

# The refusal text is what the agent reads at the moment it is blocked, so it
# outranks any SKILL.md prose. It must kill the "wait and re-check" reflex that
# turned this into three escalations.
@test "refusal messages say waiting will never help" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"NEVER"* ]]

    run bash "$SCRIPT" call POST /admin/artist/abc/enrich
    [ "$status" -eq 1 ]
    [[ "$output" == *"NEVER"* ]]
}

# --- The standalone override ---

@test "MUSO_ENRICH_STANDALONE=1 allows the artist route" {
    MUSO_ENRICH_STANDALONE=1 run bash "$SCRIPT" call POST /admin/artist/abc/enrich
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "MUSO_ENRICH_STANDALONE=1 allows enrichByUrl without profileId" {
    MUSO_ENRICH_STANDALONE=1 run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- The gate must not widen beyond the two profile-capture routes ---

@test "track enrichByUrl is NOT gated (no profileId concept there)" {
    run bash "$SCRIPT" call POST /admin/track/enrichByUrl \
        '{"enrichmentUrl":"https://open.spotify.com/track/2bB1wffMW7q22y7ByfruDg"}'
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "album enrichByUrl is NOT gated" {
    run bash "$SCRIPT" call POST /admin/album/enrichByUrl \
        '{"enrichmentUrl":"https://open.spotify.com/album/abc"}'
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "an unrelated profile POST is NOT gated" {
    run bash "$SCRIPT" call POST /admin/profile/collaborators/rebuild '{}'
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "GET on the gated path is NOT blocked (reads pass)" {
    run bash "$SCRIPT" call GET /admin/profile/enrichByUrl
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- Case normalization + dry-run ---

@test "lower-case 'post' is gated the same as POST" {
    run bash "$SCRIPT" call post /admin/profile/enrichByUrl "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

# Unlike the other write gates, this one does NOT self-skip in dry-run: the
# defect is the request shape, so a dry-run that reported success for an
# unlinkable call would validate exactly the mistake being prevented.
#
# Both dry-run tests assert on the dry-run AUDIT ROW as well as the gate token.
# Without that, they would pass even if OPS_DRY_RUN never reached the script
# (the blocked case blocks in either mode, and the allowed case falls through to
# a failing curl in either mode) — i.e. they would prove nothing about dry-run.
@test "the gate still fires in dry-run mode, before the dry-run short-circuit" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
    # Blocked BEFORE the short-circuit, so no would-be-write was ever recorded.
    [ ! -s "$OPS_DRY_RUN_AUDIT_PATH" ]
}

@test "a well-formed call still reaches the dry-run short-circuit" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
    # Positive proof dry-run was genuinely active AND the gate let the call
    # through to it: the would-be write was recorded.
    [ -s "$OPS_DRY_RUN_AUDIT_PATH" ]
    run jq -r '.path' "$OPS_DRY_RUN_AUDIT_PATH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/admin/profile/enrichByUrl"* ]]
}

# --- Path normalization: the near-miss shapes that silently bypassed the gate ---
#
# cmd_call forwards $path to curl verbatim, so an exact-string route match let
# `?query` and a trailing `/` through on the very route this gate targets.
# is_tier2_endpoint / is_bulk_destructive_op already strip the query string for
# this reason; this gate now mirrors them. Caught by the ship-stage review, not
# by the original suite — the first version of these tests only ever exercised
# the canonical path spelling.

@test "enrichByUrl with a query string is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl?force=true" \
        "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "enrichByUrl with a trailing slash is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl/" \
        "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "the artist route with a query string is still gated" {
    run bash "$SCRIPT" call POST "/admin/artist/abc/enrich?priority=high"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_CANNOT_LINK"* ]]
}

@test "the artist route with a trailing slash is still gated" {
    run bash "$SCRIPT" call POST "/admin/artist/abc/enrich/"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_CANNOT_LINK"* ]]
}

# Stability half: normalization must not drag UNRELATED routes into the gate.
@test "normalization does not over-match a different route with a query string" {
    run bash "$SCRIPT" call POST "/admin/track/enrichByUrl?force=true" \
        '{"enrichmentUrl":"https://open.spotify.com/track/abc"}'
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "a well-formed call with a query string still passes" {
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl?force=true" \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- Path spellings that reach the SAME route (found by the ship-stage
# adversarial review, each verified live against a real Express app / raw
# socket capture before being fixed) ---
#
# curl resolves dot-segments and strips the fragment before the request leaves
# the machine, and Express routes case-insensitively by default — so every
# spelling below hits the identical handler as the canonical path while a
# literal bash match sees a different string.

@test "uppercase path segments are still gated" {
    run bash "$SCRIPT" call POST "/ADMIN/profile/ENRICHBYURL" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "the artist route in uppercase is still gated" {
    run bash "$SCRIPT" call POST "/admin/artist/ABC123/ENRICH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_CANNOT_LINK"* ]]
}

@test "a /./ dot-segment is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/./enrichByUrl" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "a /../ traversal spelling is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/x/../enrichByUrl" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "a URL fragment is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl#frag" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "repeated and multiple trailing slashes are still gated" {
    run bash "$SCRIPT" call POST "/admin//profile///enrichByUrl//" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

# Stability: normalization must not drag a DIFFERENT route into the gate.
@test "normalization does not over-match the track route in mixed case" {
    run bash "$SCRIPT" call POST "/ADMIN/TRACK/enrichByUrl" \
        '{"enrichmentUrl":"https://open.spotify.com/track/abc"}'
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- profileId must be a USABLE link, not merely present ---
#
# jq's `// empty` only rejects null/false/"". Every other JSON type is truthy,
# so a number/bool/array/object sailed through and reproduced the incident
# exactly: accepted:true, then muso_profile_id matches no CatalogProfile.

@test "a numeric profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":12345}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_NOT_A_STRING"* ]]
}

@test "a boolean profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":true}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_NOT_A_STRING"* ]]
}

@test "an array profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":[]}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_NOT_A_STRING"* ]]
}

@test "an object profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":{}}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_NOT_A_STRING"* ]]
}

@test "a whitespace-only profileId is BLOCKED as missing" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"   \"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "a non-UUID string profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"9001\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_MALFORMED"* ]]
}

# Stability half: a real UUID must still pass, in either case.
@test "an uppercase UUID profileId still passes" {
    local upper_pid
    upper_pid="$(printf %s "$PID" | tr '[:lower:]' '[:upper:]')"
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$upper_pid\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- cmd_upload is a second path to curl ---
#
# The gate was wired only into cmd_call, so `upload` bypassed it entirely.

@test "upload to the artist enrich route is gated too" {
    local f="$TEST_ROOT/payload.txt"; printf 'x' > "$f"
    run bash "$SCRIPT" upload /admin/artist/abc/enrich "$f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_CANNOT_LINK"* ]]
}

@test "upload to an unrelated route is NOT gated" {
    local f="$TEST_ROOT/payload.txt"; printf 'x' > "$f"
    run bash "$SCRIPT" upload /admin/profile/9001/image "$f"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- Boundary dot-segment forms (QA review on #805, Important) ---
#
# The first canonicalizer handled only "/./" and "/seg/../", both of which
# require a FOLLOWING slash, so terminal and root-leading forms stayed
# non-canonical and slipped the match. Verified on the wire with a raw socket:
# curl sends "/admin/profile/enrichByUrl/." as ".../enrichByUrl/" and
# "/../admin/profile/enrichByUrl" as the exact canonical path — both reach the
# live Express route. normalize_admin_path is now RFC 3986 5.2.4 complete.

@test "a terminal /. dot-segment is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl/." "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "a root-leading /../ dot-segment is still gated" {
    run bash "$SCRIPT" call POST "/../admin/profile/enrichByUrl" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

@test "a terminal /. on the artist route is still gated" {
    run bash "$SCRIPT" call POST "/admin/artist/abc/enrich/."
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_CANNOT_LINK"* ]]
}

@test "a terminal /./ combination is still gated" {
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl/./" "{\"enrichmentUrl\":\"$URL\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

# Stability halves: full dot-segment resolution must not pull in a route the
# gate has no business refusing, and must not break the well-formed call.
@test "dot-segment resolution does not over-match the track route" {
    run bash "$SCRIPT" call POST "/admin/track/enrichByUrl/." \
        '{"enrichmentUrl":"https://open.spotify.com/track/abc"}'
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "a /.. that resolves AWAY from the route is not gated" {
    # /admin/profile/enrichByUrl/.. resolves to /admin/profile — a different
    # route entirely, so refusing it would be over-matching.
    run bash "$SCRIPT" call POST "/admin/profile/enrichByUrl/.."
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "a well-formed call survives full dot-segment normalization" {
    run bash "$SCRIPT" call POST "/admin/profile/./enrichByUrl" \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

# --- profileId must be usable AS SENT, not after cleanup (QA review on #805) ---
#
# cmd_call sends $body to curl byte-for-byte (curl_args+=(-d "$body")), so
# validating only a trimmed copy blesses a value the backend never receives:
# " <uuid> " arrives WITH the padding, matches no profile, and the capture is
# accepted and attaches to nothing — the exact incident. The gate refuses rather
# than rewriting the caller's body.

@test "a space-padded profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\" $PID \"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

@test "a leading-space profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\" $PID\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

@test "a trailing-tab profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"${PID}\\t\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

@test "the whitespace refusal shows the corrected value to send" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\" $PID \"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"\"profileId\":\"$PID\""* ]]
}

# Stability half: the unpadded id must still pass, and a whitespace-only value
# must still report as MISSING rather than as padding.
@test "an unpadded UUID profileId still passes" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "a whitespace-only profileId is still MISSING, not padding" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"   \"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_MISSING_PROFILE_ID"* ]]
}

# --- Trailing decoded newline (QA review on #805, Important) ---
#
# $(jq -r .profileId) strips ALL trailing newline bytes — command substitution
# does — so {"profileId":"<uuid>\n"} arrived inside the gate as a bare UUID and
# passed, while the unchanged body still decoded to UUID+newline for the API and
# matched no profile. Validation now happens INSIDE jq and only a short verdict
# token crosses the shell boundary. Also note jq/Oniguruma `$` matches BEFORE a
# trailing newline (verified), so the anchors are \A and \z plus length==36.

@test "a trailing-newline profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"${PID}\\n\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

@test "a leading-newline profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"\\n${PID}\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

@test "multiple trailing newlines are BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"${PID}\\n\\n\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

@test "a carriage-return padded profileId is BLOCKED" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"${PID}\\r\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE"* ]]
}

# A UUID with a newline in the MIDDLE is not padding — it is simply not a UUID.
@test "an embedded newline reports MALFORMED, not whitespace" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"15bb7a07\\n7249-4405-a37a-7255d1cb9321\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_ENRICH_PROFILE_ID_MALFORMED"* ]]
}

# The refusal must render the invisible byte, not print a wrecked message.
@test "the whitespace refusal shows the padding as an escape, not a raw newline" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"${PID}\\n\"}"
    [ "$status" -eq 1 ]
    [[ "$output" == *'\n'* ]]
}

# Stability half: the clean id must still pass through the jq-driven path.
@test "a clean UUID still passes the jq-driven validation" {
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$PID\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}

@test "an uppercase UUID still passes the jq-driven validation" {
    local upper_pid
    upper_pid="$(printf %s "$PID" | tr '[:lower:]' '[:upper:]')"
    run bash "$SCRIPT" call POST /admin/profile/enrichByUrl \
        "{\"enrichmentUrl\":\"$URL\",\"profileId\":\"$upper_pid\"}"
    [[ "$output" != *"MUSO_ENRICH_"* ]]
}
