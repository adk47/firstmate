# Item 0: node-8's interim `scale_drain.py`, landed in git

Measured 2026-11-14, 20:45Z to 21:02Z. node-8 was read only; nothing on it was changed.

## What node-8 runs

| file on node-8 (`/opt/hydra/scripts/credit_review/`) | sha256 | what it is |
|---|---|---|
| `scale_drain.py` | `9c99530b…21f3` | the hand edit, live |
| `scale_drain.py.bak-before-memfix-20261114T1914Z` | `4b025ccc…6ad9` | the deployed baseline (`284745cd6`), byte for byte |
| `scale_drain.py.bak-before-nohumans-20261114T2034Z` | `65c2523b…9adc` | baseline plus a LIMIT form of `--max-rows` |
| `scale_drain.py.bak-before-nh3-20261114T2038Z` | `c7f4a828…bafd` | the first no-humans edit (proof refuse was `reject`) |

`/opt/hydra/.deployed-sha` is `284745cd6` at 21:01Z.

## What this branch carries

- The ladder hunks of the live file, byte for byte. At commit `2a605ff52`, measured then
  against the file fetched from node-8, the signed diff lines of this branch against `main`
  equalled the signed diff lines of node-8's file against its own base, apart from the two
  comment changes below. The review rounds after that commit changed comments, docstrings,
  the automation registry description and the docs, so the branch's prose now differs from
  node-8's in more places than those two. The ladder code lines are the same; the prose is
  not, and a diff against node-8 will show it.
- The bound on `--max-rows` in the filter form that is already on `main`
  (https://github.com/Muso-AI/hydra/pull/1984, merged 20:51Z). node-8's LIMIT form is not
  carried: it cuts the decided population, so a bounded plan made on node-8 today has
  wrong precedent.
- The two comment changes that were not on node-8 at `2a605ff52`:
  1. the deploy's git-wins marker at the top of the file;
  2. the `KNOWN GAP` comment in `apply()`, corrected (next section).

## The told mark did run

node-8's comment says the removed `mark_told()` line "could never run". The production
ledger (`/var/lib/hydra/credit-review/drain.sqlite`, opened read-only) says it ran:

| table | rows |
|---|---|
| `applied` | 92,398 |
| `told` | 1,324 |
| `intents` | 3,326 |
| `core_refusals` | 0 |
| `write_failures` | 0 |

| `applied` rule / outcome | rows | applied_at |
|---|---|---|
| `ask` / `ask` | 91,071 | 2026-11-11T18:41:01Z to 2026-11-14T19:15:38Z |
| `precedent` / `queue_tier2` | 1,165 | 2026-11-11T18:41:01Z |
| `proof_verdict` / `queue_tier2` | 159 | 2026-11-11T18:41:01Z |
| `proof_verdict` / `reject` | 3 | 2026-11-14T20:34:43Z |

`told` holds 1,165 `precedent_refuse` and 159 `proof_verdict_refuse` rows, all at
2026-11-11T18:41:01Z: one per `queue_tier2` row. `mark_told()` only inserts that row, and
`apply()` has no send, so no message stands behind any of the 1,324.

`told` is keyed `(request_id, reason_code)` and `applied` is append-only (a trigger
refuses UPDATE and DELETE). A later sender that calls `mark_told()` for one of those
pairs gets `False`. It must not read that as "the customer already heard".

## The rehearsal's "applied: 3"

It wrote three rows to the production ledger: `proof_verdict` / `reject` /
`proof_verdict_refuse`, at 2026-11-14T20:34:43Z. That is six seconds after the first
no-humans edit was written (20:34:37Z, kept as the `nh3` backup), the one that returned
`reject` for a refuse verdict; the live file replaced it at 20:38:12Z. No API write and no
message: `reject` is outside `WRITE_STATUS`, so `apply()`
commits a ledger row and nothing else.

Does it make the real run skip those requests? Reproduced on a scratch ledger with this
branch's code (one request with a refuse verdict, a `reject` row for it already applied):

```
plan     proof_verdict / ask / proof_verdict_refuse
apply    applied 2, skipped 0, told 0
verify   ok false, missing 0, orphans 1
```

- **Under this branch, no.** The outcome is in the decision key, the ladder now emits
  `ask` for a refuse verdict, so the key differs and the request is applied again as an
  `ask` row.
- **`verify` reports the three as orphans and returns `ok: false`**, as it will for the
  1,324 `queue_tier2` rows: no plan this code makes names those keys.
- **A later change that emits `reject` for a refuse verdict under `RULE_VERSION` "1"
  rebuilds the same key, and `apply()` skips those three requests as already applied.**
  This is read from `decision_key()` and the `already_applied` check, not run. The proof
  refusal change (item 3) has to bump `RULE_VERSION`.

## What this change does not do

A `cannot_confirm` row is a ledger row. No status is written and no customer is told.
The 500-row rehearsal produced `ask` only, so it exercised neither `cannot_confirm` branch.
`apply` with this code has not been run against the production ledger.

## The exit for a refuse precedent (added 2026-11-15)

QA refused the first head of https://github.com/Muso-AI/hydra/pull/1991 because a refuse
precedent outranked any document the customer filed later, so those rows had no exit. The
decision was to add the exit in this change: evidence newer than the refusal takes the
request out of the `precedent` rule (`SET_ASIDE_SQL` in `scale_drain.py`; the rule is in
`docs/credit-verification/scale-drain.md`).

Measured on node-8 2026-11-15 01:23Z-01:28Z, read only: one snapshot from the replica and
the stores (102,432 pending requests), built by this branch's code and planned four times
at the same `--now`.

| plan | approve | ask | `queue_tier2` | `cannot_confirm` | unmatched |
|---|---|---|---|---|---|
| deployed (`c1fbf5a22`) | 3,365 | 96,616 | 1,395 | 0 | 1,056 |
| `main` (`26181fc54`) | 3,365 | 96,616 | 1,395 | 0 | 1,056 |
| this branch before the exit (`13b851d8a`) | 3,365 | 96,839 | 0 | 1,172 | 1,056 |
| this branch with the exit, merged with `main` | 3,365 | 97,017 | 0 | 994 | 1,056 |

- Against `main`, 1,395 requests change outcome and no other request does: 994 refuse
  precedents become `cannot_confirm`, 223 refused documents become `ask`, and 178 refuse
  precedents with newer evidence become `ask` / `proof_on_file_undecided`.
- The exit is those 178 requests (44 users, 125 refusals set aside). `asks` offers 57 of
  them (28 users) to the ask path and holds 121 (17 users) for a cause no document clears:
  76 fraud, 40 band C, 4 impersonation, 1 velocity. That hold is `main`'s rule
  (`ask_hold`), not this change's.
- Of the 223 refused-document asks, `asks` offers 100 (37 users) and holds 123.
- 994 requests (176 users) stay `cannot_confirm`: 984 have no evidence on file (734 never
  asked, 250 asked) and 10 have evidence that is not newer than the refusal. Nothing tells
  those customers that evidence would reopen the request.
- 15,292 `ask` rows change reason from `no_rule_matched` to `proof_on_file_undecided`: a
  filed document names them and no verdict exists. Rule, outcome and ledger key are the
  same, so `apply` does not write them again.
- The approve set is the same 3,365 requests in all four plans.
- The DSP anchor store held 0 `built` or `written` rows, so that branch ran on fixtures
  only. The refusal time is core's `updatedat`, which is not a decided-at.
- An earlier run at 00:38Z used a tree copied without the validator's band table, so its
  snapshot read no hold cause; its outcome counts (176 set aside, 996 left, of 102,419)
  agree with this run and its ask-path split was discarded.

## node-8 after the first measurement (read only, 2026-11-15 01:52Z)

node-8's copy changed twice more after the table at the top was measured.

| when | node-8 `scale_drain.py` | what it was |
|---|---|---|
| 2026-11-14 21:12Z | `ddf5f84c…55b3` | a deploy wrote `main`'s bytes over the first hand edit |
| 2026-11-15 01:45Z | `aa481820…7a40` | a second hand edit of the deployed file (`c1fbf5a22`) |

The second hand edit changes 11 lines of the deployed file and nothing else: the outcome
name the ladder had for a refusal is replaced on each. A refuse precedent and an expiry
return `cannot_confirm` and a refuse verdict returns `ask`, as on this branch. Two of its
lines differ from this branch:

- `tier2-queue` selects `WHERE outcome = 'reject'`. The production ledger holds 3 rows
  with that outcome (the 20:34Z rehearsal), so on node-8 that command lists those 3 for a
  tier-2 approver. On this branch the command lists no row.
- `apply` calls `mark_told()` for a `reject` row. The ladder returns `reject` for no row,
  so the line cannot run. This branch has no such line.

The file on node-8 still describes a refusal as a named human's in its comments and
docstrings: 22 of its lines name a person, a tier-2 approver or `tier2-queue`, against 9
on this branch (the `tier2-queue` command itself, one error message for a row core
refused, and two comments). It does not have the exit for a refuse precedent. No timer,
cron file or running process on node-8 names `scale_drain`. The three backups taken on
node-8 before that edit (`.bak-before-filter-20261115T0110Z`, `.bak-go-20261115T0144Z`,
`.bak-go-20261115T0145Z`) are all the deployed file, `ddf5f84c…`.

The ledger at 01:52Z: `applied` 91,071 `ask`, 1,324 with the old refusal outcome, 3
`reject`; `told` 1,324. It has not been written since 2026-11-14 20:34Z.

On this branch `scale_drain.py` does not contain the old refusal outcome's name, in code,
comment or docstring, and no other file under `scripts/` or `policies/` does except one
test fixture, which seeds a ledger row with that outcome to show `tier2-queue` does not
list it. The name remains in the docs and in this record, as what the 1,324 ledger rows
carry. The merge of `main` at `e2d292252` brought it back in one test expectation, which
`7d15231e9` corrected.

## Deploy

`main` at `ab2d22298` changes `scale_drain.py` and its blob has no git-wins marker, while
node-8's copy matches neither the deployed baseline nor that blob. Read from
`scripts/lib/delta-sync.sh`, a deploy of `main` as it stands stops on that file as a
CONFLICT. This branch's blob carries the marker; `delta_head_has_git_wins_marker` returns
true for it. The same holds at 2026-11-15 01:52Z: node-8's copy is the second hand edit
and `main`'s blob (`d48676d8c`) has no marker.
