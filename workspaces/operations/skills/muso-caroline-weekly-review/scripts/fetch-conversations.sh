#!/usr/bin/env bash
# Fetch a rolling window (default 30h) of Caroline-touched conversations from Intercom.
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
# Rolling window for the daily pulse. The daily cron sets no per-job env, so the
# 30h default governs; SP2's weekly KB job sets CAROLINE_WINDOW_HOURS=168 inline at
# invocation (cron-jobs.json has no per-job env field). 30h at a 09:00 fire overlaps
# the prior run by (prior local day length - 24h): 6h normally, 5h on the fall-back
# 25h day, 7h on the spring-forward 23h day -- never negative, so a late/missed run
# leaves no ungraded gap. Do not lower toward 24h. fetch-audit.sh reads the same knob
# so the leak audit window rolls in lockstep (a timestamp-less leak must not re-fire
# as a fresh P0 for days).
WINDOW_HOURS="${CAROLINE_WINDOW_HOURS:-30}"
WINDOW_START=$((NOW - WINDOW_HOURS * 3600))

# intercom_request (429/Retry-After + backoff) lives in a shared lib so
# check-escalated.sh reuses the exact same retry logic.
# shellcheck source=lib/intercom-request.sh disable=SC1091
. "$(dirname "$0")/lib/intercom-request.sh"

build_query() {
  local cursor="${1:-}"
  local pagination='{"per_page":150}'
  [ -n "$cursor" ] && pagination="{\"per_page\":150,\"starting_after\":\"$cursor\"}"
  # Broad updated_at search for CANDIDATE ids only. An admin_assignee_id filter
  # would drop conversations Caroline handled that were later reassigned to a
  # human. Authorship is decided after the per-id GET (the list response carries
  # no conversation_parts).
  jq -nc --argjson since "$WINDOW_START" --argjson pagination "$pagination" '
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
# window only scopes the CANDIDATE by .updated_at; a thread bumped recently by a
# customer or human still carries Caroline's OLDER replies. So scope to the window
# HERE too, on the parts: keep a conversation only if Caroline authored a part
# WITHIN the window, and emit only in-window parts — otherwise a stale Caroline
# reply gets re-graded, inflates repeated-question clusters, and seeds the report
# with stale voice/sentiment evidence. The .source opener is always kept as the
# question-context anchor: it is the customer's words (never Caroline's voice, so
# it cannot pollute the voice/sentiment grade) and is needed to judge whether the
# in-window reply was appropriate. Normalize. Part body defaults to "" — Intercom
# note/system parts can have a null/absent body, and a null reaching the LLM grader
# crashes any (.body|test(...)) it composes ("null cannot be matched"), aborting the
# run; keeping body a string makes the grading input null-safe at the source.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  conv=$(intercom_request GET "$API/conversations/$id?display_as=plaintext")
  echo "$conv" | jq -c --arg admin "$CAROLINE_BOT_ADMIN_ID" --argjson cutoff "$WINDOW_START" '
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
           | {author: .author, body: (.body // "")}]
      ),
      started_at: .created_at,
      closed_at: .updated_at
    }
  ' >> "$OUTPUT"
done < "$IDS"

rm -f "$CANDIDATES" "$IDS"

echo "fetch-conversations: wrote $(wc -l < "$OUTPUT") conversations (from $total_candidates candidates, cap $CAP)"
