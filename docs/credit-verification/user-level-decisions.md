# User-level decision, row-level effect

Captain 2026-11-12: "the verification decision unit is wrong". The held queue is counted and worked in
rows, and it is made of people: 11,552 rows on us were 1,617 users, and the R8-volume cohort was 2,061
rows held by 65 of them.

`scripts/credit_review/user_decision.py` changes the **unit** the decider's stored-fact rules are
evaluated in. It changes no threshold, no refusal rule and no hold reason, and it approves nothing.

- **One verdict per person.** A user's open rows are grouped by the stored facts the rules read. The
  ladder is walked once per group; the user-scope fact (the deny list) is read once per person.
- **The effect is still per row.** Every row gets its own answer (rule, decision, reason), worded by
  the same strings the per-row path prints, so a ledger row is what it was.
- **An unreadable row is never covered by a batch.** A row whose stored facts are not in the shape the
  rules were written for (a string score, a `verificationData` that is not an object, no user id) is
  walked on its own exactly as before, and counted as a fallback.

## What is user-level, and what stayed per-row

`user_decision.RULES` is the inventory; this table is its summary.

| Rule | Unit | Why |
|---|---|---|
| validator `reject_*` rule fired → hold | **user** | reads only the row's stored validator rules; decided before any live read |
| user on the deny / fraud / hold list → support | **user** | a fact about the person |
| profile on the deny list → support | **user** | reads only the row's profile id |
| no `trackId` → defer | **user** | reads only whether the row has one |
| validator conflict (`review_*` ≥ 30, class C, hold-on-error) → support | **user** | reads only the row's stored validator rules |
| evidence unavailable, catalog track or artist unreadable → defer | row | a transient failure of one read says nothing about the person's other rows |
| big track, trusted-source contradiction, red flags, editorial role | row | each reads the row's own track and role |
| trusted confirmation, footprint, web check, paid provisional, per-role split | row | these are the **approvals**; an approval is never inferred from another row |
| document contradiction | row | a document verdict is keyed by claim (request and role) |
| never re-ask, daily caps, account gate | user (already) | `decide.filter_support`, the cap counters and `account_gate.Cached` were per person before this change |

**Where the decider takes its answer from the pass.** `decide.run` takes only the reject-rule hold from
`user_decision.decide_users`: it is the one stored-fact rule that sits ahead of every live read. The
other four are still reached through `decide.pre_model` after the row's own evidence build, because a
failed read of that row defers it first (`Answer.live` names the read). Their wording now lives once, in
`user_decision.py`, and `pre_model` imports it.

## Equivalence (2026-11-15, ak47, Python 3.12.3, live replica)

`credit-user-decisions.py equivalence` computes the per-row answer and the per-user answer for every
row and compares the whole answer (rule, decision, reason, live read) row for row, on a fresh replica
snapshot taken after rebasing onto `origin/main` @ `7f59b7219`. Exit 1 on any disagreement, 2 on an
unreadable rows file, 3 on too few people to call it a proof.

Sample: every row of the 10 largest and the 10 smallest holders in each cohort.

| Scope | Rows | Users | Agree | Disagree | Fallback | Walks before → after | Clock before → after |
|---|---|---|---|---|---|---|---|
| Sample (paid held) | 3,717 | 86 | 3,717 | 0 | 0 | 3,717 → 249 | 17.5 → 17.8 ms |
| Paid held court, all | 7,358 | 886 | 7,358 | 0 | 0 | 7,358 → 1,520 | 35.5 → 50.2 ms |
| Sample (open `unverified`) | 8,752 | 96 | 8,752 | 0 | 0 | 8,752 → 394 | 41.8 → 47.6 ms |
| Every open `unverified` row | 22,566 | 2,256 | 22,566 | 0 | 30 | 22,566 → 4,159 | 111.4 → 165.3 ms |

The sample spans every cohort (paid held: 24 R8 volume, 22 R8 hard, 27 score-only, 37 named review, 11
no-codes; open `unverified`: 25 / 21 / 44 / 37 / 20). The 30 fallbacks are rows with no user id: they
cannot be attributed to a person, so each is walked on its own.

**A snapshot is all of its rows or none of them.** `parse_snapshot` raises on any line that is not a
CSV row instead of skipping it (QA review 2026-11-15: the skip let `snapshot` write a PARTIAL rows file
that `equivalence` then proved 0 disagreements over). The replica's stdout is CSV only - the wrapper
sends the jline banner to stderr, measured with `scripts/trino-query.sh "SELECT 1 AS a, 'x' AS b"` -
so a line that is not a row is a transport error, never chatter. `test_one_line_that_is_not_a_row_fails_the_whole_snapshot`
replays the mixed valid/malformed stdout QA reproduced.

Two things back the claim that the per-row side of this comparison is the decider's answer and not this
module's opinion of it:

- `test_user_decision.py` `PinnedToTheDecider` runs each stored-fact rule through the real
  `decide.run` and compares the ledger row.
- Against the production decisions ledger (read 2026-11-12, on that day's 5,976-row held snapshot): of
  the 4,172 rows the pass decides, 2,995 carry exactly the pass's decision and reason in their latest
  decider row. The other 1,177 carry a never-re-ask reason written by a later layer (proof on file,
  emailed support@, proof status unknown), which neither confirms nor contradicts the stored-fact
  answer. No row carries a different stored-fact or evidence rule's answer.

**The wall clock did not improve; it is slightly worse.** A ladder walk costs about 4 microseconds, and
grouping rows costs more than the walks it saves. The ladder was never where the decider's time goes:
that is the live evidence build (admin reads per row) and the web check, and this change removes none of
those (see "What this does not do"). What changed is the size of the work a reader faces - one line per
distinct answer a person holds, and the mean of 8.3 rows a person hides the shape.

## What it does to each cohort

- **R8 volume (2,833 rows / 83 users).** Every row is decided by a stored fact, and every user has one
  answer: request support on the validator conflict `review_hourly_velocity_profile`. It is 83
  decisions and 0 rows left per-row.
- **Named review (1,944 / 393).** 389 users are fully decided by a stored fact and 10 rows stay
  per-row.
- **Score-only (1,997 / 490).** **The unit change does almost nothing here.** The validator's risk score
  held these rows without a named rule at 30 or more, so the answer comes from the row's own track,
  role and catalog evidence: 5 users are decided and 1,975 rows stay per-row. This cohort stays
  row-level work until a rule exists that reads the person.
- **R8 hard.** Every row is a reject-rule hold for a named human; one decision per person.

## What this does not do

- **It skips no live read.** A row whose stored-fact answer is "request support" still gets its
  evidence build first. Taking that answer before the build would save one build on every row a stored
  fact decides, and it is **not** equivalent: a row whose read fails today is deferred, and
  the ledger row would lose its track title, popularity and catalog columns. That is a change of
  outcome and of audit trail, so it needs a ruling and is not in this change. Its saving is unmeasured.
- **It sends nothing and writes nothing.** One ask per user was already `filter_support`'s rule.
- **It does not make the cohort labels an input.** `user_decision.cohort` reproduces the paid-queue
  census labels from the validator's `hold_reason_codes` (the census script is not in this repo); the
  mapping is pinned by `test_user_decision.py` `Cohorts`, one assertion per label. A label never
  selects an answer.

## Running it

```bash
# on node-8 (reads the replica; writes only the --out file). From a checkout, pass the repo's own
# trino wrapper, because the default is the deployed /opt/hydra path:
#   --trino scripts/trino-query.sh
scripts/credit-user-decisions.py snapshot --court paid-held --out /tmp/held.json
scripts/credit-user-decisions.py equivalence --rows /tmp/held.json      # exit 0 / 1 disagree / 2 unreadable / 3 too few users
scripts/credit-user-decisions.py plan --rows /tmp/held.json --top 30    # the per-person worklist
```

Tests: `scripts/tests/test_user_decision.py` (PR Validation).
