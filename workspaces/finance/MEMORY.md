# MEMORY.md — FINANCE Agent

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned
_(none yet — agent will populate during operation)_

## Key Context
_(initialized 2026-03-22)_

## Migrated from Clio (2026-03-23)

### Recurring Invoices Master List
- Liza Basco manages payout reconciliation and recurring invoice tracking in #finance_muso.
- Stripe is the billing system of record.
- 9 Stripe products with `business_line` and `tier` metadata (added 2026-02-25).
- Product categories: Pro Plan, Business Plan, Plaque, Bulk Data Feed, API Access.
- 1,170 active Business subs (680 monthly, 509 annual) as of Feb 2026.
- ~35-50 Pro cancellations per day.
- 767 refunds ($79,630) in week of Feb 10, 1,506 new subs vs 2,666 cancellations (net -1,160).

### Invoice Creation Rules
- **ACH payment option is MANDATORY** on all invoices. Never create an invoice without ACH.
- Stripe amounts are in CENTS — always divide by 100 for dollars. (Lesson: displayed $3,000 instead of $30 once.)
- Demo payout: po_1T4WVu — 419 charges, mostly Pro (386) + Business (27).

### Payout Reports Requirements (Liza's Rules)
- Payout reports must include: payout_id, charge_id, amount_usd, fee_usd, net_usd, description, customer_email, product_name, business_line, tier, charge_date.
- Include charges, refunds, and Stripe fee rows separately.
- ~600 charges per payout takes ~3-5 min with parallel enrichment.
- Reports match standard Stripe Dashboard CSV export format + 3 enrichment columns.

#### Subscription Types
- Pro Monthly, Pro Annual, Pro Trial
- Business Monthly, Business Annual
- Encore (promotional, Nov-Feb yearly)

#### Charge + Payment Types
- Charges: subscription renewal, one-time purchase (plaque, data feed, API)
- Payments: card, ACH
- Refunds: full or partial, tracked separately
- Stripe fees: included as separate rows in reports

### Stripe Product Map (Prod IDs to Names)
| Product Pattern | Product Name | Business Line | Tier |
|----------------|--------------|---------------|------|
| Pro Plan / Pro | Muso Pro | credits | pro |
| Business Plan / Business | Muso Business | credits | business |
| Plaque | Digital Plaque | plaque | plaque |
| Bulk Data Feed | Data Feed | data | enterprise |
| API Access | API Access | api | enterprise |

If a product has no metadata, fall back to product name matching using patterns above.

### Non-Subscription Product Labeling Rules
- Plaques, data feeds, and API access are one-time or custom-billed — NOT subscriptions.
- Label them by their `business_line` (plaque, data, api), never as "subscription."
- Custom invoices (e.g., Kali Audio $2,500/mo) are ads contracts, not subscription revenue.
