# The empty-track approve rule (ET1)

Captain, 2026-11-16 02:1xZ: *"if no credits are on a track we let those go on if it makes sense?"*

A held credit request (`unverified` / `user_verification_needed`) asks us to prove a claim about a track. When the
track carries **no credits at all**, there is nothing to verify: the claim is the first credit on it, the presence
rules (which credit is "already served", whether the profile is over-credited) have nothing to compare against, and
the usual reason a request is stuck — our own catalogue already disagrees — does not exist.

`scripts/credit_review/empty_track_approve.py` is the coded rule for it. It is **its own rule**: it does not move
the validator low-risk path's thresholds (`score_approve.py`: popularity 1–59, total risk < 30) and it does not
reuse them. It shares only the refusal predicates every credit rule shares: `policy.validator_conflict`,
`policy.validator_rejected_rules`, `roles.family_of`, the account gate, the fraud watchlist and R8.

## The five conditions, and what a hold looks like

An approve needs **every one** of these; the first that fails is the row's `reason_code`.

| # | condition | hold reason when it fails |
|---|---|---|
| 1 | the track is in the catalogue with a **real** ISRC or Spotify id, under **this** id | `track_unread`, `track_deleted`, `track_merged`, `track_moved:<id>`, `track_identifier_placeholder` |
| 2 | **zero credits** on the track | `track_has_credits:<n>` (n = the credits core lists) |
| 3 | no role conflict on the claim | `reject_rule:<names>`, `validator_conflict`, `review_hold:<names>`, `organization_role` |
| 4 | no watchlist hit on the account or the profile | `watchlist_user`, `watchlist_profile` |
| 5 | no R8 account hold, and the account gate is a green allow | `R8_account_hold`, `account_hold_unknown:<…>`, `account_gate_<state>`, `account_gate_unknown:<…>`, `watchlisted_account` |

Deterministic, no model. **Every unreadable input is a hold**, never an approve: a track document we could not read
is `track_unread` (a 404 does not prove the catalogue lacks the track — core answers 404 when its own catalogue read
failed), a credit list core did not return is `track_credits_unknown`, an unreadable gate or hold set is
`*_unknown`, and a claim whose `credits` column is NULL is `roles_unread` (an empty array is a measured answer and
is left to the validator's rules).

### Condition 2 is the one that must never rot

A track with **one** credit is never approved by this rule, whatever else is true of the row: condition 2 is checked
for the whole track, not for the profile. `test_one_credit_on_the_same_track_never_approves` in
`scripts/tests/test_credit_empty_track_approve.py` pins it by name, and so does
`test_a_track_with_fifty_credits_never_approves`. A track whose credit list is empty but whose `collaboratorsCount` is not
zero is `track_has_credits` too: a collaborator entry is a credit we have not finished serving.

## Where the emptiness is read

**Conditions 1 and 2 are read from core's own track document, `GET /admin/track/<id>`** — one paced GET per
*candidate* track, where a candidate is a request that already passed conditions 3–4 (no role conflict, no
watchlist hit), which are local reads over the queue. The document supplies the track's identity (a real ISRC or a
real Spotify id, under this id) and its `credits[]`; an empty list is the only thing that satisfies condition 2.

The analytics replicas are **not** used for this, and the reason is measured: `postgresql_stats.public.profile_track`
(the served-credit replica the queue report counts) says **zero** for tracks that carry credits — of 40 tracks it
counted zero, core's document lists credits on 39; of 40 it counted non-zero, 33 disagree, usually undercounting
(7 vs 71, 1 vs 9). `postgresql_core.public.profile_v3_tracks` disagrees the same way (39 of 40 "zero" tracks carry
2–5 credits in core). A rule that pre-filtered on a replica and then approved would approve tracks that already
carry credits, which is the one thing this rule must never do. `track_credit_counts` still exists in the module as
a measurement helper and **no decision path calls it** (a test pins that).

The catalogue replica cannot answer condition 1 either: `postgresql_catalog.catalog_profile_track` carries org
profiles only, and there is no track table with an ISRC.

## Nothing arms

`policies/credit-empty-track-approve.json` ships `apply_enabled: false` with `approved_by`/`approval_ref` null, and
the module wires **no approve writer at all** (`apply_refusal` answers `NO_WRITER` even with the switch flipped).
Approving in core is a second, reviewed change: this repo has one credited approve path (`score_approve`'s executor
and its wrapper predicate), and AGENTS.md does not allow a second executor to grow beside it. The registry row in
`policies/credit-approval-automation.json` is `approved: false`, so a cron or loop that ran this script would be
refused by `check-credit-approval-automation.sh` rather than slipping past it.

## Running it

```
python3 scripts/credit-empty-track-approve.py measure --sql      # how big is it (population, not approvals)
python3 scripts/credit-empty-track-approve.py decide --sample 5  # rows, with reasons; shadow ledger
python3 scripts/credit-empty-track-approve.py apply              # refuses, always
```

`measure` reads one statement for the open queue's facts (status, user, profile, track, the claim's roles and the
validator's own verificationdata), then core's track document for the candidate tracks, and splits its candidates by
the decider's human bucket. It reads no account gate and no R8 hold set — those are one
paced question per user — so a `measure` number is a **population**, never an approval count; the output says so in
`NOT_READ_HERE`. `decide` reads all five conditions and records one row per request in the rule's own table
(`empty_track_decisions`), never in the decider's `decisions` (seven readers act on the newest row there, and a
shadow approve must not be one of them).

Both commands **fail closed**. A fraud watchlist that cannot be read is not a watchlist that says nobody is on it:
`measure` prints nothing but the reason, `decide` records nothing, and the failure is paged. A request whose
validator verdict is missing, is not an object, has no `rule_risk_percent` map, or carries
`rule_errors[_hold_on_error]` is held (`validator_rules_unread` / `validator_conflict`) — an unmeasured verdict is
never "no conflict". `test_an_unreadable_watchlist_never_approves`, `test_a_missing_verdict_never_approves`,
`test_a_malformed_rules_map_never_approves`, `test_a_rule_errors_hold_on_error_never_approves`,
`test_a_null_roles_column_never_approves` and `test_a_null_roles_column_is_held_by_the_scan_to_decision_path` pin
all six.

A document served for a *different* id is not a failed read: core redirects a merged-away track id to its survivor,
so the request points at an id that no longer exists. That is `track_moved:<survivor id>` and a hold — the empty
credit list would belong to the wrong id. 12 of the 29 empty tracks found in the census are this case.

## The measurement (2026-11-16)

See the report beside the rule: `data/empty-track-approve-r1/report.md`. The headline: of 42,387 candidate tracks
behind ~103k open requests, **29 (0.07%) carry zero credits in core**; their 30 open requests are the rule's whole
population, and on a full five-condition dry run **18 would approve** (10 users) while 12 are held because the track
id was merged away.
