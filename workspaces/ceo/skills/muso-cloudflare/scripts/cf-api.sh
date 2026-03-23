#!/usr/bin/env bash
# Cloudflare API wrapper — read-only operations
# Usage: cf-api.sh <METHOD> <endpoint> [jq-filter]
# Examples:
#   cf-api.sh GET /zones
#   cf-api.sh GET /zones/ZONE_ID/dns_records
#   cf-api.sh GET /zones/ZONE_ID/analytics/dashboard?since=-1440

set -euo pipefail

METHOD="${1:?Usage: cf-api.sh <METHOD> <endpoint> [jq-filter]}"
ENDPOINT="${2:?Usage: cf-api.sh <METHOD> <endpoint> [jq-filter]}"
JQ_FILTER="${3:-.}"

# Only allow read methods
if [[ "$METHOD" != "GET" && "$METHOD" != "get" ]]; then
  echo "ERROR: Only GET requests allowed (read-only token)" >&2
  exit 1
fi

TOKEN="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN in env}"
BASE="https://api.cloudflare.com/client/v4"

# Strip leading slash if present
ENDPOINT="${ENDPOINT#/}"

RESPONSE=$(curl -s -X GET "${BASE}/${ENDPOINT}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json")

# Check for API errors
SUCCESS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "parse_error")

if [[ "$SUCCESS" == "False" ]]; then
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

# Apply jq filter if available, fallback to python pretty-print
if command -v jq &>/dev/null; then
  echo "$RESPONSE" | jq "$JQ_FILTER"
else
  echo "$RESPONSE" | python3 -m json.tool
fi
