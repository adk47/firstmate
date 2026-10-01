---
name: "subscription-refund-reconciliation"
description: "Reconcile downgrade credits before refunding plan-change charges."
---

# Subscription Refund Reconciliation

Reconcile a subscription downgrade credit before refunding an accidental upgrade charge so the customer receives cash once and retains only legitimate residual credit.

## Procedure

1. Retrieve the customer, all subscriptions, the charged upgrade invoice, the reversal/downgrade invoice, every charge in scope (the annual-conversion charge, plus the original monthly charge in the multi-charge case), and the customer balance; confirm the subscription currently matches the customer’s requested plan and that none of the charges identified for refund has already been refunded.

2. Reconstruct the billing sequence from invoice line items: record the cash charge, any balance credit consumed by the upgrade invoice, and the credit created by the reversal invoice; finish when each amount is tied to a specific invoice or balance transaction. Choose the refund set from the requested entitlement: when the customer keeps the earlier paid monthly term, refund only the annual-conversion invoice's actual charge after its embedded unused-monthly proration credit. When the entire mutated subscription is canceled and the customer will repurchase monthly separately, refund both the annual-conversion charge and the original monthly charge so no paid monthly amount is stranded without access. Treat these as one multi-charge resolution, obtain the required repeat-refund override before the second refund, and verify each charge and refund record independently.

3. Treat an existing negative customer balance as value already returned. Do not refund the charge while leaving a reversal credit that represents the same annual-plan value, because that reimburses the customer twice. For an ordinary downgrade inquiry where the requested lower plan is active and the downgrade invoice already created a live proration credit, resolve the difference as account credit that will apply to future invoices; do not create a cash refund unless the customer explicitly requests conversion to cash. Before explaining this resolution, verify that later payment attempts captured zero and that no cash refund already exists.

4. Separate the reversal credit into the amount duplicating the requested cash refund and any legitimate residual credit. Use invoice and customer-balance ledger amounts rather than deriving the adjustment from plan list prices; preserve taxes, prorations, and rounding exactly. If the ledger does not make the split unambiguous, obtain read-only Finance guidance before recommending or executing a write.

5. Choose the correction from the intended entitlement. For a mid-term downgrade, preview the existing item IDs on matching monthly prices with `proration_behavior=always_invoice` and `billing_cycle_anchor=now`; reconcile the exact negative total. To preserve an already-paid monthly term without charging again, restore the original monthly price and quantity, remove annual-only items, use `proration_behavior=none`, and set `trial_end` to the original line-item period end; verify one monthly item, a zero-dollar invoice, the cutoff, and zero live concession before refunding only the annual-conversion charge. To charge a different monthly plan now, preview it with existing item IDs, monthly prices, `proration_behavior=none`, and a current anchor. Apply it with `payment_behavior=pending_if_incomplete` without `cancel_at`—Stripe rejects that combination. Verify the paid replacement invoice, then set and verify `cancel_at` in a separate guarded write. Only then refund the original charge set one charge at a time with required keep-subscription and repeat-refund waivers; confirm the replacement charge remains unrefunded and no credit was created.

6. Write the resolution in this order: adjust the customer balance to remove only the duplicate value, verify the resulting balance, refund each identified charge through the approved money-moving gate one at a time, verifying that charge’s concrete refund record before issuing the next (the repeat-refund override precedes the second), then confirm the requested subscription remains active only when an authorized keep-subscription waiver is present. Both writes are non-idempotent: never retry a balance adjustment or a refund whose outcome is unknown.

7. If any refund is refused, fails, or returns an unknown outcome after the balance adjustment succeeded, stop and re-read both authoritative states: the customer balance transactions and every identified charge's refund list. In a multi-charge resolution, name which charge's refund landed and which did not, and never re-issue a refund for a charge whose read-back is unknown. When the read-back proves a refund did not land, restore only the portion of the removed balance credit that the step 2 ledger mapping ties to that failed charge, with a compensating balance adjustment, and verify the resulting balance; never restore value that belongs to a refund that succeeded. If the removed credit cannot be split per charge unambiguously from the ledger, escalate to Finance instead of compensating automatically. When the refund outcome is unknown, or the compensating adjustment fails, escalate to Finance with both read-backs and do not retry either write.

8. When summarizing an existing support resolution, treat conversation notes and customer replies as claims, not proof. Re-read every identified charge, each charge’s concrete refund record, the customer balance, and the subscription; reconcile them with the refund/audit log, then report only the confirmed amount and disposition per charge.

9. Separate proposed from read-back-confirmed writes; finish only when balance, refunds, and subscription match the resolution. For engineering, give the observed symptom and timeline of plan selections, charge, reversal invoices, and balance transactions. Keep remediation separate; do not infer a root cause or prescribe product changes from billing artifacts. Customer-facing bar: `references/customer-communication.md`.

## Roster-seat proration branch

When an accidental profile-seat swap increases a graduated subscription quantity, reconstruct the intended roster before moving money:

1. Read the active roster seats, their update timestamps, the subscription quantity, and the charge invoice. Confirm the invoice is a quantity-change proration and identify the customer’s intended replacement from the seat transition evidence. Preserve the previously active seat and the newly activated replacement; pause only the extra seat whose later reactivation created the temporary quantity increase.
2. Apply the roster correction through the gated team-seat update, read back the named active and paused profiles, then run the workspace subscription-sync endpoint. A successful seat update request is not proof that billing changed; finish this step only when the product seat limit and payment subscription quantity both equal the intended count.
3. Re-read the customer balance and newest correction invoice after subscription sync. The sync can mint a new live proration credit, so use that post-sync value—not the pre-correction balance—for reconciliation. Neutralize the live concession before refunding the original proration charge, verify the live concession is zero, then issue and verify the refund with the authorized keep-subscription and prior-refund waivers when applicable.
4. Tell the customer which profiles remain active, which profile was paused, that the subscription remains active, and the verified refund amount; add the same concrete resolution to the internal support note.

## Paid-month restoration branch

When the customer paid for a monthly term, then converted that same subscription to annual, and the annual refund requires canceling the mutated subscription, restore only the retained monthly entitlement:

1. Read the original monthly invoices and use their line-item period end as the access cutoff; do not estimate a month from the current date.
2. Create a new subscription on the original monthly price and paid quantity, set `trial_end` to that exact cutoff, retain the workspace/user/plan metadata and applicable standing discount, and use an idempotency key. If the customer should receive only the retained paid access, also set `cancel_at` to the cutoff so no renewal occurs. If the customer explicitly wants the monthly plan restored as recurring, omit `cancel_at`; the trial bridges the already-paid term and monthly billing resumes at the cutoff. Run the write through the guarded Stripe path with a pre-write audit entry.
3. Read back the new subscription, its initial invoice, recent charges, and the product user record. Finish only when the monthly plan and quantity are present, the subscription is active-like through the exact cutoff, the initial invoice amount due and paid are zero, no charge was created, and the product entitlement reflects the monthly plan. For access-only restoration, verify `cancel_at` equals the cutoff. For recurring restoration, verify `cancel_at_period_end=false`, preview the next invoice, and confirm its period begins at the cutoff and its total matches the monthly plan after retained discounts. Record the verified result in the audit trail.

## Verification checklist

• Each charge ID and refund amount in the refund set match the payments identified in step 2.
• No prior refund already covers any charge in the refund set.
• The post-adjustment balance retains every legitimate residual credit and none of the duplicate reversal credit.
• Every refund in the set has a concrete successful refund record.
• Any balance adjustment that outlived a failed refund was compensated and read back, or escalated with both read-backs.
• The subscription is on the customer’s requested plan and its active/canceled state matches the authorized disposition.
