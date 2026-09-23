#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# jev-shadow-prune.sh — drops Jev shadow rows older than
# JEV_SHADOW_RETENTION_DAYS (default 30) from every
# ${JEV_SHADOW_DIR:-/var/lib/hydra-jev/shadow}/*.jsonl.
#
# Every shadow row now carries the raw `state` object next to
# state_sha256 (scripts/lib/jev.sh, jev-shadow-log.ts, format-digest.sh) so a
# misclassification can be replayed against Jev directly -- but that means
# the shadow log is customer text accumulating unbounded on disk unless
# something ages it out. This script is that something.
#
# Every writer to $JEV_SHADOW_DIR/*.jsonl -- scripts/lib/jev.sh's
# _jev_shadow_log, format-digest.sh's _jev_email_triage_classify_shadow, and
# the in-process Caroline writer plugins/intercom/src/jev-shadow-log.ts (via
# the `flock` binary) -- now appends under the SAME per-file "<file>.lock"
# flock before touching the file at all. That means the whole
# read-filter-write-mv rewrite below can happen under ONE exclusive hold of
# that same lock, with no writer able to append mid-rewrite or interleave
# with the mv. There is no more window for a lock-free append to race the
# read, the rewrite, or the rename -- that class of race is closed
# structurally by the shared lock, so the snapshot-cut / tail-catch-up /
# old-inode post-mv-recovery machinery that used to paper over the edges of
# that window is gone, not patched further (Rule 3: dead complexity once the
# thing it worked around no longer exists).
#
# Each file is rewritten atomically (write a sibling tmpfile, then `mv` it
# into place on the same filesystem) while holding the lock for the entire
# operation. Lock contention is fail-soft: a file whose lock cannot be
# acquired within the wait is skipped (WARN on stderr, counted, tried again
# next run) rather than blocking or corrupting it.
#
# A row this script cannot parse (malformed JSON, missing/unparseable .ts)
# is KEPT and counted as malformed -- pruning must never silently destroy
# a row it doesn't understand.
#
# Usage:
#   jev-shadow-prune.sh
#
# Env:
#   JEV_SHADOW_DIR              default /var/lib/hydra-jev/shadow
#   JEV_SHADOW_RETENTION_DAYS   default 30; must be a positive integer
#
# Exit codes:
#   0  ok (including "nothing to prune" and lock-contention skips)
#   5  invalid JEV_SHADOW_RETENTION_DAYS
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/epoch.sh
source "$SCRIPT_DIR/lib/epoch.sh"

: "${JEV_SHADOW_DIR:=/var/lib/hydra-jev/shadow}"
: "${JEV_SHADOW_RETENTION_DAYS:=30}"

case "$JEV_SHADOW_RETENTION_DAYS" in
  ''|*[!0-9]*|0)
    echo "jev-shadow-prune.sh: JEV_SHADOW_RETENTION_DAYS must be a positive integer (got: $JEV_SHADOW_RETENTION_DAYS)" >&2
    exit 5
    ;;
esac

# Read as decimal: Bash arithmetic treats a leading zero as octal, so "08"
# would abort the daily job and "010" would mean 8 days. An all-zero value
# ("00") is 0 days and is refused like "0", or it would prune every row.
JEV_SHADOW_RETENTION_DAYS=$((10#$JEV_SHADOW_RETENTION_DAYS))
if [ "$JEV_SHADOW_RETENTION_DAYS" -eq 0 ]; then
  echo "jev-shadow-prune.sh: JEV_SHADOW_RETENTION_DAYS must be a positive integer (got a zero value)" >&2
  exit 5
fi

command -v jq >/dev/null 2>&1 || { echo "jev-shadow-prune.sh: jq is required" >&2; exit 5; }

now_epoch="$(date -u +%s)"
cutoff_epoch=$(( now_epoch - JEV_SHADOW_RETENTION_DAYS * 86400 ))

if [ ! -d "$JEV_SHADOW_DIR" ]; then
  echo "jev-shadow-prune.sh: shadow dir does not exist: $JEV_SHADOW_DIR -- nothing to prune"
  exit 0
fi

shopt -s nullglob
files=("$JEV_SHADOW_DIR"/*.jsonl)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "jev-shadow-prune.sh: no shadow files under $JEV_SHADOW_DIR -- nothing to prune"
  exit 0
fi

total_kept=0
total_dropped=0
total_malformed=0
total_locked=0

for f in "${files[@]}"; do
  surface="$(basename "$f" .jsonl)"
  lock_file="${f}.lock"

  exec 9>>"$lock_file"
  if ! flock -w 5 9; then
    echo "jev-shadow-prune.sh: WARN could not lock $f within 5s -- skipping this run" >&2
    total_locked=$((total_locked + 1))
    exec 9>&-
    continue
  fi

  tmp_file="$(mktemp "${f}.XXXXXX")" || {
    echo "jev-shadow-prune.sh: WARN could not create tmpfile for $f -- skipping" >&2
    exec 9>&-
    continue
  }
  chmod 0600 "$tmp_file" 2>/dev/null || true

  kept=0
  dropped=0
  malformed=0

  # Every writer takes this same lock before appending, so the file is
  # quiescent for the whole read below -- no snapshot, no catch-up needed.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    ts="$(printf '%s' "$line" | jq -r 'if type == "object" then (.ts // empty) else empty end' 2>/dev/null || true)"
    row_epoch=""
    if [ -n "$ts" ]; then
      row_epoch="$(iso_to_epoch "$ts" 2>/dev/null || true)"
    fi
    if [ -z "$row_epoch" ]; then
      # Unparseable row (bad JSON, missing/unparseable .ts): keep it, count
      # it, never drop what we can't understand.
      printf '%s\n' "$line" >> "$tmp_file"
      malformed=$((malformed + 1))
      kept=$((kept + 1))
      continue
    fi
    if [ "$row_epoch" -lt "$cutoff_epoch" ]; then
      dropped=$((dropped + 1))
    else
      printf '%s\n' "$line" >> "$tmp_file"
      kept=$((kept + 1))
    fi
  done < "$f"

  mv -f "$tmp_file" "$f"
  exec 9>&-

  total_kept=$((total_kept + kept))
  total_dropped=$((total_dropped + dropped))
  total_malformed=$((total_malformed + malformed))

  echo "jev-shadow-prune.sh: $surface.jsonl kept=$kept dropped=$dropped malformed=$malformed"
done

echo "jev-shadow-prune.sh: done. retention_days=$JEV_SHADOW_RETENTION_DAYS total_kept=$total_kept total_dropped=$total_dropped total_malformed=$total_malformed files_locked_skipped=$total_locked"
