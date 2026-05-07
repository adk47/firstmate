#!/usr/bin/env bash
# discogs-isrc-lookup.sh — deterministic ISRC → release lookup against the
# Discogs API. Mirrors the shape of musicbrainz-isrc-lookup.sh / spotify-
# track-lookup.sh: one positional arg (the ISRC), optional --credited-name,
# --track-title, --role flags, single JSON object on stdout, deterministic
# exit codes.
#
# Why Discogs alongside MusicBrainz: Discogs has substantially better
# coverage of engineering / mastering / mixing / production credits on
# US/UK pop releases (where MusicBrainz is sparse) and of physical-only
# releases. The two databases overlap but both have blind spots — having
# both as deterministic API helpers means the dispatcher can clear ~60%
# of credits without ever spending a browser cycle.
#
# Usage:
#   discogs-isrc-lookup.sh <ISRC>
#                          [--credited-name <name>]
#                          [--track-title <title>]
#                          [--role <role>]
#
# Stdout: one JSON object —
#   {
#     "isrc": "...",
#     "found": true|false,
#     "release": {
#       "id": <int>,
#       "title": "...",
#       "artists": ["..."],
#       "year": <int|null>,
#       "label": "..."
#     } | null,
#     "name_match": true|false,
#     "role_match": true|false,
#     "evidence_excerpt": "..." | null,
#     "error": null | "<message>"
#   }
#
# Exit codes:
#   0 = found ≥1 release
#   1 = ISRC unknown to Discogs (no results)
#   2 = network / HTTP / rate-limit / auth error
#   3 = usage error
#   4 = credentials missing (DISCOGS_TOKEN unset)
#
# Required env:
#   DISCOGS_TOKEN
#     Personal access token from https://www.discogs.com/settings/developers
#     (free, 30s signup). Add to /etc/openclaw/main.env when minted.
#
# Optional env:
#   DISCOGS_CURL          curl binary path — used by tests to PATH-shadow
#   DISCOGS_USER_AGENT    User-Agent string (Discogs requires app name + version)
#
# Stubbing: curl is invoked via `${DISCOGS_CURL:-curl}` so bats tests can
# PATH-shadow without hitting the live API. Sleep is also PATH-shadowed
# in tests to skip the 1.1s rate-limit pause between the two calls.
#
# Rate limit: Discogs allows 60 req/min for authenticated clients. We sleep
# 1.1s between the search call and the release-detail call. The caller is
# responsible for spacing repeat invocations of this script.

set -euo pipefail

# ---------- arg parsing ----------------------------------------------------

ISRC=""
CREDITED_NAME=""
ROLE=""

usage_err() {
  echo "ERROR: $1" >&2
  echo "Usage: discogs-isrc-lookup.sh <ISRC> [--credited-name N] [--track-title T] [--role R]" >&2
  exit 3
}

if [[ $# -lt 1 ]]; then
  usage_err "ISRC positional argument required"
fi

ISRC="$1"
shift || true

# Support `--isrc <code>` instead of positional, just in case.
if [[ "$ISRC" == "--isrc" ]]; then
  [[ $# -ge 1 ]] || usage_err "--isrc requires a value"
  ISRC="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credited-name) [[ $# -ge 2 ]] || usage_err "$1 requires a value"; CREDITED_NAME="$2"; shift 2 ;;
    --track-title)   [[ $# -ge 2 ]] || usage_err "$1 requires a value"; shift 2 ;;  # accepted for dispatcher parity, value unused
    --role)          [[ $# -ge 2 ]] || usage_err "$1 requires a value"; ROLE="$2";          shift 2 ;;
    *) usage_err "unknown arg: $1" ;;
  esac
done

[[ -n "$ISRC" ]] || usage_err "ISRC must be non-empty"

# ---------- creds ----------------------------------------------------------

emit_creds_missing() {
  jq -nc --arg isrc "$ISRC" \
    '{isrc:$isrc, found:false, release:null, name_match:false, role_match:false, evidence_excerpt:null, error:"DISCOGS_TOKEN must be set"}'
  exit 4
}

if [[ -z "${DISCOGS_TOKEN:-}" ]]; then
  emit_creds_missing
fi

# ---------- HTTP helpers ---------------------------------------------------

CURL_BIN="${DISCOGS_CURL:-curl}"
USER_AGENT="${DISCOGS_USER_AGENT:-MusoCreditVerification/0.1 +https://muso.ai}"

TMPDIR_INTERNAL="$(mktemp -d -t discogs-isrc.XXXXXX)"
trap 'rm -rf "$TMPDIR_INTERNAL"' EXIT
HTTP_ERR_FILE="$TMPDIR_INTERNAL/http_err"
: > "$HTTP_ERR_FILE"

fail_network() {
  local msg="$1"
  jq -nc --arg isrc "$ISRC" --arg err "$msg" \
    '{isrc:$isrc, found:false, release:null, name_match:false, role_match:false, evidence_excerpt:null, error:$err}'
  exit 2
}

# GET <url> with Discogs token header. On full success prints body; otherwise
# writes error to $HTTP_ERR_FILE and returns 1. Same file-vs-variable trick
# as the MB helper — variables don't survive a $(...) capture subshell.
http_get() {
  local url="$1"
  local body_file="$TMPDIR_INTERNAL/body.$$.$RANDOM"
  local rc code
  set +e
  code=$("$CURL_BIN" --max-time 15 -sS \
         -A "$USER_AGENT" \
         -H "Authorization: Discogs token=${DISCOGS_TOKEN}" \
         -H 'Accept: application/json' \
         -o "$body_file" \
         -w '%{http_code}' \
         "$url")
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf '%s' "curl exit $rc for $url" > "$HTTP_ERR_FILE"
    return 1
  fi
  if [[ "$code" == "429" || "$code" == "503" ]]; then
    printf '%s' "Discogs returned HTTP $code (rate limit / unavailable)" > "$HTTP_ERR_FILE"
    return 1
  fi
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    printf '%s' "Discogs auth failed: HTTP $code" > "$HTTP_ERR_FILE"
    return 1
  fi
  if [[ "$code" != "200" ]]; then
    printf '%s' "Discogs returned HTTP $code" > "$HTTP_ERR_FILE"
    return 1
  fi
  cat "$body_file"
}

# ---------- step 1: ISRC → release search ----------------------------------

# Discogs search supports `q=<freetext>&type=release` — ISRC isn't a typed
# search field but the full-text index includes ISRCs found in tracklist
# metadata. Limit to the top 5 results for sanity.
search_url="https://api.discogs.com/database/search?q=${ISRC}&type=release&per_page=5"
if ! search_body=$(http_get "$search_url"); then
  fail_network "$(cat "$HTTP_ERR_FILE")"
fi

if ! echo "$search_body" | jq -e . >/dev/null 2>&1; then
  fail_network "ISRC search returned non-JSON body"
fi

count=$(echo "$search_body" | jq -r '(.pagination.items // (.results | length) // 0)')
if [[ "$count" == "0" || -z "$count" ]]; then
  jq -nc --arg isrc "$ISRC" \
    '{isrc:$isrc, found:false, release:null, name_match:false, role_match:false, evidence_excerpt:null, error:null}'
  exit 1
fi

release_id=$(echo "$search_body" | jq -r '.results[0].id // empty')
if [[ -z "$release_id" ]]; then
  jq -nc --arg isrc "$ISRC" \
    '{isrc:$isrc, found:false, release:null, name_match:false, role_match:false, evidence_excerpt:null, error:null}'
  exit 1
fi

# Honor Discogs rate limit between the two calls.
sleep 1.1

# ---------- step 2: release detail → extraartists --------------------------

rel_url="https://api.discogs.com/releases/${release_id}"
if ! rel_body=$(http_get "$rel_url"); then
  fail_network "$(cat "$HTTP_ERR_FILE")"
fi

if ! echo "$rel_body" | jq -e . >/dev/null 2>&1; then
  fail_network "release lookup returned non-JSON body"
fi

# Discogs releases carry credits in two places:
#   .extraartists[]     release-level (mastering, design, etc.)
#   .tracklist[].extraartists[]  per-track credits
# Both have shape {name, role, ...}. We project both into a flat list of
# {name, role} entries the gate can scan.
release_json=$(echo "$rel_body" | jq -c '
  {
    id: (.id // 0),
    title: (.title // ""),
    artists: ([.artists[]?.name // empty]),
    year: (.year // null),
    label: ([.labels[]?.name // empty] | join(", ")),
    credits: (
      ([.extraartists[]? | {name: (.name // ""), role: (.role // "")}])
      + ([.tracklist[]?.extraartists[]? | {name: (.name // ""), role: (.role // "")}])
    )
  }')

# ---------- name-match -----------------------------------------------------

name_match=false
matched_name=""
matched_role_raw=""

if [[ -n "$CREDITED_NAME" ]]; then
  cname_len=${#CREDITED_NAME}
  if (( cname_len >= 4 )); then
    needle_lc=$(printf '%s' "$CREDITED_NAME" | tr '[:upper:]' '[:lower:]')

    # jq emits TSV-ish lines: <name>\t<role>
    while IFS=$'\t' read -r hay rraw; do
      [[ -z "$hay" ]] && continue
      hay_lc=$(printf '%s' "$hay" | tr '[:upper:]' '[:lower:]')
      if [[ "$hay_lc" == *"$needle_lc"* ]]; then
        name_match=true
        matched_name="$hay"
        matched_role_raw="$rraw"
        break
      fi
    done < <(echo "$release_json" | jq -r '
      ( .credits[]? | "\(.name)\t\(.role)" ),
      ( .artists[]? | "\(.)\t" )
    ')
  fi
fi

# ---------- role-match -----------------------------------------------------

# Discogs role strings are free-text and often parenthesized
# (e.g. "Mastered By", "Producer [Co-Producer]", "Mixed By"). The synonym
# table lower-cases everything and uses substring matching.
role_synonyms() {
  local r
  r=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$r" in
    mixing)    echo "mixing mix mixed by mix engineer" ;;
    mastering) echo "mastering master mastered by mastering engineer" ;;
    producer)  echo "producer produced by co-producer" ;;
    composer)  echo "composer songwriter writer written by music by" ;;
    lyricist)  echo "lyricist lyrics words by" ;;
    engineer)  echo "engineer engineered by recording engineer recorded by" ;;
    *)         echo "$r" ;;
  esac
}

role_match=false
matched_role=""

if [[ -n "$ROLE" && -n "$CREDITED_NAME" && "$name_match" == "true" ]]; then
  syn_str=$(role_synonyms "$ROLE")
  rraw_lc=$(printf '%s' "$matched_role_raw" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$rraw_lc" ]]; then
    for syn in $syn_str; do
      if [[ "$rraw_lc" == *"$syn"* ]]; then
        role_match=true
        matched_role="$matched_role_raw"
        break
      fi
    done
  fi

  # If the matched name slot didn't carry the right role, scan all credits
  # for any role-matching entry where the name also matches. This handles
  # multi-role artists (same person credited in two roles on the release).
  if [[ "$role_match" != "true" ]]; then
    needle_lc=$(printf '%s' "$CREDITED_NAME" | tr '[:upper:]' '[:lower:]')
    while IFS=$'\t' read -r hay rraw; do
      [[ -z "$hay" || -z "$rraw" ]] && continue
      hay_lc=$(printf '%s' "$hay" | tr '[:upper:]' '[:lower:]')
      [[ "$hay_lc" == *"$needle_lc"* ]] || continue
      rlc=$(printf '%s' "$rraw" | tr '[:upper:]' '[:lower:]')
      for syn in $syn_str; do
        if [[ "$rlc" == *"$syn"* ]]; then
          role_match=true
          matched_role="$rraw"
          break 2
        fi
      done
    done < <(echo "$release_json" | jq -r '.credits[]? | "\(.name)\t\(.role)"')
  fi
fi

# ---------- evidence excerpt ----------------------------------------------

# Format: "<credited_name> – <role or release title> (Discogs)"
# The "(Discogs)" suffix mirrors the Spotify helper's source attribution.
evidence_excerpt="null"
if [[ "$name_match" == "true" ]]; then
  rel_title=$(echo "$release_json" | jq -r '.title // ""')
  tail_part=""
  if [[ -n "$matched_role" ]]; then
    tail_part="$matched_role"
  elif [[ -n "$matched_role_raw" ]]; then
    tail_part="$matched_role_raw"
  elif [[ -n "$rel_title" ]]; then
    tail_part="$rel_title"
  fi

  excerpt="${matched_name:-$CREDITED_NAME} – ${tail_part} (Discogs)"
  if (( ${#excerpt} > 200 )); then
    excerpt="${excerpt:0:200}"
  fi
  if (( ${#excerpt} < 8 )); then
    excerpt="${excerpt} (Discogs)"
  fi
  evidence_excerpt=$(jq -nc --arg s "$excerpt" '$s')
fi

# ---------- emit ----------------------------------------------------------

jq -nc \
  --arg isrc "$ISRC" \
  --argjson release "$release_json" \
  --argjson name_match "$name_match" \
  --argjson role_match "$role_match" \
  --argjson evidence_excerpt "$evidence_excerpt" \
  --arg credited_name "$CREDITED_NAME" \
  --arg role "$ROLE" \
  '{
    isrc: $isrc,
    found: true,
    release: $release,
    name_match: (if $credited_name == "" then false else $name_match end),
    role_match: (if ($credited_name == "" or $role == "") then false else $role_match end),
    evidence_excerpt: $evidence_excerpt,
    error: null
  }'

exit 0
