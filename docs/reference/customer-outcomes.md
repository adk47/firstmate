# Customer outcome contract

ClickUp workflow status and customer-visible outcome are separate facts.
`resolved`, `done`, or `closed` means internal work stopped; it does not prove
that the exact state the customer requested is now correct.

User Request tickets carry at most one namespaced outcome tag:

- `customer-outcome:complete` — exact requested state verified by readback.
- `customer-outcome:partial` — some requested work remains.
- `customer-outcome:needs-customer` — more information or proof is required.
- `customer-outcome:blocked` — an upstream or engineering dependency remains.
- `customer-outcome:verification-required` — a related change shipped, but the
  customer-visible result is not positively confirmed.
- `customer-outcome:not-applicable` — no completion notification is appropriate.

Missing, invalid, or multiple outcome tags are ambiguous and therefore fail
closed. `impossible` never counts as customer-complete, even if a stale
`customer-outcome:complete` tag is present.

`resolve-notify.py` may send the fixed “all sorted” message only when workflow
is terminal and the sole outcome is `complete`. The conversation closer uses
the same shared predicate and requires every linked ticket to be complete.

Automated writers stamp outcome before status. If a write is interrupted after
the tag but before the terminal status, consumers still reject the ticket. If
the tag write fails, the writer must not resolve the ticket. A human completing
a ticket follows the same order: verify the exact result, set the outcome tag,
then resolve it.

Historical terminal tickets are not backfilled as complete from status alone.
They remain ineligible unless direct evidence supports an explicit outcome.
