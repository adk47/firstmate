---
name: muso-profitwell
description: |
  ProfitWell (Paddle Retain) subscription metrics - READ ONLY. Query MRR, churn, growth metrics.
  CRITICAL: This skill is READ-ONLY. Never modify data.

  Use when: checking daily/monthly MRR, churn metrics, customer growth, plan performance,
  subscriber details, or revenue benchmarks.

  Triggers: "profitwell", "paddle retain", "mrr", "churn", "growth rate", "subscribers",
  "revenue metrics", "plan metrics"
allowed-tools:
  - Bash
compatibility: |
  Requires MUSOAI_PROFITWELL_TOKEN env var.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# ProfitWell Skill (READ-ONLY)

Query Muso.AI subscription metrics and financial data from ProfitWell (Paddle Retain).

## CRITICAL: READ-ONLY ACCESS

**ONLY USE GET REQUESTS. NO POST, PUT, PATCH, OR DELETE.**

## Authentication

The API token is available as `$MUSOAI_PROFITWELL_TOKEN` in the environment.

ProfitWell uses a custom Authorization header (no "Bearer" prefix):

```bash
curl -s \
  -H "Authorization: $MUSOAI_PROFITWELL_TOKEN" \
  "https://api.profitwell.com/v2/metrics/monthly/"
```

All subsequent curl commands use the same auth header.

> **Important:** ProfitWell URLs must end with a **trailing slash** (`/`). Requests without trailing slashes will fail.

## Base URLs

| API | Base URL |
|-----|----------|
| Metrics API | `https://api.profitwell.com/v2/` |
| Events API | `https://api.profitwell-events.com/v2/` |

## Allowed Operations (Read-Only)

### Monthly Metrics
```bash
# Get all monthly metrics (returns full history: MRR, customers, churn, etc.)
curl -s "https://api.profitwell.com/v2/metrics/monthly/" | jq

# Filter by plan
curl -s "https://api.profitwell.com/v2/metrics/monthly/?plan_id=PLAN_ID" | jq
```

> **Note:** The monthly endpoint does not support date range filtering.
> It returns all historical data. Filter client-side with jq if needed.

### Daily Metrics
```bash
# Get daily metrics for a specific month (month param is REQUIRED)
curl -s "https://api.profitwell.com/v2/metrics/daily/?month=2026-01" | jq

# Filter by plan for a month
curl -s "https://api.profitwell.com/v2/metrics/daily/?month=2026-01&plan_id=PLAN_ID" | jq
```

> **Note:** The daily endpoint **requires** a `month` parameter in `YYYY-MM` format.

### Available Metric Names
Use these in the `metrics` parameter (comma-separated for multiple):

| Metric | Description |
|--------|-------------|
| `recurring_revenue` | MRR |
| `active_customers` | Active paying customers |
| `new_customers` | New customers acquired |
| `churned_customers` | Customers who churned |
| `upgraded_customers` | Customers who upgraded |
| `downgraded_customers` | Customers who downgraded |
| `reactivated_customers` | Customers who reactivated |
| `churned_recurring_revenue` | MRR lost to churn |
| `new_recurring_revenue` | New MRR from new customers |
| `upgrade_recurring_revenue` | MRR gained from upgrades |
| `downgrade_recurring_revenue` | MRR lost to downgrades |
| `reactivated_recurring_revenue` | MRR from reactivations |
| `cumulative_net_new_mrr` | Net new MRR |
| `lifetime_value` | LTV |

### Plans
```bash
# List all plans
curl -s "https://api.profitwell.com/v2/plans/" | jq

# Get plan details
curl -s "https://api.profitwell.com/v2/plans/PLAN_ID/" | jq
```

### Plan Metrics
```bash
# Get metrics broken down by plan
curl -s "https://api.profitwell.com/v2/metrics/monthly/?plan_id=PLAN_ID" | jq
```

## Common Workflows

### Current Revenue Snapshot
```bash
# Get latest monthly MRR value
curl -s "https://api.profitwell.com/v2/metrics/monthly/" | \
  jq '.data.recurring_revenue | last | {date, mrr: .value}'
```

### MRR Trend (Last 6 Months)
```bash
curl -s "https://api.profitwell.com/v2/metrics/monthly/" | \
  jq '.data.recurring_revenue[-6:] | .[] | {date, mrr: .value}'
```

### Daily MRR for Current Month
```bash
curl -s "https://api.profitwell.com/v2/metrics/daily/?month=2026-02" | \
  jq '.data.recurring_revenue[] | {date, mrr: .value}'
```

### Churn Analysis
```bash
# Get all monthly metrics and extract churn data
curl -s "https://api.profitwell.com/v2/metrics/monthly/" | \
  jq '.data | {
    churned_customers: .churned_customers[-6:],
    churned_revenue: .churned_recurring_revenue[-6:]
  }'
```

## Tips

- **READ-ONLY ONLY** - Never modify data
- **Trailing slashes are required** on all URLs - requests without them will fail
- Monthly endpoint returns all history (no date filtering); daily endpoint requires `?month=YYYY-MM`
- Monetary values are in **dollars** (not cents) — e.g., `200163.26`
- Response format: `{"data": {"metric_name": [{"date": "...", "value": ...}, ...]}}`
- Use `| jq` to parse and filter JSON responses
- Always use `-s` (silent) flag with curl to suppress progress output
- Filter by plan with `?plan_id=PLAN_ID`
- Rate limit: check response headers for current limits
- The Events API (`profitwell-events.com`) is for event ingestion — use the Metrics API for reads

## Documentation

- ProfitWell API Docs: https://profitwellapidocs.readthedocs.io/
- Metrics Endpoint: https://profitwellapidocs.readthedocs.io/en/latest/metrics.html
