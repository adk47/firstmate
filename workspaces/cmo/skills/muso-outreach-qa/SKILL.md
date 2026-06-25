---
name: muso-outreach-qa
description: |
  Audits every other outreach subskill for correctness, consistency, and drift.
  Checks stage IDs are current, sheet to GHL consistency, no em dash violations,
  Gmail labels applied correctly, log completeness, and template integrity.

  Runs daily as a cron. Posts findings to #sales-alerts. Blocks the pipeline if
  critical drift is detected.

  Use when: "audit outreach", "check health", "qa outreach", "outreach sanity"

  Triggers: "audit outreach", "qa outreach", "outreach health", "sanity check outreach"
depends-on:
  - muso-outreach-engine
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
  cron: "muso-outreach-qa-daily"
---

# Muso Outreach QA

Daily audits of the outreach engine and all its subskills. This is the single
most important skill for keeping the system honest.

## Access Control

Read only across all data sources. QA should never modify data (it only reports
drift and flags issues for Nick to fix).

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Cadence

**Daily at 8 AM CEST** (before the morning workflow). Cron `muso-outreach-qa-daily`.

Also runs on demand.

## Audit Checklist

### 1. Config Integrity

- [ ] `config.md` exists and is readable
- [ ] All sheet IDs in config match the expected values
- [ ] GHL location and pipeline IDs match
- [ ] Slack channel IDs are all 9+ characters (basic format check)
- [ ] Voice mappings cover all 4 Muso accounts

### 2. GHL Pipeline Stages

- [ ] Fetch live stages from GHL
- [ ] Compare against `pipeline-stages.md`
- [ ] Confirm all 11 stages exist (Cold through Closed Lost)
- [ ] If any stage ID changed or a new stage was added: alert Nick, update `pipeline-stages.md`

### 3. Data Integrity

Contact + company intelligence lives in NocoDB now (canonical) — audit it via the
`muso-nocodb` skill (REST API, no MCP; see `../muso-outreach-engine/references/config.md`).
Templates + logbook stay on the Sheet.

For NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`):
- [ ] All rows have a non empty `Row ID`
- [ ] All rows have a `Domain` (join key)
- [ ] No duplicate `Row ID` values
- [ ] No duplicate `Valid Professional Email` values (same email = duplicate contact)

For NocoDB Company Intelligence (`mvr6nmzcv7albxt`):
- [ ] All rows have a `Domain` (unique key)
- [ ] No duplicate domains
- [ ] All rows have `ICPCategory Label` (required for name drop logic)
- [ ] Flag rows missing `Why Muso Ads Matters` (critical for outreach)

For `email_templates` (Sheet):
- [ ] All rows have an `ID`, `Template Type`, `Subject Line`, `Email Body`
- [ ] No em dash in any `Email Body` or `Subject Line`
- [ ] Reply Rate (%) and Booking Rate (%) are computed correctly (Replies / Times Sent)

For `muso-b2b-outreach-reports`:
- [ ] All rows have Date, Muso Email, Contact, Company
- [ ] Muso Email is one of the 4 allowed values (a@, f@, ak@, aaron.k@)
- [ ] No rows with future dates
- [ ] No rows older than the oldest known outreach (sanity bound)

### 4. Sheet to GHL Consistency

- [ ] For each Sent row in the logbook, a matching GHL contact exists (lookup by email)
- [ ] For each Sent row, a matching GHL opportunity exists at stage `Emailed` or later
- [ ] For each Replied row, the GHL stage is `Replied`, `Meeting Booked`, `Proposal Sent`, `Closed Won`, or `Closed Lost`
- [ ] No GHL opportunity is missing its `sheet_row_id` custom field
- [ ] No GHL opportunity has a `sheet_row_id` that does not exist in NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`, `Row ID` column)

Any drift → alert Nick with specific row IDs and GHL opportunity IDs.

### 5. Gmail Label Hygiene

For each Muso account:
- [ ] Label `B2B - Ads` exists
- [ ] Count of labeled messages ≥ count of `Sent` rows in logbook for that account (drift indicator)
- [ ] Spot check 5 random sent messages from the last 24h to confirm label is applied

### 6. Em Dash Sweep

Scan the following for em dash characters (—):
- [ ] `email_templates` sheet (Subject Line and Email Body columns)
- [ ] `muso-b2b-outreach-reports` sheet (Email Subject and Hook / Notes columns)
- [ ] All `muso-outreach-*` SKILL.md files and references
- [ ] All api-logs from the last 24h

Any em dash found → critical alert. Nick has zero tolerance.

### 7. Template Rotation

- [ ] No single template used > 50% of sends in last 7 days (rotation failure)
- [ ] Last Used Date bumps after every send (writeback working)
- [ ] Times Sent monotonically increases

### 8. Discovery Cron Health

- [ ] Discovery cron ran today (check `#company-finder` for today's post)
- [ ] 5 companies were delivered (or a documented reason if fewer)
- [ ] No duplicate companies posted in the last 7 days
- [ ] `parent-companies.md` is current

### 9. Reply Scanner Health

- [ ] Scanner has run at least once in the last 30 minutes
- [ ] No errors in `api-logs/scanner/`
- [ ] Reply counts in logbook match Gmail label counts (approximately)

### 10. Follow Up Sanity

- [ ] No contact has received more than 3 follow ups (FU-04 should not exist in logbook yet)
- [ ] No follow ups sent on Saturday or Sunday
- [ ] Follow up cadence matches config (7d, 14d, 140d)

## Critical vs Informational

### Critical (block pipeline, page Nick)

- Em dash found in any outgoing channel
- Sheet to GHL drift > 10 items
- Follow up sent on a weekend
- A contact received more than 3 follow ups
- GHL pipeline stage IDs changed without update
- More than one template used for > 50% of sends (rotation broken)
- Missing `sheet_row_id` on more than 5 GHL opportunities

### Informational (note in report, do not block)

- `Why Muso Ads Matters` missing on 1 to 5 companies
- Reply rate trending down (but still > 5%)
- Company finder delivered fewer than 5 for a good reason
- Templates with < 10 sends (insufficient data)

## Output

Post to `#sales-alerts` (`C0ARQ021M40`):

```
🔍 *Outreach QA, YYYY-MM-DD*

Status: 🟢 All Green | 🟡 Warnings | 🔴 Critical Issues

Critical:
  • (none) OR list of critical issues with fix suggestions

Warnings:
  • ...

Informational:
  • Config: ✅
  • GHL stages: ✅
  • Sheet integrity: ✅
  • Drift: 0 items
  • Em dash sweep: 0 hits
  • Reply scanner last ran: {timestamp}
  • Discovery ran today: ✅ 5 companies posted
  • Template rotation: ✅
  • Follow up sanity: ✅

Pipeline drift (sheet vs GHL):
  • {N} rows in logbook, {M} opportunities in GHL, {K} reconciled

Next audit: {next run timestamp}
```

If status is 🔴 Critical, mention `@nick` at the top of the post.

## Never

- Never modify data during an audit (read only)
- Never auto fix issues (report, don't repair)
- Never skip a critical check
- Never silently ignore em dash hits (always escalate)
- Never mark the audit green if any critical check failed

## Why QA Exists

Every prior version of this system failed because state drifted silently between
sources. Batches went out with duplicates, replies were missed, stages fell out
of sync, em dashes crept in. QA catches these before they cause pain.

If QA is ever disabled or skipped, the rest of the engine starts to drift within
days.
