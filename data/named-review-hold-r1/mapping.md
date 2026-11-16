# What the "named review" bucket selects

Measured 2026-11-16 19:40Z on node-8 (deployed `9d01302c5`), read-only:
ledger `/var/lib/hydra/credit-review/ledger.sqlite3` (`mode=ro`), and the replica's paid-held court from
`scripts/credit-user-decisions.py snapshot --court paid-held` (7,766 rows / 928 users). The commit holds counts
only. No request, user or profile id is in it.

## The bucket is not a ledger reason

The report's "named review" bucket is `user_decision.cohort(row) == "named_review"`
(`scripts/credit_review/user_decision.py:221-239`). It reads the validator's own `verificationData.hold_reason_codes`
on the core row, not any ledger `reason`. A row belongs to the bucket when it has at least one hold code, none of
which is `review_hourly_velocity_profile` (that is R8 volume), none starts with `reject_` (R8 hard), and none is
`risk_score_at_or_above_threshold` (score-only). "Named" means that a `review_*` rule is named. It does not mean a
person is named.

Reproduced on the paid-held court:

| cohort | rows | users | report 19:05Z |
|---|---|---|---|
| named_review | 2,027 | 414 | 2,025 / 415 |
| r8_volume | 3,035 | 91 | 3,035 / 91 (exact) |
| score_only | 2,095 | 509 | |
| r8_hard | 485 | 42 | |
| other (no codes) | 124 | 11 | |

Validator codes on the 2,027 rows (a row can carry several): review_big_track_without_trusted_credit 675,
review_role_credited_to_other_at_trusted_source 562, review_held_submitter 465, fraud_hold 398,
review_org_role_without_outside_source 102, review_duplicate_of_approved_credit 94, review_big_track_weak_footprint 84,
review_editing_role_without_trusted_credit 20, _hold_on_error 12, track_not_in_catalog 10, evaluation_error:* 9,
review_operations_tombstone 3.

## The five candidate ledger reasons

The total and paid columns count every `decisions` row carrying the reason (paid = `paid_priority=1`). The latest
column counts requests whose newest decision carries it. The last column counts the bucket's 2,027 rows whose newest
decision carries it.

| reason | total rows | paid rows | latest: rows (paid rows / paid users) | rows in bucket (users) | in bucket? |
|---|---|---|---|---|---|
| proof on file: human review (a document is already on file; never ask again) | 68,947 | 24,344 | 7,683 (3,368 / 518) | 113 (18) | partly: 113 of 2,027 |
| same + ` \| already user_verification_needed: recorded so stage 2 reads the document` | 25,413 | 11,500 | 22,608 (8,703 / 589) | 0 | no |
| validator reject rule fired (reject_publisher_label_credit): never approved or asked by automation; human review | 7,920 | 4,940 | 1,082 (557 / 35) | 0 | no (a `reject_` code is R8 hard by construction) |
| emailed support@ in the last 90 days: human review, never asked (when in doubt, don't send) | 4,084 | 3,435 | 648 (576 / 26) | 69 (14) | partly: 69 of 2,027 |
| server approval guard would refuse (popularity_unattributable): human review | 1,032 | 207 | 53 (10 / 2) | 0 | no |

Two of the brief's strings are truncated forms. The ledger text carries the suffixes shown above.

## What the bucket's rows carry in the ledger (newest decision per request)

| rows | users | decision | reason |
|---|---|---|---|
| 492 | 116 | hold | proof on file: stage 2 judged the document (need_more): asked through gap-ask |
| 414 | 131 | support | validator conflict: review_big_track_without_trusted_credit |
| 352 | 9 | support | validator conflict: review_held_submitter |
| 345 | 106 | support | validator conflict: review_role_credited_to_other_at_trusted_source |
| 113 | 18 | hold | proof on file: human review (a document is already on file; never ask again) |
| 69 | 14 | hold | emailed support@ in the last 90 days: human review, never asked |
| 63 | 14 | defer | proof_status_unknown (proof-on-file part cs-gmail stale) |
| 57 | 35 | support | validator conflict: review_duplicate_of_approved_credit |
| 33 | 10 | support | validator conflict: review_big_track_weak_footprint |
| 30 | 5 | support | validator conflict: review_org_role_without_outside_source |
| 21 | 2 | support | user on the fraud / PULL / HOLD / RE-VERIFY list |
| 11 | 2 | hold | proof on file: stage 2 judged the document (no_document): asked through uvn-status |
| 7 | 4 | support | no trusted or verifiable web evidence found (NOT_FOUND) |
| 12 | 10 | support | validator conflict: big_track_weak_footprint,hold_on_error / tombstone / hold_on_error / velocity,hold_on_error / big_track,hold_on_error |
| 5 | 4 | (no ledger row) | |
| 3 | 2 | defer | web check unavailable (musicbrainz 503) |

Of the 2,027 rows, 182 carry a "human review" ledger reason. 69 of them (the "emailed support@" reason) are
retired, and the decider's next pass re-decides them. The other 113 (the "proof on file: human review" reason)
clear only through stage 2. Of those 113, 53 have `need_more` (released to gap-ask on the next pass), 59 have no
stage-2 verdict yet (unread), and 1 is an approve with no path, because the document class is `approved: false`.
The other 1,840 already have a non-person ledger answer: a validator-conflict support ask (1,243), a stage-2 ask
(503), a deny-list support (21), a web-check support (7), or a defer that retries (66). Five rows have no ledger row.

## Step 2: what places the hold and what clears it (same snapshot, 19:40-19:55Z)

**What places it: the validator, in core, not hydra.** The validator writes `review_*` / `fraud_hold` /
`_hold_on_error` into `verificationData.hold_reason_codes` and leaves the row `unverified`. Core refuses an agent
approval of these rows ("validator conflict (the server refuses agent approvals of these)"). Hydra only labels
them (`user_decision.cohort`, `user_decision.py:221-239`) and judges them (`decide.run`). The census row stays in
the bucket for as long as core's status stays `unverified` and no proof is submitted (`snapshot_sql`,
`COURT_PAID_HELD`).

**What clears it: nothing reaches these rows today.** Of the 2,027 rows, 2,022 have only ever been decided in
`--mode judge`, 5 have no ledger row, and 0 have ever had an apply decision (cron `credit-trust-decide-15m`).
That mode makes no core write, sends no ask and posts no notify
(`credit-review.py:338-339`). `decision_outcomes` holds only `support/shadow` lines for them (75,406). The
message coverage is a measured three-way split: 1,695 rows (84%) are named by no message at all (no verify-ledger
row names them), 70 rows are named only in ledger rows that were never sent (an attempt, a hold or a deferred row,
with no sent message), and 262 rows (73 users) are named by at least one sent message. 1,695 + 70 + 262 = 2,027.
Those 262 rows are 265 row-campaign pairs: uvn-status 253, uvn-new-rows 8, uvn-reminder-14 2, proof-refusal 1,
proof-need-ask 1. The pairs sum to 265, 3 more than the 262 rows, because some rows are named by more than one
campaign.

By what may happen to the row (`policy.never_ask` on the row's own verdict):

| class | rows | users | terminal path that exists today |
|---|---|---|---|
| impersonation (`review_role_credited_to_other_at_trusted_source`) | 563 | 160 | none: never asked (owner 2026-11-14), never rejected (no writer of `rejected`) |
| fraud (`review_held_submitter`, `fraud_hold`) | 465 | 12 | none: same |
| already_held (`review_duplicate_of_approved_credit`) | 94 | 61 | none: same |
| unmeasured (`_hold_on_error`) | 11 | 6 | none: same |
| legal (`review_operations_tombstone`) | 3 | 3 | none: same |
| askable: big_track_without_trusted_credit 675, org_role_without_outside_source 102, big_track_weak_footprint 84, editing_role_without_trusted_credit 20, track_not_in_catalog 10 | 891 | 236 | an ASK would settle it, but the decider's `support` here is judge-only, so it is never sent |

The two "human review" ledger holds inside the bucket:

- `emailed support@ ... human review` (69 rows / 14 users) is **retired**. `decide.filter_support` stopped writing it
  (`decide.py:105`, firstmate 041). node-8 got that code at 2026-11-16 13:15Z. The last row carrying the string was
  written at 05:00Z. These 69 rows are stale verdicts, and the decider's next pass over them gives them the ladder's
  own answer. No code change is needed.
- `proof on file: human review` (113 rows / 18 users) is placed at `decide.py:1114-1116` (`filter_support`,
  `proof.covers(d)` with no stage-2 release). It clears only through `stage2_verdicts.RELEASES`: `need_more` goes to
  gap-ask and `no_document` goes to uvn-status. Stage 2's verdicts on these 113 rows: need_more 53 (a release that
  the next pass picks up), no verdict 59 (waiting on stage 2's read), approve 1. Every other verdict "stays with a
  human" (`stage2_verdicts.py:20`). An `approve` has no path because the document class is `approved: false`
  (`policies/credit-approval-automation.json`), so it never reaches core.

**The defect** is the 1,136 never-ask rows plus the 891 askable rows that judge mode never asks. That is 2,027 rows
whose verdict nothing executes. The two "human review" strings are a side issue: 182 rows, one of the two already
retired.

## Step 3 (ruling 002, B2): where the 891 askable rows sit in the existing ask path (19:00Z owing list, replica re-read 20:0xZ)

The premise that "nobody has ever asked" holds for the decider's judge ledger rows only. The owing-proof builder
(`scripts/credit_review/owing_proof.py`, `owed()`: an `unverified` row with `proof_required` is the `uvn` class
[key=k-proof-required]) already puts the askable rows in the live, gated uvn-status families. 866 of the 891 rows
carry `proof_required=true`.

| where the row is | rows | users |
|---|---|---|
| listed for the uvn-status first ask (class `uvn`, never told) | 241 | 54 |
| already asked by a sent uvn-status ask, still in its window (reminder not due 148, document received 95, other 10) | 253 | 69 |
| listed `uvn_new_rows`, user has a sent uvn-status ask (gets the follow-up) | 44 | 23 |
| listed `uvn_new_rows`, user told only by core's own `proofRequest` notice on another row, never by our ask | 343 | 93 |
| in no ask class: `track_not_in_catalog` only, `proof_required=false`, no `review_*` rule | 10 | 4 |

The first three lines (538 rows) are in the existing ask path today. Over the last 48 ticks their gate outcomes
are the standing rules: `run_size`, `core_notice_within_7d`, `messaged_7d`, comm_state holds, `c2_signed_only`.

The fourth line (343 rows / 93 users) is listed and never sent. `verify_ledger.new_rows_user_done` answers
`no_prior_ask` for a user with no SENT uvn-status ask, and `owing_proof.build` keeps that user off the first ask
because core's marker on another row counts as told. This is the documented ask-never-asked gap (AGENTS.md
"The new-rows follow-up"). Across the whole 19:00Z list it is 1,095 of 1,450 `uvn_new_rows` users (524 paid). It is
not specific to this bucket.

An ask does not move a core row out of `unverified`, so no B2 path makes the census bucket count fall.

## Outcome (firstmate rulings 002 and 003, 2026-11-16)

This lane measures and closes. It changes no code, writes nothing to core and sends nothing. Each part of the
bucket has the following terminal path:

| part | rows | users | terminal path |
|---|---|---|---|
| askable, already in the live uvn-status ask path (listed, or asked and in its window) | 538 | 139 | ASK, through the existing families, copy gate and caps |
| askable, listed `uvn_new_rows` behind `no_prior_ask` (core-told, never asked by us) | 343 | 93 | ASK, once the general fix lands. Filed as its own lane: a core marker counts as told only for the rows it names. That gap covers 1,095 users (524 paid), not just this bucket. |
| `track_not_in_catalog` only, in no ask class | 10 | 4 | NO with the rule named (B1). A document cannot add a track to the catalog. |
| never-ask: impersonation 563, fraud 465, already_held 94, unmeasured 11, legal 3 | 1,136 | 237 | NO with the rule named (B1), after reject-signed-message-r1 lets core take a copy-gate-signed rejection notice |

Not a terminal path: the decider's `judge` rows. They record a verdict and never execute it. An ask leaves the core
row `unverified`, so the census bucket count falls only when B1's NO lands or a row is approved.

The user counts are distinct users within each line, and one user can appear in more than one line.

BUCKET = validator hold_reason_codes containing a `review_*` / `fraud_hold` / `_hold_on_error` / `track_not_in_catalog` / `evaluation_error:*` code and no `review_hourly_velocity_profile`, no `reject_*`, no `risk_score_at_or_above_threshold` (user_decision.cohort == named_review). None of the five ledger reasons composes it. Two of them overlap it: "proof on file: human review" (113 rows / 18 users) and "emailed support@ ... human review" (69 rows / 14 users).
