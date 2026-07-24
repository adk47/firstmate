#!/usr/bin/env bash
# refresh-dedupe-cache.sh — snapshot the three dedup sources (Company
# Intelligence + Contacts Intelligence + Seen Ledger) and write the normalized-
# source EXISTING set to the dedupe cache atomically, so dedupe-candidates.sh
# (prep-batch) reads it in <1s instead of a ~50s live 3-table fetch.
#
# WHY THIS EXISTS
#   Scout is a codex code-mode agent whose exec cell yields at ~10s by default.
#   The live dedup snapshot legitimately takes ~50s (three NocoDB tables, paced
#   under the 5 req/s/user limit), so prep-batch never returned in the foreground
#   and Scout's company batches came back PARTIAL/UNSAFE (2026-07-22 McLaren
#   incident). Precomputing the snapshot out-of-band makes prep-batch fast enough
#   to finish inside one cell.
#
#   Correctness is unchanged: the AUTHORITATIVE dedup check stays LIVE in
#   ledger.sh suggest (finalize-batch), which re-checks all three sources before
#   any post. So a stale cache can NEVER post a duplicate — the worst case is a
#   LEDGER_COLLISION re-run.
#
# SCHEDULE: run by hydra-company-finder-cache-refresh.timer every 15 min (see
#   scripts/install-aux-units.sh). The cache TTL (DEDUPE_CACHE_TTL_SECONDS,
#   default 30 min) is > the refresh interval, so a single missed refresh does
#   not force dedupe onto the slow live path.
#
# FAIL-CLOSED: if ANY required source is unavailable, exit non-zero and DO NOT
#   overwrite the existing cache (a stale-but-complete cache beats a partial one;
#   dedupe's TTL falls back to a live snapshot if the refresher stays broken).
#
# Exit codes: 0 success, 2 dedup source unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

locate_nocodb_api
resolve_ledger_table_id "DEDUP_SOURCE_UNAVAILABLE"

# One full snapshot (the same builder dedupe uses for its live fallback, so the
# cached EXISTING is byte-identical to what a live run would produce).
rc=0; EXISTING="$(build_existing_snapshot)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "refresh-dedupe-cache: source unavailable (rc=$rc) — keeping the existing cache, not overwriting." >&2
  exit "$rc"
fi

now="$(date +%s)"
mkdir -p "$(dirname "$DEDUPE_CACHE_FILE")"
tmp="$(mktemp "${DEDUPE_CACHE_FILE}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# EXISTING (the full 3-table snapshot, ~300KB) goes on STDIN, never --argjson: a
# single argv string is capped at MAX_ARG_STRLEN (128KB) and overflows once the
# tables pass ~2k rows ("jq: Argument list too long"), the same trap
# dedupe-candidates.sh documents. $now is a bounded scalar, so it stays on argv.
printf '%s' "$EXISTING" | jq --argjson t "$now" \
  '{generated_at_epoch: $t, count: length, existing: .}' > "$tmp"
mv -f "$tmp" "$DEDUPE_CACHE_FILE"
trap - EXIT
echo "refresh-dedupe-cache: wrote $(jq -r '.count' "$DEDUPE_CACHE_FILE") rows -> $DEDUPE_CACHE_FILE" >&2
