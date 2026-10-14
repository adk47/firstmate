"""AI credit review for Muso credit requests (hydra).

Two modes share one evidence + judge + policy core:

* APPROVAL AUDITOR (``credit-review.py audit``): re-checks every credit request
  that reached ``approved`` (any path) shortly after it was approved, and returns
  CONFIRMED / SUSPECT / CONTRADICTED / UNVERIFIABLE with cited evidence. It is
  read-only on credits.
* PRE-APPROVAL REVIEWER (``credit-review.py review``): reviews requests the
  validator held (``status=unverified``) and recommends APPROVE-RECOMMENDED /
  REJECT-RECOMMENDED / NEEDS-HUMAN. It is advisory: no phase in this package
  writes a credit-request status.

Design and rollout: docs/credit-verification/ai-credit-reviewer.md.
Stdlib only, so it runs on node-8's bare python3 and in CI without pip.
"""
