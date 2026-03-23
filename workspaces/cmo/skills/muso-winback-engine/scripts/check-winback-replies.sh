#!/usr/bin/env bash
# check-winback-replies.sh — Scan for unread Win-Back replies
# Usage: bash check-winback-replies.sh
# Returns JSON lines of unread replies in the Win-Back label

set -euo pipefail

echo "=== Checking Win-Back replies at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# Search for unread replies in the Win-Back label
RESULTS=$(gog gmail messages search "label:Win-Back is:unread" --account a@muso.ai --json 2>/dev/null || echo '{"messages":[]}')

# Count results
COUNT=$(echo "$RESULTS" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    msgs = data.get('messages', data.get('result', []))
    if isinstance(msgs, list):
        print(len(msgs))
    else:
        print(0)
except:
    print(0)
")

echo "Found $COUNT unread Win-Back messages"

if [ "$COUNT" -gt 0 ]; then
    echo "$RESULTS"
fi
