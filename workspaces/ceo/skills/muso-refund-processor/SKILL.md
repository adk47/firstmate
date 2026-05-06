---
name: muso-refund-processor
description: |
  End-to-end refund handling for Muso.AI: investigate, decide, and execute refunds (full or partial) via Stripe.
  Combines the refund-investigation workflow with actual refund execution authority.

  Use when: an ops team member asks to process a refund, evaluate a refund request,
  or when triggered in the #operations channel with any refund-related request.

  Triggers: "refund", "process refund", "refund request", "can we refund", "partial refund",
  "should we refund", "refund this user", "cancel and refund"

  IMPORTANT: This skill has WRITE access to Stripe (creates refunds). All refunds are logged.
depends-on:
  - muso-refund-investigation
  - muso-stripe
  - muso-amplitude
  - muso-slack-formatter
compatibility: |
  Requires muso-refund-investigation, muso-stripe, muso-amplitude, muso-slack-formatter. WRITE access to Stripe.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Refund Processor Skill

Autonomous refund handling: investigate → decide → execute → report.

## Workflow

### Step 1: Investigation

Run the full refund-investigation checklist (see that skill). Produce the standard investigation report.

### Step 2: Decision

Based on investigation results, make one of these decisions:

| Decision | When |
|---|---|
| **APPROVED — Full Refund** | No prior refunds + minimal/no activity + recent charge |
| **APPROVED — Partial Refund** | No prior refunds + some activity but clear overpayment (proration credit balance) |
| **DENIED** | Prior refund exists (one-time policy), repeat offender, heavy usage, or value clearly extracted |

#### Partial Refund Logic

Partial refunds are the preferred path when:
- User has a **credit balance** on their Stripe account from proration (refund the credit balance, not the original charge)
- User had **some but limited** usage — refund prorated unused portion
- User is within **7 days** of charge but did use the product lightly — refund minus a fair-use deduction

Calculate partial amounts based on:
1. **Credit balance** (`stripe customers retrieve cus_XXX | jq '.balance'`) — if negative, that's owed to the customer
2. **Days used** — prorate: `refund = charge × (remaining_days / total_days)`
3. **Never refund more than the original charge minus any value already received**

### Step 3: Execute

#### If APPROVED (full or partial):

```bash
# Full refund on a charge
stripe refunds create -d "charge=ch_XXX" -d "reason=requested_by_customer" --confirm

# Partial refund (amount in cents)
stripe refunds create -d "charge=ch_XXX" -d "amount=AMOUNT_IN_CENTS" -d "reason=requested_by_customer" --confirm
```

ALWAYS use `--confirm` to skip the interactive prompt.

After execution, verify:
```bash
stripe refunds retrieve re_XXX
```

#### If DENIED:

Do not execute any refund. Report the denial with clear reasoning.

### Step 4: Report

Post the full investigation report to the channel, then append the action taken:

**If refunded:**
> ✅ *Refund Executed*
> • Refund ID: `re_XXX`
> • Amount: $XX.XX
> • Type: Full / Partial
> • Charge: `ch_XXX`
> • Customer: `cus_XXX` (email)
> • Reason: [brief explanation]

**If denied:**
> ⛔ *Refund Denied*
> • Customer: `cus_XXX` (email)
> • Reason: [detailed explanation citing policy]
> • Note: This decision is final per policy. If the customer disputes, escalate to Aaron.

### Step 5: Log

After every refund decision (approved or denied), append a record to the refund log:

```bash
# Create log dir if needed
mkdir -p memory/refund-log

# Append to monthly log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] | DECISION | email | cus_XXX | ch_XXX | $AMOUNT | REASON" >> memory/refund-log/$(date +%Y-%m).log
```

## Safety Rails

1. **Maximum single refund: $500.** If the refund amount exceeds $500, do NOT execute — report the recommendation and tag Aaron for approval.
2. **Maximum daily refunds: 5.** Check today's log count before executing. If at limit, queue and report.
3. **One-time refund policy is absolute.** If any linked account has a prior refund, DENY. No exceptions.
4. **Always show your work.** Never refund without posting the full investigation report first.
5. **Partial over full.** When in doubt between full and partial, prefer partial — it's fairer to both sides.
6. **Log everything.** Every decision gets logged, approved or denied.

## Escalation

Escalate to Aaron (do not auto-process) when:
- Refund amount > $500
- Customer is threatening legal action or chargeback
- Edge case not clearly covered by guidelines
- You're genuinely uncertain
