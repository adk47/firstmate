#!/bin/bash
# Runs once per week via root crontab: 0 9 * * 1
# Processes drafts labeled B2B-Ads/auto-fu-approved and sends via the
# outreach sender worker. Idempotent per draft.
set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# gog needs the keyring passphrase in non-interactive contexts. File is
# mode-600, root-owned, not tracked in git. Provisioned manually on the
# server; see docs/RUNBOOK-outreach-sender-worker.md.
GOG_PW_FILE="/root/.gog-keyring-password"
if [[ -r "$GOG_PW_FILE" ]]; then
  GOG_KEYRING_PASSWORD="$(cat "$GOG_PW_FILE")"
  export GOG_KEYRING_PASSWORD
else
  echo "[muso-outreach-monday] FATAL: $GOG_PW_FILE missing or unreadable" >&2
  exit 2
fi

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
