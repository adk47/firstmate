---
name: muso-winback-engine
description: |
  End-to-end winback and Lite-to-Pro upgrade campaign engine for Muso.AI.
  Sends personalized emails from Aaron to churned Pro users and high-value Lite users,
  monitors replies, handles conversations adaptively, and knows when to quit.

  Two campaigns: (1) Win-back churned Pro subscribers, (2) Upgrade engaged Lite users to Pro.
  Handles the full lifecycle: targeting, drafting, sending, reply monitoring, follow-up,
  and conversation management — all with human-like timing and behavior.

  WRITE ACCESS: Aaron (U7RP6HKUZ) ONLY. No one else can trigger sends.

  Use when: running winback campaigns, sending upgrade emails, monitoring winback replies,
  following up with churned users, converting Lite users to Pro.

  Triggers: "winback", "win-back", "win back", "churn recovery", "upgrade campaign",
  "lite upgrade", "re-engage", "churned users", "recovery email", "bring them back"
---

# Muso Win-Back & Upgrade Engine

Personalized email campaigns to recover churned Pro users and convert high-value Lite users.
Written as Aaron. Sent from `a@muso.ai`. Every email feels like a founder who noticed their profile.

## Access Control

**Aaron (U7RP6HKUZ) ONLY.** No one else can send, approve, or modify campaign state.

## Data Sources

### Churned Pro Users
Sheet: `1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`
Tab: `Win-Back Campaign - Churned Pro Users (Enriched)`
Account: `a@muso.ai`
~8,650 rows. Rolling 5-month window, refreshed daily at 10am PT via cron.

Key columns for filtering: `cancel_date`, `email`, `credits_count`, `popularity`, `has_claimed_profile`, `used_analytics`, `used_audits`, `used_roster`, `submitted_credits`, `viewed_profiles`, `logins_last_90d`
Tracking columns: `outreach_status`, `email_sent_date`, `email_variant`, `response_status`, `notes`, `stage`

### Lite Upgrade Targets
Sheet: `1T7R3RzwzWfQpZ8uIP9FcJeoWH4d5Vf-p2g9WV4tAd_U`
Tab: `Sheet1`
Account: `a@muso.ai`
~150 rows. High-value claimed Lite users with popularity ≥85.

Key columns: `email`, `first_name`, `last_name`, `profile_name`, `profile_id`, `popularity`,
`credits_count`, `roles`, `events_90d`, `used_analytics`, `used_audits`, `viewed_profiles`,
`submitted_credits`, `logins_90d`, `last_active`, `target_segment`, `value_prop`,
`profile_url`, `outreach_status`, `email_sent_date`, `email_variant`, `response_status`,
`notes`, `priority_tier`

### Reading Sheets

```bash
# Churned Pro (first 100 rows for inspection)
gog sheets get 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs \
  "Win-Back Campaign - Churned Pro Users (Enriched)!A1:AN101" --account a@muso.ai --plain

# Lite Upgrade Targets
gog sheets get 1T7R3RzwzWfQpZ8uIP9FcJeoWH4d5Vf-p2g9WV4tAd_U \
  "Sheet1!A1:AF200" --account a@muso.ai --plain
```

## Coupon Codes

Manual Stripe promotion codes (user enters at checkout):
- `LITE10` — 10% off monthly Pro
- `LITE20A` — 20% off annual Pro
- Users CAN use `LITE20A` on monthly too — intentional. If they "discover" this, they feel clever. We still win.
- Checkout promo code field is visible on monthly plans by default (Stripe `allow_promotion_codes: true`).
- For annual: if Path B (URL coupon param) is implemented, link directly. Otherwise instruct to enter code at checkout.

**Upgrade link:** `https://app.muso.ai/pricing?plan=pro`
Include the code in the email and tell them to enter it at checkout.

## Email Identity

- **From:** `a@muso.ai` (Aaron Kaufman)
- **Voice:** Aaron writing personally. Casual, direct, founder-to-creator. Not a marketing email.
- **Sign-off:** Just "Aaron" or "— Aaron" (no title, no company, no footer)

## Event-Driven Triggers

The engine runs reactively off two event sources, not manual commands:

### Trigger 1: New Sheet Rows (Daily Churn Cron)
The churn sheet refreshes daily at 10am PT. When new rows appear (fresh cancellations):
1. Pull all rows, sort by `cancel_date` DESC (LIFO — most recent first)
2. Identify rows where `outreach_status` is empty (untouched)
3. Filter out ineligible (Apple relay, no email, etc.)
4. **Check Stripe subscription status** before drafting (see Pre-Send Stripe Check below)
5. Draft emails for the next batch (up to 500/day)
6. Post batch to #clio_analyst for Aaron's approval
7. On approval, send and update sheet

### Trigger 2: Gmail Replies (3x Daily Scan)
Scan `label:Win-Back is:unread` in Gmail at 9am, 1pm, 5pm CST:
1. For each unread reply, read content and classify sentiment
2. **Check Stripe subscription status** — if they already re-subscribed, don't pitch
3. Look up their row in the sheet for context (what we sent, when, which template)
4. Draft response per Conversation Playbook with appropriate delay
5. Post to #clio_analyst: reply summary + draft response + scheduled send time
6. Update sheet: `response_status`, `stage`, `notes`

### Trigger 3: Follow-Up Due (Daily Check)
Daily at 10am CST, scan sheet for rows where:
- `outreach_status` = `sent` AND `email_sent_date` is 7+ days ago AND `response_status` is empty
- These are Day 7 follow-up candidates
1. **Check Stripe** — did they re-subscribe since our email? If yes → mark `converted`, skip
2. **Check Gmail** — did they reply and we missed it? If yes → process the reply instead
3. Draft follow-up emails
4. Post batch to #clio_analyst for approval

### Pre-Send Stripe Check (MANDATORY — before EVERY outreach action)
Before sending any email (initial, follow-up, or reply), verify the user hasn't re-subscribed:

```bash
# Search Stripe by email for active subscription
source ~/.zshrc && stripe customers search --query="email:'<user_email>'" --limit=1 2>&1
# Then check their subscriptions
source ~/.zshrc && stripe subscriptions list --customer=<cus_id> --status=active --limit=1 2>&1
```

**Rules:**
- If active subscription found → mark `outreach_status=converted` in sheet, do NOT email
- If no customer or no active sub → proceed with outreach
- This prevents embarrassing "come back!" emails to people who already came back
- Run this check for EVERY email: initial sends, follow-ups, AND conversation replies

### Sheet Status Tracking
Every interaction updates the sheet in real-time:

| Event | `outreach_status` | `response_status` | `stage` | `notes` |
|-------|-------------------|-------------------|---------|---------|
| Email sent | `sent` | | `initial` | template name, date |
| Follow-up sent | `follow_up_sent` | | `follow_up` | follow-up date |
| Positive reply | `replied` | `positive` | `conversation` | reply summary |
| Negative reply | `replied` | `negative` | `closed` | reply summary |
| Price objection | `replied` | `price_objection` | `conversation` | reply summary |
| Feature question | `replied` | `question` | `conversation` | reply summary |
| User re-subscribed | `converted` | | `closed` | date confirmed via Stripe |
| No reply after follow-up | `no_response` | `no_reply` | `closed` | |
| User asked to stop | `declined` | `negative` | `closed` | |

## Sending Rules

### Volume & Pacing
- Max 300 emails/day. LIFO order (most recent cancellations first).
- Space emails 2-4 minutes apart (never bulk blast)
- Only send 8:00 AM – 6:00 PM CST (recipient-facing sends)
- Never send Saturday or Sunday

### Gmail Commands
```bash
# Send HTML email with label
gog gmail messages send \
  --to "<email>" \
  --subject "<subject>" \
  --body-html "<html_body>" \
  --account a@muso.ai \
  --label "Win-Back"
```

### Email Formatting (MANDATORY)
- ALWAYS `--body-html` with `<p>` tags. NEVER `--body` or `--body-file`.
- Each paragraph = one `<p>` block, continuous flowing text, no `<br>` mid-paragraph.
- No images, no HTML tables, no fancy formatting. Plain styled text only.
- Hyperlink "Muso" or "Muso.AI" ONCE (first mention): `<a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>`

## Filtering — Skip These

Before drafting any email, filter out:
- `email` contains `privaterelay.appleid.com` → skip (Apple relay, unreliable delivery)
- `email` is empty or malformed → skip
- `outreach_status` is `sent`, `replied`, `declined`, `converted` → skip (already in pipeline)
- `has_claimed_profile` = `no` (churned sheet) → deprioritize (no profile to reference)
- For Lite sheet: `events_90d` = 0 AND `logins_90d` = 0 → skip (truly dormant)

Also check Gmail before each send:
```bash
gog gmail messages search "to:<email>" --account a@muso.ai
```
If we've already emailed them about winback/upgrade → skip unless follow-up eligible (>7 days, no reply).

## Tiering — Who Gets Emailed First

### Churned Pro Tiers
1. **Tier 1 — Hot** (send first): `popularity` ≥ 80, `credits_count` ≥ 500, cancelled in last 60 days, used features (`used_analytics` > 0 OR `used_audits` > 0)
2. **Tier 2 — Warm**: `popularity` ≥ 60, `credits_count` ≥ 100, cancelled in last 90 days
3. **Tier 3 — Long tail**: everyone else with valid email

### Lite Upgrade Tiers (from sheet's `priority_tier`)
1. Tier 1 — Active High-Pop + B2B targets
2. Tier 2 — Dormant High-Pop + Power Users
3. Tier 3 — Mid-Pop + Standard

## User Type Detection (MANDATORY — determines template)

Classify by first match (run in order):

1. **Has Credits** (`credits_count > 0`) ~83% — standard winback, reference catalog/credits/roles
2. **Roster Tracker** (`used_roster > 0`) ~5% — pitch Discovery/Roster analytics, NOT personal credits
3. **Credit Builder** (`submitted_credits > 0`) ~2.5% — lead with help getting set up, not features
4. **Power Browser** (`analytics + audits + viewed_profiles > 20`, `profile_id` exists) ~4% — help them claim/connect
5. **Needs Help** (same engagement but `profile_id = NONE`) — onboarding rescue, genuine help offer
6. **Tire-kicker** (everything else, `engagement < 5, logins < 3`) — generic short email

## Email Templates

See `references/email-templates.md` for the full template library.

Core principle: **reference their PUBLIC profile data (credits, roles, popularity), never their click behavior.**
Say "I was looking at your profile" — not "I see you viewed 42 audit reports."

### Personalization Variables
- `{first_name}` — from sheet
- `{profile_name}` — their Muso display name
- `{credits_count}` — total credits
- `{roles}` — their roles (Engineer, Producer, Songwriter, etc.)
- `{popularity}` — only reference indirectly ("one of the larger catalogs")
- `{cancel_reason}` — for churned users, adapt pitch if reason is known
- `{coupon_monthly}` — `LITE10` (or `LITE20A` — let them "discover" this)
- `{coupon_annual}` — `LITE20A`

### Subject Lines
- Churned Pro: `{first_name} — quick question about your {credits_count} credits`
- Lite Upgrade: `{first_name} — thought you'd want to see this`
- Follow-up: `re: {original_subject}` (threaded reply, not new email)

## Reply Monitoring & Conversation Handling

### Monitoring Schedule
Check for replies 3x daily during business hours (9am, 1pm, 5pm CST):
```bash
gog gmail messages search "label:Win-Back is:unread" --account a@muso.ai
```

### Response Timing — Human-Like Delays
**NEVER reply instantly.** Simulate Aaron's natural response pattern:
- Reply received 8am-12pm CST → respond 1-3 hours later (same morning)
- Reply received 12pm-6pm CST → respond 2-4 hours later (same afternoon)
- Reply received 6pm-11pm CST → respond next morning 9-10am CST
- Reply received 11pm-8am CST → respond 9-10am CST
- Reply received weekend → respond Monday 9-10am CST

### Conversation Playbook

- **Interested** → highlight 1-2 relevant features + coupon. Max 2 exchanges before offering a call.
- **Price objection** → offer LITE20A (20% off). Let them "discover" it works on monthly too.
- **Feature question** → answer accurately, briefly. If missing: "Not yet, on our roadmap."
- **"Not interested" / "Please stop"** → "No worries. Your profile's still there. — Aaron" Mark `declined`.
- **Angry** → "Appreciate the feedback, [name]." Mark `declined`. Done.
- **"I cancelled because [issue]"** → acknowledge genuinely. If fixed, say so. If not, be honest.
- **No reply** → see Follow-Up Cadence below.

### Know When to Quit
- Max 2 emails per person total (initial + 1 follow-up)
- If they reply negatively → DONE. Mark declined. Zero further contact.
- If no reply to follow-up → DONE. Mark `no_response`.
- Never argue. Never beg. Never send a third email.
- If someone re-subscribes independently → mark `converted`, stop all outreach.

## Follow-Up Cadence

- **Day 7:** One follow-up if no reply to initial email
- Follow-up should reference the original email: "Just bumping this — wanted to make sure it didn't get buried."
- Different angle: if initial was about analytics, follow-up mentions MLC audit or credit accuracy
- After follow-up with no reply → done. Mark `no_response`.
- Check Gmail for reply before sending follow-up — they may have replied and we missed the label.

## Sheet Updates

After every action, update the tracking columns in the source sheet:

```bash
# Update outreach_status, email_sent_date, email_variant for a specific row
gog sheets update <SHEET_ID> "<TAB>!<RANGE>" \
  --values '[["sent","2026-03-09","winback_v1"]]' --account a@muso.ai
```

Status values for `outreach_status`: `queued`, `sent`, `follow_up_sent`, `replied`, `converted`, `declined`, `no_response`, `bounced`
Status values for `response_status`: (empty), `positive`, `negative`, `question`, `price_objection`, `feature_request`, `no_reply`
`stage`: `initial`, `follow_up`, `conversation`, `closed`

## Logging (MANDATORY)

Log every action to `api-logs/gmail/YYYY-MM-DD.jsonl`:
```json
{"ts":"ISO8601","action":"winback_send","to":"email","name":"name","campaign":"churned_pro|lite_upgrade","variant":"template_name","subject":"subject","tier":"1|2|3"}
{"ts":"ISO8601","action":"winback_reply","from":"email","name":"name","sentiment":"positive|negative|question|price","response_summary":"brief summary"}
{"ts":"ISO8601","action":"winback_followup","to":"email","name":"name","followup_num":1}
```

## Batch Workflow — Sending a Batch

When Aaron says "send a batch" or "start the campaign":

1. **Select targets:** Pull eligible rows from the appropriate sheet, apply tier filtering
2. **Filter:** Remove skips (Apple relay, already contacted, no email, etc.)
3. **Check Gmail:** Verify no prior outreach to each target
4. **Draft emails:** Personalize using template + profile data. See `references/email-templates.md`
5. **Present for approval:** Show drafts to Aaron in Slack. Format:
   ```
   *Win-Back Batch — [date]*
   [X] emails ready

   1️⃣ *{profile_name}* — {roles} | {credits_count} credits | Pop {popularity}
      To: {email}
      Subject: {subject}
      [Full draft]

   2️⃣ ...
   ```
6. **Wait for "send" / "go"** — never auto-send
7. **Send:** Space 2-4 min apart, HTML format, label `Win-Back`
8. **Update sheet:** Set `outreach_status=sent`, `email_sent_date`, `email_variant`
9. **Log:** Write to `api-logs/gmail/YYYY-MM-DD.jsonl`

## Reply Monitoring — Integrated in Heartbeat

Reply monitoring runs automatically via HEARTBEAT.md (3x daily: 9am, 1pm, 5pm CST).
See Event-Driven Triggers section above for the full workflow.
Posts to #clio_analyst thread for Aaron's visibility. All replies get a drafted response
with appropriate timing delay before send.

## Metrics & Reporting

Track in the sheet and report weekly:
- Emails sent (by tier, by campaign)
- Reply rate (replies / sent)
- Positive reply rate (positive + question / sent)
- Conversion rate (re-subscribed / sent)
- Decline rate
- No-response rate
- Best-performing email variants

Post weekly summary to #clio_analyst on Mondays.

## Product Knowledge — What Pro Unlocks

Use this to craft accurate pitches. **Get the gating right.**

### Free for Everyone (Lite)
- Credit modifications (add/edit credits)
- Basic profile page
- Audit summary view (can see gaps exist, can't drill in)
- Limited profile browsing

### Pro Only
- **Full streaming analytics** across Spotify, YouTube, TikTok, Shazam, SoundCloud, Apple Music
- **Detailed audit reports** — drill into specific missing credits, MLC mechanical royalty audit
- **Roster management** — add profiles, track collaborators
- **Milestone sharing** — shareable achievement cards (certified streams, career firsts)
- **Discovery** — add any profile to Roster, see their analytics, collaborations, growth
- **Priority data capture** — Pro profiles get refreshed every 2 days vs 45-180 days for free

### The MLC Angle (strongest for songwriters/producers)
The MLC (Mechanical Licensing Collective) holds unclaimed mechanical royalties. Muso's audit tool
cross-references a user's catalog against MLC data to find money they didn't know existed.
For users with 500+ credits spanning songwriting/production, this is often the most compelling pitch.

## Constraints

- ❌ Never reference user's clickstream / behavioral data in emails (audit views, login counts, etc.)
- ❌ Never send without Aaron's explicit approval
- ❌ Never send more than 2 emails to any individual (initial + 1 follow-up)
- ❌ Never send outside 8am-6pm CST or on weekends
- ❌ Never reply to a user instantly — always delay per Response Timing rules
- ❌ Never argue with someone who says no
- ✅ Always reference public profile data (credits, roles, popularity tier) — this is visible on their profile
- ✅ Always check Gmail before sending to avoid double-contacting
- ✅ Always update sheet after every action
- ✅ Always log to api-logs before sending
- ✅ Always present drafts for approval before sending
