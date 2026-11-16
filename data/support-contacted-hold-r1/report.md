# The support@ hold in the credit decider: what it held, and what removing it does

Measured read-only on node-8 (`/var/lib/hydra/credit-review/ledger.sqlite3`, deployed `46fa7f007c50`),
2026-11-14 20:00Z (counts) and 20:28Z (replay). Counts only; no request or user id left the host.

## The count

```sql
SELECT count(*), count(DISTINCT request_id), count(DISTINCT user_id), min(decided_at), max(decided_at)
FROM decisions WHERE instr(reason, 'emailed support@ in the last 90 days') > 0;
```

| | rows | requests | users |
|---|---|---|---|
| all rows carrying the reason | 3,420 | 954 | 69 |
| `mode = 'apply'`, `decision = 'hold'` | 1,236 | 242 | 2 |
| `mode = 'judge'`, `decision = 'hold'` | 2,184 | 713 | 68 |

First row 2026-10-17T23:30Z, last 2026-11-14T19:30Z. Every row has the one reason text
`emailed support@ in the last 90 days: human review, never asked (when in doubt, don't send)` and
`decision = 'hold'`; none is a per-role (`approve_partial`) row. `reason LIKE '%support%'` matches 148,912
rows, most of them other reasons.

3,420 is rows, not people. A held request was decided again about once a day and held again, so 954
requests from 69 users produced 3,420 rows.

## Where the hold was

Not in the ladder. `filter_support` runs after the ladder, on rows the ladder already decided to ASK
(`decision == "support"`) or to split per role. Its `elif proof.contacted_support(d)` branch turned those
into the hold. So every one of the 3,420 rows was an ask the ladder had reached; no approve and no deny
was ever blocked by it. `ASK_HOLD_MARKERS` is read only by `uvn_status.partial_pending_roles`, for per-role
rows, of which this reason has none.

## The replay

`tools/dry_run.py`, run on node-8 as a file. Population: the requests whose newest decider row is still
this hold. For each one still `unverified` in core it rebuilds the ask and runs the deployed
`filter_support` twice: as deployed, and with `contacted_support` answering False, which is what the
change does.

```
at 2026-11-14T20:28:00Z deployed 46fa7f007c50 filter_support sha256 de8e3794a936
requests ever held on the reason: 954; newest row is still that hold: 490 (47 users)
core status today: {'user_verification_needed': 246, 'unverified': 231, 'approved': 12, 'deleted': 1}
still listed by the decider (unverified): 231 (38 users)
proof status: readable
caps: 100 users/run, 400 users/day
-- as deployed (control)
     208 requests /  30 users  hold     emailed support@ in the last 90 days
      20 requests /   7 users  hold     proof on file: human review
       3 requests /   2 users  hold     proof on file: stage 2 judged the document
-- with the support@ hold removed
     208 requests /  30 users  support  ask stands
      20 requests /   7 users  hold     proof on file: human review
       3 requests /   2 users  hold     proof on file: stage 2 judged the document
```

Read as:

- 464 of the 954 requests already have a newer row with another reason. This change does not touch them.
- Of the 490 still parked, 259 are no longer `unverified` in core (246 are already
  `user_verification_needed`, 12 approved, 1 deleted). The decider lists `unverified` only, so it will not
  decide them again whatever this change does.
- 231 requests of 38 users are still listed. 208 of them (30 users) become an ask. 23 (9 users) are held
  for a document on file, which is the rung above the one removed. None becomes an approve or a deny,
  because the ladder had already chosen to ask.

## What a user experiences

Nothing yet. The production cron runs `credit-review.py decide --mode judge`, which records the verdict
and writes nothing to core. After this change the 208 rows are recorded as `support` instead of `hold`.

If the decider is run in `--mode apply`, those rows are support writes: up to 208 requests of 30 users
move to `user_verification_needed`, within the 100 users/run and 400 users/day caps they share with every
other ask.

## What the replay does not show

- It does not re-run the ladder. A request whose evidence changed since its last row may get another
  verdict on the next run.
- The replay holds only these rows, so the caps were theirs alone. 30 users is under both caps.
- Only the decider. `verify_notify`, `claim_proof_ask`, `uvn_status` (stale Gmail part) and
  `score_approve` each hold a support@ contact on their own and are unchanged, so no note from those
  senders reaches these users, and nothing here posts on a support thread.
