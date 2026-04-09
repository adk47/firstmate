---
name: muso-winback-reporter
description: |
  Generates reports on win back campaign activity. Reads from the win back sheet,
  GHL pipeline, and Stripe for re subscription detection. Produces daily, weekly,
  and batch summaries. Posts to #win-back-alerts on demand or on a schedule.

  Use when: "winback report", "how is winback going", "weekly winback",
  "winback metrics", "winback recovery"

  Triggers: "winback report", "winback summary", "winback metrics", "weekly winback"
depends-on:
  - muso-winback-engine
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Win Back Reporter

Reads win back logs and generates summaries for Aaron and Fede.

## Shared Config

See `../muso-winback-engine/references/config.md`.

## Report Types

### Daily Summary

Trigger: 8 PM CST cron, or manual.

Content:
- Emails sent today (per Muso account, per template)
- Replies received today (by classification)
- Re subscriptions detected today (with MRR recovered)
- Follow ups sent today (Day 7 + Day 45 breakdown)
- Marked Lost today (Day 90)
- Current pipeline snapshot (count per stage)

Format:

```
📊 *Win Back Daily, YYYY-MM-DD*

Sent today: {N} (a@: {a}, ak@: {b}, aaron.k@: {c}, f@: {d})
Replies today: {M} ({by_type})
Re subscriptions: {K} (${MRR} MRR recovered)

Follow ups today:
  Day 7: {x}
  Day 45: {y}
  Marked Lost (Day 90): {z}

Pipeline:
  Churned: {a}
  Next Up: {b}
  Emailed: {c}
  Replied: {d}
  Follow-up: {e}
  Re-subscribed: {f}
  Lost: {g}

Top template by reply rate:
  • {template_id}: {reply_rate}% ({replies}/{sends})

Total to date:
  Sent: {N_total}
  Replies: {M_total} ({reply_rate}%)
  Re subscribers: {K_total} ({conversion_rate}%)
  MRR recovered: ${MRR_total}
```

### Weekly Summary

Trigger: Monday 9 AM CST cron, or manual.

Content (last 7 days):
- Total sends, replies, re subscriptions, follow ups, lost
- Reply rate and conversion rate
- Top 3 templates by reply rate (minimum 10 sends to qualify)
- Worst 3 templates (candidates to retire)
- Conversion funnel: Sent → Replied → Re subscribed
- Top tier breakdown (Tier 1 vs Tier 2 vs Tier 3 performance)

### Batch Summary

Trigger: after every send batch by `muso-winback-sender`.

Content:
- Batch size and sender account
- Tier breakdown
- Template distribution
- Language breakdown
- Pre Send Stripe check skips (people who re subscribed independently)
- Estimated reply window (7 days)

### Conversion Report

Trigger: weekly with weekly summary.

Content: for each user who re subscribed:
- Original churn date
- Days since cancellation
- Email that triggered the conversion (or "spontaneous" if no email touched)
- Plan they re subscribed to
- Monthly value
- Total LTV impact

## Data Sources

### Win Back Sheet
```bash
gog sheets get 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs \
  --range "high_value_churn" --account a@muso.ai
```

Filter by date range, `outreach_status`, `Pipeline Stage`.

### GHL Pipeline
```bash
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_WINBACK_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=fmK5Vl9sJv49WTYA0QyP" \
  -d "pipeline_id=AZa8jK5S7UyQ0fqfxzyB" \
  -d "limit=100" -d "page=1" | python3 -m json.tool
```

Paginate ALL pages, count by stage.

### Stripe (for MRR recovered)
```bash
# For each row marked converted, look up the active subscription value
source ~/.zshrc && stripe subscriptions list --customer=<cus_id> --status=active
```

Sum the monthly value for `MRR recovered`.

## Output

All reports post to `#win-back-alerts` (`C0ARTH6U0S2`) using
`muso-slack-formatter` rules. No markdown tables. Bullet lists. Correct Slack syntax.

## Constraints

- Never present data from one source only (crosscheck sheet + GHL + Stripe)
- Never fabricate numbers
- If a data source is unavailable, say so explicitly in the report
- Always follow `muso-slack-formatter` rules
- Always include both absolute counts and rates (X sends, Y reply rate)

## Historical Baselines (Tentative)

These are placeholders. Once campaigns run at scale, replace with real numbers.

- Reply rate target: > 5% (higher than B2B cold because these users know us)
- Re subscription rate target: > 1% of sent (TBD with real data)
- Net MRR recovered per week target: TBD

The previously cited "52.9% win back conversion" number was unverified and was
removed from MEMORY.md per Fede directive 2026-04-09.
