#!/usr/bin/env bash
# MUS-5643: fail on any NEW literal /tmp/ scratch or clone path in agent-facing
# instructions and scripts. Agent Bash calls are separate shells, so a
# `trap ... EXIT` never holds across them (536 pr-review-*.json, 1171 review
# clones left in /tmp). Use ${PAPERCLIP_RUN_SCRATCH_DIR:-<workspace>/tmp}/...
# (Paperclip agents) or the agent's workspaces/<agent>/tmp/ (openclaw agents).
# Only ADDED lines are checked, so legacy sites are not a blocker.
# Allow a legitimately fixed path with: `# tmp-ok: <reason>` on the same line.
#
# Usage: check-no-tmp-scratch.sh --base <ref> | --staged
set -euo pipefail

SCOPE=(
  ':(glob)skills-all/**'
  ':(glob)workspaces/*/AGENTS.md'
  ':(glob)scripts/**'
  ':(exclude,glob)scripts/tests/**'
  ':(exclude,glob)**/*.bats'
  ':(exclude,glob)scripts/check-no-tmp-scratch.sh'
)

case "${1:-}" in
  --base)   [ -n "${2:-}" ] || { echo "usage: $0 --base <ref> | --staged" >&2; exit 2; }
            diff_cmd=(git diff -U0 --no-color "$2" HEAD -- "${SCOPE[@]}") ;;
  --staged) diff_cmd=(git diff -U0 --no-color --cached -- "${SCOPE[@]}") ;;
  *)        echo "usage: $0 --base <ref> | --staged" >&2; exit 2 ;;
esac

hits="$("${diff_cmd[@]}" | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^\+\+\+ /    { next }
  /^\+/ && index($0, "/tmp/") {
    if ($0 ~ /tmp-ok:[ \t]*[^ \t]/) next
    print file ": " substr($0, 2)
  }')"

if [ -n "$hits" ]; then
  echo "::error::new literal /tmp/ scratch path (MUS-5643) - use \${PAPERCLIP_RUN_SCRATCH_DIR:-<workspace>/tmp}/..., or add '# tmp-ok: <reason>':" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
