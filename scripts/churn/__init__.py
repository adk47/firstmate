"""Support-churn win-back: the FIX-FIRST pipeline (rulings R2-R6, report
data/support-churn-winback-fable-c1/report.md; dispatch support-churn-winback-fix-first-w1).

Three stages, each a thin entry script over this package:

* ``scripts/route_fix.py``     (daily)  - one fix ticket per churned-with-issue user, into
                                           the OWNING lane's existing intake, tagged
                                           ``churned:<date>`` and paid-priority (R4).
* ``scripts/fix_readback.py``  (hourly) - a user becomes message-eligible ONLY when the fix is
                                           Seen in the system of record. Writes ``fixed_at``.
* ``scripts/winback_fix_send.py`` (daily) - renders ``wb_fix_1`` for the eligible users, runs
                                           every exclusion and the copy guards, and hands ONE
                                           batch to the single sender seat. It never sends.

Why the split exists: R2. An apology without the fix is what these 325 users already received.
A message is only ever justified by a fix we can point at in a store, so the read-back - not
the routing, and never a schedule - decides who is messageable.

Nothing here approves a credit (``policies/credit-approval-automation.json``): routing only
puts the user at the head of the owning lane's existing queue, and the lane's own gates still
decide. Nothing here sends: the sender seat owns that (R5).
"""

from __future__ import annotations

__all__ = ["model", "state", "tickets", "lanes", "readback", "render", "guards", "audience", "returns"]
