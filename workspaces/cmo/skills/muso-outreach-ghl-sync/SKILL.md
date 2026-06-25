---
name: muso-outreach-ghl-sync
description: |
  Keeps the outreach log sheet and the GHL B2B-Ads-Clio pipeline in sync.
  Creates contacts and opportunities in GHL on outreach send, moves stages on
  reply detection or meeting booking, and runs a daily full reconciliation sweep
  to catch any drift.

  Used by every other outreach subskill whenever state needs to be written to GHL.

  Use when: any state change that needs GHL update, daily full sync reconciliation

  Triggers: "sync ghl", "update pipeline", "move stage", "create opportunity",
  "ghl reconcile"
depends-on:
  - muso-outreach-engine
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Outreach GHL Sync

Single point of GHL write operations for the outreach engine. Every other
subskill calls this one when state needs to be reflected in GHL.

## Access Control

Write access: Nick (U0AL36NADEY) and Aaron (U7RP6HKUZ) only. Cron operations
run under the system identity (approved for automated stage moves).

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Location & Pipeline

- **Location**: `S5w31kRRgsBjjiVATWlP` (B2B Ads sales, NOT the churn win back location)
- **Pipeline**: `B2B-Ads-Clio` (`GeSt85TueSvJ0SNFZXfQ`)
- **API**: `$GHL_API_KEY`, Version `2021-07-28`

## API Operations

### Create Contact

```bash
source ~/.zshrc && curl -s "https://services.leadconnectorhq.com/contacts/" \
  -X POST \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -H "Content-Type: application/json" \
  -d '{
    "locationId": "S5w31kRRgsBjjiVATWlP",
    "firstName": "<first>",
    "lastName": "<last>",
    "email": "<email>",
    "companyName": "<company>",
    "customFields": [{"key": "sheet_row_id", "field_value": "<row_id>"}],
    "tags": ["B2B-Ads", "Outreach"]
  }' | python3 -m json.tool
```

### Create Opportunity

```bash
source ~/.zshrc && curl -s "https://services.leadconnectorhq.com/opportunities/" \
  -X POST \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -H "Content-Type: application/json" \
  -d '{
    "locationId": "S5w31kRRgsBjjiVATWlP",
    "pipelineId": "GeSt85TueSvJ0SNFZXfQ",
    "pipelineStageId": "<STAGE_ID>",
    "name": "<Company> | <Contact Name>",
    "contactId": "<contact_id>",
    "status": "open"
  }' | python3 -m json.tool
```

### Move Opportunity Stage

```bash
source ~/.zshrc && curl -s "https://services.leadconnectorhq.com/opportunities/<opportunity_id>" \
  -X PUT \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -H "Content-Type: application/json" \
  -d '{
    "pipelineStageId": "<NEW_STAGE_ID>"
  }' | python3 -m json.tool
```

### Search Opportunities (GET with pagination, NOT POST)

```bash
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=S5w31kRRgsBjjiVATWlP" \
  -d "pipeline_id=GeSt85TueSvJ0SNFZXfQ" \
  -d "limit=100" -d "page=1" | python3 -m json.tool
```

**Always paginate** until 0 results (`page=1`, `page=2`, `page=3`, etc).
POST `/opportunities/search` is broken, caps at 100, cursor does not work.

## Standard Operations

### On Outreach Send (called by muso-outreach-sender)

Input: contact row, company row, sender account, template used, `sheet_row_id`.

1. Check if contact already exists in GHL (search by email)
2. If not, create contact with `sheet_row_id` custom field + B2B-Ads tag
3. Check if opportunity already exists for this company + contact
4. If not, create opportunity at `Emailed` stage
5. Log to `api-logs/ghl/YYYY-MM-DD.jsonl`
6. Return opportunity ID to caller

### On Follow Up Send (called by muso-outreach-followup)

Input: opportunity ID, FU number.

1. Move opportunity stage to `Follow-up`
2. Log to `api-logs/ghl/YYYY-MM-DD.jsonl`

### On Reply Detection (called by muso-outreach-reply-scanner)

Input: contact email, reply type.

1. Search for contact in GHL
2. Find the opportunity in B2B-Ads-Clio
3. Move stage based on reply type:
   - `Send more info`, `Adding colleague`, `Interesting`, `Pivot` → `Replied`
   - `Let's schedule` → `Meeting Booked`
   - `We pass` → `Closed Lost`
4. Log to `api-logs/ghl/YYYY-MM-DD.jsonl`

### On Meeting Booked (called by muso-outreach-calendar)

Input: contact email, meeting details.

1. Search for contact in GHL
2. Find the opportunity
3. Move stage to `Meeting Booked`
4. Append meeting details to the opportunity notes
5. Log to `api-logs/ghl/YYYY-MM-DD.jsonl`

## Daily Full Reconciliation

Runs once per day as a safety net. Catches any drift between sheet and GHL.

### Steps

1. Pull the full `muso-b2b-outreach-reports` logbook
2. Pull all opportunities in B2B-Ads-Clio (paginate ALL pages)
3. For each logbook row without a matching GHL opportunity → create it
4. For each GHL opportunity without a matching logbook entry → log it
5. For each pair where stages disagree:
   - If logbook is newer → update GHL
   - If GHL is newer → append a sync row to logbook
6. Post reconciliation summary to `#sales-alerts`:

```
🔄 *GHL Sync Reconciliation, YYYY-MM-DD*

Sheet rows: {N}
GHL opportunities: {M}
Drift fixed: {K} stages reconciled
New GHL contacts created from sheet: {X}
New logbook rows from GHL: {Y}
```

If `Drift fixed > 10`, flag for Nick review (something is wrong upstream).

## Custom Fields

These must exist on the GHL Contact object:
- `sheet_row_id`: the `Row ID` from NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`) (enables reverse lookup)

If the field does not exist, the startup checklist will fail and prompt Nick to
create it in GHL.

## Error Handling

- If create contact returns 409 (already exists): search, return existing contact ID
- If create opportunity returns 409: search, return existing opp ID
- If stage move returns 404: opportunity was deleted, log error and alert Nick
- If API returns 401: `$GHL_API_KEY` may have expired, escalate to Aaron

## Constraints

- Never skip logging to `api-logs/ghl/`
- Never write to the Churn Win Back location (`fmK5Vl9sJv49WTYA0QyP`)
- Never create an opportunity without `sheet_row_id` set
- Never create a contact without `B2B-Ads` and `Outreach` tags
- Always use GET + `page=N` for searches (POST is broken)
- Always use the version header `Version: 2021-07-28`
