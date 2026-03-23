#!/usr/bin/env bash
# Deel REST API v2 wrapper
# Usage: deel-api.sh <METHOD> <endpoint> [json_body]
# Example: deel-api.sh GET /people
#          deel-api.sh GET "/people?hiring_statuses=active&limit=10"
#          deel-api.sh POST /invoice-adjustments '{"contract_id":"abc","description":"Bonus"}'

set -euo pipefail

METHOD="${1:?Usage: deel-api.sh METHOD endpoint [body]}"
ENDPOINT="${2:?Usage: deel-api.sh METHOD endpoint [body]}"
BODY="${3:-}"

BASE="https://api.letsdeel.com/rest/v2"

# Strip leading slash if present
ENDPOINT="${ENDPOINT#/}"

if [[ -z "$DEEL_API_TOKEN" ]]; then
  echo "Error: DEEL_API_TOKEN not set" >&2
  exit 1
fi

ARGS=(
  -s
  -X "$METHOD"
  -H "Authorization: Bearer $DEEL_API_TOKEN"
  -H "Content-Type: application/json"
)

if [[ -n "$BODY" ]]; then
  ARGS+=(-d "$BODY")
fi

curl "${ARGS[@]}" "${BASE}/${ENDPOINT}"
