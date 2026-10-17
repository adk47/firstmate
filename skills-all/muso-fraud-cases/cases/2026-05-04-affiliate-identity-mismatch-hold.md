---
id: "2026-05-04-affiliate-identity-mismatch-hold"
title: "Affiliate registration identity does not match the payout email identity; $5 held"
source: "repo_mined"
date_opened: "2026-05-04"
date_closed: null
vector: "referral_abuse"
signals: ["registration_payout_identity_mismatch", "possible_account_takeover_or_purchased_account"]
evidence_sources: ["workspaces/finance/SOP-rewardful-fraud-detection.md (rubric rule 15; Appendix: identity mismatch case file)"]
outcome: "inconclusive"
actions_taken: ["$5 commission held pending Rewardful identity verification"]
detector_factors_that_fired: []
what_would_have_caught_it_earlier: "The identity verification result, which is not recorded in the repo: without it nobody can say whether this was an account takeover, a purchased account, or fake KYC. The customer side is clean (1 real referral, 5.7M streams, 327 events), so only the affiliate side is in question."
related_profiles: []
---

# Affiliate identity mismatch (audit of 2026-05-04)

Rewardful affiliate id `6f49ad7e-b316-4d95-9dc2-49433dd5b2bb`. Held, not closed: the SOP lists three possible explanations and records no verdict.

## Counts
- 1 referral; $5 commission held.

## Corrections
(none yet. When the identity verification result is known, record it here as a new dated section and change `outcome` only by a dated correction, never silently.)
