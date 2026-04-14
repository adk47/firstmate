#!/bin/bash
# Runs once per week via root crontab: 0 9 * * 1
# Processes drafts labeled B2B-Ads/auto-fu-approved and sends via the
# outreach sender worker. Idempotent per draft.
set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

LOGPREFIX="[muso-outreach-monday $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
LOCKFILE="/var/lock/muso-outreach-monday.lock"

echo "$LOGPREFIX start"

flock -n "$LOCKFILE" \
  /opt/hydra/scripts/muso-outreach-sender-worker.py \
    --label "B2B - Ads/auto-fu-approved" \
    --account "a@muso.ai" \
  2>&1 | sed "s/^/$LOGPREFIX /" \
|| echo "$LOGPREFIX SKIPPED: another instance is running (lock held)"

echo "$LOGPREFIX done"
