#!/usr/bin/env bash
# Send a document for signature via DocuSign.
# Usage: send-envelope.sh <document_path> <signer_email> <signer_name> <subject> [cc_email] [cc_name]
#
# Example:
#   send-envelope.sh contract.pdf "client@example.com" "Jane Doe" "Please sign the contract"
#   send-envelope.sh nda.pdf "client@example.com" "Jane Doe" "NDA for review" "legal@muso.ai" "Legal Team"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DOC_PATH="${1:?Usage: send-envelope.sh <doc_path> <signer_email> <signer_name> <subject> [cc_email] [cc_name]}"
SIGNER_EMAIL="${2:?Signer email required}"
SIGNER_NAME="${3:?Signer name required}"
SUBJECT="${4:?Subject required}"
CC_EMAIL="${5:-}"
CC_NAME="${6:-}"

# Determine file extension and MIME type
FILENAME=$(basename "$DOC_PATH")
EXT="${FILENAME##*.}"
case "${EXT,,}" in
  pdf) MIME="application/pdf" ;;
  doc|docx) MIME="application/vnd.openxmlformats-officedocument.wordprocessingml.document" ;;
  *) MIME="application/octet-stream" ;;
esac

# Base64 encode the document
DOC_B64=$(base64 < "$DOC_PATH")

# Build recipients
RECIPIENTS=$(cat <<EOF
{
  "signers": [{
    "email": "$SIGNER_EMAIL",
    "name": "$SIGNER_NAME",
    "recipientId": "1",
    "routingOrder": "1",
    "tabs": {
      "signHereTabs": [{
        "anchorString": "/sn1/",
        "anchorUnits": "pixels",
        "anchorXOffset": "10",
        "anchorYOffset": "0"
      }],
      "dateSignedTabs": [{
        "anchorString": "/ds1/",
        "anchorUnits": "pixels",
        "anchorXOffset": "10",
        "anchorYOffset": "0"
      }]
    }
  }]
}
EOF
)

# Add CC if provided
if [[ -n "$CC_EMAIL" && -n "$CC_NAME" ]]; then
  RECIPIENTS=$(echo "$RECIPIENTS" | jq --arg email "$CC_EMAIL" --arg name "$CC_NAME" \
    '.carbonCopies = [{"email": $email, "name": $name, "recipientId": "2", "routingOrder": "2"}]')
fi

# Build envelope
ENVELOPE=$(jq -n \
  --arg subject "$SUBJECT" \
  --arg docB64 "$DOC_B64" \
  --arg filename "$FILENAME" \
  --arg ext "$EXT" \
  --argjson recipients "$RECIPIENTS" \
  '{
    "emailSubject": $subject,
    "documents": [{
      "documentBase64": $docB64,
      "name": $filename,
      "fileExtension": $ext,
      "documentId": "1"
    }],
    "recipients": $recipients,
    "status": "sent"
  }')

# Send via API
"$SCRIPT_DIR/docusign-api.sh" POST /envelopes "$ENVELOPE"
