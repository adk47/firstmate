---
name: muso-docusign
description: |
  DocuSign eSignature — send documents for signature, manage envelopes, download signed docs, list templates.
  Uses DocuSign eSignature REST API v2.1 with JWT Grant authentication.

  WRITE ACCESS: Aaron (U7RP6HKUZ) and Fede (U07NF5A77E2) ONLY. All other users are blocked entirely.

  Use when: sending contracts/agreements for signature, checking envelope status, downloading signed documents,
  listing or using templates, managing DocuSign recipients, or any e-signature workflow.

  Triggers: "docusign", "signature", "sign", "envelope", "e-sign", "send for signature",
  "contract signing", "NDA", "agreement", "send document"
---

# DocuSign Skill

## Access Control (MANDATORY)

**Only Aaron (U7RP6HKUZ) and Fede (U07NF5A77E2) can use this skill.**
Check `sender_id` from inbound metadata. If anyone else asks, decline and tell them to ask Aaron.

## Authentication

JWT Grant flow via scripts. Tokens are cached in `/tmp/docusign_token.json` (1hr TTL).

Required env vars (set in `~/.zshrc`):
- `DOCUSIGN_INTEGRATION_KEY` — App's Integration Key (client ID)
- `DOCUSIGN_USER_ID` — `30e67e2d-a68d-4633-9956-d702ed7b615d`
- `DOCUSIGN_ACCOUNT_ID` — `10d725ac-6f47-4a57-8acf-ea29b26e0448`
- `DOCUSIGN_BASE_URI` — `https://na3.docusign.net`
- `DOCUSIGN_RSA_KEY_FILE` — Path to RSA private key PEM file
- `DOCUSIGN_AUTH_SERVER` — `account.docusign.com` (default, production)

## Scripts

All scripts are in `~/.openclaw/skills/skills/muso-docusign/scripts/`.

### API Wrapper
```bash
# Generic API calls — endpoint is relative to /restapi/v2.1/accounts/{account_id}
bash scripts/docusign-api.sh GET /envelopes
bash scripts/docusign-api.sh GET "/envelopes?from_date=2026-03-01T00:00:00Z"
bash scripts/docusign-api.sh GET /envelopes/<envelope_id>
bash scripts/docusign-api.sh GET /templates
```

### Send Document for Signature
```bash
bash scripts/send-envelope.sh <file_path> <signer_email> <signer_name> <subject> [cc_email] [cc_name]

# Example
bash scripts/send-envelope.sh contract.pdf "client@co.com" "Jane Doe" "Please sign the contract"
```

The document is base64-encoded and sent inline. Supports PDF, DOC, DOCX.

**Signature tab placement:** Uses anchor strings `/sn1/` (sign here) and `/ds1/` (date signed).
If the document doesn't have anchors, use the API wrapper to build a custom envelope with
absolute positioning (pageNumber, xPosition, yPosition) instead.

### Send from Template
```bash
bash scripts/send-from-template.sh <template_id> <signer_email> <signer_name> <subject> [cc_email] [cc_name]
```

### Download Signed Documents
```bash
bash scripts/download-document.sh <envelope_id> [output_dir] [document_id]
# document_id: specific ID, "combined" (default), or "archive" (ZIP)
```

## Common API Endpoints (via docusign-api.sh)

### Envelopes
```bash
# List recent envelopes (default: last 30 days)
bash scripts/docusign-api.sh GET /envelopes

# Filter by date and status
bash scripts/docusign-api.sh GET "/envelopes?from_date=2026-01-01T00:00:00Z&status=completed"

# Get envelope details
bash scripts/docusign-api.sh GET /envelopes/<id>

# Get envelope recipients
bash scripts/docusign-api.sh GET /envelopes/<id>/recipients

# Get envelope documents list
bash scripts/docusign-api.sh GET /envelopes/<id>/documents

# Void an envelope (unsent/sent only)
bash scripts/docusign-api.sh PUT /envelopes/<id> '{"status":"voided","voidedReason":"Cancelled"}'

# Resend envelope notification
bash scripts/docusign-api.sh PUT /envelopes/<id>/recipients '{"resendEnvelope":"true"}'
```

### Templates
```bash
# List all templates
bash scripts/docusign-api.sh GET /templates

# Get template details
bash scripts/docusign-api.sh GET /templates/<id>
```

### Search/Filter
```bash
# Search by email
bash scripts/docusign-api.sh GET "/envelopes?email=client@example.com&from_date=2025-01-01T00:00:00Z"

# Search by status: sent, delivered, signed, completed, declined, voided
bash scripts/docusign-api.sh GET "/envelopes?status=sent&from_date=2026-01-01T00:00:00Z"
```

## Envelope Statuses
- `created` — Draft, not sent
- `sent` — Sent to recipients, awaiting action
- `delivered` — Opened by recipient
- `signed` — Signed by recipient (multi-signer: may still be in progress)
- `completed` — All recipients finished, fully executed
- `declined` — Recipient declined to sign
- `voided` — Sender cancelled the envelope

## Write Activity Logging

All write operations (send envelope, void, resend) MUST be logged to `api-logs/docusign/YYYY-MM-DD.jsonl` BEFORE execution per SOUL.md rules.

## Tips
- `from_date` is required on most list queries (ISO 8601 format)
- Envelope IDs are UUIDs (e.g., `a1b2c3d4-e5f6-...`)
- For documents without anchor strings, build custom tab positioning via the API wrapper
- Template role names must match exactly what's defined in the template
