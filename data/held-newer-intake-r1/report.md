# held_newer_intake: what the rule is

Read at `122412404` (main). Part 1 of 3: the rule and the 10-user table. The rule change and the timing follow.

## The rule

`held_newer_intake` is the count of (user, need) pairs the proof-need-ask builder drops because the user has sent
us something after the document the ask would name. The proof-need-ask message says "the document you sent on
{date} can't be checked, please send X"; it names the newest document of one need group that doc-verify read as
`unverifiable`. The rule holds that ask when ANY `proof_intake` row of the same user arrived later than that
document, whatever the later file is, which request it was filed against, and whether doc-verify has read it. So it
protects against asking a customer to replace a document they have already followed up on: the later intake may be
the answer to the ask we are about to send. It is a superseded-document guard, and it is not a double-ask guard:
it reads no ask history at all (the "already asked" rule is a separate ledger read,
`scripts/credit_review/need_asks.py:900-907`). It also has no window and no release: the predicate compares two
timestamps, so a user whose later intake is never read, or is read and yields nothing askable, is held on every run.

The line that sets it, `scripts/credit_review/need_asks.py:643-646`:

```python
if comm_state.newer_intake(newest["doc_received_at"], u.get("arrivals") or [],
                           {str(a.get("intake_id") or "") for a in docs if a.get("intake_id")}):
    held.append(f"user {uid}: {need} (an intake newer than its newest document)")
    continue
```

The predicate, `scripts/credit_review/comm_state.py:593-594` (inside `newer_intake`, defined at line 583):

```python
if ts > t or (ts == t and iid and iid not in named):
    return True
```

`t` is the named document's arrival, `ts` each intake's arrival; the second clause counts a different intake in
the same second as newer. The list becomes `report.held_newer` at `need_asks.py:921` and the printed
`held_newer_intake` number at `need_asks.py:1255`. The gate applies the same predicate again at send time
(`comm_state.py:680-681`, reason `newer_document:proof_intake`, surfaced by `decide` at `comm_state.py:757-759` as
`newer_after_document:`).

## Ten held users

Store and columns: the two dates the rule compares are both `proof_intake.received_at`
(`/var/lib/hydra-credit-verify/proof.sqlite` on node-8), read here from the builder's own list
`/root/h2-runs/sched/20261115T0500Z/need-asks-all.json` (generated 06:10:23Z, the list the 06:10-06:21Z paid segment
ran on), where they are `asks[].doc_received_at` and `arrivals[]`. The last column is
`max(createdat)` of `postgresql_core.public.credit_requests` (`deletedat IS NULL`, by `userid`), one replica query.

| user | need the ask would name | named document arrived | newest intake arrived | gap | later intakes | newest intake askable on this list | held on every need | newest credit_requests.createdat |
|---|---|---|---|---|---|---|---|---|
| 118230 | distributor_dashboard_with_code | 2026-07-23T22:42:39Z | 2026-11-13T20:37:15Z | 112.9 d | 1 | readable_document | no | 2026-11-06T19:02:17Z |
| 4519 | readable_document | 2026-08-28T22:12:14Z | 2026-11-13T12:52:04Z | 76.6 d | 3 | distributor_dashboard_with_code | no | 2026-11-13T12:39:30Z |
| 100098 | counterparty_signed_or_registered | 2026-11-06T22:11:17Z | 2026-11-14T04:31:03Z | 7.3 d | 2 | distributor_dashboard_with_code | no | 2026-11-11T12:02:16Z |
| 29196 | counterparty_signed_or_registered | 2026-10-30T08:37:09Z | 2026-11-01T00:36:25Z | 40.0 h | 1 | distributor_dashboard_with_code | no | 2026-11-12T17:04:21Z |
| 261345 | distributor_dashboard_with_code | 2026-08-18T22:14:04Z | 2026-08-18T22:18:39Z | 5 min | 1 | readable_document | no | 2026-11-01T22:15:47Z |
| 65574 | distributor_dashboard_with_code | 2026-08-08T01:20:22Z | 2026-08-08T01:20:22Z | 0 s | 3 | no | yes | 2026-11-13T18:49:19Z |
| 84537 | readable_document | 2026-11-02T19:42:06Z | 2026-11-02T19:42:06Z | 0 s | 2 | distributor_dashboard_with_code | yes | 2026-11-08T06:45:11Z |
| 145833 | counterparty_signed_or_registered | 2026-10-24T06:49:57Z | 2026-10-24T06:49:57Z | 0 s | 1 | no | yes | 2026-10-22T00:19:55Z |
| 193646 | distributor_dashboard_with_code | 2026-11-09T22:14:59Z | 2026-11-09T22:14:59Z | 0 s | 1 | no | yes | 2026-11-07T20:55:41Z |
| 315238 | counterparty_signed_or_registered | 2026-07-14T23:09:26Z | 2026-07-14T23:09:26Z | 0 s | 1 | distributor_dashboard_with_code | yes | 2026-10-06T14:16:47Z |

The ten are every 16th held user by user id, shown by gap descending; nobody was hand picked. Script:
`data/held-newer-intake-r1/tools/held_table.py` (reads the list and calls the deployed `comm_state.newer_intake`;
opens no store, writes nothing).

A column that was asked for and is not what the rule reads: `credit_requests.createdat`. The rule never looks at
when a request was created; "intake" in `held_newer_intake` is a `proof_intake` row, a file the user sent. The
column is in the table as asked, and it shows one thing of its own: in 5 of the 10 rows the user's newest request
was created after their newest intake, so they have filed requests since without sending a file.

Over all 725 paid users on that list:

| measure | count |
|---|---|
| users with at least one need held by this rule | 161 |
| (user, need) pairs held | 207 |
| users held on every need they have on the list, so no payload is possible | 71 |
| held users whose newest intake arrived in the same second as the named document | 50 |
| ... 1 s to 10 min after it | 28 |
| ... 10 min to 24 h after it | 22 |
| ... 1 to 30 days after it | 35 |
| ... more than 30 days after it | 26 |
| held users whose newest intake is itself an unverifiable document with a sendable need on this list | 110 |

What the rows say about the rule:

- **Nearly half of the holds are not a follow-up.** 78 of 161 held users have their "newer" intake within 10 minutes of
  the named document, 50 of them in the same second. That is the second clause of the predicate (a different
  intake in the same second counts as newer): another file of the same sitting, not an answer to anything.
- **For 110 of 161 the newer intake has already been read** and is on this same list as a document we could ask
  about (under another need in each of the seven sampled rows where it applies). The rule holds the older need and says nothing about the newer one; whether the user
  is then asked about the newer one depends on that need's own requests still being pending and unasked.
- **Nothing releases a hold.** Seven of the ten named documents are older than two weeks and five are from July
  or August. A past date does not change, so the same rows are held on every run.

Limits of this table. It repeats the builder's grouping but not its live re-read of which requests are still
pending and not yet asked, so it reproduces 9 of that run's 10 `held_newer_examples`; the tenth
(`user 53558: distributor_dashboard_with_code`) is not explained here. It counts the whole paid list, where the
run counts one 200-user page, so its 207 pairs and the run's 31 are not the same measure.

## What the newer intake is, and whether it was asked about

`data/held-newer-intake-r1/tools/classify_held.py` on the same 06:10Z list, read-only (the list, `proof.sqlite`,
`doc-verify.sqlite`, and `verify_requests` in the verify ledger). For each held user it takes the newest intake that
holds one of their needs. Window: `REASK_LOCK_DAYS`, 90 days. Raw output: `classify-held-0610Z-v2.txt` (the first
run, `classify-held-0610Z.txt`, took the user's newest arrival overall, which for a same-second pair can be the held
document itself; it is kept and marked).

| the intake that holds | all 161 held users | the 71 held on every need |
|---|---|---|
| on the list, sendable need, its requests never asked (`askable_unasked`) | 105 | 20 |
| on the list, its requests asked inside the window (`asked_in_window`) | 5 | 0 |
| on the list, asked longer ago than the window | 0 | 0 |
| read as unverifiable, need `issuer_email_from_official_domain` (no ask exists for it: `verify_at_off`) | 36 | 36 |
| read as unverifiable, need `distributor_dashboard_with_code`, not on the list | 4 | 4 |
| read as `unknown` (our reader did not answer) | 5 | 5 |
| not read by doc-verify | 4 | 4 |
| read as verified | 2 | 2 |

Of the 71 held on every need, 50 are held only by an intake of the same second and 21 by a later one.

What this says before any rule is changed:

- **The 90 users held on one need and not on another can already be asked about their newest document today.** The
  builder skips the held need and moves to the next one; 85 of those 90 have an askable newer document with no
  proof-need-ask row. Whether that ask then goes is the builder's other filters and the gate, not this rule. The
  hold costs them the older need, not the message.
- **The users this rule silences are the 71, and "ask about the newest intake" reaches 20 of them.** Those 20 have
  an askable document that is itself held, which can only be by a file of the same second (nothing is later than
  the newest holder).
- **For 51 of the 71 there is no newest intake to ask about.** 36 are held by a document whose need has no ask yet
  (the issuer-email need is switched off), 4 by a distributor document that is not on the list, 2 by a document that
  verified, and 9 by a document our reader has not answered (5 `unknown`, 4 unread). What to do with these is the
  open question for part 2: the brief's rule (hold only when that intake was asked about inside the window) lets
  the older document's ask go for all 51, including the 9 where we have not read what the customer sent.
- **An ask inside the window explains 5 of 161 holds.** The case the hold is meant to keep is the rare one.

## The 07:06Z pass in the brief is not on node-8

The brief's numbers (sent 0 of 200, deferred 194, 173 held_newer_intake, refused 5, 525 of 725 filtered) match no
run record I could find. The 07:00Z tick wrote one line and exited: another tick held the lock. No `.out`, `.log`
or `.json` under `/root`, `/var/lib/hydra` or `/var/log` written in the three hours before 08:02Z carries a
`held_newer_intake` other than the 0500Z tick's files, and the literal `"held_newer_intake": 173` is in none of
`/root/h2-runs`, `/root/c2-runs`, the outbound state directory or `/var/log/credit-verify-outbound.log`. That search
does not cover another host or a number derived by hand. The last paid proof-need-ask pass on record is the 0500Z
tick's, 06:10:25Z to 06:21:15Z:

| step | listed | candidates | accepted | deferred | refused | filtered | sent | held_newer_intake |
|---|---|---|---|---|---|---|---|---|
| check | 200 | 50 (tick cap 50) | 1 | 35 | 14 | 150 | 0 | 31 |
| apply | 200 | 1 | - | 0 | 0 | 199 | 1 | 31 |

So on the record that pass sent 1, not 0, and held 31 pairs, not 173. The one figure that does match is 725: the
paid users on the builder's list. The table above therefore uses that 06:10Z list, not a 07:06Z one.

## One thing the code says about those numbers (not checked against an outcomes file)

The builder hold runs in `payloads()`, before any gate call. A user it holds on every need gets no payload and is
recorded as `filtered` (`need_asks.py:666-668`), not as a gate `deferred`. So by construction the 173 are not a
subset of the 194 gate deferrals: they are (user, need) pairs among the 525 filtered before the gate, and one user
can count twice (once per need). The gate's own deferrals for this cause carry a different reason string,
`newer_after_document:`. Which reasons the 194 actually carry has to be read from the run's outcomes file.
