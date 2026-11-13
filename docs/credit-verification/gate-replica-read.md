# The send gate's per-person replica read

`scripts/intercom-verify-request.sh` (the send gate) checks one person per call. Two of its helpers read the core
replica: `credit_review/core_notice.py` (the 7-day core-notice cooldown) and `credit_review/comm_state.py` (what the
person owes, what we already told them, the fraud lens). Each asked the replica its own questions, one
`trino-query.sh` call per question.

The gate now asks the replica ONCE per person and both helpers are answered from that read. No rule, bar, timeout
or cap changed: the unmeasured bar is still `max(5, 10% of the batch)` and the read timeout is still 20 s.

## What was measured (node-8, 2026-11-12/13)

Same list, same page (`--start-entry 762 --max-entries 200`), same `--max-users 50`, the deployed `uvn-status` paid
check in `--mode dry-run --check-recipients`, under a process sampler
(`data/node8-fly-gate-v2/tools/proc_sampler.py`; summaries in `data/node8-fly-gate-v2/evidence/`).

A `trino-query.sh` call costs about 2.1 s, of which about 1.85 s is fixed: `kubectl get pods`, `kubectl exec`, and
the Trino CLI's JVM. `SELECT 1` costs 1.85 s. So the cost of a gate call was the NUMBER of questions, not the
questions.

| 4 read-only workers (what the tick runs) | before | after |
|---|---|---|
| gate call, s per person: mean / p50 / p90 / max | 11.87 / 14.95 / 19.98 / 20.03 | 7.16 / 6.23 / 12.35 / 18.97 |
| replica round trips per person | 4.30 (max 6) | 1 |
| replica wall per person | 9.32 s (78.5% of the call) | 3.70 s (51.7%) |
| gate calls at the 20 s read timeout | 6 | 0 |
| unmeasured / bar | 5 / 5: UNMEASURED STOP | 0 / 5 |
| would be messaged | 1 (stopped early) | 10 |

| 1 read-only worker | before | after |
|---|---|---|
| gate call, s per person: mean / p50 / p90 / max | 13.47 / 15.16 / 20.03 / 20.03 | 6.23 / 5.80 / 10.88 / 18.80 |
| replica round trips per person | 4.97 (max 6) | 1 |
| replica wall per person | 10.25 s (76.1% of the call) | 2.91 s (46.7%) |
| gate calls at the 20 s read timeout | 5 | 0 |
| unmeasured / bar | 5 / 5: UNMEASURED STOP | 0 / 5 |
| would be messaged | 0 (stopped early) | 10 |

Across the two "after" runs the helpers asked 297 replica statements; all 297 were answered from the read (about 0.05 s
each) and none fell through to a live round trip. For 10 people of that page (8 the check accepted, 2 it deferred
on the core-notice cooldown) `core_notice.py check` was run both ways on node-8, served and live: 10 of 10 identical,
both holds included.

The runs are the same list and page hours apart, so the people are the same and their state is not: a "before" run
stopped at its fifth unmeasured person, and by the "after" runs some cooldowns had lapsed and some people had been
messaged by a real tick. The per-person seconds compare; the outcome counts are not a like-for-like diff.

The 4-worker "after" run had the host busier (load 7-9 against 3.7) and still finished the page.

What is left in a gate call after this change, per person (4 workers): the one replica read (3.6 s), Intercom reads
(1.3 s mean, 7.6 s on the slowest person, who had 37 of them), and bash / jq / Python start-up / our own SQLite
stores (2.2 s).
The slowest call was 18.97 s, and Intercom, not the replica, was most of it. That is the next thing to shorten if
calls approach the timeout again; it is not addressed here.

## How it works

1. `credit_review/gate_facts.py read` lists every replica statement the two helpers will ask about this person and
   sends them to `trino-query.sh` in ONE invocation (`credit_review/replica_batch.py read_many`). A sentinel row
   carrying a random nonce closes each statement's rows. Anything short of every sentinel, in order, with exit 0
   is a failed read: there is no partial answer.
2. The gate writes that read to a file in a root-only tmpfs directory (`/run/hydra/gate-facts`, mode 700), removed
   when the gate call exits. A file a SIGKILL left behind is swept by the next call after 2 minutes.
3. The gate runs the two helpers UNCHANGED, with `scripts/replica-serve.sh` as their replica command
   (`CORE_NOTICE_TRINO`, `COMM_STATE_TRINO`) and `REPLICA_BATCH_FACTS` naming the file. For each statement a helper
   asks, `replica-serve.sh` answers from the read when it holds that EXACT statement text and the read is at most
   `replica_batch.MAX_AGE_S` (30 s) old; otherwise it becomes the real `trino-query.sh` (exec) with that statement.

So the read cannot change an answer:

- no read, a failed read, a stale read, a malformed read: every statement is read live, as before;
- a statement the read does not hold (a helper changed, a rare branch): that statement is read live;
- a statement names its user id, so one person's read cannot answer a question about another;
- nothing is evaluated in `gate_facts.py`: the rules stay in `core_notice.reasons_by_user` and `comm_state.check`.

Our own stores (ledger, proof, doc-verify, account holds) and Intercom are never in the read.

## What a failed read costs

Time, inside the gate call's own 20 s read timeout, before the first helper runs:

- a read that fails at once (replica refuses, a statement errors): its own round trip, about 2 s;
- a read that never answers: `replica_batch.BATCH_TIMEOUT_S`, 8 s, then every statement is read live.

The read asks `comm_state.py`'s statements before `core_notice.py` has run. Before this change a person
`core_notice.py` holds never had those statements asked at all, so a stall in one of them could not touch that
person. The bound is sized for that person: 8 s + two live round trips (4.4 s) + the rest of a gate call (2.5 s) =
14.9 s. It first shipped at 15 s, where the same person took 19.7 s before any of the rest and would have been
left unmeasured (QA on PR 1926; `test_gate_facts.py` reproduces it and pins the sum against
`verify_notify.READ_TIMEOUT_S`).

What the bound does not save: a person who needs all of the live reads (12 to 13 s measured) after a read that
stalled for the full 8 s is over 20 s and unmeasured. Before this change that person made 5 to 6 separate replica
calls, any one of which stalling had the same result.

Of the 114 reads measured on node-8, the slowest took 6.12 s (4 workers, load 7-9) and the median 3 s; none came
within 1.8 s of the bound. A read slower than 8 s that would have answered by 15 s is now abandoned.

## What is deliberately not in the read

A reply-due answer's own reads, the doc-verify follow-up (it depends on our own store), and the "nothing is
needed" re-check of a rendered body. They are rare and stay live.

## Why the statement texts of two helpers are copied into `gate_facts.py`

`core_notice.py` and `comm_state.py` are not touched by this change. On 2026-11-12 node-8 ran hand-edited copies of
both (and of 7 other files), and a deploy stops on a file whose server copy matches neither the last deployed
commit nor the new one (`scripts/lib/delta-sync.sh`). Changing either file would have put this fix behind that
conflict. The price is that the text of their statements lives in two places. `scripts/tests/test_gate_facts.py`
runs the real helper functions against a recording replica and fails when a helper asks a statement
`gate_facts.plan` does not list. Until such a failure is fixed, a drifted statement costs one live round trip and
nothing else.

The fraud lens and the approval-path read are imported, not copied: `fraud_lens.Lens.statements` and
`uvn_status.uvn_requests_sql` are the same builders the live reads use.

## Pinned paths

A deployed gate takes the reader, the server and the directory from constants (`PROD_GATE_FACTS_HELPER`,
`PROD_REPLICA_SERVE`, `PROD_GATE_FACTS_DIR`); the test seams are refused on a deployed copy. `replica-serve.sh` and
`gate_facts.py` find `trino-query.sh` and `replica_batch.py` from their own location, never from the caller.

## Reading it on node-8

```bash
# why a read fails (the gate discards this message and reads live)
/usr/bin/python3 -I /opt/hydra/scripts/credit_review/gate_facts.py read \
    --campaign uvn-status --copy uvn --user-id <id> --request-ids x >/dev/null

# is a helper being served? ~0.1 s with a read on file, ~4 s live
F=$(mktemp -p /run/hydra/gate-facts); /usr/bin/python3 -I /opt/hydra/scripts/credit_review/gate_facts.py read \
    --campaign uvn-status --copy uvn --user-id <id> --request-ids x > "$F"
time CORE_NOTICE_TRINO=/opt/hydra/scripts/replica-serve.sh REPLICA_BATCH_FACTS="$F" \
    /usr/bin/python3 -I /opt/hydra/scripts/credit_review/core_notice.py check --user-id <id>; rm -f "$F"
```

The tick's own number is in every check outcome file: `unmeasured_users` against `unmeasured_stop_at`.

## Revert

Revert the commit and deploy. With `gate_facts.py` or `replica-serve.sh` absent from the host the gate takes no
read and both helpers read live, so removing either file by hand is also a complete revert of the behaviour.
