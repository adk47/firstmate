# The established-claimant rule (shadow)

`scripts/credit_review/established_claimant.py`, policy `policies/established-claimant.json`.
Tests: `scripts/tests/test_established_claimant.py` (the rule and the scheduled pass) and
`scripts/tests/install-aux-units-established-claimant.bats` (the timer).

It reads the core replica, decides, and writes two files. It approves nothing, asks nobody and
calls no API. `established-claimant.timer` runs it once a day on node-8; nobody starts it.

## The rule

A pending credit request is **established** when all of these hold:

1. Its profile has 100 or more approved requests, and rejected requests are 1% or less of the
   approved and rejected together (`profile_passes`; the two numbers are the policy file's).
2. The same user already holds an approved credit in **every** role the request claims.
3. Each of those credits is on a track that shares an artist id with this request's track.

An established request then gets one of three outcomes (`decide`):

| outcome | when | what the module does with it |
|---|---|---|
| `approve` | the validator's own verdict says approved (`is_approved` is `true`) and nothing below applies | records it |
| `ask` | the validator declined it, or recorded no decision, or holds it for a cause a document can clear | records it; the ask itself belongs to `need_asks.py` |
| `barred` | a hold no document clears, an earlier removal or revert, or a verdict that is missing or cannot be read | records it; nobody is asked |

Two rulings fix the edges (firstmate, 2026-11-15):

- **A hold is honoured by every rule, for every person.** A record of 596 approvals does not
  outrank a hold. Which holds bar and which ask is `policy.never_ask`, the one reading the
  drain, uvn-status, `need_asks.py` and claim-proof-ask already share: fraud, impersonation,
  band C, a legal hold, a credit the profile already has and an evaluation error bar; the
  band B proof rules ask.
- **A request the validator declined is never approved** (captain 2026-10-26: "do not approve
  validator-declined rows"). It is an `ask`. Whether a precedent may ever approve a declined
  request is a held decision and this rule does not reopen it.

Three bars are not in the rule's one-line wording and are applied anyway, because each is a
case no approver here acts on: a request whose `metadata` carries `fraudRemoval` or
`precedentRevert`, a validator-approved request carrying a hold code that core's guard does
not act on (`verify_anchor.uncovered_holds`; the drain's `held_by_validator`), and a verdict
that is absent or unreadable.

## The scheduled pass

`established-claimant.timer` (03:20 UTC, `Persistent=true`) starts `scripts/established-claimant.py`,
which runs `tick`. The unit is installed, enabled and started by `scripts/install-aux-units.sh`
on every deploy, and it is in the `OnFailure` table, so a failed pass pages `#clio_devops`.

- A pass whose reads all finished is published as
  `/var/lib/hydra/established-claimant/runs/<UTC time>/` and `latest` is moved to it. The two
  files are written to a hidden directory and renamed into place, so a pass exists whole or
  not at all.
- A pass that could not finish (the replica did not answer, or the verdict read did not
  return a row it asked for) publishes nothing and exits non-zero. `latest` stays on the last
  complete pass. Read `latest/funnel.json` for the count, never a pass's directory by name.
- The 14 newest passes are kept.
- Nothing has to be done between two passes. The stop switch is
  `/etc/hydra/established-claimant.disabled`: while it is present a pass reads nothing and
  exits 0. Nothing in the repo creates it, so a pass never waits on it being removed.
- The unit is capped at 2 GB and one CPU. A pass is about 210 statements over about 20
  minutes.

## What it writes

A pass writes `decisions.jsonl` and `funnel.json` and prints the funnel. `run --out DIR`
writes the same two files into `DIR` and publishes nothing.

- `decisions.jsonl`: one row per established request, sorted by request id, sorted keys, no
  clock and no run id, so two runs over the same data are byte-identical. A row carries the
  outcome, its reason, every bar that applies (`bars`), the request each claimed role is
  anchored on (`anchors`, the lowest approved request id of that user, role and artist), who
  approved the credits it rests on (`basis_via`), and on an `approve` row what core's approval
  guard would answer (`core_guard`, from `policy.server_approval_refusal`).
- `funnel.json`: the count at each step, each outcome, each reason and each bar.
  `left_pending_between_reads` counts a request that stopped being pending, or was deleted,
  between the pending read and the verdict read: it is not decided, and it is not a failed
  read.

Exit 0 when every read finished, 1 when the verdict read did not return a row it asked for
(`verdict_row_not_returned`, which a deleted row is not), 2 when the policy cannot be read
or asks for a mode other than `shadow`.

To read the newest answer:

```bash
cat /var/lib/hydra/established-claimant/latest/funnel.json
systemctl list-timers established-claimant.timer
```

A pass outside the schedule is `systemctl start established-claimant.service`, which keeps the
unit's memory cap. `run --out DIR` is for a scratch copy and must be run capped
(`systemd-run --scope -p MemoryMax=2G -p CPUQuota=100%`).

## How it reads

Five kinds of statement, none of which joins the table to itself:

1. pending requests by status (one statement);
2. approved and rejected counts for every profile with 100 or more approved and something
   pending (one grouped statement);
3. the pending requests on the profiles that pass, 200 profiles a statement;
4. those users' approved requests, grouped by role list, artists and approver, 200 users a
   statement;
5. the verdict parts and current status of each established request, by id, 200 a
   statement.

The verdict is read part by part (`VERDICT_PARTS`), extracted on the server: a whole
`verificationdata` can be longer than the CSV reader's field limit. An id that is not a UUID,
or a user id that is not a number, raises before any statement is built.

Artists are matched by id only. The same artist under two id schemes does not match, so the
established count is a floor.

## Measured on production

Run on node-8 against the production core replica, read-only and memory-capped, 2026-11-15
19:39Z to 19:57Z (the module at this change, the deployed `policy.py` and band table):

| step | requests |
|---|---|
| pending | 102,672 |
| on a profile that passes the bar (1,977 profiles) | 36,333 |
| established | 13,833 |
| **approve** | **2,078** (476 users) |
| ask: the validator declined it | 7,950 (557 users) |
| barred | 3,805 (300 users) |

What bars the 3,805, by the first bar on the row:

| bar | requests |
|---|---|
| velocity hold, not on an editing role (band C) | 2,345 |
| removed as fraud or reverted before | 475 |
| impersonation: the role is credited to someone else at a trusted source | 376 |
| band C, other | 283 |
| fraud hold | 211 |
| the credit is already on the profile | 88 |
| evaluation error | 27 |

Of the 36,333, 402 carry no artist id, 23 no user, and can never match.

About the 2,078:

- **Core's guard would refuse every one of them** as `proof_required`: 2,040 carry band hint
  B and 1,532 a proof request. That is derived from each row's stored fields with
  `policy.server_approval_refusal`; no write was attempted.
- Track popularity: 0 on 1,071, 1 to 29 on 786, 30 to 59 on 211, 60 or more on 10.
- 45 rest only on credits `precedent_v1` approved.
- One user holds 90, one 51, and no other more than 40. The user with 90 (1409452) is the
  account measured on 2026-11-03 holding 2,301 pending requests, whose approvals that day
  came from duplicate-only verdicts with no velocity check.
- 30 rows from 30 users were re-read by id with a different statement (target pending,
  validator-approved, no hold; each anchor approved, same user, same role, shared artist):
  30 agree.

A first run at 18:59Z with the same rule gave the same 2,078 requests.

The 2026-11-14 count of 9,895 was the rule before the two rulings: it approved requests the
validator had declined (7,909 of them).

## What arming it would take

Nothing in this change approves. Before any `approve` row is written:

- **A recorded captain decision and a registry row.** Turning this file's rows into approvals
  is a new approval automation: `policies/credit-approval-automation.json`, with
  `approved_by` and `approval_ref`.
- **A registration in core.** Core's guard answers `proof_required` for a request whose
  verdict carries a band hint other than A or whose metadata carries a proof request, and
  that is nearly every `approve` row (`approve_core_would_refuse` in the funnel). These
  requests are pending because core asked the claimant for proof although the validator's
  score approved them. The rule approves them on the claimant's record instead; core will
  refuse that write until the automation is registered there for it.
- **A write gate that re-reads each row.** A decision file is a snapshot. The drain's gate
  (`verify_anchor.py`) re-reads the live request before each write; an established-claimant
  write needs the same check of its own facts (still pending, still validator-approved, still
  unheld, each anchor still approved).
- **Caps.** The rule reaches accounts in bulk, so a first live rung is small and read back,
  as the drain's is: a cap per run and a cap per user. At 5 per user the 2,078 would take
  1,240 on a first pass and hold 838.
