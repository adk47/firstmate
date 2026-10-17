---
id: "2025-01-31-muso-only-credit-profiles-pattern"
title: "Profiles whose popularity is mostly carried by muso-only credits (saved-query pattern, no recorded outcome)"
source: "repo_mined"
date_opened: "2025-01-31"
date_closed: null
vector: "muso_only_credits"
signals: ["muso_only_popularity_pct_over_50", "muso_only"]
evidence_sources: ["skills-all/muso-query-writer/saved-queries/misc/potential_fraud_accounts_muso_only_credits.sql (last_exported 2025-01-31)", "docs/credit-verification/fraud-detection-spec.md (section 6 muso_only factor)", "docs/credit-verification/fraud-issue-scorer-followups.md (section 1 snapshot proposal)"]
outcome: "inconclusive"
actions_taken: ["muso_only factor (weight 3, fail-soft) added to the batch detector, backed by this query", "Daily snapshot of the lookup proposed in the scorer follow-ups, not recorded as built"]
detector_factors_that_fired: []
what_would_have_caught_it_earlier: "Outcome data. The query is marked one_off with no description, and returns profiles where over 50% of summed track popularity comes from muso-only credits (and total popularity over 50). Missing evidence: the profile ids it returned, who reviewed them, and what they found. The 2026-06 fleet case notes say legit engineers and labels are on-source while injected credits are muso-only, which supports the signal but is not a labeled result."
related_profiles: []
---

# Muso-only credit profiles (saved query, last exported 2025-01-31)

`date_opened` is the query's `last_exported` date, the earliest date the repo gives for this pattern. This is a **pattern**, not a closed investigation.

## What the repo shows
- The query selects processed-claim, non-organization profiles and sums track popularity over credits that are muso-created (`recording_id` and `profile_id` both `muso%`), against all credits.
- A profile surfaces when summed popularity is over 50 and more than 50% of it is muso-only. It also reports the share that predates credit verification (before 2023-10-01).
- The detector's `muso_only` factor uses the same band (`CV_FRAUD_MUSO_ONLY_PCT=50`).

## Why inconclusive
No document records a result set or a verdict from running it. `pii: unknown` on the query.

## Corrections
(none yet. Add new dated sections below; never rewrite the sections above.)
