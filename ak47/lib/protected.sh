#!/usr/bin/env bash
# ak47/lib/protected.sh - the one owner of the /tmp protected set.
#
# Sourced by every script that may move a /tmp entry, so the tick and the
# take-down cannot drift apart on what must never be touched. Depends on
# ak47_path_identity from safe-delete.sh, which must be sourced first.
#
# The set is canonicalised once at source time, not per candidate: the tick's
# loop runs thousands of times and a realpath fork per comparison cost 24
# minutes on the first measurement. After this, every comparison is a string
# test.
#
# Public:
#   ak47_protected_spelling <path>  0 when the (already canonical) string is protected
#   ak47_is_protected <path>        0 when the path must not be touched

AK47_PROTECTED_ROOT=${AK47_TMP_ROOT:-/tmp}
AK47_PROTECTED_EXACT=(
  "$AK47_PROTECTED_ROOT/fm-move"
  "$AK47_PROTECTED_ROOT/jest_0"
  "$AK47_PROTECTED_ROOT/.X11-unix" "$AK47_PROTECTED_ROOT/.ICE-unix"
  "$AK47_PROTECTED_ROOT/.font-unix"
  "$AK47_PROTECTED_ROOT/.Test-unix" "$AK47_PROTECTED_ROOT/.XIM-unix"
)
AK47_PROTECTED_GLOB=(
  "$AK47_PROTECTED_ROOT/ak47-*" "$AK47_PROTECTED_ROOT/orcad-*"
  "$AK47_PROTECTED_ROOT/systemd-*" "$AK47_PROTECTED_ROOT/snap*"
  "$AK47_PROTECTED_ROOT/.X*-lock" "$AK47_PROTECTED_ROOT/*router*.sh"
  "$AK47_PROTECTED_ROOT/*forward*"
  "$AK47_PROTECTED_ROOT/cli-proxy*" "$AK47_PROTECTED_ROOT/*.token"
)

AK47_PROTECTED_EXACT_CANON=()
for p in "${AK47_PROTECTED_EXACT[@]}"; do
  AK47_PROTECTED_EXACT_CANON+=("$(ak47_path_identity "$p" || echo "$p")")
done
AK47_PROTECTED_GLOB_CANON=()
for p in "${AK47_PROTECTED_GLOB[@]}"; do
  # Only the directory part can be a symlink; the pattern tail is literal.
  dir=${p%/*}; tail=${p##*/}
  AK47_PROTECTED_GLOB_CANON+=("$(ak47_path_identity "$dir" || echo "$dir")/$tail")
done

# ak47_protected_spelling <path> - the string tests, no forks.
ak47_protected_spelling() {
  local id=$1 p task
  for p in "${AK47_PROTECTED_EXACT_CANON[@]}"; do
    [ "$id" = "$p" ] && return 0
    case "$id" in "$p"/*) return 0 ;; esac
  done
  for p in "${AK47_PROTECTED_GLOB_CANON[@]}"; do
    # shellcheck disable=SC2053,SC2254  # these globs are patterns on purpose
    case "$id" in $p) return 0 ;; esac
  done
  # A live task's scratch root is protected for as long as its metadata exists.
  case "$id" in
    "$AK47_PROTECTED_ROOT"/fm-*)
      task=${id#"$AK47_PROTECTED_ROOT"/fm-}
      task=${task%%/*}
      [ -f "$FM_HOME/state/$task.meta" ] && return 0
      ;;
  esac
  return 1
}

# ak47_is_protected <path> - 0 when the path must not be touched.
# The literal spelling is checked first and costs nothing. Only a symlink can
# spell itself differently from its canonical path here, because every candidate
# is a direct child of a real /tmp, so the canonical pass runs at most once per
# symlink instead of once per candidate.
ak47_is_protected() {
  local path=$1 id
  ak47_protected_spelling "$path" && return 0
  [ -L "$path" ] || return 1
  id=$(ak47_path_identity "$path") || return 0   # cannot canonicalise -> protect
  ak47_protected_spelling "$id" && return 0
  return 1
}
