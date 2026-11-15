# Precedent approvals in the credit-review ledger

`scripts/credit_review/precedent_ledger.py`. Tests: `scripts/tests/test_precedent_ledger.py`,
`scripts/tests/install-aux-units-precedent-ledger.bats`.

## What was wrong

precedent_v1 (prev2.js) approves a credit request in core's Postgres from inside a core-backend
pod. It wrote no row to the node-8 ledger's `decisions` / `decision_outcomes`, so every approval
count read from the ledger left its approvals out. `applied_1h` is one of them
(`decision_outcomes` with outcome `approved`).

Measured 2026-11-15:

- request `094355b2-19a8-4c44-af33-c8f6fd4f8b95`, approved in core at 07:36:55Z by run
  `prev-2026-11-15T07`, six precedent ids: no row for it in `decisions`;
- `decisions` rows with `evidence_kind = 'precedent'`: 0 of 1,139,905;
- `decision_outcomes` rows with outcome `approved`, all paths, all time: 723;
- precedent approvals in core, all time: 10,384.

## The two stores cannot share a transaction

The approval is a row in core's Postgres, written by a pod. The ledger is a SQLite file on node-8
that the pod cannot open. No commit covers both. The module gives an order instead, and a reader
that closes it:

| step | who | what |
|---|---|---|
| 1 `claim` | node-8, before the core write | one `precedent_claims` row per request the run is about to approve: run, request, the precedent it matched, `claimed_at` |
| 2 the core write | prev2.js, in the pod | not this module's, and never made from here |
| 3 `reconcile` | node-8, reads core read-only | closes every open claim: `landed` or `not_landed` |

`landed`: core holds the approval under the claim's run. The request gets its `decisions` row, its
`approved` outcome and its move to `APPROVED`, in the one SQLite transaction that closes the claim.

`not_landed`: core does not hold it 15 minutes after the claim (`NOT_LANDED_AFTER_S`; the read is a
replica, and a young claim with no approval is a write still on its way). The claim is closed with
what core said, and nothing else is written. An approval row exists only for an approval core holds.

A claim is its own table, and no approval count reads it. It is not an early `decisions` row
because `decisions` is append-only (triggers refuse UPDATE and DELETE) and seven readers act on a
request's newest row there. A claim whose write did not land would stay as that newest row for
good, an `approve` over the hold or the partial approval the request is still under.

## What runs today, and what does not

`precedent-ledger-reconcile.timer` runs `precedent_ledger.py reconcile --since-hours 6` every
10 minutes. Besides the open claims it reads every precedent approval core changed in the window
and writes each one's row. That is step 3 without step 1, and it is what records approvals today.

Nothing runs step 1 yet. node-8 runs `/root/prev2.js`, a file in no repository; its tracked copy is
https://github.com/Muso-AI/hydra/pull/1967 and it prints no plan line. The unit that would run
claim, prev2.js and reconcile in order is a host file too. A fix that lives only on the host is the
same class of problem as the ledger gap. When prev2.js is tracked, it prints one line before its
UPDATE and the unit feeds it to `claim`, starting the core write on exit 0 and on nothing else:

```
{"marker": "PREV2_PLAN", "run": "<run>", "batch": [{"id": "<request>", "precedent_ids": ["..."]}]}
```

Until then a precedent approval has its row within one timer period of the replica showing it, not
before the write.

## What a row carries

`decisions`: `run_id` (core's `metadata.approval.run`), `decided_at` (core's `approval.at`, never
the time the pass ran), `request_id`, decision `approve`, mode `apply`, `evidence_kind`
`precedent` (the path), and in `reason` the precedent it matched. `decision_outcomes`: action
`approve`, outcome `approved`, `at` the same time. So an approval is in `applied_1h` for the hour
after core approved it, and a backfilled one is in no later hour's count.

`profile_id` and `user_id` are NULL on purpose. A profile id would put the request in
`verify_notify`'s customer-note audience; a user id would count it against the decider's per-user
daily caps. Both are pinned by tests.

Which precedent: a claim names its request's own precedent ids. Core does not. prev2.js writes the
whole batch's precedent sets into every row of the batch, with nothing saying which set is whose.
A row written without a claim names its ids only when its batch was one request; otherwise its
reason says how many sets core recorded.

## The backfill

```
python3 /opt/hydra/scripts/credit_review/precedent_ledger.py backfill            # the plan; writes nothing
python3 /opt/hydra/scripts/credit_review/precedent_ledger.py backfill --apply    # inserts what is missing
python3 /opt/hydra/scripts/credit_review/precedent_ledger.py report              # live rows, rows per batch, claims
```

It reads every precedent approval core holds, read-only, and inserts a row for each one the ledger
lacks. Every inserted row's reason ends with ` [backfill <batch id>]`; a live row never does. A
second run inserts zero and reports them as `already_present`. An approval core no longer holds
(taken back, or the row deleted) gets no row and is counted in its own class. The whole core read
finishes before the first insert, the inserts are one transaction, and a read that skipped a slice
writes nothing (exit 4).

The read cannot be one statement. The replica cancels a statement at 60 s: the whole-table filter
on `metadata.approval.via` does not fit and neither does a 30-day window. The read walks
`updatedAt` in 6 h slices, halves a slice the replica cancels, and at 15 minutes lists the changed
ids (which opens no metadata) and asks about those by id.

### Measured 2026-11-15

The core read ran against the live replica (read-only, 78 statements). The inserts ran against a
scratch ledger built from the live schema, never the ledger on node-8: this change is not deployed
and the production backfill has not been run.

| | count |
|---|---|
| precedent approvals core holds, all time | 10,384 (all `approved`, 0 deleted, 0 without a time) |
| plan against the production ledger's 0 precedent rows | 10,384 missing, 0 already present |
| first `--apply` on the scratch ledger | 10,384 inserted, 0 already present |
| second `--apply`, another batch id | 0 inserted, 10,384 already present |

By day of approval: 9,465 on 11-10, 368 on 11-11, 121 on 11-12, 324 on 11-13, 97 on 11-14, 9 on
11-15 (to 07:36Z). None before 2026-11-10.

## Which run a row names

9,465 of the 10,384 are two UPDATEs of 2026-11-10 (4,396 rows at 12:22:56Z, 5,069 at 12:38:44Z)
whose `approval` object has no `run` key: prev2.js did not write one yet. Their rows carry
`prev-unnamed-<approval time>` as the run id, which names the batch because one UPDATE stamps all
of its rows with one `now()`, and the reason says core recorded no run name. The other 919 carry
core's run name (66 runs, the first on 2026-11-11T17:01Z). A run name that is not one (anything
outside letters, digits and `_.:+-`) is `unreadable_approval` and gets no row.

Only 52 of the 10,384 name their own precedent ids, the ones whose batch was one request.

## Stops and failures

- `/etc/hydra/precedent-ledger.disabled`: the scheduled `reconcile` reads nothing and writes
  nothing (exit 0). It does not stop `claim`.
- Exit 4, core not read: nothing was written. The service is in the OnFailure table.
- Exit 3, the ledger refused the open or the write. Exit 2, no plan or result line.
- A `decisions` row cannot be removed (the table is append-only). A row written in error is
  answered by a later row for the request, the way every other writer of the table does it.
