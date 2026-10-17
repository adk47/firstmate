"""credit-retro r1: role-scoped take-back of the proven batch-approved credits
plus the prepared (never sent) proof-request waves.

Context: from 2026-05-18 to 10-11 the hydra credit-verification batch approved
validator-declined credit requests on an inverted signal (wiki:
credit-verification-bypass-2026). The f1 retro review (firstmate data
credit-retro-hold-docfraud-f1, part-c.md) tiered the 09-01 -> 10-11 approvals.

What this package does (firstmate decision 001, 2026-10-15 23:09Z, "A + X"):

* TAKE-BACK, role-scoped: remove ONLY the one-person roles (Mixing / Mastering /
  Immersive / Remastering) that a trusted source credits to a different profile
  AND a cited web lookup of THAT role confirmed. The agent stages one approval set
  per user (core-backend #10597); Nick or Jan decides each pair; ``apply`` spends the
  approved pairs through #10638 ``POST /admin/credit-removals/:id/execute`` (the same
  removal as ``DELETE /admin/track/:trackId/profile/:profileId/credits``) and sends
  the user's take-back notice in the same step.
  Every other role on the same request stays live and goes to the verify waves.
  No credit-request status transitions and no generic notice.
* Execute and the removal routes refuse every agent token (core-backend #10638,
  #10310), so ``apply`` and ``revert`` run from a named human's (nick@ / jan@) own
  login session.
* Every run writes an append-only ledger (JSONL + sqlite): row id, before
  state, action, evidence URL, actor, run id. ``revert --run <id>`` re-adds
  exactly the roles that run removed.
* Past credits that are not proven fraud are never removed for silence (captain
  2026-10-16 ~00:35Z): they get a friendly documentation ask, PREPARED only (payload
  files for scripts/intercom-verify-request.sh); nothing here sends. Silence leaves the
  credit on the profile, flagged unverified internally.

The live decision rules are in ``takeback.py``; see
docs/credit-verification/credit-retro-r1.md for the runbook.
"""
