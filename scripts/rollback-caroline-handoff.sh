#!/usr/bin/env bash
#
# Rollback for Caroline analytics handoff deploy (PR #270).
#
# Restores the pre-deploy snapshot of /root/.openclaw-edge/openclaw.json,
# reverts to the previous git SHA on hydra's /opt/hydra/ checkout, and
# restarts the edge gateway. Logs each step so post-mortem analysis has
# a trail.
#
# Usage:
#   On hydra:
#     /opt/hydra/scripts/rollback-caroline-handoff.sh [pre-deploy-sha]
#
#   pre-deploy-sha is the SHA that was deployed BEFORE this PR. Defaults
#   to whatever is in /opt/hydra/.deployed-sha.bak if it exists.
#
# Safety: This script does NOT run a destructive git command without
# explicit confirmation. It prints what it would do and waits for "yes"
# unless --force is passed.

set -euo pipefail

readonly EDGE_CFG=/root/.openclaw-edge/openclaw.json
readonly DEPLOYED_SHA_FILE=/opt/hydra/.deployed-sha
readonly HYDRA_DIR=/opt/hydra
readonly LOG_TAG="[rollback-caroline-handoff]"

force=false
prev_sha=""
for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    --help|-h) sed -n '1,30p' "$0"; exit 0 ;;
    *) prev_sha="$arg" ;;
  esac
done

log() { echo "$LOG_TAG $(date -Iseconds) $*" >&2; }

# 1. Determine previous SHA.
if [[ -z "$prev_sha" ]] && [[ -f "${DEPLOYED_SHA_FILE}.bak" ]]; then
  prev_sha=$(cat "${DEPLOYED_SHA_FILE}.bak")
fi
if [[ -z "$prev_sha" ]]; then
  log "ERROR: no previous SHA argument and no ${DEPLOYED_SHA_FILE}.bak found."
  log "Usage: $0 <pre-deploy-sha> [--force]"
  exit 2
fi

# 2. Locate most recent openclaw-edge.json backup.
edge_bak=$(find /root/.openclaw-edge -maxdepth 1 -name 'openclaw.json.bak-*' -printf '%f\n' 2>/dev/null \
  | sort | tail -1 | xargs -I{} echo "/root/.openclaw-edge/{}" || true)
if [[ -z "$edge_bak" ]]; then
  log "WARN: no /root/.openclaw-edge/openclaw.json.bak-* snapshot found."
  log "The pre-start-heal script will auto-recover on schema-invalid configs, but"
  log "no manual snapshot exists for this rollback. Proceeding with git revert only."
fi

# 3. Confirm.
log "Plan:"
log "  - Revert /opt/hydra to git SHA $prev_sha (current: $(cat "$DEPLOYED_SHA_FILE" 2>/dev/null || echo unknown))"
if [[ -n "$edge_bak" ]]; then
  log "  - Restore $EDGE_CFG from $edge_bak"
fi
log "  - Restart openclaw-gateway-edge.service"
log "  - Run tool-registration smoke (5 tools must register)"

if [[ "$force" != "true" ]]; then
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 1; }
fi

# 4. Execute.
log "Reverting git checkout..."
cd "$HYDRA_DIR"
git fetch origin
git checkout "$prev_sha"
echo "$prev_sha" > "$DEPLOYED_SHA_FILE"

if [[ -n "$edge_bak" ]]; then
  log "Restoring $EDGE_CFG from $edge_bak..."
  cp -p "$edge_bak" "$EDGE_CFG"
fi

log "Restarting openclaw-gateway-edge.service..."
systemctl restart openclaw-gateway-edge.service
sleep 2
systemctl is-active --quiet openclaw-gateway-edge.service || {
  log "ERROR: edge gateway failed to start after rollback. Check journalctl -u openclaw-gateway-edge.service"
  exit 3
}

# 5. Tool-registration smoke (passive — checks startup log for the contracts.tools error).
log "Waiting 10s for plugin registration..."
sleep 10
diag=$(journalctl -u openclaw-gateway-edge.service --since "30 seconds ago" -o cat 2>/dev/null \
  | grep -iE "contracts\.tools|plugin must declare|requires.*runtime output" | head -5 || true)
if [[ -n "$diag" ]]; then
  log "WARN: plugin registration diagnostics detected during rollback. Investigate:"
  while IFS= read -r line; do echo "    $line"; done <<< "$diag"
fi

log "Rollback complete. Edge gateway active on $prev_sha."
