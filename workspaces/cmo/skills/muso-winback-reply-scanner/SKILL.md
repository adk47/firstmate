---
name: muso-winback-reply-scanner
description: |
  Scans Gmail across all 4 Muso accounts (a@, f@, ak@, aaron.k@) 3x daily for
  new Win-Back replies, classifies sentiment, runs Stripe check (in case they
  re subscribed), updates sheet, moves GHL stage, and posts to #win-back-alerts.
  Drafts a contextual response with human like timing delay.

  Runs as a cron 3x daily (9 AM, 1 PM, 5 PM CST). Silent unless a new reply
  is detected.

  Use when: automated reply detection, manual "check winback replies" request

  Triggers: "check winback replies", "scan winback", "winback replies"
depends-on:
  - muso-winback-engine
  - muso-winback-writer
  - muso-winback-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
  cron: "winback-reply-scanner-3x"
---

# Muso Win Back Reply Scanner

Automated reply detection across all 4 Muso email accounts for win back replies.

## Cadence

**3x daily**: 9 AM, 1 PM, 5 PM CST. Cron `winback-reply-scanner-3x`.

**Silent if no new replies.** Never post "nothing found" messages.

## Shared Config

See `../muso-winback-engine/references/config.md`.

## Workflow

### Step 1: Scan All 4 Accounts

```bash
for acct in a@muso.ai f@muso.ai ak@muso.ai aaron.k@muso.ai; do
  gog gmail messages search 'label:"Win-Back" is:unread in:inbox' --account $acct --max 50
done
```

The scanner runs in parallel on all 4 accounts.

### Step 2: Deduplicate

A thread may appear in multiple inboxes if support@muso.ai is CC'd. Merge by
thread ID, pick the most recent reply per thread.

### Step 3: Classify Each Reply

Categorize using these types:

| Type | Signal | Suggested Action |
|------|--------|------------------|
| Interested | "tell me more", "interesting", "details please" | Reply with feature highlight + (TBD coupon) |
| Question | "how does X work", "what about Y" | Answer accurately, briefly |
| Price objection | "too expensive", "can't afford", "cheaper option" | (TBD: offer discount when coupon codes ready) |
| Negative | "not interested", "stop", "remove me" | Reply once: "No worries. Your profile's still there. Aaron". Mark `declined`. |
| Angry | hostile or upset language | Reply once: "Appreciate the feedback, {name}. Aaron". Mark `declined`. |
| Cancel reason elaboration | "I cancelled because X" | Acknowledge genuinely. If fixed, say so. If not, be honest. |
| Re subscription confirmation | "I already came back" | Verify in Stripe, mark `converted`. |
| Out of office | auto reply | Skip, mark to retry in 7 days |

Classification uses keyword matching plus Claude intent detection for edge cases.

### Step 4: Stripe Re Verification

For each reply, run a fresh Stripe check (the user may have re subscribed
between the original send and now):

```bash
stripe customers search --query="email:'<email>'" --limit=1
stripe subscriptions list --customer=<cus_id> --status=active --limit=1
```

If active subscription found:
- Mark `outreach_status = converted` in sheet
- Move GHL stage to `Re-subscribed`
- Do NOT pitch in the response
- Reply with a genuine "great to have you back" message

### Step 5: Update Sheet

For the matching row in `high_value_churn`:

| Reply Type | `outreach_status` | `response_status` | `stage` | `Pipeline Stage` |
|------------|-------------------|-------------------|---------|------------------|
| Interested | `replied` | `positive` | `conversation` | `Replied` |
| Question | `replied` | `question` | `conversation` | `Replied` |
| Price objection | `replied` | `price_objection` | `conversation` | `Replied` |
| Negative | `declined` | `negative` | `closed` | `Lost / No Answer` |
| Angry | `declined` | `negative` | `closed` | `Lost / No Answer` |
| Cancel elaboration | `replied` | `question` | `conversation` | `Replied` |
| Re subscribed | `converted` | | `closed` | `Re-subscribed` |
| Out of office | (no change) | | | |

Also append to `Reply Date` and `Reply Content` columns.

### Step 6: GHL Sync

Call `muso-winback-ghl-sync` with:
- Email
- New stage based on classification
- Reply summary for opportunity notes

### Step 7: Draft Response

Call `muso-winback-writer` with the reply context. The writer crafts a response
in Aaron's voice that matches the classification.

**Never reply instantly.** Apply human like delay:

| Reply Received | Respond At |
|----------------|-----------|
| 8 AM to 12 PM CST | 1 to 3 hours later (same morning) |
| 12 PM to 6 PM CST | 2 to 4 hours later (same afternoon) |
| 6 PM to 11 PM CST | Next morning 9 to 10 AM CST |
| 11 PM to 8 AM CST | 9 to 10 AM CST |
| Weekend | Monday 9 to 10 AM CST |

Schedule the draft to send at the calculated time.

### Step 8: Slack Notification

Post to `#win-back-alerts` (`C0ARTH6U0S2`):

```
📬 *Win Back Reply, YYYY-MM-DD HH:MM*

From: *{first} {last}* ({profile_name})
Received on: {muso_email}
Type: *{reply type}*
Stage moved: {previous} → *{new}*

Preview: _{first 200 chars of reply}_

Draft response queued for: {scheduled_send_time}

Suggested next move:
{one line action}
```

For `Re subscribed` specifically, include the new subscription details from
Stripe (plan, MRR recovered).

### Step 9: Log

Append to `api-logs/gmail/YYYY-MM-DD.jsonl`:

```json
{"ts":"ISO8601","action":"winback_reply","from":"<email>","name":"<first> <last>","sentiment":"<type>","summary":"<first 100 chars>"}
```

## Conversation Playbook (Quick Reference)

- **Interested**: highlight 1 to 2 relevant features. Max 2 exchanges before offering a call.
- **Price objection**: TBD coupon offer. Until codes are set, escalate to Aaron.
- **Feature question**: answer accurately and briefly. If missing, "Not yet, on our roadmap."
- **"Not interested" / "Please stop"**: reply once with `"No worries. Your profile's still there. Aaron"`. Mark `declined`. Done.
- **Angry**: reply once with `"Appreciate the feedback, {name}. Aaron"`. Mark `declined`. Done.
- **"I cancelled because [issue]"**: acknowledge genuinely. If fixed, say so. If not, be honest.
- **No reply**: handled by `muso-winback-followup`.

## Know When To Quit

- Max 2 emails total per person (initial + 1 follow up... actually 2 follow ups in current cadence: Day 7 and Day 45)
- Negative reply → DONE. Mark `declined`. Zero further contact.
- No reply at Day 90 → DONE. Mark `Lost / No Answer`.
- Never argue. Never beg. Never send a 4th email.
- Re subscription detected → mark `converted`, stop all outreach.

## Constraints

- Never reply instantly (always delay per timing rules)
- Never auto send a response (all responses go through approval flow)
- Never argue with someone who declined
- Never send a 4th email (initial + 2 follow ups + reply response is the absolute max)
- Always run Stripe check before sending response
- Always update sheet and GHL on every classification
- Never post "nothing found" silent rule
- Never use em dash in any draft response
