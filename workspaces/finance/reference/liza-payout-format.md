# Liza's Payout Report CSV Format

Established 2026-03-09 per Liza Basco (U0A8CCTTAAG) in #finance_muso.

## Structure
Transactions grouped into sections with subtotal rows between each:

1. **Business Plan** charges (grouped together)
   - Subtotal row
2. **Pro Plan** charges (grouped together)
   - Subtotal row
3. **Plaque** charges (grouped together)
   - Subtotal row
4. **Refunds**
   - Subtotal row
5. **Adjustments** (disputes/chargebacks)
   - Subtotal row
6. **Stripe Fees** (3DS, Radar, Billing, CAU, Adaptive Acceptance, etc.)
   - Subtotal row
7. **Stripe Loan** (if applicable)

## Columns (exact headers)
Type, ID, Created, Description, Amount, Currency, Converted Amount, Fees, Net, Converted Currency, Details, Customer ID, Customer Email, Customer Name, Address_Validation_Status (metadata), Coupon (metadata), Referral deactivated (metadata), referral (metadata), Campaign (metadata), View in Rewardful (metadata), Affiliate (metadata), Link (metadata), userId (metadata), teamId (metadata)

## Key Rules
- **Do NOT mix everything together** — each category is its own section
- Subtotal rows have empty Type/ID/Created/Description, just Amount/Fees/Net totals
- Product names come from Stripe invoice line items (not charge description)
- Product ID mapping:
  - `prod_OFVYGPlM6SjHS6` = Pro Plan
  - `prod_OFVYBKkzV3ypza` = Business Plan
  - `prod_OQkgKKXueCq0lx` = Business Plan
  - Plaque products: name contains "Plaque"
- Filename format: `{Month}.{Day},{Year}-${amount}-{payout_id}.csv`
- Script: `/tmp/payout_csv_final.py` (regenerate from this doc if needed)

## Important: Source ID Handling
When listing balance_transactions without `--expand`, the `source` field comes back as a plain string ID (e.g. `ch_xxx`), NOT an expanded object. Must handle both cases in `get_charge_id_from_txn`.
