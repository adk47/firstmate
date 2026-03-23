---
name: muso-chartmogul
description: |
  ChartMogul subscription analytics - READ ONLY. Query MRR, churn, LTV, customer metrics.
  CRITICAL: This skill is READ-ONLY. Never modify data.

  Use when: checking MRR, ARR, churn rate, customer count, LTV, revenue metrics,
  subscription analytics, customer lookup, or financial KPIs.

  Triggers: "chartmogul", "mrr", "arr", "churn", "ltv", "revenue", "subscription metrics",
  "customer count", "monthly recurring revenue", "annual recurring revenue"
allowed-tools:
  - Bash
compatibility: |
  Requires MUSOAI_CHARTMOGUL_TOKEN env var.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# ChartMogul Skill (READ-ONLY)

Query Muso.AI subscription analytics and revenue metrics from ChartMogul.

## CRITICAL: READ-ONLY ACCESS

**ONLY USE GET REQUESTS. NO POST, PUT, PATCH, OR DELETE.**

## Authentication

The API token is available as `$MUSOAI_CHARTMOGUL_TOKEN` in the environment.

ChartMogul uses HTTP Basic Auth with the token as the username and an empty password:

```bash
curl -s -u "$MUSOAI_CHARTMOGUL_TOKEN:" \
  "https://api.chartmogul.com/v1/..."
```

> **Note the trailing colon** after the token - this indicates an empty password.

All subsequent curl commands use the same auth.

## Base URL

`https://api.chartmogul.com/v1`

## Allowed Operations (Read-Only)

### MRR (Monthly Recurring Revenue)
```bash
# Get MRR for a date range
curl -s "https://api.chartmogul.com/v1/metrics/mrr?start-date=2026-01-01&end-date=2026-02-16" | jq

# Get MRR with monthly interval
curl -s "https://api.chartmogul.com/v1/metrics/mrr?start-date=2025-01-01&end-date=2026-02-16&interval=month" | jq
```

### ARR (Annual Recurring Revenue)
```bash
curl -s "https://api.chartmogul.com/v1/metrics/arr?start-date=2026-01-01&end-date=2026-02-16" | jq
```

### Churn Rate
```bash
# Customer churn rate
curl -s "https://api.chartmogul.com/v1/metrics/customer-churn-rate?start-date=2025-01-01&end-date=2026-02-16" | jq

# MRR churn rate (net revenue churn)
curl -s "https://api.chartmogul.com/v1/metrics/mrr-churn-rate?start-date=2025-01-01&end-date=2026-02-16" | jq
```

### Customer Count
```bash
curl -s "https://api.chartmogul.com/v1/metrics/customer-count?start-date=2025-01-01&end-date=2026-02-16" | jq
```

### LTV (Lifetime Value)
```bash
curl -s "https://api.chartmogul.com/v1/metrics/ltv?start-date=2025-01-01&end-date=2026-02-16" | jq
```

### ARPA (Average Revenue Per Account)
```bash
curl -s "https://api.chartmogul.com/v1/metrics/arpa?start-date=2025-01-01&end-date=2026-02-16" | jq
```

### ASP (Average Sale Price)
```bash
curl -s "https://api.chartmogul.com/v1/metrics/asp?start-date=2025-01-01&end-date=2026-02-16" | jq
```

### All Metrics Summary
```bash
# Get all key metrics in one call
curl -s "https://api.chartmogul.com/v1/metrics/all?start-date=2025-01-01&end-date=2026-02-16&interval=month" | jq
```

### Customer Search & List
```bash
# List customers
curl -s "https://api.chartmogul.com/v1/customers?page=1&per_page=50" | jq

# Search customers by email
curl -s "https://api.chartmogul.com/v1/customers/search?email=user@example.com" | jq

# Get a specific customer
curl -s "https://api.chartmogul.com/v1/customers/CUSTOMER_UUID" | jq
```

### Customer Subscriptions
```bash
# List subscriptions for a customer
curl -s "https://api.chartmogul.com/v1/customers/CUSTOMER_UUID/subscriptions" | jq
```

### Customer Activities
```bash
# List activities for a customer (payments, cancellations, etc.)
curl -s "https://api.chartmogul.com/v1/customers/CUSTOMER_UUID/activities" | jq
```

### Plans
```bash
# List all plans
curl -s "https://api.chartmogul.com/v1/plans?page=1&per_page=50" | jq
```

## Common Workflows

### Monthly Revenue Dashboard
```bash
# Get all key metrics for the past year
curl -s "https://api.chartmogul.com/v1/metrics/all?start-date=2025-02-01&end-date=2026-02-16&interval=month" | \
  jq '.entries[-1] | {
    date,
    mrr: .mrr,
    arr: .arr,
    customers: .customers,
    customer_churn_rate: .["customer-churn-rate"],
    mrr_churn_rate: .["mrr-churn-rate"],
    ltv: .ltv,
    arpa: .arpa
  }'
```

### Look Up a Customer's Subscription Status
```bash
# 1. Find the customer
curl -s "https://api.chartmogul.com/v1/customers/search?email=user@example.com" | \
  jq '.entries[] | {uuid, name, email, status, mrr}'

# 2. Get their subscriptions (use uuid from step 1)
curl -s "https://api.chartmogul.com/v1/customers/CUSTOMER_UUID/subscriptions" | jq
```

### MRR Growth Over Time
```bash
curl -s "https://api.chartmogul.com/v1/metrics/mrr?start-date=2025-01-01&end-date=2026-02-16&interval=month" | \
  jq '.entries[] | {date, mrr: (.mrr / 100), mrr_new: (.["mrr-new"] / 100), mrr_churn: (.["mrr-churn"] / 100)}'
```

## Tips

- **READ-ONLY ONLY** - Never modify data
- All monetary values are in **cents** - divide by 100 for dollars
- Date format is `YYYY-MM-DD`
- Valid intervals: `day`, `week`, `month`, `quarter`
- Use `| jq` to parse and filter JSON responses
- Always use `-s` (silent) flag with curl to suppress progress output
- Pagination: use `page` and `per_page` query params (default 200 per page)
- Rate limit: 40 requests per 2 seconds per API token
- Geo filter: add `geo=US` (or other ISO country code) to filter metrics by geography

## Documentation

- ChartMogul API Docs: https://dev.chartmogul.com/
- Metrics API: https://dev.chartmogul.com/reference/introduction
- Customer API: https://dev.chartmogul.com/reference/list-customers
