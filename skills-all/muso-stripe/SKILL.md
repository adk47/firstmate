---
name: muso-stripe
description: |
  Stripe payment processing and subscription management using the Stripe CLI.

  Use when: creating/managing customers, processing payments, handling subscriptions,
  refunding charges, viewing invoices, managing payment methods, or any Stripe operations.

  Triggers: "stripe", "payment", "subscription", "customer", "charge", "refund",
  "invoice", "payment method", "credit card"
compatibility: |
  Requires Stripe CLI (`stripe`). Optional: `jq` for nicer output. Assumes the CLI is authenticated (e.g., via `MUSOAI_STRIPE_API_KEY`).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
allowed-tools:
  - Bash
---

# Stripe Skill

Stripe CLI is pre-configured with the MUSOAI_STRIPE_API_KEY. All `stripe` commands work automatically.

> **Money-moving writes are gated.** Read operations (`list`, `retrieve`) call `stripe`
> directly. Writes that move money — `refunds create`, and any cancel-and-refund flow — MUST
> go through `bash /opt/hydra/scripts/muso-stripe-write.sh <args>`, which refuses the write
> while the codex model is degraded onto a weak fallback (fail-closed). See the
> `muso-refund-processor` skill for the refund flow.

## Quick Reference

### Refunds (Read-Only)
```bash
# List refunds
stripe refunds list --limit 100

# List refunds by date range
stripe refunds list -d "created[gte]=1730419200" -d "created[lt]=1740787200"

# Get refund details
stripe refunds retrieve re_xxxxx
```

### Customers (Read-Only)
```bash
# List customers
stripe customers list --limit 10

# Get customer details
stripe customers retrieve cus_xxxxx

# Search customers by email
stripe customers list --email="user@example.com"
```

### Subscriptions (Read-Only)
```bash
# List subscriptions
stripe subscriptions list --limit 10

# Get subscription details
stripe subscriptions retrieve sub_xxxxx
```

### Charges & Payments (Read-Only)
```bash
# List charges
stripe charges list --limit 10

# Get charge details
stripe charges retrieve ch_xxxxx
```

### Invoices (Read-Only)
```bash
# List invoices
stripe invoices list --limit 10

# Get invoice details
stripe invoices retrieve in_xxxxx
```

### Payment Methods (Read-Only)
```bash
# List payment methods
stripe payment_methods list --customer=cus_xxxxx --type=card

# Get payment method
stripe payment_methods retrieve pm_xxxxx
```

### Products & Prices (Read-Only)
```bash
# List products
stripe products list --limit 10

# List prices
stripe prices list --limit 10
```

## Output Format

By default, Stripe CLI outputs JSON. You can pipe to `jq` for filtering:

```bash
# Get just customer emails
stripe customers list --limit 10 | jq -r '.data[].email'

# Get subscription status
stripe subscriptions retrieve sub_xxxxx | jq -r '.status'

# List active subscriptions
stripe subscriptions list | jq '.data[] | select(.status=="active")'
```

## Common Workflows

### Count Refunds and Calculate Total
```bash
stripe refunds list --limit 500 -d "created[gte]=1730419200" -d "created[lt]=1740787200" | \
grep -o '"amount": [0-9]*' | \
awk '{sum+=$2; count++} END {printf "Count: %d\nTotal USD: $%.2f\n", count, sum/100}'
```


## Authentication

**Stripe CLI is pre-configured with the API key.**

The CLI was configured with:
```bash
stripe config --set api_key $MUSOAI_STRIPE_API_KEY
```

All `stripe` commands automatically use this API key. No additional authentication needed.

## Tips

- All amounts are in cents (e.g., $20.00 = 2000)
- Use `--limit` to control result count (default varies by endpoint)
- Use `--starting-after` for pagination
- Add `| jq` for pretty JSON output
- Timestamps are Unix timestamps in seconds

## Documentation

- Stripe CLI Docs: https://stripe.com/docs/cli
- Stripe API Docs: https://stripe.com/docs/api
- Stripe Dashboard: https://dashboard.stripe.com/
