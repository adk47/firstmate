---
name: muso-outreach-calendar
description: |
  Scans the a@muso.ai Google Calendar for newly-booked B2B Ads meetings (events
  created in roughly the last hour with an external prospect attendee) and posts
  a notification to #sales-alerts. Read-only: NocoDB is read for context only;
  no GHL, no Google Sheets, no stage moves, no calendar modifications.

  Runs as a cron every hour. Silent unless a new meeting is detected.

  Use when: automated meeting detection, manual "check for meetings" request

  Triggers: "check meetings", "new meetings", "calendar scan", "meeting booked"
depends-on:
  - muso-outreach-engine
  - muso-slack-formatter
metadata:
  version: "2.0"
  last-updated: "2026-06-05"
  cron: "b2b-meeting-scanner-hourly"
---

# Muso Outreach Calendar Scanner

Detects newly-booked B2B Ads meetings on the `a@muso.ai` Google Calendar.

## Cadence

**Every hour** via cron `b2b-meeting-scanner-hourly` (job id
`217113ad-34ad-4ad8-81a8-c8452a635afc`, agent `cmo`, isolated session).

**Silent if nothing new.** When no qualifying new meetings are found, the run's
final visible message must be exactly `NO_REPLY` — OpenClaw recognizes that token
and silently completes the run without posting to Slack. (The gateway only
suppresses the literal `NO_REPLY` token; do not invent a `NO_MEETING` token — it
would be posted to Slack.)

## Systems of record (read-only)

- **gog owns calendar read.** It is the source of truth for bookings.
- **NocoDB is read-only** — contact/company context only. Look up the external
  attendee's company when possible. **Do not write to NocoDB.**
- **Do not use GHL. Do not use Google Sheets.** (The old GHL Meeting-Booked
  stage-move + logbook Sheet workflow is retired; Nick/team update NocoDB
  manually.)
- Do not move pipeline stages. **Do not create, modify, or delete any calendar
  event** (no auto-accept on Nick/Aaron's behalf).

## Workflow

### Step 1: Fetch events

Run **exactly** this command — do not add other flags (especially not `--fields`,
which the agent tends to malform):

```bash
gog -a a@muso.ai calendar events --from=today --days=90 --max=250 --all-pages --json
```

Each event carries `created`, `updated`, `start`, `summary`, and `attendees`.

### Step 2: Keep only newly-booked prospect meetings

Keep an event only if it BOTH:

1. has a `created` timestamp within the last ~70 minutes (compare `created` vs now
   in UTC — this is the "newly booked" signal, regardless of when the meeting is
   scheduled to occur), AND
2. has at least one attendee whose email domain is **not** `muso.ai` (an external
   prospect).

Deduplicate by event `id`. Ignore internal-only events, personal events,
all-hands, standups, OOO, and recurring internal meetings.

### Step 3: Post to Slack

Post to `#sales-alerts` (`C0ARQ021M40`) as concise mrkdwn, one block per meeting:

```
*New B2B Meeting Booked*
With: *<name>* (<company>, <title if known>)
When: <event start, with timezone>
Account: a@muso.ai
Attendees: <external attendees>
```

Manual next step: Nick/Aaron set the prospect's NocoDB Status to Meeting Booked.

## Never

- Never post "no meetings found" (silent rule — emit `NO_REPLY` instead).
- Never write to NocoDB, GHL, or Google Sheets.
- Never create, modify, accept, or delete a calendar event.
- Never process the same event twice (dedupe by event `id`).
- Never treat an internal-only event as a prospect meeting (require an external
  attendee).

## Error Handling

- If the calendar read fails: the cron's `bestEffort` delivery lets the run
  complete, and the cron-health watchdog surfaces a hard error to `#clio_devops`.
- If attendee context is ambiguous: still post the meeting with what is known;
  do not block on enrichment.

## Legacy Note

Earlier drafts of this skill described a 15-minute cron that moved GHL stages to
Meeting Booked and appended to the `muso-b2b-outreach-reports` Sheet — and, in
fact, no cron was ever deployed for it. The current cron (`b2b-meeting-scanner-hourly`,
added 2026-06-05) is hourly, read-only on systems of record, and notifies
`#sales-alerts` only, leaving the CRM update to a human via NocoDB.
