#!/usr/bin/env bash
# One pass of the READ-ONLY profile-merge queue census (every 30 min on node-8).
#
# This is the body of /etc/cron.d/merge-queue-census. It touches nothing customer-facing:
# it refreshes clickup.json from the ClickUp User Requests board and re-derives plan.json,
# which is what the reply-queue pass and any human read. It exists as a script (not a
# 600-character `bash -c` in the cron file) so the installed cron can be tested and the
# plan refresh cannot be edited into a shape that clobbers plan.json.
#
# Refuses (exit 1, log line only) when the deployed chain is not the pinned tree, so a
# drifted copy cannot rewrite plan.json in a shape no pinned reader expects.
#
#   CHAIN_DIR   deployed chain copies   (default /root/q1)
#   HYDRA_ROOT  the deployed hydra tree (default /opt/hydra)
#   PYTHON      interpreter             (default python3)
#   SELECTION   plan.py's second arg    (default m1_sel.json)
#   MAIN_ENV / EDGE_ENV  credential env files (default /etc/openclaw/main.env, edge.env)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="${HYDRA_ROOT:-$(cd "$HERE/../.." && pwd)}"
CHAIN_DIR="${CHAIN_DIR:-/root/q1}"
PYTHON="${PYTHON:-python3}"
SELECTION="${SELECTION:-m1_sel.json}"
KILL_FILE="${MERGE_QUEUE_CENSUS_KILL:-/etc/hydra/merge-queue-census.disabled}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"
EDGE_ENV="${EDGE_ENV:-/etc/openclaw/edge.env}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] merge-queue-census: $*"; }

if [ -e "$KILL_FILE" ]; then
  log "kill file present ($KILL_FILE) - no census this pass"
  exit 0
fi

[ -d "$CHAIN_DIR" ] || { log "FATAL chain dir missing: $CHAIN_DIR"; exit 1; }
PREFLIGHT="$HYDRA_ROOT/scripts/merge-queue/chain-preflight.sh"
[ -r "$PREFLIGHT" ] || { log "FATAL preflight missing: $PREFLIGHT (HYDRA_ROOT=$HYDRA_ROOT)"; exit 1; }

if ! bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR"; then
  log "FATAL chain drift in $CHAIN_DIR - refusing to rewrite plan.json"
  exit 1
fi

for f in "$MAIN_ENV" "$EDGE_ENV"; do
  if [ -r "$f" ]; then
    set -a
    set +u
    # shellcheck disable=SC1090
    . "$f"
    set -u
    set +a
  fi
done

cd "$CHAIN_DIR"

# clickup.json is replaced atomically: a half-written census is worse than an old one.
"$PYTHON" clickup_merges.py > clickup.json.tmp
mv clickup.json.tmp clickup.json
# plan.py writes plan.json itself; its stdout is the summary a human reads.
"$PYTHON" plan.py clickup.json "$SELECTION" > census.last 2>> census.err
{ date -u +%FT%TZ; cat census.last; } >> census.log
