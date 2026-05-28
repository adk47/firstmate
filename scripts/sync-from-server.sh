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
Usage: scripts/sync-from-server.sh <target> [--apply] [--only <path> ...]

Targets:
  skills        Pull skills-all/ from node-8 into repo
  workspaces    Pull workspaces/ from node-8 (memory, IDENTITY, .openclaw, etc)
  audit         Pull audit/ from node-8 (per-workspace memory snapshots, conv logs)
  all           skills + workspaces (NOT audit — opt in explicitly, large)

Flags:
  --apply       Actually copy files. Without this, runs as a dry-run.
  --only <path> Pull ONLY this repo-relative path instead of the whole target
                subdir. Repeatable. Use this to capture a single drifted file
                (e.g. one a drift gate flagged SERVER-AHEAD) WITHOUT clobbering
                other locally-modified files in the same tree. The path must
                live under the target's subdir (e.g. skills → skills-all/...).

Examples:
  # Check if anyone edited skills on the server
  scripts/sync-from-server.sh skills

  # Pull and inspect:
  scripts/sync-from-server.sh skills --apply
  git status skills-all/
  git diff skills-all/

  # Capture just one flagged file (safe alongside other PR edits):
  scripts/sync-from-server.sh skills --apply --only skills-all/muso-anrok/SKILL.md

  # If the diff looks legitimate, commit it:
  git add skills-all/ && git commit -m "chore: pull skill edits from node-8"

  # Pull audit logs (large — explicit opt-in):
  scripts/sync-from-server.sh audit --apply
USAGE
  exit 1
}

# Parse args. --apply is positional-flexible (before or after the target).
# --only <path> is repeatable and takes the next arg as a value.
TARGET=""
APPLY=false
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --only)
      shift
      [[ $# -gt 0 ]] || { echo "--only requires a <path> argument" >&2; usage; }
      ONLY+=("$1")
      ;;
    --only=*) ONLY+=("${1#--only=}") ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        echo "Unexpected extra argument: $1" >&2; usage
      fi
      ;;
  esac
  shift
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

# Allowed path prefixes for the chosen target — used to validate --only paths.
target_prefixes() {
  case "$TARGET" in
    skills)     printf '%s\n' "skills-all/" ;;
    workspaces) printf '%s\n' "workspaces/" ;;
    audit)      printf '%s\n' "audit/" ;;
    all)        printf '%s\n' "skills-all/" "workspaces/" ;;
    *)          usage ;;
  esac
}

# Reject any --only path that doesn't live under the target's subdir, so a
# typo can't pull (and on --apply, write) an unexpected tree.
validate_only_paths() {
  local p pre ok prefixes pretty
  prefixes=$(target_prefixes)
  pretty=$(printf '%s' "$prefixes" | tr '\n' ' ')
  for p in "${ONLY[@]}"; do
    # Reject absolute paths and '..' traversal BEFORE the prefix check: a path
    # like skills-all/../scripts/foo passes the "starts with skills-all/" test
    # but escapes the target tree once rsync resolves it (the /./ anchor in
    # pull_files would write outside skills-all/).
    if [[ "$p" == /* ]] || [[ "$p" =~ (^|/)\.\.(/|$) ]]; then
      red "  --only path '$p' is invalid (no absolute paths or '..' traversal)"
      exit 1
    fi
    ok=false
    while IFS= read -r pre; do
      [[ "$p" == "$pre"* ]] && { ok=true; break; }
    done <<< "$prefixes"
    if ! $ok; then
      red "  --only path '$p' is not under the '$TARGET' target (expected prefix: $pretty)"
      exit 1
    fi
  done
}

# Pull only the named repo-relative paths. -R recreates the relative path
# (parent dirs included) under HYDRA_ROOT; the /./ anchor marks where the
# relative portion begins. No --delete — same safety contract as pull().
pull_files() {
  local mode="DRY-RUN"
  $APPLY && mode="APPLY"
  : > "$TMP"
  local p
  for p in "${ONLY[@]}"; do
    log "Pulling $p  ($mode)"
    if ! rsync -az $DRY_FLAG -R --checksum --itemize-changes \
         -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
         "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/./$p" \
         "$HYDRA_ROOT/" \
         | tee -a "$TMP" ; then
      red "  rsync failed for $p"
      exit 1
    fi
  done
  local n
  n=$(grep -cE '^[<>]f' "$TMP" || true)
  if (( n > 0 )); then
    if $APPLY; then yellow "  → $n file(s) pulled"; else yellow "  → $n file(s) would be pulled"; fi
  else
    green "  → repo already matches server (no changes)"
  fi
}

if (( ${#ONLY[@]} > 0 )); then
  validate_only_paths
  pull_files
else
  case "$TARGET" in
    skills)     pull "skills-all" ;;
    workspaces) pull "workspaces" ;;
    audit)      pull "audit" ;;
    all)        pull "skills-all"; pull "workspaces" ;;
    *)          usage ;;
  esac
fi

echo
if ! $APPLY; then
  yellow "DRY-RUN — nothing was written. Re-run with --apply to pull for real."
else
  green "Done. Review with: git status && git diff"
  green "Then commit if the changes are intentional."
fi
