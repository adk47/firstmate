# Never-asked canary: count reconciliation, then the digest

Lane `never-asked-canary-r1`, branch `fm/never-asked-canary-r1`. Written 2026-11-15 00:40Z, last changed 01:40Z.
**Nothing has been sent or armed by this lane. The canary through the deployed sender sent 0
(section 4): its first-ask apply is locked out by another unit.** Sections 1 and 2 are the
reconciliation. Section 3 is the digest: its audience and canary rule are code with tests, wired
to no sender.

## 1. The two counts, reconciled

Both numbers come from the same two reads and the same instant. They are two different
formulas over the same two sets, and only one of them counts requests.

- **P** = pending requests in core: `credit_requests.status = 'user_verification_needed'`, not deleted.
- **A** = every request id that has a row in the verify ledger (`verify_requests`), in any campaign
  and with any outcome, whether or not that request is still pending.

| | the 9,002 count | the 26,574 count (lane gauge) |
|---|---|---|
| formula | `|P| - |A|` : one count subtracted from another | `|P minus A|` : pending requests joined to the ledger by request id |
| what it counts | **no population.** It is a difference of two totals. No list of requests has this size. | **pending requests that no ledger row names**: never offered to the send gate in any campaign |
| source | the gauge before firstmate's 2026-11-14 21:5xZ fix ("Fable's 9,002 of 11,382" is this arithmetic: OURS 11,382 is `|P| - |sent ids|`) | `verif-lane.check.sh` since that fix: `len(p - asked)` |
| brief's reading | 9,002 | 26,574 |
| my reading, 2026-11-15 00:19Z | 9,078 | 26,617 |
| the same formulas, 2026-11-14 20:46Z (PR 1988) | 9,041 | 26,531 |

**Why they differ.** `|P minus A| - (|P| - |A|) = |A minus P|` exactly: the gap is the ledger's
request ids that are no longer pending (asked earlier, since approved, rejected or withdrawn). The
old formula subtracts those from today's pending although they are not in it.

| reading 2026-11-15 00:19Z | requests |
|---|---|
| P, pending | 80,101 (7,270 users) |
| A, ledger request ids, all time | 71,023 |
| A still pending | 53,484 |
| **A no longer pending** | **17,539** |
| `|P| - |A|` | 9,078 |
| `|P minus A|` | 26,617 |
| difference | 17,539 = A no longer pending, to the row |

The brief's own pair gives 26,574 - 9,002 = 17,572, the same quantity at an earlier reading.
I did not re-read at that instant, so 17,572 is the identity applied to the brief's numbers, not
a measurement of mine.

**Which one stands.** 26,617 is the real count of pending requests with no ledger row. 9,078
counts nothing and should not be quoted again. That is not the flattering answer: the larger
number is the true one.

**But 26,617 is not the number of people who need a message,** and that is the part that
matters before a send. It is requests, not customers, and it includes requests nobody should be
written to about:

| the 26,617 never-asked requests, 00:19Z | requests | users |
|---|---|---|
| all | 26,617 | 2,876 (+ 413 requests with no user id) |
| request has no user id: nobody to write to | 413 | - |
| core already sent its own proof notice for this request (`metadata.proofRequest`); 3 of them have no user id | 7,459 | - |
| users whose EVERY never-asked request carries core's notice: not owed an ask from us | 3,640 | 1,256 |
| **users with at least one never-asked request core did not ask about** | 18,748 unasked (+ 3,816 of theirs core asked) | **1,620** |
| of those 1,620: paying | - | 629 |
| of those 1,620: another pending request of theirs is named by a sent ask of ours | - | 272 |
| of those 1,620: core's notice told them about another request | - | 720 |

So the ceiling for "customers a first digest could be owed to" is **1,620, not 26,617 and not
9,002**. It is a ceiling: the holds below are not yet subtracted.

### The 1,620, hold by hold (measured 00:39Z)

Each customer is in one row, placed by the first reason that applies, top to bottom. This table is
the output of committed code over the snapshot: `scripts/credit_review/never_asked_digest.py`, run
by `python3 data/never-asked-canary-r1/tools/audience_from_snapshot.py SNAPSHOT --now 2026-11-15T00:39:00Z`.
Sources: the proof-on-file export of 23:58Z, every `verify_messages` row, and the DSP verifier's
open captures.

| the 1,620 customers | customers | their never-asked requests core did not ask about |
|---|---|---|
| on the per-customer stop list (empty today) | 0 | 0 |
| a refused or rejected row on file under their account: never offered again | 4 | 7 |
| a proof entry on file (887 of the 1,620 have a document not yet read to a verdict): owed a read, not an ask | 1,258 | 14,756 |
| already told by a sent `uvn-status` ask of ours; these rows are newer (the follow-up PR 1988 opens) | 98 | 432 |
| a sent note of ours in another campaign | 18 | 197 |
| emailed support@ in the last 90 days (`SUPPORT_CONTACTED_HOLD`) | 2 | 285 |
| a DSP capture that has not come back | 2 | 27 |
| **no hold found: a first contact, one digest each** | **238** | **3,044** |
| total | 1,620 | 18,748 |

**The first-contact population is 238 customers: 28 paying, 210 free.** 132 of them were never
told by anyone (the builder's `uvn` class, which the armed `uvn-status` note already covers: one
note per customer). 106 were told by core's notice about another request and never by us; no
family asks them today. The digests are uneven: the largest names 620 requests.

**A canary of 500 does not exist in this population.** Every one of the 238 could be sent and
the canary would still be under half its size; the committed decision code answers
`stop: canary_short` for exactly that case. The 238 is itself a ceiling, and the next section
shows the gate has already answered for part of it.

### What the send gate has already said about the 238

The armed `uvn-status` tick offers the 132 never-told customers to the gate in a dry-run check
every tick. Their newest answer in the check files of 2026-11-12 to 11-15 (94 files, read-only):

| newest gate answer | customers |
|---|---|
| accepted | 0 |
| **refused: Intercom identity** (no contact for the email 21, several contacts 1, no external id 1, a different Muso account 1) | **24** |
| **refused: the note's own fields** (a link or markup in a field 7, the outbound sanitiser 1) | **8** |
| held: messaged in the last 7 days 7, core's notice in the last 7 days 4, thread state 3, in-app not armed 1 | 15 |
| unmeasured: the gate call timed out | 1 |
| deferred by the runner before the gate on 11-12 (`run_size`), no gate answer since | 81 |
| no answer in any check | 3 |
| the 106 customers only core told: no family offers them, so no gate answer exists | 106 |

**32 of the 238 are already refused by the gate, and 0 are accepted.** The bar allows 9 refusals
in a canary of 500 (under 2 percent). On the answers already on file this population is past it
before a single message goes. This is a reading of dry-run checks, not a canary: 187 of the 238
have no gate answer at all, and their rate is not known.

**Why 0 accepted is not a surprise, and what it means for a canary.** The 132 are a residue. The
armed tick offers every never-told customer to the gate and sends to the ones it accepts, and a
customer who is sent to leaves this population. Whoever is still here is someone the gate refused,
held, or has not reached. So the first contact with never-told customers is not waiting for this
lane: it has been running since 2026-10-22 (3,231 sent), and a canary drawn from what is left
measures the gate's leftovers, not a fresh population. The 106 only core told are the one group
nothing has offered yet.

Where the 26,617 requests sit, as customers would see it: core already asked (7,456), a
proof entry is on file (14,756), a first contact is owed (3,044), a follow-up is owed (432),
nobody to write to (413, no user id), other holds (516). That sums to 26,617. **The never-asked count is mostly a
reading backlog, not an asking backlog.**

### The 2 percent bar, read against the sender's own history

The closest existing send is `uvn-status` (same gate, same kind of customer). Its ledger rows:

| `uvn-status` first asks | sent | refused or rejected | rate |
|---|---|---|---|
| all time (2026-10-22 to 11-14) | 3,231 | 114 | 3.4% |
| before 2026-11-03 | 1,953 | 114 | 5.5% |
| since 2026-11-03 | 1,278 | 0 | 0% |

The 0% is not a clean sender. Since 11-03 no refusal has written a ledger row; PR 1988 found
307 never-asked requests held on Intercom identity refusals that it read from the tick's check
files (`uvn-status-*-check.json`), not from the ledger. I have not traced the code change that
moved them; the reading is that the runner's dry-run check now takes the refusal before the
post. Either way: **a canary refusal rate read from ledger rows alone would read near 0
whatever happened.** The rate must count the check's refusals too: (customers the gate refused,
at the check or at the post) / (customers offered to the gate). The 114 past refusals: 85 are
Intercom identity (the contact for the email belongs to a different Muso account, or matches
none or several), 28 are Intercom's `action_forbidden`, 1 is the outbound sanitiser. Rate here is
refused / (sent + refused).

### Not measured

- The gate's answer for 187 of the 238 (the 106 no family offers, and the 81 not offered since 11-12).
- **215 refused or rejected ledger rows carry no account id** (they are keyed by email only), so the
  "never offered again" row above cannot see them. The send gate refuses those people again at send
  time; this audience does not yet leave them out by itself.
- Opt-out and bounce state for the 238: the mail gateway answers it at send time; the ledger shows
  17 past `suppressed:unsubscribe` / `hard_bounce` refusals across all campaigns.
- Whether core's notice reached the customer: the marker is the only evidence (PR 1988 says the same).
- The proof-on-file export is 14 minutes older than the builder's list it is joined to.

## 2. "DSP request in flight": the marker in core is not it

`metadata.freshDspCapture` is on 9,633 pending requests (9,575 of them never-asked), and 2,091 of
the 2,876 never-asked users have one. Read as "in flight", it would skip 73% of the population.
It is not a live state:

- its `status` is `partial` (7,316), `enqueued` (2,254) or `deduped_fresh` (63) and nothing else;
- **approved** requests created since 2026-10-29 carry the same values (9,639 `partial`, 5,390
  `enqueued`): the field is a receipt of the capture request and is never updated when the
  capture comes back;
- where a request has both the marker and core's proof notice, the notice came after the capture
  decision in 5,726 of 5,779.

What is in flight is a capture that has not come back: an open row in the DSP verifier's own
store (`dsp-verify.sqlite`, `dsp_captures.closed = 0`; the verifier closes a capture when every
reading is final or after its window, `CLOSE_AFTER` = 100 min), or a core capture requested less
than that window ago. A skipped customer is offered again on the next tick. **Measured 00:39Z:
27 customers have an open capture and 4 more only a core capture under 100 minutes old (31 in
all); 2 of the 1,620 are held by it and by nothing earlier.**

This is my reading of "in flight", stated so it can be overruled: if the ruling is "any request
with the core marker", most of the 238 go too (2,091 of the 2,876 never-asked users carry it).

## 3. The digest: what is built, and what is not

**Built and tested, wired to nothing:** `scripts/credit_review/never_asked_digest.py` decides who
would get a first-contact digest and reads a canary. It imports no sender, no ledger and no
network (a test holds it to an import allowlist), so merging it sends nothing.

| requirement | where it is | proven by (`scripts/tests/test_never_asked_digest.py`, 39 tests) |
|---|---|---|
| one digest per customer | `build()`: one `Digest` per user id, carrying every never-asked request of theirs core did not ask about | a customer with four pending requests gets one digest naming all four; no customer and no request appears twice however the rows repeat; on the live snapshot 238 digests, 238 customers |
| skip DSP in flight | `Holds.dsp_in_flight` (section 2's rule, read by the caller) | the customer is left out with that reason and nobody else is |
| paid first | `build()` orders paid, then oldest request | order test; `next_page()` keeps it |
| canary 500 | `CANARY_USERS`; `next_page()` never offers past it | 498 measured, page of 50 asked: 2 offered |
| continue only under 2% | `decide()`: refused / (sent + refused); 9 of 500 continues, 10 of 500 stops; the 10th refusal stops the canary at once | boundary tests on both sides; held and unmeasured customers never complete a canary; a population under 500 answers `stop: canary_short`, never `continue` |
| never resend to an opt-out or bounce | `Holds.never_again`, checked before every other reason but the stop list; a sent or refused customer is never on a later page | tests; see the 215-row gap under "Not measured" |
| reversible per customer | `load_stop_list()`: one user id on the list removes that customer's digest and changes no other | test compares every other digest before and after |
| no cap raised, no bulk approve or reject | the module writes no policy and no credit status | the import allowlist |

**Not built: the send.** No copy, no campaign, no tick family, no ledger write, no gate call.
Nothing was sent and no canary was run, so **there is no measured canary refusal rate.** Building
the send needs three answers that are not an implementation worker's to give:

1. **The canary size.** 500 first contacts do not exist; 238 do, and at least 32 of those the
   gate already refuses. Either the canary is this population at its real size, judged on a rate
   that is already known to be over the bar for the part measured, or "never-asked" is meant to
   include people this report leaves out (the 1,258 with a document on file are the only group
   large enough, and asking them for proof they already sent is the thing the strict rule exists
   to stop).
2. **Which approved copy.** No approved copy says "here are all your pending credits" to a
   customer core told and we did not (the 106). `uvn-status` is the approved first ask and is
   already one note per customer; it is in `observe` mode, so "every body through the copy gate
   on approved copy only" needs it, or a digest campaign, moved to `enforce` first.
   `uvn-new-rows` opens "since we last wrote", which is false for someone we never wrote to.
3. **What "DSP in flight" means** (section 2): an open capture (2 customers held), or core's
   marker (most of the population).

PR https://github.com/Muso-AI/hydra/pull/1988 already opens `uvn-new-rows` for the 98 customers
in the "already told" row; this lane builds no second sender beside it.

## 4. The canary through the deployed sender (ruling 01:02Z): 0 sent

Ruling: run the canary through the sender on main, at whatever the deployed cap allows. The
deployed sender for a first contact is the armed `uvn-status` family of the hourly tick
(`credit-verify-outbound.sh`, node-8 head `c1fbf5a22`). It sends one note per customer naming
all of that customer's owed requests. This lane started no send of its own and ran no apply by
hand: the result below is the tick's.

**The three numbers, read back 01:33Z.** This is a run of the deployed sender that sent nothing,
not a canary:

| | |
|---|---|
| rows selected | 8 requests, of the 5 customers the gate's check accepted (78 customers offered) |
| customers covered | **0 sent** of 5 accepted; the cap permitted 50 |
| told rows confirmed | **0**: `verify_messages` has 0 rows for the 5 since 01:00Z, `decision_told` 0 rows for the 5, `told` 0 rows for their 8 requests |
| refusals | 1, "link or markup in a field" (G5): a copy defect, see below |
| free segment | not run, lock held |

At 01:33Z the lock is still held by the same process (pid 2361528, started 00:55:41Z), and the
last `uvn-status` send is still 2026-11-14 23:20:49Z.

| the 01:00Z tick, the first after the ruling | |
|---|---|
| cap the deployed policy permits | 50 customers per segment per tick (`tick_cap.uvn-status` 50 paid / 50 free) |
| paid list | 918 customers; this tick's page was entries 642 to 917 |
| customers the page brought to an outcome | 78 |
| accepted by the gate's check | 5 |
| **sent** | **0** |
| told rows read back from the ledger (01:17Z) | 0: no `uvn-status` row written since 2026-11-14 23:20Z |
| refused | 1 ("link or markup in a field", G5; a copy defect; no ledger row) |
| held or deferred | 72 (32 class C signed-only, 17 messaged in the last 7 days, 16 held thread state, 9 core notice in the last 7 days, 3 email unreachable and in-app not armed) |
| free segment | not run, lock held: the paid apply failed on the lock and the tick stops there |
| customers of the 238 on this page | 0 |

**Why 0.** The apply ended with `NOTHING sent: another uvn-status apply run is in progress`.
Every credit campaign shares one run lock (`ledger.sqlite3.credit-group.run.lock`, taken without
waiting). At 01:09Z it was held by `python3 -m credit_review.need_asks send --segment paid --mode
apply --max-users 200`, started 00:55:41Z by `/opt/hydra/scripts/credit-ask-tick.sh`.

- `credit-ask-tick.timer` fires at :25 and :55. The script and its units were written on node-8 on
  2026-11-14 23:26Z and are not in this repository.
- One pass holds the lock for the hour: the 23:55Z pass was killed by its own 3,600 s unit timeout
  at 00:55:00Z (`Failed with result 'timeout'`), and the next started the same second.
- The 00:00Z tick lost its 5 accepted customers the same way (00:18:48Z). The last `uvn-status`
  send was 23:20Z, before that pass began.
- So while that unit runs, the first-ask family sends nothing and the tick ends before the free
  segment. Two ticks in a row; the 02:00Z tick will meet the same lock.
- What the other unit sent in the same window (00:00Z to 01:17Z): 10 `proof-need-ask` notes, 38
  deferred. None of the 10 names a never-asked request. 18 of the deferred name 161 of them and
  write no request row, so the never-asked count did not move.

I did not stop that unit (its own switch is `/etc/hydra/credit-ask-STOP`) and did not change the
lock: it is another lane's send, and the lock is the shared-budget rule (QA #1617).

**The one refusal is a copy defect, not a customer's fault.** The gate's rule G5
(`scripts/intercom-verify-request.sh`, "no link, address or markup in any interpolated field")
refuses a note when a name or title filled into it carries a link, an address or markup. The
approved wording is not what fails: the note as rendered for that customer is. The customer did
nothing, is told nothing, and is offered again and refused again every tick, with no ledger row.
14 customers were refused this way between 2026-11-12 and 11-14, 7 of them among the 238. Until
the note can carry such a title, those customers cannot be asked by this sender at all.

**Recorded as seen, and stopped (ruling 01:34Z).** Lock held by `credit-ask-tick.service`; 78
offered, 5 accepted, 8 requests, 0 sent, 0 told rows, 1 refusal "link or markup in a field"; free
segment not run, lock held. Nothing here works around the lock: it was not renamed, no wait was
shortened, no second sender was added.

**No canary refusal rate exists.** 0 sent and 1 refused on a page with none of the 238 is not a
rate. The nearest real reading is the same sender's last three days, sends that did go out:

| `uvn-status` first asks, 2026-11-12 to 11-14 | customers |
|---|---|
| sent (ledger) | 273 |
| refused by the gate and never sent | 42 (Intercom identity 26, link or markup in a field 14, over 1,000 credits in one note 1, outbound sanitiser 1) |
| refused / (sent + refused) | 13.3% |

That is history, not this lane's canary, and it leans high: a refused customer is offered again
every tick, so the 42 include people first refused before 11-12, while the 273 are three days of
sends. It is still nowhere near 2 percent.

## How these numbers were read

Read-only, 2026-11-15 00:19-00:39Z, from ak47. The files hold user and request ids and are not
committed; `tools/audience_from_snapshot.py` reads a directory of them and prints counts only.

| file | read | columns |
|---|---|---|
| `facts.csv` | `scripts/trino-query.sh < data/never-asked-canary-r1/tools/facts.sql` (core replica, 00:21Z) | id, userid, createdat, paid, core `proofRequest` marker, notice time, DSP marker, ... |
| `ledger.psv` | `sqlite3 -readonly /var/lib/hydra/credit-review/ledger.sqlite3` on node-8, `verify_requests` left-joined to `verify_messages` (00:19Z) | request id, message status, campaign, message row |
| `messages.psv` | the same ledger, every `verify_messages` row (00:39Z) | id, account id, campaign, kind, status, message type, day, reason, credits |
| `proof-on-file.json` | `/var/lib/credit-trust/proof-on-file.json` on node-8, generated 23:58Z | `entries[].user_id`, `gmail_contacts_90d.user_ids` |
| `dspcap.psv` | `sqlite3 -readonly /var/lib/hydra-credit-verify/dsp-verify.sqlite`, `dsp_captures` open or submitted since 20:00Z (00:39Z) | id, user id, submitted at, closed, reads, request ids |
| `dsp.csv` | core replica, pending requests carrying `metadata.freshDspCapture` (00:22Z) | id, capture status, decided at, ... |
| check files | `/root/h2-runs/sched/2026111[2345]T*/uvn-status-*-check.json` on node-8 (94 files) | per customer: result and reason |

Joined by lower-cased request id and by user id. The stores were read minutes apart, not at one
instant: a request that changed state in between is counted as it stood at its own read.
