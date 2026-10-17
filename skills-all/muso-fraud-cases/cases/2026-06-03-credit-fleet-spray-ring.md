---
id: "2026-06-03-credit-fleet-spray-ring"
title: "One submitter ring sprayed ~1,100 creative credits across unrelated top catalogs to climb the Producer chart"
source: "repo_mined"
date_opened: "2026-06-03"
date_closed: null
vector: "credit_self_add"
signals: ["high_volume_creative_credits", "many_distinct_primary_artists", "approved_while_verifier_rejected", "free_zero_ltv_account", "alias_sprawl", "graduation_seed_cascade", "ops_queue_bulk_approval", "muso_only_credits"]
evidence_sources: ["docs/credit-verification/credit-fleet-fraud-backend-recommendations.md (sections 1-2)", "skills-all/muso-ops-fraud/SKILL.md (Credit Fleet Fraud)", "skills-all/muso-query-writer/saved-queries/misc/credit_fleet_fraud_user_scan.sql (header notes, validated_on_node8 2026-06-04)", "skills-all/muso-query-writer/saved-queries/misc/credit_fleet_fraud_reject_candidates.sql"]
outcome: "confirmed_fraud"
actions_taken: ["Backend hard-gate recommendations filed: core-backend#8837 and industry-data-processing#1260", "Hydra user-level fleet-fraud scan (advisory, analyst review, no auto-revoke) built as credit_fleet_fraud_user_scan.sql", "Reversal-candidate list query (dry-run, human-gated execution) built as credit_fleet_fraud_reject_candidates.sql", "Flagship submitter 162720 recorded as fully remediated (n_approved=0) in the 2026-06-04 scan notes; the retroactive sweep of the other ring ids is described as in progress and its completion is not recorded in this repo"]
detector_factors_that_fired: []
what_would_have_caught_it_earlier: "User-level scoring of the submitter as a running transaction (volume x distinct primary artists x creative roles x free account); a hard gate on status=approved while verificationData.is_approved=false; closing the ops/admin validation bypass; not letting user-added or ops-approved credits seed the common-collaborator auto-approve. The batch detector (score-fraud-signals.sh) did not exist at the time and no retro-scoring of this case is recorded here, so detector_factors_that_fired is empty because it is unknown, not because none would fire."
related_profiles: ["9703c867"]
---

# Credit fleet spray ring (June 2026)

**Status:** outcome `confirmed_fraud` per the backend recommendations doc. `date_closed` is null: only the flagship submitter's remediation is recorded.

## What happened (as sourced)
- A free, zero-LTV account (userid 162720) had a contested claim on a small real profile (id prefix `9703c867`) processed in Oct 2025.
- It then injected about 1,100 Producer/Writer credits onto unrelated top-popularity catalogs and reached about #1 on the Producer chart.
- About 1,340 approvals (about 68% per the source) went through the Retool/Clio ops queue. The two figures (about 1,100 injected, about 1,340 approvals) are quoted as the source gives them and are not reconciled in the source.
- 632 rows had `status=approved` while `verificationData.is_approved=false`. 598 rows were approved in one window.
- The 2026-06-04 scan note surfaces the ring as submitter ids 162720, 184149, 179969 (an alias group) plus 301754.
- Flagship id counts from the scan note: 1,253 requests, 104 distinct primary artists, 225 high-risk submissions on pop >= 70 tracks.

## Mechanism
Auto-approve rules that short-circuit the risk score (`approve_common_collaborator` needs only 2 credits with an artist; `approve_credit_exists`; `approve_owning_track`) mean a small seed cascades. Ops approvals both skipped validation and seeded that cascade.

## Gaps in this record
- No customer-facing or financial impact figure is recorded in the repo.
- Whether the three other ring ids were remediated is not recorded here.

## Corrections
(none yet. Add new dated sections below; never rewrite the sections above.)
