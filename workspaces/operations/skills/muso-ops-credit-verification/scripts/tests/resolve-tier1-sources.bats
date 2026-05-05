#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for resolve-tier1-sources.sh — backend Tier-1 source resolver.
#
# This script is the single place that knows how to walk muso's admin API
# to surface backend-known Tier-1 source URLs (today: Tidal album-credits)
# for a credit-request item. SKILL.md B3's three-branch decision tree
# consumes the {backend_tier1_count, ...} envelope it emits.
#
# Failure semantics: the envelope is ALWAYS valid JSON on stdout and the
# script always exits 0 unless required args are missing. Network /
# wrapper / shape failures degrade silently to count=0 with the affected
# fields null — callers (fetch-queue.sh) do not need to special-case
# anything.

setup() {
    setup_tmp_env
    SCRIPT="$SCRIPTS_DIR/resolve-tier1-sources.sh"
    [[ -x "$SCRIPT" ]] || { echo "resolve-tier1-sources.sh missing or not executable: $SCRIPT" >&2; return 1; }

    ADMIN_LOG="$TEST_TMPDIR/admin-invocations.log"
    export ADMIN_LOG

    # Stub muso-admin-api.sh keyed off path ($3 of `call GET <path>`).
    # Behaviors are selected via env so each test can pin a scenario.
    ADMIN_API_SH="$TEST_TMPDIR/fake-muso-admin-api.sh"
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
{
    printf 'ARGS:'
    for a in "$@"; do printf '\n  %s' "$a"; done
    printf '\n'
} >> "${ADMIN_LOG:-/dev/null}"

# Sub-mode env knobs (per path):
#   STUB_TRACK_MODE        ok | not_found | wrapper_fail
#   STUB_ALBUM_SOURCES_MODE has_tidal | no_tidal | not_found
#   STUB_TRACK_SOURCES_MODE has_tidal | no_tidal
url="${3:-}"

if [[ "$url" =~ ^/admin/track/[^/]+/sources$ ]]; then
    case "${STUB_TRACK_SOURCES_MODE:-has_tidal}" in
        has_tidal)
            printf '%s\n' '{"http_status":200,"body":{"data":{"sources":[{"source":"tidal","items":[{"id":"514666065","url":"https://listen.tidal.com/track/514666065"}]}]}}}'
            ;;
        no_tidal)
            printf '%s\n' '{"http_status":200,"body":{"data":{"sources":[]}}}'
            ;;
    esac
    exit 0
fi

if [[ "$url" =~ ^/admin/track/[^/]+$ ]]; then
    case "${STUB_TRACK_MODE:-ok}" in
        ok)
            printf '%s\n' '{"http_status":200,"body":{"data":{"id":"T1","album":{"id":"A1"}}}}'
            ;;
        not_found)
            printf '%s\n' '{"http_status":404,"body":{"error":"track not found"}}'
            ;;
        wrapper_fail)
            echo "stub: wrapper crash" >&2
            exit 7
            ;;
    esac
    exit 0
fi

if [[ "$url" =~ ^/admin/album/[^/]+/sources$ ]]; then
    case "${STUB_ALBUM_SOURCES_MODE:-has_tidal}" in
        has_tidal)
            printf '%s\n' '{"http_status":200,"body":{"data":{"sources":[{"source":"spotify","items":[{"id":"S1"}]},{"source":"tidal","items":[{"id":"514666056","url":"https://listen.tidal.com/album/514666056"}]}]}}}'
            ;;
        no_tidal)
            printf '%s\n' '{"http_status":200,"body":{"data":{"sources":[{"source":"spotify","items":[{"id":"S1"}]}]}}}'
            ;;
        not_found)
            printf '%s\n' '{"http_status":404,"body":{"error":"album not found"}}'
            ;;
    esac
    exit 0
fi

echo "stub: unrecognized URL: $url" >&2
exit 98
STUB
    chmod +x "$ADMIN_API_SH"
    export ADMIN_API_SH
}

teardown() { teardown_tmp_env; }

# --- Happy path -------------------------------------------------------

@test "track + album sources both have tidal → backend_tier1_count=1, credits URL populated" {
    STUB_TRACK_MODE=ok \
    STUB_ALBUM_SOURCES_MODE=has_tidal \
    STUB_TRACK_SOURCES_MODE=has_tidal \
        run bash "$SCRIPT" --track-id T1 --cr-id CR1
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == "T1"
      and .muso_album_id == "A1"
      and .tidal_album_id == "514666056"
      and .tidal_album_credits_url == "https://tidal.com/album/514666056/credits"
      and .tidal_track_id == "514666065"
      and .tidal_track_url == "https://listen.tidal.com/track/514666065"
      and .backend_tier1_count == 1
    ' >/dev/null
}

# --- Track 404 ---------------------------------------------------------

@test "track endpoint 404 → all-null envelope (except muso_track_id), count 0" {
    # muso_track_id is the input echo, kept for diagnostic correlation.
    # Everything else (album, tidal) is null because we couldn't hop to
    # the album to look up sources.
    STUB_TRACK_MODE=not_found \
        run bash "$SCRIPT" --track-id Tmissing --cr-id CR2
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == "Tmissing"
      and .muso_album_id == null
      and .tidal_album_id == null
      and .tidal_album_credits_url == null
      and .backend_tier1_count == 0
    ' >/dev/null
}

# --- Album sources has no tidal ---------------------------------------

@test "album sources has no tidal item → tidal fields null, count 0" {
    STUB_TRACK_MODE=ok \
    STUB_ALBUM_SOURCES_MODE=no_tidal \
    STUB_TRACK_SOURCES_MODE=no_tidal \
        run bash "$SCRIPT" --track-id T1 --cr-id CR3
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == "T1"
      and .muso_album_id == "A1"
      and .tidal_album_id == null
      and .tidal_album_credits_url == null
      and .tidal_track_id == null
      and .tidal_track_url == null
      and .backend_tier1_count == 0
    ' >/dev/null
}

# --- v1: no muso track id, only spotify_track_id ----------------------

@test "only --spotify-track-id supplied → all-null envelope, count 0 (v1 behavior)" {
    # v1 does NOT do spotify_track_id → muso_track_id resolution. If trackId
    # is null at fetch time, the agent runs the full search-and-click chain;
    # we don't try to recover here.
    run bash "$SCRIPT" --spotify-track-id SP1 --cr-id CR4
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == null
      and .muso_album_id == null
      and .tidal_album_id == null
      and .backend_tier1_count == 0
    ' >/dev/null

    # And the admin-api wrapper must NOT have been called at all — saves
    # ~2 round-trips per item where the muso catalog won't help anyway.
    [ ! -s "$ADMIN_LOG" ] || { echo "stub got called for spotify-only branch — should be skipped"; cat "$ADMIN_LOG"; false; }
}

# --- Argument validation ----------------------------------------------

@test "missing both --track-id and --spotify-track-id → exit 2 with usage error" {
    run --separate-stderr bash "$SCRIPT" --cr-id CR5
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--track-id or --spotify-track-id required"* ]]
    [ -z "$output" ]
}

@test "unknown flag → exit 2" {
    run --separate-stderr bash "$SCRIPT" --bogus-flag x --track-id T1
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown arg"* ]]
}

# --- Admin-API wrapper failure modes ----------------------------------

@test "admin-api wrapper non-zero exit → all-null envelope, count 0, stderr captured" {
    STUB_TRACK_MODE=wrapper_fail \
        run --separate-stderr bash "$SCRIPT" --track-id T1 --cr-id CR6
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == "T1"
      and .muso_album_id == null
      and .backend_tier1_count == 0
    ' >/dev/null
    [[ "$stderr" == *"admin-api wrapper exited rc"* ]]
    [[ "$stderr" == *"cr=CR6"* ]]
}

@test "ADMIN_API_SH path missing → all-null envelope, count 0" {
    # bash <nonexistent> exits with rc 127. The script must not blow up.
    ADMIN_API_SH=/nonexistent/path-to-muso-admin-api.sh \
        run --separate-stderr bash "$SCRIPT" --track-id T1 --cr-id CR7
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.backend_tier1_count == 0' >/dev/null
    [[ "$stderr" == *"admin-api wrapper exited rc"* ]]
}

# --- Album sources 404 (track ok, album lookup miss) ------------------

@test "album sources endpoint 404 → tidal fields null, count 0" {
    STUB_TRACK_MODE=ok \
    STUB_ALBUM_SOURCES_MODE=not_found \
    STUB_TRACK_SOURCES_MODE=no_tidal \
        run bash "$SCRIPT" --track-id T1 --cr-id CR8
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == "T1"
      and .muso_album_id == "A1"
      and .tidal_album_id == null
      and .backend_tier1_count == 0
    ' >/dev/null
}

# --- Live API shape: body.data is a bare array (not body.data.sources) -

@test "live shape: /admin/album/<id>/sources returns body.data as bare array" {
    # The live muso admin API on hydra emits the sources list directly at
    # .body.data (not .body.data.sources). Pin this shape so the alternation
    # `(.body.data.sources?) // .body.data // []` keeps handling both.
    # 2026-05-04: smoke-test against production track fb2c1729-... initially
    # threw "Cannot index array with string sources" because the original
    # `// .body.data` alternation never reached its second branch.
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "$@"; do printf '\n  %s' "$a"; done; printf '\n'; } >> "${ADMIN_LOG:-/dev/null}"
url="${3:-}"
case "$url" in
  /admin/track/Tlive)
    printf '%s\n' '{"http_status":200,"body":{"data":{"album":{"id":"Alive"}}}}' ;;
  /admin/album/Alive/sources)
    # Bare array shape — no .sources wrapper.
    printf '%s\n' '{"http_status":200,"body":{"data":[{"source":"spotify","items":[{"id":"sp_1"}]},{"source":"tidal","items":[{"id":"519563107"}]}]}}' ;;
  /admin/track/Tlive/sources)
    printf '%s\n' '{"http_status":200,"body":{"data":[{"source":"tidal","items":[{"id":"514666065","url":"https://listen.tidal.com/track/514666065"}]}]}}' ;;
  *) echo "stub: unrecognized URL: $url" >&2; exit 98 ;;
esac
STUB
    chmod +x "$ADMIN_API_SH"

    run bash "$SCRIPT" --track-id Tlive --cr-id CR_LIVE
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .muso_track_id == "Tlive"
      and .muso_album_id == "Alive"
      and .tidal_album_id == "519563107"
      and .tidal_album_credits_url == "https://tidal.com/album/519563107/credits"
      and .tidal_track_id == "514666065"
      and .backend_tier1_count == 1
    ' >/dev/null
}

# --- Output shape contract --------------------------------------------

@test "stdout is exactly one compact JSON line" {
    STUB_TRACK_MODE=ok STUB_ALBUM_SOURCES_MODE=has_tidal STUB_TRACK_SOURCES_MODE=has_tidal \
        run bash "$SCRIPT" --track-id T1
    [ "$status" -eq 0 ]
    # Single line, no embedded newlines
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
    # All required keys present
    echo "$output" | jq -e '
      has("muso_track_id") and has("muso_album_id")
      and has("tidal_track_id") and has("tidal_track_url")
      and has("tidal_album_id") and has("tidal_album_credits_url")
      and has("backend_tier1_count")
    ' >/dev/null
}
