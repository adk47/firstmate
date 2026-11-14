## Summary

Four send families listed 4,852 people and would message 0. **It is not one shared gate**, and it is
not the 90-day re-ask lock (4 of 947 on uvn-status-paid), a copy verdict, the one-per-day rule or
the owing-builder class. The send gate's answers are standing rules working as written. The lists
are what is wrong: they keep offering people the gate will not pass.

The largest bucket is stuck, not done. 485 of 924 paid and 942 of 2,259 free uvn-status users are
held as `documents on file`. Only a stage-2 verdict ends that hold, stage 2 takes its work only
from the decider's `proof on file` holds, and the decider lists `status=unverified` only. A
document filed against a request already in `user_verification_needed` was handed to nobody.

**What that meant for a customer:** someone who was asked for proof and sent the document got no
reading of it by any job, so no approval and no follow-up question, for as long as the request
stayed in that status, while our lists kept counting them as a person still to be asked.

**The change** (`scripts/credit_review/decide.py`, `hold_documented_uvn`): after its normal pass the
decider reads every `user_verification_needed` request from the replica in one query, keeps the
ones a document on file covers, and records `hold` / `proof on file: human review` for those whose
newest decider row is none, an ask or a deferral. That row is what stage 2 selects.

It writes decider ledger rows only: no core write, no ask, no approval, no model call, in any mode.
No gate rule, cooldown or send path is touched. `REASK_LOCK_DAYS`, the unmeasured-stop settings
and every existing cap are unchanged; the one new policy key is this pass's own cap.

## Drain: 2,598 users, about three days

| | rate | basis |
|---|---|---|
| decider: users given a hold | about 900 a day | 90 `judge` runs a day measured (83 to 95 per UTC day, 5 to 13 November) x 10 users a run |
| stage 2: users given a verdict | about 890 a day | hourly, `--max-users 40`, so 960 at most; its normal intake took 70 users on 13 November |

All 2,598 are held after 260 runs, 2.9 days, and stage 2 takes them about as fast as they arrive.
The clock starts at the first run on a deployed head; merging does not deploy.

**Raising the decider cap alone buys nothing, because stage 2 is the real bound.** The decider
supplies 37.5 users an hour and stage 2 takes 40. A larger decider batch moves the wait from "not
yet held" to "held, not judged", makes every hourly stage-2 run look up the status of a longer
queue, and gives no verdict sooner. The number that shortens the drain is stage 2's `--max-users`,
raised together with this cap; that spends stage 2's time margin (its slowest 40-user run took
1,283 s against a 3,300 s kill). Decision recorded 2026-11-13: both stay where they are.

**The order is fixed.** Each run reads the whole population again (no cursor) and ranks users:
paying first, then the user whose oldest selected request is oldest, then user id. It takes the
first 10 whole users; the rest wait their turn and are counted in the run line as `still to hold`.
A paying user who files tomorrow goes ahead of every free user still waiting.

One thing that could make it longer: on its three full-queue days in October stage 2 recorded
verdicts in 14, 9 and 23 hourly runs, and the store does not say whether the other hours were an
empty queue or failed runs. At 9 runs a day the drain is about 7 days. Measurements and queries:
`data/send-families-zero-sends-r1/drain-time.md`.

## Credit approval impact

**What changes.** The decider adds `hold` rows to its own ledger for documented requests already in
`user_verification_needed`, so stage 2 (shadow) reads those documents. Stage 2's verdicts release a
credit to an ask (`need_more`, `no_document`) or leave it held for a person.

**What does not change.** Nothing is approved, declined or asked by this pass, and no approve arm,
gate or cap that existed before is touched.

Measured on prod data (node-8 ledger, the replica and the 21:58Z proof-on-file export, read-only,
2026-11-13 22:13-22:18Z):

- Before: 0 of the 79,101 `user_verification_needed` requests on prod are read by the decider; 3,305 documented requests of 236 users are stage-2 input; 2,568 documented users have none. Approvals made by this pass: 0.
- After (the selection replayed on the same prod data, not a deployed run): 28,688 more requests of 2,598 users are recorded as holds, 10 users a run; 2,498 users get a verdict path for the first time and 70 stay without one. Approvals made by this pass: 0.

Read 22:13-22:18Z on 2026-11-13.

| | requests | users | query |
|---|---|---|---|
| `unverified` on core (what the decider lists, 8,000 a run) | 21,302 | 2,152 | A |
| `user_verification_needed` on core (never listed) | 79,508 | 7,186 | A |
| of those, covered by a document on file | 32,644 | 2,804 | B, C |
| already held as proof on file (stage 2 has them) | 3,305 | 236 | D |
| **selected by the new pass** | **28,688** | **2,598** | D |
| users with documented requests and no stage-2 input today | | 2,568 | D |
| **of those, users who get a verdict path for the first time** | | **2,498** | D |
| stay without one (only the 651 left-out requests) | | 70 | D |

- **A** (replica, 3.0 s):
  `SELECT status, count(*), count(DISTINCT userid), min(createdat), count_if(updatedat < TIMESTAMP '2026-10-17 10:45:12 UTC') FROM postgresql_core.public.credit_requests WHERE deletedat IS NULL AND status IN ('unverified', 'user_verification_needed') GROUP BY 1`
- **B** (replica, 3.5 s, 79,101 rows): `decide.UVN_REPLICA_SQL`, the statement the pass itself runs.
  It returns 407 fewer than A: A was read four minutes earlier and counts rows with no user.
- **C**: `tools/covered_uvn.py`, the decider's own `proof_on_file` / `with_intake` / `covers` over B,
  the 21:58Z proof-on-file export and the 10,943 `proof_intake` rows, run off node-8.
- **D**: `tools/ledger_probe.sql`, one probe of index `decisions_req` per covered request (0.14 s).

## Was `status=unverified` deliberate?

It was the right selection for what the decider decides and the wrong one for what stage 2 needs.

- The selection is from the decider's first commit (`d4c4b8b1a`, 2026-10-17, #1243) and
  `git log -S'status=UNVERIFIED'` shows no later change. A decider that approves or asks has
  nothing to decide on a request that was already asked.
- Stage 2 was written to judge both statuses: `stage2.HELD = ("unverified",
  "user_verification_needed")`, and `docs/credit-verification/proof-forensics.md` says so. Nothing
  in the repo says a `user_verification_needed` request must not be read.
- 54,505 of the 79,508 requests in that status were last written before the decider's first run
  (287 of 300 in the sample of listed no-row requests), so the decider did not put them there and
  never saw them.

What stays out, on purpose:

| stays out | requests | why |
|---|---|---|
| `user_verification_needed` with no document on file | 46,457 of 79,101 | asked once already; there is nothing to read and a credit is asked about once |
| newest decider row is a `proof on file` hold | 3,305 | already stage 2's input |
| newest decider row is a standing hold of another kind | 623 | `score approval not now` holds (591), same-anchor, support@-contact and already-asked holds; a newer row would hide them from their readers |
| newest decider row is `duplicate_noop` | 28 | closed as duplicates |
| stage 2 already released the request to its ask | not counted | it has its verdict |

### The 651 left out, by reason

Documented `user_verification_needed` requests the pass does not take, by the reason on their newest
decider row (`tools/ledger_probe.sql`, last query). A newer row from this pass would replace that
row as the request's newest, and its reader would lose it.

| newest decider row | requests | users | why it is left |
|---|---|---|---|
| hold, `score approval not now: proof path: engaged` | 368 | 109 | the score-approval arm set this request aside; its row is that arm's record |
| hold, `score approval not now: stored popularity 0` | 156 | 42 | same arm |
| hold, `score approval not now: organization / label` | 46 | 5 | same arm |
| hold, `same_anchor_requests` | 12 | 2 | held with another request on the same anchor |
| hold, `score approval not now: big track` | 11 | 3 | same arm |
| hold, `score approval not now: user on the decider's list` | 10 | 2 | same arm |
| hold, `emailed support@ in the last 90 days` | 10 | 6 | held for a person |
| hold, `support already requested for this credit` | 7 | 3 | already asked about once |
| hold, other reasons not itemised by the query | 3 | - | - |
| `duplicate_noop` | 28 | 7 | closed as a duplicate of a decided request |
| **total** | **651** | | |

The same user can appear on more than one line. 70 users have only left-out requests and so still
have no verdict path. The 623 holds need their own decision: whether stage 2 should read a document
on a request another arm has set aside.

## 10 people from each list

Tick `20261113T2005Z` on node-8, the first 10 entries of the page each check walked. Tool:
`tools/sample10.sh` (jq over the tick's own list and `-check.json`; per user, probes of
`verify_requests` by request id, one read of `verify_messages` (13,109 rows) by account, and
`stage2_shadow` by request id). `no gate call` means the runner dropped the person before the gate.

**uvn-status-paid** (page 0..695 of 923): 10 of 10 documents on file, none judged by stage 2.

| entry | user | requests | dropped by |
|---|---|---|---|
| 0 | 26139 | 13 | documents on file: 13 of 13 requests covered, 0 judged by stage 2 |
| 1 | 66517 | 1 | documents on file: 1 of 1, 0 judged |
| 2 | 37398 | 1 | documents on file: 1 of 1, 0 judged |
| 3 | 150172 | 27 | documents on file: 27 of 27, 0 judged |
| 4 | 96625 | 1 | documents on file: 1 of 1, 0 judged |
| 5 | 101263 | 10 | documents on file: 10 of 10, 0 judged |
| 6 | 89771 | 9 | documents on file: 9 of 9, 0 judged |
| 7 | 147027 | 24 | documents on file: 24 of 24, 0 judged |
| 8 | 109152 | 1 | documents on file: 1 of 1, 0 judged |
| 9 | 110414 | 3 | documents on file: 3 of 3, 0 judged |

**uvn-status-free** (page 589..1051 of 2,259): 5 class C signed-only, 4 documents on file, 1 not
attributable.

| entry | user | requests | dropped by |
|---|---|---|---|
| 589 | 305902 | 2 | gate: `c2_signed_only` (the ask would correct the 10-26 status line) |
| 590 | 346126 | 4 | gate: `c2_signed_only` |
| 591 | 311866 | 15 | documents on file: 15 of 15, 0 judged |
| 592 | 309535 | 1 | documents on file: 1 of 1, 0 judged |
| 593 | 173704 | 2 | gate: `c2_signed_only` |
| 594 | 76880 | 2 | gate: `c2_signed_only` |
| 595 | 340051 | 19 | gate: `c2_signed_only` |
| 596 | 347969 | 85 | documents on file: 85 of 85, 0 judged |
| 597 | 144827 | 1 | documents on file: 1 of 1, 0 judged |
| 598 | 329685 | 79 | no gate call, no document, no ledger row: one of the runner's own holds (fraud lens, blank title, nothing to ask). The artefacts do not say which. |

**r1-paid** (page 0..361 of 768): 6 already receipted, 2 core notice inside 7 days, 1 receipted in
thread, 1 not attributable.

| entry | user | requests | dropped by |
|---|---|---|---|
| 0 | 11863 | 10 | already handled: 10 of 10 requests have a `status-doc-received` ledger row (sent 10-22) |
| 1 | 213550 | 3 | already handled: 3 of 3 (sent 10-23) |
| 2 | 12735 | 1 | already handled: 1 of 1 |
| 3 | 17619 | 15 | already handled: 15 of 15 (sent 10-22) |
| 4 | 12390 | 1 | already handled: 1 of 1 (sent 10-22) |
| 5 | 84019 | 1 | gate: `core_notice_within_7d` (core's approved notice inside 7 days) |
| 6 | 10562 | 14 | already handled: 14 of 14 (sent 10-26) |
| 7 | 11887 | 3 | gate: `core_notice_within_7d` |
| 8 | 53136 | 223 | no gate call, no ledger row: one of the runner's own holds. The artefacts do not say which. |
| 9 | 85340 | 22 | gate: `r1_receipted_in_thread` (we answered in the filing conversation) |

**r1-free** (page 617..818 of 902): 6 receipted in thread, 1 core notice, 1 filing class unknown,
1 unreadable filing, 1 not attributable.

| entry | user | requests | dropped by |
|---|---|---|---|
| 617 | 279236 | 5 | gate: `core_notice_within_7d` |
| 618 | 132219 | 47 | no gate call, no ledger row: one of the runner's own holds. The artefacts do not say which. |
| 619 | 1380463 | 11 | gate: `r1_receipted_in_thread` |
| 620 | 32671 | 1 | gate: `r1_receipted_in_thread` |
| 621 | 325976 | 1 | gate: `r1_receipted_in_thread` |
| 622 | 237161 | 8 | gate: `r1_receipted_in_thread` |
| 623 | 305170 | 4 | gate: `r1_receipted_in_thread` |
| 624 | 248144 | 29 | gate: `r1_filing_class_unknown` (the filing has no doc-verify read yet) |
| 625 | 343982 | 1 | gate: `r1_receipted_in_thread` |
| 626 | 1404851 | 2 | gate: `r1_unreadable_filing` (the reader found no text) |

## Count per gate, whole list

Read from the checks' own `-check.out` and `-check.json` on node-8, one rotation of pages per list
(`tools/gate.jq`). A list is rebuilt every tick, so a rotation joins pages of lists a few entries
apart. uvn-status-paid and r1-free are itemised with their pages in `per-gate-counts.md`.

| | uvn-status-paid | uvn-status-free | r1-paid | r1-free |
|---|---|---|---|---|
| entries walked | 947 | 2,255 | 766 | 818 of 902 |
| pages (ticks) | 2005Z, 1800Z | 1854Z, 2005Z, 1400Z, 1530Z, 1800Z | 2005Z, 1800Z, 1854Z | 1800Z, 1854Z, 2005Z |
| documents on file, not asked | 480 | 1,597 | - | - |
| `c2_signed_only` | 133 | 793 | - | - |
| `r1_receipted_in_thread` | - | - | 211 | 301 |
| already handled | 67 | 210 | 208 | 237 |
| `r1_filing_class_unknown` | - | - | 83 | 107 |
| `r1_unreadable_filing` | - | - | 30 | 36 |
| filing is a Muso screenshot | - | - | 13 | 9 |
| nothing to ask (inferred remainder) | 107 | not derived | - | - |
| 7-day cooldown, ledger | 56 | not derived | not derived | 36 |
| `core_notice_within_7d` | 29 | 43 | 57 | 30 |
| `messaged_7d` at the gate | 18 | 36 | 1 | 0 |
| `comm_state` | 17 | 33 | 0 | 1 |
| ask-only (big-track single signal) | 0 | 0 | 52 | 35 |
| fraud lens held | 14 | not derived | not derived | 12 |
| 90-day re-ask lock | 4 | 0 at the gate | 0 | 0 |
| Intercom identity / no channel | 3 | 46 | 1 | 2 |
| left for the next run (run size) | 0 | 1,056 | 0 | 0 |
| **accepted** | **1** | **54** | **0** | **0** |

`not derived`: the runner prints that counter mixed with gate deferrals (`render()` adds every gate
deferral to "deferred (messaged in the last 7 days or today)"), and I separated it only for the two
itemised lists. The 1,056 `run_size` rows on uvn-status-free were candidates the dry run did not
put to the gate, so they carry no gate reason. The 54 accepted on uvn-status-free were at 14:00Z
(4) and 15:30Z (50); the 18:54Z and 20:05Z pages accepted nobody.

## Not changed here

| bucket | state | what it needs |
|---|---|---|
| uvn-status `c2_signed_only` (133 paid, 793 free) | waiting on a recorded decision | an armed `armed_families["uvn-status:c2"]` row in node-8's live policy, placed by an operator, not a PR. Written up as a decision with a recommendation (arm both segments) in `data/send-families-zero-sends-r1/c2-row-decision.md`. |
| r1 already handled (208 paid, 237 free) | complete, and still listed | `receipts.py build()` does not read the verify ledger. |
| r1 `r1_receipted_in_thread` (211 paid, 301 free) | not settled | the hold records nothing, so the person returns every tick. |
| r1 filing class unknown (578 of 1,812 receipt rows) | unknown, not a no | doc-verify has no current read of the filing; why was not measured. |
| r1 unreadable filing (137) | no receipt is owed | the reader found no text; no family sends what these people are owed. |

## Not verified

- Nothing is deployed and no pre-check was re-run on the new code, so there is no after-the-fix
  list count. The zero the pre-check reported was a correct answer about the people it was given;
  the after numbers above are the selection replayed over copies of the live stores.
- A hold sends nothing. A user leaves `documents on file` only when stage 2 returns a verdict, and
  how the 2,598 will split between verdicts is not known.
- The pass has not been timed on node-8. It runs last in a decider run; a run killed before it
  holds nobody and the next run takes the same users.
- Three of the 40 sampled people (329685, 53136, 132219) were dropped by the runner before the
  gate with no reason in the artefacts. r1-free entries 818..902 were not walked by any check.

## Tests

`scripts/tests/test_credit_trust_decide.py`: 26 new tests, one assertion per line. The selection
reaches a `user_verification_needed` request and the old selection missed it; with the pass
stubbed out 11 of them fail, and with the allow-list widened 3 fail. Suite: 255 passed.
`test_credit_review.py` 137 passed; `test_ci_test_discovery.py` passed.
