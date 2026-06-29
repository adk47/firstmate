#!/usr/bin/env bash
# build-search-url.sh — emit canonical URLs for Tier-1 sources.
#
# Replaces ad-hoc URL composition by the investigation subagent. Two modes:
#
# 1. Direct ID (preferred): when an external ID is provided (--spotify-id,
#    --isrc, --apple-music-id, --musicbrainz-id, --tidal-id, --discogs-id)
#    the URL points straight at the entity. No search needed.
#
# 2. Search fallback: when no ID is available, build a search URL with
#    proper URL-encoding (jq @uri) and the platform's REAL search path.
#    The previous agent-improvised URLs failed for two reasons —
#    unencoded spaces ("Sarpey zero esperanza") and wrong path shape
#    (Spotify is /search?q=… not /search/<query>/tracks).
#
# Usage:
#   build-search-url.sh --host <name> --credited-name X [--track-title Y] [--role Z]
#                       [--spotify-id ID] [--isrc CODE] [--apple-music-id ID]
#                       [--musicbrainz-id MBID] [--tidal-id ID] [--discogs-id ID]
#                       [--entity track|artist]   # default: track
#
# Stdout: a single absolute URL (no trailing newline). Empty if --host
#         unrecognised.
# Exit codes:
#   0 = URL emitted
#   2 = invalid args / unrecognised host
#
# Hosts: spotify, apple, musicbrainz, discogs, allmusic, tidal
#
# Encoding: jq's `@uri` is the only encoder we use — handles spaces,
# quotes, colons, ampersands consistently across platforms.

set -euo pipefail

HOST=""; CREDITED_NAME=""; TRACK_TITLE=""
SPOTIFY_TRACK_ID=""; SPOTIFY_ARTIST_ID=""
ISRC=""; APPLE_ID=""; MB_ID=""; TIDAL_ID=""; TIDAL_ALBUM_ID=""; DISCOGS_ID=""
ENTITY="track"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)              HOST="$2"; shift 2 ;;
    --credited-name)     CREDITED_NAME="$2"; shift 2 ;;
    --track-title)       TRACK_TITLE="$2"; shift 2 ;;
    --spotify-track-id|--spotify-id) SPOTIFY_TRACK_ID="$2"; shift 2 ;;
    --spotify-artist-id) SPOTIFY_ARTIST_ID="$2"; shift 2 ;;
    --isrc)              ISRC="$2"; shift 2 ;;
    --apple-music-id)    APPLE_ID="$2"; shift 2 ;;
    --musicbrainz-id|--mbid) MB_ID="$2"; shift 2 ;;
    --tidal-id)          TIDAL_ID="$2"; shift 2 ;;
    --tidal-album-id)    TIDAL_ALBUM_ID="$2"; shift 2 ;;
    --discogs-id)        DISCOGS_ID="$2"; shift 2 ;;
    --entity)            ENTITY="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "ERROR: --host required" >&2; exit 2; }
[[ -n "$CREDITED_NAME" ]] || { echo "ERROR: --credited-name required" >&2; exit 2; }

# URL-encode helper. jq @uri encodes per RFC 3986 (reserved + space + quote).
url_encode() {
  jq -nrR --arg s "$1" '$s | @uri' 2>/dev/null
}

# Build a "credited_name + track_title" search query, trimming to non-empty.
search_query() {
  if [[ -n "$TRACK_TITLE" ]]; then
    printf '%s %s' "$CREDITED_NAME" "$TRACK_TITLE"
  else
    printf '%s' "$CREDITED_NAME"
  fi
}

case "$HOST" in
  spotify|open.spotify.com)
    # Pick the most specific direct URL available: track > artist > search.
    # When --entity is explicitly "artist" prefer the artist ID; otherwise
    # fall through to the most specific anchor we have.
    if [[ "$ENTITY" == "artist" && -n "$SPOTIFY_ARTIST_ID" ]]; then
      printf 'https://open.spotify.com/artist/%s' "$SPOTIFY_ARTIST_ID"
    elif [[ -n "$SPOTIFY_TRACK_ID" ]]; then
      printf 'https://open.spotify.com/track/%s' "$SPOTIFY_TRACK_ID"
    elif [[ -n "$SPOTIFY_ARTIST_ID" ]]; then
      printf 'https://open.spotify.com/artist/%s' "$SPOTIFY_ARTIST_ID"
    else
      printf 'https://open.spotify.com/search/%s/%ss' "$(url_encode "$(search_query)")" "$ENTITY"
    fi
    ;;
  apple|music.apple.com|applemusic)
    if [[ -n "$APPLE_ID" ]]; then
      # Apple's track URL needs both album and song id; without that, search.
      printf 'https://music.apple.com/us/song/%s' "$APPLE_ID"
    else
      printf 'https://music.apple.com/us/search?term=%s' "$(url_encode "$(search_query)")"
    fi
    ;;
  musicbrainz|musicbrainz.org|mb)
    if [[ -n "$MB_ID" ]]; then
      printf 'https://musicbrainz.org/recording/%s' "$MB_ID"
    elif [[ -n "$ISRC" ]]; then
      # ISRC lookup endpoint returns matching recordings.
      printf 'https://musicbrainz.org/isrc/%s' "$(url_encode "$ISRC")"
    elif [[ "$ENTITY" == "artist" ]]; then
      printf 'https://musicbrainz.org/search?query=%s&type=artist' "$(url_encode "$CREDITED_NAME")"
    else
      # MB advanced search: scope query to recording field for tighter matches.
      local_query=$(printf 'recording:"%s" AND artist:"%s"' "$TRACK_TITLE" "$CREDITED_NAME")
      printf 'https://musicbrainz.org/search?query=%s&type=recording' "$(url_encode "$local_query")"
    fi
    ;;
  discogs|www.discogs.com)
    if [[ -n "$DISCOGS_ID" ]]; then
      printf 'https://www.discogs.com/release/%s' "$DISCOGS_ID"
    else
      printf 'https://www.discogs.com/search/?q=%s&type=release' "$(url_encode "$(search_query)")"
    fi
    ;;
  allmusic|www.allmusic.com)
    # AllMusic search URLs use path segments, not query params.
    case "$ENTITY" in
      artist) printf 'https://www.allmusic.com/search/artists/%s' "$(url_encode "$CREDITED_NAME")" ;;
      *)      printf 'https://www.allmusic.com/search/songs/%s'   "$(url_encode "$(search_query)")" ;;
    esac
    ;;
  tidal|tidal.com|listen.tidal.com)
    # Album-credits page is the verification target — it lists per-track
    # producer/engineer/writer rows for unauthenticated headless browsers
    # (verified 2026-05-04 on hydra). Album ID takes priority over the
    # track ID because the credits panel is on the album page.
    if [[ -n "$TIDAL_ALBUM_ID" ]]; then
      printf 'https://tidal.com/album/%s/credits' "$TIDAL_ALBUM_ID"
    elif [[ -n "$TIDAL_ID" ]]; then
      printf 'https://tidal.com/browse/%s/%s' "$ENTITY" "$TIDAL_ID"
    else
      printf 'https://tidal.com/search?q=%s' "$(url_encode "$(search_query)")"
    fi
    ;;
  muso|muso.ai|app.muso.ai)
    # First arg of credited_name is interpreted as profile_id when present.
    # The subagent calls this with --credited-name <profile_id> for the
    # anchor load. Caller can also pass --entity profile to be explicit.
    printf 'https://credits.muso.ai/profile/%s' "$CREDITED_NAME"
    ;;
  *)
    echo "ERROR: unrecognised host: $HOST" >&2
    exit 2
    ;;
esac
