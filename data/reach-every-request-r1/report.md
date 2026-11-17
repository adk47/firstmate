# Reach every request: which family reaches each un-contacted group, and what binds it

Measured on node-8 (`ovh-node-8`, 40.160.32.80) on 2026-11-16 between 02:20Z and 04:10Z, from the
tick's own artefacts (`/root/h2-runs/sched/<stamp>/tick.log`, `*-check.json`, `*-apply.json`), the
shared verify ledger (`/var/lib/hydra/credit-review/ledger.sqlite3`, table `verify_messages`), the
audience builders' own output (`need-asks.json`, `owing-reminder-14.json`, `claim-list.json`) and the
live policy `/opt/hydra/policies/credit-verify-outbound.json` (byte-identical to this repo's copy at
measurement time). Nothing here is taken from the brief: every number below was re-measured, and two
of the brief's premises did not survive.

## The number: never contacted, BEFORE

**2,939 distinct people** are owed a message today by the three groups a family can carry, measured
as the union of the three audiences the tick itself builds (02:14Z-02:45Z):

| Audience | People | Source |
|---|---|---|
| Owed proof, never asked | 1,585 | `need-asks.json`, 02:45:41Z |
| Reminder due, never reminded | 782 | `owing-reminder-14.json`, 02:28:42Z |
| Claim status never told | 629 | `claim-list.json` 02:10:05Z (874 un-told claims) |
| **Union** | **2,939** | overlaps: need∩claim 54, reminder∩claim 3, need∩reminder 0 |

Two further groups have no family at all and are not in that number: profile merges (135 shadow
`link_proposals`, no merge store on node-8) and Intercom threads waiting on us (880 in
`support-backlog.json`, 03:36:01Z). The brief's 2,173 was a different query; this is the one the tick
can reproduce, and it is the figure the AFTER is measured against.

## The five groups

| # | Group | Armed family that would carry it today | Measured count | Binding cap | Reached since 02:00Z? | This change |
|---|-------|----------------------------------------|----------------|-------------|-----------------------|-------------|
| 1 | Owed proof never asked | `proof-need-ask` (armed 2026-11-10T02:17Z) | **1,585 users** listed (`need-asks`, 02:45:41Z) | **Not the cap.** The gate accepts 0-1 of 50 candidates per segment per tick; the family sent 1, 2, 10, 5, 17, 1 a day 11-11..11-16 | No (0 accepted of 100 candidates in the 02:00Z tick) | **daily 400 -> 1,585, tick 50 -> 100** - 100 is the family's own `FIRST_CAP` ceiling (a higher tick number is inert), and what bounds how much is *examined* is the page and the deadline, not this row |
| 2 | Claims never told | `claim-status` (armed 2026-10-31T17:55Z) | **874 un-told status claims / 629 people** of 1,904 in `claim-list.json`; 756 already told | **`shared_daily_cap.claim` = 25/day** for both claim families together - the family's own 500/500 row never binds, because a claim runner's `done` is 0 by design | No (the 02:00Z tick skipped the claim lane on a stale list; the 03:00Z tick never started - see "The tick is not hourly in practice") | **Not this change.** The group's one claim cap is carried by **hydra #2076** (**500/day**, the send gateway's claim allocation - the policy matches the ceiling that actually binds instead of sitting under it); this PR records the measured before - 21 sent of 25, 478 held `over today's cap`, ~35 days for 874 - and the arithmetic that shows why the rows never bound |
| 3 | Credits waiting on us never told | `uvn-status` (armed 2026-10-31T18:02Z) | **2,703 users** owed (`owing-uvn.json`, 02:28:42Z); 864 on the paid list, 1,845 on the free list | **`tick_cap.uvn-status` = 50** binds the free segment (50 of 1,845 messaged); the paid segment is bound by eligibility (5 of 864) | Yes - 5 paid + 50 free sent in the 02:00Z tick | **No cap raised** - see "Caps not raised" |
| 4 | Profile merges never told | **None** | 135 `link_proposals` rows, all `kind=link_tray, mode=shadow`; no merge store on node-8 (`/var/lib/hydra/merge-intake` holds only an empty `keep-conflict-unflagged/`) | n/a - there is no family to cap | n/a | **Reported as unreached**; what building one requires is below |
| 5 | Intercom never answered | **None, and none should exist here** | `support-backlog.json` 03:36:01Z: 9,795 open, **880 waiting on us**, 4,230 open commitments (4,110 overdue, 1,471 unbacked), 4,125 messages held | n/a - Caroline's lane | n/a | **Reported as unreached by any outbound family**; confirmed Caroline's lane, not duplicated |

### Group 1: the 400/day cap was not what held this group

The brief's premise ("proof-need-ask at 400/day against 1,159 owed is the clear one") does not hold on
the live tick. The family sends 1-17 a day, and the reason is upstream of any cap:

- 02:00Z tick, free segment: `candidates 50, accepted 0, gate_non_send 50, deferred 49, refused 1,
  held_newer_intake 1`; paid segment: `candidates 50, accepted 0, gate_non_send 50, deferred 47,
  refused 2`. Both segments: "the check accepted nobody; no apply this tick".
- The refusals are `G2: conversation ... was opened by us (an admin or bot), not the customer` and
  `held_newer_intake` (an intake newer than the newest document). The deferrals are `comm_state`
  holds: the user owes something else, or has an open ask.
- The page does advance (free 782 -> 833, paid 512 -> 563), so the family walks the 1,585-user list
  at ~100 candidates a tick and converts ~0-1 of them.

**What the raise does and does not do (QA finding on #2086, corrected here).** The daily cap only stops
a day being spent on the same list twice; it never bounded examination. Examination is the page plus the
deadline: `page_entries()` returns `CHECK_ENTRIES` (200) per segment per tick, and the tick deadline cuts
it - the measured ticks walked **51 candidates per segment**. And the per-segment ceiling on what may be
*accepted* is not the tick row at all: `family_cap()` holds a family with no `FULL_CAP_FROM` entry at
`FIRST_CAP` (100), and `tick_cap` can only lower. So the honest statement is:

- the tick row moves **50 -> 100**, i.e. from a clamp below the family's own first-batch ceiling to that
  ceiling. Writing 150 there changes nothing, and a number that reads like a promise while binding
  nothing is the class of bug the follow-up PR's guard exists for;
- **the list is not examined inside one day by this change.** At the full page (200 per segment, 400 a
  tick) 1,585 is ~4 ticks; at the measured walk (51 per segment, ~100 a tick) it is ~16 ticks, i.e. one
  to three days depending on how much the deadline gives back. Both numbers are arithmetic on constants
  in the tick, not a measurement of the next 24 hours;
- sends stay where the gate puts them (0-1 of 50 candidates accepted per segment), and moving the gate's
  rules is a copy/decision change out of scope here.

### Group 2: the claim cap is another PR's, and this one records what it measured

`room()` is `min(cap, daily - done, shared - used)`, and for a **claim** runner `done` is 0 by design:

```
for ... family claim-status|claim-proof-ask ...:
    done = daily_claim_count(...)   # ledger rows for BOTH segments today
```

So `daily - done` is always the whole 500 row and never binds; `shared - used` is the group's real
ceiling. `shared_daily_cap.claim` was 25, so both claim families together could message **25 a day**,
and 874 un-told status claims sat behind that - about **35 days**, not the ~1.6 days a per-segment
reading predicts. Measured on node-8 the same day: **21 sent of 25** (`claim-status`, ledger day
2026-11-16) and the 08:09:23Z check line holding **478 claims for `over today's cap (next run)`** -
the cap, not the audience, was the binder.

**This change does not raise it.** The group's one claim cap is carried by **hydra #2076**, which steps
it to **500**, which is the send gateway's claim allocation for the route. The derivation is the point, not
the value: 500 is what the gateway will ever give this route, so a policy number at 500 matches the ceiling that
actually binds, and a policy number above it would be a number that never binds - the exact defect this PR
exists to fix. The number it is stepping *towards* is
argued from arithmetic rather than taste: two claim families x paid/free is four
runs, the tick grants each at most its own `CLAIM_CAP` (250 a segment, `credit-verify-outbound.sh`), so
what the rows *ask for* is 4 x 250 = **1,000** - and the send gateway allocates this route **500/day**
(`notify` 3,000 split credit 2,500 / claim 500, see "The warm-up limit, measured"). The binding number
is therefore the gateway's 500, not the policy's and not the rows': the policy sits at it, and
the guard added in the follow-up PR fails only when hydra asks for more than the gateway will ever give. A policy number *above* the rows is
a promise the rows cannot keep; a policy number *below* them - which 25 was - is a ceiling nobody can
see. What this PR does on this group is leave the number alone and record the measurement it was
holding at, so the change that moves it can cite one.

The rows were never binding *below* the shared number, and that is the bug of the class: at 25 both rows
were decorative and the group's
real send rate was whatever the shared number said. The step to 500 is what makes the rows bind. The ceiling that actually answers at send time is read
**empirically**, because it is the gateway's answer and not a file: `scripts/credit_review/bulk_queue.py`
`WARMUP_GATES` includes `route_ceiling`, and `classify_email()` maps the gateway's answer to an outcome,
deferring the send to the next UTC midnight when the ceiling fires. An allocation is not a proven rate -
it is the number the gateway admits by policy - so the first `route_ceiling` reply, not this document,
is what tells us what the route really takes.

**No `route_ceiling` answer exists on node-8 yet.** Grepped for it in
`/var/lib/hydra/credit-verify-outbound` (nothing) and read every `deferred` reason in today's ledger
rows (all `copy_review_hold: copy_review_pending`, none a ceiling) at 08:50Z. So the claim allocation
has never actually refused a send, and the first answer that fires is owed with both numbers: the
policy cap asked for and the allocation that answered. Until one fires, the claim group's real send
rate is whatever the gateway admits; 500 is the allocation it should admit, not a rate we measured.

One correction to the premise that came with the gate: `daily_cap` is **not** a per-segment 1,000 a
day for this family. The row is per segment in name only for claim runners, because `done = 0` for
both segments - the arithmetic above is what runs. `main.env` on node-8 (83 keys) carries no warm-up
key either way, which is what `scripts/claim-status-daily.sh` used to claim; that comment now says
where the ceiling really lives.

### Group 4: what building a merge family would require

There is no merge-outcome family in the credit-verify tick, and no store for one on node-8. The only
merge sender in the tree is `scripts/merge-outcome-notify.py` (S5): it replies in-thread on a ClickUp
ticket tagged `merge-outcome:{merged,needs-evidence,not-merged}`, runs on its own timer
(`*:05/15`), is copy-gated, skips anything younger than 7 days and holds keep-conflicts. It is not a
`credit-verify-outbound` family and has no `armed_families` row.

Building one would require, in this order: (1) a merge-outcome store on node-8 that names the
requester and the merge (today the only merge-shaped rows are 135 shadow `link_proposals`, which are
proposals, not outcomes); (2) an audience builder with the same shape as `need_asks`/`owing_proof`
(one row per user, a reason per skip, a signed list); (3) approved copy for the outcome, which is a
Fable ruling, not a code change; (4) an `armed_families` row and a `daily_cap`/`tick_cap` row; (5) a
test that the family with no row sends nothing. Steps 1-3 are the work; 4-5 are the wiring this task
already knows how to do.

### Group 5: Intercom is Caroline's lane

`support-backlog.json` is written by `scripts/caroline-monitor.py` and read by the backlog drain; the
unanswered-thread page is `scripts/intercom-unanswered-reply-watchdog.py`. Neither is a
`credit-verify-outbound` family, and adding one would be a second sender on the same conversations.
Confirmed and not duplicated.

## The warm-up limit, measured

The email warm-up ceiling is not a guess and not a policy number: it is
`WARMUP_CEILINGS: '{"news":1000,"notify":3000,"mail":100,"digest":0}'` in
`H-DevOps k8s/prod/messaging/78-send-gateway.yaml` (line 167), and the `notify` route's 3,000 is
allocated **credit 2,500 / claim 500** - the same two numbers as this policy's `shared_daily_cap`, so
a family cap at or under its group's shared ceiling cannot breach the warm-up. The claim group's one
number is the exception only in that it is not this PR's: #2076 sets it to 500, the allocation
itself, so at the end of the step each family is bounded by its own row and the gateway's answer is the
ceiling above it (see "Group 2").
The gateway enforces
the batch ceiling per route per UTC day and auto-pauses a route above 2 % permanent bounces or 0.1 %
complaints; event-driven mail is never capped.

Every **credit** cap below is therefore `min(audience, the group's warm-up allocation)`; the claim group
is not in this table at all - its number is #2076's.

## The cap changes

| Cap | Before | After | Group it unblocks | Day it clears |
|-----|--------|-------|-------------------|---------------|
| `daily_cap.proof-need-ask` | 400/400 | **1,585/1,585** = min(1,585 listed, 2,500 credit allocation) | Owed proof never asked (1,585 people) | Not a day by itself: it stops the day being spent twice on one list. Examination is the page (200/segment) and the deadline; sends are the gate's 0-1 of 50 |
| `tick_cap.proof-need-ask` | 50/50 | **100/100** | same | 100 is the family's `FIRST_CAP` ceiling; above it the digit is inert. Time to walk 1,585: ~4 ticks at the full 200-candidate page per segment, ~16 at the measured 51 |
| `daily_cap.uvn-reminder-14` | 1,200/1,200 | **832/832** = min(782 due, 2,500 credit allocation) | Reminder due, never reminded (782 people) | day 1 |
| `tick_cap.uvn-reminder-14` + `R14_CAP` | 50/50 | **100/100** (the same `FIRST_CAP` ceiling) | same | 832 at 100 a segment is ~9 ticks on a full page, more when the deadline cuts the page - not one day |

The claim group's cap is deliberately **not** in this table: it is one number for the group, it is
**#2076's**, and this PR neither raises nor lowers it (Group 2 records the measurement behind it).

The reminder's per-tick raise is the one that needed evidence, because its own comment says the cap
rises only by PR on three clean ticks. The three ticks before the raise read 0.0 % (50 contacts),
0.0 % (5) and 1.82 % (1 of 55) hard bounces - **one bounce in 110 contacts, 0 complaints, 0
unsubscribes** - and the route's auto-kill still stops the family above 2 %.

Revert: set `daily_cap.proof-need-ask` back to `400/400`,
`tick_cap.proof-need-ask` to `50/50`, `daily_cap.uvn-reminder-14` to `1200/1200`,
`tick_cap.uvn-reminder-14` to `50/50` and `R14_CAP` to `50`, then deploy. Nothing else reads those
numbers.

## The 794 reminders stuck in copy review are NOT reached by this

Firstmate's dry run found 11,905 rows past ask + 14 days across 1,382 users that never got a
reminder: 11,111 with no reminder row at all and 794 stuck in copy review. The cap raise reaches the
first class only, and only as far as the builder's own rules allow (782 people are due today; the
rest are held as `already_reminded`, `already_sent`, `not_due`, `proof_received`, `replied`,
`no_prior_ask`, `noted_since_ask`).

The 794 are a different fix: the copy gate binds a verdict to the rubric's sha256, so editing
`policies/outbound-copy-rubric.md` staleness-ified every signed verdict, `uvn-reminder-14`'s
included. Those bodies hold as `copy_review_pending` until the reviewer host is re-installed and signs
again from the deployed tree. No cap moves them, and this change does not claim to.

## Caps not raised, and why

- **`tick_cap.uvn-status` 50/50** - it *does* bind the free segment (50 of 1,845). It is not raised
  here because it is not a throughput knob: it was set on 2026-11-04 because the free apply loses its
  outcomes artefact past ~80 users when the Intercom note step hits the subprocess timeout (#1756,
  twice in one afternoon). Raising it without fixing that loss would trade sends for unmeasured
  sends. The daily row (2,000) is not binding.
- **`daily_cap.claim-status` 500/500 and `daily_cap.claim-proof-ask` 500/500** - not raised, and not
  touched at all: each already exceeds what one family can send in a segment (250 via `CLAIM_CAP`), so
  raising a row that no longer binds would change no send. `claim-proof-ask`'s 25 a segment comes from
  its own `tick_cap` row, which is also untouched here.
- **`shared_daily_cap.claim`** - not this PR's to set: #2076 carries the group's single value, 500/day,
  which is the send gateway's claim allocation.
- **`shared_daily_cap.credit` 2,500** - untouched: it is at the credit warm-up allocation already.

## wait-apology: armed by its own row, and still sends nobody

`wait-apology` sat in the credit group with `daily_cap` 2500/2500 and **no row anyone could write**:
`read_arming`'s `KNOWN` set had no key for it, so a row for it made the whole block `malformed` and
armed *nothing* - the family that could never be switched on was also the one an operator could not
switch off in review. This change adds the key (and the arming loop's case) and the row:

```json
"wait-apology": { "live": true, "paid": true }
```

No `unsigned_from`, on purpose. The arming loop *assigns* that empty date
(`UNSIGNED_FROM[wait-apology]=""`), so the family is wired and stays **SIGNED-only**: it checks,
renders its bodies and applies nobody. A date in that row is fable d2's GO, not a wiring change.

It is also **not** the acknowledgement family for a never-contacted requester. Its audience is the
retired paid-status recheck list: `apology_family()` reads
`/var/lib/hydra/paid-status/<day>/<segment>`, and there has been no paid-status run since
2026-11-03 (the 02:00Z tick logged `no paid-status run for today ...; skipped (never a guessed
audience)` for both segments). So arming it reaches nobody today, for two independent reasons, and
this change does not pretend otherwise.

## The tick is not hourly in practice

The 02:00Z tick ran 02:02:16Z -> 03:10:34Z (68 min) and the 03:00Z tick exited at once:
`another tick holds /var/lib/hydra/credit-verify-outbound/tick.lock (pid 2696598, 3601s); exit`. So
the effective cadence is one tick per ~1-2 h, not 24 a day, and every per-tick cap is really a
per-~2h cap, and a shared number is spent a slice at a time: while the claim lane's shared cap was 25,
that lane could not exceed 25 a day however many ticks ran. At #2076's 500 a single tick's grant is
`CLAIM_CAP` (250 a segment), so the group's day is spent in about two ticks; at 500 it is
one tick - which is the point of stepping rather than jumping to the allocation the gateway will answer
with from then on. The same arithmetic is why the reminder's 50 a tick was ~600 a
day.

## Tests

- `scripts/tests/credit-verify-outbound.bats`:
  - `reach-every-request-r1): wait-apology is armed by its OWN row and still applies nobody` - the
    row does not malform the block, the arming line says `SIGNED-only: the row sets no
    unsigned_from`, the family is checked and never applied, and with the row removed it is
    `not armed` and still never applied.
  - `reach-every-request-r1): the claim group's shared cap is #2076's stepped value and it binds there` -
    the harness hydrates the branch with the gateway's allocation (this branch carries no claim hunk): that many claim rows today
    leaves no room (`daily cap reached for claim-proof-ask/paid; no apply`), 199 leaves exactly one
    (`--mode apply --max-users 1`), and with nothing sent yet a claim family is granted more than the old
    25 - the shared number no longer sits under the rows it governs.
  - the model test `test_reach_every_request.py` pins the arithmetic behind the number: `CLAIM_CAP` is
    readable from the tick, four claim runs x 250 is what the rows ask for (1,000), #2076's stepped value
    is the allocation itself and below the rows' 1,000 ask, and `room()` at zero used
    returns the family's own `CLAIM_CAP` when the shared number is at or above it while at the old 25 it
    returned 25 - the old bug, recorded in arithmetic.
  - the shipped-policy cases now assert the cap against the gateway's allocation, the 1,585/100 proof-need-ask rows, the 832/100
    reminder rows, and the wait-apology row's shape (no `unsigned_from`, `[wait-apology]=""` still in
    the code). The shared-budget cases pin `CVO_R14_CAP=50` so they keep testing the mechanism (one
    budget across paid + free) rather than the number; the shipped default is pinned by the
    `--print-config` case.
- `scripts/tests/test_reach_every_request.py` - this report's table names all five groups, marks the
  two with no family as unreached, and carries each cap change with its before/after/group/day.
