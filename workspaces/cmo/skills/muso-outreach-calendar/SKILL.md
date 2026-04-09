---
name: muso-outreach-calendar
description: |
  Scans Google Calendar on a@muso.ai for new B2B Ads meeting bookings. Detects
  calendar invites from prospects, triggers GHL stage move to Meeting Booked,
  logs to the logbook sheet, and posts notifications to #sales-alerts.

  Runs as a cron every 15 minutes. Silent unless a new meeting is detected.

  Use when: automated meeting detection, manual "check for meetings" request

  Triggers: "check meetings", "new meetings", "calendar scan", "meeting booked"
depends-on:
  - muso-outreach-engine
  - muso-outreach-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Outreach Calendar Scanner

Detects new B2B Ads meeting bookings on the a@muso.ai Google Calendar.

## Cadence

**Every 15 minutes.** Silent unless a new meeting is detected.

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Calendars to Watch

Primary account: `a@muso.ai`

Calendars (configurable, ask Fede to confirm):
- `Intro | Muso Ads`
- `Business Pro Meetings`
- `Muso Ads 2`

Also watch the main calendar for events with these keywords in the title or description:
- "Muso Ads"
- "Muso.AI"
- "demo"

## Workflow

### Step 1: Fetch Recent Events

```bash
gog calendar events list --account a@muso.ai \
  --time-min "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --time-max "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --calendar "<calendar_id>"
```

Query the last hour window for new events (overlap with previous run is fine,
we dedupe by event ID).

### Step 2: Deduplicate

Maintain a simple state file or memory key to track processed event IDs. Skip
any event ID already processed.

### Step 3: Match to Outreach Contact

For each new event:
1. Extract attendees (not including Aaron/Fede)
2. For each external attendee, lookup email in `contacts_intelligence`
3. If a match is found, this is a B2B Ads meeting booking
4. If no match, log it but do not process (might be a customer meeting, not outreach)

### Step 4: Trigger GHL Stage Move

Call `muso-outreach-ghl-sync` with:
- Contact email
- New stage: `Meeting Booked`
- Meeting details (date, time, calendar link)

### Step 5: Log to Sheet

Append to `muso-b2b-outreach-reports`:

```
N | YYYY-MM-DD | a@muso.ai | domain | Contact | Company | Title | email |
Meeting Booked | Meeting Booked | (meeting subject) | (original template) |
Meeting on YYYY-MM-DD HH:MM, link: <calendar_link>
```

### Step 6: Post to Slack

Post to `#sales-alerts` (`C0ARQ021M40`):

```
🗓 *Meeting Booked, YYYY-MM-DD*

Prospect: *{Contact Name}* ({Company}, {Title})
Meeting: {Meeting Title}
When: {Date} at {Time} {Timezone}
Link: <{calendar_link}|Open in Calendar>

Stage moved: {previous stage} → *Meeting Booked*
```

For high value prospects (C-level, Tier 1 companies), prepend the post with `@fede` mention.

### Step 7: Do Not Double Process

Mark the event as processed. On the next scan, skip.

## Never

- Never post "no meetings found"
- Never move a prospect to Meeting Booked without confirming attendee match
- Never confuse a demo call with a customer meeting (check against contacts_intelligence)
- Never auto accept a meeting on Fede or Aaron's behalf

## Error Handling

- If calendar API fails: log error, retry next run
- If attendee match is ambiguous: post to `#sales-alerts` with question, do not auto move GHL
- If the meeting was cancelled: move GHL stage to `No-Show` or back to `Replied`

## Legacy Note

This replaces the old calendar watcher that ran under Clio. Same logic, now posts
to `#sales-alerts` instead of `#clio_x_fede`.
