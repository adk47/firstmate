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

5. Choose the correction method from the intended entitlement. For an ordinary mid-term downgrade, create a Stripe invoice preview using the existing subscription-item IDs, matching monthly price IDs, `proration_behavior=always_invoice`, and `billing_cycle_anchor=now`; use its exact negative total to reconcile the resulting credit. When the customer already paid for the current monthly term, accidentally converted that same subscription to annual, and should keep monthly access without another charge, instead update the existing subscription with the original monthly price and quantity, delete annual-only items, set `proration_behavior=none`, and set `trial_end` to the original monthly invoice line-item period end. Read back one monthly item, a zero-dollar correction invoice, the exact renewal cutoff, and zero live concession credit before refunding only the annual-conversion charge.

6. Write the resolution in this order: adjust the customer balance to remove only the duplicate value, verify the resulting balance, refund each identified charge through the approved money-moving gate one at a time, verifying that charge’s concrete refund record before issuing the next (the repeat-refund override precedes the second), then confirm the requested subscription remains active only when an authorized keep-subscription waiver is present. Both writes are non-idempotent: never retry a balance adjustment or a refund whose outcome is unknown.

7. If any refund is refused, fails, or returns an unknown outcome after the balance adjustment succeeded, stop and re-read both authoritative states: the customer balance transactions and every identified charge's refund list. In a multi-charge resolution, name which charge's refund landed and which did not, and never re-issue a refund for a charge whose read-back is unknown. When the read-back proves a refund did not land, restore only the portion of the removed balance credit that the step 2 ledger mapping ties to that failed charge, with a compensating balance adjustment, and verify the resulting balance; never restore value that belongs to a refund that succeeded. If the removed credit cannot be split per charge unambiguously from the ledger, escalate to Finance instead of compensating automatically. When the refund outcome is unknown, or the compensating adjustment fails, escalate to Finance with both read-backs and do not retry either write.

8. When summarizing an existing support resolution, treat conversation notes and customer replies as claims, not proof. Re-read every identified charge, each charge’s concrete refund record, the customer balance, and the subscription; reconcile them with the refund/audit log, then report only the confirmed amount and disposition per charge.

9. Report the proposed and completed states separately, naming every write that a read-back confirmed, including a partial write and its compensation. Say that no payment or subscription change has been made only when no write succeeded; finish only when the balance, every identified charge’s refund, and the subscription state all match the resolution.

## Paid-month restoration branch

When the customer paid for a monthly term, then converted that same subscription to annual, and the annual refund requires canceling the mutated subscription, restore only the retained monthly entitlement:

1. Read the original monthly invoices and use their line-item period end as the access cutoff; do not estimate a month from the current date.
2. Create a new subscription on the original monthly price and paid quantity, set `trial_end` and `cancel_at` to that exact cutoff, retain the workspace/user/plan metadata, and use an idempotency key. This represents already-paid access, creates no renewal, and must go through the guarded Stripe-write path with a pre-write audit entry.
3. Read back the new subscription, its initial invoice, recent charges, and the product user record. Finish only when the monthly plan and quantity are present, the subscription is active-like through the cutoff, `cancel_at` equals the cutoff, the invoice amount due and paid are zero, no charge was created, and the product entitlement reflects the monthly plan. Record the verified result in the audit trail.

## Verification checklist

• Each charge ID and refund amount in the refund set match the payments identified in step 2.
• No prior refund already covers any charge in the refund set.
• The post-adjustment balance retains every legitimate residual credit and none of the duplicate reversal credit.
• Every refund in the set has a concrete successful refund record.
• Any balance adjustment that outlived a failed refund was compensated and read back, or escalated with both read-backs.
• The subscription is on the customer’s requested plan and its active/canceled state matches the authorized disposition.
