#!/usr/bin/env bash
set -euo pipefail

# Downloads all attachments (structured + inline <img>) of an Intercom
# conversation to local files so agents can inspect them with vision.
#
# Intercom CDN attachment URLs are signed with a ~30-minute TTL, so this
# helper re-fetches the conversation fresh (never re-uses a URL captured
# earlier by a caller) to get live, unexpired URLs.
#
# node-8 has no `file` binary, so image/PDF type detection is done here via
# magic bytes (first 12 bytes, hex-dumped with `od`) -- no external
# dependency beyond curl and jq.
#
# Extraction mirrors plugins/intercom/src/filters.ts (extractImageAttachments
# / extractDocumentAttachments / INTERCOM_CDN_HOST_RE): structured
# attachments at .source.attachments[] and
# .conversation_parts.conversation_parts[].attachments[], plus inline
# <img src="..."> URLs scraped from the HTML .source.body and
# .conversation_parts.conversation_parts[].body -- deduped by URL, then
# filtered through the same CDN host allowlist.

usage() {
  cat <<'USAGE'
Usage: fetch-conversation-attachments.sh <conversation_id> [--out-dir DIR]

Downloads all attachments of an Intercom conversation to local files.

  <conversation_id>   Intercom conversation id (required).
  --out-dir DIR       Directory to download into. Default:
                       ./intercom-attachments/<conversation_id>/

Requires MUSOAI_INTERCOM_TOKEN in the environment.

Prints one compact JSON line per successfully downloaded attachment to
stdout:
  {"path":"...","source_url":"...","detected_type":"png","bytes":123}
USAGE
}

CONVERSATION_ID=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir)
      [ $# -ge 2 ] || { echo "--out-dir requires a value" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$CONVERSATION_ID" ]; then
        CONVERSATION_ID="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [ -z "$CONVERSATION_ID" ]; then
  echo "Missing required argument: conversation_id" >&2
  usage >&2
  exit 2
fi

# Guard the id before it reaches a filesystem path (the default OUT_DIR embeds
# it) or the Intercom URL: it must be a plain id token, never a path fragment.
# This blocks `../` traversal in the default out-dir from a crafted argument.
if [[ ! "$CONVERSATION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Invalid conversation_id '${CONVERSATION_ID}': expected characters [A-Za-z0-9_-]." >&2
  exit 2
fi

: "${MUSOAI_INTERCOM_TOKEN:?MUSOAI_INTERCOM_TOKEN must be set to an Intercom Bearer token -- see skills-all/muso-intercom/SKILL.md}"

OUT_DIR="${OUT_DIR:-intercom-attachments/${CONVERSATION_ID}}"
mkdir -p "$OUT_DIR"

# CDN host allowlist -- mirrors plugins/intercom/src/filters.ts INTERCOM_CDN_HOST_RE
# (case-insensitive there; we lowercase the URL before matching to keep parity).
CDN_HOST_RE='^https://([a-z0-9-]+\.)*(intercomcdn\.(com|io)|intercom-attachments(-[0-9]+)?\.com)/'

detect_type() {
  local f="$1" hex
  hex="$(head -c 12 "$f" | od -An -tx1 | tr -d ' \n')"
  case "$hex" in
    89504e47*) echo png; return ;;
    ffd8ff*) echo jpeg; return ;;
    47494638*) echo gif; return ;;
    25504446*) echo pdf; return ;;
  esac
  if [[ "$hex" == 52494646* && "${hex:16:8}" == "57454250" ]]; then
    echo webp
    return
  fi
  echo unknown
}

CONVO_JSON="$(mktemp)"
cleanup() { rm -f "$CONVO_JSON"; }
trap cleanup EXIT

if ! curl -sS --fail-with-body \
    -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
    -H "Intercom-Version: 2.11" \
    -H "Accept: application/json" \
    -o "$CONVO_JSON" \
    "https://api.intercom.io/conversations/${CONVERSATION_ID}"; then
  echo "Failed to fetch conversation ${CONVERSATION_ID} from Intercom (non-2xx response):" >&2
  cat "$CONVO_JSON" >&2 || true
  exit 1
fi

if ! jq -e . "$CONVO_JSON" >/dev/null 2>&1; then
  echo "Conversation ${CONVERSATION_ID}: Intercom response was not valid JSON." >&2
  exit 1
fi

# jq program: extract candidate attachment URLs from both branches, dedupe.
read -r -d '' JQ_PROGRAM <<'JQEOF' || true
def structured_atts:
  ((.source.attachments // [])[] | {url: .url, content_type: (.content_type // null), name: (.name // null)}),
  ((.conversation_parts.conversation_parts // [])[] | (.attachments // [])[] | {url: .url, content_type: (.content_type // null), name: (.name // null)});

def inline_urls(body):
  (body // "") as $b
  | ( [$b | scan("<img[^>]*\\ssrc=\"([^\"]*)\"")] | map(.[0]) )
  + ( [$b | scan("<img[^>]*\\ssrc='([^']*)'")] | map(.[0]) );

([structured_atts]) as $structured
| ( inline_urls(.source.body)
    + ( [(.conversation_parts.conversation_parts // [])[]] | map(inline_urls(.body)) | add // [] )
  ) as $inline_raw
| ( $inline_raw | map(select(. != null and . != "")) | map({url: ., content_type: null, name: null}) ) as $inline
| ( $structured + $inline )
| map(select(.url != null and .url != ""))
| unique_by(.url)
JQEOF

CANDIDATES_JSON="$(jq -c "$JQ_PROGRAM" "$CONVO_JSON")"

total=0
downloaded=0
idx=0

while IFS= read -r cand; do
  total=$((total + 1))
  url="$(jq -r '.url' <<<"$cand")"

  url_lc="${url,,}"
  if [[ ! "$url_lc" =~ $CDN_HOST_RE ]]; then
    echo "Skipping non-allowlisted attachment host: $url" >&2
    continue
  fi

  idx=$((idx + 1))
  tmp_file="$OUT_DIR/.tmp-${idx}"
  if ! curl -sS --fail-with-body \
      --max-filesize 10485760 \
      --connect-timeout 10 --max-time 60 \
      -o "$tmp_file" \
      "$url"; then
    echo "Failed to download attachment #${idx} (${url})." >&2
    rm -f "$tmp_file"
    continue
  fi

  detected="$(detect_type "$tmp_file")"
  dest="$OUT_DIR/${idx}.${detected}"
  mv "$tmp_file" "$dest"
  size="$(wc -c <"$dest" | tr -d ' ')"

  jq -nc --arg path "$dest" --arg url "$url" --arg type "$detected" --argjson bytes "$size" \
    '{path: $path, source_url: $url, detected_type: $type, bytes: $bytes}'
  downloaded=$((downloaded + 1))
done < <(jq -c '.[]' <<<"$CANDIDATES_JSON")

if [ "$total" -eq 0 ]; then
  echo "No attachments found in conversation ${CONVERSATION_ID}." >&2
  exit 0
fi

if [ "$downloaded" -eq 0 ]; then
  echo "Failed to download any of ${total} candidate attachment(s) for conversation ${CONVERSATION_ID}." >&2
  exit 1
fi

exit 0
