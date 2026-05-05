#!/usr/bin/env bash
# resolve-tier1-sources.sh — resolve backend-known Tier-1 source URLs for a
# muso credit-request item.
#
# What this is for: SKILL.md B3 has a three-branch decision tree based on
# how many backend-known Tier-1 source URLs we have for the track at fetch
# time:
#   - >=2 backend Tier-1 URLs → verify with backend sources only, no search
#   - == 1                    → backend URL + ONE search-and-click
#   - == 0                    → full search-and-click chain
#
# Today, the only Tier-1 source the muso catalog actually carries is Tidal,
# and it's hidden under /admin/track/<id>/sources and /admin/album/<id>/sources
# (NOT the standard /admin/track/<id> response). Apple Music / MusicBrainz /
# Discogs / AllMusic IDs are not yet ingested — see hydra issue #236. When
# that lands, this script is the single place to extend (the same /sources
# response shape will surface them).
#
# Algorithm:
#   1. If --track-id is unset or empty, emit an all-null envelope with
#      backend_tier1_count=0. (v1 does NOT do spotify_track_id → muso UUID
#      lookup; that's a follow-up if coverage hurts.)
#   2. GET /admin/track/<muso_track_id> → extract .body.data.album.id.
#   3. GET /admin/album/<album_id>/sources → walk .body.data.sources[],
#      find entry with .source == "tidal", take .items[0].id for the album.
#   4. (Optional, for diagnostics) GET /admin/track/<muso_track_id>/sources
#      → extract Tidal items[0].id and items[0].url for tidal_track_*.
#   5. Derive tidal_album_credits_url as
#      https://tidal.com/album/<tidal_album_id>/credits.
#   6. backend_tier1_count = number of distinct backend-direct Tier-1 sources
#      (today: 1 if Tidal album ID resolved, else 0).
#
# Failure modes (all silent — emit envelope with affected fields null):
#   - /admin/track/<id> 404 (track not in muso catalog) → all-null envelope
#   - /admin/album/<id>/sources missing tidal items     → tidal fields null
#   - admin-API wrapper non-zero exit                   → log to stderr only
# The envelope is ALWAYS valid JSON on stdout. Failure does not exit non-zero
# (caller does not need to special-case — they get count=0).
#
# Usage:
#   resolve-tier1-sources.sh [--track-id <muso_track_uuid>]
#                            [--spotify-track-id <id>]
#                            [--cr-id <credit_request_uuid>]
#
# At least one of --track-id / --spotify-track-id is required (rc 2 if both
# empty).
#
# Env:
#   ADMIN_API_SH   path to muso-admin-api.sh (default
#                  /opt/hydra/workspaces/operations/skills/muso-ops-admin/
#                  scripts/muso-admin-api.sh — same as fetch-queue.sh).
#
# Output (stdout, exactly one compact JSON line):
#   {
#     "muso_track_id":          "<uuid> | null",
#     "muso_album_id":          "<uuid> | null",
#     "tidal_track_id":         "<id>   | null",
#     "tidal_track_url":        "<url>  | null",
#     "tidal_album_id":         "<id>   | null",
#     "tidal_album_credits_url":"<url>  | null",
#     "backend_tier1_count":    <int>
#   }
#
# Exit codes:
#   0  envelope emitted (whether or not anything resolved)
#   2  invalid args (no track-id and no spotify-track-id)

set -euo pipefail

TRACK_ID=""
SPOTIFY_TRACK_ID=""
CR_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --track-id)         TRACK_ID="${2:-}";         shift 2 ;;
    --spotify-track-id) SPOTIFY_TRACK_ID="${2:-}"; shift 2 ;;
    --cr-id)            CR_ID="${2:-}";            shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TRACK_ID" && -z "$SPOTIFY_TRACK_ID" ]]; then
  echo "ERROR: --track-id or --spotify-track-id required" >&2
  exit 2
fi

ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"

# Diagnostic prefix shown in stderr when the wrapper non-zero exits. Falls
# back to "?" if no cr-id was supplied. Keeps cron logs greppable.
diag_prefix() {
  printf '[resolve-tier1-sources cr=%s track=%s]' "${CR_ID:-?}" "${TRACK_ID:-?}"
}

# Emit an envelope with the supplied jq-style key=value pairs and exit 0.
# Always-null fields are filled in for the consumer.
emit_envelope() {
  local muso_track_id="${1:-}"
  local muso_album_id="${2:-}"
  local tidal_track_id="${3:-}"
  local tidal_track_url="${4:-}"
  local tidal_album_id="${5:-}"
  local tidal_album_credits_url="${6:-}"
  local backend_tier1_count="${7:-0}"

  jq -nc \
    --arg muso_track_id "$muso_track_id" \
    --arg muso_album_id "$muso_album_id" \
    --arg tidal_track_id "$tidal_track_id" \
    --arg tidal_track_url "$tidal_track_url" \
    --arg tidal_album_id "$tidal_album_id" \
    --arg tidal_album_credits_url "$tidal_album_credits_url" \
    --argjson backend_tier1_count "$backend_tier1_count" \
    '{
      muso_track_id:           ($muso_track_id           | select(length>0) // null),
      muso_album_id:           ($muso_album_id           | select(length>0) // null),
      tidal_track_id:          ($tidal_track_id          | select(length>0) // null),
      tidal_track_url:         ($tidal_track_url         | select(length>0) // null),
      tidal_album_id:          ($tidal_album_id          | select(length>0) // null),
      tidal_album_credits_url: ($tidal_album_credits_url | select(length>0) // null),
      backend_tier1_count:     $backend_tier1_count,
    }'
}

# Run the admin-API wrapper. On non-zero exit, log to stderr and return 1.
# Capture rc with `|| rc=$?` so the inner exit status survives — `if !` would
# rewrite it to 0 by the time we read $? inside the then-branch.
admin_call() {
  local path="$1" out rc=0
  out=$(bash "$ADMIN_API_SH" call GET "$path" 2>/dev/null) || rc=$?
  if (( rc != 0 )); then
    echo "$(diag_prefix) admin-api wrapper exited rc=$rc for path=$path" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# v1: no muso track UUID lookup from spotify_track_id. Emit empty envelope.
if [[ -z "$TRACK_ID" ]]; then
  emit_envelope "" "" "" "" "" "" 0
  exit 0
fi

# 1. Track → album UUID
# admin_call already returns 1 with a stderr line on failure; the empty-resp
# check below is the one that actually drives the fallback. The `|| true`
# guard is redundant inside command substitution (which already softens rc)
# so omitting it makes the failure path explicit.
TRACK_RESP=$(admin_call "/admin/track/${TRACK_ID}") || TRACK_RESP=""
if [[ -z "$TRACK_RESP" ]]; then
  emit_envelope "$TRACK_ID" "" "" "" "" "" 0
  exit 0
fi

TRACK_HTTP=$(echo "$TRACK_RESP" | jq -r '.http_status // "unknown"')
if [[ "$TRACK_HTTP" != "200" ]]; then
  emit_envelope "$TRACK_ID" "" "" "" "" "" 0
  exit 0
fi

ALBUM_ID=$(echo "$TRACK_RESP" | jq -r '.body.data.album.id // empty')
if [[ -z "$ALBUM_ID" ]]; then
  emit_envelope "$TRACK_ID" "" "" "" "" "" 0
  exit 0
fi

# 2. Album → tidal album id (the verification target)
ALBUM_SOURCES_RESP=$(admin_call "/admin/album/${ALBUM_ID}/sources") || ALBUM_SOURCES_RESP=""
TIDAL_ALBUM_ID=""
if [[ -n "$ALBUM_SOURCES_RESP" ]]; then
  ALBUM_HTTP=$(echo "$ALBUM_SOURCES_RESP" | jq -r '.http_status // "unknown"')
  if [[ "$ALBUM_HTTP" == "200" ]]; then
    TIDAL_ALBUM_ID=$(echo "$ALBUM_SOURCES_RESP" \
      | jq -r '((.body.data.sources?) // .body.data // [])
               | map(select(.source == "tidal"))
               | .[0].items[0].id // empty')
  fi
fi

# 3. Track-level Tidal (informational only)
TRACK_SOURCES_RESP=$(admin_call "/admin/track/${TRACK_ID}/sources") || TRACK_SOURCES_RESP=""
TIDAL_TRACK_ID=""
TIDAL_TRACK_URL=""
if [[ -n "$TRACK_SOURCES_RESP" ]]; then
  TRACK_SRC_HTTP=$(echo "$TRACK_SOURCES_RESP" | jq -r '.http_status // "unknown"')
  if [[ "$TRACK_SRC_HTTP" == "200" ]]; then
    TIDAL_TRACK_ID=$(echo "$TRACK_SOURCES_RESP" \
      | jq -r '((.body.data.sources?) // .body.data // [])
               | map(select(.source == "tidal"))
               | .[0].items[0].id // empty')
    TIDAL_TRACK_URL=$(echo "$TRACK_SOURCES_RESP" \
      | jq -r '((.body.data.sources?) // .body.data // [])
               | map(select(.source == "tidal"))
               | .[0].items[0].url // empty')
  fi
fi

# 4. Compose envelope
TIDAL_ALBUM_CREDITS_URL=""
BACKEND_COUNT=0
if [[ -n "$TIDAL_ALBUM_ID" ]]; then
  TIDAL_ALBUM_CREDITS_URL="https://tidal.com/album/${TIDAL_ALBUM_ID}/credits"
  BACKEND_COUNT=1
fi

emit_envelope \
  "$TRACK_ID" \
  "$ALBUM_ID" \
  "$TIDAL_TRACK_ID" \
  "$TIDAL_TRACK_URL" \
  "$TIDAL_ALBUM_ID" \
  "$TIDAL_ALBUM_CREDITS_URL" \
  "$BACKEND_COUNT"
