# Stripe Payment Operations

## Decision Logic: Stripe CLI vs Athena

**Use Stripe CLI (via Bash tool) when:**
- ✅ Query includes TODAY or last 7 days (real-time data)
- ✅ Small volume expected (< 500 records)
- ✅ Need current status/state
- ✅ Simple counts, totals, or details

**Use Athena when:**
- ✅ Historical only (> 7 days ago, no recent data)
- ✅ Large volume (> 1000 records)
- ✅ Cross-system joins (payments + users/profiles)
- ✅ Complex aggregations or trends

**Example:** "Refunds from November to today" → **Use Stripe CLI** (includes today)
**Example:** "Refunds in 2024" → **Use Athena** (historical only)

## Why This Matters

1. **Real-time** - Stripe has latest data, database may lag by hours/days
2. **Complete** - Stripe has all metadata (reasons, statuses)
3. **Accurate** - Stripe is source of truth for current state

## Stripe CLI Configuration

**Stripe CLI is pre-configured with the API key:**

```bash
stripe refunds list --limit 100
stripe customers list
stripe charges list
```

**Setup (already done):**
1. Added `STRIPE_API_KEY` to OpenClaw gateway environment variables in `~/Library/LaunchAgents/ai.openclaw.gateway.plist`
2. Reloaded the launchd service

All `stripe` commands automatically use this API key. No additional authentication needed.

**Note:** CLI tools need environment variables set in the OpenClaw launchd plist, not just in `.zshrc`. See `openclaw-environment-setup.md` for details.

## Common Queries

### Refunds by Date Range

**TEMPLATE - Always use this exact format:**
```bash
stripe refunds list --limit 500 -d "created[gte]=START_TIMESTAMP" -d "created[lt]=END_TIMESTAMP" 2>/dev/null | grep -o '"amount": [0-9]*' | awk '{sum+=$2; count++} END {printf "Count: %d\nTotal USD: $%.2f\n", count, sum/100}'
```

**WORKING EXAMPLE - November 2025 to Feb 2026:**
```bash
stripe refunds list --limit 500 -d "created[gte]=1730419200" -d "created[lt]=1740787200" 2>/dev/null | grep -o '"amount": [0-9]*' | awk '{sum+=$2; count++} END {printf "Count: %d\nTotal USD: $%.2f\n", count, sum/100}'
```

**Example timestamps:**
- Nov 1, 2025: 1730419200
- Dec 1, 2025: 1733011200
- Jan 1, 2026: 1735689600
- Feb 1, 2026: 1738368000
- Mar 1, 2026: 1740787200

**For multiple months, run separate queries:**
```bash
# November 2025
striperefunds list --limit 500 -d "created[gte]=1730419200" -d "created[lt]=1733011200"

# December 2025
striperefunds list --limit 500 -d "created[gte]=1733011200" -d "created[lt]=1735689600"

# January 2026
striperefunds list --limit 500 -d "created[gte]=1735689600" -d "created[lt]=1738368000"

# February 2026
striperefunds list --limit 500 -d "created[gte]=1738368000" -d "created[lt]=1740787200"
```

### Customer Queries

```bash
# List customers
stripecustomers list --limit 10

# Search by email
stripecustomers list | jq '.data[] | select(.email | contains("user@example.com"))'

# Get customer details
stripecustomers retrieve cus_xxxxx
```

### Subscription Queries

```bash
# List all subscriptions
stripesubscriptions list --limit 50

# List active subscriptions
stripesubscriptions list | jq '.data[] | select(.status=="active")'

# Get subscription details
stripesubscriptions retrieve sub_xxxxx
```

### Payment/Charge Queries

```bash
# List recent charges
stripecharges list --limit 20

# Charges by date
stripecharges list -d "created[gte]=TIMESTAMP" -d "created[lt]=TIMESTAMP"
```

## Important Notes

- **Amounts are in cents** - divide by 100 for USD
- **Limit parameter** - max 500 per request, use pagination if needed
- **Timestamps** - Unix timestamps in seconds
- **Parsing** - Use `grep -o '"amount": [0-9]*'` to extract amounts
- **Calculation** - Use `awk` to sum and count

## Quick Decision Matrix

| Query Type | Includes Today? | Expected Volume | Use |
|------------|-----------------|-----------------|-----|
| Feb 2026 refunds | YES | < 500 | **Stripe CLI** |
| Refunds by month (last 6 months) | YES | < 3000 | **Stripe CLI** (monthly batches) |
| 2024 annual refunds | NO | High | **Athena** |
| Refunds + user details | Maybe | Any | **Athena** (needs join) |
| Today's payments | YES | < 100 | **Stripe CLI** |

## When Database (Athena) Is Better

- Historical-only analysis (no recent/today data needed)
- Large volumes that exceed Stripe pagination
- Need to join with user, profile, or subscription tables
- Complex multi-table aggregations

## Environment

The `MUSOAI_STRIPE_API_KEY` is a restricted key (rk_live_*) configured in ~/.zshrc. It has read-only access to production Stripe data.
