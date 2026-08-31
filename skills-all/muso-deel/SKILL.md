---
name: muso-deel
description: |
  USE THIS for Muso.AI's Deel contractor-payroll platform: look up people/contractors,
  contracts, invoices, payment runs, timesheets, invoice adjustments (bonuses/expenses/
  deductions), groups, and webhooks. ACCESS-GATED: BOTH read and write are Aaron
  (U7RP6HKUZ) ONLY — everyone else is blocked because Deel holds highly sensitive PII
  (addresses, birth dates, bank/compensation info). Never expose this data outside Aaron's DM.
---

# muso-deel — Deel Payroll & Contractor Management

Deel is Muso.AI's contractor payroll platform. All team members are hired as contractors through Deel.

## Access Control

- **READ access:** Aaron (U7RP6HKUZ) only
- **WRITE access:** Aaron (U7RP6HKUZ) only
- **Everyone else:** Blocked entirely. Deel contains PII (addresses, birth dates, bank info, compensation). No exceptions.

## API Configuration

- **Base URL:** `https://api.letsdeel.com/rest/v2`
- **Auth:** Bearer token (`DEEL_API_TOKEN` env var in `~/.zshrc`)
- **Token type:** Personal Access Token (JWT) with full scopes
- **Organization ID:** 34076
- **Legal entity:** Muso.AI Inc (`6a11cd03-963b-45bb-ab8b-d087e1f6ea11`)

## Wrapper Script

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-deel/scripts/deel-api.sh <METHOD> <endpoint> [json_body]
```

Source `~/.zshrc` before calling to ensure `DEEL_API_TOKEN` is set.

## Key Endpoints (verified working)

### People (team directory)
```bash
# All people (paginated, 50/page default)
GET /people
GET /people?hiring_statuses=active
GET /people?hiring_statuses=inactive
GET /people?offset=50&limit=50
# Single person
GET /people/{person_id}
```
Response includes: name, emails, birth_date, start_date, nationalities, addresses, employments (with payment rate/scale/currency), hiring_status, job_title, team, timezone, country

### Contracts
```bash
GET /contracts
GET /contracts?statuses[]=in_progress       # active only
GET /contracts?statuses[]=completed
GET /contracts/{contract_id}
```
Response includes: id, title, type, status, client, worker, signatures, termination_date

### Invoices
```bash
GET /invoices
GET /invoices?contract_id={id}
GET /invoices?statuses[]=pending
GET /invoices?statuses[]=paid
GET /invoices/{invoice_id}
```
Response includes: id, status, currency, total, amount, deel_fee, paid_at, due_date, contract_id, is_overdue

### Payments (batch payroll runs)
```bash
GET /payments
GET /payments?limit=10
GET /payments/{payment_id}
```
Response includes: id, payment_method, status, total, workers[], paid_at, label

### Timesheets
```bash
GET /timesheets
GET /timesheets?contract_id={id}
GET /timesheets?date_from=2026-01-01&date_to=2026-01-31
GET /timesheets/{timesheet_id}
```

### Invoice Adjustments (expenses, bonuses, deductions)
```bash
GET /invoice-adjustments
GET /invoice-adjustments?contract_id={id}
GET /invoice-adjustments?types[]=bonus
GET /invoice-adjustments?types[]=expense
POST /invoice-adjustments  # body: {contract_id, description, type, amount, ...}
```

### Groups (teams/departments)
```bash
GET /groups
```
Known groups: Customer Service, Marketing/Sales, Development, Catalog/Verification

### Organizations
```bash
GET /organizations
```

### Webhooks
```bash
GET /webhooks
POST /webhooks  # body: {name, url, events[]}
```

## Pagination

Most list endpoints support:
- `limit` (default 50, max varies)
- `offset` (for offset-based)
- Response includes `page.total_rows` and sometimes `page.cursor`

## Current State (as of 2026-03-10)

- **22 active people** (contractors)
- **24 active contracts**
- **3,982 invoices** total
- **260 payment runs** total
- **3,321 timesheets** total
- **4,327 invoice adjustments** total
- **6 groups** (teams)

## Data Notes

- All contractors are under **Muso.AI Inc** legal entity
- Payment scales: hourly, biweekly, semimonthly, monthly, custom
- All amounts in USD
- Teams: Development, Marketing/Sales, Customer Service, Catalog/Verification
- Key people with active contracts include engineering (Andrey, Serhii, Ihor S, Artem M, Jay), ops (Jan, Dave, McLaren, ops team in PH), marketing (Nick as CMO), devops (Artem D)

## PII Warning

Deel data contains highly sensitive PII:
- Full legal names, birth dates, nationalities
- Home addresses (full street-level)
- Personal email addresses
- Compensation details (rates, currencies)
- Bank/payment info (not exposed via API but referenced)

**NEVER expose this data in any shared channel.** Aaron's DM only.

## Write Operations (Aaron only)

Available writes with current token scopes:
- Create/update invoice adjustments (bonuses, expenses, deductions)
- Create invoices
- Manage timesheets
- Manage webhooks
- Update contracts, people profiles
- Manage groups

**All writes require Aaron's explicit instruction.** Log to `api-logs/deel/YYYY-MM-DD.jsonl` before execution.
