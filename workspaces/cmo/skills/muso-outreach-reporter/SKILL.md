---
name: muso-outreach-reporter
description: |
  Generates reports on B2B Ads outreach activity. Reads from the logbook sheet
  and the GHL pipeline, produces daily / weekly / batch summaries, and posts to
  #sales-alerts on demand or on a schedule.

  Use when: "outreach report", "how are we doing", "weekly outreach summary",
  "template performance", "conversion rates"

  Triggers: "outreach report", "outreach summary", "how is outreach doing",
  "weekly outreach", "template performance"
depends-on:
  - muso-outreach-engine
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Outreach Reporter

Reads outreach logs and generates human readable summaries for Nick and Aaron.

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Report Types

### Daily Summary

Trigger: manual request or 10 PM CEST cron (coordinate with `cmo-eod-briefing`).

Content:
- Emails sent today (per Muso account)
- Replies received today (by type)
- Meetings booked today
- Follow ups sent today
- New companies discovered today
- Current pipeline snapshot (count per stage)

Format:

```
📊 *Outreach Daily, YYYY-MM-DD*

Sends: {N} ({breakdown by account})
Replies: {M} ({breakdown by type})
Meetings: {K}
Follow ups: {FU-01 count, FU-02 count, FU-03 count}
New companies: {D} (discovered and queued)

Pipeline:
  Cold: {a}
  Emailed: {b}
  Follow-up: {c}
  Replied: {d}
  Meeting Booked: {e}
  Awaiting for Application: {f}
  Proposal Draft: {g}
  Proposal Sent: {h}
  Closed Won: {i}
  Closed Lost: {j}

Today's top template by reply rate:
  • {template name}: {reply_rate}% ({replies}/{sends})
```

### Weekly Summary

Trigger: Monday 9 AM CEST cron, or manual.

Content (last 7 days):
- Total sends, replies, meetings, follow ups
- Reply rate and meeting rate
- Top 3 templates by reply rate (minimum 10 sends to qualify)
- Worst 3 templates (candidates to retire)
- Conversion funnel: Emailed → Replied → Meeting Booked → Proposal Sent → Closed Won
- New opportunities added vs closed

### Batch Summary

Trigger: after every send batch by `muso-outreach-sender`.

Content:
- Batch size and sender account
- Template distribution
- Estimated reply window (7 days from send)
- Link to approval thread

### Template Performance Report

Trigger: manual, or weekly with weekly summary.

Content: for each template in `email_templates` sheet:
- Times Sent
- Replies
- Reply Rate (%)
- Meetings Booked
- Booking Rate (%)
- Last Used Date
- Recommendation: `Keep`, `Retire`, `Test variations`

Rules for recommendations:
- Less than 10 sends: insufficient data, do not recommend
- 10 to 50 sends: early signal, `Keep` if reply rate > 15%, else `Test variations`
- 50+ sends: solid signal, `Keep` if > 15%, `Test variations` if 8 to 15%, `Retire` if < 8%

### Company Funnel Report

Trigger: manual, or monthly.

Content:
- New companies discovered in period
- Companies enriched
- Companies contacted
- Companies with replies
- Companies with meetings
- Companies closed won
- Drop off rate at each stage

## Data Sources

### Logbook Sheet
```bash
gog sheets get 1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0 \
  --range "muso-b2b-outreach-reports" --account a@muso.ai
```

Filter by Date range, Action type, Status.

### Email Templates Sheet
```bash
gog sheets get 1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I \
  --range "email_templates" --account a@muso.ai
```

Pull performance columns.

### GHL Pipeline
```bash
/opt/hydra/scripts/ghl.sh GET /opportunities/search \
  location_id=S5w31kRRgsBjjiVATWlP pipeline_id=GeSt85TueSvJ0SNFZXfQ \
  limit=100 page=1
```

Paginate all pages, count by stage.

## Output

All reports post to `#sales-alerts` (`C0ARQ021M40`) using `muso-slack-formatter`
rules. No markdown tables, use bullet lists, correct Slack syntax.

If a report is requested on demand from a different channel, post in that channel
and also append a copy to `#sales-alerts` for the record.

## Constraints

- Never present data from one source only (crosscheck sheet + GHL + logbook)
- Never fabricate numbers
- If a data source is unavailable, say so explicitly in the report
- Never include sensitive prospect data in reports that go to wider audiences
- Always follow `muso-slack-formatter` rules

## Historical Baselines

For context in reports:
- Email open rates: 60 to 70% (Muso.AI benchmark, well above industry)
- Reply rate target: > 15% (based on Private Invite template history)
- Meeting rate target: > 5% of sends
- Typical cold outreach reply rate: 1 to 3% (we should always beat this)
