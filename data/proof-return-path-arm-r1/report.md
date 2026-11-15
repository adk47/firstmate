# Arming the proof reviewer: what was measured, 2026-11-15

Lane `proof-return-path-arm-r1`. Every number below was read on node-8 through read-only SQLite connections
(`mode=ro`) unless the line says otherwise. node-8 ran `be9e53e6e` for all of it, which is the reviewer WITHOUT the
guard this change adds.

## What changed in this branch

| file | change |
| --- | --- |
| `cron-jobs.json` | `credit-proof-reviewer`: `enabled` false to true. Schedule, argv, cwd and timeout are untouched |
| `scripts/credit_review/proof_reviewer.py` | exit 70 (`EX_NO_ROWS`) when an `apply` reached verdicts and none is on file |
| `scripts/tests/test_proof_reviewer.py` | the guard's cases, and the cron test now pins `enabled` true |
| docs | `proof-path.md`, `AGENTS.md`, one cron lesson in `docs/lessons/openclaw-and-codex.md` |

The job's argv is `python3 /opt/hydra/scripts/credit_review/proof_reviewer.py apply`, as it was. That `apply` is the
reviewer's own subcommand: it writes `verify_proof_reviews` and `proof_review_decisions` rows in the verify ledger.
It makes no admin API call and approves nothing in core. No approval path is switched on by this change.

## Before (12:48Z, reviewer never run)

| what | count |
| --- | --- |
| `verify_proof_reviews` rows | 0 |
| `proof_marks` rows | 662 |
| notes with `proof_tagged_at` | 767 |
| `proof_review_decisions` | table did not exist |

`proof_reviewer.py plan --list` (read-only, 11.2 s, exit 0) on the first 200 notes: 614 notes under review, 8,481
credits with no verdict, 1,381 verdicts reachable (3 accepted, 1,378 rejected), 1,820 credits waiting on our reader
(oldest 356 days), 365 notes left for later runs, 40 claim notes skipped (they are `claim-doc-ladder.py`'s).

I then ran `apply` against a copy of the ledger in a scratch directory (`sqlite3` backup API, production untouched):
exit 0, 1,381 rows written, tagged notes 767 to 577. The copy has been deleted.

## After (13:00:55Z)

Firstmate enabled the job on node-8 at 12:52Z with `openclaw cron enable`. I did not arm it and did not repeat it.

| run | how | accepted | rejected | rows |
| --- | --- | --- | --- | --- |
| `pr-20261115T125207Z` | no gateway receipt, so not the scheduler | 3 | 1,378 | 1,381 |
| `pr-20261115T125501Z` | scheduled :55, receipt `ok`, 12:55:00Z to 12:55:35Z | 1 | 1,181 | 1,182 |
| total on file | | 4 | 2,559 | 2,563 |

Nothing is reverted. Tagged notes: 381. Reader backlog after the second run: 1,817 credits, oldest 356 days
(`/var/lib/hydra/credit-review/proof-reader-waiting.json`).

First run by reason: `doesnt_name_you` 714, `other_track` 410, `unreadable` 237, `not_a_document` 16,
`other_role` 1, accepted 3. Recorded ask route on the audit row: `proof-need-ask` 1,125,
`blocked:no_unverifiable_read` 232, `blocked:verify_at_off` 21.

Both runs together by reason: `doesnt_name_you` 1,565, `other_track` 673, `unreadable` 271, `not_a_document` 43,
`other_role` 7, accepted 4.

### One answered request, end to end

Request `4bec612c-565d-4abf-abc3-db5cc4feb25a`: `verify_proof_reviews` row `family=1448`, `outcome=accepted`,
`reviewed_at=2026-11-15T12:52:07Z`, `reviewed_by=ai:proof-reviewer/pr-1 doc-verify/dv-4
model=deepseek/deepseek-v4.1-flash-1017`. Command: `python3 /opt/hydra/scripts/credit_review/proof_reviewer.py apply`.

A rejected one: `a84381ef-3fc4-4fba-9573-31a1ce1b9893`, `family=2212`, `rejected` / `doesnt_name_you`, same run,
`model=gpt-6-sol`.

### What the rows did to customers

Nothing was sent by this change. `proof_review_decisions` is read by the reviewer alone, no cron names `need_asks`,
`proof-need-ask` or `decline`, and the only `verify_messages` rows dated after 12:52Z by 13:00Z were 39
`backlog-reply` sends, a campaign that does not read reviews. `verify_proof_reviews` IS read by `verify_ledger`
(the close window, the removal-due reading, the status lists), so a review changes what those readers report from
the next run on. That is the point of arming it, and it is the reason the undo below names the rows as well as the
switch.

## The distribution in the four words asked for: not given, and why

Firstmate asked for the distribution as `same / different / unreadable / pending`, "the pinned vocabulary from
#2012". #2012 pins the opposite. Those four words are `proof_verifications`' (`scripts/credit_review/proof_verifications.py`,
the removal executor's link table): does a link a `not_me` claimant sent name a different person, the claimant,
neither, or was it not graded. `scripts/tests/test_doc_verify_trace.py:490` asserts doc-verify never emits them
and never names that table, and `data/proof-verifications-persist-r1/premise-check.md` records why a mapping such
as `verified -> same` or `contradicted -> different` "has no honest target".

The reviewer's own words are `accepted` / `rejected` with a reason from `REJECTION_REASONS`, and "no verdict yet"
is the `wait_reader` count, which is not a row. Its reason `unreadable` (the document could not be read) is a
different fact from that table's `unreadable` (the link names neither person). A four-bucket rollup needs a ruling
on the mapping. I have not invented one.

## The 20 requests for a known-answer check

All from the first run (`pr-20261115T125207Z`, 1,381 rows, 1,381 distinct requests). Picked by rule, not by eye:
within each class, order by `sha256(request_id)` and take the first N. Quota: every accepted row (3), 5
`doesnt_name_you`, 5 `other_track`, 4 `unreadable`, 2 `not_a_document`, the one `other_role`.

These are the reviewer's recorded verdicts. Nobody has checked them against the documents yet: that check is what
makes this a known-answer set.

| # | request id | verdict | reason | need recorded | route recorded |
| --- | --- | --- | --- | --- | --- |
| 1 | `4bec612c-565d-4abf-abc3-db5cc4feb25a` | accepted | | | |
| 2 | `2f71d408-3cda-4cdb-82af-626fe9b9ce4c` | accepted | | | |
| 3 | `62a3de30-9862-4df7-aa05-09334ba5de73` | accepted | | | |
| 4 | `a84381ef-3fc4-4fba-9573-31a1ce1b9893` | rejected | `doesnt_name_you` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 5 | `a29bb2e7-f969-4b8c-83fc-e0814f0350b3` | rejected | `doesnt_name_you` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 6 | `bb31ab69-7bda-4573-b540-293967e0287a` | rejected | `doesnt_name_you` | `counterparty_signed_or_registered` | `proof-need-ask` |
| 7 | `c32a1ec9-6230-4ad8-a3bf-14380516b2b8` | rejected | `doesnt_name_you` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 8 | `4537007c-1015-4cf0-92ab-d847f8761dd7` | rejected | `doesnt_name_you` | `counterparty_signed_or_registered` | `proof-need-ask` |
| 9 | `b1956495-720d-4476-aa9f-b81fbf545ce5` | rejected | `other_track` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 10 | `b27e9671-a16a-4fb0-bcdd-fb3acf3bea54` | rejected | `other_track` | | `blocked:no_unverifiable_read` |
| 11 | `80dd7a42-8f55-4d19-a715-a5316d9e94b2` | rejected | `other_track` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 12 | `08047ee8-af54-4b91-89bf-65575f3954b6` | rejected | `other_track` | | `blocked:no_unverifiable_read` |
| 13 | `eeb490f0-a7c7-4bd9-90d6-8348ddd6eba5` | rejected | `other_track` | | `blocked:no_unverifiable_read` |
| 14 | `4a3b450b-4781-48ce-b523-d74fdaad37c4` | rejected | `unreadable` | `readable_document` | `proof-need-ask` |
| 15 | `5ee3461d-de62-48a8-a99f-4b8052c55334` | rejected | `unreadable` | `readable_document` | `proof-need-ask` |
| 16 | `40684c80-481b-4304-9126-dc61441987a9` | rejected | `unreadable` | `readable_document` | `proof-need-ask` |
| 17 | `81f80862-581f-4716-a49a-ee00c5bf1757` | rejected | `unreadable` | `readable_document` | `proof-need-ask` |
| 18 | `2a5f5ce9-41b2-442f-88f9-0f449ddafbed` | rejected | `not_a_document` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 19 | `61278450-2223-45b5-9fb7-a3cb652e5085` | rejected | `not_a_document` | `distributor_dashboard_with_code` | `proof-need-ask` |
| 20 | `42550927-a791-46ac-a837-b15f41665414` | rejected | `other_role` | `distributor_dashboard_with_code` | `proof-need-ask` |

The set is 3 accepted to 17 rejected because the run was 3 to 1,378. A set that must also test "accepts what it
should" needs more accepted rows than one run produced; the second run added one.

## The guard

`processed` is the credits a run reached a verdict for. `written` is the `verify_proof_reviews` rows found for
that run's own audit rows on a new read-only connection after the commit, never the run's counter.

| the run | exit |
| --- | --- |
| reached verdicts, none on file | 70, with the counters and an `error` line |
| reached no verdict (nothing under review, or all waiting on the reader) | 0 |
| at least one row on file | 0 |

An all-`wait_reader` run exits 0 on purpose. It reached nothing, so it owes nothing, and that backlog is the
reader's, which has its own guard (`credit-doc-verify.py` exit 70). Failing it would page every hour the reader is
behind and say nothing about the reviewer.

Paging needs no new code. The gateway records a command cron's non-zero exit as an errored receipt (read on
node-8: `credit-trust-score-approve-15m`, `status: error`, `command exited with code 3`), and
`cron-health-watchdog.sh` pages once the job has errored on `MIN_STREAK` consecutive runs (default 2) in
`cron_run_receipts`. At the hourly schedule a page follows the second consecutive exit 70; a single exit 70
between ok runs does not page. Not observed for exit 70 itself: no run has returned it.

## `cron-jobs.json` and the store

The gateway runs what `cron_jobs` in `/root/.openclaw-main/state/openclaw.sqlite` says. `cron-jobs.json` is what a
deploy imports into it (`deploy.sh` near line 3563: `saveCronStore` deletes and re-inserts the whole repo set,
`enabled` included). Two consequences:

- Editing the file on the host arms nothing. The live flip was `openclaw cron enable f760addc-c276-5003-a009-768466accda1`.
- **A deploy from a `main` that still says `enabled: false` switches the reviewer back off.** The scheduled deploy
  is 05:38Z. Read from `deploy.sh`, not observed. This change has to be on `main` before then, or the job is off
  from that deploy until this one ships.

## Undo

- Stop it now: `touch /etc/hydra/proof-reviewer.disabled` (exit 0, nothing read or written).
- Switch it off: `enabled: false` in `cron-jobs.json` and a deploy, or `openclaw cron disable <id>` until one.
- Take a run's rows back: `proof_reviewer.py revert --run-id <run>`, per run. It reports `changed_since` for rows
  a later write has replaced.

## Event-driven trigger: a proposal, no code

Firstmate's design: a systemd `.path` unit on `/var/lib/hydra-credit-verify/proof.sqlite`, 60 s debounce, the
hourly :55 kept as the sweep. Not built, by instruction, until the design is signed off. Four things measured or
read that the design should answer first:

1. **A write to `proof.sqlite` is not the event that makes a credit reviewable.** The reviewer acts on a note the
   marker has tagged (`ledger.sqlite3`) whose document doc-verify has read (`doc-verify.sqlite`). At the moment a
   document is filed, both are missing, so a reviewer fired by the filing finds that document in `wait_reader` and
   writes nothing for it. The chain today is file :15, mark :45, read :50, review :55: up to about 100 minutes from
   upload to verdict, almost all of it upstream of the reviewer. The trigger that shortens the wait is on the read
   (run mark then review when doc-verify finishes a document), or it starts at the filing and runs the whole
   chain for that one document.
2. **"Cannot miss an insert" holds for `proof.sqlite` and not for the other two.** `proof.sqlite` is
   `journal_mode=delete`, so every commit touches the main file. `doc-verify.sqlite` and `ledger.sqlite3` are WAL:
   a commit lands in `-wal` and the main file's mtime moves only at a checkpoint (seen: main file 12:57:05Z, `-wal`
   13:01:00Z). A path unit on either main file would lag by a checkpoint.
3. **A path-fired run pages nowhere today.** The exit-70 page rides on `cron_run_receipts`. A systemd service
   writes no receipt, so its unit needs an `OnFailure=` of its own or the guard is silent on exactly the runs the
   trigger adds.
4. **Two starters need one lock.** `apply` is a single `BEGIN IMMEDIATE`, so a path-fired run overlapping the :55
   run waits or fails on the lock (exit 2). A `flock` shared by both callers makes the loser skip, not error.

systemd has no debounce setting for path units. The usual shape is a oneshot service that sleeps first, since a
path unit does not start a service that is already running. Whether a change that lands during that run is
re-delivered afterwards should be tested on node-8's systemd 255 before anything relies on it; the hourly sweep
covers it either way. The repo already ships two path units through `scripts/install-aux-units.sh`
(`claim-list-build.path`, `openclaw-config-write-audit@.path`), so the mechanism is not new here.

## The decide stage: untouched, and what arming it would take

`doc_approve.py` and `claim-doc-ladder.py` were not changed. `credit-verify-proof-email` is still `enabled: false`.

From `data/proof-processing-ovh-e1/arming-wall.md` (read 2026-11-13 against `c0f06f8f`; not re-measured today),
six switches sit between a verified document and a core write: the registry row `document_small_track` is
`approved: false`; the freeze file `/var/lib/hydra-credit-verify/doc-approve.frozen` is present; `muso-admin-api.sh`
has no predicate that reads `document_small_track`; `policies/credit-trust-decide.json` has `approve_arm: false`;
no cron runs an apply (`credit-trust-decide-15m` runs `decide --mode judge`); and `expectedStatus` is fixed at
`unverified`, which left 3 of 15 verified-document requests reachable. `claim-doc-ladder.py` has no executor at
all, so arming it means writing a new approval automation and its registry row. Firstmate's gate on top of those:
the 20-request set at 20 of 20, and one anchors-push run.
