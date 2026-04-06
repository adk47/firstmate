#!/bin/bash
# Notify active Slack channels before/after gateway restart
# Only messages channels with conversation activity in the last 60 seconds

ACTION="${1:-pre}"
REASON="${2:-routine maintenance}"
CONFIG="/root/.openclaw/main/openclaw.json"
ACTIVE_WINDOW_SEC=60

# Get Clio token
CLIO_TOKEN=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c.get('channels',{}).get('slack',{}).get('accounts',{}).get('clio',{}).get('botToken',''))
" 2>/dev/null)

if [ -z "$CLIO_TOKEN" ]; then
    echo "No Clio token — skipping notification"
    exit 0
fi

# All channels the bots are in
ALL_CHANNELS=$(python3 -c "
import json, urllib.request, time

with open('$CONFIG') as f:
    c = json.load(f)

seen_channels = set()
now = time.time()
active = []

# Check each bot account for channels with recent messages
for name, acct in c.get('channels',{}).get('slack',{}).get('accounts',{}).items():
    if name == 'default':
        continue
    token = acct.get('botToken','')
    if not token:
        continue
    try:
        req = urllib.request.Request(
            'https://slack.com/api/users.conversations?types=public_channel,private_channel&limit=200&exclude_archived=true',
            headers={'Authorization': f'Bearer {token}'})
        resp = json.loads(urllib.request.urlopen(req).read())
        for ch in resp.get('channels', []):
            ch_id = ch.get('id','')
            if ch_id in seen_channels:
                continue
            seen_channels.add(ch_id)
            # Check if channel has recent activity
            try:
                req2 = urllib.request.Request(
                    f'https://slack.com/api/conversations.history?channel={ch_id}&limit=1',
                    headers={'Authorization': f'Bearer {token}'})
                resp2 = json.loads(urllib.request.urlopen(req2).read())
                msgs = resp2.get('messages', [])
                if msgs:
                    msg_ts = float(msgs[0].get('ts', 0))
                    age = now - msg_ts
                    if age < $ACTIVE_WINDOW_SEC:
                        active.append(ch_id)
            except:
                pass
    except:
        pass

if active:
    print(' '.join(active))
else:
    print('')
" 2>/dev/null)

if [ -z "$ALL_CHANNELS" ]; then
    echo "No active channels — skipping notification"
    exit 0
fi

CHANNEL_COUNT=$(echo "$ALL_CHANNELS" | wc -w | tr -d ' ')

if [ "$ACTION" = "pre" ]; then
    MSG="🔄 *Agents restarting briefly* — $REASON. Back in ~30s."
elif [ "$ACTION" = "post" ]; then
    VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
    MSG="✅ *Agents back online* — $VERSION"
else
    MSG="ℹ️ $REASON"
fi

echo "[restart-notify] $ACTION: notifying $CHANNEL_COUNT active channels"

for CH in $ALL_CHANNELS; do
    curl -sf -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $CLIO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":\"$CH\",\"text\":\"$MSG\"}" >/dev/null 2>&1 &
done
wait
