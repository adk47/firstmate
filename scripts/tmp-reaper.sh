#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# tmp-reaper.sh — hourly reaper for the known /tmp scratch patterns.
#
# systemd-tmpfiles (scripts/aux-units/tmp.conf) ages /tmp by mtime but has NO
# open-handle check, and its 24h floor is too slow: on node-8 only 32 of 6,055
# entries were older than a day while / went 85% -> 93% in 26h. This reaper
# deletes the scratch that CI/QA tooling leaves behind within hours, and only
# when nothing holds a file open under it.
#
# Strictly allow-listed (anything else is left to the tmpfiles catch-all):
#   dir   ^[a-z0-9-]+-[0-9]+(-review)?-[A-Za-z0-9]{6}$   idle > 3h
#   entry pr-review-*.json | qa-pr-* | qa-alerts.*       idle > 3h
#   entry tmp.[A-Za-z0-9]{6}                             idle > 24h
# "idle" = top-level mtime. Symlinks are never followed or removed.
# jest_0 is jest's live, perpetually-reused cache: never touched.
#
# Logs path + reclaimed KiB per deletion; never file contents.
#
# Env:
#   TMP_REAPER_ROOT     default /tmp
#   TMP_REAPER_DIR_RE   test hook only (the unit never sets it)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="${TMP_REAPER_ROOT:-/tmp}"
DEFAULT_DIR_RE='^[a-z0-9-]+-[0-9]+(-review)?-[A-Za-z0-9]{6}$'
DIR_RE="${TMP_REAPER_DIR_RE:-$DEFAULT_DIR_RE}"
SHORT_MIN=180
LONG_MIN=1440

if ! command -v lsof >/dev/null 2>&1; then
  echo "tmp-reaper.sh: lsof missing; refusing to delete without an open-handle check" >&2
  exit 6
fi

# lsof -t prints PIDs holding anything open under the path; empty = idle.
# Returns 0 busy, 1 idle, 2 lsof failed. rc 1 + empty stderr is lsof's "no
# matches"; anything else (stderr text, rc>1) fails closed.
has_open_handles() {
  local out err rc=0 errf
  errf=$(mktemp) || return 2
  if [ -d "$1" ]; then
    out=$(lsof -t +D "$1" 2>"$errf") || rc=$?
  else
    out=$(lsof -t -- "$1" 2>"$errf") || rc=$?  # +D only accepts directories
  fi
  err=$(cat "$errf"); rm -f "$errf"
  [ -n "$out" ] && return 0
  if [ -n "$err" ] || [ "$rc" -gt 1 ]; then return 2; fi
  return 1
}

reaped=0
total_kib=0
skipped_busy=0
failures=0

reap() {
  local path="$1" kib
  local rc=0
  has_open_handles "$path" || rc=$?
  if [ "$rc" -eq 0 ]; then
    skipped_busy=$((skipped_busy + 1))
    echo "tmp-reaper: skip (open handles) $path"
    return 0
  elif [ "$rc" -eq 2 ]; then
    failures=$((failures + 1))
    echo "tmp-reaper: WARN lsof failed, keeping $path" >&2
    return 0
  fi
  kib=$(du -sk "$path" 2>/dev/null | cut -f1 || true)
  if rm -rf -- "$path"; then
    reaped=$((reaped + 1))
    total_kib=$((total_kib + ${kib:-0}))
    echo "tmp-reaper: deleted $path (${kib:-0} KiB)"
  else
    failures=$((failures + 1))
    echo "tmp-reaper: WARN could not delete $path" >&2
  fi
}

while IFS= read -r -d '' path; do
  name="${path##*/}"
  [ "$name" = "jest_0" ] && continue
  if [ -d "$path" ] && [[ "$name" =~ $DIR_RE ]]; then
    reap "$path"
  fi
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -mmin +"$SHORT_MIN" -print0)

while IFS= read -r -d '' path; do
  name="${path##*/}"
  case "$name" in
    pr-review-*.json|qa-pr-*|qa-alerts.*) reap "$path" ;;
  esac
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -mmin +"$SHORT_MIN" -print0)

while IFS= read -r -d '' path; do
  name="${path##*/}"
  [[ "$name" =~ ^tmp\.[A-Za-z0-9]{6}$ ]] && reap "$path"
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -mmin +"$LONG_MIN" -print0)

echo "tmp-reaper: done reaped=$reaped skipped_busy=$skipped_busy reclaimed_kib=$total_kib failures=$failures"
[ "$failures" -eq 0 ]
