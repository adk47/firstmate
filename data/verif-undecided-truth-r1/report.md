# verif-undecided-truth-r1: hydra held no reader of `request_state` at `7944deb5a`

Written 2026-11-14 on branch `fm/verif-undecided-truth-r1`, cut from hydra `main` at `7944deb5a`.
This report is the lane's only change: no code was written and nothing on node-8 was written.

**Everything below "Finding" describes `7944deb5a`. It is no longer true of `main`**: see
"What changed on main afterwards" first.

## What changed on main afterwards (read 2026-11-15 at `babea62ec`)

The day this was written, `main` gained tracked code that reads and writes the table:

- `b0a2acd5e` (2026-11-14T17:24Z, https://github.com/Muso-AI/hydra/pull/1980) added
  `scripts/credit_review/request_state.py` (the node-8 file, now tracked: `transition()`,
  `backfill()`, both write `request_state` and `request_state_log`) and
  `scripts/credit_review/reconcile_approved.py`.
- `babea62ec` (2026-11-15T11:36Z, https://github.com/Muso-AI/hydra/pull/2021) added
  `scripts/credit_review/precedent_ledger.py`, whose `reconcile` moves precedent approvals to
  `APPROVED` through `request_state.transition()`. `scripts/install-aux-units.sh` installs
  `precedent-ledger-reconcile.timer` for it, and `docs/credit-verification/precedent-ledger.md`
  says it runs every 10 minutes.
- `reconcile_approved.py measure` prints the undecided count from core `credit_requests.status`
  and from `request_state` side by side, and `backfill` selects the ledger's undecided rows
  (`UNDECIDED = ("ASKED", "OPEN_UNASKED", "PROOF_RECEIVED")`).

So on `main` today the table has a scheduled writer in the repo and hydra has a reader of the
undecided count on both sides. The ruling this lane was given called the table dead; whether it
stays a counted source now that it is written again is not this lane's decision.

The firstmate checks moved too (read 2026-11-15; they are outside this repo). Two of the four
named under "Where the number comes from" now take the undecided count from core
`credit_requests.status`, with a comment dated 2026-11-14 saying why: `creds-goal.check.sh`
line 67 and `goals-status.check.sh` line 52 query `credit_requests where status in
(user_verification_needed, unverified, processing)`. Their older `request_state` lines are still
in the files, and `goals-status.check.sh` keeps the ledger count when the core read returns
nothing (`[ -n "$core" ] && und=$core`). Neither query filters on `deletedat IS NULL`, which
hydra's `owing_proof.REPLICA_SQL` and the 101,338 below do; I did not measure the difference.
`verif-pipeline.check.sh` and `verif-liveness.check.sh` are unchanged since 2026-11-13 and still
count `request_state`.

So the measurement change the ruling asked for is only partly in place. None of this needed a
hydra code change.

Two of the four checks read core, and both of them can still report the dead table's number:

- `creds-goal.check.sh` guards its core read with `if [ -n "$uvn$unv" ]` (line 74 of the file as
  it stands on 2026-11-15). When the core read fails or returns nothing, `asked`, `unasked` and
  `proof` keep the `request_state` values read at lines 47-48, and the check silently reports
  their sum -- the flat 78,528 measured on 2026-11-14 -- as the undecided count. That is the
  number the ruling says can never move.
- `goals-status.check.sh` has the same fallback at line 55 (`[ -n "$core" ] && und=$core`).
- `verif-pipeline.check.sh` and `verif-liveness.check.sh` still count `request_state`.

So the ledger read in those two checks is a live silent fallback, not a revert path: the check's
comment at `creds-goal.check.sh` line 66 calls it a revert ("no backup: revert = restore the
sqlite request_state sum in place of the core read"), and that is wrong. The fallback is an open
defect, escalated to the parent firstmate; it is not fixed here, and the goals number can still
silently regress to the dead table's count.

Not checked: whether `babea62ec` is deployed, whether the timer has run on node-8, and what
either count reads now. The measurements below are from 2026-11-14 and were not repeated.

Unchanged at `babea62ec`: none of the six files the brief names matches `request_state`, and
nothing under `scripts/sentinel` or in `policies/sentinel-capabilities.json` does
(`git grep -c "request_state" origin/main -- <those paths>` prints nothing).

## Finding (at `7944deb5a`)

hydra `main` at `7944deb5a` held no query against `request_state` or `request_state_log`, so
there was no reader in this repo to repoint at core `credit_requests.status`. The undecided
number came from outside this repo (see "Where the number comes from").

## The grep and its output

Run in this worktree at `7944deb5a`:

```
$ git grep -c "request_state"
scripts/tests/test_credit_removal.py:9
data/proof-processing-ovh-e1/baseline.md:2
data/node8-load-split-f1/evidence/02-volumes-and-stores-1112.md:1

$ git grep -n "request_state"
data/node8-load-split-f1/evidence/02-volumes-and-stores-1112.md:36:| `/var/lib/hydra/credit-review/ledger.sqlite3` | 873,021,440 | wal | 11-12 15:50 | decisions 1,012,654; decision_outcomes 317,111; request_state_log 104,576; request_state 92,861; verify_requests 75,023; reviews 35,517; verify_messages 12,891; decision_told 3,499 |
data/proof-processing-ovh-e1/baseline.md:69:| `request_state` | ASKED 61,228; OPEN_UNASKED 15,545; CLOSED_STALE 7,702; DUPLICATE 6,631; PROOF_RECEIVED 1,755 |
data/proof-processing-ovh-e1/baseline.md:70:| newest `request_state.entered_at` | 2026-11-11T04:27Z |
scripts/tests/test_credit_removal.py:83:                 request_state=(200, {"data": {"requestId": "req-1", "state": "checking"}}),
scripts/tests/test_credit_removal.py:89:                        "removal_request": request_state, "credits": credits, "probe": probe,
scripts/tests/test_credit_removal.py:351:            core = Core(request_state=(0, {"message": "wrapper timed out"}))
scripts/tests/test_credit_removal.py:531:            core = Core(request_state=(200, {"data": {"requestId": "req-1", "state": "removed"}}))
scripts/tests/test_credit_removal.py:540:            core = Core(request_state=(200, {"data": {"state": "listed"}}))
scripts/tests/test_credit_removal.py:551:            core = Core(request_state=(200, {"data": {"state": "kept"}}))
scripts/tests/test_credit_removal.py:599:            core = Core(request_state=(200, {"data": {"requestId": "req-1", "state": "listed"}}))
scripts/tests/test_credit_removal.py:662:            core = Core(request_state=(500, {"message": "boom"}))
scripts/tests/test_credit_removal.py:782:            core = Core(request_state=(200, {"data": {"state": "checking"}}))
```

- The two `data/` hits are measurement notes (row counts of the live ledger).
- The nine `test_credit_removal.py` hits are a keyword argument of a test double for the
  credit-removal API. It is unrelated to the ledger table.

The state names give the same answer. Outside `data/`, `OPEN_UNASKED` appears only in prose
(`AGENTS.md`, `docs/credit-verification/scale-drain.md`, a docstring and a SQL comment in
`scripts/credit_review/scale_drain.py`, a test docstring); `CLOSED_STALE`, `entered_at` and
`state_log` do not appear at all:

```
$ git grep -n -E "OPEN_UNASKED|CLOSED_STALE|entered_at|state_log" -- ':!data'
AGENTS.md:1181:  never-asked request falls through to `ask`: the 23,247 OPEN_UNASKED rows are the
docs/credit-verification/scale-drain.md:8:92,861 requests carry a declared state (ASKED 61,228; OPEN_UNASKED 23,247; DUPLICATE 6,631;
docs/credit-verification/scale-drain.md:169:through to `ask`, because the 23,247 OPEN_UNASKED rows are the drain's population, not
scripts/credit_review/scale_drain.py:39:never-asked request falls through to ``ask``: the 23,247 OPEN_UNASKED rows are the
scripts/credit_review/scale_drain.py:515:    -- customer-facing denial we do not do. The 23,247 OPEN_UNASKED rows are the drain's
scripts/tests/test_scale_drain.py:519:    The 23,247 OPEN_UNASKED rows are the drain's population, not its refuse pile.
```

## What the six named files contain

Each matches the word "undecided" and none reads `request_state`
(`git grep -n -i "undecided" -- <the six files>`):

| file | lines | what "undecided" means there |
| --- | --- | --- |
| `scripts/credit_retro/takeback.py` | 1065, 1083, 1096-1097 | a take-back pair no named human has decided (`withheld = "pair_undecided"`) |
| `scripts/credit_review/comm_state.py` | 1349, 1359 | prose in the message-choice rule: "a document on file, undecided, never receipted" |
| `scripts/credit_review/policy.py` | 290, 305 | a catalog-evidence verdict that needs the model (`needs_model=True`) |
| `scripts/credit_review/runner.py` | 309-310 | docstring: rows pass 1 did not decide go to the model in pass 2 |
| `scripts/credit_review/scale_drain.py` | 147, 626 | the reason code `proof_on_file_undecided` on an `ask` row |
| `scripts/credit_review/uvn_status.py` | 953-981, 1042, 1561, 1910 | `undecided_ids`, a user's live open requests |

Two of them already read core, not the ledger table:

- `uvn_status.py` builds `undecided_ids` from `postgresql_core.public.credit_requests` (line 946).
- `scale_drain.py` snapshots `postgresql_core.public.credit_requests WHERE status IN
  ('user_verification_needed', 'unverified') AND deletedat IS NULL` (lines 1604-1605).

hydra's sentinel reports no undecided count either:

```
$ git grep -n -i -E "undecided|open_requests|open requests" -- scripts/sentinel policies/sentinel-capabilities.json data/sentinel/README.md
(no output)
```

## Where the number comes from

Outside this repo. From this repo alone that is all that can be said: nothing tracked here
produces it.

Before the instruction to stop looking arrived, I had already read the following, read-only.
It is recorded here so it is not found a third time; I looked no further after that instruction.

Four firstmate checks in `/home/aaron/Projects/firstmate/state/` each ran a `sqlite3` count on
`request_state` over ssh to node-8 (as read 2026-11-14 at about 08:25Z):

| check | line | query |
| --- | --- | --- |
| `creds-goal.check.sh` | 47-48 | `select state, count(*) from request_state group by state`, then sums ASKED + OPEN_UNASKED + PROOF_RECEIVED |
| `goals-status.check.sh` | 45 | `select count(*) from request_state where state in ("ASKED","OPEN_UNASKED","PROOF_RECEIVED")` |
| `verif-pipeline.check.sh` | 35 | the same count (and line 34 reads `max(at)` from `request_state_log`) |
| `verif-liveness.check.sh` | 52 | the same count |

I did not find a sentinel or a report that prints the number, in hydra or in those four files.

## Measurements (read-only, node-8, 2026-11-14 08:25Z to 08:30Z)

| | value |
| --- | --- |
| old metric: `request_state` in ASKED, OPEN_UNASKED, PROOF_RECEIVED | 78,528 (61,228 + 15,545 + 1,755) |
| core open, `deletedat IS NULL` | 101,338 (`user_verification_needed` 79,749; `unverified` 21,587; `processing` 2) |
| newest `request_state_log.at` and newest `request_state.entered_at` | 2026-11-11T04:27:03Z |
| `request_state_log` actors, all one-off | `backfill` 73,627 (to 11-11 00:57Z); `sync` 23,247 (11-11 00:58Z); `decider-v1` 7,702 (11-11 04:27Z) |
| `state_transitions` (filled by the `rs_audit` trigger on any `UPDATE OF state`) | 0 rows |

The core figure was 101,014 when the captain ruled; it had grown by 324 by 08:30Z while the old
metric had not moved.

Writer search on node-8 (grep for the table name, then for `INSERT`/`UPDATE`/`DELETE`/`REPLACE`
statements against it, over `/opt/hydra/scripts`, top-level scripts under `/root`,
`/etc/systemd/system`, `/etc/cron.d`, `/etc/hydra`, `/usr/local/bin`):

- `/opt/hydra/scripts/credit_review/request_state.py`, `decider.py` and `funnel.py`: mode 700,
  dated 2026-11-11, not tracked in hydra. `request_state.py` and `decider.py` carry the write
  statements; no write statement matched in `funnel.py`.
- The only unit that runs any of them is `credit-decider.service` (`decider.py --apply`). Its
  timer `credit-decider.timer` is `disabled` and `inactive`.
- `/root/sync2.py`, `/root/age.py`, `/root/age2.py` write the table, and `/root/today1.sh` creates
  the trigger. `/root/backfill2.py` and `/root/recon.py` name the table and no write statement
  matched in them (the pattern needs the verb and the table name on one line). No unit or cron
  entry names `sync2.py`; I did not check the other five `/root` files by name.
- Nothing else under those paths names the table.

So the only scheduled writer found is disabled, and the log agrees: three actors, the last on
2026-11-11, and no `UPDATE OF state` since the trigger was installed.

How these were read: `sqlite3 -readonly 'file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro'`
for the ledger; one statement through `/opt/hydra/scripts/trino-query.sh` for core
(`SELECT status, count(*) ... WHERE deletedat IS NULL AND status IN ('unverified', 'processing',
'user_verification_needed') GROUP BY status`, 3.4 s); `grep`, `systemctl cat` and
`systemctl is-enabled` for the writer search.

## Not done

- No reader was repointed: none existed in hydra at `7944deb5a`, and the four checks are outside
  this worktree. `reconcile_approved.py measure`, added since, already prints the core count.
- `request_state` was not touched: no writer added, no backfill, no removal.
- For whoever repoints the checks: hydra already defines the open statuses once, with a guard
  that refuses the read on an unknown status (`scripts/credit_review/owing_proof.py`,
  `OPEN_STATUSES = ("unverified", "processing", "user_verification_needed")`, `check_statuses`).
  That set is the one behind the 101,014.
