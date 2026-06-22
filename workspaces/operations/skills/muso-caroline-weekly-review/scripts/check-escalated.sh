#!/usr/bin/env bash
# Source-1 follow-up: for each ESCALATED conv in the guard audit, check whether a
# HUMAN (a non-Caroline admin) has since replied.
#
# An escalated conv had Caroline's reply SUPPRESSED and was reassigned to a human
# inbox, so it does NOT appear in conversations.jsonl (which keeps only convs
# Caroline authored in-window). We therefore GET each escalated conv directly. A
# conv with no non-Caroline admin part is an OPEN action item (a customer is
# waiting on a human). Emits {conv, human_replied, url} to
# $WORKDIR/escalated-status.jsonl and keeps ONLY those three fields -- the raw
# transcript is parsed in memory and never written to disk.
set -euo pipefail

: "${MUSOAI_INTERCOM_TOKEN:?MUSOAI_INTERCOM_TOKEN required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"
: "${WORKDIR:?WORKDIR required}"

# Canonical workspace-scoped Intercom deep-link (the legacy
# inboxes/all/conversations/<id> form 404s). Default + override mirror
# render-digest.py / linkify-convs.sh and the data-complaint watchdog.
WORKSPACE_ID="${INTERCOM_WORKSPACE_ID:-dwjzhcge}"

# shellcheck source=lib/intercom-request.sh disable=SC1091
. "$(dirname "$0")/lib/intercom-request.sh"

API="https://api.intercom.io"
AUDIT="$WORKDIR/audit.jsonl"
OUTPUT="$WORKDIR/escalated-status.jsonl"
: > "$OUTPUT"

# Treat "audit absent" and "audit present, zero escalations" identically.
[ -f "$AUDIT" ] || { echo "check-escalated: no audit.jsonl; nothing to check"; exit 0; }

ids=$(jq -r 'select(.kind == "reasoning_leak" and .action == "escalated")
             | .conv | select(. != null and . != "")' "$AUDIT" | sort -u)
[ -n "$ids" ] || { echo "check-escalated: no escalated convs"; exit 0; }

while IFS= read -r id; do
  [ -n "$id" ] || continue
  conv=$(intercom_request GET "$API/conversations/$id?display_as=plaintext") || {
    # Fail SAFE: a transient/4xx GET must not make a suppressed-reply escalation
    # vanish from the daily P1 list. Emit a conservative human_replied:false row
    # (customer assumed still waiting) so the digest still surfaces it, and keep
    # going rather than aborting the whole run on one bad conversation.
    echo "check-escalated: GET $id failed; emitting conservative open row" >&2
    jq -nc --arg conv "$id" --arg ws "$WORKSPACE_ID" \
      '{conv: $conv, human_replied: false,
        url: ("https://app.intercom.com/a/inbox/" + $ws + "/inbox/conversation/" + $conv)}' >> "$OUTPUT"
    continue
  }
  # human_replied = a non-Caroline admin replied AFTER the customer's most recent
  # message -- i.e. the customer is no longer waiting. Anchoring on the customer's
  # last message (rather than "any non-Caroline admin part anywhere") is what keeps
  # a human reply that PREDATES the escalation from hiding a still-open action item:
  # if the only human part is older than the customer's latest message, the customer
  # is still waiting and the escalation must stay open. We have no escalation
  # timestamp to anchor on (leak markers carry none -- see fetch-audit.sh), and the
  # customer's last message is a stronger "still waiting?" anchor anyway. created_at
  # is Intercom epoch seconds; `numbers` drops parts with no timestamp.
  #
  # Fail SAFE when ordering cannot be proven: if NO customer message carries a
  # timestamp ($lastUser is not a number) we cannot show the human replied after the
  # customer, so we leave the escalation OPEN rather than guessing it answered. The
  # customer opener lives in .source, follow-ups in conversation_parts.
  human_replied=$(printf '%s' "$conv" | jq -r --arg bot "$CAROLINE_BOT_ADMIN_ID" '
    [ (.source // empty), (.conversation_parts.conversation_parts[]? ) ] as $all
    | ( [ $all[] | select(.author.type == "user")  | .created_at | numbers ] | max ) as $lastUser
    | ( if ($lastUser | type) != "number" then false
        else [ $all[]
               | select(.author.type == "admin" and (.author.id | tostring) != $bot)
               | .created_at | numbers
               | select(. > $lastUser) ] | length > 0
        end )
    | tostring' 2>/dev/null || true)
  [ "$human_replied" = "true" ] || human_replied=false
  jq -nc --arg conv "$id" --argjson human "$human_replied" --arg ws "$WORKSPACE_ID" \
    '{conv: $conv, human_replied: $human,
      url: ("https://app.intercom.com/a/inbox/" + $ws + "/inbox/conversation/" + $conv)}' >> "$OUTPUT"
done <<< "$ids"

echo "check-escalated: wrote $(wc -l < "$OUTPUT") records"
