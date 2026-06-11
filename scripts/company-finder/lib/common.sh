#!/usr/bin/env bash
# common.sh — shared plumbing for the company-finder scripts. SOURCED, never
# executed. Single source of truth for table ids, the nocodb-api.sh locator,
# and the paginate-with-one-retry table snapshot (the same single-source
# rationale as lib/normalize.jq: read-side/write-side drift between copies is
# the failure class this directory exists to kill).
#
# Callers must set -euo pipefail themselves and define SCRIPT_DIR before
# sourcing (every script in this directory already does).

COMPANY_TABLE_ID="${COMPANY_TABLE_ID:-mvr6nmzcv7albxt}"
CONTACTS_TABLE_ID="${CONTACTS_TABLE_ID:-m9vsbijhrr9ddeu}"
NOCODB_BASE_ID="${NOCODB_BASE_ID:-p11hvpwapu4hv0x}"
# LEDGER_TABLE_ID is auto-discovered by title at runtime (see
# resolve_ledger_table_id) — set the env var only to skip the lookup
# (tests do) or to override the discovered table.
LEDGER_TABLE_TITLE="Company Seen Ledger"
PAGE_LIMIT="${PAGE_LIMIT:-1000}"

CF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# locate_nocodb_api — resolve NOCODB_API_SH (env override wins) or fail.
locate_nocodb_api() {
  if [[ -z "${NOCODB_API_SH:-}" ]]; then
    local cand
    for cand in \
      "$CF_LIB_DIR/../../../skills-all/muso-nocodb/scripts/nocodb-api.sh" \
      "/opt/hydra/skills-all/muso-nocodb/scripts/nocodb-api.sh"; do
      if [[ -f "$cand" ]]; then NOCODB_API_SH="$cand"; break; fi
    done
  fi
  if [[ -z "${NOCODB_API_SH:-}" || ! -f "$NOCODB_API_SH" ]]; then
    echo "ERROR: could not locate nocodb-api.sh (set NOCODB_API_SH)." >&2
    return 1
  fi
}

run_nocodb() { bash "$NOCODB_API_SH" --raw "$@"; }

# jqn — jq with the shared lib dir on the include path, so call sites don't
# each re-derive it from their own SCRIPT_DIR. Use with: include "normalize";
jqn() { jq -L "$CF_LIB_DIR" "$@"; }

# resolve_ledger_table_id <marker> — use $LEDGER_TABLE_ID if set, otherwise
# discover the Company Seen Ledger by title in the base. Auto-discovery means
# the one-time setup-ledger-table.sh run is the ONLY operator step — no pin
# commit, no redeploy. Until the table exists, callers fail closed with the
# caller's required-source marker (DEDUP_SOURCE_UNAVAILABLE /
# LEDGER_SOURCE_UNAVAILABLE) and exit 2 — the same instructed bucket the
# cron doctrine already handles (NO_REPLY / PARTIAL-UNSAFE).
# Requires locate_nocodb_api to have run first.
resolve_ledger_table_id() {
  local marker="${1:?resolve_ledger_table_id needs a marker}"
  [[ -n "${LEDGER_TABLE_ID:-}" ]] && return 0
  local resp
  if ! resp=$(run_nocodb tables.ls "$NOCODB_BASE_ID" 2>/dev/null); then
    if ! resp=$(run_nocodb tables.ls "$NOCODB_BASE_ID" 2>/dev/null); then
      echo "$marker: Seen Ledger (could not list tables in base $NOCODB_BASE_ID to resolve LEDGER_TABLE_ID)" >&2
      return 2
    fi
  fi
  LEDGER_TABLE_ID=$(jq -r --arg t "$LEDGER_TABLE_TITLE" \
    '.list[]? | select(.title == $t) | .id' <<<"$resp" 2>/dev/null | head -1)
  if [[ -z "$LEDGER_TABLE_ID" ]]; then
    echo "$marker: Seen Ledger (\"$LEDGER_TABLE_TITLE\" not found in base $NOCODB_BASE_ID — run setup-ledger-table.sh once, or set LEDGER_TABLE_ID)" >&2
    return 2
  fi
  export LEDGER_TABLE_ID
}

# fetch_table <tableId> <label> <fields> <marker> — paginate the table,
# retry each page once, emit a JSON array of RAW rows (callers do their own
# mapping). On a source still unavailable after the retry, prints
# "<marker>: <label> (<tid>)" to stderr and returns 2.
fetch_table() {
  local tid="$1" label="$2" fields="$3" marker="$4"
  local offset=0 combined="[]" resp chunk islast
  while :; do
    if ! resp=$(run_nocodb records.ls "$tid" --fields "$fields" \
                  --limit "$PAGE_LIMIT" --offset "$offset" 2>/dev/null); then
      if ! resp=$(run_nocodb records.ls "$tid" --fields "$fields" \
                    --limit "$PAGE_LIMIT" --offset "$offset" 2>/dev/null); then
        echo "$marker: $label ($tid)" >&2
        return 2
      fi
    fi
    if ! chunk=$(jq -ce '.list // empty' <<<"$resp" 2>/dev/null); then
      echo "$marker: $label ($tid) — unexpected response shape" >&2
      return 2
    fi
    combined=$(jq -cs 'add' <<<"$combined"$'\n'"$chunk")
    # Strictly boolean termination: a short page ALWAYS terminates, even if a
    # NocoDB version/proxy serializes isLastPage as a string or 0/1 — a
    # non-boolean truthy value must never leave us paginating forever.
    islast=$(jq -r --argjson lim "$PAGE_LIMIT" \
      '((.pageInfo.isLastPage == true) or ((.list | length) < $lim))' <<<"$resp")
    [[ "$islast" == "true" ]] && break
    offset=$((offset + PAGE_LIMIT))
  done
  printf '%s\n' "$combined"
}

# read_candidates_stdin — read stdin, default to [], reject non-arrays.
read_candidates_stdin() {
  local cands
  cands="$(cat)"
  [[ -z "${cands//[[:space:]]/}" ]] && cands="[]"
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$cands"; then
    echo "ERROR: stdin must be a JSON array of {name,domain,...} candidates." >&2
    return 1
  fi
  printf '%s\n' "$cands"
}
