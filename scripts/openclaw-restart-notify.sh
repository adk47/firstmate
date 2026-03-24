#!/bin/bash
# Notify all Slack channels before/after gateway restart
# Usage: openclaw-restart-notify.sh [pre|post] [reason]

ACTION="${1:-pre}"
REASON="${2:-routine maintenance}"
CONFIG="/root/.openclaw/openclaw.json"

# Get all unique bot tokens
TOKENS=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
accounts = c.get('channels',{}).get('slack',{}).get('accounts',{})
seen = set()
for name, acct in accounts.items():
    if name == 'default': continue
    token = acct.get('botToken','')
    if token and token not in seen:
        seen.add(token)
        print(f'{name}:{token}')
" 2>/dev/null)

# Pick a representative token (clio) for posting
CLIO_TOKEN=$(echo "$TOKENS" | grep "^clio:" | cut -d: -f2-)

if [ -z "$CLIO_TOKEN" ]; then
    echo "No Clio token found, skipping notification"
    exit 0
fi

# Channels to notify
CHANNELS="C7TBH462K C0ADV2W76G4 C0AHN078CSH C031DKAGQSH C0ADREBPNQ2"

if [ "$ACTION" = "pre" ]; then
    MSG="🔄 *HYDRA agents going offline briefly* — $REASON. Back in ~30 seconds."
elif [ "$ACTION" = "post" ]; then
    VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
    MSG="✅ *HYDRA agents back online* — $VERSION. All systems operational."
else
    MSG="ℹ️ HYDRA: $REASON"
fi

for CH in $CHANNELS; do
    curl -sf -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $CLIO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":\"$CH\",\"text\":\"$MSG\"}" >/dev/null 2>&1 &
done
wait
