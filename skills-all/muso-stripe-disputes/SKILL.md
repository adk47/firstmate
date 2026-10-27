---
name: muso-stripe-disputes
description: |
  Daily Stripe dispute monitoring, investigation, and evidence submission for Muso.AI.
  Handles the full lifecycle: detect new disputes, investigate user activity, build evidence,
  submit to Stripe, and post a daily summary to the operations channel.

  Use when: checking disputes, submitting dispute evidence, handling chargebacks,
  or running the daily dispute review.

  Triggers: "dispute", "chargeback", "dispute evidence", "fight dispute",
  "dispute summary", "daily disputes"
depends-on:
  - muso-stripe
  - muso-slack-formatter
compatibility: |
  Requires Stripe CLI with rak_dispute_read and rak_dispute_write, and Trino access
  via the muso CLI (`muso query`). Optional: product activity (`muso-analytics`).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Stripe Disputes Skill — Daily Dispute Handler

## Overview

Run daily to detect, investigate, and respond to Stripe disputes. Posts a single consolidated summary to the operations Slack channel.

## Operations Channel

Post daily summaries to: `#finance_muso` (C08GZPWAKBJ)

## Daily Workflow

### 1. Detect Open Disputes

```bash
# List all disputes needing response
stripe disputes list --limit 100 2>&1 | jq '[.data[] | select(.status == "needs_response") | {
  id, amount: (.amount/100), reason, 
  email: .evidence.customer_email_address,
  name: .evidence.customer_name,
  charge: .charge,
  due: (.evidence_details.due_by | todate),
  has_evidence: .evidence_details.has_evidence
}]'
```

**IMPORTANT: Submit evidence IMMEDIATELY when a dispute is detected. Do not wait for the due date. (Per Liza, Feb 26)**

Prioritize by:
1. Earliest due date (respond before deadline)
2. Largest amount (fight the big ones first)
3. Already-investigated disputes that just need submission

### 2. Investigate Each Dispute

For each dispute, gather evidence from all available sources:

#### a) Stripe — Billing & Subscription History
```bash
# Customer lookup
stripe customers list --email="USER_EMAIL"

# All subscriptions (including canceled)
stripe subscriptions list -d "customer=cus_XXX" -d "status=all" --limit 20

# Charge history
stripe charges list -d "customer=cus_XXX" --limit 20

# Previous refunds on this charge
stripe refunds list -d "charge=ch_XXX"

# Customer balance (check for proration credits)
stripe customers retrieve cus_XXX | jq '.balance'
```

#### b) Trino — User Activity & Profile Claims

Run on node-8 via the muso CLI (heredoc SQL; CSV with header row — prefer `--format json` when parsing):

```bash
# User lookup
muso query - <<'SQL'
SELECT id, email, createdat, updatedat
FROM postgresql_core.public.users
WHERE email = 'USER_EMAIL'
SQL

# Action log (shows every API call the user made)
muso query - <<'SQL'
SELECT createdat, route, requestmethod
FROM postgresql_core.public.user_action_log
WHERE userid = USER_ID
ORDER BY createdat DESC LIMIT 100
SQL

# Profile claims (also covers the user's claimed profiles)
muso query - <<'SQL'
SELECT id, status, profileid, profiletype, createdat
FROM postgresql_core.public.claiming
WHERE userid = USER_ID
SQL
```

#### c) Product Engagement (`muso-analytics`; Amplitude as fallback)
```bash
# Is the window covered by our stack? (events_view_covered_to / cutover_at)
bash /opt/hydra/scripts/muso-stack-read.sh coverage
# Search user by Muso user id (the API does not search by email)
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/usersearch?user=USER_ID'
# Activity timeline (newest first, limit max 1000)
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/useractivity?user=USER_ID&limit=1000'
```
While Amplitude is live and the dispute window ends after our coverage (or the user is
not found), also read it via the `muso-amplitude` skill (`usersearch?user=USER_EMAIL`, then
`useractivity?user=AMPLITUDE_ID&length=1000`). Evidence must name its source.

### 3. Build Evidence

For each dispute, build the strongest possible case based on what the data shows.

#### Evidence Strategy by Dispute Reason

*Fraudulent:*
- Lead with: login timestamps, IP address, billing address match, deliberate signup flow
- Key argument: "The cardholder created an account, provided personal details, and actively used the service — inconsistent with unauthorized access"

*Product Unacceptable:*
- Lead with: feature usage, session count, time spent, profile edits
- Key argument: "The customer actively engaged with the product over [X period], indicating the service met expectations"

*Subscription Canceled:*
- Lead with: cancellation was available self-service, customer didn't cancel before renewal
- Key argument: "Self-service cancellation was available at any time. The customer did not cancel before the billing date."

*Credit Not Processed:*
- Lead with: refund was never requested, or was processed as expected
- Key argument: "No refund was requested through our support channels prior to this dispute"

*Duplicate:*
- Lead with: each charge corresponds to a distinct billing period/service
- Key argument: "Each charge represents a separate billing period as shown in the invoice history"

#### Evidence Template

Always include these elements:

1. *Product Description:*
> Muso.AI is a music industry analytics platform providing verified streaming credits, career analytics, and profile management for artists and music professionals. Subscriptions provide access to premium analytics dashboards, streaming statistics, credit verification tools, and profile management.

2. *Terms of Service (https://credits.muso.ai/terms):*
> The customer agreed to Muso.AI's Terms of Service upon account registration. Key provisions:
> - Section 2.1: Electronic agreement constitutes the legal equivalent of a handwritten signature.
> - Section 2.4: The customer is solely responsible for all account activity including subscription purchases.
> - Section 3.1: Subscriptions are prepaid monthly in advance and the customer is "NOT entitled to a refund in the event of termination."
> - Section 4.2: The customer certified they are the authorized card user and "will not dispute these transactions with your bank."
> - Section 4.3: Fee disputes must be submitted in writing to Muso.AI within 10 days of the charge. Failure to do so waives the right to dispute. No such written notice was received from this customer.
> The customer filed a chargeback with their bank rather than following the dispute process outlined in the Terms they agreed to.

3. *Proof of Authorized Transaction:*
> [Customize based on investigation — signup flow, checkout attempts, billing address, IP, card details]

4. *Proof of Service Delivery:*
> [Customize — action log entries, feature usage, profile edits, analytics views, session data]

5. *Customer Activity Timeline:*
> [Chronological list of key actions from signup through disputed charge]

6. *Cancellation Availability:*
> Self-service cancellation was available at any time through the customer's billing dashboard. The customer [did not cancel until after filing the dispute / never canceled].

### 4. Submit Evidence to Stripe

```bash
# Submit evidence (requires rak_dispute_write permission)
stripe disputes update du_XXXXX \
  -d "evidence[product_description]=Muso.AI is a music industry analytics platform..." \
  -d "evidence[uncategorized_text]=FULL_EVIDENCE_TEXT" \
  -d "evidence[access_activity_log]=ACTIVITY_LOG" \
  -d "evidence[service_date]=YYYY-MM-DD" \
  -d "submit=true"
```

Evidence fields to populate:
- `product_description` — What Muso.AI is and what the subscription provides
- `access_activity_log` — Timestamped user actions from our backend logs
- `uncategorized_text` — The full narrative evidence (proof of authorization, service delivery, timeline)
- `service_date` — Date the disputed service was provided
- `cancellation_policy` — Link to or text of our ToS cancellation terms
- `cancellation_policy_disclosure` — How/when the customer was shown the policy
- `customer_purchase_ip` — Already auto-populated by Stripe

Note: `submit=true` finalizes the evidence — it can only be submitted once. Review carefully before submitting.

### 5. Daily Summary Format

Post ONE message per day to the operations channel with this format:

```
*🛡️ Daily Dispute Report — [Date]*

*Disputes Handled: [N]*

[For each dispute:]
━━━━━━━━━━━━━━━━━━━━━━━━
*[Name]* — $[amount] ([reason])
• Dispute: du_XXX
• Charge: [date] — [description]
• Evidence submitted: ✅ / ⏳ Pending investigation
• Strategy: [1-line summary of argument]
• Strength: 💪 Strong / 🤷 Moderate / 😬 Weak
━━━━━━━━━━━━━━━━━━━━━━━━

*Open Disputes Remaining: [N]*
*Total $ at Risk: $[amount]*
*Evidence Due Next: [date] ([name])*

*Wins/Losses This Month:* [W]-[L] ([win rate]%)
```

### 6. Verdict Guidelines

*FIGHT (submit evidence):*
- User has ANY login/action history after subscribing
- Multiple checkout attempts (shows deliberate intent)
- Profile edits, entity upserts, analytics views
- Subscribed for 2+ months before disputing
- US-issued card matching US billing address

*ACCEPT (don't fight):*
- Zero activity after signup (possible true fraud / card testing)
- Single charge, immediate dispute, no logins
- Foreign card with no matching user activity
- Very small amount where $15 dispute fee exceeds recovery

*BORDERLINE (fight but note weakness):*
- Minimal activity (1-2 sessions)
- Quick cancel after subscribing
- Legitimate product complaints in Intercom history

## Cron Setup

Add to HEARTBEAT.md or set up a dedicated daily cron:

```
# Daily at 9:00 AM PST
openclaw cron add --schedule "0 9 * * *" --task "Run the stripe-disputes skill: check all open Stripe disputes needing response, investigate each one, submit evidence for disputes worth fighting, and post a single daily summary to the operations channel. Include the ToS (https://credits.muso.ai/terms) in every evidence submission." --label "daily-dispute-handler"
```

## Tracking

Maintain a dispute tracker in the workspace for win/loss tracking:

File: `memory/dispute-tracker.json`
```json
{
  "disputes": {
    "du_XXX": {
      "customer": "email",
      "amount": 12.50,
      "reason": "fraudulent",
      "status": "evidence_submitted",
      "submitted_date": "2026-02-23",
      "outcome": null,
      "notes": "Strong case — 6 checkout attempts, 3 months active"
    }
  },
  "monthly_stats": {
    "2026-02": { "submitted": 0, "won": 0, "lost": 0 }
  }
}
```

## Important Notes

- *Stripe permissions required:* `rak_dispute_read` and `rak_dispute_write` on the restricted API key — ✅ CONFIRMED: both permissions are active on our key as of Feb 26, 2026
- *ToS inclusion:* Always reference https://credits.muso.ai/terms in evidence (per Liza's suggestion)
- *One submission per dispute:* Evidence can only be submitted once — review before submitting with `submit=true`
- *$15 dispute fee:* Stripe charges $15 per dispute regardless of outcome. Factor this into fight/accept decisions.
- *Trino queries:* run via `muso query - <<'SQL'` heredocs (see `muso-query-writer`). Keep queries filtered by userid.
