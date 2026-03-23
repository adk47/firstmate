#!/usr/bin/env bash
# Send an envelope from a DocuSign template.
# Usage: send-from-template.sh <template_id> <signer_email> <signer_name> <subject> [cc_email] [cc_name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TEMPLATE_ID="${1:?Usage: send-from-template.sh <template_id> <signer_email> <signer_name> <subject> [cc_email] [cc_name]}"
SIGNER_EMAIL="${2:?Signer email required}"
SIGNER_NAME="${3:?Signer name required}"
SUBJECT="${4:?Subject required}"
CC_EMAIL="${5:-}"
CC_NAME="${6:-}"

# Build template roles
ROLES='[{"email":"'"$SIGNER_EMAIL"'","name":"'"$SIGNER_NAME"'","roleName":"Signer"}]'
if [[ -n "$CC_EMAIL" && -n "$CC_NAME" ]]; then
  ROLES='[{"email":"'"$SIGNER_EMAIL"'","name":"'"$SIGNER_NAME"'","roleName":"Signer"},{"email":"'"$CC_EMAIL"'","name":"'"$CC_NAME"'","roleName":"CC"}]'
fi

ENVELOPE=$(jq -n \
  --arg subject "$SUBJECT" \
  --arg templateId "$TEMPLATE_ID" \
  --argjson roles "$ROLES" \
  '{
    "emailSubject": $subject,
    "templateId": $templateId,
    "templateRoles": $roles,
    "status": "sent"
  }')

"$SCRIPT_DIR/docusign-api.sh" POST /envelopes "$ENVELOPE"
