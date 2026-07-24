# HEARTBEAT.md, CMO Automation Registry

Registry of all active cron jobs, automations, and scheduled tasks the CMO
agent runs. This file documents WHAT runs, WHEN it runs, WHERE it posts, and
WHO it alerts.

**Not an implementation file.** Actual cron schedules live on the HYDRA server
or in n8n workflows. This file is the source of truth for the schedule itself.

_Updated 2026-04-09 during CMO rebuild. Channels updated to reflect the new
split: `#sales-alerts` for outreach, `#win-back-alerts` for winback._

---

## Posting Rule (Universal)

- Heartbeat system posts → **MAIN CHANNEL** (top level), never in a thread
- Use `message(action=send, target=<channel_id>)` with NO `threadId` or `replyTo`
- Silent rule: if an automation has nothing new to report, POST NOTHING. Never spam "nothing found" messages.

---

## System Heartbeat (HYDRA health)

**Cron**: every 6 hours
**Posts to**: `#hydra-heartbeat`
**Payload**:
```json
{"agent": "cmo", "status": "healthy", "timestamp": "<ISO8601>"}
```

Part of the HYDRA agent hive standard health check. Proves CMO is alive.

---

## Outreach Engine Automations

All outreach related crons post to `#sales-alerts` (`C0ARQ021M40`).
**Never post outreach notifications to `#clio_x_fede`.** That is the old Clio channel, deprecated for sales.

### Reply Scanner (every 60 minutes)

**Cron**: `b2b-reply-scanner-1h`
**Runs**: every 60 minutes
**Scans**: Gmail inbox on `a@muso.ai` for B2B prospect replies
**On reply detected**:
1. Classify reply type per `muso-outreach-reply-scanner` SKILL
2. Move GHL opportunity stage via `muso-outreach-ghl-sync`
3. Log to `muso-b2b-outreach-reports` sheet
4. Bump template stats (`Replies`, `Reply Rate`)
5. Post to `#sales-alerts` with prospect + reply type + suggested next move

**Silent if no new replies.**

### Calendar Scanner (every 15 minutes)

**Cron**: `b2b-calendar-scanner-15m`
**Runs**: every 15 minutes
**Scans**: Google Calendar on `a@muso.ai` for new B2B Ads meeting bookings
**Calendars**: `Intro | Muso Ads`, `Business Pro Meetings`, `Muso Ads 2`
**On booking detected**:
1. Match attendee to contact in NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`)
2. Move GHL opportunity to `Meeting Booked` via `muso-outreach-ghl-sync`
3. Log to `muso-b2b-outreach-reports`
4. Post to `#sales-alerts` with meeting details

**Silent if no new meetings.**

### Daily GHL Reconciliation (once per day, 6 AM CST)

**Cron**: `b2b-ghl-reconciliation-daily`
**Runs**: daily at 6 AM CST
**Action**: full pass through `muso-b2b-outreach-reports` sheet and GHL `B2B-Ads-Clio` pipeline to catch any drift between sources. Catches anything the 15-minute reply scanner missed.
**Posts**: reconciliation summary to `#sales-alerts` only if drift was found.

### Monday Follow Up Batch Prep

**Cron**: `b2b-followup-monday`
**Runs**: Mondays at 9 AM CST
**Action**: `muso-outreach-followup` pulls contacts due for follow up (7d, 14d, 140d), crosschecks Gmail for replies, drafts follow up batch for approval.
**Posts**: draft batch to `#sales-alerts` for Nick to review and approve.

**Status**: NOT YET LIVE. Follow up automation is paused until GHL + sheet sync is fully working. Enable once first few batches have been tested manually.

### Daily Company Finder (moved to @Scout)

> **Owned by the Scout agent now, not CMO.** The `company-finder-daily` cron runs as `scout`
> and the `muso-outreach-discovery` skill lives in Scout's workspace. CMO is not responsible for
> this cron. Approved companies still flow back into this funnel as `Needs Enrichment` Company
> Intelligence rows; "find new companies" requests should be routed to `@Scout`.

**Cron**: `company-finder-daily` (agentId: scout)
**Runs**: daily at 1 PM CEST (Nick's timezone)
**Action**: `muso-outreach-discovery` finds 5 new parent companies matching target verticals, dedupes against sheet + GHL + parent-companies.md, applies rollup logic.
**Posts**: batch of 5 new parent companies to `#company-finder` (`C0ARS7XMY93`)

**Status**: PLANNED, not yet wired. Requires Datagma / Snov.io / Enrow accounts to be active first.

### Outreach QA (daily)

**Cron**: `muso-outreach-qa-daily`
**Runs**: daily at 8 AM CST
**Action**: `muso-outreach-qa` audits every outreach subskill for drift, em dash violations, stage ID correctness, sheet to GHL consistency.
**Posts**: audit results to `#sales-alerts` (critical issues mention `@nick`)

---

## Win Back Engine Automations

All winback related crons post to `#win-back-alerts` (`C0ARTH6U0S2`).
**Never post winback notifications to `#clio_x_fede` or `#clio_analyst`.**

### Reply Scanner (3x daily)

**Cron**: `winback-reply-scanner-3x`
**Runs**: 3x daily at 9 AM, 1 PM, 5 PM CST
**Scans**: Gmail label `Win-Back` across all 4 Muso accounts
**On reply detected**:
1. Classify reply type per `muso-winback-reply-scanner` SKILL
2. Run fresh Stripe check (user may have re subscribed)
3. Move GHL opportunity stage via `muso-winback-ghl-sync`
4. Update sheet `high_value_churn` tracking columns
5. Draft contextual response with human-like delay timing
6. Post to `#win-back-alerts`

**Silent if no new replies.**

### Daily Follow Up Check

**Cron**: `winback-followup-daily`
**Runs**: daily at 10 AM CST
**Action**: `muso-winback-followup` scans sheet for Day 7, Day 45, and Day 90 candidates. Marks Day 90 no-reply as Lost. Drafts Day 7 and Day 45 follow ups.
**Posts**: draft follow up batch to `#win-back-alerts` for approval.

**Status**: NOT YET LIVE. Waiting on first send batches to test.

### Daily GHL Reconciliation

**Cron**: `winback-ghl-reconciliation-daily`
**Runs**: daily at 7 AM CST
**Action**: full pass through `high_value_churn` sheet and `Churn -> Win-back` GHL pipeline. Catches drift. Also runs a fresh Stripe check on all Emailed and Follow-up stage contacts to detect silent re subscribers.
**Posts**: reconciliation summary to `#win-back-alerts` only if drift found.

### Win Back QA (daily)

**Cron**: `winback-qa-daily`
**Runs**: daily at 8 AM CST
**Action**: `muso-winback-qa` audits every winback subskill for drift, em dash violations, Pre Send Stripe Check compliance, BCC detection, wrong API key usage, DNS deliverability.
**Posts**: audit results to `#win-back-alerts` (critical issues mention `@aaron` and `@nick`)

### Daily Win Back Report

**Cron**: `winback-report-daily`
**Runs**: daily at 8 PM CST
**Action**: `muso-winback-reporter` generates daily summary (sends, replies, re subscriptions, pipeline snapshot).
**Posts**: daily summary to `#win-back-alerts`.

---

## Nick Personal Briefings

### EOD Briefing

**Cron**: `cmo-eod-briefing`
**Runs**: daily at 22:00 CET (Nick's local evening)
**Action**: `cmo-eod` skill generates a top-level header message with threaded updates covering: tech, Nick mentions, replies to Nick, channels, marketing systems, email, outreach and pipeline, ClickUp, other.
**Posts**: to Nick's Slack DM (`D0AKT90NQJX`)

**Note**: delivered to Nick's DM (reassigned from `#clio_x_fede`, Fede's old
channel, during the Fede→Nick handover). The destination is set in one place —
`cron-jobs.json` (`cmo-eod-briefing` → `delivery.to`).

**Rules**:
- ONCE per day only. Never re-send. Track state to prevent duplicate sends.
- Max 40 bullet points total. Brevity is the default.
- Required 3-point crosscheck for any data (Gmail + GHL + sheet).
- If there is nothing meaningful to report, post a single-line "quiet day" acknowledgment. Do NOT skip the briefing entirely (Nick wants to see it went out).

---

## AMP Daily Report

**Cron**: `amp-daily-report`
**Runs**: daily at 11:00 AM CST (9:00 AM PST)
**Action**: Query core-backend `ad_events` and `ads` via Trino (`postgresql_core.public`, `muso query`). Post summary: all-time / 7d / today with deltas, top 5 ads by CTR, underperformers, AMP vs Feed, platform breakdown, daily trend.
**Posts**: to `#growth-team` (`C031DKAGQSH`)

**Note**: "AMP" here refers to the Muso Amp product, not Muso Ads. See
`wiki/company/product-naming.md`.

---

## Cron Channel Summary Table

| Channel | Crons Posting Here |
|---------|-------------------|
| `#sales-alerts` (`C0ARQ021M40`) | b2b-calendar-scanner-15m, b2b-ghl-reconciliation-daily, b2b-followup-monday, muso-outreach-qa-daily |
| `#company-finder` (`C0ARS7XMY93`) | company-finder-daily |
| `#win-back-alerts` (`C0ARTH6U0S2`) | winback-reply-scanner-3x, winback-followup-daily, winback-ghl-reconciliation-daily, winback-qa-daily, winback-report-daily |
| Nick DM (`D0AKT90NQJX`) | cmo-eod-briefing |
| `#growth-team` (`C031DKAGQSH`) | amp-daily-report |
| `#hydra-heartbeat` | 6-hour health check |

---

## Status Legend

- **ACTIVE**: cron is wired and running
- **NOT YET LIVE**: cron is documented but not yet scheduled (waiting on prerequisites)
- **PLANNED**: cron is designed but not yet built

## Current Status Check (2026-04-09)

| Cron | Status | Blocker |
|------|--------|---------|
| HYDRA heartbeat | ACTIVE | none |
| b2b-reply-scanner-1h | ACTIVE | posts to `#sales-alerts` (`C0ARQ021M40`); scans `a@muso.ai` only |
| b2b-calendar-scanner-15m | ACTIVE | same |
| b2b-ghl-reconciliation-daily | ACTIVE | same |
| b2b-followup-monday | NOT YET LIVE | first manual batches pending |
| company-finder-daily | PLANNED | enrichment stack (Datagma, Snov.io, Enrow) not yet wired |
| muso-outreach-qa-daily | NOT YET LIVE | turn on after first batch sends |
| winback-reply-scanner-3x | PLANNED | first win back batch not yet sent |
| winback-followup-daily | NOT YET LIVE | first batch pending |
| winback-ghl-reconciliation-daily | NOT YET LIVE | first batch pending |
| winback-qa-daily | NOT YET LIVE | first batch pending |
| winback-report-daily | NOT YET LIVE | first batch pending |
| cmo-eod-briefing | ACTIVE | running |
| amp-daily-report | ACTIVE | running |

Update this table as crons come online.

---

## History

- 2026-04-09: full rewrite during CMO rebuild. Channels migrated from `#clio_x_fede` / `#clio_analyst` to `#sales-alerts` / `#win-back-alerts` / `#company-finder`. Added winback QA, reporter, reply scanner crons. Marked status for each cron.
- 2026-03-24: original "cutover from Clio complete" content (deprecated)
