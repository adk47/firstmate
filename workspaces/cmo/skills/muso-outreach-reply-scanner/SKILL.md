---
name: muso-outreach-reply-scanner
description: |
  Scans Gmail across all 4 Muso email accounts (a@, f@, ak@, aaron.k@) for new
  B2B Ads replies, categorizes each reply, and (via muso-outreach-reply-responder)
  posts a single suggested reply to #sales-alerts. Read-only on systems of record:
  NocoDB is read for context only, never written; no GHL, no Google Sheets, no
  stage moves, no auto-send.

  Runs as a cron every hour. Silent unless a new reply or bounce is detected.

  Use when: automated reply detection, manual "check for replies" request

  Triggers: "check replies", "scan replies", "new b2b replies", "reply scanner"
depends-on:
  - muso-outreach-engine
  - muso-outreach-reply-responder
  - muso-slack-formatter
metadata:
  version: "2.0"
  last-updated: "2026-06-05"
  cron: "b2b-reply-scanner-hourly"
---

# Muso Outreach Reply Scanner

Automated reply detection across all 4 Muso email accounts.

## Cadence

**Every hour** via cron `b2b-reply-scanner-hourly` (job id
`0e39220e-d666-4f00-b871-29a479315037`, agent `cmo`, isolated session).

**Silent if nothing actionable.** When no new prospect replies or B2B bounces are
found, the run's final visible message must be exactly `NO_REPLY` — OpenClaw
recognizes that token and silently completes the run without posting to Slack.
Never post "nothing found".

## Systems of record (read-only)

- **Gmail owns send/reply detection.** It is the source of truth for inbound mail.
- **NocoDB is read-only** — the source of contact/company context. Look up the
  contact/company when possible. **Do not write to NocoDB.**
- **Do not use GHL. Do not use Google Sheets.** (The old GHL stage-move + logbook
  Sheet workflow is retired; Fede/team update the NocoDB Status manually.)
- Do not move pipeline stages. Do not auto-reply. Do not create Gmail drafts. Do
  not mark messages read.

## Workflow

### Step 1: Scan all 4 accounts (last ~70 minutes)

Scan `a@muso.ai`, `f@muso.ai`, `ak@muso.ai`, `aaron.k@muso.ai`. Use a broad gog
Gmail search with the body included — **do not rely only on `label:"B2B - Ads"`**,
because inbound replies often do not carry the label. Search broadly for inbox
replies tied to Muso Ads outreach, including subjects/bodies around: Muso Ads,
Muso.AI, calendar.muso.ai, Private invite, 820K, "ads to 820K", "Reaching 820K",
"Muso.AI x".

### Step 2: Deduplicate

A thread may appear in multiple account inboxes if a prospect replied-all. Merge
by Gmail `threadId` and account; pick the most recent reply per thread.

### Step 3: Filter to real prospect items

Keep true prospect replies, meeting-booking language, referrals / new points of
contact, questions, pricing asks, explicit pass/unsubscribe replies, OOO with
useful referral info, and B2B delivery failures/bounces. Filter out internal
muso.ai mail, SaaS notifications, DMARC reports, newsletters, spam, and unrelated
support noise.

### Step 4: Classify each item

Classify as one of: **Replied, Meeting Booked, Referral, Pricing, Question,
Interested/send-info, Soft-no/later, Pass, Bounce, OOO, Other.** Classification
uses keyword matching + intent detection for edge cases.

### Step 5: Draft via muso-outreach-reply-responder

For each real item, apply `muso-outreach-reply-responder`:
- Decide answer vs skip.
- Match sender voice to the receiving account: `a@`/`ak@`/`aaron.k@` = Aaron,
  `f@` = Fede.
- Pull thread history before drafting when available.
- If answering, provide ONE exact suggested reply whose only goal is a 15–20
  minute call. Keep warm-thread replies short and playbook-native. No em dashes
  or en dashes.
- **Do not create the Gmail draft until Fede or Aaron approves in Slack.**

### Step 6: Post to Slack

Post to `#sales-alerts` (`C0ARQ021M40`) as concise mrkdwn. Per item:

```
*New B2B Reply*
From: *<name>* (<company>, <title if known>)
Received on: <account>
Type: *<classification>*
Preview: _<short preview>_
Verdict: answer / skip

*Suggested reply:*
> <exact draft body, as Aaron or Fede would send>
```

Manual next step: Fede/Aaron approve before any Gmail draft is created. Fede/team
updates the NocoDB Status manually if needed.

## Never

- Never post "no replies found" (silent rule — emit `NO_REPLY` instead).
- Never auto-reply to prospects or create a Gmail draft before approval.
- Never write to NocoDB, GHL, or Google Sheets.
- Never mark messages read.
- Never process the same reply twice (dedupe by `threadId` + account).

## Error Handling

- If Gmail auth fails on one account: continue with the other 3 and note the
  failed account in the Slack post. The cron-health watchdog will also surface a
  failed run to `#clio_devops`.
- If the Slack post fails: the cron's `bestEffort` delivery means the run still
  completes; the watchdog catches a hard error.

## Legacy Note

Earlier versions of this scanner ran every 15 minutes, scanned only `a@`, relied
on the `B2B - Ads` label, moved GHL stages, and appended to the
`muso-b2b-outreach-reports` Sheet. That GHL/Sheets/label-only workflow is retired.
The current cron is hourly, scans all 4 accounts with a broad query, is read-only
on systems of record, and leaves CRM updates to a human via NocoDB.
