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

> A **DENIED** on the one-time / daily-limit policy is not automatically final: if the
> requester is on the god-mode allowlist, it becomes an interactive override offer rather than
> a flat no — see Step 3 "If DENIED".

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
report it as done, do not invent an approval/ticket — say it couldn't complete and
@-mention Nick (`U0AL36NADEY`), per the operations honesty rules.

After execution, verify:
```bash
stripe refunds retrieve re_XXX
```

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

# Append to monthly log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] | DECISION | email | cus_XXX | ch_XXX | $AMOUNT | REASON" >> memory/refund-log/$(date +%Y-%m).log

# For an authorized override, record WHO waived the policy and the approval message ts:
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] | OVERRIDE | email | cus_XXX | ch_XXX | $AMOUNT | one-time policy waived by <approver> (msg <approval_msg_id>)" >> memory/refund-log/$(date +%Y-%m).log
```

## Safety Rails

1. **Maximum single refund: $500.** If the refund amount exceeds $500, do NOT execute — report the recommendation and tag Aaron for approval.
2. **Maximum daily refunds: 5.** Check today's log count before executing. If at limit, queue and report.
3. **One-time refund policy.** A prior refund (this account or a linked account) blocks an automatic repeat. A non-allowlisted requester cannot waive it (DENY). An allowlisted requester (Aaron / Jan / Nick) may waive it **only** through the explicit interactive confirm + override token in Step 3 — never silently, never on a fabricated confirmation. The money gate (`muso-stripe-write.sh`) enforces this independently.
4. **Always show your work.** Never refund without posting the full investigation report first.
5. **Partial over full.** When in doubt between full and partial, prefer partial — it's fairer to both sides.
6. **Log everything.** Every decision gets logged, approved or denied.

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
