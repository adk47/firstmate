#!/bin/bash
# Runs once per week via root crontab: 0 9 * * 1
# Processes drafts labeled B2B-Ads/auto-fu-approved and sends via the
# outreach sender worker. Idempotent per draft.
set -euo pipefail

LOGPREFIX="[muso-outreach-monday $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
echo "$LOGPREFIX start"

/opt/hydra/scripts/muso-outreach-sender-worker.py \
  --label "B2B - Ads/auto-fu-approved" \
  --account "a@muso.ai" \
  2>&1 | sed "s/^/$LOGPREFIX /"

echo "$LOGPREFIX done"
