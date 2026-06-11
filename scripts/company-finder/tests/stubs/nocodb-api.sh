#!/usr/bin/env bash
# Hermetic stub of skills-all/muso-nocodb/scripts/nocodb-api.sh for
# company-finder tests. Honors records.ls --offset (page 2 is always empty)
# and returns the per-table fixtures by table id. Set
# NOCODB_STUB_FAIL=<tableId> to simulate an unreachable source (exits
# non-zero) so the retry/exit path can be exercised.
#
# Write commands (records.create / records.update) append
#   "<cmd> <tableId> <jsonBody>"
# to $NOCODB_STUB_LOG (if set) and reply with synthetic ids, so tests can
# assert exactly what would have been written — and that NOTHING was written
# on the atomic-failure paths.
set -euo pipefail

# Drop global wrapper flags, keep subcommand + positionals.
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw|--dry-run) shift ;;
    --base) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

cmd="${1:-}"; shift || true
tid="${1:-}"; shift || true

if [[ -n "${NOCODB_STUB_FAIL:-}" && "$tid" == "$NOCODB_STUB_FAIL" ]]; then
  echo "stub: simulated failure for $tid" >&2
  exit 3
fi

case "$cmd" in
  records.ls)
    offset=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --offset) offset="${2:-0}"; shift 2 ;;
        *) shift ;;
      esac
    done
    # Single-page fixtures: any offset > 0 is the empty tail page.
    if [[ "$offset" -gt 0 ]]; then
      echo '{"list":[],"pageInfo":{"isLastPage":true}}'
      exit 0
    fi
    case "$tid" in
      "${COMPANY_TABLE_ID:-mvr6nmzcv7albxt}")  cat "$NOCODB_STUB_FIXTURES/company.json" ;;
      "${CONTACTS_TABLE_ID:-m9vsbijhrr9ddeu}") cat "$NOCODB_STUB_FIXTURES/contacts.json" ;;
      "${LEDGER_TABLE_ID:-}")                  cat "$NOCODB_STUB_FIXTURES/ledger.json" ;;
      *)
        # Generic by-id fixture (e.g. the migration tests' dirty table).
        if [[ -f "$NOCODB_STUB_FIXTURES/$tid.json" ]]; then
          cat "$NOCODB_STUB_FIXTURES/$tid.json"
        else
          echo '{"list":[],"pageInfo":{"isLastPage":true}}'
        fi
        ;;
    esac
    ;;
  records.create)
    body="${1:?jsonBody}"
    [[ -n "${NOCODB_STUB_LOG:-}" ]] && printf 'records.create %s %s\n' "$tid" "$body" >>"$NOCODB_STUB_LOG"
    jq -c 'if type == "array" then to_entries | map({Id: (101 + .key)}) else {Id: 101} end' <<<"$body"
    ;;
  records.update)
    body="${1:?jsonArray}"
    [[ -n "${NOCODB_STUB_LOG:-}" ]] && printf 'records.update %s %s\n' "$tid" "$body" >>"$NOCODB_STUB_LOG"
    jq -c 'map({Id: .Id})' <<<"$body"
    ;;
  tables.ls)
    # $tid is the baseId here. Serve fixtures/tables.json when present so the
    # title-based LEDGER_TABLE_ID auto-discovery can be exercised.
    if [[ -f "$NOCODB_STUB_FIXTURES/tables.json" ]]; then
      cat "$NOCODB_STUB_FIXTURES/tables.json"
    else
      echo '{"list":[]}'
    fi
    ;;
  *) echo '{}' ;;
esac
