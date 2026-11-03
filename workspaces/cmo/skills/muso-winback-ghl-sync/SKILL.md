---
name: muso-winback-ghl-sync
description: |
  Single point of GHL write operations for the win back engine. Creates contacts
  and opportunities, moves stages, runs daily reconciliation between sheet and
  GHL. Uses the Win Back location (fmK5Vl9sJv49WTYA0QyP) and the GHL_WINBACK_API_KEY,
  never the B2B Ads location or key.

  Used by every other winback subskill whenever state needs to be written to GHL.

  Use when: any state change that needs GHL update, daily reconciliation

  Triggers: "sync winback ghl", "move winback stage", "winback reconcile"
depends-on:
  - muso-winback-engine
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Win Back GHL Sync

Single point of GHL writes for the win back engine.

## CRITICAL: Right Location, Right API Key

Always use the **Win Back location** and the **Win Back API key**:

- Location ID: `fmK5Vl9sJv49WTYA0QyP`
- API key: `$GHL_WINBACK_API_KEY` (NOT `$GHL_API_KEY` which is for B2B Ads)
- Pipeline: `Churn -> Win-back` (`AZa8jK5S7UyQ0fqfxzyB`)

If you accidentally use the B2B Ads key or location, the request will either
fail or write to the wrong pipeline. The QA skill catches this drift.

## Access Control

Read by all subskills. Writes are triggered only by Aaron or Nick via approval flow.

## Shared Config

See `../muso-winback-engine/references/config.md`.

## API Operations

### Create Contact

```bash
body=$(mktemp) && cat > "$body" <<'JSON'
{
    "locationId": "fmK5Vl9sJv49WTYA0QyP",
    "firstName": "<first>",
    "lastName": "<last>",
    "email": "<email>",
    "tags": ["win-back-pro", "<tier_tag>", "<reason_tag>"],
    "customFields": [{"key": "sheet_row_id", "field_value": "<row_index>"}]
}
JSON
/opt/hydra/scripts/ghl.sh --account winback --data-file "$body" POST "/contacts/"; rc=$?
rm -f "$body"; (exit "$rc")  # payload removed on success and failure; block exits with ghl.sh's code
```

### Create Opportunity

```bash
body=$(mktemp) && cat > "$body" <<'JSON'
{
    "locationId": "fmK5Vl9sJv49WTYA0QyP",
    "pipelineId": "AZa8jK5S7UyQ0fqfxzyB",
    "pipelineStageId": "<STAGE_ID>",
    "name": "<first> <last> | <profile_name>",
    "contactId": "<contact_id>",
    "monetaryValue": <total_ltv>,
    "status": "open"
}
JSON
/opt/hydra/scripts/ghl.sh --account winback --data-file "$body" POST "/opportunities/"; rc=$?
rm -f "$body"; (exit "$rc")  # payload removed on success and failure; block exits with ghl.sh's code
```

### Move Stage

```bash
body=$(mktemp) && cat > "$body" <<'JSON'
{
    "pipelineStageId": "<NEW_STAGE_ID>"
}
JSON
/opt/hydra/scripts/ghl.sh --account winback --data-file "$body" PUT "/opportunities/<opportunity_id>"; rc=$?
rm -f "$body"; (exit "$rc")  # payload removed on success and failure; block exits with ghl.sh's code
```

### Search Opportunities (GET with pagination)

```bash
/opt/hydra/scripts/ghl.sh --account winback GET /opportunities/search \
  location_id=fmK5Vl9sJv49WTYA0QyP pipeline_id=AZa8jK5S7UyQ0fqfxzyB \
  limit=100 page=1
```

Always paginate `page=N` until 0 results. POST search is broken (caps at 100,
cursor does not work).

## Standard Operations

### On Initial Send (called by muso-winback-sender)

Input: row data, sender account.

1. Search for contact by email in GHL win back location
2. If not found, create contact with tags
3. Search for opportunity by contact ID
4. If not found, create opportunity at `Emailed` stage with monetary value = Total LTV
5. If found at `Churned` or `Next Up`, move to `Emailed`
6. Log to `api-logs/ghl-winback/YYYY-MM-DD.jsonl`

### On Follow Up Send (called by muso-winback-followup)

Input: opportunity ID, FU number.

1. Move opportunity stage to `Follow-up` (no stage change for FU-02 since already in Follow-up)
2. Append note to opportunity: "FU-{N} sent on {date}"
3. Log

### On Reply Detection (called by muso-winback-reply-scanner)

Input: email, reply classification.

| Classification | New Stage |
|----------------|-----------|
| Interested, Question, Price objection, Cancel elaboration | Replied |
| Negative, Angry | Lost / No Answer |
| Re subscribed | Re-subscribed |

1. Search for contact by email
2. Find opportunity in `Churn -> Win-back` pipeline
3. Move stage per table
4. Append reply summary to opportunity notes
5. Log

### On Day 90 Lost (called by muso-winback-followup)

Input: opportunity ID.

1. Move stage to `Lost / No Answer`
2. Append note: "Day 90 reached with no reply"
3. Log

### On Stripe Re Subscription (called by muso-winback-sender or muso-winback-reply-scanner)

Input: email.

1. Search for contact by email
2. Move opportunity to `Re-subscribed`
3. Update monetary value to current LTV (not historical)
4. Append note: "Re subscribed on {date}, plan: {plan}"
5. Log

## Daily Reconciliation

Runs once per day as a safety net. Catches drift between sheet and GHL.

### Steps

1. Pull entire `high_value_churn` sheet
2. Pull all opportunities in `Churn -> Win-back` pipeline (paginate ALL pages)
3. For each sheet row without a matching GHL contact, create it
4. For each GHL opportunity without a matching sheet row, log it (probable manual GHL add)
5. For each pair where stage disagrees:
   - Sheet `Pipeline Stage` should equal GHL stage
   - If sheet is newer (per `email_sent_date` or `Reply Date`), update GHL
   - If GHL is newer, update sheet
6. Run a fresh Stripe check on all `Emailed` and `Follow-up` stage opportunities
   - If any are now active subscribers, move to `Re-subscribed`
7. Post reconciliation summary to `#win-back-alerts`:

```
🔄 *Win Back GHL Reconciliation, YYYY-MM-DD*

Sheet rows: {N}
GHL opportunities: {M}
Drift fixed: {K} stage corrections
Stripe re subscribers detected: {S}

Stage breakdown:
  Churned: {a}
  Next Up: {b}
  Emailed: {c}
  Replied: {d}
  Follow-up: {e}
  Re-subscribed: {f}
  Lost / No Answer: {g}
```

If drift fixed > 10, flag for Nick review (something is wrong upstream).

## Custom Fields

Required on every Win Back contact:
- `sheet_row_id`: row index in `high_value_churn` (enables reverse lookup)

If the field does not exist in the GHL location, the STARTUP.md checklist will
fail and prompt Nick to create it.

## Error Handling

- `ghl.sh` exit 10 (401), 11 (Cloudflare 1010) or 12 (other 403) → retry once; still failing → page DevOps with the stderr line, not Aaron or Nick
- 404 Not Found → opportunity was deleted, log error and alert
- 409 Conflict → contact or opportunity already exists, fetch and return existing ID

## Constraints

- ALWAYS use `$GHL_WINBACK_API_KEY` (never `$GHL_API_KEY`)
- ALWAYS use location `fmK5Vl9sJv49WTYA0QyP` (never `S5w31kRRgsBjjiVATWlP`)
- ALWAYS use pipeline `AZa8jK5S7UyQ0fqfxzyB` (never B2B-Ads-Clio)
- ALWAYS log to `api-logs/ghl-winback/`
- ALWAYS use GET + `page=N` for searches (POST is broken)
- ALWAYS pass `Version: 2021-07-28` header
