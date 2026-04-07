#!/usr/bin/env bash
set -euo pipefail

# HYDRA Deploy Script
# ===================
# CD entrypoint: validate config, sync to Node 8, restart gateway, smoke test.
# Supports targeted deployment: --target main|edge|dev|all
#
# Quick start (laptop): you probably need
#     export NODE8_IP=40.160.32.80      # public IP, vrack default won't reach
#     # SSH_KEY is auto-detected — see the SSH config block below for details
# Then: ./scripts/deploy.sh [--target main|edge|dev|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

# Detect if we're running on Node 8 (the HYDRA host)
if hostname | grep -q 'node-8\|ovh-node-8' || [ -d "/opt/hydra/workspaces" ]; then
  HYDRA_LOCAL=true
else
  HYDRA_LOCAL=false
fi

# ─── SSH connection: which key, which IP, why? ────────────────────
#
# There are TWO valid configurations for reaching node-8 and they don't
# share defaults. The script auto-picks one and lets you override either
# half via env var.
#
#   ┌────────────────┬────────────────────┬──────────────────────┐
#   │ Where you are  │ SSH key            │ NODE8_IP             │
#   ├────────────────┼────────────────────┼──────────────────────┤
#   │ CI / vrack     │ ~/.ssh/ovh_muso    │ 10.0.0.8  (vrack)    │
#   │ Laptop / WAN   │ ~/.ssh/nick_ovh    │ 40.160.32.80 (public)│
#   └────────────────┴────────────────────┴──────────────────────┘
#
# SSH_KEY: auto-detected. We probe `~/.ssh/ovh_muso` first (CI's key,
# also present on most operator machines that have ever deployed) and
# fall back to `~/.ssh/nick_ovh` (laptop-only). Override with:
#     export SSH_KEY=~/.ssh/your-key
#
# NODE8_IP: NOT auto-detected. The vrack IP (10.0.0.8) is the default
# because that's what CI uses, and probing both addresses at every
# deploy would add 5-10s of latency. Laptop users add this to their
# shell rc:
#     export NODE8_IP=40.160.32.80
#
# Why no shared defaults file? Because there's no central place to put
# it that's both checked into git AND machine-specific. Env vars are
# the lowest-friction config surface that handles "different defaults
# for different humans". sync-from-server.sh mirrors this exact logic.
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
NAMESPACE="${NAMESPACE:-hydra}"
SLACK_WEBHOOK="${HYDRA_SLACK_WEBHOOK:-}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# SSH options used by every ssh/rsync invocation in this script.
# - StrictHostKeyChecking=no: server is in our control, key churn is normal
# - ConnectTimeout=10:        fail fast instead of hanging on a slow host
# - BatchMode=yes:            never prompt for password — fail loudly if key auth doesn't work
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
SSH_OPTS_STR="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# Use C locale for sort/comm consistency. Drift detection compares two
# sorted file lists with `comm`, which silently mis-classifies if the
# producer's locale collation differs from the consumer's.
export LC_ALL=C

# Parse --target flag
TARGET="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ -z "${2:-}" ]] && { echo "Error: --target requires a value (main|edge|dev|all)"; exit 1; }
      TARGET="$2"; shift 2 ;;
    main|edge|dev|all) TARGET="$1"; shift ;;
    *) echo "Usage: deploy.sh [--target main|edge|dev|all]"; exit 1 ;;
  esac
done

# Validate target value (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|dev|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|dev|all"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; notify_slack ":x: HYDRA deploy FAILED ($TARGET): $*"; exit 1; }
needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }

notify_slack() {
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

log "Deploy target: $TARGET"

# -------------------------------------------------------------------
# Mutual exclusion: only one deploy at a time per source tree.
# -------------------------------------------------------------------
# Two concurrent deploys would race the .deployed-sha baseline (last
# writer wins) and could each pass Step 0 against the same baseline,
# missing the other's changes. Portable mkdir-based locking — mkdir is
# atomic on every POSIX FS, and unlike flock it works on macOS without
# extra packages.
#
# SCOPE: this lock is per-host. Two operators deploying from two
# different machines each acquire their own local lock. The actual
# cross-host serialization happens server-side via the .deployed-sha
# baseline + Step 0 drift check — one of the two will fail drift and
# refuse. The mkdir lock just prevents one operator's machine from
# racing itself.
#
# Stale-lock recovery: a SIGKILL'd or crashed deploy leaves $LOCK_DIR
# behind. The next run inspects $LOCK_DIR/pid: if the recorded PID is
# dead, we clear and retake. The pid file is written AFTER mkdir (one
# bash line later), so a SIGKILL in that microsecond window leaves an
# empty $LOCK_DIR with no pid file — that case is handled below as
# "PID: unknown" and reported clearly so the operator knows to clean up.
LOCK_DIR="${TMPDIR:-/tmp}/hydra-deploy.lock.d"
mkdir_err=$(mkdir "$LOCK_DIR" 2>&1)
mkdir_rc=$?
if (( mkdir_rc != 0 )); then
  # Distinguish "lock dir already exists" (EEXIST → check for stale)
  # from other failures (permission denied, ENOSPC, EROFS, etc.).
  # Without this distinction, all of those fall into the "another
  # deploy running" branch with a misleading error.
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail "could not create deploy lock dir at $LOCK_DIR: $mkdir_err"
  fi
  # Lock dir exists. Try stale-PID recovery.
  if [[ -f "$LOCK_DIR/pid" ]]; then
    holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    # Validate the pid is a positive integer before passing to kill -0,
    # so a corrupted/empty pid file doesn't get misinterpreted.
    if [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
      fail "another deploy is already running (lock: $LOCK_DIR, holder PID: $holder_pid)"
    fi
    log "  stale deploy lock found (holder PID '$holder_pid' is dead or invalid) — clearing"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || fail "failed to re-acquire deploy lock after clearing stale: $LOCK_DIR"
  else
    # Lock dir exists but pid file does not. Either another deploy is
    # mid-acquisition (microsecond race window between mkdir and
    # echo $$ > pid) or a previous deploy was SIGKILL'd in that window.
    # Refuse rather than guess — manual `rm -rf $LOCK_DIR` is the fix.
    fail "deploy lock at $LOCK_DIR exists but has no pid file (another deploy mid-acquisition, or a prior deploy was killed before writing pid). If you're sure no deploy is running, remove it manually: rm -rf $LOCK_DIR"
  fi
fi
echo $$ > "$LOCK_DIR/pid"
# Arm the cleanup trap ONLY after we successfully claim the lock.
# If we'd armed it earlier and then fail()'d during the EEXIST check,
# the trap would wipe the OTHER deploy's lock dir on our exit.
trap 'rm -rf "$LOCK_DIR"' EXIT

# -------------------------------------------------------------------
# Ensure git hooks are activated for this checkout.
# -------------------------------------------------------------------
# setup-hooks.sh is idempotent: it just sets core.hooksPath and chmods.
# Running it from deploy.sh guarantees that anyone who deploys from a
# fresh clone gets the pre-commit guard active without a manual step.
#
# We don't `fail` on hook setup failure (idempotent activation
# shouldn't block a deploy) — but we DO surface a visible warning
# instead of swallowing the error with `|| true`. The whole point of
# setting hooks up here is "guarantee they're active"; silently
# failing would break that guarantee while pretending it succeeded.
if [[ -x "$SCRIPT_DIR/setup-hooks.sh" ]] && [[ -d "$HYDRA_ROOT/.git" ]]; then
  if ! hook_setup_out=$("$SCRIPT_DIR/setup-hooks.sh" 2>&1); then
    log "  WARNING: setup-hooks.sh failed — pre-commit guard may not be active."
    log "  Run manually to investigate: scripts/setup-hooks.sh"
    echo "$hook_setup_out" | sed 's/^/    /'
  fi
fi

# -------------------------------------------------------------------
# RSYNC_EXCLUDES (shared by Step 0 drift check, Step 4a pre-flight, Step 4b push)
# -------------------------------------------------------------------
# Each path here is server-owned state that --delete would otherwise
# silently wipe on every deploy. Confirmed by running pre-flight against
# the live server (2026-04-07).
RSYNC_EXCLUDES=(
  # Repo hygiene
  --exclude='.git'
  --exclude='hydra docs/'
  --exclude='secrets/'
  # Drift baseline file (server-managed, not part of the repo)
  --exclude='.deployed-sha'
  # Workspace runtime data (real, accumulating data)
  --exclude='workspaces/*/memory/'
  --exclude='workspaces/*/api-logs/'
  # Generated reports (CSVs, PDFs, JSON dumps from agent runs).
  # Convention: agents that produce reports for human consumption
  # write them to workspaces/<agent>/reports/<filename>. They're
  # server-owned (often contain customer PII like emails or invoice
  # data) and must never propagate into git. Established 2026-04-07
  # after the finance agent's q1_2026_sales_tax_report.csv triggered
  # a pre-flight block during deploy testing.
  --exclude='workspaces/*/reports/'
  # Workspace runtime state (regenerated by openclaw at boot, but the
  # data on disk is more current than the repo seeds, so we leave it.)
  --exclude='workspaces/*/.openclaw/'
  --exclude='workspaces/*/IDENTITY.md'
  --exclude='workspaces/*/HEARTBEAT.md'
  # Audit logs (per-workspace memory snapshots, conversation logs)
  --exclude='audit/'
  # Manual audit backup (pre-existing on node-8 at /opt/hydra/audit-local-backup/,
  # 8.6MB of 2026-04-07 memory snapshots created during the audit/ migration).
  # Treated like audit/ — server-owned, not synced from repo.
  --exclude='audit-local-backup/'
  # Plugin install artifacts (server runs npm install in-place)
  --exclude='plugins/*/node_modules/'
  --exclude='plugins/*/package-lock.json'
)

# -------------------------------------------------------------------
# Step 0: Drift check (deploy-equivalent of `git pull` before `git push`)
# -------------------------------------------------------------------
# git push refuses when remote has commits the local doesn't. We mirror
# that here using a tiny baseline file on the server: /opt/hydra/.deployed-sha
# (written after every successful deploy, AFTER smoke test passes).
# It records the git SHA the server was last synced from.
#
# Drift logic:
#   intended_changes = files this repo touched since LAST_SHA
#                      (committed + staged + unstaged, in one git diff)
#   would_update     = files rsync says have different content vs server
#   drift            = would_update − intended_changes
#
# If drift is non-empty, the server has files we don't account for —
# someone edited /opt/hydra/ directly. Refuse and tell the user to pull
# with scripts/sync-from-server.sh.
#
# Bypass:
#   HYDRA_FORCE=1            skip both this check AND Step 4a pre-flight
#   HYDRA_SKIP_DRIFT_CHECK=1 skip only Step 0; Step 4a pre-flight still runs
#                            (use when SSH baseline read is genuinely broken)
log "Step 0/9: Drift check (server vs last-deployed SHA)..."
drift_check_against_baseline() {
  if [[ "${HYDRA_FORCE:-0}" == "1" ]]; then
    log "  Skipped (HYDRA_FORCE=1 set)"
    return 0
  fi
  if [[ "${HYDRA_SKIP_DRIFT_CHECK:-0}" == "1" ]]; then
    log "  Skipped (HYDRA_SKIP_DRIFT_CHECK=1 set; Step 4a pre-flight will still run)"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    log "  git not found — skipping drift check"
    return 0
  fi
  if ! git -C "$HYDRA_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "  not a git checkout — skipping drift check"
    return 0
  fi

  # 1. Read baseline SHA from server.
  # Distinguish three cases via a single SSH round-trip:
  #   - file exists & readable    → its content
  #   - file absent (first deploy) → sentinel "__ABSENT__"
  #   - ssh failed                 → ssh non-zero exit → fail closed
  # Single-call form saves a round-trip vs probe-then-cat AND closes
  # a tiny race where the file could be deleted between the two calls.
  local last_sha=""
  if $HYDRA_LOCAL; then
    if [[ -f "$DEPLOY_PATH/.deployed-sha" ]]; then
      last_sha=$(cat "$DEPLOY_PATH/.deployed-sha")
    fi
  else
    local read_rc=0 read_out=""
    read_out=$(ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "if [ -f '$DEPLOY_PATH/.deployed-sha' ]; then cat '$DEPLOY_PATH/.deployed-sha'; else echo __ABSENT__; fi" \
      2>&1) || read_rc=$?
    if (( read_rc != 0 )); then
      log "  ssh failed reading drift baseline (rc=$read_rc):"
      echo "$read_out" | sed 's/^/    /'
      fail "could not reach node-8 to read drift baseline. Fix SSH or set HYDRA_SKIP_DRIFT_CHECK=1 explicitly."
    fi
    if [[ "$read_out" == "__ABSENT__" ]]; then
      last_sha=""
    else
      last_sha="$read_out"
    fi
  fi
  last_sha=$(echo "$last_sha" | tr -d '[:space:]')

  if [[ -z "$last_sha" ]]; then
    log "  No .deployed-sha on server (first deploy with this guard)"
    log "  → drift check skipped, will be enabled after this deploy succeeds"
    return 0
  fi

  # Validate format. A garbled value (rare — would mean someone edited the
  # baseline file by hand) should not silently degrade to "skip check".
  if ! [[ "$last_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "baseline .deployed-sha on server is not a valid 40-char hex SHA: '$last_sha'. Inspect /opt/hydra/.deployed-sha and remove it if corrupted."
  fi

  if ! git -C "$HYDRA_ROOT" cat-file -e "$last_sha^{commit}" 2>/dev/null; then
    log "  Server reports last_sha=$last_sha but it's not in this repo's git history"
    log "  → can't compute drift baseline. Run: git fetch && retry."
    log "  Skipping drift check this run; pre-flight (Step 4a) will still catch deletions."
    return 0
  fi

  log "  Baseline: $last_sha (server's last successful deploy)"

  # 2. Files we intentionally changed since baseline.
  # `git diff --name-only <commit>` (single arg) covers committed +
  # staged + unstaged in one shot. Simpler than the prior two-diff
  # version that unioned `diff $last_sha HEAD` with `diff HEAD` —
  # both compute the same set, but one call is less to read and one
  # less subshell to spawn.
  #
  # NOTE: this also includes files DELETED locally since baseline,
  # which is what we want — a local delete that the deploy will
  # propagate to the server is "intended", not drift.
  local intended
  intended=$(git -C "$HYDRA_ROOT" diff --name-only "$last_sha" | sort -u | sed '/^$/d')

  # 3. Files rsync would push (content differs between repo and server).
  # Capture rsync exit code separately — `|| true` would let an SSH
  # failure look identical to "clean", which is the exact silent-failure
  # this whole step exists to prevent.
  local dry_out dry_rc=0
  if $HYDRA_LOCAL; then
    dry_out=$(rsync -an --checksum --itemize-changes \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  else
    dry_out=$(rsync -azn --checksum --itemize-changes \
      -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  fi
  if (( dry_rc != 0 )); then
    log "  rsync dry-run failed (rc=$dry_rc):"
    echo "$dry_out" | sed 's/^/    /'
    fail "drift check rsync failed — refusing to proceed without a clean baseline (override: HYDRA_SKIP_DRIFT_CHECK=1)"
  fi

  # Parse rsync itemize lines. Format is `<flags> <filename>` where flags
  # are 11 chars: YXcstpoguax. We want lines where:
  #   - col 2 (X) = 'f'   → it's a file, not a dir
  #   - col 3 (c) = 'c'   → checksum differs (existing file modified) OR
  #   - col 4 (s) = 's'   → size differs
  #
  # SCOPE NOTE: This catches CONTENT DRIFT on files that exist on both
  # sides. It does NOT catch:
  #   - new files server-only (caught by Step 4a's `*deleting` path
  #     when --delete dry-run sees server-only files)
  #   - new files local-only (those are just "new content to push" —
  #     not drift, not blocked, and including them would false-positive
  #     on every untracked local file: .DS_Store, .worktrees/, etc.)
  #
  # Filename can contain spaces, so strip the first whitespace-delimited
  # token (the flags) and print the rest verbatim.
  local would_update
  would_update=$(echo "$dry_out" \
    | awk '{
        if (substr($0,2,1)=="f" && (substr($0,3,1)=="c" || substr($0,4,1)=="s")) {
          sub(/^[^[:space:]]+[[:space:]]+/, "")
          print
        }
      }' \
    | sort -u | sed '/^$/d')

  # 4. drift = would_update − intended (set difference; both sides sorted under LC_ALL=C)
  local drift
  drift=$(comm -23 <(echo "$would_update") <(echo "$intended"))

  if [[ -z "$drift" ]]; then
    log "  Clean — every file rsync would update is accounted for in local commits/edits"
    return 0
  fi

  cat <<DRIFT_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — server has edits this repo doesn't account for
================================================================================

WHAT THIS MEANS:
  Like \`git push\` refusing when the remote has moved ahead, deploy.sh
  just compared the server (/opt/hydra/, last synced from commit
  $last_sha) against your local repo. The files below differ in
  content, but they are NOT in the diff between the baseline and HEAD —
  meaning you didn't edit them locally. Someone edited them DIRECTLY
  on node-8.

  Pushing now would silently overwrite their work. There is no backup.

DRIFTED FILES (server has edits not in any local commit):
$(echo "$drift" | sed 's/^/  /')

WHAT TO DO (the only safe path, mirrors \`git pull --rebase\`):
  1. Pull the server-side edits into your local repo:
       scripts/sync-from-server.sh skills --apply       # if drift is in skills-all/
       scripts/sync-from-server.sh workspaces --apply   # if drift is in workspaces/
       scripts/sync-from-server.sh audit --apply        # if drift is in audit/
       # or pull a single file directly (uses same defaults as deploy.sh):
       scp -i "\$SSH_KEY" "\$NODE8_USER@\$NODE8_IP:$DEPLOY_PATH/<path>" ./<path>
  2. Review what came down:
       git status
       git diff -- <path>
  3. Commit the pulled changes (this advances your HEAD past the
     server's edits, so the next drift check sees them as accounted for):
       git add -A
       git commit -m "chore: pull <description> from node-8"
  4. Re-run deploy. Step 0 should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  Almost never. This is the equivalent of \`git push --force\` over a
  teammate's commits. Only do it if:
    - You have explicit confirmation from whoever made the edits that
      they want them discarded, AND
    - You have inspected each drifted file and verified it's safe.

  If you can't satisfy both, don't HYDRA_FORCE=1.

  Skip just the drift check but keep pre-flight + post-deploy guards:
    HYDRA_SKIP_DRIFT_CHECK=1 ./scripts/deploy.sh
  (Use only when SSH to node-8 is broken in a way that breaks the
  baseline read, not as a way to ignore drift.)
================================================================================
DRIFT_BRIEFING
  fail "drift detected against baseline $last_sha (override: HYDRA_FORCE=1)"
}
drift_check_against_baseline

# -------------------------------------------------------------------
# Step 1: Validate config files
# -------------------------------------------------------------------
log "Step 1/9: Validating config files..."

if needs_target "main"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-main.json" >/dev/null 2>&1 || fail "openclaw-main.json is not valid JSON"
  log "  openclaw-main.json is valid JSON."
fi
if needs_target "edge"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-edge.json" >/dev/null 2>&1 || fail "openclaw-edge.json is not valid JSON"
  log "  openclaw-edge.json is valid JSON."
fi
if needs_target "dev"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-dev.json" >/dev/null 2>&1 || fail "openclaw-dev.json is not valid JSON"
  log "  openclaw-dev.json is valid JSON."
fi

# Run drift check when deploying all or multiple profiles
if [[ "$TARGET" == "all" ]] || [[ "$TARGET" == *","* ]]; then
  "$SCRIPT_DIR/validate-shared-config.sh" || fail "Shared config drift detected"
fi

# -------------------------------------------------------------------
# Step 2: Validate SOUL.md files
# -------------------------------------------------------------------
log "Step 2/9: Validating SOUL.md files..."
validate_souls() {
  local config="$1"
  local label="$2"
  local agents
  agents=$(python3 -c "
import json, os
with open('$config') as f:
    c = json.load(f)
defaults_ws = c.get('agents', {}).get('defaults', {}).get('workspace', '')
for a in c.get('agents', {}).get('list', []):
    ws = a.get('workspace', defaults_ws)
    print(a['id'] + ':' + os.path.basename(ws))
")
  local missing=()
  for entry in $agents; do
    local agent_id="${entry%%:*}"
    local ws_dir="${entry##*:}"
    [[ -z "$ws_dir" ]] && ws_dir="$agent_id"
    if [[ ! -f "$HYDRA_ROOT/workspaces/$ws_dir/SOUL.md" ]]; then
      missing+=("$agent_id")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing SOUL.md for $label agents: ${missing[*]}"
  fi
}

if needs_target "main"; then validate_souls "$HYDRA_ROOT/openclaw-main.json" "main"; fi
if needs_target "edge"; then validate_souls "$HYDRA_ROOT/openclaw-edge.json" "edge"; fi
if needs_target "dev"; then validate_souls "$HYDRA_ROOT/openclaw-dev.json" "dev"; fi
log "  All SOUL.md files present."

# -------------------------------------------------------------------
# Step 3: Validate tool-deny-lists.yaml
# -------------------------------------------------------------------
log "Step 3/9: Validating tool-deny-lists.yaml (deny lists can only grow)..."
DENY_LIST="$HYDRA_ROOT/policies/tool-deny-lists.yaml"

if [[ ! -f "$DENY_LIST" ]]; then
  fail "policies/tool-deny-lists.yaml not found"
fi

if git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" >/dev/null 2>&1; then
  PREV_TOOLS=$(git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" | grep -E '^\s+- ' | sed 's/^[[:space:]]*- //' | sort -u)
  CURR_TOOLS=$(grep -E '^\s+- ' "$DENY_LIST" | sed 's/^[[:space:]]*- //' | sort -u)
  REMOVED=$(comm -23 <(echo "$PREV_TOOLS") <(echo "$CURR_TOOLS"))
  if [[ -n "$REMOVED" ]]; then
    fail "Deny list SHRUNK. Removed tools: $REMOVED"
  fi
fi
log "  Deny lists validated (only growth detected)."

# -------------------------------------------------------------------
# Step 4: rsync repo to Node 8
# -------------------------------------------------------------------
# RSYNC_EXCLUDES is defined near the top of the file (hoisted because
# Step 0 also uses it for the drift check baseline computation).

# -------------------------------------------------------------------
# Step 4a: Pre-flight drift check
# -------------------------------------------------------------------
# Abort if the server has content in skills-all/ that the repo doesn't —
# that means someone edited skills directly on the server and a deploy
# would silently wipe their work. Also surface any suspicious deletions
# inside workspaces/ or skills-all/.
# Bypass: HYDRA_FORCE=1 ./deploy.sh ...
log "Step 4a/9: Pre-flight drift check..."
preflight_drift_check() {
  local dry_out dry_rc=0
  if $HYDRA_LOCAL; then
    dry_out=$(rsync -an --delete --checksum --itemize-changes \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  else
    dry_out=$(rsync -azn --delete --checksum --itemize-changes \
      -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  fi
  if (( dry_rc != 0 )); then
    log "  rsync dry-run failed (rc=$dry_rc):"
    echo "$dry_out" | sed 's/^/    /'
    fail "pre-flight rsync failed — refusing to proceed without a clean dry-run (no override; fix SSH first)"
  fi

  # Content drift in skills-all/: itemize cols are YXcstpoguax.
  # We require col 2 = 'f' (file, not dir) AND (col 3 = 'c' or col 4 = 's').
  # Without the col-2 'f' filter we'd false-match directory entries with
  # `cd+++++++++` flags. The Step 0 awk uses the same shape — keeping
  # them symmetric so a future bug fix to one applies to the other.
  local skills_drift
  skills_drift=$(echo "$dry_out" \
    | awk '{ if (substr($0,2,1)=="f" && (substr($0,3,1)=="c" || substr($0,4,1)=="s")) print }' \
    | grep -F 'skills-all/' || true)

  # Deletions that --delete would perform on the server
  local deletions
  deletions=$(echo "$dry_out" | grep '^\*deleting' || true)

  if [[ -n "$skills_drift" ]]; then
    cat <<DRIFT_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — skills-all/ content drift detected on node-8
================================================================================

WHAT THIS MEANS:
  Someone (often Fede) edited files under /opt/hydra/skills-all/ DIRECTLY
  on node-8. The repo does NOT have those edits. If you push past this
  check, the rsync --delete will permanently OVERWRITE their work and
  there is NO backup. Skill files are how Muso's agents do real work —
  losing them silently breaks production.

DRIFTED FILES (server has changes the repo doesn't):
$(echo "$skills_drift" | sed 's/^/  /')

THE ONLY SAFE FIX (do this, in order):
  1. scripts/sync-from-server.sh skills           # dry-run, see what's there
  2. scripts/sync-from-server.sh skills --apply   # actually pull into repo
  3. git status skills-all/ && git diff skills-all/
  4. Read each diff. If the changes are intentional, commit them:
       git add skills-all/
       git commit -m "chore: pull skill edits from node-8"
  5. Re-run deploy. Pre-flight should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  - You have explicit confirmation from the editor that they want their
    changes discarded, AND
  - You have verified each file in the list above is safe to overwrite,
    AND
  - You understand this destroys the work permanently.

  If ANY of those is not true, STOP. Run sync-from-server.sh first.
================================================================================
DRIFT_BRIEFING
    if [[ "${HYDRA_FORCE:-0}" != "1" ]]; then
      fail "skills-all drift — refusing to deploy (override: HYDRA_FORCE=1)"
    fi
    log "  HYDRA_FORCE=1 set — proceeding despite drift (will overwrite server)"
  fi

  if [[ -n "$deletions" ]]; then
    local del_count sus_count
    del_count=$(printf '%s\n' "$deletions" | grep -c .)

    # Deletions inside workspaces/ or skills-all/ are likely real data
    # (IDENTITY.md, workspace-state.json, custom skills) — these get a
    # full briefing. Other deletions just get a heads-up.
    local suspicious
    suspicious=$(echo "$deletions" | grep -E 'workspaces/|skills-all/' || true)
    sus_count=$(printf '%s\n' "$suspicious" | grep -c . || true)

    if [[ -n "$suspicious" ]]; then
      local sus_overflow=""
      if (( sus_count > 30 )); then
        sus_overflow="  ... ($((sus_count - 30)) more)"
      fi
      cat <<DEL_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — sync would delete server state
================================================================================

WHAT THIS MEANS:
  rsync --delete is about to remove files from /opt/hydra/ that exist
  on the server but NOT in the repo. The files below sit under
  workspaces/ or skills-all/, which means they're likely either:
    - real accumulated data (dispute trackers, audit logs, scan results)
    - runtime state generated by openclaw on the server
    - skills someone added directly on node-8 without committing

  Wiping any of these silently breaks production. There is no backup.

FILES THAT WOULD BE DELETED ($del_count total, suspicious shown):
$(echo "$suspicious" | head -30 | sed 's/^/  /')
$sus_overflow

THE ONLY SAFE FIX (do this, in order):
  1. For each path above, decide:
     (a) Is it real data? → Pull it into the repo:
           scripts/sync-from-server.sh workspaces --apply   # for workspaces/*
           scripts/sync-from-server.sh skills --apply       # for skills-all/*
           scripts/sync-from-server.sh audit --apply        # for audit/*
         Then commit.
     (b) Is it runtime state we want server-owned? → Add an --exclude
         line to RSYNC_EXCLUDES at the top of scripts/deploy.sh (it's
         hoisted there because Step 0 also reads it) so rsync stops
         trying to manage it. Then re-run pre-commit:
           bash .githooks/pre-commit
         The Check 2 list (required_excludes) in .githooks/pre-commit
         must also be updated so future deploys keep enforcing it.
  2. Re-run deploy. Pre-flight should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  - You've individually verified every file in the list is regenerable
    or genuinely garbage, AND
  - You're certain no human or agent will need it again.

  If you're not sure, STOP. Pull first.
================================================================================
DEL_BRIEFING
      if [[ "${HYDRA_FORCE:-0}" != "1" ]]; then
        fail "refusing to delete server state (override: HYDRA_FORCE=1)"
      fi
      log "  HYDRA_FORCE=1 set — proceeding despite suspicious deletions"
    else
      # Non-suspicious deletions: just log them and continue
      log "  ⚠ sync will delete $del_count file(s) on server (none under workspaces/ or skills-all/):"
      echo "$deletions" | head -10 | sed 's/^/      /'
      (( del_count > 10 )) && log "      ... ($((del_count - 10)) more)"
    fi
  fi

  log "  Pre-flight clean."
}
preflight_drift_check

# -------------------------------------------------------------------
# Step 4b: rsync repo to Node 8
# -------------------------------------------------------------------
if $HYDRA_LOCAL; then
  log "Step 4b/9: Local sync (running on Node 8)..."
  rsync -a --delete \
    "${RSYNC_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$DEPLOY_PATH/"
  log "  Config synced locally to $DEPLOY_PATH/"
else
  log "Step 4b/9: Remote sync to Node 8 ($NODE8_IP)..."
  rsync -azP --delete \
    -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
    "${RSYNC_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
  log "  Config synced to $NODE8_IP:$DEPLOY_PATH/"
fi

# Fix script permissions (rsync doesn't preserve +x from git)
chmod +x "$DEPLOY_PATH"/scripts/*.sh "$DEPLOY_PATH"/scripts/*.py 2>/dev/null || true
log "  Script permissions fixed"

# NOTE: drift baseline (.deployed-sha) is updated AFTER Step 7 (smoke test
# passes), not here. Writing it now would advance the baseline before we
# know the deploy actually works — a half-failed deploy would leave a
# stale baseline that masks real drift on the next run.

# Sync per-profile configs to profile state dirs
log "  Syncing profile configs..."
if [ "$TARGET" = "main" ] || [ "$TARGET" = "all" ]; then
  mkdir -p /root/.openclaw-main
  cp "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw-main/openclaw.json
  cp "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw/openclaw.json
  log "  Synced main profile config (+ default openclaw.json)"
fi
if [ "$TARGET" = "edge" ] || [ "$TARGET" = "all" ]; then
  mkdir -p /root/.openclaw-edge
  cp "$DEPLOY_PATH/openclaw-edge.json" /root/.openclaw-edge/openclaw.json
  log "  Synced edge profile config"
fi
if [ "$TARGET" = "dev" ] || [ "$TARGET" = "all" ]; then
  mkdir -p /root/.openclaw-dev
  cp "$DEPLOY_PATH/openclaw-dev.json" /root/.openclaw-dev/openclaw.json
  log "  Synced dev profile config"
fi

# -------------------------------------------------------------------
# Step 5: Post-sync setup on Node 8
# -------------------------------------------------------------------
log "Step 5/9: Running post-sync setup..."

run_on_node8() {
  if $HYDRA_LOCAL; then
    bash -c "$1"
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" "$1"
  fi
}

# Post-sync inline (runs locally on node-8 or via SSH)
bash << 'POSTSYNC'
set -euo pipefail

# AWS credentials (from K8s secret or pre-configured)
if [ ! -f ~/.aws/credentials ]; then
  echo "  Setting up AWS credentials..."
  mkdir -p ~/.aws
  AWS_KEY=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d)
  AWS_SECRET=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d)
  AWS_ROLE=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_ROLE_ARN}' 2>/dev/null | base64 -d)
  if [ -n "$AWS_KEY" ]; then
    cat > ~/.aws/credentials << CEOF
[plaque]
aws_access_key_id = ${AWS_KEY}
aws_secret_access_key = ${AWS_SECRET}
CEOF
    cat > ~/.aws/config << CEOF
[default]
region = us-west-2
role_arn = ${AWS_ROLE}
source_profile = plaque

[profile plaque]
region = us-west-2
CEOF
    chmod 600 ~/.aws/credentials
    echo "  AWS credentials configured."
  else
    echo "  WARNING: aws-hydra-readonly secret not found — skipping AWS setup."
  fi
fi

# Ensure GOG_KEYRING_PASSWORD is set for gog CLI
if ! grep -q "GOG_KEYRING_PASSWORD" /root/.bashrc 2>/dev/null; then
  GOG_PW=$(kubectl get secret -n hydra hydra-service-tokens -o jsonpath='{.data.GOG_KEYRING_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -n "$GOG_PW" ]; then
    echo "export GOG_KEYRING_PASSWORD='${GOG_PW}'" >> /root/.bashrc
    echo "  GOG keyring password set in .bashrc"
  fi
fi

# Note: mention gate patch (patch-openclaw-mention-gate.sh) removed — no longer needed on OpenClaw 2026.4.2+

# Sync cron jobs from repo (preserve live state)
if [ -f /opt/hydra/cron-jobs.json ]; then
  LIVE_CRON="/root/.openclaw/cron/jobs.json"
  if [ -f "$LIVE_CRON" ]; then
    python3 -c "
import json
with open('/opt/hydra/cron-jobs.json') as f:
    repo = json.load(f)
with open('$LIVE_CRON') as f:
    live = json.load(f)
live_states = {j['name']: j.get('state', {}) for j in live.get('jobs', [])}
for j in repo.get('jobs', []):
    if j['name'] in live_states:
        j['state'] = live_states[j['name']]
with open('$LIVE_CRON', 'w') as f:
    json.dump(repo, f, indent=2)
print(f'  Synced {len(repo.get(\"jobs\", []))} cron jobs (preserved live state)')
"
  else
    cp /opt/hydra/cron-jobs.json "$LIVE_CRON"
    echo "  Deployed cron jobs (fresh install)"
  fi
fi

# Use local embeddings for memory search on main profile
python3 -c "
import json
cfg = '/root/.openclaw/main/openclaw.json'
with open(cfg) as f:
    c = json.load(f)
defaults = c.setdefault('agents', {}).setdefault('defaults', {})
defaults['memorySearch'] = {'enabled': True, 'provider': 'local'}
c.get('models', {}).get('providers', {}).pop('openai', None)
with open(cfg, 'w') as f:
    json.dump(c, f, indent=2)
print('  Memory search: local embeddings (no OpenAI)')
"

# Patch Gmail plugin (main profile only)
GMAIL_CHANNEL="/root/.openclaw/extensions/openclaw-gmail/src/channel.ts"
if [ -f "$GMAIL_CHANNEL" ]; then
  if ! grep -q "describeMessageTool" "$GMAIL_CHANNEL"; then
    sed -i 's/listActions: () => \["send"\],/listActions: () => ["send"],\n    describeMessageTool: () => ({ actions: ["send"], capabilities: ["send"] }),/' "$GMAIL_CHANNEL"
    echo "  Patched Gmail plugin describeMessageTool"
  fi
fi

GMAIL_MONITOR="/root/.openclaw/extensions/openclaw-gmail/src/monitor.ts"
if [ -f "$GMAIL_MONITOR" ]; then
  if grep -q 'account.backend !== "api" && !(await GogGmailClient.checkExists())' "$GMAIL_MONITOR" && ! grep -q "PATCHED" "$GMAIL_MONITOR"; then
    sed -i 's|if (account.backend !== "api" && !(await GogGmailClient.checkExists())) {|if (false \&\& account.backend !== "api" \&\& !(await GogGmailClient.checkExists())) { // PATCHED: skip gog check|' "$GMAIL_MONITOR"
    echo "  Patched Gmail monitor gog CLI check"
  fi
  if grep -q "^  await ensureQuarantineLabel(client, log);" "$GMAIL_MONITOR"; then
    sed -i '/^  await ensureQuarantineLabel(client, log);/c\  try { await ensureQuarantineLabel(client, log); } catch (e) { log.warn(`Quarantine label setup failed: ${String(e)}`); }' "$GMAIL_MONITOR"
    sed -i '/^  await pruneGmailSessions(account, log);/c\  try { await pruneGmailSessions(account, log); } catch (e) { log.warn(`Prune failed: ${String(e)}`); }' "$GMAIL_MONITOR"
    echo "  Patched Gmail monitor init resilience"
  fi
fi
POSTSYNC

log "  Post-sync setup complete."

# -------------------------------------------------------------------
# Step 6: Restart targeted gateway(s)
# -------------------------------------------------------------------
log "Step 6/9: Restarting OpenClaw Gateway ($TARGET)..."
restart_gateway() {
  local service="$1"
  local cmd="systemctl restart $service"
  if $HYDRA_LOCAL; then
    eval "$cmd"
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" "$cmd"
  fi
  # Gateway takes ~12s to start (loads all agents + plugins). Poll up to 30s.
  for i in $(seq 1 15); do
    sleep 2
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log "  $service restarted successfully (${i}x2s)."
      return 0
    fi
  done
  fail "Failed to restart $service (timed out after 30s)"
}

if needs_target "main"; then restart_gateway "openclaw-gateway-main"; fi
if needs_target "edge"; then restart_gateway "openclaw-gateway-edge"; fi
if needs_target "dev"; then restart_gateway "openclaw-gateway-dev"; fi

# -------------------------------------------------------------------
# Step 7: Run smoke test
# -------------------------------------------------------------------
log "Step 7/9: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh" "$TARGET"; then
  fail "Smoke test failed after deploy"
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Update drift baseline (only after smoke test passed).
# -------------------------------------------------------------------
# Step 0 of the next deploy reads this file to know what "baseline" to
# compare against when detecting server-side edits. Writing here (not
# after Step 4b) means a half-failed deploy never advances the baseline
# past a SHA the server isn't actually running — the equivalent of
# `git push` only updating remote refs after the push succeeds.
if command -v git >/dev/null 2>&1 \
   && git -C "$HYDRA_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  DEPLOYED_SHA=$(git -C "$HYDRA_ROOT" rev-parse HEAD)
  # Validate format before sending — defense against weird git output.
  if ! [[ "$DEPLOYED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    fail "git rev-parse HEAD returned unexpected format: '$DEPLOYED_SHA' (refusing to write baseline)"
  fi
  # Write via stdin pipe rather than embedding the value in a remote
  # shell command — sidesteps quoting/injection issues entirely.
  if $HYDRA_LOCAL; then
    printf '%s\n' "$DEPLOYED_SHA" > "$DEPLOY_PATH/.deployed-sha"
  else
    printf '%s\n' "$DEPLOYED_SHA" \
      | ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
        "cat > '$DEPLOY_PATH/.deployed-sha'" \
      || fail "failed to write drift baseline to server (ssh/cat error)"
    # Read it back to verify it landed. Capture rc and stderr separately
    # so a transient SSH failure on the readback produces an actionable
    # error instead of "server has '', expected 'abc...'".
    readback_rc=0
    readback_out=$(ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "cat '$DEPLOY_PATH/.deployed-sha'" 2>&1) || readback_rc=$?
    if (( readback_rc != 0 )); then
      log "  baseline readback ssh failed (rc=$readback_rc):"
      echo "$readback_out" | sed 's/^/    /'
      fail "drift baseline readback failed — wrote SHA but couldn't verify it landed"
    fi
    readback_clean=$(echo "$readback_out" | tr -d '[:space:]')
    if [[ "$readback_clean" != "$DEPLOYED_SHA" ]]; then
      fail "drift baseline write verification failed: server has '$readback_clean', expected '$DEPLOYED_SHA'"
    fi
  fi
  log "  Drift baseline updated: .deployed-sha → $DEPLOYED_SHA"
fi

# -------------------------------------------------------------------
# Step 8: Verify AWS access (main only)
# -------------------------------------------------------------------
# NOTE: Hydra is hosted on OVH (node-8), not AWS. This step verifies
# the *data plane* — Muso has two AWS accounts (Flagship 068358774785
# and Plaque 686505752817) holding the data lake (S3, Athena, Glue)
# and audit trail (CloudTrail). Several agents query them at runtime:
#   - devops: daily-aws-change-report cron (CloudTrail scan)
#   - data-expert / query-writer: Athena queries
#   - clio: data-platform queries
# Step 5 wrote ~/.aws/credentials on node-8 from the k3s secret
# `aws-hydra-readonly` (role: plaque, region: us-west-2). This step
# runs `aws sts get-caller-identity` to confirm the credentials
# propagated and the role is assumable. Non-fatal — a failure here
# only affects AWS-reading agents on the next cron run.
if needs_target "main"; then
  log "Step 8/9: Verifying AWS data-plane access (Athena/S3/CloudTrail)..."
  if $HYDRA_LOCAL; then
    aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1 \
      && log "  AWS access verified." \
      || log "  WARNING: AWS access check failed (non-fatal)."
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1" \
      && log "  AWS access verified." \
      || log "  WARNING: AWS access check failed (non-fatal)."
  fi
else
  log "Step 8/9: Skipping AWS check (not targeting main)."
fi

# -------------------------------------------------------------------
# Step 9: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
log "Step 9/9: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully (target: $TARGET). Commit: $COMMIT_SHA"
log "Deploy complete. Target: $TARGET. Commit: $COMMIT_SHA"
