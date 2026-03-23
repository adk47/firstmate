#!/usr/bin/env bash
# DocuSign JWT auth — generates an access token and caches it.
# Requires: DOCUSIGN_INTEGRATION_KEY, DOCUSIGN_USER_ID, DOCUSIGN_RSA_KEY_FILE
# Outputs the access token to stdout. Caches in /tmp/docusign_token.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${DOCUSIGN_INTEGRATION_KEY:?Set DOCUSIGN_INTEGRATION_KEY}"
: "${DOCUSIGN_USER_ID:?Set DOCUSIGN_USER_ID}"
: "${DOCUSIGN_RSA_KEY_FILE:?Set DOCUSIGN_RSA_KEY_FILE}"
: "${DOCUSIGN_AUTH_SERVER:=account.docusign.com}"

CACHE="/tmp/docusign_token.json"

# Check cached token
if [[ -f "$CACHE" ]]; then
  EXPIRES=$(jq -r '.expires_at // 0' "$CACHE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if (( NOW < EXPIRES - 60 )); then
    jq -r '.access_token' "$CACHE"
    exit 0
  fi
fi

# Generate JWT assertion
JWT=$(python3 "$SCRIPT_DIR/generate_jwt.py" \
  --integration-key "$DOCUSIGN_INTEGRATION_KEY" \
  --user-id "$DOCUSIGN_USER_ID" \
  --rsa-key-file "$DOCUSIGN_RSA_KEY_FILE" \
  --auth-server "$DOCUSIGN_AUTH_SERVER")

# Exchange JWT for access token
RESPONSE=$(curl -s -X POST "https://${DOCUSIGN_AUTH_SERVER}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${JWT}")

# Check for error
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
if [[ -n "$ERROR" ]]; then
  echo "Auth failed: $(echo "$RESPONSE" | jq -r '.error_description // .error')" >&2
  exit 1
fi

ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
EXPIRES_IN=$(echo "$RESPONSE" | jq -r '.expires_in')
NOW=$(date +%s)
EXPIRES_AT=$((NOW + EXPIRES_IN))

# Cache it
jq -n --arg token "$ACCESS_TOKEN" --argjson exp "$EXPIRES_AT" \
  '{access_token: $token, expires_at: $exp}' > "$CACHE"

echo "$ACCESS_TOKEN"
