#!/usr/bin/env bash
# audit-credit-claim-attachments.sh
#
# Phase 0 audit for the Caroline `credit-claim-with-proof` Lobster pipeline.
# Read-only: queries the Intercom REST API to find recent conversations
# matching credit-claim keywords, walks their parts, and counts attachments.
#
# Output: CSV + JSON summary at $OUT_DIR, raw conversation JSON archived
# alongside for offline analysis.
#
# Required env:
#   INTERCOM_TOKEN   — Intercom access token (Bearer)
#
# Optional env:
#   DAYS_BACK        — lookback window in days (default 90)
#   OUT_DIR          — output directory (default ./out/intercom-audit-YYYYMMDD)
#   MAX_CONVS        — cap on conversations to inspect (default 500)
#   API_VERSION      — Intercom-Version header (default 2.11)
#   SLEEP_MS         — sleep between requests in ms (default 250 — Intercom limit is ~83 rps)
#
# Usage:
#   INTERCOM_TOKEN="$(jq -r '.channels.intercom.accounts.default.token' openclaw-edge.json)" \
#     scripts/intercom/audit-credit-claim-attachments.sh
#
# Then inspect $OUT_DIR/summary.json and $OUT_DIR/conversations.csv.

set -euo pipefail

# ---------- Args / defaults ----------
: "${INTERCOM_TOKEN:?ERROR: INTERCOM_TOKEN env var is required (Bearer token, dG9rOj...)}"
DAYS_BACK="${DAYS_BACK:-90}"
OUT_DIR="${OUT_DIR:-./out/intercom-audit-$(date -u +%Y%m%d)}"
MAX_CONVS="${MAX_CONVS:-500}"
API_VERSION="${API_VERSION:-2.11}"
SLEEP_MS="${SLEEP_MS:-250}"

API="https://api.intercom.io"
NOW_S=$(date -u +%s)
SINCE_S=$(( NOW_S - DAYS_BACK * 86400 ))

# Search keywords — broad. We dedupe + classify client-side.
# Order matters only for documentation; the API does an OR.
KEYWORDS=(
  "produced this"
  "produced the track"
  "co-writer"
  "co-write"
  "co-wrote"
  "writer credit"
  "producer credit"
  "credit on"
  "add my credit"
  "proof"
  "see attached"
  "here is"
  "split sheet"
  "release form"
  "contract"
)

mkdir -p "$OUT_DIR" "$OUT_DIR/conversations"
CSV="$OUT_DIR/conversations.csv"
SUMMARY="$OUT_DIR/summary.json"
LOGFILE="$OUT_DIR/audit.log"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOGFILE" >&2; }

# Header line for the CSV. Use TAB as field separator to dodge commas in body snippets.
printf 'conversation_id\tcreated_at\tuser_messages\tinbound_with_attachments\ttotal_attachments\tcontent_types\ttotal_size_bytes\tlargest_attachment_bytes\tfirst_user_body_snippet\n' > "$CSV"

# ---------- Helpers ----------
sleep_throttle() {
  # Portable subsecond sleep (macOS sleep supports floats; bash arithmetic for ms).
  local s
  s=$(awk "BEGIN { printf \"%.3f\", $SLEEP_MS / 1000 }")
  sleep "$s"
}

curl_intercom() {
  # $1 = HTTP method, $2 = path, $3 (optional) = body for POST
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --fail-with-body
    -H "Authorization: Bearer $INTERCOM_TOKEN"
    -H "Accept: application/json"
    -H "Intercom-Version: $API_VERSION"
    -X "$method"
    "$API$path"
  )
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}"
}

# Build a search body covering one keyword. Searches the latest message body
# of conversations updated within the lookback window. We OR-merge keywords
# server-side to reduce round trips, but Intercom caps OR depth so we batch.
build_search_body() {
  local since_s="$1" per_page="${2:-50}" cursor="${3:-}"
  local kw_clauses
  kw_clauses=$(printf '%s\n' "${KEYWORDS[@]}" | jq -R . | jq -s '[.[] | {field:"source.body", operator:"~", value:.}]')

  local pagination_field=""
  if [[ -n "$cursor" ]]; then
    pagination_field=$(jq -nc --arg c "$cursor" '{starting_after: $c}')
  fi

  jq -nc \
    --argjson since "$since_s" \
    --argjson per "$per_page" \
    --argjson kw "$kw_clauses" \
    --argjson pag "${pagination_field:-{\}}" \
    '{
      query: {
        operator: "AND",
        value: [
          {field: "updated_at", operator: ">", value: $since},
          {operator: "OR", value: $kw}
        ]
      },
      pagination: ({per_page: $per} + $pag)
    }'
}

# ---------- Step 1: search for candidate conversations ----------
log "Phase 1: searching conversations updated since $(date -u -r "$SINCE_S" 2>/dev/null || date -u -d "@$SINCE_S")"
candidates_file="$OUT_DIR/candidates.json"
: > "$candidates_file"

cursor=""
total_seen=0
while true; do
  body=$(build_search_body "$SINCE_S" 50 "$cursor")
  resp=$(curl_intercom POST "/conversations/search" "$body") || { log "search request failed"; break; }
  page_count=$(echo "$resp" | jq '.conversations | length')
  total_seen=$(( total_seen + page_count ))
  echo "$resp" | jq -c '.conversations[] | {id, created_at, updated_at}' >> "$candidates_file"
  log "search page: +$page_count (total $total_seen)"
  cursor=$(echo "$resp" | jq -r '.pages.next.starting_after // empty')
  if [[ -z "$cursor" ]] || (( total_seen >= MAX_CONVS )); then
    break
  fi
  sleep_throttle
done

log "Found $total_seen candidate conversations (cap was $MAX_CONVS)."

# Dedupe by ID (in case multiple keyword paths matched).
sort -u "$candidates_file" -o "$candidates_file"

# ---------- Step 2: fetch each conversation, walk parts, count attachments ----------
log "Phase 2: fetching full conversations + counting attachments"
processed=0
with_attachments=0

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  conv_id=$(echo "$line" | jq -r '.id')
  conv_created=$(echo "$line" | jq -r '.created_at')
  processed=$(( processed + 1 ))

  raw_file="$OUT_DIR/conversations/${conv_id}.json"
  if [[ ! -s "$raw_file" ]]; then
    if ! curl_intercom GET "/conversations/${conv_id}?display_as=plaintext" > "$raw_file"; then
      log "  fetch failed for $conv_id"
      rm -f "$raw_file"
      sleep_throttle
      continue
    fi
    sleep_throttle
  fi

  # Walk the conversation parts. Inbound = author.type == "user".
  # Initial message (source) is the first user turn — also has attachments.
  stats=$(jq '
    def all_user_parts:
      [.source] + (.conversation_parts.conversation_parts // [])
      | map(select(.author.type == "user" or (.part_type == "comment" and .author.type == "user")));
    def attach_list:
      [.[] | (.attachments // [])[]];
    {
      user_messages: (all_user_parts | length),
      inbound_with_attachments: (all_user_parts | map(select((.attachments // []) | length > 0)) | length),
      total_attachments: (all_user_parts | attach_list | length),
      content_types: (all_user_parts | attach_list | map(.content_type // "unknown") | unique | join("|")),
      total_size_bytes: (all_user_parts | attach_list | map(.filesize // 0) | add // 0),
      largest_attachment_bytes: (all_user_parts | attach_list | map(.filesize // 0) | max // 0),
      first_user_body_snippet: ((all_user_parts | map(.body // "") | join(" ") )[:200] | gsub("[\t\r\n]"; " "))
    }
  ' "$raw_file" 2>/dev/null) || { log "  parse failed for $conv_id"; continue; }

  user_messages=$(echo "$stats" | jq -r '.user_messages')
  inbound_with_att=$(echo "$stats" | jq -r '.inbound_with_attachments')
  total_att=$(echo "$stats" | jq -r '.total_attachments')
  ctypes=$(echo "$stats" | jq -r '.content_types')
  total_size=$(echo "$stats" | jq -r '.total_size_bytes')
  largest=$(echo "$stats" | jq -r '.largest_attachment_bytes')
  snippet=$(echo "$stats" | jq -r '.first_user_body_snippet')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$conv_id" "$conv_created" "$user_messages" "$inbound_with_att" "$total_att" "$ctypes" "$total_size" "$largest" "$snippet" >> "$CSV"

  if (( inbound_with_att > 0 )); then
    with_attachments=$(( with_attachments + 1 ))
  fi

  if (( processed % 25 == 0 )); then
    log "  processed $processed / $total_seen (with attachments: $with_attachments)"
  fi
done < "$candidates_file"

log "Done. Processed $processed conversations. $with_attachments had user-side attachments."

# ---------- Step 3: summary ----------
jq -nR --arg days "$DAYS_BACK" --arg total "$processed" --arg with_att "$with_attachments" '
  {
    days_back: ($days | tonumber),
    candidate_conversations: ($total | tonumber),
    conversations_with_user_attachments: ($with_att | tonumber),
    attachment_rate_pct: (($with_att | tonumber) * 100 / ($total | tonumber | if . == 0 then 1 else . end) | floor),
  }
' > "$SUMMARY"

# Aggregate content-type frequency + size buckets (read the CSV we just wrote).
content_type_freq=$(awk -F'\t' 'NR>1 && $6 != "" { split($6, ct, "|"); for (i in ct) c[ct[i]]++ } END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$CSV" | sort -t$'\t' -k2 -nr | jq -Rs '
  [ split("\n")[] | select(length > 0) | split("\t") | {content_type: .[0], count: (.[1] | tonumber)} ]
')

size_buckets=$(awk -F'\t' 'NR>1 && $7 > 0 {
    s=$7
    if (s < 1024*1024) b="<1MB"
    else if (s < 5*1024*1024) b="1-5MB"
    else if (s < 25*1024*1024) b="5-25MB"
    else if (s < 100*1024*1024) b="25-100MB"
    else b=">100MB"
    c[b]++
  } END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$CSV" | jq -Rs '
  [ split("\n")[] | select(length > 0) | split("\t") | {bucket: .[0], count: (.[1] | tonumber)} ]
')

# Merge into summary.
jq --argjson ct "$content_type_freq" --argjson sz "$size_buckets" \
  '. + {content_type_frequency: $ct, size_buckets: $sz}' "$SUMMARY" > "$SUMMARY.tmp" && mv "$SUMMARY.tmp" "$SUMMARY"

log "Summary written to $SUMMARY"
log "CSV written to $CSV"
log "Raw conversation archives at $OUT_DIR/conversations/"

# Print the summary to stdout for quick eyeball.
cat "$SUMMARY"
