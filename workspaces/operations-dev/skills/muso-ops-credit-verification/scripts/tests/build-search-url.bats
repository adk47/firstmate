#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for build-search-url.sh — canonical URL builder for Tier-1 sources.
#
# Pinning: Tidal album-credits flag (new 2026-05-04). The credits panel
# lives on the album page, not the track page — so when the muso catalog
# surfaces a Tidal album ID via /admin/album/<id>/sources, we point the
# agent directly at /album/<id>/credits to skip the search-and-click chain.

setup() {
    setup_tmp_env
    SCRIPT="$SCRIPTS_DIR/build-search-url.sh"
    [[ -x "$SCRIPT" ]] || { echo "build-search-url.sh missing or not executable: $SCRIPT" >&2; return 1; }
}

teardown() { teardown_tmp_env; }

# --- Tidal precedence: album credits > track > search ----------------

@test "tidal: --tidal-album-id emits /album/<id>/credits" {
    run bash "$SCRIPT" --host tidal --credited-name "Anyone" \
                       --tidal-album-id 519563107
    [ "$status" -eq 0 ]
    [ "$output" = "https://tidal.com/album/519563107/credits" ]
}

@test "tidal: --tidal-album-id wins over --tidal-id (album credits panel preferred)" {
    # Album takes priority because the credits panel is on the album page,
    # not the track page. The track ID would only point at the player view.
    run bash "$SCRIPT" --host tidal --credited-name "X" --track-title "Y" \
                       --tidal-album-id 519563107 \
                       --tidal-id 514666065
    [ "$status" -eq 0 ]
    [ "$output" = "https://tidal.com/album/519563107/credits" ]
}

@test "tidal: only --tidal-id falls back to /browse/track/<id>" {
    run bash "$SCRIPT" --host tidal --credited-name "X" \
                       --tidal-id 514666065
    [ "$status" -eq 0 ]
    [ "$output" = "https://tidal.com/browse/track/514666065" ]
}

@test "tidal: no IDs falls back to /search?q=…" {
    run bash "$SCRIPT" --host tidal --credited-name "Person Name" \
                       --track-title "Track Name"
    [ "$status" -eq 0 ]
    [[ "$output" == https://tidal.com/search?q=* ]]
    [[ "$output" == *"Person%20Name%20Track%20Name"* ]]
}

# --- Other Tier-1 hosts: smoke pin so the new flag doesn't break them -

@test "apple: --apple-music-id direct URL" {
    run bash "$SCRIPT" --host apple --credited-name "X" --apple-music-id 12345
    [ "$status" -eq 0 ]
    [ "$output" = "https://music.apple.com/us/song/12345" ]
}

@test "apple: search fallback uses US storefront" {
    run bash "$SCRIPT" --host apple --credited-name "Anne" --track-title "Song"
    [ "$status" -eq 0 ]
    [[ "$output" == https://music.apple.com/us/search* ]]
}

@test "musicbrainz: --musicbrainz-id direct URL" {
    run bash "$SCRIPT" --host musicbrainz --credited-name "X" --musicbrainz-id abc-mbid
    [ "$status" -eq 0 ]
    [ "$output" = "https://musicbrainz.org/recording/abc-mbid" ]
}

# --- Argument validation ---------------------------------------------

@test "unknown flag → exit 2" {
    run --separate-stderr bash "$SCRIPT" --host tidal --credited-name "X" --bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown arg"* ]]
}

@test "missing --host → exit 2" {
    run --separate-stderr bash "$SCRIPT" --credited-name "X"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--host required"* ]]
}
