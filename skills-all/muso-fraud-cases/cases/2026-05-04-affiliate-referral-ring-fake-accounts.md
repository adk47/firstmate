---
id: "2026-05-04-affiliate-referral-ring-fake-accounts"
title: "Affiliate referral ring: 9 conversions from throwaway-email accounts with billing-only activity"
source: "repo_mined"
date_opened: "2026-05-04"
date_closed: "2026-05-04"
vector: "referral_abuse"
signals: ["single_country_referrals", "low_median_events_per_user", "billing_only_event_types", "plus_tag_email_aliasing", "high_commission_tier_concentration", "payout_identity_scramble", "affiliate_has_no_product_account", "subscription_failure_tail"]
evidence_sources: ["workspaces/finance/SOP-rewardful-fraud-detection.md (Fraud detection rubric; Three-audit baseline; Appendix: case file for the referral ring)", "Slack #finance_muso thread 2026-05-04 (full audit; not in this repo)"]
outcome: "confirmed_fraud"
actions_taken: ["Affiliate and 11 referred accounts flagged for deactivation", "$95.82 pending commissions voided"]
detector_factors_that_fired: []
what_would_have_caught_it_earlier: "Pre-payout automatic run of the SOP rubric (proposed guardrail 1, not recorded as built), a signup-time email-normalization check for shared base inboxes (guardrail 3), and a country-concentration alert at 80% single country (guardrail 4). The credit detector factors do not apply to this vector."
related_profiles: []
---

# Affiliate referral ring (audit of 2026-05-04)

Rewardful affiliate id `a1d8308a-a4d0-40c5-8bd9-ef2f76bd75a3`. `date_closed` is the audit date the SOP records the outcome on.

## Counts (from the SOP baseline table and appendix)
- 9 conversions, 11 referred accounts, 10 of 11 in a single country plus one VPN outlier.
- Median 67 lifetime events per referred user (min 18, max 131) against 1,401 and 1,958 for the two legit baselines.
- 100% billing-only event types: zero analytics, profile or credits views.
- 7 of 11 accounts on Business/Pro Graduated tiers.
- About $200 collected in Stripe; subscriptions "all dying" after the first charge.
- Neither the signup email nor the payout email has a Muso user row. The payout email is letter-scrambled against one referral email.

## Outcome
The SOP rule is that 2+ rubric hits blocks payout. The source records the outcome as: affiliate and referred accounts flagged for deactivation, pending commissions voided. It does not record how many rubric signals were counted.

## Gaps in this record
- Actual deactivation of the 11 accounts is "flagged for deactivation" in the source; execution is not recorded in the repo.

## Corrections
(none yet. Add new dated sections below; never rewrite the sections above.)
