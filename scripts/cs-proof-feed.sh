#!/usr/bin/env bash
# cs-proof-feed.sh — hourly refresh of the proof-on-file feed that the credit-trust decider reads
# (/var/lib/credit-trust/inputs/cs-proofs.json: "this user already sent us a document"), on node-8.
#
# Until 2026-10-26 this ran on the captain's Mac (launchd ai.muso.fmc1.proof-hourly,
# cs-systemic-issues-lane-c1 proof-hourly.sh) and pulled the Intercom token from Vault onto the Mac
# every hour. Captain 2026-10-26 ~21:15Z: recurring ops run on OVH, not his computer (ops-to-ovh-m1,
# docs/runbooks/ops-to-ovh-inventory.md #1). Same three steps, same order, same timeouts:
#   1. Intercom incremental: conversations updated since the last SUCCESSFUL scan (+1 h overlap, at least
#      2 h), so an outage never leaves a gap; only once the full pass is ingested
#   2. support@ Gmail incremental: back to the last successful run (+1 day, at least 2 days) — gog, local
#   3. export: contact -> core user id (read-only replica via Trino), request-level links from the
#      hydra send ledger (sqlite, read-only), atomic install of cs-proofs.json
# Read-only on every source. No AI call. Writes only under $STATE and the one feed file.
#
# Schedule: /etc/cron.d/hydra-cs-proof-feed (scripts/install-aux-units.sh), hourly at :21.
# After a long outage the resume window can outgrow the 1500 s scan timeout; each failed run leaves the
# stamp where it was (no gap), and one manual run without `timeout` catches up.
# Kill switch: touch /etc/hydra/cs-proof-feed.disabled   (consumers go stale-safe: the feed's own
#              per-part `stale` flag flips after 3 h, and readers then treat proof as UNKNOWN)
# Logs:        journalctl -t hydra-cs-proof-feed
# State:       /var/lib/hydra/cs-proof-feed/ (never /opt/hydra — the deploy rsync owns that)
set -uo pipefail

HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
LIB="${CS_PROOF_LIB:-$HYDRA_ROOT/scripts/cs_proof_feed}"
STATE="${CS_PROOF_STATE:-/var/lib/hydra/cs-proof-feed}"
KILL="${CS_PROOF_KILL:-/etc/hydra/cs-proof-feed.disabled}"
ENV_FILE="${CS_PROOF_ENV:-/etc/openclaw/main.env}"
PY="${PYTHON:-python3}"

case "${1:-}" in
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
esac

log() { echo "$(date -u +%FT%TZ) $*"; }

if [ -e "$KILL" ]; then log "kill switch $KILL present: skip"; exit 0; fi

mkdir -p "$STATE/out" "$STATE/gmail"
exec 9>"$STATE/run.lock"
flock -n 9 || { log "previous run still holds $STATE/run.lock: skip"; exit 0; }

# The Intercom token (and gog's Google credentials) come from the gateway env file. Never echoed:
# set -a only exports what the file already holds; nothing below prints the environment.
# shellcheck source=/dev/null  # host secrets file, not in the repo
if [ -r "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
if [ -z "${MUSOAI_INTERCOM_TOKEN:-}" ]; then log "no MUSOAI_INTERCOM_TOKEN in $ENV_FILE: skip"; exit 1; fi
export CS_PROOF_GMAIL_DIR="$STATE/gmail" CS_PROOF_GMAIL_SCAN="$LIB/gmail_scan.sh"

OUT="$STATE/out"
rc=0
if grep -q "FULL PASS COMPLETE" "$OUT/scan.log" 2>/dev/null; then
  # The stamp is taken BEFORE the scan starts, so the next window always reaches back past this run.
  started=$(date -u +%FT%TZ)
  # Freshness advances ONLY on a complete scan: proof_scan.py exits non-zero (3) when any
  # Intercom read fails after its retries, and the part then goes stale (> 3 h) for consumers.
  if timeout 1500 "$PY" "$LIB/proof_scan.py" "$OUT" --incremental 2 --resume-from "$OUT/intercom-last-success"; then
    echo "$started" > "$OUT/intercom-last-success"
  else
    log "intercom incremental FAILED (feed keeps the last good part; it goes stale after 3 h)"; rc=1
  fi
else
  log "no completed full Intercom pass in $OUT/scan.log: intercom part not refreshed"; rc=1
fi
timeout 1500 "$PY" "$LIB/gmail_proof.py" "$OUT" --incremental || { log "gmail incremental not refreshed"; rc=1; }
timeout 1800 "$PY" "$LIB/proof_export.py" "$OUT"; erc=$?
case "$erc" in
  0) ;;
  4) log "export installed with cs-intercom marked STALE (unreadable Intercom contacts; readers hold everyone as UNKNOWN)"; rc=1 ;;
  *) log "export FAILED (rc=$erc): previous feed left in place, it ages out on its own stamps"; exit 1 ;;
esac
unset MUSOAI_INTERCOM_TOKEN
exit "$rc"
