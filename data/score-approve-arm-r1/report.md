# score-approve arm r1: the amber rule, the cap, and the 1,008 rows the job does not approve

Branch `fm/score-approve-arm-r1`. Nothing was enabled, written to core, sent to a customer, deployed or
merged. Every node-8 read below was read-only (`mode=ro` SQLite opens, one file read, `grep` of run.log).

## 1. What this change does

| item | state | where |
| --- | --- | --- |
| (a) amber fraud-watch accounts are not approved | **done, tested** | `scripts/credit_review/account_gate.py` `watch_refusal`, called at the gate step of `score_approve.run` |
| (c) 50 approvals per run | **done, tested** | `policies/credit-trust-decide.json` `score_approve.max_per_run` 100 -> 50 |
| the not-approved breakdown | **done, measured** | section 2 |
| (b) cron row `enabled: true` | **not done: refused by the held-cron guard** | section 3 |
| (d) 10 approvals per run with a Fable verdict | **not done: no path exists, needs a decision** | section 3 |
| (e) approved-credit message per approval | **not done: needs a decision on which sender and copy** | section 3 |

### (a) The rule

The account gate answers `allow` for an amber account: the watch was never a hold. `score_approve` approved
on `allowed` alone, so the watch excluded nobody from this job. The rule now is **only a green allow
approves**:

- band `green`, watch flag off: approved as before;
- band `amber`, or the watch flag on: `account on fraud watch (gate band amber: <the gate's reasons>): no score approval`;
- any other band on an allow (a released `red`): not approved;
- an allow that names no band: not approved. An unread band is never read as green.

It is the same code path in shadow and apply. Holds and unknowns are untouched (`account gate hold ...:
no approval, proof ask`). The run line gains `N not approved: account not green at the gate (fraud watch)`.

Replayed over the dry run's 221 would-approve rows (`tools/measure_held.py`): **28 rows / 5 users leave,
193 rows / 43 users stay**, the population the arming was approved on. All 221 had a readable band.

Tests (`scripts/tests/test_credit_score_approve.py`, `scripts/tests/test_credit_account_gate.py`):

- `test_an_amber_fraud_watch_account_is_not_approved_and_a_green_one_still_is`: same row shape on two
  accounts, the band the only difference; only the green account's row reaches the writer.
- `test_the_amber_rule_holds_in_shadow_too`, `test_an_allow_that_is_red_or_names_no_band_is_not_approved`.
- `WatchRefusal` (6 cases) on the gate client, fed the gate's own JSON shape.
- Mutation check: with the rule's `if watch:` replaced by `if False:`, exactly those three score-approve
  tests fail. Restored after.

Run: `test_credit_account_gate.py` 10 OK, `test_credit_score_approve.py` 62 OK,
`test_credit_trust_decide.py` 258 OK, `test_fraud_watchlist.py` 9 OK.

**On node-8 today the rule is absent.** Deployed sha `d88e2a111`; both kill files are absent (section 3);
the scheduler row is the only stop. Running the cron's argv by hand there would approve the 28 rows.

### (c) The cap

The policy held `max_per_run: 100` and the code ceiling is 100 (`ScorePolicy.load` refuses more), not 500
as the brief has it. It is 50 now because the decision on this lane set 50 (item "(c) cap 50 per run" of
the lane's ruling, passed into the task brief as the required cap and confirmed by firstmate
2026-11-14): 50 is the number that will bound the live approve path once the job is armed, and it is
inert until then because the cron row `credit-trust-score-approve-15m` stays `enabled: false`
(section 3b). The ceiling stays 100, so any number in 0..100 is this file's alone;
`test_the_checked_in_policy_paces_a_run_at_50_and_the_pace_binds` loads the checked-in policy and shows
row 51 waits. Four runs an hour is at most 200 approvals an hour; the 2,000 fleet cap per UTC day is
unchanged.

## 2. The 1,008 rows the job does not approve

Source: the dry run's decision log (cohort frozen 2026-11-14 14:53:40Z, 1,201 rows / 323 users, the deployed
job's own decisions). 221 would be approved by the deployed code; with the green rule 193 are, so
**1,008 are not** (the brief's "about 980" is 1,201 - 221, before the rule).

The proof-on-file split was read on node-8 at about 16:15Z (proof export of 15:58Z), 80 minutes after the

decisions. Rows / users; a user can sit in two groups.

Each group also carries **the class uvn-status puts the row in**, measured with the repository's own
`uvn_status._no_ask_of` on the admin row each decision was read from (`tools/ask_class_read.py`, section 6):
`approval_path` and `already_on_profile` are never asked about (`uvn_status.NO_ASK`), `low_risk_asked` and a
blank class keep the ask. On the 1,201 decided rows: **1,197 are `approval_path`, 4 are `low_risk_asked`**, so
of the 1,008 not approved here, **1,004 are in a class uvn-status never asks about**.

| # | rows | users | paid rows | the job's reason | the ask class | what moves it |
| --- | ---: | ---: | ---: | --- | --- | --- |
| 1 | 698 | 195 | 362 | proof on file: the **account** has a proof entry, no filed document names this request | `approval_path` (all 698) | an ask, and only through `proof-need-ask`: a `no_document` release to `uvn-status` would still leave the row out (`uvn_status.plan`: `nothing_to_ask`), and `need_asks.py` has no `NO_ASK` / `approval_path` check, so a sendable `need_more` need can be asked. Nothing approves it. See below |
| 2 | 238 | 69 | 142 | proof on file: a filed document names this request | `approval_path` (all 238) | an ask through `proof-need-ask` for a sendable doc-verify need; `uvn-status` cannot carry it (same class). `gap-ask` for `need_more` has no live sender. See below |
| 3 | 28 | 5 | 2 | account on the amber fraud watch (this change) | `approval_path` (all 28) | **nothing today.** The band is invisible to `uvn_status.approval_path_admits`, so uvn-status leaves all 28 out of its ask because the low-risk path can admit them, and this job now holds them for a reason uvn-status does not read. **See "neither asked nor approved" below** |
| 4 | 16 | 2 | 14 | `same_anchor_requests_7d unreadable` (velocity read failed in the run) | `approval_path` | the next run's read, after the 6 h re-read cooldown (`score_approve.REREAD_COOLDOWN_H`, `recently_held`). No person, no ask |
| 5 | 8 | 2 | 7 | engaged: Intercom conversation since the ask | `approval_path` (all 8) | **nothing today.** This job holds them for stage 2 and asks nothing; uvn-status leaves them out on the same ground as group 3, and its engagement signals (`engagement_checker`) are ones uvn-status does not read. Moving them needs a product change. See below |
| 6 | 7 | 1 | 7 | user on the deny / fraud / hold list (gate: hold, red) | `approval_path` (all 7) | **a deny: nothing approved, nothing refused.** uvn-status leaves them out (class), and a user the fraud lens holds is held in every campaign anyway. This job never refuses a request. See below |
| 7 | 4 | 3 | 1 | profile on the deny / fraud / hold list | `approval_path` (all 4) | a deny, same as group 6: the deny list is this job's answer, uvn-status does not read it, and the class already keeps them out of its ask |
| 8 | 4 | 1 | 4 | stored popularity 0 (unknown) | `low_risk_asked` (all 4) | an `uvn-status` ask: `popularity_unattributable` (`policy.server_big_track_reasons`) is in `uvn_status.POPULARITY_REASONS`, so the row keeps the ask. Nothing in this repo fills a popularity from a document, so what the answer moves is a person (`doc_approve.py`, Fable R22a D1 "Refuse popularity 0 in gate_tier") |
| 9 | 3 | 2 | 0 | organization / label / publisher / studio role | `approval_path` (all 3) | **nothing today.** The org-role rule is this job's alone (`score_approve.why_not`); uvn-status leaves the row out on the low-risk path, and no ask route reads the rule. Moving the group needs a product decision, not a workaround |
| 10 | 1 | 1 | 0 | user reached 20 score approvals today | `approval_path` | the next UTC day, when `written_today` no longer counts them against `per_user_per_day`. No person, no ask |
| 11 | 1 | 1 | 1 | no independent anchor: evidence incomplete (an admin read failed) | `approval_path` | the next run's read, after the same 6 h cooldown. No person, no ask |
| | **1,008** | | | | | |

### Groups 1 and 2: 936 rows / 263 users "for stage 2", of which stage 2 can see 29

The job's reason reads `proof path: engaged user (proof on file): stage 2, never a provisional approval`.
Measured against the stores stage 2 reads:

| a filed document names the request | decider row | stage-2 verdict | rows | users |
| --- | --- | --- | ---: | ---: |
| no (account-level entry only) | none | none | 676 | 188 |
| no | defer / support (not stage 2's input) | none | 21 | 13 |
| no | proof-on-file hold | need_more | 1 | 1 |
| yes | none | none | 196 | 57 |
| yes | proof-on-file hold | none yet | 15 | 5 |
| yes | defer / support | none | 14 | 9 |
| yes | proof-on-file hold | need_more | 13 | 3 |

- **872 of the 936 have no decider row at all.** Stage 2 judges only what the decider holds as proof on
  file, and the decider lists `unverified`; all of these are `user_verification_needed`. The pass that
  hands them over (`decide.hold_documented_uvn`) is live and takes 10 users a run: at 16:08Z it logged
  `19801 still to hold`, down from 20,201 at 14:56Z. That is about 330 requests an hour, so about 60 hours
  for the backlog if nothing new arrives (arithmetic on six log lines, not a measurement of the future).
- **Stage 2 does not approve.** Fleet-wide, its latest verdicts under the current analyzer (`pf-2`):
  need_more 18,811 requests, no_document 3,259, review 84, undetermined 297, human 17, reject_hold 11,
  **approve 2**. All 14 judged rows of this cohort are `need_more`. So moving groups 1 and 2 needs an
  **ask**, not an approval, and all 936 rows are `approval_path`: a `no_document` release to `uvn-status`
  would still ask them nothing (`uvn_status.plan` returns `nothing_to_ask` when every one of the user's rows
  is in `NO_ASK`). The live route is `proof-need-ask`, which does not read that class (`need_asks.py` has no
  `NO_ASK` / `approval_path` check and selects on the latest doc-verify need), and those two families are
  sending: 189 `uvn-status` and 15 `proof-need-ask` rows since 2026-11-13. `need_more` also names `gap-ask`
  (`stage2_verdicts.RELEASES`), and `gap-ask` has no live sender: it is not a family
  `scripts/credit-verify-outbound.sh` knows, and its crons are `enabled: false` (see below). Which of the 936
  will get which verdict is not known: only 14 are judged.
- **An approval from a document needs a product change.** No job turns a read document into an approval
  (the document class is `approved: false` in `policies/credit-approval-automation.json`). Until a captain
  decision creates that writer, a customer in groups 1 and 2 who answers the ask is read and not decided.
- **Group 1 is the larger question: 698 rows are on the proof path because of the account, not the
  request.** Every entry is an Intercom or Gmail whole-account entry; 382 rows / 87 users have only
  `human_approved_after_doc` entries (a person approved another credit of that account after a document).
  The decider's own per-request rule (`ProofOnFile.covers`) agrees these are covered, so this is the rule
  as ruled (Fable 15:40Z (3), review-core-10733 condition 1), not a bug. Whether one past document should
  keep every earlier request of an account off the low-risk lane is a ruling to change, not something to
  work around here.
- Gate mix of the 936, for anyone who would move them into this job: 759 allow/green, 137 allow/amber,
  1 allow/red, 39 hold. The green rule would refuse 138 of them.

### Neither asked nor approved: 1,004 of the 1,008 are in a class `uvn-status` never asks about

This is the finding the group routes add up to, and it is one defect, not eleven. `uvn-status` leaves a
request out of its ask **because the approval path can admit it** (`uvn_status._no_ask_of` ->
`approval_path_admits` -> `uvn_status.NO_ASK`), and `score-approve` then holds the same row for a reason
`uvn-status` does not read: engagement, the account gate's band, a deny list, an org role, a popularity value.
A row in both conditions is neither asked nor approved, and it waits for nothing that will arrive. The one
sub-case the ask path does honour is core's explicit `proof_required` verdict, which overrides the exclusion
in `uvn_status._no_ask_of` (the measurement includes that override).

Closing the gap is a product change: either the ask path reads the approval path's actual decision ("this row
was held, so ask it") or a watch refusal files its own ask. This PR does not do either, and it does not
resolve the rows; it records them.

### "No ask": groups 3, 5, 6, 7, 8, 9

This job sends nothing and files no ask. For these groups the question is which other job, if any, reaches
them; where the answer is "none", the wording says so and names what would have to exist.

- **The ask sender is `scripts/credit-verify-outbound.sh`**, ticked from node-8's
  `/etc/cron.d/credit-verify-outbound` (`scripts/lib/deploy-send-tick-hold.sh`), and a family it does not know
  cannot be sent: `KNOWN` there is `r1`, `status-doc-received`, `uvn-status`, `claim-status`,
  `claim-proof-ask`, `proof-need-ask`, `reply-due`, `uvn-status:c2`. **`gap-ask` is not on that list**, and
  its crons (`credit-stage2-gap-ask-paid` / `-free`) are `enabled: false` in `cron-jobs.json`, so a
  `need_more` user's live route is `proof-need-ask` (`need_asks.build`, a sendable doc-verify need) or
  nothing. `uvn-status` and `proof-need-ask` are the two families the ledger shows sending.
- **Group 3 (amber, 28 rows / 5 users).** All 28 are `approval_path`, so `uvn-status` never asks about them
  (`uvn_status.NO_ASK`): the band is invisible to `approval_path_admits`, and the job's new amber rule is a
  reason that ask path does not read. **Nothing moves them today** - not this job (it holds) and not an ask
  (it excludes). What would have to exist: an ask path that reads the gate's band, or a watch refusal that
  files its own ask. That is a product change; the fail-closed behavior (no approval) is the required one.
- **Group 5 (engaged, 8 rows / 2 users).** All 8 are `approval_path` and `score-approve` holds them for
  stage 2: **nothing moves them today.** The engagement signals this job reads (`engagement_checker`:
  `proof_on_file`, `support_email_90d`, `conversation_since_ask`) are invisible to `uvn-status`, whose
  `approval_path_admits` sees none of them, so the row is left out of the ask on the same ground as
  group 3. Nor is there a route through stage 2: an engaged row's verdict would release it to `uvn-status`
  (`no_document`), which would still leave it out on the class, or to `gap-ask` (`need_more`), which has no
  live sender. Moving them needs a product change (the ask path reading the approval path's hold).
- **Groups 6 and 7 (deny / fraud / hold, 11 rows / 4 users).** All 11 are `approval_path`, so `uvn-status`
  leaves them out, and a user the fraud lens holds is held in every campaign and never messaged
  (`fraud_lens.default_lens` with `policies/fraud-lens-holds.json`; `uvn_status` docstring: "a held user ...
  is reported fraud_held and never messaged or closed"). A **deny**, in the only sense this lane has: no
  approval, and this job never refuses a request. A hold that lifts is re-read on the next run, which is the
  only thing that moves these rows without a person. The gate's own hold reasons come from outside this repo
  (`/opt/firstmate/fraud-lens`).
- **Group 8 (popularity 0, 4 rows / 1 user).** All 4 are `low_risk_asked`, so they keep the `uvn-status`
  document ask: a stored popularity of 0 yields `popularity_unattributable`
  (`policy.server_big_track_reasons`), which is one of `uvn_status.POPULARITY_REASONS`, so
  `approval_path_admits` is false. The ask does not change the stored popularity, and nothing in this repo
  fills it from a document (`doc_approve.py`, Fable R22a D1: "Refuse popularity 0 in gate_tier"), so what
  decides these rows after an answer is a person, not this job.
- **Group 9 (org / label / publisher / studio role, 3 rows / 2 users).** All 3 are `approval_path` and
  `uvn-status` never asks about them: the org-role exclusion is this job's rule (`score_approve.why_not`),
  and no ask route reads it. **Nothing moves them today.** Moving the group needs a product decision (who may
  approve an org-role credit and on what evidence), not a workaround here.

## 3. What this change does not do, and what is needed

### (b) `enabled: true` is refused, and the recorded lift never happened

`scripts/check-held-cron-guard.py --staged` on the one-line flip:

```
held-cron-guard: REFUSED - 1 finding(s) against HEAD:
  - R1 credit-trust-score-approve-15m: enabled False -> true while its kill file
    /etc/hydra/credit-trust-score-approve.disabled is present; the scheduler row is a stop, lifted only
    by the recorded step
```

The only way through is a committed `data/kill-lift/<key>.evidence` whose last record is `lifted`, which the
node-8 hand-off job compares byte for byte with the host's copy. There is none:

- node-8 holds kill-lift evidence files from 11-04 to 11-08. **None of them contains a `lifted` record**,
  and the four newest end `PLANNED, NOT EXECUTED`.
- The last plan is `kill-lift-1108-1747` (its generated `lift-step.sh` is still there, unrun). 38 minutes
  later the score-approve kill file was renamed by hand to `.disabled.cleared-20261108T1825Z`; the
  decider's was renamed three times (`.cleared-20261108T0538Z`, `T1820Z`, `20261109T1730Z`).
- So `policies/held-crons.json` says both crons are held by a present kill file, and the host has had
  neither since 11-08. The planner refuses to run in that state (`NOTHING TO LIFT`).

I did not write an evidence file, edit the registry or touch node-8. Any of those would be passing the
guard on a record of something that did not happen.

### (d) A Fable verdict on 10 approvals per run has nowhere to be made or recorded

- The job files a deterministic sample (10 % / 5 %) to `score-approve-audit/<day>.jsonl`. Nothing in the
  repo reads those files back. At 50 a run, 5 % is 2 or 3 rows, not 10.
- node-8 cannot reach Fable. The one existing shape for a Fable verdict on node-8 work is the copy gate's
  pull round from the reviewer host (`outbound_copy/review_pull.py`, signed verdicts).
- An hourly AI audit of approvals is already on (`credit-approval-auditor-hourly`, 10 % of a 90-minute
  window), on a different model. It is not a Fable verdict.

What a verdict does is the open part: Fable's band-B condition 10 pauses the job when an audit falls below
95 % precision, and nothing enforces it today.

### (e) No approved-credit message exists for these approvals, and two senders are barred

- `score_approve` sends nothing by design. Its docstring says core's "approved" notice goes out on every
  approval; the dry run found **0 of 69** approvals of the 11-13 run carry core's notice stamp, and no
  `decision_told` or verify-ledger row for any of their 28 users.
- The hydra sender for provisional approvals (`verify-notify`, campaign `verify-live`, through
  `intercom-verify-request.sh`) was retired on 2026-11-06 (Fable switch-on plan row 7: "keeping it enabled
  means two senders") and is a held cron behind `/etc/hydra/credit-verify-notify.disabled`.
- `decision_told.py` sends core's decision-approved notice, capped and laddered, but it is not behind
  hydra's copy gate.
- `credit-approved-elsewhere` is send-locked and is a different message.

So "through the existing copy gate, one per user per UTC day" has no sender to attach to without either
reviving a retired one or adding a family with new copy. Both are decisions on customer copy.

## 4. Deploy

Arming takes effect only when a deploy lands a head with the flipped row. As given in the brief: the
14:36Z run halted at Step 0 on node-8 drift (baseline `d88e2a111`, 94 changed files) and
https://github.com/Muso-AI/hydra/pull/1981 is the fix. I confirmed the deployed sha and that the PR is
open; I did not read the halted run.

## 5. Not measured

- The ask class is measured from the admin rows the dry run read at 14:53Z with this repository's own
  `uvn_status._no_ask_of` (`tools/ask_class_read.py`), not observed from a `uvn-status` run, which reads the
  core replica: a row whose replica copy differs from the admin copy the dry run saw could be classed
  differently.
- Whether core sends a notice without stamping `metadata.approvedNotice`.
- Whether the 16 `unreadable` velocity rows are the dry-run harness or production behaviour.
- Whether `hold_documented_uvn` takes a request whose newest decider row is a defer or support (35 rows).
- The fraud lens rules on node-8 (`/opt/firstmate/fraud-lens`), which decide who is amber and who the gate
  holds, are outside this repo; this change reads the band and does not define it.

## 6. Reproduce

```
OUT=<score-approve-dryrun-r1>/run/out.jsonl          # names and e-mails inside: not committed
T=data/score-approve-arm-r1/tools
python3 $T/measure_held.py $OUT                                    # the groups, and the green rule's 28 / 193
python3 $T/measure_held.py $OUT --stage2-ids > ids.json
python3 $T/measure_held.py $OUT --scope-ids  > scope-ids.json
# each reader runs on node-8 with its input prepended as REQUESTS_JSON (see the reader's docstring):
#   stage2_read.py -> s2.json   proof_scope_read.py -> scope.json   decider_state_read.py -> decider.json
python3 $T/measure_held.py $OUT --stage2 s2.json --scope scope.json --decider decider.json
python3 $T/ask_class_read.py $OUT                                  # the ask class of every group (section 2)
```
