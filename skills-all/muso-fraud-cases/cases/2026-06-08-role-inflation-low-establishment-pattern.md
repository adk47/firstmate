---
id: "2026-06-08-role-inflation-low-establishment-pattern"
title: "Role-inflation pattern: many non-creative roles on one credit from a low-credit-count profile (test-fixture shaped, no recorded outcome)"
source: "repo_mined"
date_opened: "2026-06-08"
date_closed: null
vector: "role_inflation"
signals: ["role_inflation", "non_creative_role_bundle", "low_credit_count", "spclient_source_heavy", "high_velocity_profile"]
evidence_sources: ["docs/credit-verification/fraud-detection-spec.md (section 6 factors table)", "docs/credit-verification/fraud-issue-scorer-followups.md (section 3 labeled-set plan)", "workspaces/operations/skills/muso-ops-credit-verification/scripts/tests/fixtures/fraud/raw.json", "workspaces/operations/skills/muso-ops-credit-verification/scripts/tests/fixtures/fraud/scored.json", "skills-all/muso-ops-fraud/SKILL.md (Claiming Fraud, Credit Fraud)"]
outcome: "inconclusive"
actions_taken: ["Multi-factor detector score-fraud-signals.sh built with CV_FRAUD_MODE off | shadow | enforce", "Backtest against a labeled set planned in the scorer follow-ups, not recorded as done"]
detector_factors_that_fired: ["role_inflation", "source_quality", "establishment", "velocity"]
what_would_have_caught_it_earlier: "A labeled outcome. The spec names this pattern and the follow-ups plan to use such profiles as backtest positives, but no document records a confirmed or cleared real case. Missing evidence: real profile ids, the reviewed verdict, and the shadow-run score history."
related_profiles: ["11111111-1111-1111-1111-111111111111", "44444444-4444-4444-4444-444444444444"]
---

# Role-inflation pattern (spec of 2026-06-08)

This is a **pattern**, not a closed investigation. The two related profile ids are synthetic ids from the detector's test fixtures, not production profiles.

## What the repo shows
- Fixture profile `1111...`: one credit carrying 11 roles (9 non-creative, e.g. editorial, photography, art, design, A&R, marketing), spclient source, credit count 34, popularity 72.
- Fixture profile `4444...`: editorial role, credit count 12, popularity 18, `reject_high_velocity_profile` set.
- Running `score-fraud-signals.sh` in `shadow` mode over the fixtures with the Trino factor unavailable gives both profiles a score of 0.47, **under** the 0.60 threshold, so neither is flagged. The first fires role_inflation + source_quality + establishment; the second fires role_inflation + establishment + velocity.

## Why inconclusive
The sources describe these as fraud patterns and plan them as backtest positives. They record no confirmed outcome. Do not read the factor list above as evidence of fraud: it records what the detector would fire on test data.

## Corrections
(none yet. Add new dated sections below; never rewrite the sections above.)
