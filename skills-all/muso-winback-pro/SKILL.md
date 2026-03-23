---
name: muso-winback-pro
description: |
  Win-back campaign engine for churned Muso Pro users. Sends personalized emails from Aaron's account
  to high-value churned subscribers. Manages the full lifecycle: prospect selection, email drafting,
  timezone-batched sending, reply scanning, GHL pipeline sync, and daily reporting.

  COMPLETELY SEPARATE from B2B Ads outreach (muso-outreach-engine). Different audience, different
  pipeline, different GHL location, different strategy. Never mix them.

  Use when: sending win-back emails, checking win-back replies, importing churned users to GHL,
  running daily win-back batches, win-back reporting, or any churned Pro user re-engagement.

  Triggers: "win-back", "winback", "churned users", "churned pro", "win back", "re-engage churned",
  "high-value churns", "reactivation campaign"
allowed-tools:
  - Bash
compatibility: |
  Requires GHL_WINBACK_API_KEY env var (or use key directly).
  Requires GOG_KEYRING_PASSWORD for Gmail sends via gog.
  Requires AWS credentials for Athena queries.
metadata:
  version: "1.0"
  created: "2026-03-21"
---

# Win-Back Pro Campaign Skill

Personalized email campaign to win back churned Muso Pro subscribers.

## ⛔ CRITICAL: This is NOT B2B Ads Outreach

| | Win-Back Pro (THIS SKILL) | B2B Ads (muso-outreach-engine) |
|---|---|---|
| Audience | Individual Pro users who cancelled | Companies who never had Muso |
| GHL Location | `fmK5Vl9sJv49WTYA0QyP` (Muso Win-Back) | `S5w31kRRgsBjjiVATWlP` (B2B Ads) |
| GHL API Key | `pit-239a5db4-6ba1-4b6e-857d-0f8cc4464410` | `$GHL_API_KEY` (pit-bbc35461...) |
| Pipeline | Win-Back pipeline (TBD) | B2B-Ads-Clio |
| Email style | Personal from Aaron, 150-350 chars | Private Invite format |
| Google Sheet | "High-Value Churns" tab | clay_n8n_clio_b2b_ads sheet |

**NEVER use the B2B Ads API key or pipeline for win-back. NEVER use the Win-Back API key for B2B Ads.**

## Access Control

- **Aaron (U7RP6HKUZ):** Full access
- **Fede (U07NF5A77E2):** Full access (co-owns the campaign)
- **All others:** Read-only (can view reports, not trigger sends)

## GHL Configuration

- **Location ID:** `fmK5Vl9sJv49WTYA0QyP`
- **API Key:** `pit-239a5db4-6ba1-4b6e-857d-0f8cc4464410`
- **Pipeline:** `Churn -> Win-back` (ID: `AZa8jK5S7UyQ0fqfxzyB`)
- **Pipeline Stages:**
  - Churned: `819bd77b-9b34-4773-bdb3-4f532f925a9a`
  - Next Up: `6f5fe454-c404-49c5-ac0c-c05299781ca2`
  - Emailed: `c01f6866-106a-4663-b177-93af8603a920`
  - Replied: `73b66a22-98cb-47a5-b4fd-3b558394cc7b`
  - Follow-up: `24f693ab-714e-4585-9245-100e50210eaa`
  - Re-subscribed: `e51bd206-edec-4bb5-b344-39b2d96cd39e`
  - Lost / No Answer: `6a357aa2-e62b-4e7e-92dc-d124530c44b2`
- **IMPORTANT:** Always pass `locationId=fmK5Vl9sJv49WTYA0QyP` in GHL API calls
- **Base URL:** `https://services.leadconnectorhq.com`
- **API Version:** `2021-07-28`

## Google Sheet

- **Sheet ID:** `1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`
- **Tab:** "High-Value Churns"
- **Criteria:** credits > 100 OR popularity > 50, cancelled in last 6 months
- **Columns:** A-AF
  - A-X: Core data (email, name, churn data, credits, popularity, cancel reason/comment, psych lever, winback strategy, email template, comment value, language, country, city)
  - Y: **Next Up** (batch planning: "Next Up: EU (6am PST)", etc.)
  - Z: **Email Subject Sent** (actual subject used)
  - AA: **Email Body Sent** (actual body sent)
  - AB: **Pipeline Stage** (synced with GHL: Churned/Emailed/Replied/Follow-up/Re-subscribed/Lost)
  - AC: **Reply Date** (when they replied)
  - AD: **Reply Content** (what they said)
  - AE: **Monthly Value** (plan price/month)
  - AF: **Total LTV** (monthly value x months subscribed)

## Email Rules

- **From:** a@muso.ai (Aaron's account)
- **CC:** support@muso.ai on EVERY email (so support sees all win-back threads)
- **BCC:** aaron@muso.ai on EVERY email (Aaron sees everything, recipient doesn't know)
- **Voice:** Aaron, the CEO. Personal, direct, confident, helpful.
- **Length:** 150-350 characters. Short, spartan, plain language.
- **Subject:** Short recap of the email that triggers interest. Feels personal and serious, like the CEO reaching out. NOT salesy, NOT marketing, NOT clickbait.
- **Language:** Match the user's language (English, French, Italian, Dutch, Spanish, Portuguese, German, etc.)
- **No em dashes.** No marketing fluff. No filler words.
- **Format:** Always `--body-html` with `<p>` tags via gog gmail send.
- **Gmail Label:** Every sent email gets labeled "Win-Back Pro" for organization.
- **Signature:** `Aaron, CEO & Founder | www.muso.ai` (HTML link)
- **MUST verify Gmail label exists before first send.** Create it if missing.

## Email Deliverability Rules (CRITICAL)

### DNS Requirements (must be verified before ANY campaign launch)
- **DKIM:** `google._domainkey.muso.ai` must exist with valid RSA key (Google Admin Console → Gmail → Authenticate Email)
- **SPF:** Must use `-all` (hardfail), not `~all` (softfail)
- **DMARC:** Must be at least `p=quarantine` (ideally `p=reject` after monitoring)
- **Pre-flight check:** Before first batch of any day, verify all 3 DNS records are valid. If any fail, STOP and alert.

### Content Rules to Avoid Spam Flags
- NO "note for support" or system explanations in user-facing emails
- NO phrases: "account inactive", "account suspended", "verify your account", "click here to reactivate"
- Avoid combining BCC + CC (triggers phishing detectors)
- Keep body under 400 chars (shorter = higher deliverability)
- Subject must NOT sound like phishing: no urgency, no "action required", no "verify"
- Plain text feel: minimal HTML, no images, no tracking pixels, no links in first email
- Signature link (www.muso.ai) is the ONLY link allowed in first touch

### Warm-Up Protocol (for new campaigns)
- Day 1-3: Send 20/day to most engaged contacts (recently active before churn)
- Day 4-7: Ramp to 50/day
- Day 8-14: Ramp to 100/day
- Day 15+: Full 120/day
- Monitor bounce rate: if >5% on any day, STOP and investigate
- Monitor spam reports: if ANY, stop and investigate immediately

## Daily SOP (120 emails/day)

### Step 1: Pull Next Batch
Pull 120 unsent contacts from the sheet, sorted by priority:
1. VIP (popularity >= 80)
2. High-credit (credits > 500)
3. Payment recovery (reason = payment_failed)
4. Rest by LTV descending

### Step 2: Group by Timezone
- EU batch (~40): send at 6am PST = 3pm CET
- US East batch (~40): send at 9am PST
- US West batch (~20): send at 10am PST
- APAC/Other (~20): send at 5pm PST

### Step 3: Draft Emails
For each contact, generate personalized email using:
- Their credit count, popularity, roles
- Cancel reason and comment (if available)
- Winback strategy from the sheet
- Their language

### Step 4: QA Pass (MANDATORY)
Before sending any batch:
- No broken names (ALLCAPS first names = fix to Title Case)
- Language matches country
- Subject follows approved format
- Body is 150-350 chars
- No duplicate sends (check sheet "emailed" column)

### Step 5: Send
Via `gog gmail send --to <email> --subject <subject> --body-html <html> --account a@muso.ai`

### Step 6: Track
- Mark row as "Emailed" with date in sheet column S (email_template)
- Create/update GHL opportunity at "Emailed" stage
- Log to `api-logs/gmail/YYYY-MM-DD.jsonl`

### Step 7: Reply Scan (3x daily)
- Check Gmail for replies to win-back emails
- Post new replies to #clio_x_fede (C0AHN078CSH)
- Move GHL opportunity to "Replied"
- If resubscription detected, move to "Re-subscribed"

### Step 8: End of Day Report
Post to #clio_x_fede:
- Emails sent today
- Replies received
- Resubscriptions
- Running totals

## Reporting Channel

All win-back reports and reply alerts go to **#clio_x_fede (C0AHN078CSH)**.

## Follow-Up Cadence

- Day 7: First follow-up (if no reply)
- Day 14: Second follow-up (if no reply)
- Day 21: Mark as "Lost / No Answer" (no more touches)

Follow-up templates: TBD (Fede to approve)

## Tagging Convention

All GHL contacts imported for win-back get tagged:
- `win-back-pro` (all)
- `high-value` (credits > 500 or pop > 80)
- `payment-recovery` (reason = payment_failed)
- Cancel reason tag: `churn-too-expensive`, `churn-unused`, `churn-other`, etc.

## Gmail Organization

- **Label:** `Win-Back Pro` on all outgoing win-back emails
- **Threading:** Each person gets one thread. Follow-ups reply in-thread.
- **Search:** `label:Win-Back Pro` to see all campaign emails
- **Reply detection:** Search `label:Win-Back Pro is:inbox -from:a@muso.ai`

## Scripts

All scripts live in `scripts/` directory:

| Script | Purpose | Schedule |
|--------|---------|----------|
| `daily-winback.sh` | Main engine: pull batch, draft, send, sync GHL | Daily via cron (4 batches) |
| `winback_engine.py` | Core logic: prioritization, drafting, sending, tracking | Called by daily-winback.sh |
| `qa_checklist.py` | Multi-pass QA engine (structural, content, cross-ref) | Called by winback_engine.py |
| `plan_batch.py` | Midnight planner: selects next 120, marks "Next Up" in sheet | Daily at 12:00 AM |
| `reply_scanner.py` | Scan Gmail for replies, post to Slack, update GHL + sheet | 3x daily via cron |
| `sanity_check.py` | Cross-check sheet vs GHL vs Gmail, flag drift | Daily via heartbeat |

### Running manually:
```bash
# Dry run (drafts only, no sends)
bash scripts/daily-winback.sh 10 dry

# Live send 10 emails
bash scripts/daily-winback.sh 10

# Full daily batch
bash scripts/daily-winback.sh 120

# Scan for replies
python3 scripts/reply_scanner.py

# Sanity check
python3 scripts/sanity_check.py
```

## Cron Schedule

| Time (PST) | Action |
|------------|--------|
| 12:00 AM | `plan_batch.py` - Select next 120, mark "Next Up" in sheet by timezone |
| 6:00 AM | EU batch (~40 emails from "Next Up: EU") |
| 9:00 AM | US East batch (~40 emails from "Next Up: US") |
| 10:00 AM | US West + Other batch (~20 emails from "Next Up: Other") |
| 11:00 AM | Reply scan #1 + sheet/GHL update |
| 3:00 PM | Reply scan #2 + sheet/GHL update |
| 5:00 PM | APAC batch if needed (~20 emails from "Next Up: APAC") |
| 7:00 PM | Reply scan #3 + sheet/GHL update |
| 8:00 PM | Daily report to #clio_x_fede |
| 8:30 PM | Sanity check (sheet vs GHL vs Gmail cross-ref) |

## Daily Report Format (posted to #clio_x_fede)

```
Win-Back Daily Report - [DATE]

Sent today: X
Total sent to date: X / 1,197
Replies today: X
Total replies: X (X% reply rate)
Re-subscriptions: X ($X MRR recovered)

Pipeline: Churned X | Emailed X | Replied X | Follow-up X | Re-subscribed X | Lost X

Top replies: [summary of notable replies]
```

## Opportunity Value

Each GHL opportunity's monetary value = Total LTV from the sheet.
This represents how much that person has already paid us, so we know the recovery potential.

## Multi-Pass QA Engine (`qa_checklist.py`)

Every email goes through 3 QA passes before it can be sent. ALL must pass.

### Pass 1: Structural
- Email format valid (has @, valid domain)
- Not a noreply/bounce address
- Not a disposable email domain
- Subject exists, 5-80 chars
- Body 100-500 chars (target 150-400)
- Body ends with "Aaron"

### Pass 2: Content
- No em dashes or en dashes
- No marketing buzzwords (23 banned phrases)
- First name present in body, not ALLCAPS
- No full name in greeting (first only)
- Language matches (French email = French greeting, etc.)
- Credits count mentioned accurately
- No placeholder text ({}, [NAME], TODO, etc.)
- Subject is not just a greeting ("hey", "hi")

### Pass 3: Cross-Reference
- Not a duplicate (checked against all previously sent)
- Within-batch duplicate check
- Churn date within valid range (not >1 year, not future)
- Strategy aligns with email content
- Email domain not disposable

If ANY check fails, the email is rejected with detailed reasons. Warnings are logged but don't block.

## Sanity Checks (Recurring)

1. **Sheet vs GHL drift:** emailed count in sheet should match GHL "Emailed" stage count. Flag if >5 difference.
2. **Gmail vs Sheet drift:** count of sent Win-Back Pro labeled emails should match sheet emailed count.
3. **Duplicate detection:** before sending, check if email was already sent (sheet column S + within-batch).
4. **Rate limit guard:** stop at 450 emails/day (well under Gmail's 2,000 workspace limit).
5. **Bounce detection:** if Gmail returns errors for specific emails, mark as "Lost" in GHL + sheet.
6. **Resubscription detection:** cross-check Stripe/subscription data weekly for contacts who came back.
7. **Pipeline Stage sync:** sheet column AB must match GHL stage. Sanity check flags mismatches.
8. **Next Up planning:** midnight planner marks 120 contacts. If fewer than 120 unsent remain, report it.
9. **Reply tracking:** every reply updates both GHL (stage → Replied) AND sheet (Reply Date + Content columns).
10. **Bounce detection:** check Gmail for bounce-back / delivery failure notifications. Mark bounced contacts as "Lost / No Answer" in GHL + sheet. Remove from future batches.
11. **Unsubscribe/spam detection:** if someone marks email as spam or sends an unsubscribe request, immediately remove from all future sends. Mark as "Lost / No Answer" with reason "unsubscribed."
12. **B2B Ads cross-check:** before sending, verify contact email is not an active B2B Ads prospect (check B2B-Ads-Clio pipeline in the other GHL location). Avoid double-emailing the same person from two campaigns.
13. **Gmail label pre-flight:** before the first send of any day, verify the "Win-Back Pro" label exists. Create it if missing. If labeling fails, log a warning but don't block the send.
