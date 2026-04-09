---
name: muso-winback-qa
description: |
  Audits every other win back subskill for correctness, consistency, and drift.
  Checks stage IDs are current, sheet to GHL consistency, Stripe verification
  is happening on every send, no em dash violations, Gmail labels applied,
  hive volume balance, and DNS deliverability.

  Runs daily as a cron. Posts findings to #win-back-alerts. Blocks the pipeline
  if critical drift is detected.

  Use when: "audit winback", "winback health check", "winback sanity"

  Triggers: "audit winback", "qa winback", "winback health", "winback sanity"
depends-on:
  - muso-winback-engine
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
  cron: "winback-qa-daily"
---

# Muso Win Back QA

Daily audits of the win back engine and all its subskills. Most important
skill for keeping the system honest.

## Access Control

Read only across all data sources. QA never modifies data, only reports drift.

## Shared Config

See `../muso-winback-engine/references/config.md`.

## Cadence

**Daily at 8 AM CST**, before the morning workflow. Cron `winback-qa-daily`.

Also runs on demand.

## Audit Checklist

### 1. Config Integrity

- [ ] `config.md` exists and is readable
- [ ] Sheet ID is `1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`
- [ ] GHL location is `fmK5Vl9sJv49WTYA0QyP` (NOT B2B Ads location)
- [ ] GHL pipeline is `AZa8jK5S7UyQ0fqfxzyB`
- [ ] `$GHL_WINBACK_API_KEY` env var is set (and not equal to `$GHL_API_KEY`)
- [ ] `#win-back-alerts` channel ID is `C0ARTH6U0S2`

### 2. GHL Pipeline Stages

- [ ] Fetch live stages from GHL win back location
- [ ] Compare against `pipeline-stages.md`
- [ ] Confirm all 7 stages exist (Churned through Lost / No Answer)
- [ ] If any stage ID changed, alert Fede and update `pipeline-stages.md`

### 3. Sheet Integrity

For `high_value_churn`:
- [ ] All rows have an `email` (skip rows without)
- [ ] No duplicate `email` values
- [ ] All rows have a `Pipeline Stage` (writeback alignment with GHL)
- [ ] No rows with future `email_sent_date`
- [ ] `Total LTV` is numeric on all rows with status `sent` or beyond

For `pro_churned_all`:
- [ ] Spot check 20 random rows for valid `email` and `cancel_date`
- [ ] No duplicate emails

### 4. Sheet to GHL Consistency

- [ ] For each `high_value_churn` row with `outreach_status = sent`, a matching GHL contact exists at stage `Emailed` or beyond
- [ ] For each row with `outreach_status = follow_up_sent`, GHL stage is `Follow-up` or beyond
- [ ] For each row with `outreach_status = converted`, GHL stage is `Re-subscribed`
- [ ] For each row with `outreach_status = no_response`, GHL stage is `Lost / No Answer`
- [ ] No GHL opportunity is missing its `sheet_row_id` custom field

Drift → alert with specific row IDs and GHL opportunity IDs.

### 5. Pre Send Stripe Check Compliance

CRITICAL. Spot check the last 50 sends from `api-logs/gmail/`:
- [ ] Each send has a corresponding Stripe check log entry from the same time
- [ ] No send went out to a user who had an active Stripe subscription at the time

If any send went out without a Stripe check, this is a CRITICAL bug. The
sender skill is broken. Block all win back sends until fixed.

### 6. Gmail Label Hygiene

For each Muso account:
- [ ] Label `Win-Back` exists
- [ ] Count of labeled messages ≥ count of `sent` rows in sheet for that account
- [ ] Spot check 5 random sent messages from last 24h for label presence

### 7. Em Dash Sweep

Scan for em dash characters (—) in:
- [ ] All rows in `Email Subject Sent` and `Email Body Sent` columns
- [ ] All `muso-winback-*` SKILL.md files and references
- [ ] All api-logs from the last 24h (look at email body content)

Any em dash found → critical alert. Zero tolerance.

### 8. Volume and Pacing

- [ ] No day in last 7 days exceeded 120 total sends
- [ ] No single account exceeded 40 sends in any day
- [ ] No sends went out on Saturday or Sunday
- [ ] No sends went out outside 8 AM to 6 PM CST

### 9. Cadence Sanity

- [ ] No contact has received more than 3 emails (initial + 2 follow ups)
- [ ] All Day 7 follow ups happened between Day 7 and Day 9 of cadence
- [ ] All Day 45 follow ups happened between Day 45 and Day 50
- [ ] All Day 90 Lost moves happened between Day 90 and Day 95

### 10. CC + BCC Check

- [ ] Every sent email has CC `support@muso.ai`
- [ ] No sent email has BCC (CC + BCC triggers phishing detectors)

### 11. Coupon Code Status

- [ ] If templates contain a coupon code, confirm Fede has approved the current codes
- [ ] If templates have placeholder coupon (TBD), confirm sender skill is NOT including coupons in drafts

### 12. DNS Deliverability

Once per week (or before any new campaign):
- [ ] DKIM record `google._domainkey.muso.ai` exists and is valid
- [ ] SPF record exists with `-all` (hardfail), not `~all`
- [ ] DMARC record exists at `p=quarantine` minimum

### 13. Reply Scanner Health

- [ ] Scanner has run at least once in the last 4 hours (within scheduled cadence)
- [ ] No errors in `api-logs/winback-scanner/`
- [ ] All replies in last 24h have a corresponding sheet update

### 14. Hive Balance

- [ ] If using multi account hive, no single account is carrying > 50% of volume
- [ ] Warming accounts (`ak@`, `aaron.k@`, `f@`) are within their warming protocol limits

### 15. Bounce and Unsubscribe Detection

- [ ] Bounce notifications in last 24h have corresponding `Lost / No Answer` updates
- [ ] Spam reports in last 24h have corresponding immediate stop and `Lost` updates

## Critical vs Informational

### Critical (block pipeline, page Fede or Aaron)

- Em dash found in any sent email or template
- Send went out without Pre Send Stripe Check
- Wrong API key used (`$GHL_API_KEY` instead of `$GHL_WINBACK_API_KEY`)
- Wrong location used (`S5w31kRRgsBjjiVATWlP` instead of `fmK5Vl9sJv49WTYA0QyP`)
- Send on Saturday or Sunday
- Contact received more than 3 emails total
- Daily volume exceeded 120 or single account exceeded 40
- BCC detected on any send
- DKIM, SPF, or DMARC failed validation
- Spam report received

### Informational (note in report, do not block)

- Drift between sheet and GHL on < 5 rows (auto reconcile next run)
- Templates with < 10 sends (insufficient data)
- Reply rate trending below baseline but still > 2%
- Hive imbalance under 50% (warming protocol may explain)

## Output

Post to `#win-back-alerts` (`C0ARTH6U0S2`):

```
🔍 *Win Back QA, YYYY-MM-DD*

Status: 🟢 All Green | 🟡 Warnings | 🔴 Critical Issues

Critical:
  • (none) OR list with fix suggestions

Warnings:
  • ...

Informational:
  • Config: ✅
  • GHL stages: ✅ (7 stages verified)
  • Sheet integrity: ✅
  • Sheet to GHL drift: 0 items
  • Stripe check compliance: ✅ (50/50 sends checked)
  • Em dash sweep: 0 hits
  • Volume: ✅ (120/day cap respected)
  • Cadence: ✅
  • CC/BCC: ✅ (all sends CC support@, no BCC)
  • DNS: ✅ (DKIM, SPF, DMARC valid)
  • Reply scanner last ran: {timestamp}
  • Hive balance: ✅ ({a%}/{ak%}/{aaron.k%}/{f%})

Pipeline drift (sheet vs GHL):
  • {N} sheet rows, {M} GHL ops, {K} reconciled

Coupon status: TBD (Fede to provide current codes)

Next audit: {next run timestamp}
```

If status is 🔴 Critical, prepend with `@aaron @fede` mention.

## Never

- Never modify data during an audit (read only)
- Never auto fix issues (report, do not repair)
- Never skip a critical check
- Never silently ignore em dash hits
- Never mark audit green if any critical check failed
- Never confuse the win back location with the B2B Ads location

## Why QA Exists

Win back is high stakes because we are reaching out to people who already left.
Sending the wrong email, sending to a re subscriber, hitting them on a weekend,
or missing a Stripe check would all damage trust and brand. The QA skill
catches these before they hurt us.

If QA is ever disabled or skipped, the campaigns will drift within days.
