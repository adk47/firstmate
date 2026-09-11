---
name: "subscription-refund-reconciliation"
description: "Reconcile downgrade credits before refunding plan-change charges."
---

# Subscription Refund Reconciliation

Reconcile a subscription downgrade credit before refunding an accidental upgrade charge so the customer receives cash once and retains only legitimate residual credit.

## Procedure

1. Retrieve the customer, all subscriptions, the charged upgrade invoice, the reversal/downgrade invoice, the charge, and the customer balance; confirm the subscription currently matches the customer’s requested plan and the charge has not already been refunded.

2. Reconstruct the billing sequence from invoice line items: record the cash charge, any balance credit consumed by the upgrade invoice, and the credit created by the reversal invoice; finish when each amount is tied to a specific invoice or balance transaction.

3. Treat an existing negative customer balance as value already returned. Do not refund the charge while leaving a reversal credit that represents the same annual-plan value, because that reimburses the customer twice.

4. Separate the reversal credit into the amount duplicating the requested cash refund and any legitimate residual credit. Use invoice and customer-balance ledger amounts rather than deriving the adjustment from plan list prices; preserve taxes, prorations, and rounding exactly. If the ledger does not make the split unambiguous, obtain read-only Finance guidance before recommending or executing a write.

5. Write the resolution in this order: adjust the customer balance to remove only the duplicate value, verify the resulting balance, refund the identified charge through the approved money-moving gate, then verify the refund and confirm the requested subscription remains active only when an authorized keep-subscription waiver is present. Both writes are non-idempotent: never retry a balance adjustment or a refund whose outcome is unknown.

6. If the refund is refused, fails, or returns an unknown outcome after the balance adjustment succeeded, stop and re-read both authoritative states: the customer balance transactions and the charge's refund list. When the read-back proves the refund did not land, restore the removed credit with a compensating balance adjustment and verify the resulting balance. When the refund outcome is unknown, or the compensating adjustment fails, escalate to Finance with both read-backs and do not retry either write.

7. Report the proposed and completed states separately, naming every write that a read-back confirmed, including a partial write and its compensation. Say that no payment or subscription change has been made only when no write succeeded; finish only when the balance, refund, and subscription state all match the resolution.

## Verification checklist

• The charge ID and refund amount match the accidental upgrade payment.
• No prior refund already covers the charge.
• The post-adjustment balance retains every legitimate residual credit and none of the duplicate reversal credit.
• The refund has a concrete successful refund record.
• Any balance adjustment that outlived a failed refund was compensated and read back, or escalated with both read-backs.
• The subscription is on the customer’s requested plan and its active/canceled state matches the authorized disposition.
