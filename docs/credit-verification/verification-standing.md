# Where verifications stand: the one page

`scripts/verification-standing.py` prints one screen (at most 30 lines, 112 columns) that
answers where credit and profile-claim verifications stand. It reads durable state only,
posts nothing and starts no production scan. Its only writes are the two files `--save` names.

It runs on a timer, not by hand. `verification-standing.timer` (`scripts/install-aux-units.sh`)
runs `--save /var/lib/hydra/verification-standing` at :10 and :40, ten minutes behind each queue
snapshot, so the current page is always `latest.txt` there, with the same cells in
`latest.json`. See [The scheduled run](#the-scheduled-run).

Every family in a group of `policies/credit-verify-outbound.json` that sent in the last 7
days gets one row, so adding a family there adds one line here. The page's test builds the
worst case (every family the policy on `main` ships, each with a send this week) and fails
past 30 lines: the page is 29 lines with the nine families of 2026-11-15, and 30 when one
family's sent rows cannot be dated, so the next family added after that date needs a line
taken out of the page.

```
python3 /opt/hydra/scripts/verification-standing.py            # the page
python3 /opt/hydra/scripts/verification-standing.py --json     # the same cells, with source and age
python3 /opt/hydra/scripts/verification-standing.py --strict   # exit 3 if any cell on the page is unmeasured or stale
python3 /opt/hydra/scripts/verification-standing.py --save DIR # the timer's form: save the page, exit 3 if a written number broke
cat /var/lib/hydra/verification-standing/latest.txt            # the page the timer last saved
```

Run it as root on node-8, as the queue report runs. A SQLite reader under another uid can
recreate the ledger's `-shm` file, and root's writers then fail to open the ledger
(`scripts/credit_review/ledger_open.py`).

Before the script is on the host it runs the same way over ssh, with nothing installed:
`ssh root@<node-8> 'CVO_POLICY=/opt/hydra/policies/credit-verify-outbound.json python3 -' < scripts/verification-standing.py`.

## The scheduled run

`verification-standing.service` is a oneshot that saves the page and then answers one
question: is every number that some job is supposed to write both measured and fresh?

- **Exit 0**: yes. The page is saved.
- **Exit 3**: a number that has a writer is `unmeasured` or stale. The page is still saved,
  the reasons go to stderr as one line per reason with the cells it covers
  (`credits waiting_us, waiting_user, on_hold; claims open; ours`), and the failed
  unit pages `#clio_devops` through `hydra-unit-failed@` (once per 24 h per unit; a clean run
  clears that, so a number that breaks again pages again). When the snapshot is stale because
  its writer's stop file is present, the last line names the file.
- **Exit 1**: the page could not be saved.

Every cell counts: the seven columns, the three waiting cells (`waiting on us`, `waiting on
the user`, `on hold`), the per-user median and the tracking numbers. The check walks the cells
the page carries rather than a list of their names, so a cell added later is checked without
anyone remembering to list it. Three figures are left out of the names because each comes from
the same read as the cell beside it and is measured or unmeasured with it (`SAME_READ` in the
script: rows open, rows decided, tells per day); a test holds that to be true.

A number no job writes yet does not fail the unit. Today that is `held_evidence_unbounded`
only (`NO_WRITER_YET` in the script). A unit that can never pass pages once and is then
ignored, which would hide the numbers that can break. `--strict` has no such exception.

The unit has no stop file: it writes two local files and sends nothing. The first run after a
deploy that changes the snapshot's writer can fail once, until that writer's next :00 or :30
run saves the fields the page reads.

Wiring is pinned by `scripts/tests/install-aux-units-verification-standing.bats`: both units
parse, the service's own command line exits 3 with its sources missing, no exit code is
declared a success, the timer is enabled by a top-level step that stops the install when it
fails, and the service is in the OnFailure table.

## The columns

One row per request family (`credits`, `claims`). Every column counts **users**.

| column | what it is | read from |
|---|---|---|
| open users | users with at least one open request | snapshot `open_users` |
| decided 24h | users with a request approved, plus users with one declined, in the last 24 h | snapshot `flow` |
| told 24h | distinct users a message was successfully sent to in the last 24 h | verify ledger |
| median age | median age of an OPEN REQUEST, one sample per request | snapshot `age.median_h` |
| oldest age | the oldest open request | snapshot `age.oldest_h` (or the oldest bucket) |
| last successful send | the newest successful send, and how long ago | verify ledger |
| days to zero | open users / users told per day (7-day mean) | both |

Under each family: one line per send family the outbound policy lists for it
(`policies/credit-verify-outbound.json` `groups`), plus `decision notices` under credits. A
send family with no send in 7 days is named on one line with its last send, or `never`.

Below the table: the credit requests' five tracking numbers (next section), senders the
policy does not list that still told somebody, the same population in **requests**, whose
move it is (the snapshot writer's own `AWAITING_US` /
`AWAITING_USER` bucket lists; everything else is on hold), the rate behind days to zero, and
the age of the snapshot. The three whose-move cells are `unmeasured` when the snapshot's
buckets were not classified cleanly: a ledger, proof feed or watchlist error, or a bucket
list that does not cover both `AWAITING_US` and `AWAITING_USER`. An error that says nothing
about bucketing (merges, Slack, a median read, the tracking reads) leaves them measured.

## The five tracking numbers (credit requests)

These count **requests**, not users, and are printed on their own three lines.

| number | what it is | read from |
|---|---|---|
| `OURS` | pending requests (`user_verification_needed`, not deleted) that no ask has been delivered for. `never asked` is the part with no `verify_requests` row of any campaign. It falling is the progress measure. | snapshot `ours` |
| `sent_this_tick` | what the newest sender tick sent, with the time of that tick | the sender's tick records / verify ledger |
| `applied_1h` | requests with an `approved` outcome row in the last hour, whatever its evidence kind | verify ledger |
| `decisions_per_intake` | decision rows in the hour before the snapshot / requests created in that hour. Near 1 is one decision per new request; far above 1 is the same requests decided again. | verify ledger / snapshot `intake_1h` |
| `held_evidence_unbounded` | `unmeasured`: no writer records the reason yet | — |

- **`OURS` is joined by request id** by the snapshot's writer (`ask_gap`): the pending ids
  from the core replica against the ledger's requests whose message has status `sent` and
  whose campaign is one of the ledger's `ASK_CAMPAIGNS`. A status note or a take-back notice
  is not an ask, so this counts only a delivered ASK: it can read higher than a gauge that
  treats any sent note as delivered, and never lower.
  Pending minus a count of sent ids under-reads it by every sent id that is no longer
  pending (16,861 on 2026-11-14). Measured read-only on 2026-11-15 09:10Z: 28,550 of 80,287
  pending, 26,800 never asked; the three reads took 3.1 s, 0.8 s and 2.4 s.
- **`sent_this_tick` reads the sender's own tick records.** The newest
  `YYYYMMDDTHHMMZ` directory under the sender's output root (`CVO_OUT_ROOT`, default
  `/root/h2-runs/sched`) names the tick; its `*-apply.json` / `*-check.json` records name
  the campaigns that tick ran, and the number is the ledger's `sent` `verify_messages` rows
  for those campaigns between the tick's stamp (its start) and now, capped at the stamp plus
  its hard deadline (`TICK_HARD_S`, 6900 s). Nothing else decides the end: the window can
  never be cut before a send, so it cannot read 0 for a send that happened. Its one cost is
  that a manual sender run inside the same window is counted too. A missing root, no tick, a tick with no `*-apply.json` record (a check-only
  tick included), or a record with no `sent` list is `unmeasured`, never 0. A tick older than 2 hours is marked `~`.
- **`applied_1h` counts every `approved` outcome row in the last hour, whatever its
  evidence kind.** No writer on main records a precedent approval in the ledger yet; when
  that ledger row lands, those approvals are counted here with no change to this page.
- **`held_evidence_unbounded` is `unmeasured`, never 0.** No writer records
  `reason = evidence_unbounded` on a ledger row yet: the verify-live hold
  (`hold_unbounded` in `scripts/credit_review/verify_notify.py`) keeps a held credit as a
  deferred `verify_requests` row, and that table has no reason column. A cell with no
  writer is not a measurement, so the page prints `unmeasured` and `--strict` treats it
  like any other unmeasured cell. The scheduled run does not fail on it, because no job can
  fix it yet. TODO: the verify-live hold must record the reason (the
  constant `EVIDENCE_UNBOUNDED` in `scripts/credit_review/admin.py`) before this cell can
  carry a number; the page then reads only what that writer records.
- A failed `ours` or `intake` read in the writer leaves its key out of the snapshot and its
  error in; the page then prints `unmeasured` for that number and the tables are not affected.

## The sources

- **The snapshot** is `/var/lib/hydra/verification-queue-report/last.json`, written by the
  full run of `scripts/verification-queue-report.py` (every 30 minutes). That job is the one
  population read; this page starts no second one. The writer records `age` (`median_h`,
  `oldest_per_user_median_h`, `oldest_h`, `users`, `undated`) per table, `ours` (`pending`,
  `ours`, `never_asked`) and `intake_1h` (`requests`) for this page. `median_h` is the median
  over open requests, read per request by the full run; `oldest_per_user_median_h` is the
  per-user figure (each user's oldest open request) and the page prints it on its own line,
  never under the `median age` label. A snapshot written before the per-request read existed
  carries no `median_h`, and the cell is `unmeasured`.
- **The verify ledger** is `/var/lib/hydra/credit-review/ledger.sqlite3`, opened `mode=ro`
  with `query_only`. A tell is a `verify_messages` row with status `sent`, or a
  `decision_told` row with mode `apply` and outcome `sent`. A ledger without the
  `decision_told` table is `unmeasured` for every tell, never a smaller measured count.
  Nothing else counts: not
  `attempted`, not a dry run, not a refusal. A sent row from before `sent_at` existed is
  dated by `created_at`; `updated_at` is never used, because a later proof tag moves it.
  **A row whose time cannot be read is never left out of a count.** It could be a user told
  today or an approval made this hour, so a count without it is lower than the truth by an
  unknown amount. A sent row with no readable time makes its family's told, last send and
  days to zero `unmeasured` (and `sent_this_tick`, when the tick sent that family); an
  approved outcome with none makes `applied_1h` unmeasured; a decision row with none makes
  `decisions_per_intake` unmeasured. The reason names the family and the number of rows, and
  the scheduled run fails on it. Such a row of a sender outside the policy has no cell to
  mark and is named in a `note:` line. The production ledger held no such row on 2026-11-15.
- **The sender's tick records** are the `YYYYMMDDTHHMMZ` directories under
  `/root/h2-runs/sched` (`CVO_OUT_ROOT`), each holding `*-apply.json` / `*-check.json`.
- **The policy** is `policies/credit-verify-outbound.json`. Each family's `groups` entry must be
  a non-empty list of send family names. A group that is missing, empty or anything else makes
  that family's told, last send and days to zero `unmeasured`, with the reason on the page; the
  other family keeps its numbers, and the sends stay named under `senders outside these families`.

## What the page will not do

- **It never prints 0 for "could not read".** A missing or unreadable source prints
  `unmeasured`, and a line at the bottom says which cells and why. A snapshot whose own run
  recorded a failed read for a family leaves that family unmeasured, because the writer saves
  an empty population as 0 open.
- **It never prints a number without its age.** A snapshot older than 2 hours marks every
  cell it feeds with `~`, and the page names the writer's stop file
  (`/etc/hydra/verification-queue-report.disabled`) when that file is present. Told and last
  send are read at run time and are never marked.
- **It does not mix units.** Days to zero divides open users by users told per day. Open
  requests divided by users told overstates it about twelve-fold (101,373 open credit
  requests were 8,270 users on 2026-11-14). When both outcomes of
  decided 24h are non-zero the cell prints `<=`: the snapshot counts each outcome's users
  apart, so a user in both is counted twice.
- **Days to zero is not days to closed.** It is the time until every open user has been told
  once at the measured rate. An ask leaves the request open, with the wait on the user. No
  tell in 7 days prints `no tells 7d`, not a number.
- **It does not create a missing ledger**, and the source has no write, network or
  subprocess call.

## Limits

- The median age, `OURS` and `decisions_per_intake` are `unmeasured` until a full
  queue-report run has written a snapshot with the `age`, `ours` and `intake_1h` blocks. A
  snapshot older than 2 h marks every cell it feeds with `~`, and the stale line names the
  writer's stop file when that file is in place.
- `decisions_per_intake` is measured over the snapshot's hour, not the hour before the page
  was printed, so both halves cover the same hour.
- A policy group with no row in `FAMILIES` is named in a `note:` line, and a test fails
  until the row is added.
- Merges and erasure requests have no row: no durable store here holds their told times.

Tests: `scripts/tests/test_verification_standing.py`; the writer's `age` block is covered in
`scripts/tests/test_verification_queue_report.py` (`AgeStats`), its `ours` and `intake_1h`
blocks in `AskGap`.
