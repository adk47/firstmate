#!/usr/bin/env bash
# dedupe-candidates.sh — deterministic NocoDB dedup filter for the CMO Company Finder.
#
# WHY THIS EXISTS
#   Discovery (web search) and scoring stay LLM-driven, but the dedup MUST be
#   deterministic. The old approach asked the agent to run an exact
#   `(Domain,eq,<domain>)` lookup per candidate across two tables — ~60+ tool
#   calls per run. That leaked duplicates two ways: (1) exact eq is brittle to
#   domain formatting (`https://www.AudioShake.ai/` != stored `audioshake.ai`),
#   and (2) the agent shortcut the per-candidate loop (44-66% leak-through,
#   2026-06-08/09). This packages the whole dedup as ONE sanctioned, tested
#   call: snapshot both tables once, normalize both sides identically, and
#   set-match by domain + conservative full name.
#
# INPUT  (stdin): JSON array of candidates, e.g.
#   [{"name":"AudioShake","domain":"https://www.audioshake.ai/"}, ...]
#   Extra keys per candidate (industry, why, ...) are preserved on the output.
#
# OUTPUT (stdout): JSON
#   { "new":         [ <candidate objects NOT already in NocoDB> ],
#     "duplicates":  [ {name,domain,reason,matched_against:{domain,name,table}} ],
#     "name_flags":  [ {candidate, possible_match} ],   # NEW items with a partial
#                                                        # name overlap — surfaced
#                                                        # for human eyes, NOT dropped
#     "stats":       {checked,new,dropped} }
#
# MATCHING (per the 2026-06-09 decision):
#   DROP if normalized domain is already present, OR normalized full company
#   name is already present. Partial/fuzzy name overlaps are FLAGGED, never
#   dropped, to avoid suppressing genuinely-new companies.
#
# SOURCES: Company Intelligence + Contacts Intelligence + the Company Seen
#   Ledger (every company ever suggested in a batch, any status — suggested /
#   rejected / approved). All three are REQUIRED: a silently-missing ledger
#   would re-suggest every previously rejected company.
#
# WITHIN-BATCH SELF-DEDUP: per-category discovery subagents are blind to each
#   other, so the same company can arrive twice in one union batch. First
#   occurrence wins; later batch-internal domain/name matches land in
#   .duplicates with reason "batch" and matched_against.table "(this batch)".
#
# FAILURE SEMANTICS (mirrors the company-finder-daily cron doctrine):
#   Each table fetch is retried once. A recovered transient exits 0. If a
#   REQUIRED dedup source is still unreachable after the retry, this exits
#   non-zero and prints `DEDUP_SOURCE_UNAVAILABLE: <table>` on stderr so the
#   caller marks the batch PARTIAL/UNSAFE instead of shipping with incomplete
#   dedup.
#
# Env overrides (mainly for tests):
#   NOCODB_API_SH        path to nocodb-api.sh (auto-located if unset)
#   COMPANY_TABLE_ID     default mvr6nmzcv7albxt (Company Intelligence)
#   CONTACTS_TABLE_ID    default m9vsbijhrr9ddeu (Contacts Intelligence)
#   LEDGER_TABLE_ID      Company Seen Ledger — auto-discovered by title at
#                        runtime (lib/common.sh resolve_ledger_table_id);
#                        set only to skip/override the lookup
#
# Exit codes: 0 success, 1 usage/input error, 2 dedup source unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

locate_nocodb_api
resolve_ledger_table_id "DEDUP_SOURCE_UNAVAILABLE"

# ── Read + validate candidates ──────────────────────────────────────────────
CANDS="$(read_candidates_stdin)"

# ── Snapshot all three tables once (required sources) ───────────────────────
# fetch_label <tableId> <label> — raw fetch + map to {domain,name,table}.
fetch_label() {
  local raw
  raw="$(fetch_table "$1" "$2" "Domain,Company Name" "DEDUP_SOURCE_UNAVAILABLE")" || return 2
  jq -c --arg t "$2" \
    'map({domain:(.Domain // ""), name:(."Company Name" // ""), table:$t})' <<<"$raw"
}

COMPANY_ROWS="$(fetch_label "$COMPANY_TABLE_ID" "Company Intelligence")"
CONTACT_ROWS="$(fetch_label "$CONTACTS_TABLE_ID" "Contacts Intelligence")"
LEDGER_ROWS="$(fetch_label "$LEDGER_TABLE_ID" "Seen Ledger")"
EXISTING="$(jq -c -s 'add' <<<"$COMPANY_ROWS"$'\n'"$CONTACT_ROWS"$'\n'"$LEDGER_ROWS")"

# ── Classify (single jq; normalization applied identically to both sides) ────
# EXISTING (the full 3-table snapshot — thousands of rows) is fed on STDIN, not
# via --argjson: a single argv string is capped at MAX_ARG_STRLEN (128KB), which
# the ~300KB snapshot overflows once the read actually completes ("jq: Argument
# list too long", 2026-06-13, exposed by the NocoDB throttling fix). CANDS is a
# bounded discovery batch, so it stays on argv.
jqn --argjson cands "$CANDS" '
  include "normalize";

  (map(. + {nd: (.domain | norm_domain), nn: (.name | norm_name)})) as $ex
  | ($ex | map(select(.nd != "")) | map({key: .nd, value: .}) | from_entries) as $bydom
  | ($ex | map(select(.nn != "")) | map({key: .nn, value: .}) | from_entries) as $byname
  | ($ex | map(select(.nn != "" and (.nn | length) >= 4))) as $exnames
  | reduce ($cands[] | . + {nd: (.domain | norm_domain), nn: (.name | norm_name)}) as $c
      ({new: [], duplicates: [], name_flags: [], bnd: {}, bnn: {}};
        ($bydom[$c.nd]) as $dm
        | ($byname[$c.nn]) as $nm
        | if ($c.nd != "" and $dm) then
            .duplicates += [{name: $c.name, domain: $c.domain, reason: "domain",
                             matched_against: {domain: $dm.domain, name: $dm.name, table: $dm.table}}]
          elif ($c.nn != "" and $nm) then
            .duplicates += [{name: $c.name, domain: $c.domain, reason: "name",
                             matched_against: {domain: $nm.domain, name: $nm.name, table: $nm.table}}]
          elif ($c.nd != "" and .bnd[$c.nd]) then
            .bnd[$c.nd] as $bm
            | .duplicates += [{name: $c.name, domain: $c.domain, reason: "batch",
                               matched_against: {domain: $bm.domain, name: $bm.name, table: "(this batch)"}}]
          elif ($c.nn != "" and .bnn[$c.nn]) then
            .bnn[$c.nn] as $bm
            | .duplicates += [{name: $c.name, domain: $c.domain, reason: "batch",
                               matched_against: {domain: $bm.domain, name: $bm.name, table: "(this batch)"}}]
          else
            ( ($c.nn | length) >= 4 ) as $long
            | ( $c.nn | split(" ")[0] ) as $ctok
            | ( if $long
                then ($exnames
                      | map(. as $e | select(
                          ($e.nn | contains($c.nn)) or ($c.nn | contains($e.nn))
                          or (($ctok | length) >= 4 and ($e.nn | split(" ")[0]) == $ctok)))
                      | .[0])
                else null end ) as $pf
            | ($c | del(.nd, .nn)) as $clean
            | .new += [$clean]
            | (if $c.nd != "" then .bnd[$c.nd] = {domain: $c.domain, name: $c.name} else . end)
            | (if $c.nn != "" then .bnn[$c.nn] = {domain: $c.domain, name: $c.name} else . end)
            | if $pf != null then
                .name_flags += [{candidate: $clean,
                                 possible_match: {domain: $pf.domain, name: $pf.name, table: $pf.table}}]
              else . end
          end)
  | del(.bnd, .bnn)
  | . + {stats: {checked: ($cands | length), new: (.new | length), dropped: (.duplicates | length)}}
' <<<"$EXISTING"
