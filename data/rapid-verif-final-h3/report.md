# Rapid verifications: what the queue is, and the run for today

Lane `rapid-verif-final-h3`, 2026-11-13. Every number here was read on node-8 between 11:39Z and 13:17Z on
13 November (deployed `6e8a65d8b`), read-only. The tools that produced them are in `tools/`, their aggregate
output in `measured/` (counts only, no user ids). Nothing was sent, armed, lifted or written on node-8 by this lane.

## The answer in six lines

1. **The 3,251 "owing" figure is real, and it is not a send queue.** In a random 200 of them: 0 have no credit
   request, 22 were already asked by another campaign, 171 are held by a rule, 7 are owed an ask with nothing in the
   way. The tick accepts 1 because 3.5% of its list is askable under today's rules.
2. **`skip_already_told_uvn` (4,754) holds up.** 200 sampled: 128 carry a sent, delivered ask in the ledger and 72
   carry core's own proof-request notice with a send time. 0 rest on nothing. It is not a dead counter.
3. **The largest rule in the way is one we set ourselves, and it is the run for today.** 949 of the 3,251 are
   "class C": we told them their document was received or with the team, the document was then judged not to be
   one, and the timer is forbidden to send them the corrected ask. 62% of every gate call the tick made on 12-13
   November ended on that rule. Run against the live gate, 41 of the 57 sampled class C users would be messaged now.
4. **This PR makes class C armable by one policy row.** Until it deploys, no row can arm it (the deployed tick
   reads such a row as a malformed policy and arms nothing).
5. **Expected: 20-50 sends in the first hour of the first armed tick, 70-100 in that tick, against 2 and 4 in
   the last two ticks.** About 680 users in total (range 530-800), then the class is spent.
6. **Sending is not the constraint on verifying.** 1,403 of the 3,251 already sent a document nobody has ruled on,
   239 are validator-approved and waiting on an approve lane that is switched off, and 3,326 drain approvals are
   refused by core. Those three need decisions, listed in "What needs the captain".

## 1. The paradox, settled with a sample

Source: the 10:00Z tick's `owing-uvn.json` (generated 10:39:33Z, 3,251 users: 2,299 free, 952 paid). Sample: 200
users, seed 20261113. Each was read against the core replica (is a listed request still open), the verify ledger
(every sent row, any campaign), the proof-on-file list, the fraud holds, core's notices, and the runner's own
blockers in the runner's own order (`tools/owing_sample.py`; `measured/owing-sample.json`). The same rule was then
applied to all 3,251.

| | sample of 200 | all 3,251 |
|---|---|---|
| no open credit request | 0 | 1 |
| already asked (a sent ask in another campaign, or core's proof-request notice) | 22 | 411 |
| held by a rule | 171 | 2,741 |
| owed, never asked, nothing in the way | 7 | 98 |

Already asked, sample: gap-ask 9, reminder-1 7, first-ask-1 6. The owing list counts only a `uvn-status` ask as
"told", so a user asked by another campaign stays on it; the gate's 90-day ask lock then stops the second ask.

What holds the 171 (first rule that stops each one):

| rule | sample | what clears it |
|---|---|---|
| a document is on file with no stage-2 verdict | 65 | a verdict on the document, not a message |
| class C: an earlier status line of ours named these requests | 57 | the corrected ask; armed by the row in §2 |
| on the approval path (validator-approved, risk < 30, popularity 1-59) | 14 | an approval; never asked by design |
| gate holds: comm state 7, messaged in 7 days 6, core notice in 7 days 7, other 5 | 25 | time |
| rows already noted or asked | 5 | nothing owed |
| blank or unshowable title, artist or role 3; fraud hold 2 | 5 | data fix / lens release |

The first-blocker census over all 3,251: documents on file 1,403; class C 949 (801 free, 148 paid); approval path
239; rows already noted 166; messaged in 7 days 103; fraud hold 48; unshowable 28; asked in 90 days 16; other 5;
none 294. Of the 294 with no first blocker, the gate then stopped 196 (mostly core notice, comm state, 7-day
contact, no channel), leaving the 98.

**Read by what the person has been told**, the split is different and is the one that matters: the 57 class C users
were never asked for proof. They were told "received" or "with the team" in October (status-team-review 48,
status-doc-received 9), and 56 of the 57 have a document on file that stage 2 released as not a document. So 64 of
200 (32%) are owed an ask and have never had one, and the timer may send to 7 of them.

### The 4,754 already-told claim

`skip_already_told_uvn` was 4,742 at 10:39Z and 4,754 when sampled at 12:03Z (`measured/skipped-sample.json`).
It rests on two facts per user: a sent `uvn-status` row in the ledger, or core's `metadata.proofRequest` on an open
request.

| | all 4,754 | sample of 200 |
|---|---|---|
| ledger: a sent uvn-status ask | 2,988 (86 also carry the core marker) | 128, all with a delivered message id |
| core marker only | 1,766 | 72 |
| ...of which the marker has a `noticeSentAt` | 1,763 (661 in October, 1,102 in November) | 72 |
| ...marker without a send time | 3 | 0 |

The claim stands. Three users of 4,754 are counted as told on a marker with no send time.

## 2. The run for today

### What the tick does now (the before value)

- Sent today by 13:14Z: 93 (uvn-status 77, claim-proof-ask 10, proof-need-ask 6). Per tick, in order: 22, 17,
  21, 15, 12, then 2 (10:00Z) and 4 (12:00Z). The askable users at the front of the list were used up overnight;
  what the walk meets now is class C.
- The cron is hourly and the tick is not: the 10:00Z tick ran 10:02-11:18Z and the 12:00Z tick 12:00-13:08Z, so
  the 11:00Z and 13:00Z fires found the lock and exited. One tick per two hours.
- Over the 39 uvn-status checks of 12-13 November (`measured/tick-census.json`): 2,732 gate calls, 229 accepted,
  **1,685 answered `c2_signed_only`**. On 13 November from 06:00Z the paid check makes about 210 gate calls for 0
  accepts (139-142 of them class C) and the free check about 249 for 1-2 (231-239 class C).
- uvn-status apply is serial: measured 30 s per send at p50, 72 s at p90 (138 in-run gaps since 12 November).

### What class C would do, measured on the live gate

At 13:09Z, between ticks, the deployed runner's own recipient check was run over the 57 sampled class C users
without `--no-correction` (dry run, wrote nothing; `measured/class-c-check.json`):

| | listed | would be messaged | held |
|---|---|---|---|
| free | 49 | 38 | comm state (already acknowledged) 7, messaged in 7 days 3, markup in a field 1 |
| paid | 8 | 3 | comm state 2, messaged in 7 days 1, core notice 1, markup in a field 1 |

Unmeasured 0 against a bar of 5 in both. Every other rule ran and held who it should.

Class C is not new copy and not a first send: 390 corrected asks went on 1 November under `fable-copy-1030-r5/c2`
(ledger 6338-6994), and 50 of them have a returned document against 195 of 2,724 plain asks (12.8% against 7.2%).
The timer was held off the class by ruling `[key=scale-now]` "until class C has its own clean read-back". That is
the read-back.

### The run

| | value | basis |
|---|---|---|
| family | `uvn-status`, both segments, class C armed | the 41 of 57 above |
| caps | unchanged: 50 paid and 50 free per tick, 2,000 per segment per day, 2,500 shared | node-8 policy, read 12:46Z |
| other families | unchanged (claim-proof-ask 25, proof-need-ask 50 paid / 5 free, r1) | |
| kill files to lift | none | see below |
| unmeasured bar | unchanged, 5 | |
| first hour | 20-50 sends | paid runs first: 148 class C users x 3/8 = 56, cap 50; the low end is the 95% lower bound of 3 of 8 |
| first tick (about 1 h 45) | 70-100 sends | plus free: 239 class C gate calls x 38/49, cap 50 |
| the class in total | about 680 users, range 530-800 | 801 x 38/49 + 148 x 3/8; the paid rate rests on 8 users |
| how long | 7 to 11 armed ticks, about a day | one tick per two hours |

The cap stays at 50 on purpose. It was set after the serial apply ran into the 55-60 minute subprocess limit and
lost its outcomes at 79 sends; at 30-72 s a send, 50 is 25-60 minutes.

**Cost, stated:** each armed segment adds up to 25-60 minutes of apply to a tick that already runs 68-76. The
claim families run first and are unaffected. `proof-need-ask` runs last and will be cut or skipped on some ticks
(it sent 1-2 per tick today).

**Kill files.** None of the three needs to lift for this run, and none should lift on this evidence:

- `apply-queue.disabled`: the queue is wired to claim-proof-ask only (`policies/apply-queue.json`), which sent 10
  today. Lifting it changes no uvn-status send.
- `credit-trust-decide-provisional-paid.disabled` and `fable-decider.disabled`: both are approve arms.

### How it is armed (after this PR deploys, not before)

On the deployed tree a `uvn-status:c2` row is an unknown family: the policy reads as malformed, **nothing is armed
and the tick pages**. So the order is fixed: merge, deploy, confirm `/opt/hydra/.deployed-sha` contains this
change, then add the row to node-8's live policy, between ticks:

```
cp -p /opt/hydra/policies/credit-verify-outbound.json{,.bak-classc-$(date -u +%Y%m%dT%H%MZ)}
jq '.armed_families["uvn-status:c2"] = {"live": true, "paid": true, "unsigned_from": "2026-11-13T13:09Z"}' \
  /opt/hydra/policies/credit-verify-outbound.json > /tmp/p.json && install -m 644 /tmp/p.json /opt/hydra/policies/credit-verify-outbound.json
```

The next tick's log then says `class C (/c2 corrected asks) ARMED by its row` for each segment. Undo: delete the
row (or set `live` false, which stops both segments whatever `paid` says); the policy is re-read every tick, no
deploy. To start with one segment, set `"paid": false` and only free sends.

node-8's policy file is live state edited by hand (15 `.bak-*` beside it; md5 differs from the repo's, which has no
`armed_families` at all). This PR does not touch `policies/credit-verify-outbound.json`: a PR that did would
replace the live arming and caps at the next deploy.

## 3. The proof gap

**Before** (12:30Z): of 1,926 rows sent since 7 November, 0 carried `proof_tagged_at`. The column's only writer is
`tag-proof`, driven by a sweep whose one caller was the cron retired on 6 November; `proof_checked_at` is set on 0
rows ever. 103 older stamps exist, all written in one batch on 9 November, 102 of them dated before their own send.
Meanwhile 26 of the 409 rows that carry an account had a document filed by that account after the send (median
6.6 h later).

**This lane does not ship the fix, because another lane already ran one on the live ledger.** Lane
`proof-processing-ovh-e1` ran a marker (`proof_marker.py`, rule `pm-1`) from `node-8:/root/proof-e1` at 12:34:01Z
(534 rows) and again at 13:13:20Z (18 rows). When this was measured it had no branch, PR, timer or kill file, and
its table `proof_marks` was in the live ledger from code not in the deployed tree; it has since merged as
https://github.com/Muso-AI/hydra/pull/1942 (marker, feeder checkpointing, `docs/credit-verification/proof-path.md`).
I had built a second writer of the
same column with a different rule before finding it; it was never applied and is not in this PR. Two writers of
`proof_tagged_at` with different rules would make the column mean nothing.

**After** (13:16Z, `tools/answers_check.py report`, which reads and never writes):

| sent | campaign | resolves to an account | answered | median lag |
|---|---|---|---|---|
| 9 Nov | first-ask-1 | 162 | 0 | |
| 9 Nov | reminder-1 | 906 | 0 | |
| 10 Nov | uvn-status | 46 | 6 (13.0%) | 5.5 h |
| 12 Nov | uvn-status | 80 | 1 (1.2%) | 4.3 h |
| 13 Nov | uvn-status | 77 | 0 | |
| 11-13 Nov | proof-need-ask | 9 | 0 | |

"Did they answer" is now answerable for the tick's own rows. Two gaps remain, both for the owning lane:

- **1,517 rows sent 9-11 November carry no account id** (reminder-1 925, thread-loop-close 555, doc-result-1 37).
  `pm-1` calls a note with no account unmeasured. 906 of the reminders resolve through the one account their
  email key has elsewhere in the ledger; 19 are ambiguous.
- **`pm-1` matches on the request; an account-level match finds 208 more** sent asks with a document from the same
  account after the send (`answers_check.py plan`). Those are answers to something, not provably to that ask.
  At 12:43Z, 77 of them were asks of 9 November, so the zeros in the first two rows above are not silence.

The document feeder was also stuck: the 2-hourly filer has logged "another run is in flight" on every fire since
11 November 22:37Z. The same lane reports draining it by hand at about 13:00Z.

## 4. The approve path

**State:** `drain.sqlite` holds 3,326 approve intents, all `planned` since 11 November 18:41Z (precedent 3,323,
proof verdict 3). None lost, none written.

**Why core refuses** (`core-backend` `src/services/credit-requests/agentApprovalGuard.js`, origin/HEAD
`a3118c81c4`): an agent token may approve a row the validator did not approve only when (a) the call carries
`X-Credit-Automation-Id`, (b) that id is in config `creditTrust.automationIds`, (c) it is a key of
`AUTOMATION_APPROVAL_SCOPES`, (d) the logged-in account is one of that entry's accounts, and (e) the row is inside
the entry's scope, checked in JS and again in SQL inside the approving UPDATE. Four ids exist (`uvn-under30`,
`credit-trust-decide`, `credit-trust-score-approve`, `fable-decider`). The drain fails (a): hydra's wrapper sends
no such header for it. The merged client half (#1930) names the failure; it does not send a header.

**What registration requires.** It is not a row in a table, because none of the four scopes admits a precedent row:

1. **A new scope in core**, with its SQL twin: "this claimant already holds an approved request for this track
   with this exact role set", decided by core from its own tables. hydra's `verify_anchor.py` checks exactly that
   today, client-side; core must not take the caller's word. Plus the guard's unit and SQL-twin tests.
2. **A service account of its own** (the guard requires one per automation, never a shared ops token), with the
   `credit-automation` role, and its credentials on node-8.
3. **The id added to `CREDIT_TRUST_AUTOMATION_IDS`** (default in `config/default.js`; an H-DevOps change if prod
   sets the variable).
4. **hydra:** the drain logs in as that account and the wrapper sends the header on the drain's approve only.
   About ten lines beside the four existing branches (`muso-admin-api.sh` near line 3673), in both wrapper copies.
5. **A core deploy.**

The 3 proof-verdict intents could instead go through the existing `anchored` scope (anchor kind
`proof_verification` exists), which needs an anchor record written by one account and the approve made by another.

**Can it land today: no.** Nothing is in flight: no core branch or open PR mentions the drain or a precedent
scope (searched 13:14Z). Items 1 and 2 are a new approve authority in core, a new production account and a core
deploy. hydra's own entry is captain-approved (`captain-1111-night-order`); core's is a second, separate register.
With the core PR written today, tomorrow is realistic.

## 5. What needs the captain, and what does not

**Does not need him:**

- **Arming class C.** Capped (50 and 50 per tick), one family, copy he approved and already sent 390 times, undo
  is one row. It needs this PR merged and deployed, then the row above. If he wants to say it anyway: **"arm class C"**.
- The proof marker (lane `proof-processing-ovh-e1`; merged as https://github.com/Muso-AI/hydra/pull/1942).
- The hydra half of the approve path once core has an id.

**Needs him, one line each:**

1. **The drain's approve authority in core.** A new scope that lets an automation approve validator-declined rows
   on precedent. The line: **"register the drain in core on the precedent rule"**. Without it the 3,326 wait.
2. **The low-risk approve lane.** 239 of the 3,251 (and 310 requests on the paid list alone) are validator-approved,
   risk under 30, and are deliberately never asked. The lane that approves them, `credit-trust-score-approve-15m`,
   has his recorded approval (20 October, "approve low risk credits") and a registered scope in core, and its
   cron is `enabled: false` with no reason on the row. Those users are in neither lane. The line: **"turn
   score-approve back on"**, or the reason it is off.
3. **claim-status.** It would send 17 a tick (7 paid, 10 free at 12:00Z) and has sent nothing since 7 November.
   When arming moved from two global files to per-family rows on 9 November it was given no row, and it has
   never had one. I found no ruling that held it. The line: **"arm claim-status"**. It is bounded by the
   shared claim cap of 25 a day.

**Not a decision, a queue:** the 1,403 users with a document on file and no verdict. No message moves them; a
stage-2 verdict does. That, and not the send rate, is where verification is waiting.

## 6. 10 November's 568

| day | sent | what it was |
|---|---|---|
| 9 Nov | 1,087 | reminder-1 925 + first-ask-1 162, email |
| 10 Nov | 568 | **thread-loop-close 522** (in-thread comments, from 17:28Z) + uvn-status 46 |
| 13 Nov by 13:14Z | 93 | uvn-status 77, claim-proof-ask 10, proof-need-ask 6 |

The tick did not send 568 on 10 November. It sent 46. The other 522 were one pass of a one-off driver closing the
loop on open threads, recorded as approved by `agent-thread-loop@muso.ai` under "captain 2026-11-10 no humans"; 9
November was two more one-off drivers. None of the three campaigns is named in hydra's tree, `/opt/hydra/scripts`
or any cron on node-8, and the reminder and loop-close rows carry no account id.

So the tick's rate was not lost: it is higher today (93 by 13:14Z) than on 10 November (46). What was different is
that a finite audience was sent once, by hand, outside the tick. It cannot be restored by re-running: the threads
are closed and a reminder goes once. The equivalent today is another finite audience, and class C is it: about
680 users, through the tick, with every gate on.

## What is in the PR

- `scripts/credit-verify-outbound.sh`: class C is armed by its own `armed_families` row, per segment
  (`c2_args`). No row, `live: false`, no date, a future date, legacy arming or a malformed policy all keep
  `--no-correction`. The paid segment needs `live` and `paid` together. The row never arms the family.
- `scripts/tests/credit-verify-outbound.bats`: six cases; five mutations of the rule each fail at least one.
- `docs/credit-verification/verify-request-notes.md`: the row, its cost and its undo.
- `data/rapid-verif-final-h3/`: this report, `tools/` (four read-only scripts), `measured/` (their aggregates).

## Not done, and found on the way

- `uvn_new_rows`: 1,267 listed users, 0 sends ever, and no family in the tick runs that campaign.
- The r1 (document received) walk costs 24 minutes a tick for 0 sends; 71-80 users are refused every tick for
  `r1_filing_class_unknown` and walked again the next.
- The hourly cron yields one tick per two hours.
- The paid class C rate (3 of 8) is the weakest number here; the first armed paid check replaces it.

## Follow-up, 15 November: the census is part of the tick

The census that settled section 2 (`tools/tick_census.py`) was a script run by hand. Nothing in the tick read its
own yield, so the same shape could come back unseen, and by 15 November it had: `r1-free` 23 ticks running with
3,288 gate calls and 0 accepted, `uvn-status-paid` 8 ticks with 491 and 0. `scripts/credit_review/tick_yield.py`
now runs at the end of every tick and pages a segment that makes gate calls and sends nobody three ticks in a row
(`docs/credit-verification/verify-request-notes.md`, `[key=tick-yield]`). The other tools here (`owing_sample.py`,
`subset_list.py`, `answers_check.py`) answered a one-time question and fix nothing; class C itself is a policy row
the tick re-reads every run, and it sent 383 `uvn-status` asks on 15 November with nobody starting it.
