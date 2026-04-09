# Win Back Engine Shared Config

Single source of truth for all IDs, URLs, and constants used by any
`muso-winback-*` subskill. If you change something here, it propagates to
every subskill that references this file.

**Do not hardcode these values in individual subskills.** Always reference this file.

This is the **CHURNED PRO WINBACK** engine. It is completely separate from the
B2B Ads outreach engine (`muso-outreach-*`). Different audience, different sheet,
different GHL location, different API key. Never mix them.

---

## Google Sheets

### Win Back Master Sheet
- **ID**: `1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`
- **URL**: https://docs.google.com/spreadsheets/d/1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs/edit
- **Account**: `a@muso.ai`

| Tab | gid | Purpose |
|-----|-----|---------|
| `pro_churned_all` | 280335637 | All churned Pro users (full population) |
| `high_value_churn` | 638190710 | High value subset (~1080 imported to GHL) |

#### Tab 1: pro_churned_all (gid=280335637)

All churned Pro users.

Columns: `cancel_date | email | first_name | last_name | plan_tier | plan_raw | billing_cycle | subscription_start | total_subscriptions | cancel_reason | profile_name | profile_id | credits_count | popularity | profile_type | roles | common_credits | primary_genre | country | years_active | follows_count | logins_last_90d | used_analytics | used_plaques | used_audits | viewed_profiles | used_encore | used_sharing | used_milestones | used_home_feed | submitted_credits | used_roster | has_claimed_profile | profile_url | outreach_status | email_sent_date | email_variant | response_status | notes | stage`

Tracking columns (writeback): `outreach_status`, `email_sent_date`, `email_variant`, `response_status`, `notes`, `stage`.

#### Tab 2: high_value_churn (gid=638190710)

High value subset, ~1080 contacts imported to GHL.

Columns: `email | first_name | last_name | profile_name | churn_date | total_months_subscribed | total_subscriptions | subscription_type | profile_type | roles | primary_genre | credits_count | popularity | cancel_feedback | cancel_reason | cancel_comment | psychological_lever | winback_strategy | email_template | profile_url | Comment Value | Language | Country | City | Next Up | Email Subject Sent | Email Body Sent | Pipeline Stage | Reply Date | Reply Content | Total LTV`

Special columns:
- **`psychological_lever`**: pre assigned strategy hook (e.g., "MLC royalties", "catalog scale")
- **`winback_strategy`**: pre assigned approach
- **`email_template`**: pre assigned template name. If set, use it. Otherwise fall back to user type detection.
- **`Language`**: country/language for multi language sends
- **`Next Up`**: batch planning column ("Next Up: EU (6am PST)", etc.)
- **`Email Subject Sent`**, **`Email Body Sent`**: actuals after send (writeback)
- **`Pipeline Stage`**: synced with GHL stage (writeback)
- **`Reply Date`**, **`Reply Content`**: writeback after reply detected
- **`Total LTV`**: monetary value for GHL opportunity sizing

#### Reading the Sheet

```bash
# All churned Pro
gog sheets get 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs \
  --range "pro_churned_all" --account a@muso.ai

# High value churn
gog sheets get 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs \
  --range "high_value_churn" --account a@muso.ai
```

---

## GHL (Win Back Location)

### Configuration

- **Location ID**: `fmK5Vl9sJv49WTYA0QyP` (Muso Win Back, NOT the B2B sales location)
- **Pipeline**: `Churn -> Win-back` (`AZa8jK5S7UyQ0fqfxzyB`)
- **API key**: `$GHL_WINBACK_API_KEY` (separate env var to avoid confusion with `$GHL_API_KEY` which is for B2B sales)
- **Base URL**: `https://services.leadconnectorhq.com`
- **Version header**: `Version: 2021-07-28`
- **Imported contacts**: ~1080 high value pro churned users

### Why a Separate API Key

Past versions hardcoded the win back API key directly in the skill file because
the agent kept confusing it with the B2B Ads `$GHL_API_KEY`. The fix: separate
env var. Add to `~/.zshrc`:

```bash
export GHL_WINBACK_API_KEY="pit-XXXXXXXXX"
```

Verified during STARTUP.md Phase 5.

### Pipeline Stages (7 stages)

| # | Stage | Stage ID | Trigger |
|---|---|---|---|
| 1 | Churned | `819bd77b-9b34-4773-bdb3-4f532f925a9a` | Imported, not yet emailed |
| 2 | Next Up | `6f5fe454-c404-49c5-ac0c-c05299781ca2` | Queued for next batch |
| 3 | Emailed | `c01f6866-106a-4663-b177-93af8603a920` | Initial email sent |
| 4 | Replied | `73b66a22-98cb-47a5-b4fd-3b558394cc7b` | Reply detected in Gmail |
| 5 | Follow-up | `24f693ab-714e-4585-9245-100e50210eaa` | Day 7 / Day 45 follow up sent |
| 6 | Re-subscribed | `e51bd206-edec-4bb5-b344-39b2d96cd39e` | Detected in Stripe (won) |
| 7 | Lost / No Answer | `6a357aa2-e62b-4e7e-92dc-d124530c44b2` | Day 90 no reply, or declined |

Verify these IDs in STARTUP.md Phase 5 by fetching the live pipeline.

### GHL Pagination Rule

Use GET with `page=N` for opportunity searches. POST search is broken (caps at
100, cursor does not work).

```bash
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_WINBACK_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=fmK5Vl9sJv49WTYA0QyP" \
  -d "pipeline_id=AZa8jK5S7UyQ0fqfxzyB" \
  -d "limit=100" -d "page=1" | python3 -m json.tool
```

### Opportunity Metadata (Required on every create)

- **Name format**: `{first_name} {last_name} | {profile_name}`
- **Tags**: `win-back-pro` (always), plus tier and reason tags as applicable
- **Monetary value**: set to `Total LTV` from the sheet (recovery potential)
- **Custom field `sheet_row_id`**: row index in `high_value_churn` (enables reverse lookup)

### Tags Convention

- `win-back-pro`: all imported contacts
- `high-value`: credits > 500 OR popularity > 80
- `payment-recovery`: cancel_reason = payment_failed
- Cancel reason tag: `churn-too-expensive`, `churn-unused`, `churn-other`, etc.

---

## Stripe (Pre Send Check)

Before EVERY send (initial, follow up, reply), verify the user has not already
re subscribed:

```bash
source ~/.zshrc && stripe customers search --query="email:'<user_email>'" --limit=1
source ~/.zshrc && stripe subscriptions list --customer=<cus_id> --status=active --limit=1
```

If active subscription found:
- Mark `outreach_status = converted` in sheet
- Move GHL stage to `Re-subscribed`
- DO NOT email
- Log to `api-logs/stripe/YYYY-MM-DD.jsonl`

This prevents embarrassing "come back!" emails to people who already came back.

---

## Gmail

### Sender Account

**Current (2026-04-09)**: ALL winback sends go from `a@muso.ai` only.

The other 3 accounts (`ak@`, `aaron.k@`, `f@`) are in Snov.io warm up as of
2026-04-09. Expected full capacity ~2026-05-21. Do NOT send real winback
campaigns from warming accounts. The hive rotation system (documented in
`wiki/workflows/email-engine.md`) is PAUSED until warming completes.

Gmail scanning (reply detection, crosscheck) STILL runs across all 4 accounts
because historical win back threads may exist on any of them.

### Email Identity

- **From**: depends on hive routing (default `a@muso.ai`)
- **CC**: `support@muso.ai` on EVERY email (so support sees all win back threads)
- **BCC**: none (BCC was removed; CC + BCC together triggers phishing detectors)
- **Voice**: see `muso-winback-writer` skill
- **Sign off**: just "Aaron" (no title, no company, no footer)
- **Length**: 150 to 350 characters body (short, spartan, plain)
- **Format**: HTML with `<p>` tags, never plain text

### Gmail Label

`Win-Back` (or `Win-Back Pro` if that already exists from prior config)

Verified during STARTUP.md Phase 3.

### Hyperlink Rule

Hyperlink "Muso" or "Muso.AI" ONCE (first mention only):
```
<a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>
```

---

## Slack Channel

| Purpose | Channel | ID |
|---------|---------|----|
| All win back notifications (sends, replies, daily report, alerts) | `#win-back-alerts` | `C0ARTH6U0S2` |

**Never** post win back notifications to `#clio_x_fede`, `#clio_analyst`, or
`#sales-alerts`. Those are wrong channels.

---

## Output Rules

### Prohibited Characters
- **Em dash (—) PROHIBITED.** Zero tolerance. Use commas, periods, parentheses, or restructure.
- En dash (–) is allowed.
- Hyphen (-) is allowed.

### Email Format
- HTML with `<p>` tags only. Never plain text.
- 150 to 350 characters body. Shorter is better.
- Plain styled text. No images, no tables, no tracking pixels, no fancy formatting.
- Hyperlink "Muso.AI" once, first mention only.
- Sign off: just "Aaron"

### Slack Format
- Follow `muso-slack-formatter` rules.
- No markdown tables, no headings. Bold: `*text*`. Italic: `_text_`. Links: `<url|text>`.
- Bullet markers: `•` not `-`.

---

## Volume and Pacing

### Daily Volume
- Total: **120 emails per day**
- Per email account: **40 each** (when hive is fully warmed)
- Currently `a@muso.ai` carries primary volume; other accounts ramp via warming

### Send Windows
- Only 8:00 AM to 6:00 PM CST (recipient facing)
- Never send Saturday or Sunday
- Space sends 2 to 4 minutes apart (never bulk blast)

### Timezone Batching

Use the `Next Up` column in `high_value_churn` to plan timezone aware sends:

| Batch | Send Time (CST) | Approx Volume |
|-------|----------------|---------------|
| EU (`Next Up: EU`) | 6:00 AM PST = 8:00 AM CST | ~40 |
| US East (`Next Up: US East`) | 9:00 AM CST | ~40 |
| US West (`Next Up: US West`) | 10:00 AM CST | ~20 |
| APAC / Other (`Next Up: APAC`) | 5:00 PM CST | ~20 |

Total: 120/day across all timezones.

---

## Cadence

| Touch | Days After Initial | Action |
|-------|-------------------|--------|
| Initial | 0 | First email |
| Follow up 1 | 7 | Day 7 nudge |
| Follow up 2 | 45 | Day 45 fresh angle |
| Lost | 90 | If still no reply, mark `Lost / No Answer` |

Stop after Follow up 2 with zero replies. Mark `Lost / No Answer` at Day 90.

**Never send on Saturday or Sunday.** Push weekend follow ups to Monday.

---

## Coupon Codes

**TBD.** Fede has indicated new coupon codes need to be set up before launch.

Old codes (from prior config, may be deprecated):
- `LITE10`, 10% off monthly Pro
- `LITE20A`, 20% off annual Pro

**Action item**: Fede will provide current coupon codes before campaign launch.
Until then, do NOT include any coupon code in drafts. Flag the gap in batch
preview for Fede review.

Upgrade link: `https://app.muso.ai/pricing?plan=pro`

---

## Email Deliverability (DNS Requirements)

Before any campaign launch, verify:
- **DKIM**: `google._domainkey.muso.ai` exists with valid RSA key
- **SPF**: Uses `-all` (hardfail), not `~all` (softfail)
- **DMARC**: At least `p=quarantine` (ideally `p=reject` after monitoring)

If any DNS check fails, STOP and alert. Do not send.

### Content Rules to Avoid Spam Flags

- NO "account inactive", "account suspended", "verify your account", "click here to reactivate"
- NO BCC + CC together (triggers phishing detectors)
- Body under 400 chars (shorter = higher deliverability)
- Subject NOT salesy: no urgency, no "action required", no "verify"
- Plain text feel: minimal HTML, no images, no tracking pixels
- Signature link (`www.muso.ai`) is the ONLY link allowed in first touch

### Warm Up Protocol (per email account)

For `ak@`, `aaron.k@`, `f@` (the un-warmed accounts):
- Day 1 to 3: 20 emails/day to most engaged contacts
- Day 4 to 7: 50 emails/day
- Day 8 to 14: 100 emails/day
- Day 15+: full 120/day capacity

Monitor bounce rate. If >5% on any day, STOP and investigate.
Monitor spam reports. If ANY, STOP immediately.

---

## API Log Destinations

- Gmail actions: `api-logs/gmail/YYYY-MM-DD.jsonl`
- GHL actions: `api-logs/ghl-winback/YYYY-MM-DD.jsonl`
- Stripe checks: `api-logs/stripe/YYYY-MM-DD.jsonl`
- Sheet updates: `api-logs/sheets/YYYY-MM-DD.jsonl`

Log format: `{timestamp, action, target, requester, payload_summary, result}`

---

## History

- 2026-04-09: initial shared config created during win back rebuild. Cadence
  changed from 7/14/21 to 7/45/90. Lite-to-Pro campaign dropped. API key moved
  to env var. CC only (BCC removed).
