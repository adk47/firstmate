#!/usr/bin/env bash
# scripts/sync-from-server.sh
# ===========================
# Pull files FROM node-8 INTO this repo. Inverse of scripts/deploy.sh.
#
# Use this when:
#   - deploy.sh Step 0 reports drift (someone edited the server directly
#     and you need to capture their work before the next deploy wipes it)
#   - you want to inspect audit logs or workspace runtime state locally
#   - you suspect server-only state has diverged from repo seeds
#
# Default mode: DRY-RUN. Nothing is written. Pass --apply to actually
# copy files. After --apply, review with `git diff` and commit if the
# changes are intentional.
#
# This script never deletes anything from the repo (no --delete). Worst
# case it adds files; never silently destroys them.
#
# SSH defaults match scripts/deploy.sh — same key, same host. Override
# with the same env vars (SSH_KEY, NODE8_IP, NODE8_USER) the deploy uses.
#
# Quick start (laptop): you probably need
#     export NODE8_IP=40.160.32.80      # public IP, vrack default won't reach
# See the SSH config block below for the full who/what/why.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── SSH connection: which key, which IP, why? ────────────────────
# (Same logic as scripts/deploy.sh — kept symmetric on purpose so the
# recovery path the deploy briefings advertise works the same way.)
#
#   ┌────────────────┬────────────────────┬──────────────────────┐
#   │ Where you are  │ SSH key            │ NODE8_IP             │
#   ├────────────────┼────────────────────┼──────────────────────┤
#   │ CI / vrack     │ ~/.ssh/ovh_muso    │ 10.0.0.8  (vrack)    │
#   │ Laptop / WAN   │ ~/.ssh/nick_ovh    │ 40.160.32.80 (public)│
#   └────────────────┴────────────────────┴──────────────────────┘
#
# SSH_KEY auto-detection: probe ovh_muso first, fall back to nick_ovh.
# NODE8_IP: defaults to vrack; laptop users override via env:
#     export NODE8_IP=40.160.32.80
# ──────────────────────────────────────────────────────────────────
if [[ -z "${SSH_KEY:-}" ]]; then
  for candidate in "$HOME/.ssh/ovh_muso" "$HOME/.ssh/nick_ovh"; do
    if [[ -f "$candidate" ]]; then
      SSH_KEY="$candidate"
      break
    fi
  done
fi
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"  # final fallback if no candidate exists
NODE8_IP="${NODE8_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

SSH_OPTS_STR="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

usage() {
  cat <<'USAGE'
Usage: scripts/sync-from-server.sh <target> [--apply]

Targets:
  skills        Pull skills-all/ from node-8 into repo
  workspaces    Pull workspaces/ from node-8 (memory, IDENTITY, .openclaw, etc)
  audit         Pull audit/ from node-8 (per-workspace memory snapshots, conv logs)
  all           skills + workspaces (NOT audit — opt in explicitly, large)

Flags:
  --apply       Actually copy files. Without this, runs as a dry-run.

Examples:
  # Check if anyone edited skills on the server
  scripts/sync-from-server.sh skills

  # Pull and inspect:
  scripts/sync-from-server.sh skills --apply
  git status skills-all/
  git diff skills-all/

  # If the diff looks legitimate, commit it:
  git add skills-all/ && git commit -m "chore: pull skill edits from node-8"

  # Pull audit logs (large — explicit opt-in):
  scripts/sync-from-server.sh audit --apply
USAGE
  exit 1
}

# Parse args. --apply is positional-flexible: it can appear before or
# after the target, so `--apply skills` and `skills --apply` both work.
TARGET=""
APPLY=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $arg" >&2; usage ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$arg"
      else
        echo "Unexpected extra argument: $arg" >&2; usage
      fi
      ;;
  esac
done
[[ -z "$TARGET" ]] && usage

DRY_FLAG="-n"
$APPLY && DRY_FLAG=""

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
log()    { echo "[sync-from-server] $*"; }

# Single tempfile for the whole script run, cleaned up via trap so
# Ctrl-C / rsync failure / unexpected exit all leave a clean /tmp.
TMP=$(mktemp -t sync-from-server.XXXXXX)
trap 'rm -f "$TMP"' EXIT

pull() {
  local subdir="$1"
  local mode="DRY-RUN"
  $APPLY && mode="APPLY"
  log "Pulling $subdir/  ($mode)"
  # No --delete: we never remove repo files based on server state.
  # --checksum so mtime noise doesn't pollute the diff.
  if rsync -az $DRY_FLAG --checksum --itemize-changes \
       -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
       "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/$subdir/" \
       "$HYDRA_ROOT/$subdir/" \
       | tee "$TMP" ; then
    # Count how many files would actually transfer.
    # Itemize lines for transfers start with `>f` or `<f`; we count
    # those and ignore directory entries (`>d`, `<d`) and metadata-only
    # lines (`.f....t....`).
    local n
    n=$(grep -cE '^[<>]f' "$TMP" || true)
    if (( n > 0 )); then
      if $APPLY; then
        yellow "  → $n file(s) pulled"
      else
        yellow "  → $n file(s) would be pulled"
      fi
    else
      green "  → repo already matches server (no changes)"
    fi
  else
    red "  rsync failed for $subdir"
    exit 1
  fi
}

case "$TARGET" in
  skills)     pull "skills-all" ;;
  workspaces) pull "workspaces" ;;
  audit)      pull "audit" ;;
  all)        pull "skills-all"; pull "workspaces" ;;
  *)          usage ;;
esac

echo
if ! $APPLY; then
  yellow "DRY-RUN — nothing was written. Re-run with --apply to pull for real."
else
  green "Done. Review with: git status && git diff"
  green "Then commit if the changes are intentional."
fi
