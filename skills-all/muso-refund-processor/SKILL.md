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
  - muso-analytics
  - muso-amplitude
  - muso-slack-formatter
compatibility: |
  Requires muso-refund-investigation, muso-stripe, muso-analytics (muso-amplitude as fallback until the Amplitude cutover), muso-slack-formatter. WRITE access to Stripe.
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
| **APPROVED — Partial Refund** | No prior refunds + some activity but clear overpayment (cash the customer is actually out of pocket) |
| **DENIED** | Prior refund exists (one-time policy), repeat offender, heavy usage, or value clearly extracted |

> A **DENIED** on the one-time / daily-limit policy is not automatically final: if the
> requester is on the god-mode allowlist, it becomes an interactive override offer rather than
> a flat no — see Step 3 "If DENIED".

#### Partial Refund Logic

Partial refunds are the preferred path when:
- User has a **live credit balance** from proration — that credit already IS the
  concession. Do NOT add cash on top of it. If the requester wants cash instead, zero
  the credit first (Step 3, "Credit-balance disposition"), then refund that amount.
- User had **some but limited** usage — refund prorated unused portion
- User is within **7 days** of charge but did use the product lightly — refund minus a fair-use deduction

Calculate partial amounts based on:
1. **Credit balance** (`stripe customers retrieve cus_XXX | jq '.balance'`) — if negative, that is a concession we have ALREADY made. It is a ceiling on any cash conversion, never an amount to hand out on top.
2. **Days used** — prorate: `refund = charge × (remaining_days / total_days)`
3. **Never refund more than the original charge minus any value already received**

Partial/proration refunds usually mean the customer KEEPS their subscription — that
requires the Step 3 keep waiver from an allowlisted requester, or canceling anyway.

### Step 3: Execute

#### Subscription disposition — BEFORE any refund of a subscription charge

A completed refund must leave no paid access (Aaron, #operations 2026-07-02). Before
refunding a charge that paid for a subscription:

1. List the customer's subscriptions, all states:
   ```bash
   stripe subscriptions list -d "customer=cus_XXX" -d "status=all" --limit 100
   ```
2. If any is active-like (`active`, `trialing`, `past_due`, `unpaid` — including
   `cancel_at_period_end=true`, which still grants access until period end), cancel it
   through the gate and verify:
   ```bash
   bash /opt/hydra/scripts/muso-stripe-write.sh subscriptions cancel sub_XXX --confirm
   stripe subscriptions retrieve sub_XXX   # must show status=canceled
   ```
3. **Keep exception** — the requester explicitly wants the user to keep the
   subscription (goodwill month-refund, partial/proration correction): only an
   allowlisted requester (Aaron/Jan/Nick) can waive, captured from their in-thread ask,
   by passing `--keep-subscription-confirmed-by <slack_id> --approval-msg-id <ts>` on
   the refund command. Never assume "keep" silently. A non-allowlisted requester cannot
   waive it — they may ask an allowlisted requester to, or the subscription gets
   canceled. The keep waiver does NOT waive the one-time refund policy (a repeat refund
   still needs its own `--override-confirmed-by`); when both waivers apply,
   `--approval-msg-id` is shared, so point it at a message covering both approvals.

The money gate enforces this below you: `refunds create` on a subscription charge
REFUSES while an active-like subscription remains, unless the keep waiver is passed.
One-off charges (plaques, merch) are exempt — do not cancel a subscription over a
non-subscription refund. If a subscription cannot be canceled or verified, the refund
workflow is NOT complete: say so plainly and @-mention Nick (`U0AL36NADEY`).

#### Credit-balance disposition — AFTER cancelling, BEFORE any refund

Order matters, and it is this way round for a reason: **cancelling a subscription is
often what MINTS the proration credit.** Read the balance after the cancel, never
before, or you will clear a credit that the cancel then re-creates.

A live credit balance is a concession we have already made. Cash on top of it pays the
same unused period twice — the 2026-09-09 audit found 223 customers in exactly that
state, $4,827.65, because the credit silently paid their later invoices.

1. Read the balance AND where it came from:
   ```bash
   stripe customers retrieve cus_XXX | jq '.balance'    # negative = live credit
   stripe get /v1/customers/cus_XXX/balance_transactions -d "limit=100" \
     | jq '.data[] | {id,type,amount,ending_balance}'
   ```
   Credit at or behind an `ending_balance: 0` is already spent — leave it alone.
   `adjustment` rows carrying metadata are ours (referral/offer), not this charge's
   unused time.
2. If a live concession credit remains, **zero the credit balance BEFORE the cash
   refund** (positive amount debits it away), then VERIFY:
   ```bash
   bash /opt/hydra/scripts/muso-stripe-write.sh post "/v1/customers/cus_XXX/balance_transactions" \
     -d "amount=AMOUNT_IN_CENTS" -d "currency=usd" -d "description=zeroed before cash refund on ch_XXX"
   bash -c 'source /opt/hydra/scripts/lib/stripe-credit.sh; customer_live_concession_amount cus_XXX'   # must print 0
   # NOT `.balance == 0`: a customer may legitimately still hold a tagged referral
   # or offer credit, so a NEGATIVE balance here is correct. Zeroing to 0 would
   # claw back money that was never a duplicate concession.
   ```
3. **Keep-credit exception** — the requester deliberately wants the customer to have
   BOTH the credit and the cash. Rare, and it is a double concession by definition, so
   only an allowlisted requester (Aaron/Jan/Nick) can waive it, captured from their
   in-thread ask, by passing `--keep-credit-confirmed-by <slack_id> --approval-msg-id <ts>`.
   Never assume "keep" silently. This waiver does NOT waive the one-time refund policy
   or the subscription-cancel rule; each wall needs its own token.

The money gate enforces this below you: `refunds create` REFUSES while a live
concession credit remains, unless the keep-credit waiver is passed.

#### If APPROVED (full or partial):

Execute refund writes through the **`muso-stripe-write.sh` gate**, NOT `stripe`
directly. The gate refuses to move money while the codex model is degraded onto a
weak fallback (you cannot perceive that state yourself), failing closed:

```bash
# Full refund on a charge
bash /opt/hydra/scripts/muso-stripe-write.sh refunds create -d "charge=ch_XXX" -d "reason=requested_by_customer" --confirm

# Partial refund (amount in cents)
bash /opt/hydra/scripts/muso-stripe-write.sh refunds create -d "charge=ch_XXX" -d "amount=AMOUNT_IN_CENTS" -d "reason=requested_by_customer" --confirm
```

ALWAYS use `--confirm` to skip the interactive prompt.

If the gate exits non-zero with `REFUSED`, the refund did **not** happen: do not
report it as done, do not invent an approval/ticket. If the refusal is the
active-subscription wall, that's self-recoverable — cancel the subscription (or get
the keep waiver), verify, and retry. For any other refusal, say it couldn't complete
and @-mention Nick (`U0AL36NADEY`), per the operations honesty rules.

After execution, verify:
```bash
stripe refunds retrieve re_XXX
```

If the gate prints **`POST-REFUND-CREDIT-LIVE`**, the refund **DID** happen — do NOT
re-run it. Stripe minted a proration credit during the refund itself (it did not exist
when the gate checked), so the customer now holds both. Zero the credit it names using
the command in that message, verify the live CONCESSION is 0 (not the balance —
a tagged referral or offer credit may legitimately remain, and clawing that back
is the mixed-balance error this whole section exists to prevent), and report both
actions.
`POST-REFUND-CREDIT-UNVERIFIED` means the same "refund succeeded, do not re-run" but the
follow-up read failed — check the balance by hand.

#### If OVERRIDE-confirmed (an allowlisted requester waived a soft wall):

Same execution path as APPROVED, but pass the override token so the money gate allows the
repeat refund and the waiver is attributable:

```bash
bash /opt/hydra/scripts/muso-stripe-write.sh refunds create \
  -d "charge=ch_XXX" -d "reason=requested_by_customer" --confirm \
  --override-confirmed-by <approver_slack_id> --approval-msg-id <ts_of_their_yes>
```

`--override-confirmed-by` is the Slack id of the allowlisted requester who said yes;
`--approval-msg-id` is the timestamp of that "yes" message. The gate refuses the override if a
prior refund exists and the approver is missing or not on the allowlist — so you can never move
money on a fabricated confirmation. Then log an **OVERRIDE** row (Step 5).

#### If DENIED:

Do not execute any refund yet. First classify the blocker:

- **Soft wall** — the *one-time / prior-refund* policy or the *daily-5 throttle*. These are
  limits an authorized person may waive.
- **Hard wall** — a single refund *over $500*, or a *legal-action / chargeback* threat. These
  need Aaron specifically.

**Soft wall + the requester is on the god-mode allowlist** (Aaron `U7RP6HKUZ` / Jan
`U038BM16T7W` / Nick `U0AL36NADEY`): do NOT silently deny and do NOT fabricate. Name the exact
blocker and ask whether to override, then STOP and wait — you will see their reply in the
thread on your next turn:

> Before I run this: standard policy would block it — `<email>` already has `<N>` prior
> refund(s), and the one-time-refund rule normally stops a repeat. You're authorized to waive
> that, so I can refund anyway. Go ahead and refund `<amount>` on `ch_XXX`? Reply *yes* to
> confirm, or *no* to hold.

(daily-limit variant: "we've already hit today's refund limit (`<M>`/5). You can authorize an
extra one. Refund `<amount>` on `ch_XXX` anyway? (yes / no)")

- Explicit **yes** from that same allowlisted requester → run the OVERRIDE execution above and
  report the `re_...` id.
- **no** / silence → no refund ("Got it — holding off, no refund issued.").
- A follow-up question → answer it, then re-offer.

**Soft wall + a NON-allowlisted requester:** the one-time policy stands — post the denial
template below. They cannot waive it; they may ask an allowlisted requester to.

**Hard wall (any requester):** you cannot self-authorize. Offer to flag Aaron, and on yes use
the `report-to-aaron` skill to ACTUALLY post a `<@U7RP6HKUZ>` message:

> I can't process this one myself — `<amount>` is over the $500 single-refund limit (or: this
> looks like a chargeback/legal-threat case), which needs Aaron specifically. Want me to flag
> it to him directly?

Never invent an "exception request", a "hold for Aaron approval", or an escalation you did not
actually perform (operations Honesty rules).

### Step 4: Report

Post the full investigation report to the channel, then append the action taken:

**If refunded:**
> ✅ *Refund Executed*
> • Refund ID: `re_XXX`
> • Amount: $XX.XX
> • Type: Full / Partial
> • Charge: `ch_XXX`
> • Customer: `cus_XXX` (email)
> • Subscription: canceled `sub_XXX` / kept (waived by <who>, msg <ts>) / n/a (one-off charge)
> • Credit balance: zeroed $X.XX (`cbtxn_XXX`) / none / kept (waived by <who>, msg <ts>)
> • Reason: [brief explanation]

**If denied:**
> ⛔ *Refund Denied*
> • Customer: `cus_XXX` (email)
> • Reason: [detailed explanation citing policy]
> • Note: Final for a non-allowlisted requester. An allowlisted requester (Aaron/Jan/Nick) can waive a soft wall via the Step 3 override; one-time-policy blocks are not Aaron-escalations.

### Step 5: Log

After every refund decision (approved or denied), append a record to the refund log:

```bash
# Create log dir if needed
mkdir -p memory/refund-log

# Append to monthly log — always include the subscription AND credit-balance disposition
# (subscription_canceled=sub_XXX, or subscription_kept=sub_XXX waived by <who>, or subscription=n/a one-off charge;
#  credit_zeroed=$X, or credit_kept=$X waived by <who>, or credit=none):
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] | DECISION | email | cus_XXX | ch_XXX | $AMOUNT | REASON | subscription_canceled=sub_XXX | credit_zeroed=$X" >> memory/refund-log/$(date +%Y-%m).log

# For an authorized override, record WHO waived the policy and the approval message ts:
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] | OVERRIDE | email | cus_XXX | ch_XXX | $AMOUNT | one-time policy waived by <approver> (msg <approval_msg_id>) | subscription_canceled=sub_XXX" >> memory/refund-log/$(date +%Y-%m).log

# For an authorized KEEP (subscription intentionally left active):
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] | DECISION | email | cus_XXX | ch_XXX | $AMOUNT | REASON | subscription_kept=sub_XXX waived by <approver> (msg <approval_msg_id>)" >> memory/refund-log/$(date +%Y-%m).log
```

## Safety Rails

1. **Maximum single refund: $500.** If the refund amount exceeds $500, do NOT execute — report the recommendation and tag Aaron for approval.
2. **Maximum daily refunds: 5.** Check today's log count before executing. If at limit, queue and report.
3. **One-time refund policy.** A prior refund (this account or a linked account) blocks an automatic repeat. A non-allowlisted requester cannot waive it (DENY). An allowlisted requester (Aaron / Jan / Nick) may waive it **only** through the explicit interactive confirm + override token in Step 3 — never silently, never on a fabricated confirmation. The money gate (`muso-stripe-write.sh`) enforces this independently.
4. **Always show your work.** Never refund without posting the full investigation report first.
5. **Partial over full.** When in doubt between full and partial, prefer partial — it's fairer to both sides.
6. **No paid access after refund.** A refunded subscription charge must leave no
   active-like Pro/Business/team subscription on the customer — cancel and verify BEFORE
   the refund (see Step 3 "Subscription disposition"). An intentional keep needs the
   attributable allowlisted waiver. The money gate (`muso-stripe-write.sh`) enforces this
   independently.
7. **Log everything.** Every decision gets logged, approved or denied, including the
   subscription disposition (`subscription_canceled=sub_XXX`, or kept-by-waiver, or n/a)
   and the credit disposition (`credit_zeroed=$X`, or kept-by-waiver, or none).
8. **No cash refund on top of a live credit.** One unused period, one concession. A live
   concession credit (negative `customer.balance` from `invoice_too_small`,
   `invoice_too_large`, `unapplied_from_invoice`, `credit_note`, or an untagged
   `adjustment`) must be zeroed and VERIFIED at 0 before any cash refund. A deliberate
   both needs `--keep-credit-confirmed-by` from an allowlisted requester. The money gate
   enforces this independently. **The highest-risk case is a kept subscription**: the
   customer stays on the plan, so a leftover credit silently pays their next invoices —
   which is exactly how 223 customers went unnoticed for years.

## Escalation

Escalate to Aaron (do not auto-process) when:
- Refund amount > $500
- Customer is threatening legal action or chargeback
- Edge case not clearly covered by guidelines
- You're genuinely uncertain

A one-time-policy block is **not** on this Aaron-escalation list. For a non-allowlisted
requester it is an outright DENY; for an allowlisted requester it is handled by the
interactive override in Step 3 ("If DENIED"), not by escalating to Aaron. The hard walls above
(>$500, legal / chargeback) DO need Aaron. Either way, "escalate to Aaron" means actually
posting a `<@U7RP6HKUZ>` message via `report-to-aaron`, never a free-text claim that you
escalated.
