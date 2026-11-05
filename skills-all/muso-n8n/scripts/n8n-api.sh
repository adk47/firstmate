#!/usr/bin/env bash
# n8n API wrapper script
# Usage: n8n-api.sh <METHOD> <endpoint> [json-body]
# Examples:
#   n8n-api.sh GET /workflows
#   n8n-api.sh POST /workflows/123/activate
#   n8n-api.sh PUT /workflows/123 '{"name":"Updated"}'

set -euo pipefail

METHOD="${1:?Usage: n8n-api.sh <METHOD> <endpoint> [json-body]}"
ENDPOINT="${2:?Usage: n8n-api.sh <METHOD> <endpoint> [json-body]}"
BODY="${3:-}"

# Validate env vars
if [[ -z "${N8N_API_KEY:-}" ]]; then
  echo "ERROR: N8N_API_KEY not set. It comes from the gateway env (/etc/openclaw/main.env, openclaw-gateway-main). Tell DevOps which variable is missing; do not request it." >&2
  exit 1
fi

if [[ -z "${N8N_BASE_URL:-}" ]]; then
  echo "ERROR: N8N_BASE_URL not set. It comes from the gateway env (/etc/openclaw/main.env, openclaw-gateway-main). Tell DevOps which variable is missing; do not request it." >&2
  exit 1
fi

# Strip trailing slash from base URL
BASE="${N8N_BASE_URL%/}"

# Build full URL
URL="${BASE}/api/v1${ENDPOINT}"

# Build curl args
CURL_ARGS=(
  -s
  -X "$METHOD"
  -H "accept: application/json"
  -H "X-N8N-API-KEY: ${N8N_API_KEY}"
)

if [[ -n "$BODY" ]]; then
  CURL_ARGS+=(-H "Content-Type: application/json" -d "$BODY")
fi

# Make the request
RESPONSE=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "$URL")

# Split response body and status code
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')

# Pretty print if jq available
if command -v jq &>/dev/null && echo "$BODY_RESPONSE" | jq . &>/dev/null 2>&1; then
  echo "$BODY_RESPONSE" | jq .
else
  echo "$BODY_RESPONSE"
fi

# Exit with error if non-2xx
if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "HTTP $HTTP_CODE" >&2
  exit 1
fi
