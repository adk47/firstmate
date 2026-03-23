---
name: muso-stripe-payout-enricher
description: |
  Enrich Stripe payout reports with product/plan type info.
  When Liza or anyone in #finance_muso asks for a payout report with a payout ID,
  run the enrichment script and return the CSV.

  Triggers: "payout", "payout id", "enrich payout", "payout report", "po_"
compatibility: |
  Requires Stripe CLI with charges/invoices/products read. Uses enrich-payout.sh script.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Stripe Payout Enricher

## When to Use
Someone (usually Liza Basco) mentions a Stripe payout ID (`po_...`) in #finance_muso
and asks for an enriched report showing product/plan types.

## How to Run

```bash
# Run from the skill directory (path depends on how you installed the skill)
bash enrich-payout.sh <payout_id> [output_file]
```

Output: CSV with columns: payout_id, charge_id, amount_usd, fee_usd, net_usd, description,
customer_email, product_name, business_line, tier, charge_date

## Permissions Required
- Stripe CLI with charges read, invoices read, products read
- Optional: `rak_balance_read` for exact payout→transaction matching

## Post-Processing
After the script produces the CSV:
1. Upload the CSV file to the Slack thread where it was requested
2. Post a brief summary: total charges, breakdown by product/tier, total amount

## Product Metadata
Products have `business_line` and `tier` in metadata (added 2026-02-25).
If a product has no metadata, fall back to product name matching:
- "Pro Plan" / "Pro" → credits / pro
- "Business Plan" / "Business" → credits / business  
- "Plaque" → plaque / plaque
- "Bulk Data Feed" → data / enterprise
- "API Access" → api / enterprise
