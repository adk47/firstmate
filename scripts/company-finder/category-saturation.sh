#!/usr/bin/env bash
# category-saturation.sh — per-category saturation report for the Company
# Finder pipeline. READ-ONLY: no writes, no single-flight lock (cheap reads,
# unlike prep-batch.sh/finalize-batch.sh which write and are throttled).
#
# WHY THIS EXISTS (2026-07-23): McLaren's top categories are mined out —
# Company Intelligence holds 2,806 companies, the Seen Ledger 2,690
# ever-adjudicated rows (~95 music education, ~149 live event) — so discovery
# keeps re-finding known names (IN_NOCO) and "no results" reads like a pipeline
# failure instead of the correct outcome of an exhausted category. This report
# makes that visible per category so McLaren/Scout can steer toward categories
# that still have room, instead of re-running a saturated one and reading the
# thin result as broken.
#
# SOURCES (both via lib/common.sh's fetch_table — no re-implemented pagination):
#   - Seen Ledger (Vertical, Status): every company ever suggested, any status.
#   - Company Intelligence (Industry): companies already in the CRM.
# Category names are normalized (trim + lowercase) so casing/whitespace
# variants of the same category merge into one row; an empty/missing category
# buckets as "(uncategorized)".
#
# OUTPUT (stdout):
#   default: a human table (category | in_crm | ever_suggested | rejected |
#   approved | pending), sorted by ever_suggested desc, plus a totals footer.
#   --json:  { generated_at, totals:{companies_in_crm,ledger_rows},
#              categories:[ {category,in_crm,ever_suggested,rejected,approved,pending}, … ] }
#
# Exit codes: 0 ok, 2 a required source was unavailable
#   (SATURATION_SOURCE_UNAVAILABLE — on that exit, stdout carries the
#   fail_json envelope, matching prep-batch.sh/finalize-batch.sh).
#
# Env overrides (mainly for tests): COMPANY_TABLE_ID, LEDGER_TABLE_ID — see
# lib/common.sh for defaults/auto-discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

JSON_OUT=0
if [[ "${1:-}" == "--json" ]]; then
  JSON_OUT=1
fi

# ── Fetch both sources (fetch_table paginates + retries; no snapshot cache — a
# saturation report is a cheap, occasional read, unlike the hot dedupe path). ──
locate_nocodb_api || fail_json 2 SATURATION_SOURCE_UNAVAILABLE "could not locate nocodb-api.sh"
resolve_ledger_table_id "SATURATION_SOURCE_UNAVAILABLE" \
  || fail_json 2 SATURATION_SOURCE_UNAVAILABLE "could not resolve Seen Ledger table id"
LEDGER_RAW="$(fetch_table "$LEDGER_TABLE_ID" "Seen Ledger" "Vertical,Status" "SATURATION_SOURCE_UNAVAILABLE")" \
  || fail_json 2 SATURATION_SOURCE_UNAVAILABLE "fetch of Seen Ledger failed"
CI_RAW="$(fetch_table "$COMPANY_TABLE_ID" "Company Intelligence" "Industry" "SATURATION_SOURCE_UNAVAILABLE")" \
  || fail_json 2 SATURATION_SOURCE_UNAVAILABLE "fetch of Company Intelligence failed"

# ── Aggregate (single jq per source; STDIN, not --argjson — table snapshots
# can be thousands of rows, well past the 128KB argv cap). Category key =
# trim + lowercase; empty → "(uncategorized)". ──────────────────────────────
LEDGER_AGG="$(jq -c '
  def key: (. // "" | gsub("^[ \t\r\n]+|[ \t\r\n]+$"; "") | ascii_downcase);
  map({key: (.Vertical | key), status: (.Status // "")})
  | map(.key |= (if . == "" then "(uncategorized)" else . end))
  | group_by(.key)
  | map({
      category: .[0].key,
      ever_suggested: length,
      rejected:  (map(select(.status == "rejected"))  | length),
      approved:  (map(select(.status == "approved"))  | length),
      pending:   (map(select(.status == "suggested")) | length)
    })
' <<<"$LEDGER_RAW")"

CI_AGG="$(jq -c '
  def key: (. // "" | gsub("^[ \t\r\n]+|[ \t\r\n]+$"; "") | ascii_downcase);
  map({key: (.Industry | key)})
  | map(.key |= (if . == "" then "(uncategorized)" else . end))
  | group_by(.key)
  | map({category: .[0].key, in_crm: length})
' <<<"$CI_RAW")"

TOTAL_LEDGER_ROWS="$(jq 'length' <<<"$LEDGER_RAW")"
TOTAL_CI_ROWS="$(jq 'length' <<<"$CI_RAW")"

# ── Merge (small, aggregated inputs — --argjson is fine here). Full outer
# join on category, defaulting missing counters to 0. ────────────────────────
MERGED="$(jq -cn \
  --argjson ledger "$LEDGER_AGG" \
  --argjson ci "$CI_AGG" \
  --argjson total_ci "$TOTAL_CI_ROWS" \
  --argjson total_ledger "$TOTAL_LEDGER_ROWS" \
  --arg generated_at "$(date -u +%FT%TZ)" '
  ($ledger | map({key: .category, value: .})  | from_entries) as $lby
  | ($ci     | map({key: .category, value: .}) | from_entries) as $cby
  | (($ledger | map(.category)) + ($ci | map(.category)) | unique) as $cats
  | {
      generated_at: $generated_at,
      totals: {companies_in_crm: $total_ci, ledger_rows: $total_ledger},
      categories: ($cats | map(
        (.  ) as $cat
        | ($lby[$cat] // {ever_suggested:0, rejected:0, approved:0, pending:0}) as $l
        | ($cby[$cat] // {in_crm:0}) as $c
        | {category: $cat, in_crm: $c.in_crm, ever_suggested: $l.ever_suggested,
           rejected: $l.rejected, approved: $l.approved, pending: $l.pending}
      ) | sort_by(-.ever_suggested, .category))
    }
')"

if [[ "$JSON_OUT" -eq 1 ]]; then
  printf '%s\n' "$MERGED"
  exit 0
fi

# ── Human table ──────────────────────────────────────────────────────────────
printf '%-30s %8s %14s %9s %9s %8s\n' "category" "in_crm" "ever_suggested" "rejected" "approved" "pending"
jq -r '.categories[] | [.category, .in_crm, .ever_suggested, .rejected, .approved, .pending] | @tsv' <<<"$MERGED" \
  | while IFS=$'\t' read -r category in_crm ever_suggested rejected approved pending; do
      printf '%-30s %8s %14s %9s %9s %8s\n' "$category" "$in_crm" "$ever_suggested" "$rejected" "$approved" "$pending"
    done
printf -- '--\n'
jq -r '"total companies in CRM: \(.totals.companies_in_crm)   total ledger rows: \(.totals.ledger_rows)"' <<<"$MERGED"
