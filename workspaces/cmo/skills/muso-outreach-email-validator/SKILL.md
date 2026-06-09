---
name: muso-outreach-email-validator
description: |
  Validates email addresses via Snov.io SMTP verification before any outreach
  batch is sent. This is the pre-send verification gate that prevents bounces.

  Called by muso-outreach-sender (Step 5.5), muso-outreach-followup, and
  muso-winback-sender before presenting any batch for approval. Can also be
  called standalone to verify individual emails or run a bulk sweep.

  Use when: "verify email", "check email", "validate email", "is this email valid",
  "pre-send check", "email validation", "bulk email check"

  Triggers: "verify email", "validate email", "check email", "email valid",
  "bounce check", "snov check", "pre-send validation"
depends-on:
  - muso-outreach-engine
metadata:
  version: "1.0"
  last-updated: "2026-04-11"
  status: "ACTIVE"
---

# Muso Outreach Email Validator

Pre-send email verification gate using Snov.io SMTP validation. Prevents bounces
by checking every email address before it leaves our system.

## Status: ACTIVE (since 2026-04-11)

## Shared Config

All Snov.io API details are in `../muso-outreach-engine/references/config.md`
(Snov.io section). Never hardcode credentials or endpoints.

## When This Skill Runs

This skill is called in three contexts:

1. **Pre-batch gate** (MANDATORY): Called by `muso-outreach-sender` at Step 5.5,
   `muso-outreach-followup`, and `muso-winback-sender` before presenting any
   batch for approval. This is non-negotiable.

2. **Single email check** (on demand): Anyone asks "is this email valid?" or
   "check this email for me."

3. **Bulk database sweep** (on demand): Verify all emails in NocoDB Contacts
   Intelligence and write results back to NocoDB.

## Authentication

Snov.io uses OAuth2 client_credentials. Token lasts 1 hour.

```bash
TOKEN=$(curl -s -X POST https://api.snov.io/v1/oauth/access_token \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials","client_id":"'"$SNOVIO_CLIENT_ID"'","client_secret":"'"$SNOVIO_CLIENT_SECRET"'"}' | jq -r '.access_token')
```

- Env vars: `$SNOVIO_CLIENT_ID`, `$SNOVIO_CLIENT_SECRET`
- Cache the token. Refresh at 55 minutes (before the 60-minute expiry).
- If token request fails, STOP. Do not proceed with unverified emails.

## Single Email Verification

### Step 1: Submit for verification

```bash
curl -s -X POST "https://api.snov.io/v1/add-emails-to-verification" \
  -H "Content-Type: application/json" \
  -d '{"access_token":"'"$TOKEN"'","emails":["target@company.com"]}'
```

### Step 2: Poll for result

```bash
curl -s -X POST "https://api.snov.io/v1/get-emails-verification-status" \
  -H "Content-Type: application/json" \
  -d '{"access_token":"'"$TOKEN"'","emails":["target@company.com"]}'
```

### Step 3: Read the result

Response includes per-email:
- `smtpStatus`: `valid`, `not_valid`, `unknown`, or `not_verified` (still processing)
- `isValidFormat`: boolean
- `isDisposable`: boolean
- `isWebmail`: boolean
- `isGibberish`: boolean
- `isCatchall`: boolean (domain accepts all addresses)
- `isGreylist`: boolean
- `isBannedError`: boolean
- `isConnectionError`: boolean

## Batch Verification (Pre-Send Gate)

Used by sender skills before presenting a batch for approval.

### Step 1: Collect all emails from the batch

Extract the `Valid Professional Email` for every contact in the batch.

### Step 2: Submit all emails at once

The `add-emails-to-verification` endpoint accepts multiple emails in one call:

```bash
curl -s -X POST "https://api.snov.io/v1/add-emails-to-verification" \
  -H "Content-Type: application/json" \
  -d '{"access_token":"'"$TOKEN"'","emails":["email1@a.com","email2@b.com","email3@c.com"]}'
```

### Step 3: Poll with retry

Wait 5 seconds after submission, then check status:

```bash
curl -s -X POST "https://api.snov.io/v1/get-emails-verification-status" \
  -H "Content-Type: application/json" \
  -d '{"access_token":"'"$TOKEN"'","emails":["email1@a.com","email2@b.com","email3@c.com"]}'
```

**Polling logic:**
- First poll: 5 seconds after submission
- If ANY email has `status.identifier: "not_verified"` (still processing), wait 5 more seconds
- Max retries: 6 (total wait: 30 seconds)
- If still not complete after 30 seconds: treat as timeout

For large batches (50+ emails), split into chunks of 50 and process sequentially
to avoid rate limiting. Wait 2 seconds between chunks.

### Step 4: Apply decision matrix

| smtpStatus | isCatchall | Action | Batch Note |
|------------|------------|--------|------------|
| `valid` | any | PROCEED | (none, normal entry) |
| `not_valid` | any | SKIP | :x: SKIPPED: {Name}, {Company} - email invalid (Snov.io SMTP: not_valid) |
| `unknown` | `true` | PROCEED | :warning: RISKY (catch-all): {Name}, {Company} - domain accepts all addresses, won't bounce but can't confirm delivery |
| `unknown` | `false` | PROCEED | :warning: UNVERIFIABLE: {Name}, {Company} - Snov.io could not confirm |
| `not_verified` (timeout) | any | STOP | :octagonal_sign: TIMEOUT: Snov.io did not complete verification in 30s. Do NOT send. Retry or notify Fede. |
| API error | any | STOP | :octagonal_sign: API ERROR: Snov.io unreachable. Do NOT send. Notify Fede. |

### Step 5: Handle skipped contacts

For every email that returns `not_valid`:

1. Update NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`): set `Status` =
   `Email Invalid (Snov)` for that contact's row, via the `muso-nocodb` skill —
   `bash scripts/nocodb-api.sh records.update m9vsbijhrr9ddeu '[{"Id":<id>,"Status":"Email Invalid (Snov)"}]'`
   (look up `<id>` first with `records.ls … --where "(Valid Professional Email,eq,<email>)" --fields "Id"`).
2. Log to `api-logs/snov/YYYY-MM-DD.jsonl`
3. If the contact was in GHL, update the opportunity notes with "Email invalid per Snov.io verification {date}"
4. Include the skip in the batch presentation so Fede sees what was dropped

### Step 6: Present results

In the batch presentation (before the email drafts), include a verification summary:

```
*Email Verification (Snov.io)*
:white_check_mark: {N} valid
:warning: {N} catch-all (will send, flagged)
:warning: {N} unverifiable (will send, flagged)
:x: {N} invalid (skipped)
```

Then list the skipped contacts with reasons.

## Bulk Database Sweep

For verifying the entire NocoDB Contacts Intelligence table on demand.

### Step 1: Pull all emails

```bash
# Paginate with --offset for >1000 rows. Use the muso-nocodb skill (REST API, no MCP).
bash scripts/nocodb-api.sh --raw records.ls m9vsbijhrr9ddeu \
  --fields "Id,Domain,Company Name,First Name,Last Name,Valid Professional Email,Status" \
  --limit 1000 --offset 0
```

Use the `Valid Professional Email` field (and the row `Id`, needed for write-back) for all rows.

### Step 2: Batch verify in chunks

Split into chunks of 50 emails. For each chunk:
1. Submit to `add-emails-to-verification`
2. Wait 8 seconds
3. Poll `get-emails-verification-status`
4. If any still processing, retry up to 6 times (5s intervals)
5. Wait 2 seconds before next chunk

### Step 3: Write results back to NocoDB

Ensure two columns exist on Contacts Intelligence (`m9vsbijhrr9ddeu`), creating
them once if missing (via the `muso-nocodb` skill, `columns.add`):
- `Snov Email Status` (SingleLineText): the `smtpStatus` value (`valid`, `not_valid`, `unknown`)
- `Snov Verified Date` (SingleLineText): ISO date of verification (YYYY-MM-DD)

Then update each row by its `Id` with the verification result (bulk PATCH takes an array):
```bash
bash scripts/nocodb-api.sh records.update m9vsbijhrr9ddeu \
  '[{"Id":<id>,"Snov Email Status":"valid","Snov Verified Date":"YYYY-MM-DD"}, …]'
```

### Step 4: Summary report

Post to the requesting channel:

```
*Bulk Email Verification Complete*

Total checked: {N}
:white_check_mark: Valid: {N} ({%})
:x: Invalid: {N} ({%})
:warning: Unknown/Catch-all: {N} ({%})
:warning: Failed to verify: {N} ({%})

Invalid emails (need replacement):
  1. {Name}, {Company} - {email}
  2. ...
```

## Credit Management

- 1 credit per email verified
- Already-verified emails (cached by Snov.io) do not consume credits
- Check balance: `GET https://api.snov.io/v1/get-balance?access_token=$TOKEN`
- Current plan resets every 3 days
- Before running a bulk sweep, check balance first. If credits < emails to verify,
  warn Fede and ask if they want a partial sweep or to wait for reset.

## Logging

Every verification call MUST be logged to `api-logs/snov/YYYY-MM-DD.jsonl`:

```json
{"timestamp":"ISO8601","action":"email-verify","email":"...","smtpStatus":"valid|not_valid|unknown","isCatchall":false,"isDisposable":false,"credits":1,"context":"pre-send|bulk-sweep|on-demand"}
```

## Constraints (HARD RULES)

- NEVER let an unverified email through to a batch presentation
- NEVER send if Snov.io is down or unreachable. STOP and notify Fede.
- NEVER skip this step, even for "just one quick email"
- NEVER store Snov.io credentials in files, memory, or logs (env vars only)
- ALWAYS log every verification call
- ALWAYS check credit balance before bulk sweeps
- ALWAYS include the verification summary in batch presentations
- If a previously valid email returns `not_valid` on re-check, update NocoDB
  immediately (email addresses decay over time)
