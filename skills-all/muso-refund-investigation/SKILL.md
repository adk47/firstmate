---
name: muso-refund-investigation
description: |
  Investigate a Muso.AI user's activity and subscription history to support refund decisions.
  Produces a standardized report for finance/operations team.

  Use when: evaluating a refund request, checking if a user was active before canceling,
  investigating whether a refund is warranted, or any "should we refund this user?" question.

  Triggers: "refund", "refund request", "refund investigation", "should we refund",
  "evaluate refund", "refund decision", "cancel and refund", "chargeback"
depends-on:
  - muso-stripe
  - muso-analytics
  - muso-amplitude
  - muso-slack-formatter
compatibility: |
  Requires muso-stripe, muso-analytics (muso-amplitude as fallback until the
  Amplitude cutover), muso-slack-formatter skills. Trino access
  (via `muso query`) for deep investigation.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Refund Investigation Skill

Standardized checklist for evaluating Muso.AI refund requests. Run every step in order and present a single summary report.

## Investigation Checklist

All SQL below runs on Trino: `muso query - <<'SQL'` heredocs (CSV with header; see `muso-query-writer`).

### 1. Identify the User

Get user email or name from the requester. Use it to find:
- Stripe customer ID (`stripe customers list --email="..."`)
- Muso user id (from the Muso user record below; product activity is looked up by user id, step 5)
- Muso user record: `muso users search '<email>' --env prod --json` (typed; use this, not SQL)

### 2. Repeat Offender Check (Stripe)

Check if this user has a pattern of subscribing, canceling, and resubscribing to extract value (tiles, stats) without staying:

```bash
# Get ALL subscriptions for this customer (including canceled)
stripe subscriptions list -d "customer=cus_XXX" -d "status=all" --limit 100
```

Flag as *repeat offender* if:
- 2+ canceled subscriptions followed by resubscription
- Short subscription periods (< 30 days) repeated
- Previous refunds on record

If flagged, note the pattern clearly in the summary — this is a strong signal against granting a refund.

### ⛔ One-Time Complimentary Refund Policy

*Each user gets ONE complimentary refund. Ever. No exceptions.*

If a refund has already been issued on this account, the answer is *REFUND NOT ALLOWED* — skip to the summary.

*Detecting re-registration (new email, same person):*

Users may create a new account with a different email to get another refund. Cross-reference identity using:

1. *Claimed profiles* — Query Trino for the profile(s) claimed by this user. If the same profile was previously claimed by another account that already received a refund, this is the same person.
   ```sql
   -- Find every account that claimed the same profile(s) as this user
   SELECT c.profileid, c.userid, u.email, u.createdat
   FROM postgresql_core.public.claiming c
   JOIN postgresql_core.public.users u ON u.id = c.userid
   WHERE c.profileid IN (
     SELECT profileid FROM postgresql_core.public.claiming WHERE userid = CURRENT_USER_ID
   )
   ORDER BY c.profileid, u.createdat;
   ```
   If multiple user IDs share the same claimed profile, check if any of those accounts have prior refunds in Stripe.

2. *Stripe fingerprinting* — Same payment method (card fingerprint) across different customer IDs:
   ```bash
   # Get payment methods for this customer
   stripe payment_methods list -d "customer=cus_XXX" -d "type=card"
   # Note the card fingerprint, then search for it across other customers
   ```

3. *Name + behavioral match* — Same name on Stripe customer records, similar product-activity patterns, same IP or device (if available in the activity user properties, `muso-analytics`).

If any cross-reference matches an account with a prior refund → *REFUND NOT ALLOWED (previous refund on linked account)*.

### 3. User Identity & Industry Profile

Build a complete picture of who this person is in the music industry.

**a) Muso.AI Account Details**

Prefer the typed path — it is schema-stable, the SQL is not:

```bash
muso users search 'USER_EMAIL' --env prod --json
```

That returns the full user record including `misc.countryCode`. Only drop to SQL if you
need to join against another table:

```sql
-- Full user record. NOTE: users has NO country/state/city/company/jobtitle columns —
-- the only location signal is misc.countryCode (captured from IP at signup).
SELECT u.id, u.email, u.firstname, u.lastname, u.fullname,
  u.createdat, u.updatedat, u.lastactivetime,
  u.phonenumber, u.stripecustomerid,
  json_extract_scalar(u.misc, '$.countryCode') AS country_code
FROM postgresql_core.public.users u
WHERE u.email = 'USER_EMAIL';

-- Did they claim a profile?
SELECT c.profileid, c.status, c.createdat as claim_date
FROM postgresql_core.public.claiming c
JOIN postgresql_core.public.users u ON u.id = c.userid
WHERE u.email = 'USER_EMAIL';
```

**b) Claimed Profile Details (if they claimed one)**
```sql
-- Get profile details from catalog
SELECT _id, name, legal_name, known_as_names, profile_type, profile_sub_type,
  popularity, rank, credits_count, collaborations_count,
  common_credits, country, city, about
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE _id = 'PROFILE_ID';
```

**c) Workspace & Team Context**
```sql
-- Are they part of an organization/workspace?
SELECT t.id as team_id, t.name as team_name, tu.roles
FROM postgresql_core.public.team_users tu
JOIN postgresql_core.public.teams t ON t.id = tu.teamid
JOIN postgresql_core.public.users u ON u.id = tu.userid
WHERE u.email = 'USER_EMAIL';
```

**d) Stripe Customer Metadata**
```bash
stripe customers list --email="USER_EMAIL"
```
Note: name, phone, address, metadata fields, created date.

**Capture and report:**
- Full name; location — profile `country`/`city`/`state` if they claimed one, otherwise the
  account's `misc.countryCode`. Job title and company are NOT held anywhere in Muso — do not
  report them, and do not infer them.
- Whether they claimed a profile — and if so: profile name, type (artist/professional/organization), popularity score, rank, credit count, genre, collaborators
- If they're a *known name* in music — popularity 70+ = noteworthy, 85+ = major figure
- Their role(s) in the industry: songwriter, producer, artist, label, publisher, etc.
- Workspace/team membership — are they an individual or part of a business?
- How long they've been on the platform (account age)
- Any "about" bio text from their profile

*This context matters for the refund decision:* a high-profile user who clearly gets value from Muso is different from someone who signed up by accident.

### 4. Subscription & Billing (Stripe)

```bash
# Find customer
stripe customers list --email="USER_EMAIL"

# Get subscriptions (include canceled)
stripe subscriptions list -d "customer=cus_XXX" -d "status=all"

# Payment history
stripe charges list -d "customer=cus_XXX" --limit 50

# Previous refunds
stripe refunds list -d "charge=ch_XXX"
```

Capture:
- Current subscription status (active / canceled / trialing)
- Plan name and price
- Account creation date (Stripe customer created)
- Total payments made and total amount paid
- Any previous refunds
- Cancellation date (if applicable)

### 5. Product Activity — KEY STEP

Our stack first (`muso-analytics` skill), Amplitude only for a window ours does not cover yet:

```bash
# Is the window covered? (events_view_covered_to / cutover_at)
bash /opt/hydra/scripts/muso-stack-read.sh coverage
# Find the user (Muso user id from step 1; the API does not search by email)
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/usersearch?user=USER_ID'
# Activity timeline, newest first (limit max 1000)
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/useractivity?user=USER_ID&limit=1000'
```

If the period since the subscription started ends after `events_view_covered_to`, or the
user is not found, ALSO read Amplitude while it is live (`muso-amplitude` skill:
`usersearch?user=USER_EMAIL`, then `useractivity?user=AMPLITUDE_ID&length=1000`) and name the
source of each fact in the report.

Capture:
- Last active date
- Total number of events / sessions
- Key actions performed (profile views, credit claims, searches, exports)
- Activity trend (increasing, decreasing, one-time, never used)

*Pay special attention to:*
- Analytics tile views (streaming stats, milestone tiles) — this is the main value users extract
- Pages visited — especially analytics/stats pages, profile pages, catalog pages
- Export or download actions
- Frequency and recency of engagement
- Whether activity is concentrated right after subscribing (grab-and-go pattern)

### 6. Trino Deep Dive (if needed)

Only query Trino if the product-activity data (our stack / Amplitude) is insufficient or the user is not found there.

```sql
-- Basic user info
SELECT id, email, createdat, updatedat FROM postgresql_core.public.users WHERE email = 'USER_EMAIL';

-- Team/workspace membership
SELECT * FROM postgresql_core.public.team_users WHERE userid = USER_ID;
```

### 7. Summary Report

Present the full investigation with all supporting data so the ops person can see exactly what you saw and make their own call. Give your recommendation, but always show your work.

Use bullet lists, not tables — this goes to Slack.


Report sections (use Slack bullet format, not tables):

*1️⃣ POLICY CHECK* — Prior refunds on this account + linked accounts (via claimed profile, card fingerprint, name match). Verdict: ✅ ELIGIBLE or ⛔ NOT ALLOWED.

*2️⃣ WHO IS THIS PERSON* — Name, location, account age, claimed profile (name, type, popularity, credits, roles), workspace/team, industry significance (🔴 Unknown / 🟡 Minor / 🟢 Notable / ⭐ Major).

*3️⃣ SUBSCRIPTION & BILLING* — Stripe customer ID, status, plan, total charges, charge details (last 5-10), subscription history (shows churn cycling).

*4️⃣ REPEAT OFFENDER* — Total subs, avg length, pattern flag, shortest sub.

*5️⃣ PRODUCT ACTIVITY* — (source: our stack / Amplitude) last active, events/sessions, key pages (analytics tiles, profiles, catalog), activity pattern and level (🔴 None / 🟠 Low / 🟡 Medium / 🟢 High).

*6️⃣ PRORATION* — Original charge, proration credits, live credit balance, and which SINGLE concession we are making (credit OR cash, never both). Never refund more than the live credit balance.

*7️⃣ CLIO'S TAKE* — 2-4 sentences, plain English. Recommendation: REFUND APPROVED ✅ / PARTIAL 🟡 / NOT RECOMMENDED 🟠 / NOT ALLOWED ⛔ + reason.

## Proration & Credit Balance Check (MANDATORY)

Before recommending a refund amount, ALWAYS check for prorations and account credits.

When a user switches plans (e.g. annual → monthly), Stripe automatically:
1. Prorates unused time on the old plan as a credit
2. Applies that credit toward the new plan's first charge
3. Leaves any remaining credit on the customer's balance

**A live credit balance is already a concession.** It is unused-time money we have
given back in product form, and it will silently pay the customer's next invoices
until it runs out. It is not a number that tells you what to refund — it is a
payment we have already made.

### ⛔ Never both: one unused period, one concession

**NEVER both a cash refund and a credit balance for the same unused period.**

A 2026-09-09 Stripe audit found 223 customers who got both: $4,827.65 of duplicate
concession, invisible for years because the credit quietly paid later invoices. The
exemplar is `re_3SacfBLsjTo3Ar3l1nCLgQ5C` — $107.50 refunded to the card on
2025-12-05, plus a $117.72 `invoice_too_small` credit that went on to pay nine
monthly invoices from January to September 2026. That customer used Pro for nine
months essentially free *and* got the cash back.

**The credit balance is NOT the correct refund amount. It is the amount that must be
zeroed FIRST if we are paying cash instead.**

### How to check:

```bash
# Live credit balance (NEGATIVE = credit we owe the customer; POSITIVE = they owe us)
stripe customers retrieve cus_XXX | jq '.balance'

# WHERE that balance came from — this is what tells you if it is a concession
stripe get /v1/customers/cus_XXX/balance_transactions -d "limit=100" \
  | jq '.data[] | {id,type,amount,ending_balance,invoice,created}'

# Recent invoices for proration line items
stripe invoices list -d "customer=cus_XXX" --limit 5
```

Reading the transaction types:
- `invoice_too_small` / `invoice_too_large` / `unapplied_from_invoice` / `credit_note`
  — Stripe minted this itself from a proration or an invoice correction. **This is a
  concession.**
- `adjustment` — a manual credit. If it carries no metadata it was typed in by hand
  (goodwill), and **that is also a concession**. If it carries metadata it is one of
  ours (referral reward, offer) and is unrelated to this charge's unused time.
- Anything at or behind a transaction whose `ending_balance` is `0` is already
  **spent**. We do not claw back spent credit; it reached the customer as service.

### Refund calculation:

*Refund only what the customer is actually out of pocket — and make sure they end up
with exactly ONE concession, not two.*

Same $120 annual → monthly switch, $106.73 of unused time:

| | Action | Result |
|---|---|---|
| ✅ | Leave the $106.73 credit on the account, pay no cash | **one** concession |
| ✅ | Zero the $106.73 credit **first**, then refund $106.73 to the card | **one** concession |
| ❌ | Refund $106.73 **and** leave the $106.73 credit live | **two** concessions — $213.46 for one unused period. This is the 223-customer bug. |
| ❌ | Refund the full $120 | wrong amount — they already consumed $12.50 of service |

So: **zero the credit balance BEFORE the cash refund**, and verify it landed:

```bash
# 1. zero it (amount is POSITIVE to debit the credit away)
bash /opt/hydra/scripts/muso-stripe-write.sh post "/v1/customers/cus_XXX/balance_transactions" \
  -d "amount=10673" -d "currency=usd" -d "description=zeroed before cash refund on ch_XXX"

# 2. VERIFY before going near the refund
bash -c 'source /opt/hydra/scripts/lib/stripe-credit.sh; customer_live_concession_amount cus_XXX'   # must print 0
# NOT `.balance == 0`: a customer may legitimately still hold a tagged referral
# or offer credit, so a NEGATIVE balance here is correct. Zeroing to 0 would
# claw back money that was never a duplicate concession.

# 3. only now the refund (muso-refund-processor Step 3)
```

**The money gate refuses `refunds create` while a live concession credit remains**, so
this is not advice you can skip — but do it in the right order rather than discovering
it from a REFUSED.

### In the report:

Always include a *Proration Analysis* section:
- Original charge amount
- Proration credits applied (with dates) and their transaction `type`
- Current live account credit balance, and whether it is spent or still live
- Net amount the user is actually out of pocket
- **Which single concession we are making**: leave the credit as-is, OR zero $X and
  refund $X. Never both.

## Recommendation Guidelines

- *None/minimal activity* + recent charge → Refund recommended
- *Low activity* + long-time customer → Partial refund or goodwill credit
- *High activity* + late cancellation → Refund not recommended (they used the product)
- *Repeat offender pattern* (multiple sub/cancel cycles) → Refund not recommended, flag abuse
- *Heavy analytics/tile usage* then cancel → Refund not recommended (they got what they came for)
- *Previous refunds* → Flag for review, generally not recommended
- *Very recent signup* (< 7 days) + no prior refund → Refund recommended regardless of activity
- *Prior refund exists* (this account or linked account) → REFUND NOT ALLOWED, full stop

Always present the data and recommendation — the final decision is the ops team's.
