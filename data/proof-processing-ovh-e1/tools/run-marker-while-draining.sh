#!/bin/bash
# proof-processing-ovh-e1 (2026-11-13): while the supervised feeder drain (run-feed-drain.sh) is alive, set the
# proof marker from the documents it files, every 30 minutes, and once more after the drain ends. It exists only
# because the hourly cron `credit-proof-marker` is not on node-8 until this branch is deployed.
# Honours /etc/hydra/proof-marker.disabled (proof_marker.py exits 0 and writes nothing). Each apply prints its
# run id; undo one with `proof_marker.py revert --run-id RUN`. Undo this loop: kill it.
set -uo pipefail
ROOT=/root/proof-e1
LOG=$ROOT/marker-$(date -u +%Y%m%dT%H%M%SZ).log
cd "$ROOT" || exit 1
mark() { echo "$(date -u +%FT%TZ) $(python3 scripts/credit_review/proof_marker.py apply 2>&1 | tail -1)" >> "$LOG"; }
while pgrep -f "run-feed-drain[.]sh" >/dev/null; do
  mark
  sleep 1800
done
mark
echo "$(date -u +%FT%TZ) drain gone: last mark done" >> "$LOG"
