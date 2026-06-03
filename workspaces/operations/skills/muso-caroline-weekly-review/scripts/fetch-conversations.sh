#!/usr/bin/env bash
# Fetch 7 days of Caroline-touched conversations from Intercom.
# Requires env from preflight.sh: WORKDIR, CAROLINE_BOT_ADMIN_ID.
#
# TWO-STEP retrieve (confirmed against the live API 2026-06-01):
# /conversations/search returns candidate IDs + .source but the embedded
# .conversation_parts array is EMPTY in the list representation. Caroline's
# admin replies — which we filter on and grade — only come back from
# GET /conversations/{id}. So: search for candidate IDs in the window, cap to
# the most-recent CAP, GET each by id, then filter Caroline-authored + normalize.
# Filtering on the search response alone graded an empty dataset (every
# conversation dropped) — that was the bug this flow fixes.

set -euo pipefail

: "${MUSOAI_INTERCOM_TOKEN:?MUSOAI_INTERCOM_TOKEN required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"
: "${WORKDIR:?WORKDIR required}"

OUTPUT="$WORKDIR/conversations.jsonl"
: > "$OUTPUT"

API="https://api.intercom.io"
CAP="${CAROLINE_FETCH_CAP:-200}"   # bounds per-id GET load + the grader's token budget

NOW=$(date +%s)
SEVEN_DAYS_AGO=$((NOW - 7 * 86400))

# Generic Intercom request with 429/Retry-After + exponential backoff (max 3).
# Prints the response body to stdout. $1=method $2=url $3=body(optional).
intercom_request() {
  local method="$1" url="$2" body="${3:-}" attempt=0 max=3 rc
  while [ "$attempt" -lt "$max" ]; do
    local tmp_headers tmp_body
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    set +e
    if [ -n "$body" ]; then
      curl -sS -D "$tmp_headers" -o "$tmp_body" -X "$method" \
        -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
        -H "Intercom-Version: 2.11" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$body" "$url"
    else
      curl -sS -D "$tmp_headers" -o "$tmp_body" -X "$method" \
        -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
        -H "Intercom-Version: 2.11" \
        -H "Accept: application/json" "$url"
    fi
    rc=$?
    set -e
    local status
    # `|| true` is REQUIRED: under `set -euo pipefail`, a curl connect failure
    # (DNS/TLS/connect blip) writes no headers, so grep finds no match and exits
    # 1; pipefail propagates that, the assignment returns non-zero, and set -e
    # would abort the helper here — BEFORE the `rc != 0` retry branch below. That
    # turned a retryable transient into a hard single-attempt failure.
    status=$(grep -oiE '^HTTP/[0-9.]+ +[0-9]+' "$tmp_headers" 2>/dev/null | head -1 | awk '{print $NF}' || true)
    if [ "$status" = "429" ]; then
      local wait
      # Same `|| true` reason: a 429 may omit Retry-After (it is optional), so
      # grep can no-match and abort under set -e before the fallback below.
      wait=$(grep -i "^Retry-After:" "$tmp_headers" | awk '{print $2}' | tr -d '\r' || true)
      [ -z "$wait" ] && wait=$((1 << attempt))
      sleep "$wait"
      attempt=$((attempt + 1))
      rm -f "$tmp_headers" "$tmp_body"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$tmp_headers" "$tmp_body"
      attempt=$((attempt + 1))
      sleep $((1 << attempt))
      continue
    fi
    case "${status:-}" in
      2*)
        cat "$tmp_body"
        rm -f "$tmp_headers" "$tmp_body"
        return 0
        ;;
      5*)
        # Transient server error — retry with backoff.
        rm -f "$tmp_headers" "$tmp_body"
        attempt=$((attempt + 1))
        sleep $((1 << attempt))
        continue
        ;;
      *)
        # 4xx (auth/not-found/bad-request) or unparseable: fail loud so an error
        # response can never become a silently-empty candidate set or a dropped
        # conversation.
        echo "intercom_request: $method $url returned HTTP ${status:-unknown}" >&2
        rm -f "$tmp_headers" "$tmp_body"
        return 1
        ;;
    esac
  done
  echo "intercom_request: exhausted retries for $method $url" >&2
  return 1
}

build_query() {
  local cursor="${1:-}"
  local pagination='{"per_page":150}'
  [ -n "$cursor" ] && pagination="{\"per_page\":150,\"starting_after\":\"$cursor\"}"
  # Broad updated_at search for CANDIDATE ids only. An admin_assignee_id filter
  # would drop conversations Caroline handled that were later reassigned to a
  # human. Authorship is decided after the per-id GET (the list response carries
  # no conversation_parts).
  jq -nc --argjson since "$SEVEN_DAYS_AGO" --argjson pagination "$pagination" '
    {query: {field: "updated_at", operator: ">", value: $since}, pagination: $pagination}'
}

# 1. Collect candidate {id, updated_at} across all search pages.
CANDIDATES="$WORKDIR/candidates.jsonl"
: > "$CANDIDATES"
cursor=""
while :; do
  resp=$(intercom_request POST "$API/conversations/search" "$(build_query "$cursor")")
  echo "$resp" | jq -c '.conversations[]? | {id: (.id | tostring), updated_at: .updated_at}' >> "$CANDIDATES"
  cursor=$(echo "$resp" | jq -r '.pages.next.starting_after // empty')
  [ -z "$cursor" ] && break
done

# 2. Cap to the CAP most-recently-updated candidates to bound the GET load and
# the grader's token budget. Log loudly if truncated — never silently.
total_candidates=$(wc -l < "$CANDIDATES" | tr -d ' ')
IDS="$WORKDIR/candidate-ids.txt"
jq -rs --argjson cap "$CAP" 'sort_by(.updated_at) | reverse | .[0:$cap] | .[].id' "$CANDIDATES" > "$IDS"
if [ "$total_candidates" -gt "$CAP" ]; then
  echo "fetch-conversations: WARN $total_candidates candidates in window; retrieving the $CAP most-recent (dropped $((total_candidates - CAP)))" >&2
fi

# 3. GET each candidate by id (full transcript incl. parts + source). The search
# window only scopes the CANDIDATE by .updated_at; a thread bumped this week by a
# customer or human still carries Caroline's OLDER replies. So scope to the week
# HERE too, on the parts: keep a conversation only if Caroline authored a part
# WITHIN the window, and emit only in-window parts — otherwise a stale Caroline
# reply gets re-graded, inflates repeated-question clusters, and seeds the report
# with stale voice/sentiment evidence. The .source opener is always kept as the
# question-context anchor: it is the customer's words (never Caroline's voice, so
# it cannot pollute the voice/sentiment grade) and is needed to judge whether the
# in-window reply was appropriate. Normalize.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  conv=$(intercom_request GET "$API/conversations/$id?display_as=plaintext")
  echo "$conv" | jq -c --arg admin "$CAROLINE_BOT_ADMIN_ID" --argjson cutoff "$SEVEN_DAYS_AGO" '
    select([.conversation_parts.conversation_parts[]? |
            select(.author.type == "admin" and (.author.id | tostring) == $admin
                   and ((.created_at // 0) >= $cutoff))] | length > 0) |
    {
      id: (.id | tostring),
      contact_id: (.contact_id // .contacts.contacts[0].id // null),
      customer_email: (.customer.email // .contacts.contacts[0].email // null),
      customer_first_name: ((.customer.name // .source.author.name // .contacts.contacts[0].name // "") | split(" ")[0]),
      customer_last_name: ((.customer.name // .source.author.name // .contacts.contacts[0].name // "") | split(" ") | .[1:] | join(" ")),
      parts: (
        [.source | select((.body // "") != "") | {author: .author, body: .body}]
        + [.conversation_parts.conversation_parts[]?
           | select((.created_at // 0) >= $cutoff)
           | {author: .author, body: .body}]
      ),
      started_at: .created_at,
      closed_at: .updated_at
    }
  ' >> "$OUTPUT"
done < "$IDS"

rm -f "$CANDIDATES" "$IDS"

echo "fetch-conversations: wrote $(wc -l < "$OUTPUT") conversations (from $total_candidates candidates, cap $CAP)"
