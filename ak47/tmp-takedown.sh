#!/usr/bin/env bash
# ak47/tmp-takedown.sh - the once-off big-entry take-down, done through the same
# gates the tick uses.
#
# The tick only acts on names the producer table enumerates, with a 24 h idle
# gate. That is right for routine hygiene and useless when /tmp has already
# grown to hundreds of GB: the biggest offenders are directories no producer row
# names, and they will never shrink on their own.
#
# This script exists for that state, and it is deliberately narrow:
#
#   - SIZE FIRST. It ranks /tmp's top-level entries by size and works from the
#     top, because the problem it addresses is gigabytes, not entry count.
#   - AGE, BUT NEVER AGE ALONE. An entry must be idle for MIN_AGE (default 6 h)
#     AND hold no open handle AND be outside every protected pattern AND not be
#     a live task's scratch root. Any one of those gates says no, and it says no.
#   - QUARANTINE, NEVER DELETE. Every entry is moved into a dated quarantine
#     directory inside the ak47 state dir, and its exact revert is printed. The
#     quarantine's own 7-day expiry does the eventual deleting.
#   - BOUNDED. It takes at most MAX entries (default 20) and stops when the
#     candidate set is exhausted, so a run is a decision, not a sweep.
#
# There is no fm-tmp-top helper on this box, so the ranking is here: `du` per
# direct child under a timeout, because a single recursive walk over the whole
# tree is what stopped finishing in the first place.
#
# Usage: tmp-takedown.sh [--apply|--dry-run] [--top N]
# Exit: 0 completed, 2 malformed producer table, 3 could not build a safe set.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
# shellcheck source=lib/common.sh
. "$AK47_ROOT/lib/common.sh"
# shellcheck source=lib/safe-delete.sh
. "$AK47_ROOT/lib/safe-delete.sh"

APPLY=0
TOP=${AK47_TAKEDOWN_TOP:-20}
MIN_AGE=${AK47_TAKEDOWN_MIN_AGE:-21600}   # seconds; 6 h
MAX=${AK47_TAKEDOWN_MAX:-20}
QUAR=$AK47_STATE/quarantine/$(date -u +%Y%m%d)-takedown

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --top) shift; TOP=${1:?--top needs a number} ;;
    --top=*) TOP=${1#*=} ;;
    *) echo "tmp-takedown: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

TMP_ROOT=${AK47_TMP_ROOT:-/tmp}
PROTECTED_EXACT=(
  "$TMP_ROOT/fm-move" "$TMP_ROOT/jest_0"
  "$TMP_ROOT/.X11-unix" "$TMP_ROOT/.ICE-unix" "$TMP_ROOT/.font-unix"
  "$TMP_ROOT/.Test-unix" "$TMP_ROOT/.XIM-unix"
)
PROTECTED_GLOB=(
  "$TMP_ROOT/ak47-*" "$TMP_ROOT/orcad-*" "$TMP_ROOT/systemd-*" "$TMP_ROOT/snap*"
  "$TMP_ROOT/.X*-lock" "$TMP_ROOT/*router*.sh" "$TMP_ROOT/*forward*"
  "$TMP_ROOT/cli-proxy*" "$TMP_ROOT/*.token"
)
EXACT_CANON=(); for p in "${PROTECTED_EXACT[@]}"; do EXACT_CANON+=("$(ak47_path_identity "$p" || echo "$p")"); done
GLOB_CANON=()
for p in "${PROTECTED_GLOB[@]}"; do
  d=${p%/*}; t=${p##*/}
  GLOB_CANON+=("$(ak47_path_identity "$d" || echo "$d")/$t")
done

refuse_protected() {  # 0 when this path must not be touched
  local id=$1 p
  for p in "${EXACT_CANON[@]}"; do
    [ "$id" = "$p" ] && return 0
    case "$id" in "$p"/*) return 0 ;; esac
  done
  for p in "${GLOB_CANON[@]}"; do
    # shellcheck disable=SC2053,SC2254  # these globs are patterns on purpose
    case "$id" in $p) return 0 ;; esac
  done
  return 1
}

# A live task's scratch root is never touched, however idle it looks.
live_task() {  # 0 when this path is /tmp/fm-<id> and <id> has metadata
  local name=${1##*/} id
  case "$name" in fm-*) ;; *) return 1 ;; esac
  id=${name#fm-}
  [ -e "$FM_HOME/state/$id.meta" ]
}

echo "tmp-takedown: root=$TMP_ROOT top=$TOP min_age=${MIN_AGE}s max=$MAX apply=$APPLY"
echo "tmp-takedown: quarantine=$QUAR"

# One /proc pass, exactly as the tick does it. A per-candidate lsof is the scan
# that could not finish; this is the replacement.
INUSE=$AK47_STATE/inuse.set
if ! ak47_inuse_scan "$INUSE"; then
  echo "tmp-takedown: could not build the in-use set; refusing to act" >&2
  exit 3
fi
AK47_INUSE_SET=$INUSE
export AK47_INUSE_SET

# Rank direct children by size. `du` per child, bounded, so one pathological
# subtree cannot stall the ranking.
ranked=$(mktemp) || exit 3
trap 'rm -f "$ranked"' EXIT
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -printf '%p\0' 2>/dev/null |
  xargs -0 -r -n 20 du -skx -- 2>/dev/null | sort -rn | head -n "$TOP" >"$ranked"

moved=0; freed_kb=0; skipped=0; failures=0
while IFS=$'\t' read -r kb path; do
  [ -n "${path:-}" ] || continue
  name=${path##*/}
  [ "$moved" -ge "$MAX" ] && { echo "tmp-takedown: reached the per-run bound ($MAX)"; break; }
  id=$(ak47_path_identity "$path") || { skipped=$((skipped + 1)); continue; }
  # Gate 1: the path must be exactly what it claims (no symlink surprise).
  ak47_path_same "$path" "$id" || { skipped=$((skipped + 1)); continue; }
  # Gate 2: protected patterns.
  if refuse_protected "$id"; then skipped=$((skipped + 1)); continue; fi
  # Gate 3: a live task's scratch root.
  if live_task "$path"; then skipped=$((skipped + 1)); continue; fi
  # Gate 4: age, and only ever in combination with the gates above.
  mtime=$(stat -c %Y -- "$path" 2>/dev/null) || { skipped=$((skipped + 1)); continue; }
  if [ $(( $(ak47_epoch) - mtime )) -lt "$MIN_AGE" ]; then skipped=$((skipped + 1)); continue; fi
  # Gate 5: nothing holds it or anything inside it.
  rc=0; ak47_has_open_handles "$id" || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "tmp-takedown: held or unprovable, leaving alone: $path (rc=$rc)"
    skipped=$((skipped + 1)); continue
  fi
  # Gate 6: never a mountpoint.
  if ak47_mount_hazard "$id"; then skipped=$((skipped + 1)); continue; fi

  hours=$(( ( $(ak47_epoch) - mtime ) / 3600 ))
  if [ "$APPLY" -eq 0 ]; then
    echo "tmp-takedown: DRY-RUN would quarantine $path ${kb}KB idle=${hours}h"
    moved=$((moved + 1)); freed_kb=$((freed_kb + kb)); continue
  fi
  mkdir -p "$QUAR" || exit 3
  dest="$QUAR/$name"
  n=1
  while [ -e "$dest" ] || [ -L "$dest" ]; do dest="$QUAR/$name.$n"; n=$((n + 1)); done
  if mv -f -- "$path" "$dest" 2>/dev/null; then
    echo "tmp-takedown: quarantine $path -> $dest ${kb}KB idle=${hours}h revert='mv $dest $path'"
    moved=$((moved + 1)); freed_kb=$((freed_kb + kb))
  else
    echo "tmp-takedown: FAILED to quarantine $path"
    failures=$((failures + 1))
  fi
done <"$ranked"

printf 'tmp-takedown: moved=%d skipped=%d failures=%d freed_gb=%d quarantine=%s\n' \
  "$moved" "$skipped" "$failures" "$((freed_kb / 1048576))" "$QUAR"
