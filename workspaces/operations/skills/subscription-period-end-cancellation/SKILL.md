---
name: "subscription-period-end-cancellation"
description: "Cancel recurring subscriptions at paid-term end and confirm the verified effective date."
---

# Subscription Period-End Cancellation

Cancel a recurring subscription at the end of its current paid term, preserve access until then, and confirm the verified effective date to the customer.

## Procedure

1. Re-read the support conversation and identify the requested account email, the reachable reply address, and whether the customer asked only to stop renewal or also requested a refund. Use this procedure only when no refund is requested; route refund requests through the refund workflow.
2. When the requester cannot access the billing email, validate ownership evidence against the billing customer before any write. Match the attached invoice or receipt on customer name/email, invoice number, amount, currency, paid date, plan, and billing period; then resolve exactly one live billing customer and target subscription.
3. Retrieve the target subscription immediately before writing. Require an active subscription, `cancel_at_period_end=false`, and a valid `current_period_end`; treat an already scheduled cancellation as idempotent and proceed to verification without repeating the write.
4. Write a pre-execution audit row containing the human requester, target customer and subscription IDs, reason, intended `cancel_at_period_end=true`, and the live pre-state.
5. Set `cancel_at_period_end=true` once. If the write errors or times out, do not retry until authoritative read-back proves it did not land.
6. Retrieve the subscription again. Finish the cancellation only when read-back shows `cancel_at_period_end=true` and `cancel_at=current_period_end`; convert that timestamp to an explicit UTC effective date. Record a post-execution audit row with the verified state.
7. Send a customer-facing confirmation only when the human explicitly requested an update. State that access remains through the verified paid-term end, the subscription will not renew after that date, and no further recurring subscription charges will be made. Send through the approved Intercom wrapper and require a returned reply part ID.
8. Re-read the Intercom conversation and verify the exact outbound body, reply part ID, and approved support author before reporting completion internally.

## Verification

Completion requires both: the live subscription read-back confirms end-of-term cancellation, and the customer reply is present in the authenticated conversation. A successful billing command or an earlier handoff/reference message alone is not proof that cancellation occurred.
