# The shared ledger opener: busy timeout, a lock retry, and a journal mode it reports

2026-11-15. Change: `scripts/credit_review/ledger_open.py`. Tool: `data/ledger-busy-timeout-wal-r1/tools/measure.py`.

## What was wrong

The intercom drain died mid-run on `database is locked` while four credit jobs wrote
`/var/lib/hydra/credit-review/ledger.sqlite3`. The opener every one of those writers goes through gave a connection
only what its caller asked for: no busy timeout of its own, no journal mode, no second try.

## What changed

All in `ledger_open.py`. No caller changed.

1. `_connect()` gives every connection (writer, reader, `:memory:`) a busy timeout of at least 30 s and states it as
   `PRAGMA busy_timeout`. A caller's longer `timeout=` is kept (`reconcile_approved` asks for 60 s).
   `write_state()` still probes with a zero busy timeout and restores the connection's value, never below 30000.
2. `open_rw()` never changes the journal mode. It reads it with a zero busy timeout (so it never waits behind a
   writer), records it on the connection as `ledger_journal_mode`, and reports a ledger that is not in `wal` through
   `EVENT_SINK`. A non-WAL ledger still opens and still writes. The one-time conversion is `migrate_to_wal()`, run by
   hand as `python3 scripts/credit_review/ledger_open.py migrate-to-wal <ledger>`: it converts only when no other
   connection holds a lock (zero busy timeout, no retry), reads the mode back, and exits non-zero naming the actual
   mode when the result is not `wal`. A path that does not exist is refused before connecting, so a mistyped path
   cannot create an empty ledger and report it as converted. Nothing runs it automatically. `open_ro()` sets no
   journal mode.
3. A statement or commit on a write connection that SQLite answers with `SQLITE_BUSY` / `SQLITE_LOCKED` is tried 3
   times in all, sleeping 0.2 s then 0.5 s between tries, then raises `LedgerLockedError` (still a
   `sqlite3.OperationalError`, still carrying SQLite's words) naming the ledger, the opener, the statement and the
   tries made.

## Measured, before and after

Python 3.12.3, SQLite 3.45.1, scratch ledgers in a temp directory, the other jobs played by threads holding their own
connections. "Before" is `origin/main` at `40c5c7de6`.

| Case | Before | After |
|---|---|---|
| Busy timeout, caller names none | 5000 ms | 30000 ms |
| Busy timeout, caller names 5 s | 5000 ms | 30000 ms |
| Busy timeout of a reader (`open_ro`), caller names none | 5000 ms | 30000 ms |
| Busy timeout after `write_state()`, caller named 30 s | 30000 ms | 30000 ms |
| Journal mode of a ledger `open_rw` created | `delete` | `delete` (read and reported, never set) |
| Journal mode of a rollback ledger after `open_rw` | `delete` | `delete` (read and reported, never set) |
| Journal mode of a rollback ledger after `open_ro` | `delete` | `delete` |
| Write behind an 8 s writer, caller names no timeout | fails at 5.01 s, `database is locked` | written at 8.11 s |
| Write behind a 3 s reader, ledger nobody set to WAL | written at 3.07 s | written at 3.05 s |
| Write behind a 36 s writer, caller names 30 s | fails at 30.08 s, `database is locked` | written at 36.03 s |
| Write behind a writer that outlasts every try (busy timeout cut to 300 ms for the case) | fails at 0.30 s, bare `database is locked` | fails at 1.61 s, `LedgerLockedError` naming 3 attempts |
| A constraint error | `IntegrityError` at 0.00 s | `IntegrityError` at 0.00 s |

Reproduce:

    git show origin/main:scripts/credit_review/ledger_open.py > /tmp/before.py
    python3 data/ledger-busy-timeout-wal-r1/tools/measure.py --ledger-open /tmp/before.py
    python3 data/ledger-busy-timeout-wal-r1/tools/measure.py --ledger-open scripts/credit_review/ledger_open.py

## What this does not show

- **Which statement the drain died on, now measured.** MEASURED on node-8, 2026-11-15 15:41-15:46Z (read-only):
  `/var/lib/hydra/intercom-queue-reassign/u1-20261113/drain/run7/apply.err`, 13:55:47Z, is
  `drain.py:1133 run_send -> send.py:372 ledger_claim -> verify_ledger.py:1246 claim: db.execute("BEGIN IMMEDIATE")`
  `-> ledger_open.py:316 execute -> sqlite3.OperationalError: database is locked`. The crashed connection was opened
  THROUGH `ledger_open.py` (`verify_ledger.connect`, `timeout=30`). The run's 21 backlog-reply rows were written
  13:53:28-13:55:00Z; the crash is 47 s after the last, which fits a 30 s busy wait on the 22nd claim. A 30 s busy
  timeout was therefore already in force and was not enough; what the drain lacked was a second try.
- **The journal mode was measured, and it is already WAL.** MEASURED on node-8,
  2026-11-15 15:41-15:46Z (read-only): `/var/lib/hydra/credit-review/ledger.sqlite3` is ALREADY in WAL mode (header
  bytes 18-19 = `02 02`, a live 26 MB `-wal` and a `-shm` beside it). The migration therefore has nothing to do on
  node-8; it exists for a ledger created fresh.

## What the retry does not cure

- **A read followed by a write in one deferred transaction.** SQLite answers `SQLITE_BUSY` at once, whatever the busy
  timeout, when another writer holds the lock. It is retried, but once the other writer commits the answer becomes
  `SQLITE_BUSY_SNAPSHOT`, which no wait clears. That one is raised on the first try as `LedgerLockedError` with
  `attempts` 1 and the reason. The cure is the caller's `BEGIN IMMEDIATE`, which `verify_ledger`'s claim sites
  already use.
- **A statement that may have half-applied.** `executemany` is run again only when its rows are a list and nothing
  was written; `executescript` only when no row and no schema change shows and no transaction is open. Otherwise
  it raises with `attempts` 1 and says why.
- **A lock met while fetching rows from a cursor**, after `execute()` returned. Not retried.
- **A reader's lock.** `open_ro` connections get the 30 s busy timeout and no retry.

## What it costs

A write that never gets the lock now takes three busy timeouts plus 0.7 s to say so: about 91 s for a 30 s caller,
181 s for `reconcile_approved`'s 60 s, where it took 30 s and 60 s. A job whose supervisor kills it sooner than that
is killed before the named error is raised.

The third backoff value in the specification (1.0 s) is never slept: with three tries in all, the third is followed
by the raise. It is in `LOCK_BACKOFF_S` for whoever raises `LOCK_ATTEMPTS`.

## Two tests changed, and why

Both failed because the production ledger is in WAL mode, not because an opener sets it.

- `test_proof_marker.py::test_it_leaves_the_ledger_as_mark_tagged_does` copied the ledger by reading the main file's
  bytes while a connection was open. In WAL mode the committed rows were still in the `-wal`. It now copies with
  `sqlite3`'s backup.
- `test_verify_ledger_migration_race.py::...waits_it_out_instead_of_reporting_89_failed` gave the reader a 2 x 0.1 s
  retry window against a migration that takes about 0.2 s. It passed only because, on a rollback-journal file, the
  reader's second look blocked behind the migrator's lock. In WAL mode a reader is not held, so the window has to
  cover the migration: it failed 5 of 6 runs at 0.1 s and passed 8 of 8 at 1.0 s. The production value,
  `RO_RETRY_SLEEP_S = 2.0`, is unchanged. On `origin/main` the same reader sees the same partial schema on a fixture
  that is already WAL (one of three runs showed a 6-object gap on the second look), so this is the shape of the WAL
  ledger, not something the change introduced.

## Who gets the fix

MEASURED on node-8, 2026-11-15 15:41-15:46Z (read-only): the gateway's `cron_run_receipts` for runs overlapping
13:54:30-13:55:48Z name these ledger WRITERS, all of which already open it through `ledger_open.py`:
`credit-trust-decide-15m` (`credit-review.py decide --mode judge`, 13:45:33-13:57:49; `Ledger()` at
`scripts/credit_review/ledger.py:89`), `credit-proof-reviewer` (`credit_review/proof_reviewer.py apply`,
13:55:01-13:56:26; `_rw()` at `scripts/credit_review/proof_reviewer.py:632`), `credit-trust-score-approve-15m`
(`credit-review.py score-approve --mode apply`, 13:55:44-14:02:57; `Ledger()` at `ledger.py:89`), and the drain itself
(`verify_ledger.connect` at `scripts/credit_review/verify_ledger.py:449`). Also running, not writing this ledger:
`credit-verify-proof-stage2` (reads it `mode=ro`, `scripts/credit_verify/proof/stage2.py:269`), `credit-dsp-verify-d5b`
and `credit-doc-verify` (their own stores). Also in the window and NOT identified: three receipts whose job row is
gone, one receipt running since 12:17:37 with no job row, and processes started outside the gateway (root's crontab,
systemd units).

So the writers that can be named from the host's records are covered by this change with no caller edit, because they
already go through `ledger_open.py` and the retry is what they lacked. WHICH connection held the write lock for those
30 s is not recorded anywhere that was read, so it is not established that none of the eight bare-connect writers
below was involved. The ledger is not claimed to be covered.

Every opener that reaches `_connect`:

| Module | Call |
|---|---|
| `scripts/credit_review/verify_ledger.py` | `connect()` (write), `connect_ro()` (busy timeout only) |
| `scripts/credit_review/ledger.py` | `Ledger.__init__` |
| `scripts/credit_review/reconcile_approved.py` | `open_ledger()` |
| `scripts/credit_review/precedent_ledger.py` | `open_ledger()`, through `reconcile_approved` |
| `scripts/credit_review/proof_reviewer.py` | `_rw()` |
| `scripts/credit_review/proof_marker.py` | `_rw()` |
| `scripts/credit-review.py` | through `verify_ledger.ledger_open()` and `Ledger` |

and every caller of those, the intercom drain included (`scripts/intercom-backlog/drain.py` and `send.py` open the
ledger with `verify_ledger.connect` on `--apply`).

## Who does not

A writer that opens the ledger some other way is not covered. `grep -rn "sqlite3\.connect(" scripts` outside tests
and `ledger_open.py` finds 164 calls: 120 read-only (`mode=ro` / `immutable`), 6 `:memory:`, 38 others. Of the 38,
these open the shared `ledger.sqlite3` directly and write it:

| File | Line | Timeout | Sets WAL |
|---|---|---|---|
| `scripts/credit_review/request_state.py` | 50 | 60 s | yes |
| `scripts/credit_verify/dspverify/link_proposal.py` | 532 | 60 s | no |
| `scripts/credit_verify/dspverify/merge_candidates.py` | 164 | 30 s | no |
| `scripts/credit-stale-velocity-revalidate.py` | 79 | 30 s | no |
| `scripts/credit-validator-reject-close.py` | 79 | 30 s | no |
| `scripts/credit-no-proof-close.py` | 103 | 30 s | no |
| `scripts/credit-doc-close.py` | 120 | 30 s | no |
| `scripts/credit-decision-told.py` | 62 | 30 s | no |

None of them retries on a lock. `scripts/credit_review/evaluate.py:251` opens it with a plain connect, no timeout,
and only reads. Not fixed here; named.

The other 29 open stores of their own, not the shared ledger: `credit_trust/ledger.py:85`, `credit_retro/ledger.py:102`,
`ops_intake/{ledger.py:132, store.py:148, proof_review.py:1332, redteam.py:180, redteam.py:201}`,
`merge_verify/store.py:43`, `credit_verify/proof/store.py:157`, `credit_verify/dspverify/store.py:140`,
`credit_verify/docverify/{store.py:149, name_index.py:70}`, `clickup_drain/data_deletion.py:262`,
`churn/{store.py:123, store.py:153, tickets.py:235}`, `lib/qa_broker.py:383`, `caroline_monitor/store.py:58`,
`credit_review/scale_drain.py:1078`, `credit_review/apply_queue.py:{138, 528, 559, 592}`,
`credit_review/bulk_queue.py:{191, 549}`, `credit_review/proof_verifications.py:163`, `gdpr_pipeline/store.py:315`,
`claim_verify/doc_ladder.py:970`, `cron-health-watchdog.sh:911`. (`apply_queue.py:592` reads the verify ledger in
its own `verify` check.)

## Tests

`scripts/tests/test_ledger_open.py`: 38 tests before, 91 after. Run with the change: every tracked Python test file
(187) and the 19 bats files that touch the ledger or the credit jobs. All pass except `tests/test_payout_workbook.py`,
which does not import on this machine (`No module named 'openpyxl'`) and touches none of this.
