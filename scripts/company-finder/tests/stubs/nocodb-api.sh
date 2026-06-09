#!/usr/bin/env bash
# Hermetic stub of skills-all/muso-nocodb/scripts/nocodb-api.sh for dedup tests.
# Honors records.ls --offset (page 2 is always empty) and returns the company /
# contacts fixtures by table id. Set NOCODB_STUB_FAIL=<tableId> to simulate an
# unreachable source (exits non-zero) so the retry/exit path can be exercised.
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
offset=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offset) offset="${2:-0}"; shift 2 ;;
    *) shift ;;
  esac
done

[[ "$cmd" == "records.ls" ]] || { echo '{}'; exit 0; }

if [[ -n "${NOCODB_STUB_FAIL:-}" && "$tid" == "$NOCODB_STUB_FAIL" ]]; then
  echo "stub: simulated failure for $tid" >&2
  exit 3
fi

# Single-page fixtures: any offset > 0 is the empty tail page.
if [[ "$offset" -gt 0 ]]; then
  echo '{"list":[],"pageInfo":{"isLastPage":true}}'
  exit 0
fi

case "$tid" in
  "${COMPANY_TABLE_ID:-mvr6nmzcv7albxt}")  cat "$NOCODB_STUB_FIXTURES/company.json" ;;
  "${CONTACTS_TABLE_ID:-m9vsbijhrr9ddeu}") cat "$NOCODB_STUB_FIXTURES/contacts.json" ;;
  *) echo '{"list":[],"pageInfo":{"isLastPage":true}}' ;;
esac
