#!/usr/bin/env bash
# spotify-track-lookup.sh — deterministic Tier-1 helper that confirms the
# canonical track artists / ISRC / label for a Spotify track ID via the
# Spotify Web API. Mirrors the pattern of musicbrainz-isrc-lookup.sh — a
# zero-cost (within rate limits) helper the dispatcher calls *before*
# spending browser cycles.
#
# Spotify's Web API does NOT surface engineer / mixing / mastering / etc.
# personnel — only the recording artists on the track. As a result this
# script can deterministically confirm name_match + role_match ONLY for
# performer-class roles ("Recording Artist", "Performer", "Featured Artist",
# "Vocals", "Vocalist"). For every other role role_match is always false
# and the caller must escalate to MusicBrainz / browser tier.
#
# Usage:
#   spotify-track-lookup.sh <spotify_track_id>
#                           [--credited-name <name>]
#                           [--track-title <title>]
#                           [--role <role>]
#
# Stdout: one JSON object —
#   {
#     "spotify_track_id": "...",
#     "found": true|false,
#     "track": {
#       "name": "...",
#       "artists": [{"id":"...","name":"..."}],
#       "isrc": "...",
#       "label": "...",
#       "popularity": 0
#     },
#     "name_match": true|false,
#     "role_match": true|false,
#     "evidence_excerpt": "..." | null,
#     "error": null | "<message>"
#   }
#
# Exit codes:
#   0 = found (track returned 200)
#   1 = not found (404)
#   2 = network / HTTP / auth / rate-limit error
#   3 = usage error
#   4 = credentials missing (SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET unset)
#
# Required env:
#   SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET
#     OAuth client-credentials. NOT yet provisioned on hydra (2026-05-06)
#     — Muso uses these names in k8s prod analytics worker, mirror them
#     here. Add to /etc/openclaw/main.env when keys are minted.
#
# Optional env:
#   SPOTIFY_TOKEN_CACHE   path to token cache file (default /tmp/.spotify-token-cache)
#   MB_USER_AGENT         User-Agent string (default MusoCreditVerification/0.1 (nick@muso.ai))
#   MB_CURL               curl binary path — used by tests to PATH-shadow
#
# Stubbing: curl is invoked via `${MB_CURL:-curl}` so bats tests can
# PATH-shadow without hitting the live API. We deliberately reuse the
# MB_* env-var prefix so a single PATH-shadow covers both helpers.

set -euo pipefail

# ---------- arg parsing ----------------------------------------------------

TRACK_ID=""
CREDITED_NAME=""
ROLE=""

usage_err() {
  echo "ERROR: $1" >&2
  echo "Usage: spotify-track-lookup.sh <spotify_track_id> [--credited-name N] [--track-title T] [--role R]" >&2
  exit 3
}

if [[ $# -lt 1 ]]; then
  usage_err "spotify_track_id positional argument required"
fi

TRACK_ID="$1"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credited-name) [[ $# -ge 2 ]] || usage_err "$1 requires a value"; CREDITED_NAME="$2"; shift 2 ;;
    --track-title)   [[ $# -ge 2 ]] || usage_err "$1 requires a value"; shift 2 ;;  # accepted for dispatcher parity, value unused
    --role)          [[ $# -ge 2 ]] || usage_err "$1 requires a value"; ROLE="$2";          shift 2 ;;
    *) usage_err "unknown arg: $1" ;;
  esac
done

[[ -n "$TRACK_ID" ]] || usage_err "spotify_track_id must be non-empty"

# ---------- creds ----------------------------------------------------------

emit_creds_missing() {
  jq -nc --arg id "$TRACK_ID" \
    '{spotify_track_id:$id, found:false, track:null, name_match:false, role_match:false, evidence_excerpt:null, error:"SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET must be set"}'
  exit 4
}

if [[ -z "${SPOTIFY_CLIENT_ID:-}" || -z "${SPOTIFY_CLIENT_SECRET:-}" ]]; then
  emit_creds_missing
fi

# ---------- shared HTTP helpers --------------------------------------------

CURL_BIN="${MB_CURL:-curl}"
USER_AGENT="${MB_USER_AGENT:-MusoCreditVerification/0.1 (nick@muso.ai)}"
TOKEN_CACHE="${SPOTIFY_TOKEN_CACHE:-/tmp/.spotify-token-cache}"

TMPDIR_INTERNAL="$(mktemp -d -t spot-track.XXXXXX)"
trap 'rm -rf "$TMPDIR_INTERNAL"' EXIT
HTTP_ERR_FILE="$TMPDIR_INTERNAL/http_err"
HTTP_CODE_FILE="$TMPDIR_INTERNAL/http_code"
: > "$HTTP_ERR_FILE"
: > "$HTTP_CODE_FILE"

fail_network() {
  local msg="$1"
  jq -nc --arg id "$TRACK_ID" --arg err "$msg" \
    '{spotify_track_id:$id, found:false, track:null, name_match:false, role_match:false, evidence_excerpt:null, error:$err}'
  exit 2
}

# GET <url> with bearer token. On full success prints body; otherwise writes
# error to $HTTP_ERR_FILE and returns 1. Writes the HTTP code to
# $HTTP_CODE_FILE so the caller can distinguish 404 (not found) from other
# failures — variables don't survive a $(...) capture subshell, files do.
http_get_bearer() {
  local url="$1" token="$2"
  local body_file="$TMPDIR_INTERNAL/body.$$.$RANDOM"
  local rc code
  set +e
  code=$("$CURL_BIN" --max-time 15 -sS \
         -A "$USER_AGENT" \
         -H "Authorization: Bearer $token" \
         -H 'Accept: application/json' \
         -o "$body_file" \
         -w '%{http_code}' \
         "$url")
  rc=$?
  set -e
  printf '%s' "$code" > "$HTTP_CODE_FILE"
  if [[ $rc -ne 0 ]]; then
    printf '%s' "curl exit $rc for $url" > "$HTTP_ERR_FILE"
    return 1
  fi
  if [[ "$code" == "200" ]]; then
    cat "$body_file"
    return 0
  fi
  printf '%s' "Spotify returned HTTP $code" > "$HTTP_ERR_FILE"
  return 1
}

# POST to token endpoint; prints {access_token, expires_in} JSON or fails.
http_post_token() {
  local body_file="$TMPDIR_INTERNAL/token.$$.$RANDOM"
  local rc code
  set +e
  code=$("$CURL_BIN" --max-time 15 -sS \
         -A "$USER_AGENT" \
         -u "${SPOTIFY_CLIENT_ID}:${SPOTIFY_CLIENT_SECRET}" \
         -H 'Content-Type: application/x-www-form-urlencoded' \
         -d 'grant_type=client_credentials' \
         -o "$body_file" \
         -w '%{http_code}' \
         'https://accounts.spotify.com/api/token')
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf '%s' "curl exit $rc for token endpoint" > "$HTTP_ERR_FILE"
    return 1
  fi
  if [[ "$code" != "200" ]]; then
    printf '%s' "Spotify auth failed: HTTP $code" > "$HTTP_ERR_FILE"
    return 1
  fi
  cat "$body_file"
}

# ---------- token: cached or fresh -----------------------------------------

# Cache file format: single JSON object {"access_token":"...","expires_at":<epoch>}
get_token() {
  local now access_token expires_at
  now=$(date +%s)

  if [[ -f "$TOKEN_CACHE" ]]; then
    if cached=$(jq -e . "$TOKEN_CACHE" 2>/dev/null); then
      access_token=$(echo "$cached" | jq -r '.access_token // empty')
      expires_at=$(echo "$cached" | jq -r '.expires_at // 0')
      if [[ -n "$access_token" && "$expires_at" =~ ^[0-9]+$ ]] && (( expires_at > now + 30 )); then
        printf '%s' "$access_token"
        return 0
      fi
    fi
  fi

  local token_body
  if ! token_body=$(http_post_token); then
    return 1
  fi
  if ! echo "$token_body" | jq -e . >/dev/null 2>&1; then
    printf '%s' "token endpoint returned non-JSON" > "$HTTP_ERR_FILE"
    return 1
  fi

  access_token=$(echo "$token_body" | jq -r '.access_token // empty')
  local expires_in
  expires_in=$(echo "$token_body" | jq -r '.expires_in // 3600')
  if [[ -z "$access_token" ]]; then
    printf '%s' "token endpoint missing access_token" > "$HTTP_ERR_FILE"
    return 1
  fi
  expires_at=$(( now + expires_in ))

  # Write atomically (tmp+rename) and lock down perms — token grants API access.
  local cache_tmp="${TOKEN_CACHE}.tmp.$$"
  jq -nc --arg t "$access_token" --argjson e "$expires_at" \
    '{access_token:$t, expires_at:$e}' > "$cache_tmp"
  chmod 600 "$cache_tmp" 2>/dev/null || true
  mv -f "$cache_tmp" "$TOKEN_CACHE"

  printf '%s' "$access_token"
}

if ! TOKEN=$(get_token); then
  fail_network "$(cat "$HTTP_ERR_FILE")"
fi

# ---------- track lookup ---------------------------------------------------

track_url="https://api.spotify.com/v1/tracks/${TRACK_ID}"
if ! track_body=$(http_get_bearer "$track_url" "$TOKEN"); then
  if [[ "$(cat "$HTTP_CODE_FILE" 2>/dev/null)" == "404" ]]; then
    jq -nc --arg id "$TRACK_ID" \
      '{spotify_track_id:$id, found:false, track:null, name_match:false, role_match:false, evidence_excerpt:null, error:null}'
    exit 1
  fi
  fail_network "$(cat "$HTTP_ERR_FILE")"
fi

if ! echo "$track_body" | jq -e . >/dev/null 2>&1; then
  fail_network "track endpoint returned non-JSON body"
fi

# Project the fields we care about.
track_json=$(echo "$track_body" | jq -c '
  {
    name: (.name // ""),
    artists: ([.artists[]? | {id:(.id // ""), name:(.name // "")}]),
    isrc: (.external_ids.isrc // ""),
    label: (.album.label // ""),
    popularity: (.popularity // 0)
  }')

# ---------- name-match -----------------------------------------------------

name_match=false
matched_name=""

if [[ -n "$CREDITED_NAME" ]]; then
  cname_len=${#CREDITED_NAME}
  if (( cname_len >= 4 )); then
    needle_lc=$(printf '%s' "$CREDITED_NAME" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r hay; do
      [[ -z "$hay" ]] && continue
      hay_lc=$(printf '%s' "$hay" | tr '[:upper:]' '[:lower:]')
      if [[ "$hay_lc" == *"$needle_lc"* ]]; then
        name_match=true
        matched_name="$hay"
        break
      fi
    done < <(echo "$track_json" | jq -r '.artists[]?.name // empty')
  fi
fi

# ---------- role-match -----------------------------------------------------

# Spotify exposes ONLY recording artists on a track — no producer / engineer
# / mastering / mixing relations. Performer-class roles can therefore be
# confirmed by presence in artists[]; everything else is unverifiable here
# and must escalate (role_match=false).
is_performer_role() {
  local r
  r=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$r" in
    "recording artist"|"performer"|"featured artist"|"vocals"|"vocalist"|"main artist"|"artist")
      return 0 ;;
    *) return 1 ;;
  esac
}

role_match=false
if [[ -n "$ROLE" && -n "$CREDITED_NAME" && "$name_match" == "true" ]]; then
  if is_performer_role "$ROLE"; then
    role_match=true
  fi
fi

# ---------- evidence excerpt ----------------------------------------------

# Format: "<credited_name> – <track.name> (Spotify)" — the trailing
# "(Spotify)" tag distinguishes it from MusicBrainz's en-dash format so
# the gate can attribute evidence to source. ≥8 chars, ≤200, only when
# name_match is true.
evidence_excerpt="null"
if [[ "$name_match" == "true" ]]; then
  rec_name=$(echo "$track_json" | jq -r '.name // ""')
  excerpt="${matched_name:-$CREDITED_NAME} – ${rec_name} (Spotify)"
  if (( ${#excerpt} > 200 )); then
    excerpt="${excerpt:0:200}"
  fi
  if (( ${#excerpt} < 8 )); then
    excerpt="${excerpt} (Spotify)"
  fi
  evidence_excerpt=$(jq -nc --arg s "$excerpt" '$s')
fi

# ---------- emit -----------------------------------------------------------

jq -nc \
  --arg id "$TRACK_ID" \
  --argjson track "$track_json" \
  --argjson name_match "$name_match" \
  --argjson role_match "$role_match" \
  --argjson evidence_excerpt "$evidence_excerpt" \
  --arg credited_name "$CREDITED_NAME" \
  --arg role "$ROLE" \
  '{
    spotify_track_id: $id,
    found: true,
    track: $track,
    name_match: (if $credited_name == "" then false else $name_match end),
    role_match: (if ($credited_name == "" or $role == "") then false else $role_match end),
    evidence_excerpt: $evidence_excerpt,
    error: null
  }'

exit 0
