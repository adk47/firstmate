#!/usr/bin/env bash
# Pure matching function. Inputs on stdin:
#   merges.jsonl   one line per executed merge: {mergeInto, profilesIds[]}
#   tickets.jsonl  one line per open profile-merge ticket: {task_id, customer_profile_id}
# Reads merges_path and tickets_path from args. Emits to stdout:
#   {task_id, customer_profile_id, matched_by: "survivor|loser", merge_at}
# One row per ticket that should be closed because a merge already executed.
set -euo pipefail

merges_path="${1:?usage: match-stale-tickets.sh <merges.jsonl> <tickets.jsonl>}"
tickets_path="${2:?usage: match-stale-tickets.sh <merges.jsonl> <tickets.jsonl>}"

merges=$(jq -s '.' "$merges_path")

jq -c --argjson m "$merges" '
  . as $t |
  ( $m
    | map(select(.mergeInto == $t.customer_profile_id) | {at: .at, kind: "survivor"})
    + ( $m | map(
        select( (.profilesIds // []) | any(. == $t.customer_profile_id) )
        | {at: .at, kind: "loser"}
      ))
    | .[0:1]
    | .[]
  ) as $hit |
  {
    task_id: $t.task_id,
    customer_profile_id: $t.customer_profile_id,
    matched_by: $hit.kind,
    merge_at: $hit.at
  }
' "$tickets_path"
