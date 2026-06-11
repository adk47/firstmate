#!/usr/bin/env bash
# migrate-normalize-domains.sh — one-time normalization of stored Domain
# values, doubling as a permanent re-runnable uniqueness audit.
#
# WHY: Company Intelligence accumulated mixed-format domains
# ("https://www.imbschool.eu", "apogeedigital.com (updated)", "landr.com").
# NocoDB Cloud cannot enforce a unique constraint, so the write-path scripts
# (ledger.sh) enforce it — but only over NORMALIZED values. This script
# brings the existing rows up to the same normal form (bare domain.tld) so
# collision prechecks and dedupe snapshots see clean data.
#
# MODES
#   (default)   dry-run: print the JSON report, write nothing.
#   --apply     apply the changes (non-collision rows only, chunks of 50).
#   --check     audit mode: dry-run that exits 1 if ANY change or collision
#               is found (0 when clean). Use as a recurring drift detector.
#   --table <id>  target table (default COMPANY_TABLE_ID); run it against the
#               ledger too if it ever drifts.
#
# REPORT (stdout):
#   { "changes":    [{id, name, from, to}],          # rows --apply would touch
#     "collisions": [{domain, rows: [{id,name,current}]}],  # same normalized
#                                                    # domain in >1 row — NEVER
#                                                    # auto-merged; hand to a
#                                                    # human (data would be lost)
#     "skipped_empty": N,
#     "stats": {rows, changes, collisions} }
#
# Idempotent: re-running after --apply yields an empty changes list.
#
# Env overrides (mainly for tests):
#   NOCODB_API_SH      path to nocodb-api.sh (auto-located if unset)
#   COMPANY_TABLE_ID   default mvr6nmzcv7albxt
#
# Exit codes: 0 ok / clean, 1 usage error or (--check) dirty,
#             2 source unavailable, 4 write failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CHUNK=50

MODE="dry-run"
TABLE_ID="$COMPANY_TABLE_ID"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --check) MODE="check"; shift ;;
    --table) TABLE_ID="${2:?--table needs an id}"; shift 2 ;;
    --help|-h) awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"; exit 0 ;;
    *) echo "ERROR: unknown flag $1" >&2; exit 1 ;;
  esac
done

locate_nocodb_api

# ── Snapshot the table (retry once) ─────────────────────────────────────────
TABLE_LABEL="table $TABLE_ID"
[[ "$TABLE_ID" == "$COMPANY_TABLE_ID" ]] && TABLE_LABEL="Company Intelligence"
combined="$(fetch_table "$TABLE_ID" "$TABLE_LABEL" "Id,Domain,Company Name" "MIGRATION_SOURCE_UNAVAILABLE")"

# ── Build the report ────────────────────────────────────────────────────────
report=$(jqn -c '
  include "normalize";
  map({id: .Id, name: (."Company Name" // ""), from: (.Domain // ""),
       to: (.Domain | norm_domain)}) as $rows
  | ($rows | map(select(.to == "")) | length) as $empty
  | ($rows | map(select(.to != ""))) as $nonempty
  | ($nonempty | group_by(.to) | map(select(length > 1))
     | map({domain: .[0].to,
            rows: map({id, name, current: .from})})) as $collisions
  | ($collisions | map(.rows[].id)) as $collision_ids
  | ($nonempty | map(select(.from != .to and (.id as $i | $collision_ids | index($i) | not)))) as $changes
  | {changes: $changes, collisions: $collisions, skipped_empty: $empty,
     stats: {rows: ($rows | length), changes: ($changes | length),
             collisions: ($collisions | length)}}' <<<"$combined")

jq . <<<"$report"

case "$MODE" in
  check)
    dirty=$(jq '.stats.changes + .stats.collisions' <<<"$report")
    [[ "$dirty" -eq 0 ]] || exit 1
    ;;
  apply)
    total=$(jq '.changes | length' <<<"$report")
    applied=0
    while [[ "$applied" -lt "$total" ]]; do
      patch=$(jq -c --argjson off "$applied" --argjson lim "$CHUNK" \
        '.changes[$off:$off+$lim] | map({"Id": .id, "Domain": .to})' <<<"$report")
      if ! run_nocodb records.update "$TABLE_ID" "$patch" >/dev/null 2>&1; then
        if ! run_nocodb records.update "$TABLE_ID" "$patch" >/dev/null 2>&1; then
          echo "MIGRATION_WRITE_FAILED at offset $applied (of $total) — re-run to resume (idempotent)." >&2
          exit 4
        fi
      fi
      applied=$((applied + $(jq 'length' <<<"$patch")))
      echo "applied $applied/$total" >&2
    done
    ;;
esac
