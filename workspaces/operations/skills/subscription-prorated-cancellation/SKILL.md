---
name: "subscription-prorated-cancellation"
description: "Cancel subscriptions and refund exact unused-time proration."
---

# Subscription Prorated Cancellation

Cancel an active subscription immediately and refund the exact unused portion of its current paid billing period.

## Procedure

1. Resolve the customer and retrieve all subscriptions, charges, invoices, refunds, customer balance, and the refund log before any write. For delayed or replayed requests, if the log and live read-back show the requested cancellation and refund already completed, verify the subscription, refund, charge, and balance, then report the existing result without repeating a write. Otherwise, confirm there is exactly one target subscription and charge, the charge paid for that subscription, no prior refund covers it, and no customer credit duplicates the requested refund.

2. Check product activity and repeat-subscribe/refund history using the standard refund investigation. Scope the refund-eligibility usage decision to the billing period of the target charge; treat older lifetime activity only as repeat-abuse context, never by itself as a reason to deny unused-time proration on the current period. Stop for the applicable refund-policy gate when prior refunds, repeat behavior, heavy usage during the target period, or another blocker is present.

3. Before any write, validate the proration inputs from the reads in step 1: `current_period_start` is before `current_period_end`, the request time falls inside that period, and the charge has a positive unrefunded balance. Estimate the upper-bound refund with the request time in place of `canceled_at` using the formula in step 5. Stop before canceling when that estimate is negative, zero, or above the unrefunded charge balance: the cancellation is irreversible, so a refund that cannot be computed must never follow it.

4. Log the cancellation write before execution, cancel the subscription through the approved write gate, then retrieve it again. Continue only after read-back shows `status=canceled`; never infer cancellation from a successful command exit alone.

5. Recalculate the unused-time refund from authoritative timestamps captured after cancellation: `charge_amount × (current_period_end − canceled_at) ÷ (current_period_end − current_period_start)`. Round once to the nearest minor currency unit using half-up rounding. Reject negative amounts, amounts above the unrefunded charge balance, or periods with invalid timestamps. If the post-cancel calculation is rejected even though step 3 passed, do not invent an amount and do not retry: append the canceled state to the refund log, escalate to Finance with the subscription, charge, and invoice read-backs, and report the customer as canceled without refund together with the escalation reference. Restoring paid access is a separate Finance-directed write through the guarded path, never an ad hoc re-subscribe.

6. Log the refund write before execution, create a partial refund for the calculated minor-unit amount through the approved money-moving gate, and never retry when the write outcome is unknown.

7. Retrieve the refund, charge, subscription list, and customer balance. Finish only when the refund is successful for the calculated amount, the charge’s refunded amount reflects it, no active-like subscription remains, and the customer balance contains no duplicate credit.

8. Append the verified decision to the refund log and report the original charge, billing period, unused percentage, refunded amount, canceled subscription ID, charge ID, and successful refund ID.

## Verification checklist

• Customer, subscription, invoice, and charge resolve to the same account.
• Prior-refund and daily-volume policies passed or were explicitly waived through their existing gates.
• Proration inputs and an upper-bound refund estimate were validated before the cancellation write.
• Cancellation read-back is `canceled` before the refund.
• Proration uses the actual `canceled_at`, not the request time or a rounded day count.
• Refund amount is rounded once in minor units and does not exceed the unrefunded charge balance.
• Refund, charge, subscription, and balance read-backs match the reported final state.
