#!/usr/bin/env bash
# Is the deployed merge-queue chain (default /root/q1) the PINNED tree?
#
# The chain is written by core-backend and copied to node-8 by hand, so the bytes that
# actually run are invisible to review: a six-week-old copy of send_variant_copy.py
# posts six-week-old approved copy to customers and reports success. This compares each
# pinned file's sha256 with the deployed one and names every file that drifted.
#
# The manifest must pin EXACTLY the six chain files. A truncated manifest is not a
# narrower check, it is a wider hole: one surviving `plan.py` pin would report "1 pinned
# file(s) match" and exit 0 while a stale send_variant_copy.py kept posting copy nobody
# approved (QA finding, 2026-11-11). Duplicate, unknown and missing pins are all failures.
#
# Exit 0 clean; exit 1 drift, or a manifest that is unreadable/empty/partial/duplicated
# (fail closed - none of those is "nothing to check"); exit 2 usage.
#
# Usage:
#   chain-preflight.sh [--chain-dir DIR] [--manifest FILE] [--quiet]
#
#   CHAIN_DIR  default /root/q1        (the deployed copies)
#   MANIFEST   default <this dir>/chain-manifest.sha256
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN_DIR="${CHAIN_DIR:-/root/q1}"
MANIFEST="${CHAIN_MANIFEST:-$HERE/chain-manifest.sha256}"
QUIET="${QUIET:-0}"

usage() {
  echo "usage: $(basename "$0") [--chain-dir DIR] [--manifest FILE] [--quiet]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --chain-dir) [ $# -ge 2 ] || usage; CHAIN_DIR="$2"; shift 2 ;;
    --manifest)  [ $# -ge 2 ] || usage; MANIFEST="$2";  shift 2 ;;
    --quiet)     QUIET=1; shift ;;
    -h|--help)   usage ;;
    *)           usage ;;
  esac
done

log() { [ "$QUIET" = 1 ] || echo "$*"; }
die() { echo "chain-preflight: FATAL: $*" >&2; exit 1; }

[ -d "$CHAIN_DIR" ] || die "chain dir does not exist: $CHAIN_DIR"
[ -r "$MANIFEST" ] || die "manifest unreadable: $MANIFEST"

# The chain is exactly these six files (core-backend scripts/ops/merge-queue/). The list
# is in the script, not read from the manifest, so a truncated manifest cannot redefine
# what "clean" means.
REQUIRED=(plan.py variant_plan.py send_variant_copy.py clickup_merges.py sql.py same_person.py)

# A manifest with zero pins would pass every check below and read as "clean" while
# proving nothing, so an empty pin set is its own failure. So is a partial one.
declare -A want_of=()
pins=0
drift=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  want="${line%%  *}"
  file="${line#*  }"
  if [ "$want" = "$line" ] || [ -z "$want" ] || [ -z "$file" ]; then
    die "malformed manifest line (want '<sha256>  <file>'): $line"
  fi
  case " ${REQUIRED[*]} " in
    *" $file "*) ;;
    *) die "manifest pins an unknown file: $file (the chain is exactly: ${REQUIRED[*]})" ;;
  esac
  if [ -n "${want_of[$file]:-}" ]; then
    die "manifest pins $file twice - refusing an ambiguous pin"
  fi
  want_of[$file]="$want"
  pins=$((pins + 1))
  path="$CHAIN_DIR/$file"
  if [ ! -f "$path" ]; then
    echo "DRIFT missing: $file (not present in $CHAIN_DIR)" >&2
    drift=$((drift + 1))
    continue
  fi
  got="$(sha256sum "$path" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "DRIFT changed: $file expected $want got $got" >&2
    drift=$((drift + 1))
  fi
done < "$MANIFEST"

[ "$pins" -gt 0 ] || die "manifest has no pins: $MANIFEST"
for file in "${REQUIRED[@]}"; do
  [ -n "${want_of[$file]:-}" ] \
    || die "manifest has no pin for $file - a partial manifest would let it drift unnoticed (expected all of: ${REQUIRED[*]})"
done

if [ "$drift" -gt 0 ]; then
  echo "chain-preflight: $drift of $pins pinned file(s) drifted in $CHAIN_DIR - refusing" >&2
  exit 1
fi

log "chain-preflight: $pins pinned file(s) match in $CHAIN_DIR"
