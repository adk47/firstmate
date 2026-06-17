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
# NocoDB Cloud clamps --limit to 100 regardless of what we request, so ask
# for what we'll actually get. fetch_table no longer trusts this value for
# termination either way (see the isLastPage/empty-page loop).
PAGE_LIMIT="${PAGE_LIMIT:-100}"
# Seconds slept between page fetches so a single sequential reader stays under
# NocoDB Cloud's 5 req/s/user limit. The wrapper (nocodb-api.sh) backs off on a
# 429; this keeps us from tripping it in the first place. Tests set 0.
# ~22 pages * 0.25s ≈ 5.5s added per full Company Intelligence snapshot.
NOCODB_PAGE_SLEEP="${NOCODB_PAGE_SLEEP:-0.25}"

# USE_MUSO_CLI — dark-launch cutover from the nc_pat_-token nocodb-api.sh
# wrapper to the gated, audited `muso nocodb` provider. Default OFF: the bash
# wrapper stays the path until the muso binary ships the nocodb command fleet-
# wide (it is merged on muso-cli main but unreleased) AND a live-parity check
# passes on node-8. When 1, every NocoDB write gains muso's --requester
# attribution + audit + prewrite gate; read SHAPES are unchanged because
# muso_nocodb peels muso's one-object {data:…} envelope back to the raw NocoDB
# body, so fetch_table/resolve_ledger_table_id and the write callers need no
# changes. Caller-side pagination (fetch_table) is preserved verbatim — muso's
# --limit/--offset map 1:1, so the NocoDB-Cloud ≤100 clamp is defeated the same
# way it is today (no dependency on a CLI --all flag).
USE_MUSO_CLI="${USE_MUSO_CLI:-0}"
MUSO_BIN="${MUSO_BIN:-muso}"
# Attribution for the cron's gated writes — passed explicitly per call. This is
# deliberately NOT the MUSO_REQUESTER env var: a static MUSO_REQUESTER is
# forbidden (it would freeze attribution); this names the deterministic cron's
# own identity for the audit trail.
CF_REQUESTER="${CF_REQUESTER:-company-finder@hydra-ops}"

CF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# locate_nocodb_api — resolve NOCODB_API_SH (env override wins) or fail. On the
# muso path the wrapper is never invoked, so locating it is unnecessary — skip
# (keeps the seam from depending on the wrapper file once it is retired).
locate_nocodb_api() {
  [[ "$USE_MUSO_CLI" == "1" ]] && return 0
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

run_nocodb() {
  if [[ "$USE_MUSO_CLI" == "1" ]]; then
    muso_nocodb "$@"
  else
    bash "$NOCODB_API_SH" --raw "$@"
  fi
}

# muso_nocodb — translate the nocodb-api.sh verb surface company-finder uses
# (records.ls/create/update, tables.ls/create) onto `muso nocodb …` and peel
# muso's {data:…} envelope so the emitted shape is byte-identical to the
# wrapper's --raw output. ONLY the verbs company-finder calls are mapped (KISS);
# an unmapped verb fails loud rather than silently mis-routing. Writes carry
# --requester for attribution; reads are ungated.
muso_nocodb() {
  local verb="$1"; shift
  local out
  case "$verb" in
    records.ls)
      local tid="$1"; shift
      out=$("$MUSO_BIN" nocodb records list --table "$tid" "$@" --json) || return $?
      ;;
    records.create)
      out=$("$MUSO_BIN" nocodb records create --table "$1" --data "$2" \
              --requester "$CF_REQUESTER" --json) || return $?
      ;;
    records.update)
      out=$("$MUSO_BIN" nocodb records update --table "$1" --data "$2" \
              --requester "$CF_REQUESTER" --json) || return $?
      ;;
    tables.ls)
      out=$("$MUSO_BIN" nocodb tables list --base "$1" --json) || return $?
      ;;
    tables.create)
      out=$("$MUSO_BIN" nocodb tables create --base "$1" --data "$2" \
              --requester "$CF_REQUESTER" --json) || return $?
      ;;
    *)
      echo "ERROR: muso_nocodb: unsupported verb '$verb' (company-finder maps only records.ls/create/update, tables.ls/create)" >&2
      return 1
      ;;
  esac
  # Peel the one-object {data:…} envelope back to the raw NocoDB body
  # (e.g. {list,pageInfo}) the wrapper's --raw returned. No -e: a successful
  # muso call returns 0; fetch_table's own `.list // empty` check fail-louds on
  # a degenerate body, matching the wrapper path.
  jq -c '.data' <<<"$out"
}

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
# mapping). Sleeps NOCODB_PAGE_SLEEP between pages to stay under NocoDB Cloud's
# 5 req/s/user limit. On a source still unavailable after the retry, prints
# "<marker>: <label> (<tid>)" to stderr and returns 2.
fetch_table() {
  local tid="$1" label="$2" fields="$3" marker="$4"
  local offset=0 pages="" resp chunk islast pagelen
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
    pages+="$chunk"$'\n'
    # Strictly boolean termination, clamp-proof: NocoDB Cloud silently caps
    # --limit at 100, so a page shorter than PAGE_LIMIT does NOT mean last
    # page (that assumption truncated dedupe snapshots to ~100 rows,
    # 2026-06-12). Only an explicit boolean isLastPage or an EMPTY page
    # terminates — even if a NocoDB version/proxy serializes isLastPage as a
    # string or 0/1, the empty page bounds the loop. Advance by what the
    # server actually returned, not by what we asked for.
    pagelen=$(jq -r 'length' <<<"$chunk")
    islast=$(jq -r '.pageInfo.isLastPage == true' <<<"$resp")
    [[ "$islast" == "true" || "$pagelen" -eq 0 ]] && break
    offset=$((offset + pagelen))
    sleep "$NOCODB_PAGE_SLEEP"   # pace under NocoDB Cloud's 5 req/s/user limit
  done
  jq -cs 'add // []' <<<"$pages"
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
