#!/usr/bin/env bash
# Compute unique_customers for a proposed cluster.
# Input on stdin: {"topic": "<str>", "conversation_ids": ["<id>", ...]}
# Input arg 1: path to conversations.jsonl with {id, contact_id, customer_email}
# Output on stdout: {"topic", "unique_customers", "conversation_ids"}.
#
# Dedup key: contact_id; fallback to customer_email when contact_id is null/blank.
# Rows where BOTH contact_id and customer_email are null/blank do not count.
#
# NOTE: The plan specified `--slurpfile convs <(jq -c '.' "$CONVERSATIONS")` with
# `$convs[0][]` iteration, but that fails — the inner jq emits JSONL (one object
# per line), and slurpfile wraps each top-level value as an array element, so
# `$convs[0]` is the first object (a string), not the full array. The correct
# idiom is `--slurpfile convs "$CONVERSATIONS"` with `$convs[]` iteration, which
# presents every line as a separate array element.

set -euo pipefail

CONVERSATIONS="${1:?path to conversations.jsonl required}"
INPUT="$(cat)"

# Read proposed cluster
TOPIC=$(printf '%s' "$INPUT" | jq -r '.topic')
IDS_JSON=$(printf '%s' "$INPUT" | jq -c '.conversation_ids')

# Build a lookup of id -> dedup_key using slurpfile directly on JSONL.
# $convs is an array where each element is one top-level value from the file.
LOOKUP=$(jq -nc --slurpfile convs "$CONVERSATIONS" '
  reduce $convs[] as $c ({}; .[$c.id] = (
    if ($c.contact_id // "" | length) > 0 then "cid:" + $c.contact_id
    elif ($c.customer_email // "" | length) > 0 then "email:" + $c.customer_email
    else null
    end
  ))
')

UNIQUE=$(jq -nr --argjson ids "$IDS_JSON" --argjson lookup "$LOOKUP" '
  [$ids[] | $lookup[.] | select(. != null)] | unique | length
')

jq -nc \
  --arg topic "$TOPIC" \
  --argjson ids "$IDS_JSON" \
  --argjson unique "$UNIQUE" \
  '{topic: $topic, unique_customers: $unique, conversation_ids: $ids}'
