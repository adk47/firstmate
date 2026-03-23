---
name: muso-contract-invoicer
description: |
  Create Stripe invoices from Muso Ads contracts. Upload a contract (PDF/image/text),
  extract client details, create subscription with discount, and send invoice.
  
  WRITE ACCESS: Aaron (U7RP6HKUZ) ONLY. All other users are blocked from this skill entirely.
  
  Use when: creating invoices from contracts, onboarding Muso Ads clients, sending
  discounted subscription invoices, processing ad client agreements.
  
  Triggers: "invoice", "contract", "muso ads client", "send invoice", "create invoice",
  "onboard client", "ads contract", "subscription invoice"
---

# Muso Ads Contract → Invoice Skill

## Access Control (MANDATORY)
**Only Aaron (U7RP6HKUZ) can use this skill.** Check `sender_id` from inbound metadata before ANY action. If anyone else triggers this skill, respond: _"This skill is restricted to Aaron. Please ask him directly."_

## Workflow

### Step 1: Extract Contract Details
When Aaron uploads a contract (PDF, image, or pastes text), extract:
- **Company name**
- **Contact email** (invoice recipient)
- **CC email(s)** (additional recipients, if any)
- **Monthly price** or **discount off $1,250 base**
- **Term:** monthly (ongoing) or single month trial
- **Payment terms:** net 30 (default) or custom

If any field is unclear or missing, ask Aaron — don't guess.

### Step 2: Present for Review
Show Aaron exactly what will be created:

```
*Invoice Preview:*
• Company: [name]
• Email: [email]
• CC: [cc_email] (or "none")
• Base price: $1,250/mo (Muso Ads)
• Discount: [X]% off → *$[amount] due*
• Term: [monthly / single month trial]
• Payment terms: Net [X] days
```

Wait for Aaron's explicit approval before proceeding.

### Step 3: Create in Stripe
Once approved, execute in order:

1. **Find or create customer** by email
   ```bash
   stripe customers list --email="<email>" | jq '.data | length'
   # If 0: create new customer
   stripe customers create --name="<company>" --email="<email>" --description="Muso Ads client - <company>"
   ```

2. **Create coupon** (if discount applies)
   ```bash
   stripe coupons create --percent-off=<X> --duration=once --name="Muso Ads <X>% Discount - <company>"
   ```

3. **Create subscription**
   ```bash
   stripe subscriptions create \
     --customer="<cus_id>" \
     -d "items[0][price]=price_1T6axJLsjTo3Ar3lAMszw0eW" \
     -d "coupon=<coupon_id>" \
     -d "cancel_at_period_end=<true|false>" \
     -d "collection_method=send_invoice" \
     -d "days_until_due=0"
   ```
   - `cancel_at_period_end=true` for single month trials
   - `cancel_at_period_end=false` for ongoing monthly

4. **Finalize invoice**
   ```bash
   stripe invoices finalize_invoice <invoice_id>
   ```

### Step 4: Send to Aaron First
Send the invoice to Aaron's email for visual review:
```bash
source ~/.zshrc 2>/dev/null
curl -s https://api.stripe.com/v1/invoices/<invoice_id>/send \
  -u "${MUSOAI_STRIPE_API_KEY}:" -X POST
```

Share the hosted invoice URL in Slack so Aaron can preview.

Wait for Aaron to say "send it" or approve.

### Step 5: Send to Client
On Aaron's approval, update the customer email to the real client email and re-send:
```bash
stripe customers update <cus_id> --email="<client_email>"
source ~/.zshrc 2>/dev/null
curl -s https://api.stripe.com/v1/invoices/<invoice_id>/send \
  -u "${MUSOAI_STRIPE_API_KEY}:" -X POST
```

For CC recipients: Stripe doesn't natively CC. Offer to email the invoice link to CC recipients via gog (if Aaron/Fede authorized).

### Step 6: Save Contract to Memory
After creating the invoice, save all contract details to `memory/muso-ads-clients.md`:
- Company name, entity, address, phone
- All contact names + emails
- Deal terms: products, pricing, discounts, commitment period
- Payment schedule
- Exclusivity or special terms
- Stripe IDs (customer, subscription, invoice, coupon)
- Contract signing dates and DocuSign envelope ID
- Status (invoice sent, paid, etc.)

This is the permanent record for future questions about these clients.

### Step 7: Log Everything
**MANDATORY** — log all write operations BEFORE execution:
```bash
cat >> api-logs/stripe/YYYY-MM-DD.jsonl << 'EOF'
{"ts":"<ISO>","action":"<action>","description":"<what>","requested_by":"Aaron"}
EOF
```

## Reference
- **Product:** Muso Ads (`prod_U4kOhDrEttKAAz`)
- **Price:** $1,250/mo (`price_1T6axJLsjTo3Ar3lAMszw0eW`)
- **Collection method:** `send_invoice` (client pays via payment link, no card required upfront)
- **Default payment terms:** Due immediately (days_until_due=0) — payment is upfront for activation

## Discount Cheat Sheet
| Target Price | Discount % |
|---|---|
| $1,125 | 10% |
| $1,000 | 20% |
| $937.50 | 25% |
| $875 | 30% |
| $625 | 50% |

For exact amounts that don't match a clean %, use `amount_off` (in cents) instead of `percent_off`.
