#!/usr/bin/env bash
# DocuSign eSignature REST API wrapper.
# Usage: docusign-api.sh <METHOD> <endpoint> [body]
#
# Examples:
#   docusign-api.sh GET /envelopes
#   docusign-api.sh POST /envelopes '{"documents":[...]}'
#   docusign-api.sh GET /envelopes/ENV_ID
#   docusign-api.sh GET /templates
#
# Endpoints are relative to /restapi/v2.1/accounts/{account_id}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${DOCUSIGN_ACCOUNT_ID:?Set DOCUSIGN_ACCOUNT_ID}"
: "${DOCUSIGN_BASE_URI:?Set DOCUSIGN_BASE_URI}"

METHOD="${1:?Usage: docusign-api.sh <METHOD> <endpoint> [body]}"
ENDPOINT="${2:?Usage: docusign-api.sh <METHOD> <endpoint> [body]}"
BODY="${3:-}"

# Get auth token
TOKEN=$("$SCRIPT_DIR/docusign-auth.sh")

BASE="${DOCUSIGN_BASE_URI}/restapi/v2.1/accounts/${DOCUSIGN_ACCOUNT_ID}"
URL="${BASE}${ENDPOINT}"

CURL_ARGS=(
  -s
  -X "$METHOD"
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

if [[ -n "$BODY" ]]; then
  CURL_ARGS+=(-d "$BODY")
fi

curl "${CURL_ARGS[@]}" "$URL" | jq .
