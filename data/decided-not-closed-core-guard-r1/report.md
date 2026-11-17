# decided-not-closed: the core guard that refused 1,036 rows, and the 34 requests behind them

2026-11-16. Captain's order: *"the only people involved should be the requester. our AI should handle
everything else."* The verification report printed a 44,511-row "human" bucket and a
`DECIDED-NOT-CLOSED` line of 1,036 rows, every one of them `skipped:core_guard_refused`. This is what
that number was, which core guard refused, what the guard protects, and what changed.

## What the number was

`decided_not_closed()` counted **decision rows**, not requests. Score-approve ticks every 15 minutes,
and a request it cannot land is decided again on the next tick, so one stuck request became ~30 rows.

Measured on node-8 (`/var/lib/hydra/credit-review/ledger.sqlite3`, 7-day window, 2026-11-16):

| read | rows | users |
| --- | --- | --- |
| before: every apply-mode `approve`/`support` decision row | **1,036** | 5 |
| after: the newest apply-mode decision per request | **34** | 5 |

The 34 requests sit on 5 profiles, and each was re-decided and re-refused on every tick for up to a
day (first decision 2026-11-15T12:40Z, last 2026-11-16T08:40Z):

| user | decisions | requests | profile |
| --- | --- | --- | --- |
| 104229 | 520 | 17 | `5a85fee4-e262-4af1-a00e-2c1207299c6b` (Bass) |
| 23252 | 330 | 10 | `7de70bd9-337d-4ad5-a21e-7448da7cf1ea` (Drums) |
| 341757 | 104 | 4 | `85e98716-b52d-4f58-8e77-8cca42141b61` (Exec Prod / Engineer / Mixing) |
| 100247 | 51 | 2 | `3b051cd2-3985-4f33-a283-9a21dd60916e` (Mixing) |
| 26412 | 31 | 1 | `9cd08c43-75ec-4794-b9ac-5d7139f24fd7` (Exec Prod / Mastering / Engineer / Mixing) |

All 34 are `evidence_kind = validator_low_risk`, `big_track = 0`, `doc_required = 0`, popularity 1–58 —
rows the decider is right to approve on their own evidence.

## Which guard refused, and what it protects

Core answers one word for every guarded `UPDATE` that matches no row: `lost_race`. It does not say
which pin refused. The pins on the low-risk automation's approve (`updateStatus.js`, `lowRiskAutomation`
branch) are: `NOT_VALIDATOR_CONFLICT_SQL`, `agentApprovalAllowedSql` (the row-level low-risk mirror),
`notEngagedSql()`, `notProfileBurstSql()`, and `capDayStillSql()`.

Eliminated by measurement, not by reading:

- **`capDayStillSql`** — a rolled cap day is reported as `CAP_DAY_ROLLED`, not `lost_race`. Core said
  `lost_race`.
- **`notEngagedSql`** — `verifications` holds **zero** rows for all five users (no `documentLinks`), so
  the engagement pin passes.
- **the row-level pins** — every row is validator-approved, risk 0, band A, popularity 1–58, no
  `proofRequest`, no client-sourced metadata, no one-person role. `policy.server_approval_refusal`
  (hydra's mirror of those) returns clear for all 34.

**Confirmed: `notProfileBurstSql()`.** Core refuses to approve *any* request of a profile that has a
sibling request created inside 7 days whose `verificationData.rule_risk_percent` carries
`review_hourly_velocity_profile`, `reject_high_velocity_profile` or `review_high_velocity_profile` at a
non-zero value. Every one of the five profiles has such a sibling:

| profile | sibling that fired | created |
| --- | --- | --- |
| `3b051cd2…` | `ea071cc8-01c7-427a-bbc1-07439197edf3` | 2026-11-14 01:01:44Z |
| `5a85fee4…` | `3d59d092-db05-4c02-ae78-2231e458e234` | 2026-11-12 22:42:59Z |
| `7de70bd9…` | `82523a7a-c163-4da1-aaf9-6099b92c6cee` | 2026-11-14 12:16:46Z |
| `85e98716…` | `4dd866ad-da51-4e06-93fc-7b3ed58f4470` | 2026-11-15 07:39:57Z |
| `9cd08c43…` | `b6716a4e-f9c5-4cb0-a3fd-68a56e96f8b3` | 2026-11-11 22:44:50Z |

What the guard protects: a profile that is being edited in a burst is not approved by an automation,
even when the individual row's own verdict is clean (Fable GO-WITH-NOTES (d) on core#10733). It is a
fraud/velocity gate. **It is not relaxed here, and it must not be.**

## What was wrong, and what changed

The defect was hydra-side: `policy.server_approval_refusal` mirrors core's ROW-level rules only, so
score-approve kept deciding `approve` for rows the low-risk automation can never accept, sent them,
read back the unchanged row, recorded `skipped:core_guard_refused`, and did it again 15 minutes later
for up to 7 days. The report then counted every one of those attempts as a decided-but-unclosed row.

Two changes, both in the executor and the report — no core change, no threshold moved, no proof waived:

1. **`scripts/credit_review/score_approve.py`** reads the guard's *effect* from the core replica
   (`live_profile_burst`: one statement for every profile of the run, before the anchors, bounded by
   `PROFILE_BURST_BUDGET_S`) and records the row as **`defer`** with the guard named:
   `profile_burst_hold: core's low-risk automation refuses this profile (notProfileBurstSql, Fable
   GO-WITH-NOTES (d) on core#10733): review_hourly_velocity_profile fired on request <sibling> created
   <at>; no request of this profile is approved before <date>`. The row is not sent, takes no cap slot,
   and the first run after that date approves it normally. An unreadable replica holds the row
   (`… could not be read this run … held, retried`) and is never a clear profile. A reason the clock
   answers is deferred, not held (`CLOCK_DEFER_PREFIXES`), so it never lands in a person's queue.
2. **`scripts/verification-queue-report.py`** counts the **newest apply-mode decision per request**, so
   a re-decided request is one row, and a request whose newest ruling is `defer`/`hold` is not
   "decided but not closed" at all.

Measured with the new reader against the live replica on node-8 (the deployed tree's package with only
`score_approve.py` replaced):

```
profiles read: 5
  3b051cd2-… -> review_hourly_velocity_profile on ea071cc8-… created 2026-11-14 01:01:44.519000 UTC
  5a85fee4-… -> review_hourly_velocity_profile on 3d59d092-… created 2026-11-12 22:42:59.720000 UTC
  7de70bd9-… -> review_hourly_velocity_profile on 82523a7a-… created 2026-11-14 12:16:46.805000 UTC
  85e98716-… -> review_hourly_velocity_profile on 4dd866ad-… created 2026-11-15 07:39:57.220000 UTC
  9cd08c43-… -> review_hourly_velocity_profile on b6716a4e-… created 2026-11-11 22:44:50.353000 UTC
example reason: profile_burst_hold: core's low-risk automation refuses this profile (notProfileBurstSql,
  Fable GO-WITH-NOTES (d) on core#10733): review_hourly_velocity_profile fired on request
  9e1aec54-288f-406c-842f-db3184fcdb1e created 2026-11-12 22:54:38.319000 UTC; no request of this
  profile is approved before 2026-11-19T22:54:38Z
rows the new executor would DEFER: 34 of 34
```

## Before and after

| | before | after |
| --- | --- | --- |
| `decided_not_closed` rows (7 d) | 1,036 | **34** (report fix, measured on the live ledger) |
| requests behind them | 34 | 34 |
| rows the executor re-sends every tick | 34 | **0** (all 34 deferred by name, measured above) |
| rows in the class once the executor runs | 34 | **0** — a `defer` is not a decision |
| core guard relaxed | — | **no** |

The 34 requests are approved by the first score-approve run after each profile's window lapses
(2026-11-18 → 2026-11-22), with no further change.

## What pins it

`scripts/tests/test_credit_score_approve.py` — `ProfileBurstGate` (the rule table: non-zero fires,
zero/null/absent does not, a non-numeric value fires; the 7-day window and the date it prints; the
reason names the rule, the sibling and the date; a row never holds its own profile; one replica
statement for every profile; an unreadable replica is never clear; **a successful but malformed
response — a truncated row, a verdict that is not JSON, a row naming no profile of the run — is
unreadable, never clear**) and `ProfileBurstDecisions` (a
bursting profile is deferred with the guard named and writes nothing; a deferred row takes no cap slot;
an unreadable read holds and is not cooled for 6 h; the run line reports the count).

`scripts/tests/test_verification_queue_report.py` — `DecidedNotClosed.test_a_request_re_decided_every_tick_is_counted_once`
(30 decision rows for one request count once; a request whose newest ruling is `defer` is not in the
class).

## Reproducing the measurement

```bash
# the ledger read (node-8, read-only)
ssh -i ~/.ssh/ovh_muso root@40.160.32.80 'python3 /tmp/rows.py'   # newest decision per request
# the guard's effect (node-8, the new reader against the live replica)
ssh -i ~/.ssh/ovh_muso root@40.160.32.80 \
  'cd /opt/hydra/scripts && PYTHONPATH=/tmp/newpkg:/opt/hydra/scripts python3 /tmp/probe.py'
```

Raw ledger rows are customer data and are not committed; the counts and the profile/request ids above
are the evidence.
