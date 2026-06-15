#!/usr/bin/env bash
# check-argv-safety.sh — fail if any NocoDB *table snapshot* reaches jq through
# argv (--argjson/--arg) in the company-finder scripts.
#
# WHY THIS EXISTS
#   The ledger/dedupe prechecks compare candidates against FULL table snapshots
#   (Seen Ledger + Company Intelligence + Contacts Intelligence). A single argv
#   string is capped at MAX_ARG_STRLEN (128KB); once a table grows past that,
#   `jq --argjson x "$SNAPSHOT"` dies "jq: Argument list too long" (exit 126)
#   and every write fails closed. That took the daily company-finder cron down
#   on 2026-06-13 (ledger.sh), right after the same class hit dedupe-candidates.sh
#   (#516). Snapshots MUST go off argv via `--slurpfile <(printf '%s' "$VAR")`.
#
# SELF-MAINTAINING
#   The snapshot-variable set is derived from fetch_mapped / fetch_table
#   assignments, so a newly-named snapshot var is covered with no edit here.
#   Bounded candidate batches (NORMED, CANDS, ids) are intentionally NOT flagged
#   — only variables fed by a full-table fetch, which are the unbounded ones.
#
# Exit 0 = clean, 1 = a snapshot is on argv (with file:line), 2 = usage.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="$(basename "${BASH_SOURCE[0]}")"
fail=0

shopt -s nullglob
for f in "$DIR"/*.sh; do
  [ "$(basename "$f")" = "$self" ] && continue
  # Variables assigned from a full-table snapshot fetch (fetch_mapped/fetch_table).
  # while-read (not mapfile) so this runs on bash 3.2 (macOS) as well as node-8.
  # `|| true`: grep exits 1 when a file has no snapshot fetch, which would
  # otherwise trip set -e/pipefail and abort the whole lint.
  snap_vars="$(
    grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*(fetch_mapped|fetch_table)' "$f" 2>/dev/null \
      | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | sort -u || true
  )"
  [ -z "$snap_vars" ] && continue
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    # Match `--argjson NAME "$v"` / `--arg NAME "${v}"` — snapshot fed to argv.
    pat='--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"\$\{?'"$v"'\}?"'
    hits="$(grep -nE -- "$pat" "$f" || true)"
    if [ -n "$hits" ]; then
      printf 'ERROR: %s passes table snapshot $%s to jq via --argjson/--arg.\n' \
        "$(basename "$f")" "$v" >&2
      printf '       argv is capped at 128KB (MAX_ARG_STRLEN) -> "jq: Argument list too long".\n' >&2
      printf '       Use: --slurpfile <(printf '"'"'%%s'"'"' "$%s") and dereference $name[0].\n' "$v" >&2
      printf '%s\n' "$hits" | sed 's/^/         /' >&2
      fail=1
    fi
  done <<< "$snap_vars"
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "✓ company-finder: no NocoDB table snapshot reaches jq through argv"
