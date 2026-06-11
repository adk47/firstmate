#!/usr/bin/env bash
# setup-ledger-table.sh — one-time, idempotent creation of the Company Seen
# Ledger table in the NocoDB B2B-Ads Intelligence base.
#
# WHY: the ledger records every company the Company Finder has EVER suggested
# (status: suggested / rejected / approved) so dedupe-candidates.sh can drop
# previously-surfaced companies even when they were rejected and never reached
# Company Intelligence. Company Intelligence stays an approved-only CRM.
#
# Idempotent: if a table titled "Company Seen Ledger" already exists in the
# base, prints its id and exits 0 without creating anything.
#
# Output (stdout, last line): LEDGER_TABLE_ID=<id>
# This one idempotent run is the ONLY operator step: every company-finder
# script auto-discovers the table by this title at runtime
# (lib/common.sh resolve_ledger_table_id) — no pin commit, no redeploy.
#
# Env:
#   NOCODB_API_SH   path to nocodb-api.sh (auto-located if unset)
#   NOCODB_BASE_ID  default p11hvpwapu4hv0x (B2B-ADS-intelligence)
#
# Exit codes: 0 ok, 1 setup error, 2 NocoDB unreachable/unexpected response.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

BASE_ID="$NOCODB_BASE_ID"
TABLE_TITLE="$LEDGER_TABLE_TITLE"

locate_nocodb_api

# ── Idempotency: reuse an existing table with the same title ────────────────
if ! existing=$(run_nocodb tables.ls "$BASE_ID" 2>&1); then
  echo "ERROR: could not list tables in base $BASE_ID: $existing" >&2
  exit 2
fi
existing_id=$(jq -r --arg t "$TABLE_TITLE" \
  '.list[]? | select(.title == $t) | .id' <<<"$existing" | head -1)
if [[ -n "$existing_id" ]]; then
  echo "Table \"$TABLE_TITLE\" already exists — nothing to do." >&2
  echo "LEDGER_TABLE_ID=$existing_id"
  exit 0
fi

# ── Create ──────────────────────────────────────────────────────────────────
# SingleSelect needs both dtxp and colOptions.options[] (see
# skills-all/muso-nocodb/references/api-reference.md). Domain is the primary
# value (pv) and is ALWAYS stored normalized (bare domain.tld) — writes go
# through ledger.sh, never records.create directly.
body=$(cat <<'JSON'
{
  "title": "Company Seen Ledger",
  "table_name": "company_seen_ledger",
  "columns": [
    {"title": "Domain", "column_name": "domain", "uidt": "SingleLineText", "pv": true},
    {"title": "Company Name", "column_name": "company_name", "uidt": "SingleLineText"},
    {"title": "Status", "column_name": "status", "uidt": "SingleSelect",
     "dtxp": "'suggested','rejected','approved'",
     "colOptions": {"options": [
       {"title": "suggested"}, {"title": "rejected"}, {"title": "approved"}]}},
    {"title": "Reject Reason", "column_name": "reject_reason", "uidt": "LongText"},
    {"title": "Vertical", "column_name": "vertical", "uidt": "SingleLineText"},
    {"title": "Suggested At", "column_name": "suggested_at", "uidt": "Date"},
    {"title": "Decided At", "column_name": "decided_at", "uidt": "Date"},
    {"title": "Evidence", "column_name": "evidence", "uidt": "LongText"},
    {"title": "Batch Source", "column_name": "batch_source", "uidt": "SingleLineText"}
  ]
}
JSON
)

if ! created=$(run_nocodb tables.create "$BASE_ID" "$body" 2>&1); then
  echo "ERROR: tables.create failed: $created" >&2
  exit 2
fi
new_id=$(jq -r '.id // empty' <<<"$created")
if [[ -z "$new_id" ]]; then
  echo "ERROR: unexpected tables.create response (no .id): $created" >&2
  exit 2
fi
echo "Created \"$TABLE_TITLE\" in base $BASE_ID." >&2
echo "LEDGER_TABLE_ID=$new_id"
