#!/usr/bin/env bash
# One pass of the profile-merge REPLY queue: refresh the plan from the live queue, build
# the variant plan, then send the APPROVED copy (q1-copy-1103, Fable 2026-11-03).
#
# IT SENDS BY DEFAULT. There is no dry-run safety net: an unflagged run (which is what the
# cron line does) passes --apply and posts real Intercom replies. `--dry-run` is the opt-in
# preview and is the ONLY way to run this without sending.
#
# This is the body of /etc/cron.d/merge-queue-variant-queue. It is a script rather than a
# 500-character `bash -c` inside the cron file so the send path can be tested, and so the
# one edit that bit us on 2026-11-05 is impossible: the cron line used to run
#     plan.py ... > plan.daily.json && cp plan.daily.json plan.json
# while plan.py:140 already writes plan.json itself and lines 142-143 print only a ~267
# byte summary. The redirect replaced the real ~450 KB plan with the summary and every
# downstream step read the summary as if it were a plan. Nothing here redirects plan.py.
#
# TWO refusals before any send:
#   1. the kill file exists            -> log, exit 0 (a human paused this lane)
#   2. the deployed chain is not pinned -> log DRIFT, exit 1 (chain-preflight.sh; a
#      drifted copy would send copy a human never approved or read a reshaped plan)
#
# Usage: run-variant-queue.sh [--dry-run]     (no flag = send)
#
#   CHAIN_DIR   deployed chain copies                 (default /root/q1)
#   HYDRA_ROOT  the deployed hydra tree               (default /opt/hydra)
#   PYTHON      interpreter                           (default python3)
#   SELECTION   plan.py's second arg (m1 exclusions)  (default m1_sel.json)
#   DECISIONS   the decider's ledger                  (default decisions-batch-2.jsonl)
#   DRY_RUN     1 = never pass --apply, preview only  (default 0 = SENDS)
#   MAIN_ENV / EDGE_ENV   the openclaw env files holding the credentials
#                         (default /etc/openclaw/main.env, /etc/openclaw/edge.env)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="${HYDRA_ROOT:-$(cd "$HERE/../.." && pwd)}"
CHAIN_DIR="${CHAIN_DIR:-/root/q1}"
PYTHON="${PYTHON:-python3}"
SELECTION="${SELECTION:-m1_sel.json}"
DECISIONS="${DECISIONS:-decisions-batch-2.jsonl}"
DRY_RUN="${DRY_RUN:-0}"
KILL_FILE="${MERGE_QUEUE_VARIANT_KILL:-/etc/hydra/merge-queue-variant.disabled}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"
EDGE_ENV="${EDGE_ENV:-/etc/openclaw/edge.env}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] variant-queue: $*"; }

case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  '') ;;
  *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac

if [ -e "$KILL_FILE" ]; then
  log "kill file present ($KILL_FILE) - nothing sent"
  exit 0
fi

[ -d "$CHAIN_DIR" ] || { log "FATAL chain dir missing: $CHAIN_DIR"; exit 1; }
PREFLIGHT="$HYDRA_ROOT/scripts/merge-queue/chain-preflight.sh"
[ -r "$PREFLIGHT" ] || { log "FATAL preflight missing: $PREFLIGHT (HYDRA_ROOT=$HYDRA_ROOT)"; exit 1; }
[ -r "$CHAIN_DIR/$DECISIONS" ] || { log "FATAL decisions ledger unreadable: $CHAIN_DIR/$DECISIONS"; exit 1; }

# Fail closed BEFORE the plan is refreshed: a drifted chain must not even rewrite plan.json
# in the shape the pinned variant_plan.py does not expect.
if ! bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR"; then
  log "FATAL chain drift in $CHAIN_DIR - refusing to send (republish the pinned files or bump chain-manifest.sha256)"
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

# plan.py writes plan.json itself. STDOUT IS NOISE: never redirect it onto plan.json.
"$PYTHON" plan.py clickup.json "$SELECTION" >/dev/null
"$PYTHON" variant_plan.py plan.json "$DECISIONS" > variants.json

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: would send from $CHAIN_DIR/variants.json"
  "$PYTHON" send_variant_copy.py --plan variants.json
else
  Q1_VARIANT_COPY_APPROVED=1 "$PYTHON" send_variant_copy.py --plan variants.json --apply
fi
