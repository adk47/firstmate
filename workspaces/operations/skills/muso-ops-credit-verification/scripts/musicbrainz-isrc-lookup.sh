#!/usr/bin/env bash
# musicbrainz-isrc-lookup.sh — free deterministic ISRC → recording lookup
# against the MusicBrainz Web Service v2.
#
# This is Phase C of the credit-verification redesign — a zero-cost helper
# the dispatcher calls *before* spending browser/Tier-1 cycles. When the
# claim ships an ISRC and MusicBrainz has the recording with personnel
# relations, we can settle name-match + role-match deterministically and
# emit a literal evidence excerpt the gate will accept.
#
# Usage:
#   musicbrainz-isrc-lookup.sh <ISRC>
#                              [--credited-name <name>]
#                              [--track-title <title>]
#                              [--role <role>]
#
# Stdout: one JSON object (see README §11 Phase C / spec v1 §3).
#
# Exit codes:
#   0 = found ≥1 recording (regardless of name match)
#   1 = ISRC unknown to MusicBrainz (count: 0)
#   2 = network / HTTP / rate-limit error
#   3 = usage error
#
# Stubbing: the curl binary is invoked via `${MB_CURL:-curl}` so bats tests
# can PATH-shadow / env-override without hitting the live API.
#
# Rate limit: MusicBrainz allows 1 req/sec for unauthenticated clients.
# We sleep 1.1s between the two calls. The caller is responsible for
# spacing repeat invocations of this script.

set -euo pipefail

# ---------- arg parsing ----------------------------------------------------

ISRC=""
CREDITED_NAME=""
ROLE=""

usage_err() {
  echo "ERROR: $1" >&2
  echo "Usage: musicbrainz-isrc-lookup.sh <ISRC> [--credited-name N] [--track-title T] [--role R]" >&2
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

# ---------- HTTP helpers ---------------------------------------------------

CURL_BIN="${MB_CURL:-curl}"
USER_AGENT="${MB_USER_AGENT:-MusoCreditVerification/0.1 (nick@muso.ai)}"

# Side-channel temp dir for response bodies (kept separate from caller's
# TMPDIR to avoid trampling). Cleaned on exit.
TMPDIR_INTERNAL="$(mktemp -d -t mb-isrc.XXXXXX)"
trap 'rm -rf "$TMPDIR_INTERNAL"' EXIT
# HTTP error message lives in a file because http_get runs in a $(...)
# subshell when its stdout is captured — variables set there don't survive
# back to the parent. Reading the file after a non-zero return code is the
# portable workaround.
HTTP_ERR_FILE="$TMPDIR_INTERNAL/http_err"
: > "$HTTP_ERR_FILE"

# Emit an error JSON envelope and exit with code 2.
fail_network() {
  local msg="$1"
  jq -nc --arg isrc "$ISRC" --arg err "$msg" \
    '{isrc:$isrc, found:false, recordings:[], name_match:false, role_match:false, evidence_excerpt:null, error:$err}'
  exit 2
}

# Run curl; write body to a temp file and HTTP code to a side-channel file.
# We can't call fail_network from inside a command-substitution context
# because its JSON output would be captured (and lost) by the caller's
# `$( ... )`. Instead http_get() returns success+body via stdout when the
# HTTP call is fully OK, and signals failure by writing the error message
# to $HTTP_ERR_FILE and returning non-zero — the caller reads the file
# and bails. (Variables don't survive the $(...) capture subshell, files do.)
http_get() {
  local url="$1"
  local body_file="$TMPDIR_INTERNAL/body.$$"
  local rc code
  set +e
  code=$("$CURL_BIN" --max-time 15 -sS \
         -A "$USER_AGENT" \
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
  if [[ "$code" == "503" || "$code" == "429" ]]; then
    printf '%s' "MusicBrainz returned HTTP $code (rate limit / unavailable)" > "$HTTP_ERR_FILE"
    return 1
  fi
  if [[ "$code" != "200" ]]; then
    printf '%s' "MusicBrainz returned HTTP $code" > "$HTTP_ERR_FILE"
    return 1
  fi
  cat "$body_file"
}

# ---------- step 1: ISRC → recordings -------------------------------------

q_url="https://musicbrainz.org/ws/2/recording/?query=isrc:${ISRC}&fmt=json&limit=5"
if ! search_body=$(http_get "$q_url"); then
  fail_network "$(cat "$HTTP_ERR_FILE")"
fi

# Validate JSON early; an HTML error page would otherwise blow up jq later.
if ! echo "$search_body" | jq -e . >/dev/null 2>&1; then
  fail_network "ISRC search returned non-JSON body"
fi

count=$(echo "$search_body" | jq -r '.count // (.recordings | length) // 0')
if [[ "$count" == "0" || -z "$count" ]]; then
  jq -nc --arg isrc "$ISRC" \
    '{isrc:$isrc, found:false, recordings:[], name_match:false, role_match:false, evidence_excerpt:null, error:null}'
  exit 1
fi

# ---------- step 2: first recording → relations ---------------------------

mbid=$(echo "$search_body" | jq -r '.recordings[0].id // empty')
if [[ -z "$mbid" ]]; then
  # Search reported a count but no recording — treat as miss.
  jq -nc --arg isrc "$ISRC" \
    '{isrc:$isrc, found:false, recordings:[], name_match:false, role_match:false, evidence_excerpt:null, error:null}'
  exit 1
fi

# Honor MusicBrainz 1 req/sec rate limit between the two calls.
sleep 1.1

rel_url="https://musicbrainz.org/ws/2/recording/${mbid}?fmt=json&inc=artist-credits+artist-rels+work-rels"
if ! rel_body=$(http_get "$rel_url"); then
  fail_network "$(cat "$HTTP_ERR_FILE")"
fi

if ! echo "$rel_body" | jq -e . >/dev/null 2>&1; then
  fail_network "recording lookup returned non-JSON body"
fi

# ---------- shape the recordings array ------------------------------------

# Project just the fields the caller (and the gate) need. We keep this
# minimal — the goal is deterministic match, not a faithful MB mirror.
recording_json=$(echo "$rel_body" | jq -c '
  {
    id: .id,
    title: .title,
    artist_credits: ([.["artist-credit"][]? | {name: (.name // .artist.name // "")}]),
    relations: ([.relations[]? | {
      type: (.type // ""),
      artist: (if .artist then {name: (.artist.name // "")} else null end)
    }])
  }')

# ---------- name-match -----------------------------------------------------

name_match=false
matched_name=""
matched_relation_type=""

if [[ -n "$CREDITED_NAME" ]]; then
  # Token must be ≥4 chars per spec.
  cname_len=${#CREDITED_NAME}
  if (( cname_len >= 4 )); then
    # Lowercase the haystack pieces and the needle for case-insensitive
    # substring match. We check artist_credits[].name AND
    # relations[].artist.name.
    needle_lc=$(printf '%s' "$CREDITED_NAME" | tr '[:upper:]' '[:lower:]')

    # Build a list of (haystack, relation_type-or-empty) pairs.
    # jq emits TSV-ish lines: <name>\t<reltype>
    while IFS=$'\t' read -r hay rtype; do
      [[ -z "$hay" ]] && continue
      hay_lc=$(printf '%s' "$hay" | tr '[:upper:]' '[:lower:]')
      if [[ "$hay_lc" == *"$needle_lc"* ]]; then
        name_match=true
        matched_name="$hay"
        matched_relation_type="$rtype"
        break
      fi
    done < <(echo "$recording_json" | jq -r '
      ( .artist_credits[]? | "\(.name)\t" ),
      ( .relations[]? | select(.artist != null) | "\(.artist.name)\t\(.type)" )
    ')
  fi
fi

# ---------- role-match -----------------------------------------------------

# Synonym table keyed by canonical role (lowercased). Each entry is a
# space-separated list of substrings that count as a match against the
# relation `type` field.
role_synonyms() {
  local r
  r=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$r" in
    mixing)    echo "mixing mix mixed by" ;;
    mastering) echo "mastering master mastered by mastering engineer" ;;
    producer)  echo "producer produced by" ;;
    composer)  echo "composer songwriter writer written by" ;;
    lyricist)  echo "lyricist lyrics words by" ;;
    engineer)  echo "engineer engineered by recording engineer" ;;
    *)         echo "$r" ;;  # passthrough — caller's literal role
  esac
}

role_match=false
matched_role_type=""

if [[ -n "$ROLE" && -n "$CREDITED_NAME" ]]; then
  syn_str=$(role_synonyms "$ROLE")
  # Iterate every relation type on the recording; mark match if any
  # synonym is a substring of the relation type (case-insensitive).
  while IFS= read -r rtype; do
    [[ -z "$rtype" ]] && continue
    rtype_lc=$(printf '%s' "$rtype" | tr '[:upper:]' '[:lower:]')
    for syn in $syn_str; do
      if [[ "$rtype_lc" == *"$syn"* ]]; then
        role_match=true
        matched_role_type="$rtype"
        break 2
      fi
    done
  done < <(echo "$recording_json" | jq -r '.relations[]?.type // empty')
fi

# ---------- evidence excerpt ----------------------------------------------

# When name_match is true, build a short literal excerpt the gate accepts.
# Format: "<credited_name> – <relation_type or recording_title>"
#   * uses an en-dash ("–") for visual separation; the gate's substring
#     check is byte-level so this is fine.
#   * clamped to 200 chars.
#   * only emitted when name_match is true (per spec).
evidence_excerpt="null"
if [[ "$name_match" == "true" ]]; then
  rec_title=$(echo "$recording_json" | jq -r '.title // ""')
  # Prefer the relation type that anchored the role (if any), else the
  # type of the matched relation, else the recording title.
  tail_part=""
  if [[ -n "$matched_role_type" ]]; then
    tail_part="$matched_role_type"
  elif [[ -n "$matched_relation_type" ]]; then
    tail_part="$matched_relation_type"
  elif [[ -n "$rec_title" ]]; then
    tail_part="$rec_title"
  fi

  excerpt="${matched_name:-$CREDITED_NAME} – ${tail_part}"
  # Clamp length: ≥8 (guaranteed by name + " – " + tail), ≤200.
  if (( ${#excerpt} > 200 )); then
    excerpt="${excerpt:0:200}"
  fi
  # Pad if somehow under 8 (defensive — shouldn't happen with the format).
  if (( ${#excerpt} < 8 )); then
    excerpt="${excerpt} (musicbrainz)"
  fi
  evidence_excerpt=$(jq -nc --arg s "$excerpt" '$s')
fi

# ---------- emit ----------------------------------------------------------

# Build the output JSON. We pass evidence_excerpt as a raw JSON fragment
# (already-quoted string OR the literal "null") via --argjson.
jq -nc \
  --arg isrc "$ISRC" \
  --argjson recording "$recording_json" \
  --argjson name_match "$name_match" \
  --argjson role_match "$role_match" \
  --argjson evidence_excerpt "$evidence_excerpt" \
  --arg credited_name "$CREDITED_NAME" \
  --arg role "$ROLE" \
  '{
    isrc: $isrc,
    found: true,
    recordings: [$recording],
    name_match: (if $credited_name == "" then false else $name_match end),
    role_match: (if ($credited_name == "" or $role == "") then false else $role_match end),
    evidence_excerpt: $evidence_excerpt,
    error: null
  }'

exit 0
