"""Caroline's real, safe actions (caroline-operator-c1, captain 2026-10-27 ~16:00Z).

Design and operator view: docs/credit-verification/caroline-actions.md.

Four actions, each a verb of scripts/caroline-actions.py that the support-tools plugin
execFile's with the ctx-derived verified Intercom author email (never a model argument):

  status        read core truth for the verified user and pick ONE approved status line, or none
  doc-intake    queue the customer's cached attachments for the document reader (H3/doc-verify)
  merge-intake  check a merge request before it is filed to the merge queue (no execution)
  handoff       hand a case Caroline cannot decide to the credit-trust board queue

None of them approves, rejects, deletes or hides anything: the package has no write path to core.
Every call writes one ledger row (ledger.py). The 7-day rule and the owes-proof rule live in policy.py.
"""
