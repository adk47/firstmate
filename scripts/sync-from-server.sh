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
# This script never deletes anything from the repo (no --delete), and for
# skills/workspaces/all it pulls ONLY paths git already tracks at HEAD (minus
# NEVER_PULL below). A secret on node-8 is not tracked, so it cannot be named
# in the transfer list: sync-back can never put a committable path into the
# repo. There is no secret allow/deny list to keep current.
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

# LogLevel=ERROR: ssh's "Permanently added" warning would land in rsync stderr,
# which pull_tracked() treats as foreign output and fails on.
SSH_OPTS_STR="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"

usage() {
  cat <<'USAGE'
Usage: scripts/sync-from-server.sh <target> [--apply [--allow-dirty]] [--from-local] [--only <path> ...]

Targets:
  skills        Pull git-tracked files under skills-all/ from node-8
  workspaces    Pull git-tracked files under workspaces/ from node-8
  audit         Pull audit/ from node-8 (per-workspace memory snapshots, conv logs)
  all           skills + workspaces (NOT audit — opt in explicitly, large)

Flags:
  --apply       Actually copy files. Without this, runs as a dry-run.
                A bulk --apply (no --only) refuses a dirty git tree.
  --allow-dirty Let a bulk --apply run on a dirty tree (it can overwrite many
                files at once; --only --apply never needs this).
  --from-local  Read $DEPLOY_PATH as a LOCAL directory: no ssh, no -e. For a
                process already running on node-8 (the sync-back runner).
  --only <path> Pull ONLY this repo-relative path instead of the whole target
                subdir. Repeatable. Use this to capture a single drifted file
                (e.g. one a drift gate flagged SERVER-AHEAD) WITHOUT clobbering
                other locally-modified files in the same tree. The path must
                live under the target's subdir (e.g. skills → skills-all/...)
                and be a file git tracks.

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
ALLOW_DIRTY=false
FROM_LOCAL=false
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --allow-dirty) ALLOW_DIRTY=true ;;
    --from-local) FROM_LOCAL=true ;;
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

# Transport: remote = rsync over ssh to node-8; --from-local = $DEPLOY_PATH is a
# local directory (we ARE node-8), so no ssh key and no -e at all.
RSYNC_E=(-e "ssh -i $SSH_KEY $SSH_OPTS_STR")
SRC_HOST="$NODE8_USER@$NODE8_IP:"
if $FROM_LOCAL; then RSYNC_E=(); SRC_HOST=""; fi

# ─── NEVER_PULL: tracked paths that must never be overwritten from node-8 ──
# Matched as a path COMPONENT anywhere in the repo-relative path (deploy.sh's
# excludes are unanchored too). Declared here, NOT derived from deploy.sh's
# RSYNC_EXCLUDES: both classes are push-excluded, for opposite reasons.
# Each entry is one quoted line; the count assertion below reads this block
# from this file's own source, so keep it one entry per line.
NEVER_PULL=(
  # deploy.sh:842 push-excludes tests/, so the server copy is stale by
  # construction; pulling it REVERTS git (4 of MUS-5063's 6 would-be pulls).
  'tests/'
  # deploy.sh:1206 push-excludes config/ (unanchored, nested skill config/
  # too); the server copy is stale unless an --include pair exists.
  'config/'
  # deploy.sh:1145 push-excludes audit/. The tracked hits are
  # skills-all/muso-query-writer/saved-queries/audit/ (committed SQL
  # templates that .gitignore negates), not logs.
  'audit/'
  # Intent: secrets never travel server -> git. Zero tracked hits today.
  'secrets/'
  # Stronger than config/: deploy.sh:1200-1204 --include the approver and
  # endpoint allowlists, so they ARE pushed every deploy. Pulling one back
  # would launder a server-side privilege change into git as an automated
  # commit.
  'muso-ops-admin/config/'
)
# PULL (informational): the server owns the live version of top-level
# workspaces/*/{MEMORY,IDENTITY,HEARTBEAT,TOOLS}.md and workspaces/*/wiki/.
# The tracked-only rule plus NEVER_PULL is what actually decides.

# Count assertion (runs on every invocation, scheduled or not): eval the block
# out of this file's own source, independently count its entries, and fail
# closed on inequality or a count below the floor, so a mangled array can't
# silently turn the deny-list into a no-op. Mirrors pr-validate.yml's
# RSYNC_EXCLUDES guard.
NEVER_PULL_FLOOR=5
check_never_pull_declared() {
  local block declared
  block=$(sed -n '/^NEVER_PULL=(/,/^)$/p' "${BASH_SOURCE[0]}")
  # Pin the entries by content too: a net-neutral swap keeps the count.
  # (Precedent: the grep -qFx check on the muso-ops-admin include in deploy.sh.)
  local want
  for want in 'tests/' 'config/' 'audit/' 'secrets/' 'muso-ops-admin/config/'; do
    printf '%s\n' "$block" | grep -qFx -- "  '$want'" || {
      echo "NEVER_PULL is missing the required entry '$want'. Refusing to run." >&2
      exit 1
    }
  done
  declared=$(printf '%s\n' "$block" | grep -cE "^[[:space:]]*'" || true)
  if (( ${#NEVER_PULL[@]} != declared )) || (( ${#NEVER_PULL[@]} < NEVER_PULL_FLOOR )); then
    echo "NEVER_PULL declaration problem: ${#NEVER_PULL[@]} entries loaded, $declared declared, floor $NEVER_PULL_FLOOR. Refusing to run." >&2
    exit 1
  fi
}

is_never_pull() {
  local pat
  for pat in "${NEVER_PULL[@]}"; do
    [[ "/$1" == *"/$pat"* ]] && return 0
  done
  return 1
}

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
log()    { echo "[sync-from-server] $*"; }

# Single tempfile for the whole script run, cleaned up via trap so
# Ctrl-C / rsync failure / unexpected exit all leave a clean /tmp.
TMP=$(mktemp -t sync-from-server.XXXXXX)
ERR=$(mktemp -t sync-from-server-err.XXXXXX)
LIST=$(mktemp -t sync-from-server-list.XXXXXX)
trap 'rm -f "$TMP" "$ERR" "$LIST"' EXIT

check_never_pull_declared

# Bulk --apply can overwrite many files at once: refuse on a dirty tree.
# --only --apply is deliberately exempt (its whole point is one file beside
# other local edits).
if $APPLY && (( ${#ONLY[@]} == 0 )) && ! $ALLOW_DIRTY \
   && [[ -n "$(git -C "$HYDRA_ROOT" status --porcelain --untracked-files=no)" ]]; then
  red "Refusing bulk --apply: the git tree is dirty. Commit/stash first, use --only <path>, or pass --allow-dirty."
  exit 1
fi

# Shared tail of the two pull paths: summarise the itemize output.
report_transfers() {
  local n
  n=$(grep -cE '^[<>]f' "$TMP" || true)
  if (( n > 0 )); then
    if $APPLY; then yellow "  → $n file(s) pulled"; else yellow "  → $n file(s) would be pulled"; fi
  else
    green "  → repo already matches server (no changes)"
  fi
}

# Tracked-only transfer of one subdir. Candidates = git ls-files under the
# prefix, minus NEVER_PULL. Paths git tracks but the deploy never pushes are
# absent on node-8: rsync prints link_stat errors and exits 23, which is
# success ONLY if every stderr line is that missing-source shape.
pull_tracked() {
  local subdir="$1" mode="DRY-RUN" p total=0 kept=0 rc=0
  $APPLY && mode="APPLY"
  : > "$LIST"
  # ERR doubles as scratch here (rsync truncates it below). A failed ls-files
  # must exit, not look like "no drift".
  git -C "$HYDRA_ROOT" --literal-pathspecs ls-files -z -- "$subdir/" > "$ERR" \
    || { red "  git ls-files failed for $subdir/; refusing to report on an empty candidate set"; exit 1; }
  while IFS= read -r -d '' p; do
    total=$((total + 1))
    is_never_pull "$p" && continue
    printf '%s\0' "$p" >> "$LIST"
    kept=$((kept + 1))
  done < "$ERR"
  if (( total == 0 )) && [[ -d "$HYDRA_ROOT/$subdir" ]]; then
    red "  git tracks nothing under $subdir/ but the directory exists; refusing"
    exit 1
  fi
  log "Pulling $subdir/  ($mode): $kept tracked path(s), $((total - kept)) never-pull skipped"
  # --files-from implies --relative; no --delete, ever. --checksum so mtime
  # noise doesn't pollute the diff.
  # shellcheck disable=SC2086  # DRY_FLAG is empty or -n
  rsync -az $DRY_FLAG --checksum --itemize-changes --from0 --files-from="$LIST" \
       ${RSYNC_E[@]+"${RSYNC_E[@]}"} \
       "$SRC_HOST$DEPLOY_PATH/" \
       "$HYDRA_ROOT/" 2>"$ERR" | tee "$TMP" || rc=${PIPESTATUS[0]}
  if (( rc == 23 )); then
    local missing_re='^rsync: (\[sender\] )?link_stat ".*" failed: No such file or directory \(2\)$'
    local other_re='^rsync error: some files/attrs were not transferred \(see previous errors\) \(code 23\)'
    local missing other
    missing=$(grep -cE "$missing_re" "$ERR" || true)
    other=$(grep -vE "$missing_re|$other_re" "$ERR" || true)
    if [[ -z "$other" ]] && (( missing > 0 )); then
      yellow "  $missing path(s) absent on node-8 (tracked but never deployed) — skipped"
      rc=0
    fi
  fi
  if (( rc != 0 )); then
    cat "$ERR" >&2
    red "  rsync failed for $subdir (exit $rc)"
    exit 1
  fi
  cat "$ERR" >&2
  report_transfers
}

pull() {
  local subdir="$1"
  local mode="DRY-RUN"
  $APPLY && mode="APPLY"
  log "Pulling $subdir/  ($mode)"
  # No --delete: we never remove repo files based on server state.
  # --checksum so mtime noise doesn't pollute the diff.
  if rsync -az $DRY_FLAG --checksum --itemize-changes \
       ${RSYNC_E[@]+"${RSYNC_E[@]}"} \
       "$SRC_HOST$DEPLOY_PATH/$subdir/" \
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
    if is_never_pull "$p"; then
      red "  --only path '$p' is on the NEVER_PULL list; git is authoritative for it (deploy.sh pushes it every deploy) — edit it in git instead."
      exit 1
    fi
    # Exact tracked FILE only: a directory or glob would let rsync -a pull
    # untracked content beneath it.
    if [[ "$(git -C "$HYDRA_ROOT" --literal-pathspecs ls-files -z -- "$p" | tr -d '\0')" != "$p" ]]; then
      red "  --only path '$p' is not tracked by git (sync-back pulls tracked files only)"
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
         ${RSYNC_E[@]+"${RSYNC_E[@]}"} \
         "$SRC_HOST$DEPLOY_PATH/./$p" \
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
    skills)     pull_tracked "skills-all" ;;
    workspaces) pull_tracked "workspaces" ;;
    audit)      pull "audit" ;;
    all)        pull_tracked "skills-all"; pull_tracked "workspaces" ;;
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
