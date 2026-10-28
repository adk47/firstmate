#!/usr/bin/env bash
# Pure matching function. Inputs on stdin:
#   merges.jsonl   one line per executed merge: {mergeInto, profilesIds[]}
#   tickets.jsonl  one line per open profile-merge ticket:
#                  {task_id, customer_profile_id, keep_id?, dup_ids?[]}
# Reads merges_path and tickets_path from args. Emits to stdout:
#   {task_id, customer_profile_id, matched_by: "survivor|loser|duplicates", merge_at}
# One row per ticket that should be closed because a merge already executed.
#
# A ticket that NAMES its duplicates (dup_ids non-empty) matches only when EVERY named
# duplicate was merged away INTO THE PROFILE THE CUSTOMER ASKED TO KEEP: following the
# merge records forward from the duplicate (loser -> survivor -> ...) must end on the
# same profile as following them forward from keep_id (customer_profile_id when the
# ticket names no keep). So a duplicate folded into a stranger, or a merge that merely
# touched the customer's profile while a named duplicate still stands, is not this
# request done (2026-10-26: tickets were closed "complete" on unrelated or refused
# merges into the customer's profile). merge_at = the latest merge on the duplicates'
# paths. Tickets without dup_ids keep the original customer_profile_id survivor/loser rule.
set -euo pipefail

merges_path="${1:?usage: match-stale-tickets.sh <merges.jsonl> <tickets.jsonl>}"
tickets_path="${2:?usage: match-stale-tickets.sh <merges.jsonl> <tickets.jsonl>}"

# --slurpfile, not --argjson "$(jq -s ...)": the ledger holds one row per merged loser
# (hundreds over a 90-day window) and a command-line argument that size fails with
# "Argument list too long" (exit 126), aborting the whole sweep.
jq -c --slurpfile m "$merges_path" '
  # loser -> {to, at}: where each merged-away profile went, and when (last record wins).
  ( reduce ($m[] | . as $r | (.profilesIds // [])[] | {key: ascii_downcase, value: {to: ($r.mergeInto | ascii_downcase), at: $r.at}})
      as $e ({}; .[$e.key] = $e.value) ) as $edge |
  # Follow the forward chain from a profile id: {end, ats[]}; bounded so a cycle cannot hang.
  def walk($id): {cur: $id, ats: [], n: 0}
    | until(($edge[.cur] == null) or (.n >= 20); {cur: $edge[.cur].to, ats: (.ats + [$edge[.cur].at]), n: (.n + 1)})
    | {end: .cur, ats: .ats};
  . as $t |
  (($t.dup_ids // []) | map(ascii_downcase)) as $dups |
  # An explicit keep the closer could not read ("unreadable:<ref>") or that names
  # different profiles ("conflicting:<ids>") holds the ticket open on every rule.
  if (($t.keep_id // "") | test("^(unreadable|conflicting):")) then empty
  elif ($dups | length) > 0 then
    ((($t.keep_id // $t.customer_profile_id) // "") | ascii_downcase) as $keep |
    walk($keep).end as $home |
    [ $dups[] | select(. != $keep) | walk(.) ] as $paths |
    if ($keep != "") and ($paths | length) > 0 and ($paths | all((.ats | length) > 0 and .end == $home)) then
      {
        task_id: $t.task_id,
        customer_profile_id: $t.customer_profile_id,
        matched_by: "duplicates",
        merge_at: ($paths | map(.ats | max) | max)
      }
    else empty end
  else
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
  end
' "$tickets_path"
