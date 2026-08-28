#!/usr/bin/env bash
# check-skills-config-includes.sh — every skills-all/<skill>/config/ must have an
# rsync include pair BEFORE the unanchored --exclude='config/'.
#
# WHY THIS IS A FILE AND NOT A BLOCK INSIDE deploy.sh
#
# It used to be a block inside deploy.sh, which meant it ran at DEPLOY time — after
# merge. On 2026-08-28 #874 landed skills-all/sentry-issue-triage/config/ without the
# pair, and every deploy on main failed from 4539ddb0 onward: the guard was correct and
# fired exactly as designed, at the one moment when acting on it costs a broken fleet
# deploy instead of a red check. pr-validate already carries a "shift-left copy" of the
# deploy's rsync pre-flight for precisely this reason and its own comment says so; this
# guard had simply never been included in that copy.
#
# So it lives here and BOTH callers run this one implementation. A second copy in the
# workflow would have been the drift class it exists to prevent.
#
# THE RULE
#
# rsync filter rules are FIRST-MATCH-WINS. The unanchored --exclude='config/' swallows
# skills-all/*/config/ unless a per-skill include precedes it, and an include placed
# AFTER it is dead code that reads as protection. So this checks ORDERING, not presence.
# Shipping a skill without its config is a SILENT runtime failure — already hit twice
# before the guard existed (prod-log watchdog fail-closed every tick 2026-06-10; set-env
# gate configs never reached the server).
#
# muso-ops-admin is the named exception: its canonical config carries deliberate
# server-side divergence (drifted tier2-approvers.txt, plus a godmode allowlist that
# exists only on node-8) and is synced by an explicit per-file include list instead.
#
# Usage: check-skills-config-includes.sh <hydra_root> [deploy_sh]
# Exit:  0 every config dir is covered · 1 a config dir would silently not ship
#        2 the array could not be read (fail closed — an unreadable guard is not a pass)

set -uo pipefail

HYDRA_ROOT="${1:-.}"
DEPLOY_SH="${2:-$HYDRA_ROOT/scripts/deploy.sh}"

[ -f "$DEPLOY_SH" ] || { echo "ERROR: cannot read $DEPLOY_SH" >&2; exit 2; }

# SINGLE SOURCE OF TRUTH. The array is declared once, in deploy.sh, and read from there
# by the deploy, by pr-validate's pre-flight, and by this guard. Same sed range anchor as
# the workflow: /^)$/ matches only a line that is exactly ")", which is tighter than /^)/
# and cannot terminate early on ")  # comment".
RSYNC_EXCLUDES=()
eval "$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$DEPLOY_SH")"

# FAIL CLOSED on an unreadable array. An empty array would make every config dir look
# uncovered (noise) or, with the ordering test, silently pass — neither is an answer.
declared=$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$DEPLOY_SH" | grep -cE -- "--(exclude|include)=")
if [ "${#RSYNC_EXCLUDES[@]}" -ne "$declared" ] || [ "${#RSYNC_EXCLUDES[@]}" -lt 15 ]; then
  echo "ERROR: RSYNC_EXCLUDES extraction problem — eval'd ${#RSYNC_EXCLUDES[@]} entries but the array block declares $declared. The sed range or array format likely changed." >&2
  exit 2
fi

exclude_idx=-1
idx=0
for rule in "${RSYNC_EXCLUDES[@]}"; do
  [ "$rule" = "--exclude=config/" ] && { exclude_idx="$idx"; break; }
  idx=$(( idx + 1 ))
done
if [ "$exclude_idx" -lt 0 ]; then
  echo "ERROR: RSYNC_EXCLUDES no longer contains --exclude='config/' — this guard needs updating rather than deleting." >&2
  exit 2
fi

rc=0
for cfg_dir in "$HYDRA_ROOT"/skills-all/*/config; do
  [ -d "$cfg_dir" ] || continue
  skill="$(basename "$(dirname "$cfg_dir")")"
  include_idx=-1
  idx=0
  for rule in "${RSYNC_EXCLUDES[@]}"; do
    [ "$rule" = "--include=${skill}/config/" ] && { include_idx="$idx"; break; }
    idx=$(( idx + 1 ))
  done
  if [ "$include_idx" -lt 0 ] || [ "$include_idx" -gt "$exclude_idx" ]; then
    echo "FAIL: skills-all/${skill}/config/ exists but RSYNC_EXCLUDES has no --include='${skill}/config/' pair BEFORE --exclude='config/'." >&2
    echo "      rsync is first-match-wins, so the config would SILENTLY never reach the server (see PR #474)." >&2
    echo "      Add the pair next to the existing ones in scripts/deploy.sh:" >&2
    echo "        --include='${skill}/config/'" >&2
    echo "        --include='${skill}/config/**'" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "OK: every skills-all/*/config/ has an include pair before --exclude='config/'."
exit "$rc"
