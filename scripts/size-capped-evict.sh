#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# size-capped-evict.sh — evict the OLDEST CHILDREN of a live cache container
# until the container is under a size cap. clean-my-linux rule for jest_0 under tmp.
#
# Deliberate, CTO-approved (MUS-6055) departure from tmp-reaper.sh, whose header
# says "jest_0 ... never touched". Both are right: tmp-reaper rightly refuses to
# delete the jest_0 DIRECTORY (live, perpetually reused, top-level mtime always
# fresh, so no age rule can reach it). This rule never deletes the directory
# either; it evicts old children, oldest mtime first, down to a byte cap. The
# worst case is a jest cache miss. Do not "fix" the apparent contradiction.
#
# Every child goes through safe_delete_path (lib/safe-delete.sh): open-handle
# check, identity recheck, quarantine-first rm. A held child is skipped.
#
# Dry-run unless SIZE_CAP_APPLY=1. Logs paths and KiB, never file contents.
#
# Env:
#   SIZE_CAP_ROOT         container, default jest_0 under tmp
#   SIZE_CAP_KIB          cap in KiB, default 5242880 (5 GiB)
#   SIZE_CAP_MIN_AGE_MIN  children newer than this are never evicted, default 60
#   SIZE_CAP_APPLY        1 = delete, anything else = dry-run
# Exit: 0 ok, 1 an eviction failed, 2 refused container.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="${SIZE_CAP_ROOT:-/tmp/jest_0}"  # tmp-ok: the cache being capped
CAP_KIB="${SIZE_CAP_KIB:-5242880}"
MIN_AGE_MIN="${SIZE_CAP_MIN_AGE_MIN:-60}"
APPLY="${SIZE_CAP_APPLY:-0}"

# shellcheck source=lib/safe-delete.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/safe-delete.sh"

ROOT="${ROOT%/}"
case "$ROOT" in
  ""|/tmp|/var/tmp|/root|/home|/opt|/var) echo "size-capped: refusing container '$ROOT'" >&2; exit 2 ;;
esac
if [ -L "$ROOT" ]; then echo "size-capped: refusing symlinked container '$ROOT'" >&2; exit 2; fi
if [ ! -d "$ROOT" ]; then echo "size-capped: no container at $ROOT, nothing to do"; exit 0; fi

dry=1; [ "$APPLY" = 1 ] && dry=0
mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1"; }

total_kib="$(du -skx -- "$ROOT" | awk '{print $1}')"
evicted=0; freed_kib=0; skipped_open=0; failures=0
now="$(date +%s)"

# Oldest first. Only direct children, never symlinks followed, never the root.
while IFS= read -r path; do
  [ "$total_kib" -le "$CAP_KIB" ] && break
  age_min=$(( (now - $(mtime "$path")) / 60 ))
  [ "$age_min" -lt "$MIN_AGE_MIN" ] && continue
  kib="$(du -skx -- "$path" 2>/dev/null | awk '{print $1}')"; kib="${kib:-0}"
  if [ "$dry" -eq 1 ]; then
    echo "size-capped: would evict $path (${kib} KiB)"
    evicted=$((evicted + 1)); freed_kib=$((freed_kib + kib)); total_kib=$((total_kib - kib))
  elif safe_delete_has_open_handle "$path"; then
    skipped_open=$((skipped_open + 1))
    echo "size-capped: skip (open handle) $path"
  elif got="$(safe_delete_path "$path")"; then
    evicted=$((evicted + 1)); freed_kib=$((freed_kib + ${got:-0})); total_kib=$((total_kib - ${got:-0}))
    echo "size-capped: evicted $path (${got:-0} KiB)"
  else
    failures=$((failures + 1))
    echo "size-capped: WARN could not evict $path" >&2
  fi
done < <(
  find "$ROOT" -mindepth 1 -maxdepth 1 -print0 \
    | while IFS= read -r -d '' p; do printf '%s %s\n' "$(mtime "$p")" "$p"; done \
    | sort -n | cut -d' ' -f2-
)

echo "size-capped: done root=$ROOT cap_kib=$CAP_KIB remaining_kib=$total_kib evicted=$evicted freed_kib=$freed_kib skipped_open=$skipped_open dry_run=$dry failures=$failures"
[ "$failures" -eq 0 ]
