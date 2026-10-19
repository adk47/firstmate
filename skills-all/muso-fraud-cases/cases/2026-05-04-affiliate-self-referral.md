---
id: "2026-05-04-affiliate-self-referral"
title: "Affiliate earned commission on the affiliate's own paid Muso subscription"
source: "repo_mined"
date_opened: "2026-05-04"
date_closed: "2026-05-04"
vector: "referral_abuse"
signals: ["self_referral", "affiliate_name_matches_referred_customer", "payout_to_own_subscription"]
evidence_sources: ["workspaces/finance/SOP-rewardful-fraud-detection.md (rubric rule 16; Appendix: self-referral case file)", "Slack #finance_muso thread 2026-05-04 (full audit; not in this repo)"]
outcome: "confirmed_fraud"
actions_taken: ["Commission clawback requested for $24", "Affiliate banned; the Muso subscription itself stays active (real customer, not eligible as affiliate)"]
detector_factors_that_fired: []
what_would_have_caught_it_earlier: "Rubric rule 16 run before first payout: cross-check affiliate name, email, PayPal and card fingerprint against every referred customer. Nothing synthetic to detect here, so activity-based signals would not have fired."
related_profiles: []
---

# Affiliate self-referral (audit of 2026-05-04)

Rewardful affiliate id `6777788b-b154-4bbe-a70b-8b7288f7178f`. The only conversion is Muso user id 254309, which is the affiliate's own account.

## Counts
- The referred user is a real heavy user: 5,762 events and 246M streams, so activity signals look healthy. That is the point of the case.
- One $30/month Business subscription, 3 paid renewals, $24 commission paid to the subscriber's own affiliate account.

## Corrections
(none yet. Add new dated sections below; never rewrite the sections above.)
