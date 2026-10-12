#!/usr/bin/env bash
# scripts/sync-back-run.sh
# ========================
# Scheduled node-8 -> git sync-back (MUS-5104, W2b-2b). Runs ON node-8 (the
# self-hosted runner), so /opt/hydra is a local directory: sync-from-server.sh
# is called with --from-local, no ssh, no key. Logic lives here, not in YAML, so
# bats can drive it (same split as deploy.yml -> deploy.sh).
#
#   nothing changed          -> exit 0; no branch, no commit, no PR
#   something changed        -> commit to sync/node-8-<date>, push, ONE PR
#   a sync/node-8-* PR open  -> replace that branch's commit, force-with-lease
#                               to THAT branch only; never a second PR
#
# Never merges (a human does). Target is always `all` (skills + workspaces):
# `audit` pulls untracked content and is human-inspection only. The dirty-tree
# guard is sync-from-server.sh's own bulk --apply guard; this script adds none.
# DEPLOY_PATH (/opt/hydra) is only ever read; every write lands in this clone.
#
# Usage: scripts/sync-back-run.sh [--date YYYY-MM-DD]
# Env:   SYNC_BASE (default main), SYNC_REMOTE (default origin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${SYNC_BASE:-main}"
REMOTE="${SYNC_REMOTE:-origin}"
DATE="$(date -u +%F)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) shift; DATE="${1:?--date needs a value}" ;;
    *) echo "Usage: scripts/sync-back-run.sh [--date YYYY-MM-DD] (no target argument: always 'all')" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[sync-back-run] $*"; }
g() { git -C "$ROOT" "$@"; }

g fetch -q "$REMOTE"

# An open sync PR's branch is the one we amend. Yesterday's name, not today's.
# --limit: gh's default page is 30 and hydra has more open PRs than that, so an
# old sync PR would fall off page 1 and a second one would be opened.
open_branches="$(gh pr list --state open --base "$BASE" --limit 200 --json headRefName \
  | jq -r '.[].headRefName | select(startswith("sync/node-8-"))')"
if [[ "$(printf '%s' "$open_branches" | grep -c .)" -gt 1 ]]; then
  echo "[sync-back-run] more than one open sync PR, refusing to pick one: $(echo $open_branches)" >&2
  exit 1
fi
open_branch="$open_branches"
branch="${open_branch:-sync/node-8-$DATE}"

# Detached at the base: the branch is created only once there is something to
# commit, so an empty run leaves no branch behind.
g checkout -q --detach "$REMOTE/$BASE"
"$SCRIPT_DIR/sync-from-server.sh" all --apply --from-local

if [[ -z "$(g status --porcelain --untracked-files=no)" ]]; then
  log "no drift: node-8 matches $BASE for every tracked path. No branch, no commit, no PR."
  exit 0
fi

# The lease is computed AFTER the fetch above, so it always equals the remote tip
# and does NOT guard against a human push. The branch is bot-owned (the PR body
# says so); the workflow's concurrency group is what prevents the lost-capture race.
lease=()
if g rev-parse -q --verify "refs/remotes/$REMOTE/$branch" >/dev/null; then
  lease=(--force-with-lease="$branch:$(g rev-parse "refs/remotes/$REMOTE/$branch")")
fi
files="$(g status --porcelain --untracked-files=no)"
g checkout -q -B "$branch"
g add -u
g commit -q -m "chore(sync): pull node-8 drift into git ($DATE)" \
  -m "Captured by scripts/sync-back-run.sh from node-8, git-tracked paths only." \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
g push -q ${lease[@]+"${lease[@]}"} "$REMOTE" "$branch"
log "pushed $branch ($(g rev-parse --short HEAD))"

if [[ -n "$open_branch" ]]; then
  log "PR for $branch is already open: branch replaced, no second PR."
  exit 0
fi

body="$(printf 'Automated node-8 -> git sync-back (scripts/sync-back-run.sh). Git-tracked paths only; never auto-merged.\n\nThis branch is rewritten from node-8 on every run - do not push to it; comment on the PR instead.\n\nChanged files:\n\n```\n%s\n```\n' "$files")"
gh pr create --base "$BASE" --head "$branch" \
  --title "chore(sync): pull node-8 drift into git ($DATE)" --body "$body"
