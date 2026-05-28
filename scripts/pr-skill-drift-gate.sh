#!/usr/bin/env bash
# pr-skill-drift-gate.sh — PR-time shift-left of the skill-drift check.
#
# Invoked by the .github/workflows/pr-validate.yml deploy-preflight job, which
# runs on the self-hosted node-8 runner (so /opt/hydra/ is a local path). It
# uses the 3-way classifier (scripts/lib/drift-check.sh) to surface drift
# BEFORE merge instead of only when the post-merge deploy blocks:
#
#   SERVER-AHEAD → FAIL the PR; print a per-file `sync-from-server.sh --only`
#                  capture command so the author pulls just that file without
#                  clobbering the PR's other skill edits.
#   CONFLICT     → FAIL the PR; print a 3-way reconcile recipe.
#   REPO-AHEAD   → pass (the PR's own intended edits; the deploy will push
#                  them — this is the PR-time half of the #366 fix).
#   no/unreachable baseline → WARN and pass. The gate is advisory shift-left;
#                  the merge-deploy's Step 4a is the authoritative backstop.
#
# It deliberately does NOT consult the hot-patch ack window: ack means
# "I am deploying now and accept the overwrite," which is a deploy-time
# statement. At PR time an announced server edit is exactly what a human
# should look at.
#
# Inputs (env):
#   REPO_ROOT    repo checkout to validate (default: $PWD)
#   SERVER_ROOT  live deploy target (default: /opt/hydra)
# Exit: 0 = pass/warn, 1 = drift found or classifier hard-failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
SERVER_ROOT="${SERVER_ROOT:-/opt/hydra}"

# shellcheck source=lib/drift-check.sh
source "$SCRIPT_DIR/lib/drift-check.sh"

baseline=""
if [[ -f "$SERVER_ROOT/.deployed-sha" ]]; then
  baseline=$(tr -d '[:space:]' < "$SERVER_ROOT/.deployed-sha" 2>/dev/null || true)
fi

classified=""
rc=0
classified=$(classify_skill_drift "$baseline" "$REPO_ROOT" "$SERVER_ROOT") || rc=$?

case "$rc" in
  0) ;;
  5|6)
    echo "::warning::skill-drift gate skipped — no usable node-8 baseline (rc=$rc). The merge-deploy Step 4a backstop still checks drift."
    exit 0
    ;;
  *)
    echo "::error::skill-drift classifier failed (rc=$rc) — could not certify this PR. Ensure a full-history checkout (fetch-depth: 0) and re-run."
    exit 1
    ;;
esac

server_ahead=$(printf '%s\n' "$classified" | sed -n 's/^SERVER-AHEAD //p')
conflicts=$(printf '%s\n' "$classified" | sed -n 's/^CONFLICT //p')

if [[ -z "$server_ahead" && -z "$conflicts" ]]; then
  echo "✓ No SERVER-AHEAD / CONFLICT skill drift vs node-8 (REPO-AHEAD edits pass)."
  exit 0
fi

echo "::error::skills-all/ drift vs node-8 — capture or reconcile before merging"
if [[ -n "$server_ahead" ]]; then
  echo
  echo "SERVER-AHEAD — node-8 has skill edits not in this PR. Capture each one"
  echo "WITHOUT clobbering your other edits (do NOT bulk-pull):"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # %q shell-quotes the path so copy-paste survives spaces/specials.
    printf '  scripts/sync-from-server.sh skills --apply --only %q\n' "$p"
  done <<< "$server_ahead"
  echo "  then: git add <path> && git commit, and rebase this PR onto it."
fi
if [[ -n "$conflicts" ]]; then
  echo
  echo "CONFLICT — edited on BOTH node-8 and this PR; 3-way merge by hand"
  echo "(baseline = the commit recorded in /opt/hydra/.deployed-sha):"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # %q so the baseline:path ref survives copy-paste with spaces/specials.
    printf '  git show %q   # baseline; reconcile vs the node-8 copy + your branch\n' "$baseline:$p"
  done <<< "$conflicts"
fi
exit 1
