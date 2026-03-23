#!/bin/bash
# Anrok API wrapper
# Usage: anrok-api.sh <endpoint> [json-body] [jq-filter]
# Example: anrok-api.sh transactions/list '{"limit":5}' '.transactions[:2]'
# Example: anrok-api.sh transactions/id:my-txn/void '{}'

# Load credentials (redirect all output)
source "$HOME/.zshrc" >/dev/null 2>&1 || true

if [ -z "${ANROK_API_KEY:-}" ]; then
  echo "Error: ANROK_API_KEY not set" >&2
  exit 1
fi

ENDPOINT="${1:?Usage: anrok-api.sh <endpoint> [json-body] [jq-filter]}"
BODY="${2:-"{}"}"
JQ_FILTER="${3:-}"

API_BASE="https://api.anrok.com/v1/seller"

RESPONSE=$(curl -s "${API_BASE}/${ENDPOINT}" \
  -X POST \
  -H "Authorization: Bearer ${ANROK_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${BODY}")

if [ -n "$JQ_FILTER" ]; then
  echo "$RESPONSE" | jq "$JQ_FILTER" 2>/dev/null || echo "$RESPONSE"
else
  echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
fi
