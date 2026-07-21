#!/usr/bin/env bash
set -euo pipefail

# qa-clean-merge-scratch.sh — on merge of a QA-reviewed PR, remove stray review
# scratch left directly under workspaces/qa/ so it can't red the next deploy.
# ===========================================================================
# Why this exists: the QA auto-review runs on node-8 and, on a bad day, can leave
# a server-only file directly under /opt/hydra/workspaces/qa/ (the historical
# `workspaces/qa/seven_days_ago`, a backtick-redirect accident during PR #287's
# review). deploy.sh Step 4a's rsync --delete pre-flight then flags that file as a
# would-delete server file and BLOCKS the deploy ("content drift"). Today the fix
# is manual (`rm` on node-8 + rerun). This automates that cleanup on merge.
#
# WHAT IT DELETES — and, more importantly, what it must NEVER delete:
#   Only depth-1 REGULAR FILES under TARGET that are BOTH
#     (a) NOT tracked at the merged repo HEAD, AND
#     (b) NOT matched by the depth-1-file subset of deploy.sh's RSYNC_EXCLUDES.
#   That is EXACTLY the set the deploy pre-flight would flag (scripts/lib/
#   classify-deletions.sh auto-excludes never-tracked *subdirs*, but a never-
#   tracked top-level FILE falls through to the drift briefing — so files are the
#   only class we touch). Untracked-but-legit runtime files like IDENTITY.md and
#   HEARTBEAT.md are protected by (b); tracked seeds (AGENTS/SOUL/USER/...) by (a);
#   subdirs (api-logs/, skills/, memory/, ...) are never touched at all.
#
# Fail-closed: if the tracked set cannot be computed (no git, REPO_ROOT not a
# checkout, or an empty tracked set while TARGET has files — a suspect/shallow
# clone), DELETE NOTHING. Without the tracked set we cannot tell a seed from
# scratch, and a false delete of qa state is far worse than a one-deploy red flap.
#
# Usage:
#   qa-clean-merge-scratch.sh [TARGET]      # TARGET default: /opt/hydra/workspaces/qa
#   qa-clean-merge-scratch.sh --print-keep-globs
#
# Env overrides (mainly for tests):
#   REPO_ROOT    merged git checkout used for the tracked-set (default: this repo)
#   REL_PREFIX   TARGET's path within the repo (default: workspaces/qa)
# Exit codes: 0 always (best-effort; a cleanup must never fail the merge workflow)
#             | 2 usage.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KEEP globs — the depth-1-file subset of deploy.sh's RSYNC_EXCLUDES, mirrored so
# this cleanup never deletes a file the deploy considers legit server-owned state.
# DRIFT GUARD: scripts/tests/qa-clean-merge-scratch.bats asserts every
# `--exclude='workspaces/*/<fileglob>'` in deploy.sh is present below, so adding an
# exclude there without mirroring it here fails CI. Keep them in lockstep.
KEEP_GLOBS=(
  # global file excludes (apply at any depth, including a workspace root)
  '*.bak.*' '*.bak-*' '*.mp3' '*.pyc'
  '.admin-token-cache' '.ads-token-cache'
  # workspaces/*/<file> excludes mirrored from deploy.sh RSYNC_EXCLUDES
  'MEMORY.md' 'IDENTITY.md' 'HEARTBEAT.md' 'TOOLS.md'
  'openclaw-workspace-state.json'
  '*tmp*'                              # any 'tmp'-marked scratch: .tmp-*, tmp_*, *.tmp
  'TOOLS.md.bak-*' '*.md.bak-*'
  'write-activity.log'
  '*.jpeg' '*.jpg' '*.webp' '*.gif' '*.png' '*.pdf' '*.csv' '*.txt' '*.py'
  '.env'
)

if [ "${1:-}" = "--print-keep-globs" ]; then
  printf '%s\n' "${KEEP_GLOBS[@]}"
  exit 0
fi

[ "$#" -le 1 ] || { echo "qa-clean-merge-scratch: usage: qa-clean-merge-scratch.sh [TARGET]" >&2; exit 2; }

TARGET="${1:-/opt/hydra/workspaces/qa}"
REPO_ROOT="${REPO_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
REL_PREFIX="${REL_PREFIX:-workspaces/qa}"

warn() { echo "qa-clean-merge-scratch: $*" >&2; }

# Guard obviously-wrong targets before we enumerate anything.
case "$TARGET" in
  ""|"/") warn "refusing to operate on TARGET='$TARGET'."; exit 0;;
esac
if [ ! -d "$TARGET" ]; then
  warn "TARGET '$TARGET' does not exist; nothing to clean."
  exit 0
fi

# Fail closed without a usable git checkout — we need the tracked set to tell a
# seed from scratch (cf. classify-deletions.sh's git guard).
if ! command -v git >/dev/null 2>&1 \
   || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  warn "REPO_ROOT '$REPO_ROOT' is not a git checkout; deleting nothing (fail-closed)."
  exit 0
fi

# Depth-1 tracked basenames under REL_PREFIX (strip the prefix, drop anything with
# a further slash so only top-level files count).
tracked="$(git -C "$REPO_ROOT" ls-files -- "$REL_PREFIX" \
  | sed -E "s#^${REL_PREFIX}/##" \
  | grep -v '/' || true)"

# Empty tracked set while TARGET has content is the shallow/broken-clone smell from
# classify-deletions.sh — refuse rather than treat every file as scratch.
if [ -z "$tracked" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null || true)" ]; then
  warn "tracked set for '$REL_PREFIX' is empty but TARGET has content; git state suspect, deleting nothing (fail-closed)."
  exit 0
fi

deleted=0 kept=0
while IFS= read -r -d '' path; do
  base="$(basename "$path")"

  # (a) tracked seed -> keep.
  if grep -qxF -- "$base" <<<"$tracked"; then
    kept=$((kept + 1)); continue
  fi

  # (b) matches a legit-runtime KEEP glob -> keep.
  keep_it=0
  for g in "${KEEP_GLOBS[@]}"; do
    # shellcheck disable=SC2254  # intentional glob match of $g against $base
    case "$base" in $g) keep_it=1; break;; esac
  done
  if [ "$keep_it" -eq 1 ]; then
    kept=$((kept + 1)); continue
  fi

  # Neither tracked nor excluded -> stray review scratch. Remove it, loudly.
  if rm -f -- "$path"; then
    warn "removed stray qa review scratch: ${REL_PREFIX}/${base}"
    deleted=$((deleted + 1))
  else
    warn "FAILED to remove ${REL_PREFIX}/${base} (continuing)."
  fi
done < <(find "$TARGET" -maxdepth 1 -type f -print0)

echo "qa-clean-merge-scratch: ${deleted} stray file(s) removed, ${kept} legit file(s) kept under ${TARGET}."
exit 0
