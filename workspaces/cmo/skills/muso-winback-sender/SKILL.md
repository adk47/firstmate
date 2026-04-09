---
name: muso-winback-sender
description: |
  Sends churned Pro win back email batches. Pulls tier batch from the sheet,
  runs the mandatory pre send Stripe check, calls muso-winback-writer for copy,
  presents batch for approval, sends from the appropriate Muso email account
  with CC support@muso.ai, applies Win-Back label, logs to sheet, syncs GHL,
  and posts notification to #win-back-alerts.

  Called by muso-winback-engine. Primary send pipeline for initial win back emails.

  Use when: "send winback", "send winback batch", "pull churned users", "execute winback"

  Triggers: "send winback", "winback batch", "send churned", "execute winback batch"
depends-on:
  - muso-winback-engine
  - muso-winback-writer
  - muso-winback-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Win Back Sender

Sends initial win back batches end to end.

## Access Control

Aaron (U7RP6HKUZ) and Fede (U07NF5A77E2) only.

## Shared Config

All IDs, accounts, sheets, channels, and rules are in
`../muso-winback-engine/references/config.md`.

## Workflow

### Step 1: Select Tier Batch

Pull the next batch of unsent contacts from the sheet, sorted by tier:

**Tier 1 (send first)**: VIP and high credit
- `popularity >= 80` AND `credits_count >= 500`
- Cancelled in last 60 days
- Used features (`used_analytics > 0` OR `used_audits > 0`)

**Tier 2 (warm)**:
- `popularity >= 60` AND `credits_count >= 100`
- Cancelled in last 90 days

**Tier 3 (long tail)**: everyone else with valid email

```bash
gog sheets get 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs \
  --range "high_value_churn" --account a@muso.ai
```

Filter to:
- `outreach_status` is empty (untouched)
- `email` is valid (not Apple relay, not malformed)
- `Pipeline Stage` not in [Re-subscribed, Lost / No Answer]

### Step 2: Filter Out Skips

Drop any row matching:
- `email` contains `privaterelay.appleid.com` (Apple relay, unreliable delivery)
- `email` is empty or malformed
- `outreach_status` in [`sent`, `replied`, `declined`, `converted`]
- `has_claimed_profile = no` (deprioritize, no profile to reference)

### Step 3: Gmail Crosscheck

For each remaining candidate, check Gmail across all 4 Muso accounts:

```bash
for acct in a@muso.ai f@muso.ai ak@muso.ai aaron.k@muso.ai; do
  gog gmail messages search 'label:"Win-Back" to:<email>' --account $acct
done
```

If any prior win back email exists to this address, skip unless follow up
eligible (handled by `muso-winback-followup`).

### Step 4: Pre Send Stripe Check (MANDATORY)

For each remaining candidate, verify they have NOT re subscribed:

```bash
source ~/.zshrc && stripe customers search --query="email:'<email>'" --limit=1
source ~/.zshrc && stripe subscriptions list --customer=<cus_id> --status=active --limit=1
```

If active subscription found:
- Update sheet: `outreach_status = converted`
- Move GHL stage to `Re-subscribed` (call `muso-winback-ghl-sync`)
- Skip the email
- Log to `api-logs/stripe/YYYY-MM-DD.jsonl`

This prevents sending "come back" emails to people who already came back. NEVER skip this check.

### Step 5: Draft Emails (call muso-winback-writer)

For each remaining contact, call `muso-winback-writer` with:
- Row from `high_value_churn`
- Touch number = initial
- Sender account (default `a@muso.ai`, see hive routing below)

Receive: `subject`, `body_html`, `template_id`, `language`, `checklist_passed`.

### Step 6: Hive Routing (Sender Selection)

Default for now: `a@muso.ai` carries the volume. The other 3 accounts (ak@,
aaron.k@, f@) need warming before full production use.

When the email engine is built and the hive is wired, sender selection will
distribute load across all 4 accounts up to 40 emails per account per day.
For now, use `a@muso.ai` unless explicitly told otherwise.

**See the Outstanding Items section in `muso-winback-engine/SKILL.md` for the
hive strategy reminder.**

### Step 7: Present for Approval

Post the batch to `#win-back-alerts` (`C0ARTH6U0S2`). Use `muso-slack-formatter`.

Format:

```
*Win Back Batch, YYYY-MM-DD* ({N} emails, from {muso_email})

1. *{first_name} {last_name}*, {profile_name}
   Email: {email}
   Tier: {tier}, Credits: {credits_count}, Popularity: {popularity}
   Template: {template_id}
   Language: {language}
   Subject: {subject}

   {full draft}

2. ...

⚠️ Coupon codes: TBD (Fede to provide before send)
```

Wait for explicit approval (`send`, `go`, `approved`). Never auto send.

### Step 8: Pacing and Send Window Check

Before sending, verify:
- Current time is between 8:00 AM and 6:00 PM CST
- Today is NOT Saturday or Sunday
- Today's send count for this account is below 40 (per account daily cap)
- Total today across all accounts is below 120

If any check fails, hold the batch and post to `#win-back-alerts`:
"Batch held: {reason}. Will resume {next valid window}."

### Step 9: Send

Send each email with 2 to 4 minute spacing:

```bash
gog gmail messages send \
  --to "<email>" \
  --cc "support@muso.ai" \
  --subject "<subject>" \
  --body-html "<html_body>" \
  --account <muso_email> \
  --label "Win-Back"
```

**Rules**:
- HTML body only (`--body-html`), never plain text
- CC `support@muso.ai` on every send
- NO BCC (combining CC + BCC triggers phishing detectors)
- Apply `Win-Back` label on send

### Step 10: Update Sheet

For each sent email:

```bash
gog sheets update 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs \
  --range "high_value_churn!<row>" \
  --values '[["sent","YYYY-MM-DD","<template_id>","","","Emailed"]]' \
  --account a@muso.ai
```

Update columns: `outreach_status`, `email_sent_date`, `email_variant`,
`Email Subject Sent`, `Email Body Sent`, `Pipeline Stage`.

### Step 11: GHL Sync

Call `muso-winback-ghl-sync` with:
- Email
- New stage: `Emailed`
- Sheet row reference

### Step 12: Log

Append to `api-logs/gmail/YYYY-MM-DD.jsonl`:

```json
{"ts":"ISO8601","action":"winback_send","to":"<email>","name":"<first> <last>","template":"<template_id>","tier":<tier>,"sender":"<muso_email>","language":"<lang>"}
```

### Step 13: Slack Notification

Post summary to `#win-back-alerts`:

```
📧 *Win Back Sent, YYYY-MM-DD* ({N} emails, from {muso_email})

1. *{first} {last}*, {profile_name} → Emailed ✅
2. ...

Templates: {template breakdown}
GHL: {N} opportunities moved to Emailed
Sheet: {N} rows updated
```

## Constraints

- Never send without explicit approval
- Never skip the Pre Send Stripe Check
- Never send on Saturday or Sunday
- Never send outside 8 AM to 6 PM CST
- Never exceed 40 per account or 120 total per day
- Always CC `support@muso.ai`
- Never BCC anyone (CC + BCC triggers phishing detectors)
- Always apply `Win-Back` label
- Always update sheet AND GHL after every send
- Never use em dash in any draft
- Never include a coupon code until Fede provides current ones
