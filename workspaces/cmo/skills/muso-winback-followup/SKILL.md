---
name: muso-winback-followup
description: |
  Sends Day 7 and Day 45 follow ups for churned Pro win back. Marks contacts as
  Lost at Day 90. Pulls candidates from sheet + GHL Emailed/Follow-up stages,
  runs the Stripe check, generates thread reply, sends on approval, logs.

  Cadence: Day 7, Day 45, Day 90 = Lost. Stops at 2 follow ups with no reply.
  Never sends on Saturday or Sunday.

  Use when: "send winback follow ups", "monday winback batch", "winback nudges"

  Triggers: "winback follow up", "winback nudge", "day 7 winback", "day 45 winback"
depends-on:
  - muso-winback-engine
  - muso-winback-writer
  - muso-winback-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Win Back Follow Up

Handles the follow up cadence for churned Pro win back.

## Access Control

Aaron (U7RP6HKUZ) and Nick (U0AL36NADEY) only.

## Shared Config

See `../muso-winback-engine/references/config.md`.

## Cadence

| Touch | Days After Initial | Action |
|-------|-------------------|--------|
| Initial | 0 | First email (handled by muso-winback-sender) |
| Follow up 1 (FU-01) | 7 | Day 7 nudge |
| Follow up 2 (FU-02) | 45 | Day 45 fresh angle |
| Lost | 90 | Mark `Lost / No Answer` |

Stop after Follow up 2 with zero replies.

**Never send on Saturday or Sunday.** Push weekend follow ups to Monday.

## Workflow

### Step 1: Identify Day 7 Candidates

Daily at 10 AM CST, pull contacts from the sheet matching:
- `outreach_status = sent` OR `outreach_status = follow_up_sent` (FU-01 only)
- `email_sent_date` is exactly 7 days ago (or 7 to 9 days for catch up)
- `response_status` is empty
- `Pipeline Stage` not in [Replied, Re-subscribed, Lost / No Answer]

### Step 2: Identify Day 45 Candidates

Daily at the same time, pull contacts matching:
- `outreach_status = follow_up_sent` (FU-01 already sent)
- 45 days since `email_sent_date`
- `response_status` is empty
- `Pipeline Stage = Follow-up`

### Step 3: Identify Day 90 Lost Candidates

Daily, pull contacts matching:
- `outreach_status = follow_up_sent` (FU-02 already sent)
- 90 days since initial `email_sent_date`
- `response_status` is empty

For these, do NOT send. Move to `Lost / No Answer`:
- Update sheet: `outreach_status = no_response`, `stage = closed`
- Call `muso-winback-ghl-sync` to move GHL stage to `Lost / No Answer`
- Log to `api-logs/gmail/YYYY-MM-DD.jsonl`

### Step 4: Pre Flight Checks (MANDATORY for each Day 7 / Day 45 candidate)

Before drafting any follow up, verify:

**4a. Stripe check**
```bash
source ~/.zshrc && stripe customers search --query="email:'<email>'" --limit=1
source ~/.zshrc && stripe subscriptions list --customer=<cus_id> --status=active --limit=1
```
If active subscription found, mark as `converted` and skip.

**4b. Gmail reply check** across all 4 Muso accounts:
```bash
for acct in a@muso.ai f@muso.ai ak@muso.ai aaron.k@muso.ai; do
  gog gmail messages search 'label:"Win-Back" from:<email>' --account $acct
done
```
If any inbound reply exists, skip the follow up. Update sheet to `replied` and call `muso-winback-ghl-sync` to move stage to `Replied`.

**4c. Bounce check**: confirm the original send did not bounce. If bounced, mark `Lost / No Answer`.

### Step 5: Select Template

Day 7 → `FOLLOWUP_DAY_7`
Day 45 → `FOLLOWUP_DAY_45`

Templates live in `../muso-winback-writer/references/email-templates.md`.

### Step 6: Draft (Thread Reply)

Call `muso-winback-writer` with:
- Row data
- Touch number (FU-01 or FU-02)
- Sender account (same as original send)

Use `--reply-to-message-id` pointing to the LAST sent message in the thread.
Verify by reading the thread first.

```bash
gog gmail drafts create \
  --to "<email>" \
  --cc "support@muso.ai" \
  --reply-to-message-id "<last_message_id>" \
  --body-html "<html_body>" \
  --account <muso_email> \
  --label "Win-Back"
```

Subject auto inherits as `re: {original subject}`.

### Step 7: Present for Approval

Post the batch to `#win-back-alerts`:

```
*Win Back Follow Up Batch, YYYY-MM-DD* ({N} follow ups: {X} Day 7, {Y} Day 45)

1. *{first} {last}*, {profile_name} → Day 7 (sent {X} days ago)
   Template: FOLLOWUP_DAY_7
   Preview: {first line}

2. ...

⚠️ Will mark {Z} contacts as Lost (Day 90 reached, no reply)
```

Wait for explicit approval.

### Step 8: Send

```bash
gog gmail drafts send <draftId> --account <muso_email>
gog gmail messages modify <messageId> --add "Win-Back" --account <muso_email>
```

Reapply the label after send (drafts do not auto inherit).

### Step 9: Log + Sheet + GHL Updates

For each sent follow up:
- Update sheet: `outreach_status = follow_up_sent`, bump touch counter, `Pipeline Stage = Follow-up`
- Call `muso-winback-ghl-sync` to move GHL stage to `Follow-up`
- Append to `api-logs/gmail/YYYY-MM-DD.jsonl` with action `winback_followup`, `followup_num` 1 or 2

For Day 90 Lost moves:
- Update sheet: `outreach_status = no_response`, `stage = closed`, `Pipeline Stage = Lost / No Answer`
- Call `muso-winback-ghl-sync` to move GHL stage to `Lost / No Answer`
- Append to `api-logs/gmail/YYYY-MM-DD.jsonl` with action `winback_lost`

### Step 10: Slack Notification

Post summary to `#win-back-alerts`:

```
📧 *Win Back Follow Ups Sent, YYYY-MM-DD* ({N} sent, {Z} marked Lost)

Day 7: {X}
Day 45: {Y}
Marked Lost (Day 90): {Z}

GHL: {N+Z} stage moves
```

## Constraints

- Never send on Saturday or Sunday
- Never send more than 2 follow ups per contact
- Never send if Stripe shows active subscription (mark `converted`)
- Never send if Gmail shows inbound reply (mark `replied`)
- Never send if original bounced (mark Lost)
- Never send without Aaron or Nick approval
- Always reply as a thread (use `--reply-to-message-id`)
- Always CC `support@muso.ai`
- Never BCC
- Always apply `Win-Back` label after send
- Always update sheet AND GHL after every action
- Never use em dash in any draft
