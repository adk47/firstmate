# Proof asks from the cluster: where it stands, the caps, and the plan off node-8

Lane `verif-sender-cluster-scale-k1`, 2026-11-13. Decision (firstmate, 22:1xZ): **A now, then B.** A is the
bounded pool in the existing node-8 path. B is the sender off node-8, in three PRs. This change is PR 1 of B, plus
this page and `readback.py`. It builds no sender and sends nothing.

## The captain's three questions

| Question | Answer | Source |
|---|---|---|
| Are we sending proof requests at scale? | No. One hourly tick. Proof asks run last in it, 6 at a time, and examine at most 400 people a tick. | "The caps that bind today" below. |
| Is the sending code only on node-8? | Yes. | `cv-outbound-tick` is the one cluster copy. It is pinned to `ovh-node-8` and runs in `preflight` mode, which cannot send. |
| Is it scaled on other nodes? | No, and it cannot be yet. | "Why a shared ledger is not enough" below. |

## A, as read at 23:23Z

| Piece | State |
|---|---|
| https://github.com/Muso-AI/hydra/pull/1952 (the pool) | Merged 22:08Z, **not on node-8**. The 22:53Z deploy was refused at 23:01:00Z by the deploy's own send-tick hold (`tick-not-yet-started-for-this-boundary`, 900 s budget spent); it changed nothing. A second run started 23:01:41Z and had not finished. The last successful deploy (21:22Z, `7210fe013`) predates the pool, so node-8 is on the serial walk. |
| https://github.com/Muso-AI/H-DevOps/pull/5254 (the tick as a CronJob) | Merged 22:24Z. The pod now runs image `288c812-c5510a3`, which has the pool. It is still `preflight` only and still fails `policy-armed-families`: `armed_families` is not in hydra `main`. |
| https://github.com/Muso-AI/H-DevOps/pull/5295 (node-8 memory cap) | Merged. I did not check that the cap is applied on the host. |
| **Kill file on node-8** | **Present** at 21:30Z, 22:25Z and 22:30Z; absent at 20:30Z. Read from the preflight's `host-kill-file` line in four pods. The 22:30Z pod is the newest, so nothing here is later than that. While the file is there the node-8 tick sends nothing. |

The preflight checks two files, `/etc/hydra/credit-verify-outbound.disabled` and the fallback copy under the tick's
state directory, and does not say which it found. Firstmate reported the kill file removed at 21:38Z. Either one of
the two was left, or something wrote it again. I cannot read node-8 from this box and did not touch either file.

**The pool does not speed proof asks.** It is 8 wide for `uvn-status` only (`uvn_status.py` is the one caller that
hands `send_all` a pipeline). `proof-need-ask` and `claim-proof-ask` go through `send_all` without one, which is 6
wide (`verify_notify.APPLY_WORKERS`). My earlier figure of about 1,370 an hour for A was wrong for asks.

## The caps that bind today

Repo values at `3860c01ad`. node-8 keeps its own policy file, which differed from the repo on 2026-11-12
(`data/verif-bulk-throughput-v1/design.md`); I could not read it.

| Limit | Value | Where | Binds proof asks how |
|---|---|---|---|
| Page walked per segment per tick | 200 entries | `credit-verify-outbound.sh` `CHECK_ENTRIES` | Two segments (free, paid): at most 400 people examined a tick. **This binds first.** |
| Accepted per segment per tick | 250 | same file, `CAP`, `CLAIM_CAP` | 500 a tick for `proof-need-ask`; never reached behind a 200 page. |
| Credit notes per UTC day, four campaigns together | 2,500 | `policies/credit-verify-outbound.json` `shared_daily_cap.credit` | Two 1,000-ask hours are 2,000 of it. |
| Claim notes per UTC day | 500 | same file, `shared_daily_cap.claim` | `claim-proof-ask` cannot reach 1,000 in any hour. |
| `uvn-status` free per tick | 60 | same file, `tick_cap` | Not an ask. Listed because the pool's family is the one with the tightest cap. |
| Width | 6 | `verify_notify.APPLY_WORKERS` | 1,000 sends in an hour at 6 wide needs 21.6 s a person or less. |
| Order | last in the tick | `need_families()` comment | Gets what is left of the 6,000 s tick budget. |

Seconds per person for a proof ask are not measured by this lane. The two figures on file are 21 s (the
`uvn-status` walk, #1952) and about 50 s (one need-ask segment, the comment above `need_families()`). At 6 wide
those are about 1,030 and 430 an hour. Whether the free segment sends at all depends on `UNSIGNED_FROM` on node-8,
which I could not read. The list gate (4,852 listed, 0 messageable) is another lane's and comes before all of this.

**At today's values 1,000 proof asks an hour is out of reach for any sender, on node-8 or off it.**

### The ladder

One knob per rung, one PR per rung, each citing three consecutive clean ticks at the rung before. The rung values
are my proposal, not a ruling. No cap is raised in this change. Rungs 1 and 2 are edits to the tick script, not
policy lines: the page size is chosen in `page_entries`, and `tick_cap` can only lower a family below `CAP`.

| Rung | Change | Most asks a tick after it |
|---|---|---|
| 0 | today | 400 examined |
| 1 | need-ask page 200 to 600 a segment, the size `uvn-status` free already walks | 500 (the 250 cap now binds) |
| 2 | 500 accepted a segment for `proof-need-ask` only. That needs a per-family cap that can exceed `CAP`, which the tick does not have; raising `CAP` itself would widen every family that shares it. | 1,000 |
| 3 | `shared_daily_cap.credit` above 2,500 | two 1,000 hours fit beside the other three families |

Rung 3 is the one that needs its owner. The repo describes 2,500 as the send-gateway warm-up ceiling for email
(#1952's body, `docs/credit-verification/bulk-send-queue.md`). Proof asks leave through Intercom. Whether that
number should bind them I did not resolve.

A clean tick, every line read from a record:

1. `readback.py --since <the tick's day>T00:00:00Z` reports no `duplicates` entry for the tick's UTC day
   whose rows are both from that tick and whose `cross_identity` is false (a candidate identity a single row
   supplies). An entry with `cross_identity: true` combines one row's email with another row's user id, so it is
   not evidence of a second note to one person and does not fail the tick. **2026-11-14 does not pass this
   criterion**: 16 people carry two notes that day (32 rows; the earlier output shape listed those as 32
   entries, today's lists one entry per matched row set). All 32 rows are campaign `backlog-reply` (sender `scripts/intercom-backlog/send.py`, not a proof ask), each
   pair is one conversation with the first row 19:51Z-19:57Z and the second 21:35Z-21:50Z, and every second row's
   `approval_ref` reads "firstmate 2026-11-14T21:01Z correction of run 1 no-account" - a recorded correction send
   by another sender, not a proof ask. Why that sender's own `capped()` check did not hold the second note was not
   investigated.
2. No `verify_messages` row from the tick is still `attempted` after it ends.
3. `run.log` has no `AUTO-KILL` and no `UNMEASURED STOP` for the tick, and no kill file exists after it.
4. The tick ended before the next one was due.
5. For `claim-proof-ask`: `apply_queue.py verify` shows `requests_with_two_notes`, `orphans` and
   `sent_without_ledger_row` all 0.

If a rung's ticks are clean but slower than 21.6 s a person at 6 wide, the next step is code, not a cap: the
pipeline #1952 gave `uvn_status.run`, for `need_asks`.

## B: three PRs, in this order

| # | Repo | What | Risk | Undo |
|---|---|---|---|---|
| 1 | hydra, **this change** | The production send ledger is never created by an open. | Low. See below. | Revert the commit. |
| 2 | hydra | One service beside the stores. It answers exactly the calls the gate makes: the ledger subcommands (through the unchanged `verify_ledger` functions, so one at-most-once rule), the proof-on-file read, the copy-verdict check, the api-log append, the kill-file read. Selection and gates stay in one planner where the stores are; only the per-person gate call moves. Ships in shadow: the tick asks both, logs any difference, uses the local answer. | Medium to high. It puts a network hop inside the at-most-once rule. A reply lost after `claim` leaves an `attempted` row with no outcome, which nothing re-sends: that costs asks, never a duplicate. It must accept only the workers' identity. | Stop the service; nothing depends on it in shadow. |
| 3 | hydra and H-DevOps | A pinned cluster mode in the gate, chosen by a constant in the image and never by an env var or flag. The worker Deployment: 8 pods, HPA to 32, a memory limit on each, off node-8. Dry run, then a capped 200 read back with `readback.py`. | Highest. It edits the block that refuses every override (gate lines 562-567). That needs a ruling before it is written. | Scale the Deployment to 0; the node-8 tick is untouched. |

The order is fixed by one fact: PR 3 makes it possible to run a gate where no ledger is, and before PR 1 that gate
answered "never messaged" for everyone.

https://github.com/Muso-AI/hydra/pull/1503 (open 15 days) moves the ledger to Postgres. If it lands first, the
ledger part of PR 2 is a client of that instead. I read its file list, not how complete it is.

## PR 1: what it changes

Measured at `a73c8e68f`, helper run against a path that does not exist:

| Call | Before | After, at the production path |
|---|---|---|
| write-mode `pending` (what a live send asks) | exit 0, `daily_cap: false`, `user_done: ""`; file created, 73,728 bytes, 0 rows | exit 2, nothing on stdout, nothing created |
| `claim` | claims in the new file | exit 2, nothing created |
| `migrate` (the tick runs the same open before its lock; `deploy.sh` runs this) | exit 0, `result: ok`; file created | exit 2, nothing created |
| `--readonly pending` (dry run, recipient check) | exit 0, the same answers, nothing created | unchanged |

- `verify_ledger.connect()` raises `LedgerAbsentError` at `/var/lib/hydra/credit-review/ledger.sqlite3` when the file
  is missing or has no `verify_messages` table. A ledger that has the table is opened and upgraded as before.
- Every other path is created on open as before. That is what every test and scratch ledger uses.
- `verify_ledger.py init` is the one creation. It leaves a ledger that already has a send record byte-identical,
  and it logs who ran it to stderr (the journal is the record; the ledger carries no provenance table). It refuses
  an existing file that holds tables but no send record — a restored backup from before the send record existed —
  because an empty send record beside the decider's history answers "never messaged" for everyone. On a new host
  `init` therefore has to run before anything else creates the file at that path: the decider creates the ledger
  file on its first run and can no longer add the send record itself.
- `verify_ledger.ensure_schema()`, the creator every caller with its own handle funnels through (`decide.py` opens
  the shared file with `credit_review.ledger`'s handle), refuses at the production path on the same terms, so the
  decider cannot start the send record either.
- The gate was not edited. Its existing line, "the ledger read failed; refusing to send without the idempotency
  record", already ends the send when the helper fails.
- The path is one literal. The gate and the tick are pinned to the same literal outside their test harnesses, and a
  test resolves it by running each consumer instead of reading its text.

**What it does on a host with no ledger.** The tick's open before its lock fails, and the tick's existing handler
writes the kill file and pages ("ledger migration failed"). `deploy.sh` logs its existing warning, which now carries
the refusal and names `init`. Before, both went on with an empty ledger. I ran the tick's own open command (line
616) against a mirror: exit 1, nothing created, which is the condition its handler on line 617 acts on. I did not
run the whole tick against a missing production ledger.

**Why node-8 is not affected.** Its ledger has the table and rows (#1952 cites rows 13694-13714; the preflight
reads 29 tables). I did not read node-8's ledger myself.

**What is still open after it.** The read-only open (dry run, recipient check) still answers from an empty schema
when the file is missing (re-run after the change: exit 0, the same answers, nothing created). It cannot send. Three gate checks still sit behind `[ -f "$LEDGER" ]` (lines 2783, 2791,
2909); with PR 1 the send is refused before it reaches them.

### Proof

| Check | Result |
|---|---|
| `scripts/tests/test_verify_ledger_contract.py` — the opener suites (`OpenerTests` 14, `PinnedPathTests` 2, `RealEntrypointTests` 5) | 21 pass, the same count this lane's opener suite had as its own file; the whole file is 37, and pytest collects the same 37. Folded in, not wired as a new file: see "Where these tests live" below. |
| `scripts/tests/test_verify_ledger_contract.py` — the read-back suite (`ReadbackTests`) | 11 pass: the pair `capped()` refuses with no shared identity column is reported; a one-note day reports nothing; a pair dated before a non-midnight `--since` is cap history and not a violation; every entry names its rows and nothing else; the real entrypoint prints no email and no user id. Folded in with the rest. |
| `verify_ledger.ensure_schema` at the production path, on a decider-style handle that already created the file | Refused with `LedgerAbsentError`, still only the decider's tables (3 cases). |
| The gate's own resolved ledger path, run through a stub helper that records the `--db` it was handed | equals the value the real module prints for `PRODUCTION_PATH`, with `CREDIT_REVIEW_LEDGER` and `CVO_LEDGER` set elsewhere; 0 POSTs. |
| The whole gate, in bats, with a mirror helper whose one literal is this test's ledger path | Refuses, exit 2, 0 POSTs, no file. The same send through the unmodified helper posts 1. |
| Four hand mutants (guard off; table check off; symlink not resolved; `init` not stopping at an existing ledger) | Each fails a named test. File restored byte-identical. |
| Suites that open the ledger: `test_uvn_status` 477, `test_credit_verify_notify` 189, `test_claim_proof_ask` 63, `test_verify_ledger_migration_race` 16, `test_apply_pipeline`, `test_apply_queue`, `test_ledger_open`, five more `test_verify_ledger_*` | Pass. |
| `intercom-verify-request.bats` and `credit-verify-outbound.bats`, whole files | 273 of 273 and 141 of 141 pass, none skipped. Run before the rebase onto `3860c01ad`. |

The gate bats case's mirror differs from the checked-in helper by that one line, and the case asserts it.

**Where these tests live.** Both suites are inside `scripts/tests/test_verify_ledger_contract.py`, a file PR
Validation already runs, instead of two new files with their own `python3 scripts/tests/<file>.py` lines. Adding
those lines puts `.github/workflows/pr-validate.yml` in this PR's changed set, and the `Rebase staleness check`
step fails any head that is behind a `main` which also moved that file — which is nearly all of them, since almost
every lane appends a line to it (12 of the 40 commits on `main` in the 24 h to 2026-11-16 11:15Z touch it). With
the fold, this PR's file set no longer intersects the churn: measured on the same window, `verify_ledger.py` 2 and
`scripts/tests/intercom-verify-request.bats` 2, `deploy.sh` and this report 0. `python3
scripts/tests/test_verify_ledger_contract.py` runs 37 and `pytest` collects 37, so the direct-invocation path CI
uses is the one that runs them.

## The four suspended CronJobs: none is safe to resume

All four have been `suspend: true` since they were created 16 days ago. They shipped suspended on purpose in
https://github.com/Muso-AI/H-DevOps/pull/4524 (merged 2026-10-28, "all 17 CronJobs are suspended").

| CronJob | Resume now? | Why |
|---|---|---|
| all four | No | Their image is `hydra-tools:pending-t2`, which the registry did not hold when I read it (21:4xZ, four other tags, through the API server proxy to `zot-registry`). A resumed job fails at image pull. |
| `cv-verify-notify` | No | Its kill key `credit-verify-notify.disabled` is still in ConfigMap `hydra-kill-switches`. It would also run on `ovh-node-29` against PVC `hydra-var`, created 10 days ago. I did not read that volume. If it has not been re-seeded, its ledger is 10 days behind node-8's and the job would message people node-8 has messaged since. |
| `cv-proof-intercom`, `cv-doc-verify`, `cv-proof-stage2` | No | Each has a blocker in H-DevOps `k8s/prod/hydra/cronjobs/README.md`: attachment media off node-8, a shard filter and a multi-writer store, the OCR sandbox measurement. I did not re-check whether any has cleared. |

None of the four sends the proof ask. Nothing was resumed, so there is no resume PR.

## Why a shared ledger is not enough

A worker that runs `intercom-verify-request.sh` off node-8 needs six node-8 stores, not one. Line numbers are from
`a73c8e68f`.

| Store on node-8 | How the send path uses it | Where |
|---|---|---|
| Verify ledger | Every claim and finalize, through one `ledger()` function | gate 715-719 |
| `proof.sqlite` | "A document is on file", four reads | gate 1512, 1830, 3135, 3436 |
| Copy-verdict store | The outbound copy gate's check | gate 3940 |
| api-log directory | Written before every POST | gate 891 |
| `/etc/hydra` kill files | The per-campaign stop | gate 1902 |
| doc-verify store | `need_asks.py` issues each ask's code into it | `need_asks.py` 464 |

The ask senders also open a local SQLite file on 35 lines outside the gate (`need_asks.py` 3, `claim_proof_ask.py`
4, `uvn_status.py` 11, `verify_notify.py` 10, `apply_queue.py` 7). That is why PR 2 keeps selection in one planner
beside the stores and moves only the gate call.

## The read-back, for whoever runs the capped 200

`readback.py` beside this page. Two statements: asks sent per UTC hour, and the cap invariant. The second asks
the rule itself: for every identity pair in the window it calls `verify_ledger.capped()` — the function the senders
are refused by — and lists the rows that answer it. There is no second definition of "one note per person per UTC
day" in SQL. `verify_ledger._same_user()` is a predicate against a candidate pair (the account email, OR the user id
stamped on the row, OR for a row with no account id the decider's user id for a request the note covered), not an
equivalence relation over rows, so grouping rows by one identity column can report "no duplicates" for a person
`capped()` refuses.

Each `duplicates` entry carries the day, the `verify_messages` row ids it matched and `cross_identity`; the
candidate email and user id are used to build the pairs and never printed, and entries that differ only in the
pair that found them collapse to one. `duplicate_counts` gives, per day, how many `real` and how many
`cross_identity` entries there are, so criterion 1 can be read without the list. The cap is per UTC day, so the
whole day is read as cap history, but an entry is reported against `--since` only when one of the rows it names was
written at or after that timestamp: a note dated earlier the same day is history, not a duplicate this run made.

```bash
python3 data/verif-sender-cluster-scale-k1/readback.py \
  --db /var/lib/hydra/credit-review/ledger.sqlite3 --since 2026-11-13T22:00:00Z
```

Run against the production ledger, `/var/lib/hydra/credit-review/ledger.sqlite3`, on 2026-11-15, 02:16Z-02:24Z,
read-only (`connect_ro`, mode=ro), from this lane over ssh as root on node-8: the bytes of `readback.py` at
`db02cfcb2` (sha256 `8808ded97531edbaa6003f5bf431914f03f9495a3b4fdedb955e0a071618cec7`) were fed on stdin, so no
file was written on the host, and they imported the `verify_ledger` deployed at `/opt/hydra` (`c1fbf5a22`, file
sha256 `9056438cabe4...`), whose `capped()` and `_same_user()` are source-identical to this branch's. The process
ran under a 512 MB memory limit at nice 10.

| Run | Result |
|---|---|
| `--since 2026-11-15T00:00:00Z` | 11 attempted-or-sent rows for 11 emails, all in hour 2026-11-15T00Z (`claim-proof-ask` 1, `proof-need-ask` 10). 0 `cross_identity: false` entries, 110 `true`. 132 `capped()` calls, 1.1 s. |
| `--since 2026-11-14T00:00:00Z` | 2026-11-14: 228 rows for 212 emails, 32 `cross_identity: false` entries (the 16 pairs above), 42,622 `true`. 2026-11-15 in the same window: 16 rows for 16 emails, 0 false, 240 true. 43,308 `capped()` calls, 432.7 s. |

Those entry counts are of the output shape before this change, which listed one entry per candidate identity pair
(and carried the email it had used). The entries themselves are the same rows; only the count differs now that a
pair that found the same rows lists them once.

Asks over both days up to 02:24Z were 20 in total across 6 UTC hours, at most 11 in one hour.

**Measured cost.** The read-back makes an `emails x (1 + user ids)` number of `capped()` calls at about 8-10 ms each
on this 979 MB ledger, so a 228-row day takes about 7 minutes, and the `cross_identity: true` entries grow as
`n x (n - 1)`. A capped 200 is about 40,000 calls and is in reach. A day at 1,000 an hour is millions of calls and
is not: the read-back needs a cheaper form before it can be the check at that rate.

On scratch ledgers the fixtures still hold: it counted 3 asks in one hour and 1 in the next, and returned the one
account given two notes that day under two emails. One case defeats any pairwise grouping — a note stamped with user id 9 and an older
note with no account id whose request the decider recorded for user id 7: `capped()` refuses that pair
(`a@x`, 7), which the read-back reports as rows `[a, b]` with `cross_identity: true` (no one row supplies both
`a@x` and 7), while a single-column grouping returns nothing.

It over-reports on purpose. A candidate pair that would be refused can combine one row's email with another row's
user id, so a day with two notes to two different people can still appear; every entry says which case it is in
`cross_identity` (`false` when one of the matched rows itself supplies both the email and the user id, i.e. a real
duplicate for one person; `true` when the pair was assembled from different rows). It never under-reports, which is
the failure that hides a second note, and every entry names the rows it matched so a person can read them. It names
no person itself: row ids identify nobody off node-8.


## Not done

- No sender, queue, service or manifest. No dry run of a sender, no live send, no capped 200.
- The contract's figure, 1,000 an hour for two ticks from the cluster, is not met and was not attempted.
- No cap was raised and no CronJob was resumed.
- PRs 2 and 3 are a plan. Nothing in them is written or measured.
- No PR is open for this change yet.
