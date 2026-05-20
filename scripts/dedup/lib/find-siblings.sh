#!/usr/bin/env bash
# Given a profile ID + its canonical JSON on stdin, emit a deduplicated
# list of OTHER profile IDs in the catalog that share at least one raw_id
# or IPI with the input profile.
set -euo pipefail

self_id="${1:?usage: find-siblings.sh <profile_uuid> < canonical.json}"
trino="${TRINO_QUERY:-/opt/hydra/scripts/trino-query.sh}"

profile=$(cat)
raw_ids=$(echo "$profile" | jq -r '.raw_ids[]?' | sort -u)
ipis=$(echo "$profile" | jq -r '.ipis[]?' | sort -u)

emit_for_raw() {
  local rid="$1"
  local esc="${rid//\'/\'\'}"
  local err out
  err=$(mktemp)
  if ! out=$("$trino" "SELECT _id FROM \"platform-industry-bi-prod\".matvw_catalog_profile WHERE contains(raw_profile_ids, '$esc') AND _id <> '$self_id' AND is_deleted = false" 2>"$err"); then
    echo "find-siblings: trino failed on raw_id='$rid': $(head -2 "$err")" >&2
    rm -f "$err"
    return 4
  fi
  rm -f "$err"
  echo "$out" | tr -d '"' | grep -v '^$' || true
}

emit_for_ipi() {
  local ipi="$1"
  # IPI is BIGINT in matvw; refuse non-digits to keep the SQL string-safe.
  # Soft skip (return 0): a bad IPI is a data-quality issue, not a Trino
  # transport failure. Reserve exit 4 for actual Trino failures so the
  # "results may be incomplete" warning only fires when we genuinely could
  # not ask the catalog.
  if ! [[ "$ipi" =~ ^[0-9]+$ ]]; then
    echo "find-siblings: skipping non-numeric ipi '$ipi'" >&2
    return 0
  fi
  local err out
  err=$(mktemp)
  if ! out=$("$trino" "SELECT _id FROM \"platform-industry-bi-prod\".matvw_catalog_profile WHERE contains(ipis, BIGINT '$ipi') AND _id <> '$self_id' AND is_deleted = false" 2>"$err"); then
    echo "find-siblings: trino failed on ipi='$ipi': $(head -2 "$err")" >&2
    rm -f "$err"
    return 4
  fi
  rm -f "$err"
  echo "$out" | tr -d '"' | grep -v '^$' || true
}

# Drive each lookup; if any subcall returns 4 (trino failure), propagate
# exit 4 so the caller can distinguish "no siblings" from "couldn't ask".
# The pipeline below puts the brace-group in a subshell, so a counter
# variable assigned inside would NOT survive. We use a tempfile sentinel
# so the parent shell can detect partial-failure after the pipeline drains.
err_marker=$(mktemp) || { echo "find-siblings: mktemp failed; aborting" >&2; exit 4; }
trap 'rm -f "$err_marker"' EXIT
{
  while IFS= read -r rid; do
    [ -z "$rid" ] && continue
    emit_for_raw "$rid" || echo x >> "$err_marker"
  done <<< "$raw_ids"
  while IFS= read -r ipi; do
    [ -z "$ipi" ] && continue
    emit_for_ipi "$ipi" || echo x >> "$err_marker"
  done <<< "$ipis"
  :
} | sort -u || true   # belt-and-suspenders against future pipefail interactions

if [ -s "$err_marker" ]; then
  errs=$(wc -l < "$err_marker" | tr -d ' ')
  echo "find-siblings: $errs trino lookups failed for $self_id; result is partial" >&2
  exit 4
fi
