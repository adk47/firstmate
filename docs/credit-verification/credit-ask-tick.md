# The credit ask tick

`scripts/credit-ask-tick.sh` runs one bounded pass of the per-need proof ask (campaign
`proof-need-ask`) between two rounds of the hourly outbound tick. It builds the need-ask list and
hands one segment of it to `scripts/credit_review/need_asks.py`, the one reviewed ask path.

**It decides nothing about a user and writes no copy.** Every gate the sender has runs unchanged:
the campaign lock, the copy gate, the live recipient gates, the distributor preflight, the shared
daily cap and the deploy head rail. The script passes no flag and sets no variable that skips one
(`scripts/tests/credit-ask-tick.bats` pins the exact argv and records the gate variables the sender
is actually started with).

**It sends the hourly tick's two-step path, never a bare apply.** Before anything is checked it reads
`armed_families.proof-need-ask` from the policy (the same row `family_armed` reads): a family that is
not live, a paid segment that is not armed, or an `unsigned_from` that has not passed sends nothing.
Then it runs a read-only `--check-recipients` pass and hands the resulting accepted set to the apply
as `--signed-accepted <check.json> --page`. Without that flag the apply would send every user on the
page, including every user the real gate deferred.

## When it runs

| Trigger | When | Why |
|---|---|---|
| `credit-ask-tick.timer` | every 10 minutes except :00 | off the outbound tick's start at :00; a run starts within 10 minutes of that tick going idle, and a fire while a run is still going starts nothing |

The timer starts `credit-ask-tick.service` (`Type=oneshot`, `TimeoutStartSec=1740`). Both are written
by `scripts/install-aux-units.sh`, which fails the deploy if the timer cannot be enabled, started or
is not `active` afterwards. A failed run pages through the `AUX_ONFAILURE_UNITS` table.

## What one run does

1. Stops at once if a stop file is present.
2. Takes a flock on `/run/credit-ask-tick.lock`. A second run exits 0 without building anything.
3. Does NOT wait for the outbound tick (firstmate 031, 2026-11-16): that tick holds the
   credit-group lock 60-95 minutes of every even hour, and waiting for it left the pass idle most of
   the day. Each apply takes its own run lock instead (step 6).
4. Builds the list (`need_asks.py build`) into `/var/lib/hydra/credit-ask-tick/asks.json`.
5. Picks ONE segment (paid and free alternate, one per run; a paid segment the policy does not arm
   is never applied, so the free segment carries every run until it is), then checks the stop file
   again.
6. Walks that segment in BATCHES from the saved cursor. Before each batch it re-reads the stop file
   and the policy's caps; the per-tick cap counts this run's
   `proof-need-ask` ledger rows (all batches together), and the daily cap counts today's
   `proof-need-ask` ledger rows (both segments, `sent` and `attempted` - the same count `room()` in
   `credit-verify-outbound.sh` makes, because `need_asks` keeps no per-segment record).
   One batch is:
   - the read-only `--check-recipients` pass over up to `PAGE` entries from the cursor, with
     `--max-users` the users that fit the check's time (`CHECK_S_PER_USER`), at most `PAGE`: every
     one of them gets an outcome, accepted or the gate's reason;
   - when the check accepted anyone: one apply (`--own-lock`) of
     exactly that check's accepted set (`--signed-accepted`), with `--max-users` the smaller of what
     is left of the per-tick cap and of the daily cap, `--max-entries` exactly the entries the check
     examined (an apply drops users outside the signed set without counting them, so a longer apply
     page would carry the cursor past users no check gated), `--page`, and `--apply-budget-s` at most
     `BATCH_APPLY_S`. An accepted user the caps leave unsent ends the apply's page, so the next batch
     checks them again;
   - the cursor saved from the batch's own page record (the apply's, or the check's when it accepted
     nobody), wrapping to 0 at the end of the list.
7. Ends when the end of the list is reached (`pass_complete`), the run's time is spent
   (`budget_spent`), a cap is spent, `MAX_BATCHES` batches are walked (`ran`), or a stop file
   appears.

### Locks, resume, and sending nobody twice

- This script holds no ledger lock, and never takes the credit-group one. Each apply runs
  `need_asks send --own-lock`, which takes `ledger.sqlite3.proof-need-ask.ask-tick.run.lock` instead
  and releases it when the apply exits (at most `BATCH_APPLY_S`). The outbound tick therefore applies
  whenever it runs, beside this run or between its batches, and this run applies while it runs.
- With no lock between the two writers, an own-lock apply leaves `need_asks.OWN_LOCK_RESERVE` (100)
  of today's shared credit cap (`shared_daily_cap.credit`) unspent, so the two together can overspend
  it by no more than one ask apply (the per-tick cap, 50). Neither can send a user twice: the ledger
  claims every note before it is posted.
- A run still starts no batch later than `OUTBOUND_MARGIN_S` before the next :00, and a run with less
  than one send's room before then does not start (`outbound_tick_due`), to keep its gate calls off
  the outbound tick's build and first checks.
- The cursor moves only after a batch is done. A run killed during an apply resumes at that batch.
  Users that apply already sent are not sent again: the ledger claims each note before it is posted
  (`verify_ledger.claim`, one `BEGIN IMMEDIATE` per user) and the sender skips any request with a live
  `attempted`/`sent` claim (`verify_ledger.blocked_ids`).
9. Writes one line to the journal and `/var/lib/hydra/credit-ask-tick/last-run.json`.

### The checks after every apply

Every apply is read back with the outbound tick's own checks (`scripts/credit-verify-outbound.sh`
`family_run`) before another batch may start:

1. the mail health read, `health_check.py --since <run start> --bounce-max-pct 2 --unsub-max-pct 2
   --spam-max-pct 2`;
2. the refusal spike over the apply's own outcomes (10+ attempts and more than 20% refused), where an
   outcomes file the apply never wrote, or a `post_failed` row, is **unmeasured**, never a clean read
   and never labelled a spike;
3. when the apply wrote any ledger row: the fraud re-check (`fraud_lens` over the accounts that were
   sent to), a sample pointer in `/var/lib/hydra/credit-ask-tick/samples.jsonl`, and the durable
   zero-read over exactly that apply's ledger ids (`zero_read.py --ledger-ids <lo+1>-<hi>`).

A failed health read, a spike, unmeasured outcomes, a fraud hit or an unreadable fraud lens, and a
zero-read `STOP` of any form (`STOP+UNMEASURED` included) write `/etc/hydra/credit-ask-tick.disabled`
and page (`auto_killed`); nothing of this family runs until a person reads the ledger and removes it.
A zero-read `UNMEASURED`, or a reader that printed no verdict, pages and ends the run with no kill
file (`zero_read_unmeasured`), as the outbound tick does. A killed apply is read back too, without the
spike, because it wrote no outcomes file. The cursor is saved before the checks, so a batch they stop
is not walked again. If the zero-read reader or the health read is not deployed, the run refuses
before building anything (`rails_missing`).

## The budget

| Constant | Value | Meaning |
|---|---|---|
| `INTERVAL_S` | 600 | the timer's period; a run may outlast it |
| `RUN_S` | 1500 | no batch starts after this second of the run |
| `HARD_S` | 1680 | any step still running is sent SIGTERM |
| `KILL_GRACE_S` | 30 | the SIGKILL delay after `HARD_S`'s SIGTERM |
| `TimeoutStartSec` | 1740 | systemd's own stop, above `HARD_S` plus the grace and inside the period |
| `MIN_SHARE_S` | 230 | the least a send is started with |
| `PAGE` | 400 | the most list entries one check walks; the time sizing (`CHECK_S_PER_USER`) usually sets fewer: ~310 users in a :10 run's first check, ~27 in a :50 run's |
| `CHECK_S_PER_USER` | 4 | measured cost of one gated user in the check plus margin (2.6 s all in after #2099, node-8 2026-11-16 06:58Z; 8-16 s before it); the check gets only the users that fit before its deadline |
| `CHECK_SETUP_S` | 20 | the check's start-up before its first gate call, in the same sizing |
| `BATCH_APPLY_S` | 300 | the longest share one apply gets: the longest its own run lock is held at a time |
| `MAX_BATCHES` | 200 | batches per run at most |
| `OUTBOUND_MARGIN_S` | 240 | the run ends this long before the outbound tick's next :00; it must cover `HARD_S - RUN_S` |

A run that does not fit (`RUN_S` at or below the share floor, `BATCH_APPLY_S` under it, `RUN_S` not
under `HARD_S`, `HARD_S + KILL_GRACE_S` within 60 s of the hour, `INTERVAL_S` under 60, or an outbound margin under `HARD_S - RUN_S`) exits 2
and runs nothing. The check is bounded to leave `MIN_SHARE_S`
for the apply, and the send loop starts no user whose worst case (`verify_notify.WORST_USER_S`,
200 s) would not fit its share, so a share at or under 200 s would send nobody: `MIN_SHARE_S` is
held above it by a test.

The run normally ends because the sender stops itself at its share. `HARD_S` is the last resort for
a hung interpreter. A send killed there may have sent notes before the kill: the verify ledger is
the record, and the cursor does not move.

## Reading a run

`journalctl -u credit-ask-tick.service` carries one line per run, and `last-run.json` the same
facts. States:

| State | Exit | Meaning |
|---|---|---|
| `ran` | 0 | `MAX_BATCHES` batches walked; the cursor moved after each |
| `pass_complete` | 0 | the end of the list was reached; the cursor wrapped to 0 |
| `budget_spent` | 0 | no room for another batch before the run's end; the cursor is at the first batch not done |
| `check_not_reached` | 0 | the run had no room for one gated user (`CHECK_SETUP_S + CHECK_S_PER_USER`) before the check's deadline: no check, nothing sent, the cursor kept |
| `tick_cap_spent` | 0 | this run's ledger rows reached the policy's per-tick cap |
| `outbound_tick_due` | 0 | the outbound tick starts too soon for one send to finish before it; nothing built |
| `lock_held_by_another` | 0 | another ask-tick apply held the own run lock, or a deploy held the apply lock; nothing sent, the cursor stays |
| `tick_cap_zero` | 0 | the policy's per-tick cap for this segment is 0 |
| `daily_cap_used` | 0 | today's `proof-need-ask` sends have used the policy's daily cap for this segment; nothing sent, the next run takes the other segment |
| `stopped` | 0 | a stop file was placed during the run; no further batch |
| `family_not_armed` | 0 | the policy does not arm this family for this segment, or its `unsigned_from` has not passed; nothing sent |
| `check_accepted_nobody` | 0 | (one-batch runs) the recipient check accepted nobody on the page; nothing applied, the cursor moved to where the check stopped |
| `build_failed`, `policy_unreadable`, `arming_unreadable`, `ledger_unreadable`, `send_not_reached` | 1 | nothing sent |
| `rails_missing` | 1 | the zero-read reader or the health read is not deployed; nothing built, nothing sent |
| `auto_killed` | 1 | a check after an apply stopped the family and wrote `/etc/hydra/credit-ask-tick.disabled`; the journal line before it says which |
| `zero_read_unmeasured` | 1 | the zero-read could not read a source for the batch it sent; paged, no kill file, the next run reads again |
| `check_failed`, `check_killed`, `check_unmeasured` | 1 | the recipient check did not answer; nothing sent |
| `send_failed`, `send_killed` | 1 | the sender ended badly; read the ledger for what went out |
| `page_unmeasured`, `cursor_not_saved` | 1 | the sender ran; where it stopped is not saved |

**The check is sized, not the timeout.** The first live pass (2026-11-16 05:50Z) ran at :50, where the run ends 240 s before :00 and keeps 230 s for the send: the check had until 130 s, the 47 s build left it 83 s for 20 entries, and it was killed with nothing walked. Each check now gets `floor((RUN_END - MIN_SHARE_S - now - CHECK_SETUP_S) / CHECK_S_PER_USER)` users at most (the full page of 20 at :50 and at :20 at 4 s a user; it was about 5 at :50 at the pre-#2099 16 s), the apply takes the same cap, and every batch logs how long its check took, so `CHECK_S_PER_USER` is re-measured from the journal rather than guessed.

A number the sender did not print is `unmeasured` in the line and `null` in the file, never 0. A run
that did not reach the sender reads no sender file, so it never repeats an earlier run's numbers.
"not sent because" counts the apply's answers by class, "the gate did not accept" counts the check's
non-accepted answers over every batch (`deferred/messaged_7d`, `deferred/comm_state`,
`refused_unledgered/G2`), and "filtered before the gate" counts the users the sender dropped before
any gate call (`filtered/already_asked`, `filtered/over`). `last-run.json` carries the same counts as
`gate_skips` and `filtered_before_gate`, with `walked`, `batches` and `applied_batches`; no user id
reaches the journal.

`sent 0` with every candidate deferred is the gates holding those users, not a failure of the tick.

## `distributor_preflight_not_ok` is a label, not a dependency

Before a distributor code is minted for a user, `need_asks.preflight_ok` asks the read-only recipient
gate about that one user. When the gate does not answer `RECIPIENT OK`, no code is minted and the
run's `refusals` list gets `distributor_preflight_not_ok:<request> (<result>: <the gate's first
line>)`.

On 2026-11-15 the bare label was read as one broken dependency refusing every candidate. Measured on
node-8, read-only (no user id is on file here):

- **The two complete runs of the hand-installed `credit-ask-tick.service`** (source:
  `journalctl -u credit-ask-tick.service`), 2026-11-14 23:55:00Z to 2026-11-15 00:35:28Z on
  `asks-20261114T2355Z.json` and 00:55:00Z to 01:35:12Z on `asks-20261115T0055Z.json`. Each summary:
  candidates 200 of 790 listed, sent 0, failed 0, `halted` empty; deferred 194 and refused 6 in the
  first, deferred 195 and refused 5 in the second.
- **What that summary can and cannot count.** It prints `rep.refusals[:10]`
  (`scripts/credit_review/need_asks.py`, `_main`), so each run printed exactly 10 refusal lines: 2 G2
  and 8 `distributor_preflight_not_ok`. Eight is what fit after the two G2 lines, not the number of
  labelled candidates; the tick printed no full count.
- **The bound on it.** `need_asks send --segment paid --mode dry-run --max-users 200` over each of
  the two lists, 2026-11-15 04:09:34Z to 04:10:49Z, with `verify_notify.send_all` and
  `need_asks.with_codes` replaced by counters (no gate call, nothing sent): 200 candidates = 26 plain
  payloads (18 `counterparty_signed_or_registered`, 8 `readable_document`) + 174 distributor
  payloads; `held_newer_intake` 192. An apply runs the preflight on each distributor payload, so the
  label was on at least 8 and at most 174 of the 200 per run. The exact number was not measured.
- **Why it is a per-candidate gate population, not a broken dependency.** Both applies classified all
  200 candidates as deferred or refused, with 0 failed and nothing unmeasured (a gate that cannot
  answer is recorded as unmeasured or failed, never as a deferral). Dry runs with
  `--check-recipients --outcomes-json` on 2026-11-15: the first 24 paid entries (01:52:09Z to
  01:57:28Z) gave 0 accepted, 23 deferred, 1 refused; the 10 users behind the printed label lines
  (03:54:32Z to 04:01:45Z) gave 9 deferred, 1 refused. Every one of those 34 carried its own answer:
  `messaged_7d`, `core_notice_within_7d`, a G2 refusal, comm_state holds R5 to R8.
- **Why the rate stayed where it was.** With no cursor, every run walked the same first 200 of 790
  paid entries.

The answer is now on the line so the label cannot be read that way again.

## Why the hand-installed version sent nothing

It ran `need_asks send --segment paid --mode apply --max-users 200`, then free, with no cursor,
under a 3600 s timeout on a 30-minute timer (measured 2026-11-14 23:55Z to 2026-11-15 01:55Z):

- Every run walked the same first 200 of 790 paid entries: about 40 minutes of gate calls, 0 sent.
- It was killed at 3600 s before or during the free segment and restarted the same second.
- It therefore held the credit-group run lock without a gap. The outbound tick's first credit apply
  found the lock taken at 00:18:48Z and 01:15:34Z ("another uvn-status apply run is in progress")
  and ended every credit family behind it for those ticks.

## Stop and undo

- **Delivered asks cannot be unsent.**
- Stop that lasts: `touch /etc/hydra/credit-ask-tick.disabled`. The run exits 0 before it builds
  anything. The hand-installed version's `/etc/hydra/credit-ask-STOP` is still honoured, and the
  script never removes either file.
- `systemctl stop credit-ask-tick.timer` stops it until the next deploy, which starts the timer
  again.
- The cursors are `/var/lib/hydra/credit-ask-tick/cursor-paid` and `cursor-free`. Deleting one
  starts that segment at entry 0; the ledger still stops a second ask to the same user.

## What it does not do

- It does not change who is asked, the caps, or any copy. `need_asks.py` owns all three, and this
  path honours the same two policy rows the outbound tick does: `tick_cap` lowers one run, and
  `daily_cap` is counted against today's `proof-need-ask` ledger rows before `--max-users` is handed
  over. A policy or ledger read that cannot answer sends nothing (`policy_unreadable`,
  `ledger_unreadable`), never "no cap". The shared credit-group cap is still the sender's own.
- It does not retry a failed send inside a run.
- It does not page on `sent 0`.
