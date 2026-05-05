# SOP — Rewardful Affiliate Fraud Detection

**Owner:** Finance (Liza Basco)
**Created:** 2026-05-04
**Source:** Derived from live audits on 2026-05-04 of 16 affiliates from the PayPal payout batch — 13 legit, 2 fraud (Ahmed Ibrahim / Maximilian Larson), 1 identity-verification hold (Veronica Earnhart / Ramazan Pakir).
**Audience:** Finance, Ops, CMO — anyone reviewing Rewardful affiliates before commission approval.

---

## When to run this SOP

Trigger an audit before any of the following:

1. **First payout** for any affiliate (before first `state=paid` commissions are released).
2. **Outlier affiliates** — any affiliate whose conversions in a 30-day window exceed 10, OR whose gross revenue exceeds $1,000, whichever is first.
3. **Any manual flag** from Finance, CMO, or Ops (e.g., commission looks off, Stripe disputes spike, customer complaints).
4. **Quarterly review** — sample the top 10 affiliates by paid commissions each quarter.

---

## Step-by-step audit procedure

### Step 1 — Pull affiliate profile from Rewardful

```bash
curl -s -u "$REWARDFUL_API_SECRET:" \
  "https://api.getrewardful.com/v1/affiliates/{AFFILIATE_ID}?expand[]=campaign" | jq .
```

Record:
- `email`, `paypal_email` (flag if the two don't share any common pattern)
- `created_at`, `sign_in_count`
- `visitors` / `leads` / `conversions` (compute conversion rate; healthy = 1–10%)
- `commission_stats.currencies.USD` (paid vs. unpaid vs. gross_revenue)

### Step 2 — Pull all converted referrals

```bash
curl -s -u "$REWARDFUL_API_SECRET:" \
  "https://api.getrewardful.com/v1/referrals?affiliate_id={AFFILIATE_ID}&conversion_state=conversion&limit=100" \
  | jq '.data[] | {became_conversion_at, stripe_customer_id, customer}'
```

Record: customer name, email, Stripe customer ID, conversion timing.

### Step 3 — Stripe aggregate check per customer

For each `stripe_customer_id`:
- Successful charges count + sum
- Failed charges count
- Refund count
- Dispute count
- Subscription statuses (active / canceled / past_due / incomplete_expired)

Compute totals across the full cohort.

### Step 4 — Resolve emails → Muso `user_id` (ask @CTO)

Send to `agent:cto:main` via `sessions_send`:

> Map these emails → user_id, created_at, last_login_at, country from core-backend `users`.

### Step 5 — Amplitude activity check (ask @CMO)

Send to `agent:cmo:main` via `sessions_send` with the resolved user_ids. Request:

- Lifetime events + sessions per user
- Last seen
- Top 5 event types
- Platform (iOS / Web / Android)
- Country
- Verdict: active user / moderate / signup-only / ghost

### Step 6 — Evaluate against the rubric below

---

## Fraud detection rubric

Evaluate each signal. **2 or more 🚩 Fraud hits = block payout, open investigation.** 1 hit = follow up / manual review.

| # | Signal | ✅ Legitimate | 🚩 Fraud |
|---|---|---|---|
| 1 | Country diversity across referrals | 5+ countries across continents | Single country (or single country + VPN outlier) |
| 2 | Median lifetime Amplitude events per referred user | 500+ | Under 150 |
| 3 | Median lifetime sessions | 20+ | Under 10 |
| 4 | Top Amplitude event types | `analytics_view`, `credits_view`, `profile_view`, `audit_view`, `home_view` | Only `payment_view`, `subscription_intent`, `billing_view`, `sign_up_view` |
| 5 | Platform mix | iOS + Web + Android | Single platform |
| 6 | Customer name patterns | Real, diverse names | Gibberish (`Ncjk`, `hfsr`, `shlh`), shared first-initial sequences |
| 7 | Customer email patterns | Real names, personal domains | `+tag` Gmail aliasing, especially shared base inbox (e.g., two `tinytmp+*@gmail.com`) |
| 8 | Subscription tail in Stripe | Multiple successful renewals (5+ per customer common) | Signup + 1 successful charge + all subsequent failed |
| 9 | Profile streams on Muso | Non-zero, often millions for real artists/producers | Zero |
| 10 | Plan selection | Mix of tiers (often Lite-heavy) | Concentrated on high-commission Pro/Business Graduated tiers |
| 11 | Affiliate's own Muso account | Real product user with event history | No user row, or ghost account with near-zero events |
| 12 | Affiliate's PayPal email vs. signup email | Same domain or clearly same identity | Different identity, especially with letter-scrambled names (e.g., `anamodyhiba@` ↔ `mo0odyhebah@` among referrals) |
| 13 | Conversion timing | Natural spread (hours / days between visit → lead → conversion) | Visit → lead → conversion within minutes, repeatedly |
| 14 | Dispute rate on referred customers | <1% | Any disputes at all on brand-new cohorts (*exception:* ad-agency affiliates — see rule 16) |
| 15 | **Affiliate identity check** — registration name ↔ payout email | Names clearly match the same person (John Smith → johnsmith@, or company → company domain) | Registration name and payout email point to completely different people (e.g., "Veronica Earnhart" registered with `ramazanpakir@googlemail.com`); letter-scrambled or swapped identities |
| 16 | **Self-referral check** | Affiliate's own Muso account (if any) is NOT one of their referred customers; affiliate's name, email, PayPal, and payment method do not match any referred customer | Affiliate is earning commission on their own subscription (same name / same contact info / same card fingerprint as a referral) |

---

## Affiliate categories (calibrate rubric by type)

Different affiliate archetypes show different baseline patterns. Weight the rubric accordingly.

| Category | Signature | Expected pattern | Calibration note |
|---|---|---|---|
| **Organic music-industry referrer** (producer, studio, DJ) | Personal gmail, own Muso account, small-medium volume | 1–60 conversions, 5+ countries, diverse plans, real music producers | Default rubric applies |
| **Paid-media / ad-agency** (demand.io, unbrokenads.com, tenereteam.com, onads.io, any `*ads.*` TLD) | Business domain email, no personal Muso account | Higher volume, huge stream counts per referred user, slightly elevated dispute/refund rate (users less pre-qualified) | Dispute rate up to ~5% is *not* fraud — it's ad-driven acquisition friction. Do NOT clawback on isolated disputes when the referred user is a real heavy Muso user. |
| **Community content creator** (YouTube/TikTok/Twitch) | Creator handle in email, moderate visitor-to-lead conversion | Often single-country-skewed (their audience), moderate engagement | Single-country concentration is expected — watch *volume* spikes, not geography |
| **Self-referral / identity-fraud** (Ahmed, Max, Veronica) | One of: affiliate has no product usage, affiliate referred self, registration ↔ payout identity mismatch | See fraud signatures in rubric | Always block payout and escalate |

---

## Three-audit baseline reference

Use these numbers as calibration when reviewing new affiliates:

| Metric | Ahmed (fraud) | Rhys (legit) | Bao (legit) |
|---|---:|---:|---:|
| Conversions | 9 | 12 | 60 |
| Countries | 1 (Yemen) + 1 VPN | 8 | 29 |
| Median events / user | 67 | 1,401 | 1,958 |
| Min / max events | 18 / 131 | 434 / 3,929 | 117 / 18,899 |
| Total Stripe collected | ~$200 | ~$700 | $8,263 |
| Disputes | 0 yet (all subs dying) | 0 | 0 |
| Commissions paid out | $0 | $102.28 | $1,265.48 |
| Verdict | 🚩 Fraud | ✅ Legit | ✅ Legit star |

### 2026-05-04 full payout batch outcomes (16 affiliates audited)

- **13 legit and paid:** Rhys Zacher, Bao Tran Hoai, Hoang Hien, Amir Sohail, Paulines Pencer, Felix Ann, Chang Beethy, Jonny Dang, Anthony Orozco, Hector Jon, Jimmy Doheny (star), Michael Ambrose (unbrokenads), Tenere Team (tenereteam/onads)
- **2 fraud:** Ahmed Ibrahim (Yemen ring — 11 fake accounts), Maximilian Larson (self-referral — referring his own Muso subscription)
- **1 identity hold:** Veronica Earnhart / Ramazan Pakir (registration name ≠ payout email identity)
- **Watch-list:** Anthony Orozco (100% US concentration — flag if volume spikes), Chang Beethy (affiliate VN / referral TR mismatch, customer is real so no action)

**Monetary impact:** $95.82 commissions voided (Ahmed), $24 commissions clawback requested (Max), $5 commission held (Veronica). $1,300+ paid cleanly to the 13 legit affiliates.

---

## Action matrix

| Scenario | Action |
|---|---|
| 0–1 🚩 fraud signals | ✅ Approve commission release. No action. |
| 2–3 🚩 fraud signals | ⚠️ Manual review. Escalate to Liza + Aaron before next payout. Hold pending commissions. |
| 4+ 🚩 fraud signals | 🚫 Deactivate affiliate in Rewardful. Void all unpaid commissions. Cancel referred subscriptions. Block signup emails from re-registration. Document case in `reports/fraud-affiliate-<date>-<id>.md`. |

**Never auto-refund existing paid commissions without Aaron's explicit approval** — commission clawbacks on paid amounts require written sign-off.

---

## Proactive guardrails (proposed — requires CTO/Aaron sign-off)

1. **Pre-payout auto-check** on Rewardful commission approval: run Step 3 + Step 5 of this SOP and flag any affiliate whose cohort fails 2+ rubric signals before the commission transitions `due → paid`.
2. **Tier-based approval gates**: any commission on a `Business Graduated` or `Pro Graduated` conversion requires a manual approval checkbox in the payout flow (these are the tiers fraud rings optimize for).
3. **Email-pattern detector** at signup: flag accounts whose email normalizes to a base inbox already associated with another Muso account (Gmail `+tag` aliasing, dots stripped).
4. **Country concentration alert**: if an affiliate's referrals are 80%+ from a single non-US/EU country, trigger Step 5 automatically.
5. **Subscription mortality monitor**: track % of first-charge-succeeds-then-all-fail across each affiliate's cohort; spike → alert.

---

## Appendix: Ahmed Ibrahim case file (reference for pattern-matching)

- Rewardful ID: `a1d8308a-a4d0-40c5-8bd9-ef2f76bd75a3`
- Signup email: `himoly77@gmail.com` (no Muso user row)
- PayPal email: `anamodyhiba@gmail.com` (no Muso user row, letter-scrambled against a referral email `mo0odyhebah@gmail.com`)
- 9 conversions, 10/11 accounts in Yemen, all `+tag` throwaway-style emails
- Product usage: 100% billing-only events, zero `analytics_view` / `profile_view` / `credits_view`
- Plan selection: 7/11 on Business/Pro Graduated tiers
- Outcome: affiliate + 11 referred Muso accounts flagged for deactivation, $95.82 pending commissions voided

Full audit preserved in Slack #finance_muso thread 2026-05-04.

---

## Appendix: Maximilian Larson — self-referral case file

- Rewardful ID: `6777788b-b154-4bbe-a70b-8b7288f7178f`
- Registered affiliate: `max@rightstune.com` (Maximilian Larson)
- Only conversion: `max1millionsproductions@gmail.com` (Muso user 254309, *Maximilian Larson*)
- Real heavy Muso user (5,762 events, 246M streams) — so fraud signature is *not* synthetic accounts like Ahmed. Fraud is that he is earning commission on his own $30/mo Business subscription (3 paid renewals = $24 commission to himself).
- Detection rule: always cross-check affiliate name / email / contact info against referred customer records (rubric rule 16).
- Outcome: commission clawback + affiliate ban (Muso subscription itself remains active — he is a real customer, just not eligible as an affiliate).

---

## Appendix: Veronica Earnhart / Ramazan Pakir — identity mismatch case file

- Rewardful ID: `6f49ad7e-b316-4d95-9dc2-49433dd5b2bb`
- Registered affiliate name: "VERONICA MICHELLE EARNHART"
- Signup + PayPal email: `ramazanpakir@googlemail.com` (Turkish name Ramazan Pakır)
- 1 referral (Jason Rochester, `rochestertransfers@gmail.com`) — *real* Canadian artist, 5.7M streams, 327 events. Customer side is clean.
- Issue is affiliate-side: registration identity does not match payout identity. Possible account takeover, purchased account, or fake KYC.
- Detection rule: rubric rule 15 — always require registration name ↔ payout email plausibility check before first commission release.
- Outcome: commission held ($5) pending Rewardful identity verification.
