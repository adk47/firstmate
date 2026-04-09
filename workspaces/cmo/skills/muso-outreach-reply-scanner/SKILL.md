---
name: muso-outreach-reply-scanner
description: |
  Scans Gmail across all 4 Muso email accounts (a@, f@, ak@, aaron.k@) for new
  B2B Ads replies, categorizes each reply using the Post Reply Playbook,
  triggers GHL stage moves via muso-outreach-ghl-sync, logs to the logbook sheet,
  and posts notifications to #sales-alerts.

  Runs as a cron every 15 minutes. Silent unless a new reply is detected.

  Use when: automated reply detection, manual "check for replies" request

  Triggers: "check replies", "scan replies", "new b2b replies", "reply scanner"
depends-on:
  - muso-outreach-engine
  - muso-outreach-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
  cron: "b2b-reply-scanner-15m"
---

# Muso Outreach Reply Scanner

Automated reply detection across all 4 Muso email accounts.

## Cadence

**Every 15 minutes** via cron `b2b-reply-scanner-15m`.

**Silent if no new replies.** Never post "nothing found" messages.

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Workflow

### Step 1: Scan All 4 Accounts

```bash
for acct in a@muso.ai f@muso.ai ak@muso.ai aaron.k@muso.ai; do
  gog gmail messages search 'label:"B2B - Ads" is:unread in:inbox' --account $acct --max 50
done
```

The scanner runs in parallel on all 4 accounts.

### Step 2: Deduplicate

A thread may appear in multiple account inboxes if a prospect replied all. Merge
by thread ID and pick the most recent reply per thread. The `Muso Email` column
in the logbook captures which account received the reply.

### Step 3: Categorize Each Reply

Use the Post Reply Playbook (6 types):

| Type | Signal | Action |
|------|--------|--------|
| Send more info | "send me deck", "more info", "what do you have" | Reply with `access.muso.ai/demo` + 1 line |
| Let's schedule | "let's talk", "when are you free", calendar link | Move to Meeting Booked, book immediately |
| Adding colleague | "adding X", "looping in Y" | Shift focus to new contact, update GHL |
| Interesting, tell me more | "this is interesting", "curious" | Send access link + peer validation |
| We pass | "not interested", "pass", "not right now" | Move to Closed Lost, do not chase |
| Pivot / counter | wants affiliate, wants something different | Hold position, do not concede |

Classification uses keyword matching + Claude intent detection for edge cases.

### Step 4: Trigger GHL Stage Move

Call `muso-outreach-ghl-sync` with:
- Contact email or name
- New stage (based on reply type)
- Reply summary

GHL stage mapping:

| Reply Type | GHL Stage |
|------------|-----------|
| Send more info | Replied |
| Let's schedule | Meeting Booked |
| Adding colleague | Replied (update primary contact) |
| Interesting, tell me more | Replied |
| We pass | Closed Lost |
| Pivot / counter | Replied |

### Step 5: Log to Sheet

Append to `muso-b2b-outreach-reports`:

```bash
gog sheets append 1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0 \
  --range "muso-b2b-outreach-reports" \
  --values '[["N","YYYY-MM-DD","<muso_email>","<domain>","<contact>","<company>","<title>","<email>","Reply Received","Replied","<subject>","<template>","Reply type: <type>, snippet: <first 80 chars>"]]' \
  --account a@muso.ai
```

### Step 6: Update Template Stats

For the original template the contact was emailed with (from earlier logbook row):
- Bump `Replies` count
- Recalculate `Reply Rate (%)`
- If the reply type is Meeting Booked, bump `Meetings Booked` + recalculate `Booking Rate (%)`

### Step 7: Post to Slack

Post to `#sales-alerts` (`C0ARQ021M40`), following `muso-slack-formatter` rules:

```
📬 *New B2B Reply, YYYY-MM-DD HH:MM*

From: *{Contact Name}* ({Company}, {Title})
Received on: {muso_email}
Type: *{reply type}*
Stage moved: {previous stage} → *{new stage}*

Preview: _{first 150 chars of reply}_

Suggested next move:
{one line action based on type}
```

For `Meeting Booked` specifically, include calendar link if present.

### Step 8: Mark Read (Optional)

Do NOT auto mark as read. Leave unread so Fede can see the thread in his inbox.

## Never

- Never post "no replies found" (silent rule)
- Never auto reply to prospects (all replies are manual)
- Never move stage without also logging to the sheet
- Never skip the template stats update
- Never process the same reply twice (use thread ID dedup)

## Error Handling

- If Gmail auth fails on one account: log error, continue with the other 3, post an alert to `#sales-alerts`
- If GHL sync fails: still log to the sheet, retry GHL sync next run
- If Slack post fails: log to `api-logs/scanner/` and retry next run

## Legacy Note

This cron replaces the old `b2b-reply-scanner-15m` that ran under Clio. The logic
is the same but points to `#sales-alerts` instead of `#clio_x_fede`, and scans
all 4 Muso accounts instead of only a@.
