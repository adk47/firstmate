#!/usr/bin/env bash
# Download completed/signed documents from a DocuSign envelope.
# Usage: download-document.sh <envelope_id> [output_dir] [document_id]
#   document_id: specific doc ID, "combined" for all merged, or "archive" for ZIP (default: combined)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${DOCUSIGN_ACCOUNT_ID:?Set DOCUSIGN_ACCOUNT_ID}"
: "${DOCUSIGN_BASE_URI:?Set DOCUSIGN_BASE_URI}"

ENVELOPE_ID="${1:?Usage: download-document.sh <envelope_id> [output_dir] [document_id]}"
OUTPUT_DIR="${2:-.}"
DOC_ID="${3:-combined}"

TOKEN=$("$SCRIPT_DIR/docusign-auth.sh")
BASE="${DOCUSIGN_BASE_URI}/restapi/v2.1/accounts/${DOCUSIGN_ACCOUNT_ID}"

mkdir -p "$OUTPUT_DIR"

if [[ "$DOC_ID" == "archive" ]]; then
  OUTPUT_FILE="${OUTPUT_DIR}/${ENVELOPE_ID}_archive.zip"
  curl -s -o "$OUTPUT_FILE" \
    -H "Authorization: Bearer $TOKEN" \
    "${BASE}/envelopes/${ENVELOPE_ID}/documents/archive"
  echo "Downloaded: $OUTPUT_FILE"
elif [[ "$DOC_ID" == "combined" ]]; then
  OUTPUT_FILE="${OUTPUT_DIR}/${ENVELOPE_ID}_combined.pdf"
  curl -s -o "$OUTPUT_FILE" \
    -H "Authorization: Bearer $TOKEN" \
    "${BASE}/envelopes/${ENVELOPE_ID}/documents/combined"
  echo "Downloaded: $OUTPUT_FILE"
else
  OUTPUT_FILE="${OUTPUT_DIR}/${ENVELOPE_ID}_doc_${DOC_ID}.pdf"
  curl -s -o "$OUTPUT_FILE" \
    -H "Authorization: Bearer $TOKEN" \
    "${BASE}/envelopes/${ENVELOPE_ID}/documents/${DOC_ID}"
  echo "Downloaded: $OUTPUT_FILE"
fi
