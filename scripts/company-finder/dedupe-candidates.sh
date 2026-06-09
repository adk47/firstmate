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
#
# Exit codes: 0 success, 1 usage/input error, 2 dedup source unavailable.
set -euo pipefail

COMPANY_TABLE_ID="${COMPANY_TABLE_ID:-mvr6nmzcv7albxt}"
CONTACTS_TABLE_ID="${CONTACTS_TABLE_ID:-m9vsbijhrr9ddeu}"
PAGE_LIMIT=1000

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,48p' "$0"
  exit 0
fi

# ── Locate the NocoDB API wrapper ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${NOCODB_API_SH:-}" ]]; then
  for cand in \
    "$SCRIPT_DIR/../../skills-all/muso-nocodb/scripts/nocodb-api.sh" \
    "/opt/hydra/skills-all/muso-nocodb/scripts/nocodb-api.sh"; do
    if [[ -f "$cand" ]]; then NOCODB_API_SH="$cand"; break; fi
  done
fi
if [[ -z "${NOCODB_API_SH:-}" || ! -f "$NOCODB_API_SH" ]]; then
  echo "ERROR: could not locate nocodb-api.sh (set NOCODB_API_SH)." >&2
  exit 1
fi

run_nocodb() { bash "$NOCODB_API_SH" --raw "$@"; }

# fetch_table <tableId> <label> — paginate the full Domain+Company Name columns,
# retry once on failure, emit a JSON array of {domain,name,table} rows.
fetch_table() {
  local tid="$1" label="$2"
  local offset=0 combined="[]" resp chunk n islast
  while :; do
    if ! resp=$(run_nocodb records.ls "$tid" --fields "Domain,Company Name" \
                  --limit "$PAGE_LIMIT" --offset "$offset" 2>/dev/null); then
      # one retry before declaring the source unavailable
      if ! resp=$(run_nocodb records.ls "$tid" --fields "Domain,Company Name" \
                    --limit "$PAGE_LIMIT" --offset "$offset" 2>/dev/null); then
        echo "DEDUP_SOURCE_UNAVAILABLE: $label ($tid)" >&2
        return 2
      fi
    fi
    if ! chunk=$(jq -ce '.list // empty' <<<"$resp" 2>/dev/null); then
      echo "DEDUP_SOURCE_UNAVAILABLE: $label ($tid) — unexpected response shape" >&2
      return 2
    fi
    combined=$(jq -c --argjson a "$combined" --argjson b "$chunk" '$a + $b' <<<'null')
    n=$(jq 'length' <<<"$chunk")
    islast=$(jq -r --argjson lim "$PAGE_LIMIT" \
      '.pageInfo.isLastPage // ((.list | length) < $lim)' <<<"$resp")
    if [[ "$islast" == "true" || "$n" -lt "$PAGE_LIMIT" ]]; then break; fi
    offset=$((offset + PAGE_LIMIT))
  done
  jq -c --arg t "$label" \
    'map({domain:(.Domain // ""), name:(."Company Name" // ""), table:$t})' <<<"$combined"
}

# ── Read + validate candidates ──────────────────────────────────────────────
CANDS="$(cat)"
[[ -z "${CANDS//[[:space:]]/}" ]] && CANDS="[]"
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$CANDS"; then
  echo "ERROR: stdin must be a JSON array of {name,domain} candidates." >&2
  exit 1
fi

# ── Snapshot both tables once (required sources) ────────────────────────────
COMPANY_ROWS="$(fetch_table "$COMPANY_TABLE_ID" "Company Intelligence")"
CONTACT_ROWS="$(fetch_table "$CONTACTS_TABLE_ID" "Contacts Intelligence")"
EXISTING="$(jq -c -s 'add' <<<"$COMPANY_ROWS"$'\n'"$CONTACT_ROWS")"

# ── Classify (single jq; normalization applied identically to both sides) ────
jq -n --argjson existing "$EXISTING" --argjson cands "$CANDS" '
  def norm_domain:
    (. // "") | ascii_downcase
    | gsub("^\\s+|\\s+$"; "")
    | gsub("^[a-z]+://"; "")     # scheme
    | gsub("^www\\."; "")        # leading www.
    | split(" ")[0]             # drop trailing annotations, e.g. "x.com (updated)"
    | split("/")[0]             # path
    | split("?")[0]             # query
    | split(":")[0]             # port
    | gsub("\\.$"; "");         # trailing dot
  def norm_name:
    (. // "") | ascii_downcase
    | gsub("[^a-z0-9]+"; " ")    # punctuation -> space
    | gsub("^\\s+|\\s+$"; "")
    | gsub("\\s+"; " ");

  ($existing | map(. + {nd: (.domain | norm_domain), nn: (.name | norm_name)})) as $ex
  | ($ex | map(select(.nd != "")) | map({key: .nd, value: .}) | from_entries) as $bydom
  | ($ex | map(select(.nn != "")) | map({key: .nn, value: .}) | from_entries) as $byname
  | ($ex | map(select(.nn != "" and (.nn | length) >= 4))) as $exnames
  | reduce ($cands[] | . + {nd: (.domain | norm_domain), nn: (.name | norm_name)}) as $c
      ({new: [], duplicates: [], name_flags: []};
        ($bydom[$c.nd]) as $dm
        | ($byname[$c.nn]) as $nm
        | if ($c.nd != "" and $dm) then
            .duplicates += [{name: $c.name, domain: $c.domain, reason: "domain",
                             matched_against: {domain: $dm.domain, name: $dm.name, table: $dm.table}}]
          elif ($c.nn != "" and $nm) then
            .duplicates += [{name: $c.name, domain: $c.domain, reason: "name",
                             matched_against: {domain: $nm.domain, name: $nm.name, table: $nm.table}}]
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
            | if $pf != null then
                .name_flags += [{candidate: $clean,
                                 possible_match: {domain: $pf.domain, name: $pf.name, table: $pf.table}}]
              else . end
          end)
  | . + {stats: {checked: ($cands | length), new: (.new | length), dropped: (.duplicates | length)}}
'
