#!/usr/bin/env bash
set -euo pipefail

# HYDRA Emergency Rollback
# ========================
# Reverts gateway configs to previous version, restarts all gateways, validates.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"
NODE8_IP="${NODE8_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

# -------------------------------------------------------------------
# HYDRA_LOCAL detection (mirrors scripts/deploy.sh)
# -------------------------------------------------------------------
# When running on node-8 itself (either via SSH from a laptop or
# inside the GH Actions self-hosted runner which IS node-8), we skip
# all SSH and rsync-over-SSH paths and operate on /opt/hydra/ directly.
# Before this fix, rollback.sh tried to SSH to root@10.0.0.8 with
# ~/.ssh/ovh_muso — that key doesn't exist on the runner, so the
# rollback path was dead.
# HYDRA_LOCAL may be pre-set by the caller — the bats suite
# (scripts/tests/rollback.bats) uses it as a seam to exercise the local sync
# path against a temp DEPLOY_PATH without SSH. Autodetect only when unset.
if [ -n "${HYDRA_LOCAL:-}" ]; then
  :
elif hostname | grep -q 'node-8\|ovh-node-8' || [ -d "/opt/hydra/workspaces" ]; then
  HYDRA_LOCAL=true
else
  HYDRA_LOCAL=false
fi
# See deploy.sh for the env var precedence rationale.
SLACK_WEBHOOK="${SLACK_WEBHOOK:-${HYDRA_SLACK_WEBHOOK:-}}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
# Real <@UID> mentions (Nick, Aaron) — a literal "@name" renders as plain
# text and pings nobody. IDs match SLACK_UID_* in lib/slack-notify.sh
# (not sourced here: rollback posts via a raw webhook, not the muso CLI).
fail() { log "FATAL: $*"; notify_slack ":rotating_light: HYDRA ROLLBACK FAILED: $*. <@U0AL36NADEY> <@U7RP6HKUZ> manual intervention required."; exit 1; }

# Notification path. HYDRA_SLACK_WEBHOOK has never been set on this repo
# (`gh secret list` shows only ANTHROPIC_API_KEY and FIREWORKS_API_KEY), so the
# raw-curl branch below has always been a silent no-op — every rollback since
# this script was written notified nobody. The working path is the same one the
# watchdogs use: `muso slack send --bot devops`, tokens from
# /etc/openclaw/main.env. Prefer it; keep the webhook branch for the case where
# someone does configure the secret later.
notify_slack() {
  # Via deploy-notify.sh, NOT slack_notify: the latter returns 0 even when the
  # token is missing and swallows a rejected send, so the webhook fallback
  # below could never be reached. deploy-notify.sh returns 0 only on a post
  # Slack confirmed, which makes the fallback meaningful.
  if [ -x "$SCRIPT_DIR/lib/deploy-notify.sh" ] || [ -r "$SCRIPT_DIR/lib/deploy-notify.sh" ]; then
    if bash "$SCRIPT_DIR/lib/deploy-notify.sh" critical "$1" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

CURRENT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# -------------------------------------------------------------------
# Resolve the rollback TARGET: the server's last-known-good SHA
# -------------------------------------------------------------------
# This script used to rsync "$HYDRA_ROOT/" — the checkout at the FAILED
# commit — to /opt/hydra/, reverting only openclaw-{main,edge}.json to
# HEAD~1. That is not a rollback: every other path (skills-all/, scripts/,
# workspace seeds) was FORWARD-deployed from the very commit that just
# failed. Observed 2026-08-06 (run 31080741548): the deploy died at Step 4a
# and the "rollback" pushed the failed commit's skills-all/ onto the server,
# leaving /opt/hydra/ and the live profile dirs disagreeing.
#
# The authoritative target is /opt/hydra/.deployed-sha — deploy.sh writes it
# only AFTER the smoke test passes, and it is in RSYNC_EXCLUDES so a failed
# deploy leaves it untouched. HEAD~1 is NOT a substitute: it is the previous
# COMMIT, which is only the previous DEPLOY when every commit deployed
# cleanly.
read_deployed_sha() {
  if $HYDRA_LOCAL; then
    tr -d '[:space:]' < "$DEPLOY_PATH/.deployed-sha" 2>/dev/null || true
  else
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" \
      "tr -d '[:space:]' < '$DEPLOY_PATH/.deployed-sha' 2>/dev/null" 2>/dev/null || true
  fi
}

TARGET_SHA="$(read_deployed_sha)"

# Fail SAFE, not forward. If we cannot establish what was last known good,
# syncing anything would just re-push the failed commit — strictly worse than
# leaving the server on the content it is already serving. Page instead.
if [[ ! "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  fail "cannot read a valid last-known-good SHA from $DEPLOY_PATH/.deployed-sha (got '${TARGET_SHA:-<empty>}'). Refusing to sync — that would deploy the FAILED commit. Server left as-is; roll back by hand."
fi
if ! git -C "$HYDRA_ROOT" cat-file -e "${TARGET_SHA}^{commit}" 2>/dev/null; then
  git -C "$HYDRA_ROOT" fetch --quiet origin "$TARGET_SHA" 2>/dev/null || true
fi
if ! git -C "$HYDRA_ROOT" cat-file -e "${TARGET_SHA}^{commit}" 2>/dev/null; then
  fail "last-known-good commit $TARGET_SHA is not present in this checkout and could not be fetched. Refusing to sync the FAILED commit. Server left as-is."
fi

PREVIOUS_SHA="$(git -C "$HYDRA_ROOT" rev-parse --short "$TARGET_SHA")"

log "Starting emergency rollback: $CURRENT_SHA -> $PREVIOUS_SHA (server's last-known-good)"
notify_slack ":warning: HYDRA rollback initiated. Reverting $CURRENT_SHA -> $PREVIOUS_SHA"

# -------------------------------------------------------------------
# Step 1: Materialize the last-known-good tree
# -------------------------------------------------------------------
# Check the target out into a throwaway worktree and rsync from THERE, so the
# bytes that land are exactly the last-known-good commit's — not the failed
# checkout with two files reverted. Using a separate worktree also means we
# never mutate $HYDRA_ROOT (the runner's checkout), so a partial rollback
# can't leave the source tree in a franken-state.
log "Step 1/4: Materializing last-known-good tree ($PREVIOUS_SHA)..."
ROLLBACK_TREE="$(mktemp -d -t hydra-rollback-XXXXXX)"
cleanup_rollback_tree() {
  git -C "$HYDRA_ROOT" worktree remove --force "$ROLLBACK_TREE" 2>/dev/null || true
  rm -rf "$ROLLBACK_TREE" 2>/dev/null || true
}
trap cleanup_rollback_tree EXIT
if ! git -C "$HYDRA_ROOT" worktree add --detach --force "$ROLLBACK_TREE" "$TARGET_SHA" >/dev/null 2>&1; then
  fail "could not materialize $TARGET_SHA into a worktree. Refusing to sync the FAILED commit. Server left as-is."
fi
SYNC_SRC="$ROLLBACK_TREE"
log "  Tree ready at $ROLLBACK_TREE"

# Excludes: DERIVED from scripts/deploy.sh's RSYNC_EXCLUDES at runtime.
#
# This used to be a hand-maintained copy carrying a "⚠ DRIFT WARNING: keep
# these verbatim identical" comment — and by 2026-08 it had drifted anyway,
# missing ~15 entries deploy.sh had grown (tests/, the agent-scratch globs,
# workspaces/qa/pr-review-*.json, the CTO clone-hook guards...). Nothing
# checked it, exactly as that comment predicted.
#
# Parsing deploy.sh's literals keeps ONE source of truth without moving them:
# .githooks/pre-commit Check 2 and scripts/tests/qa-clean-merge-scratch.bats
# both grep those literals out of deploy.sh by text, so relocating the array
# would break both gates.
#
# Parsed from BOTH trees and UNIONED. $SCRIPT_DIR/deploy.sh belongs to the
# FAILED checkout — the very commit we are rolling back — so it cannot be the
# sole authority for what --delete must spare: a bad commit that drops one
# protected pattern (say workspaces/*/memory/) while keeping the other 78 still
# clears any count threshold, and the rollback would then permanently erase live
# state that has no backup. The last-known-good tree we just materialized
# carries the policy that governed the last SUCCESSFUL deploy. Excluding MORE is
# always safe under --delete, so the union of the two is the fail-safe combination.
parse_rsync_excludes() {
  [ -r "$1" ] || return 0
  sed -n '/^RSYNC_EXCLUDES=(/,/^)/p' "$1" \
    | grep -v '^[[:space:]]*#' \
    | sed -n "s/^[[:space:]]*--exclude='\([^']*\)'.*/\1/p"
}

DEPLOY_SH="${DEPLOY_SH:-$SCRIPT_DIR/deploy.sh}"
LKG_DEPLOY_SH="${LKG_DEPLOY_SH:-$ROLLBACK_TREE/scripts/deploy.sh}"

# while-read, not mapfile: this script also runs from a laptop over SSH, and
# macOS still ships bash 3.2.
EXCLUDE_PATTERNS=()
while IFS= read -r pat; do
  [ -n "$pat" ] && EXCLUDE_PATTERNS+=("$pat")
done < <(
  { parse_rsync_excludes "$LKG_DEPLOY_SH"; parse_rsync_excludes "$DEPLOY_SH"; } | sort -u
)

# Runtime state with NO backup anywhere. A COUNT cannot tell "79 excludes" from
# "79 excludes, one of which no longer protects memory/", so every one of these
# must be present in the parsed union before --delete is allowed. This is a
# floor, not the whole policy — the union above still carries everything else.
ROLLBACK_REQUIRED_EXCLUDES=(
  '.git'
  'secrets/'
  '.deployed-sha'
  'audit/'
  'config/'
  'workspaces/*/memory/'
  'workspaces/*/api-logs/'
  'workspaces/*/MEMORY.md'
  'workspaces/*/backups/'
  'workspaces/*/reports/'
  'workspaces/*/.openclaw/'
  'workspaces/*/IDENTITY.md'
  'workspaces/*/HEARTBEAT.md'
)
MISSING_REQUIRED=()
for req in "${ROLLBACK_REQUIRED_EXCLUDES[@]}"; do
  found=false
  for pat in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
    [ "$pat" = "$req" ] && { found=true; break; }
  done
  $found || MISSING_REQUIRED+=("$req")
done

ROLLBACK_EXCLUDES=()
for pat in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
  ROLLBACK_EXCLUDES+=("--exclude=$pat")
done
# Whatever the parse missed, protect anyway: without --delete these still stop
# the last-known-good tree's SEEDS from overwriting live runtime state.
for req in ${MISSING_REQUIRED[@]+"${MISSING_REQUIRED[@]}"}; do
  ROLLBACK_EXCLUDES+=("--exclude=$req")
done

# Fail CLOSED on --delete. Deleting with a truncated or tampered exclude list
# during an incident would wipe live agent state (memory/, MEMORY.md, reports/,
# api-logs/ — none of it backed up). If the policy looks wrong, fall back to the
# old non-deleting sync: it can leave a file the failed deploy added, which is
# bad, but it cannot destroy production data, which is worse.
RSYNC_DELETE_ARGS=()
if [ "${#EXCLUDE_PATTERNS[@]}" -ge "${ROLLBACK_MIN_EXCLUDES:-20}" ] && [ "${#MISSING_REQUIRED[@]}" -eq 0 ]; then
  RSYNC_DELETE_ARGS=(--delete)
elif [ "${#MISSING_REQUIRED[@]}" -gt 0 ]; then
  log "  WARNING: exclude policy is missing mandatory protected pattern(s): ${MISSING_REQUIRED[*]}"
  log "  WARNING: syncing WITHOUT --delete. Files the failed deploy added will survive; remove them by hand."
else
  log "  WARNING: parsed only ${#EXCLUDE_PATTERNS[@]} excludes from $LKG_DEPLOY_SH + $DEPLOY_SH (expected >= ${ROLLBACK_MIN_EXCLUDES:-20})."
  log "  WARNING: syncing WITHOUT --delete. Files the failed deploy added will survive; remove them by hand."
fi
log "  Syncing last-known-good tree ($PREVIOUS_SHA) to Node 8..."
if $HYDRA_LOCAL; then
  rsync -a \
    ${RSYNC_DELETE_ARGS[@]+"${RSYNC_DELETE_ARGS[@]}"} \
    "${ROLLBACK_EXCLUDES[@]}" \
    "$SYNC_SRC/" \
    "$DEPLOY_PATH/"
else
  rsync -azP \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    ${RSYNC_DELETE_ARGS[@]+"${RSYNC_DELETE_ARGS[@]}"} \
    "${ROLLBACK_EXCLUDES[@]}" \
    "$SYNC_SRC/" \
    "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
fi

# Sync to profile dirs.
#
# The local branch derives BOTH roots from variables. It used to hardcode
# /opt/hydra and /root/.openclaw-*, which made it unsafe for any caller that
# redirects DEPLOY_PATH: scripts/tests/rollback.bats sets HYDRA_LOCAL=true to
# exercise this path, and the self-hosted runner IS node-8 running as root — so
# every green test run copied the LIVE /opt/hydra profile config over the LIVE
# /root/.openclaw-*/openclaw.json (silently reverting any hotfix drift, and
# unannounced, which is what the config-audit watcher pages on). The source is
# now the tree we just synced ($DEPLOY_PATH — identical to /opt/hydra in a real
# run) and the destination root is injectable. The remote branch below runs the
# heredoc ON node-8, where the real paths are the only correct ones.
# shellcheck source=lib/sync-profile-config.sh
. "$HYDRA_ROOT/scripts/lib/sync-profile-config.sh"
PROFILE_SRC_ROOT="${PROFILE_SRC_ROOT:-$DEPLOY_PATH}"
PROFILE_STATE_ROOT="${PROFILE_STATE_ROOT:-/root}"
if $HYDRA_LOCAL; then
  set +e
  for profile in main edge; do
    src="$PROFILE_SRC_ROOT/openclaw-${profile}.json"
    dst="$PROFILE_STATE_ROOT/.openclaw-${profile}/openclaw.json"
    if [ -f "$src" ]; then
      # NOT a plain `cp`. sync_profile_config preserves the live
      # `.mcp.servers` block -- runtime MCP registrations carry auth tokens
      # that are deliberately never committed, so a straight copy destroys
      # them. That is exactly what happened on 2026-08-26 (deploy run
      # 32933062895 attempt 1 failed -> this path fired -> the Sentry MCP
      # registration was wiped). See scripts/lib/sync-profile-config.sh.
      if sync_profile_config "$src" "$dst" rollback; then
        echo "  Synced ${profile} profile config"
      else
        echo "  WARNING: Failed to sync ${profile} profile config"
        SYNC_FAILED=1
      fi
      # Deliberately NOT `cmp -s "$src" "$dst"`: when the live file carried MCP
      # servers the result is CORRECTLY not byte-identical to the repo copy.
      # Asserting equality would be asserting the bug. Validate shape instead.
      jq -e . "$dst" >/dev/null 2>&1 || SYNC_FAILED=1
    else
      echo "  WARNING: $src not found — skipping ${profile}"
    fi
  done
  set -e
  [ "${SYNC_FAILED:-0}" = 0 ] || fail "Reverted config did not land in a live profile dir (/root/.openclaw-<profile>/)"
else
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'SYNC'
set -euo pipefail
# This branch runs ON node-8 via ssh, so it sources the DEPLOYED lib rather than
# the checkout's. If a deploy failed before syncing scripts/, that file may not
# exist yet -- refuse loudly instead of dying on a bare `source` error, and
# above all never fall back to `cp`: a plain copy is precisely the bug this
# module exists to fix (it destroys every runtime MCP registration).
if [ ! -r /opt/hydra/scripts/lib/sync-profile-config.sh ]; then
  echo "  ERROR: /opt/hydra/scripts/lib/sync-profile-config.sh is missing." >&2
  echo "  Refusing to restore profile configs: without it the only alternative" >&2
  echo "  is a plain cp, which would destroy live .mcp.servers registrations." >&2
  echo "  Sync scripts/ to /opt/hydra first, then re-run the rollback." >&2
  exit 1
fi
# shellcheck source=lib/sync-profile-config.sh
. /opt/hydra/scripts/lib/sync-profile-config.sh
for profile in main edge; do
  src="/opt/hydra/openclaw-${profile}.json"
  dst="/root/.openclaw-${profile}/openclaw.json"
  if [ -f "$src" ]; then
    # Same rule as the local branch: preserve live .mcp.servers, never `cp`.
    if sync_profile_config "$src" "$dst" rollback; then
      echo "  Synced ${profile} profile config"
    else
      echo "  WARNING: Failed to sync ${profile} profile config"
      SYNC_FAILED=1
    fi
    jq -e . "$dst" >/dev/null 2>&1 || SYNC_FAILED=1
  else
    echo "  WARNING: $src not found — skipping ${profile}"
  fi
done
exit "${SYNC_FAILED:-0}"
SYNC
  then
    fail "Reverted config did not land in a live profile dir (/root/.openclaw-<profile>/)"
  fi
fi
log "  Config synced."

# -------------------------------------------------------------------
# Step 2: Restart all gateways
# -------------------------------------------------------------------
log "Step 2/4: Restarting all gateways..."
if $HYDRA_LOCAL; then
  for svc in openclaw-gateway-main openclaw-gateway-edge; do
    if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
      systemctl restart "$svc" && echo "  Restarted $svc" || echo "  WARNING: Failed to restart $svc"
    fi
  done
else
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'RESTART'
for svc in openclaw-gateway-main openclaw-gateway-edge; do
  if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
    systemctl restart "$svc" && echo "  Restarted $svc" || echo "  WARNING: Failed to restart $svc"
  fi
done
RESTART
fi
sleep 5
log "  Gateways restarted."

# -------------------------------------------------------------------
# Step 3: Run smoke test
# -------------------------------------------------------------------
log "Step 3/4: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh" all; then
  fail "Smoke test FAILED after rollback. System may be in a bad state."
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Step 4: Post rollback status
# -------------------------------------------------------------------
log "Step 4/4: Posting rollback status..."
notify_slack ":rewind: HYDRA rollback complete. Now running $PREVIOUS_SHA. Smoke test passed."
log "Rollback complete. Now running: $PREVIOUS_SHA"
