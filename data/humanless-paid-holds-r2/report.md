# Paid holds that end at a person: what is measured so far

Status: PARTIAL. Written 2026-11-14 on firstmate's instruction (inbox 001) before any code change.
Only the census is measured. The approve / decline / ask split per reason is NOT measured yet.

## How it was measured

- Source: node-8 `/var/lib/hydra/credit-review/ledger.sqlite3`, opened `mode=ro`, at 2026-11-14T08:49:20Z.
  Deployed tree on node-8: `7944deb5a`. Ledger: 1,089,571 `decisions` rows, 2026-10-17 to 2026-11-14T08:30Z.
- Tool: `data/humanless-paid-holds-r2/tools/measure.py` (piped over ssh, leaves no file on node-8).
  Raw output: `data/humanless-paid-holds-r2/measure-2026-11-14T0849Z.json`. The query takes about 1.5 s.
- Population: the LATEST `decisions` row of each request (highest id, any mode) where `paid_priority = 1`.
  That is 18,498 paid requests. A row is grouped by its reason text, each row counted once:
  `score approval not now` prefix, then `proof on file: stage 2 judged` prefix, then any reason containing
  `human review`.

## The three groups

| Group | Rows | Users | Previous lane (rows / users) |
|---|---|---|---|
| human review | 7,966 | 857 | 4,690 / 608 |
| score approval "not now" | 1,206 | 208 | 1,214 / 204 |
| stage 2 judged | 1,386 | 225 | 1,379 / 223 |
| users in any group | | 1,138 | about 1,035 |

My numbers are the ones to use. Score and stage 2 agree with the previous lane to within a day of ledger
movement. Human review does not: 7,966 rows against 4,690. I cannot reproduce 4,690 from any slice I tried
(apply mode only is 3,437 rows / 492 users; judge mode only is 4,505 / 422). One candidate explanation, NOT
verified: 3,153 of the rows (280 users) carry the suffix `already user_verification_needed: recorded so
stage 2 reads the document`, which is the per-run-capped hand-off added by #1959, and 7,966 - 3,153 = 4,813.
I have not checked those rows' dates.

### human review, by the site that wrote the row

| Reason prefix | Rows | Users | Written at |
|---|---|---|---|
| `proof on file: human review` | 6,904 | 797 | `decide.py` `DOC_ON_FILE_HOLD` (`filter_support`, and the #1959 hand-off) |
| `validator reject rule fired ...: human review` | 606 | 42 | `decide.py` about line 2982 |
| `emailed support@ in the last 90 days: human review` | 416 | 34 | `decide.py` about line 1109 |
| `support already requested for this credit once: ... human review` | 30 | 5 | `decide.py` about line 1113 |
| `server approval guard would refuse (...): human review` | 10 | 2 | `decide.py` about line 3326 |

By mode: apply 3,437 rows / 492 users, judge 4,505 / 422, shadow 24 / 1. Every row is `decision = hold`.
Two more sites write `human review` in the code and have no paid latest row today: `documentation required
... no approved proof is on file` (about line 3305) and `doc approval refused at the write boundary` (about
line 3374).

### score approval "not now", by sub-reason

| Sub-reason | Rows | Users |
|---|---|---|
| `proof path: engaged user (...): stage 2, never a provisional approval` | 553 | 157 |
| `stored popularity N (...): human` | 254 | 63 |
| `organization / label / publisher / studio role` | 200 | 5 |
| `no independent anchor: the validator approved it only via the claimant's own Muso cred...` | 126 | 10 |
| `same_anchor_requests...` (velocity-class hold, readable and unreadable) | 24 | 2 |
| `user reached N score approvals today` | 24 | 1 |
| `big track (...)` | 12 | 4 |
| `user on the decider's deny / fraud / hold list` | 10 | 2 |
| `editorial role (...) on a track at pop >= 30` | 2 | 1 |
| `profile on the decider's deny / fraud / hold list` | 1 | 1 |

By mode: shadow 1,169 rows / 206 users, apply 37 / 2. By decision: hold 1,182, defer 24.

### stage 2 judged, by the verdict in the reason

| Verdict | Rows | Users |
|---|---|---|
| `need_more` | 1,286 | 217 |
| `no_document` | 100 | 8 |

By mode: judge 1,333 rows / 207 users, apply 53 / 21. Every row is `decision = hold`.

## What the person was going to add, per reason

Read from the code at `98f1b48eb`. This is what the code says, not what any person did.

- **proof on file: human review** (797 users). A document is on file and nobody has decided whether it
  supports the credit. The person was to read the document against the track and role. The AI decision that
  replaces it is the document read that already exists (doc-verify and stage 2): approve when the document
  covers the track and role, otherwise an ask naming the track, the role and the kind of document.
  `stage2_verdicts.py` says which stage-2 verdicts are left at this hold: `review`, `reject_hold`, `human`, a
  first `undetermined`, and `approve` ("stays with a human"). Those five are the real person-ending set.
- **validator reject rule fired** (42 users). The person was to confirm that the reject rule is right. The
  replacement is a decline that carries the rule as its reason, or an ask when the rule names a missing piece.
- **emailed support@ in the last 90 days** (34 users). The person is whoever answers the support thread.
  The replacement is a decision or an ask on the credit itself; the open thread is not an answer to it.
- **support already requested once** (5 users). The customer was asked once and the credit is never asked
  again. The person was to chase it. The replacement is a wait on the customer with an end: a decision from
  what is on file when the wait closes.
- **server approval guard would refuse** (2 users). An approve the server would refuse for a reason that is
  not a documentation need (for example a stored popularity of 0). The replacement is an ask for the
  document that would let the server accept it.
- **score approval "not now"** (208 users). The validator approved the request at low risk and one of the
  score arm's own checks said no. The person was to supply what that check lacked: an outside anchor, the
  popularity of the track, proof for an organisation role. The replacement is per sub-reason: a decline with
  its reason where the check is a genuine decline (deny list), an ask naming the missing piece everywhere
  else. No threshold moves.
- **stage 2 judged** (225 users). See the first blocker below: the hold text already names a customer ask.

## What I found that stands in the way

1. **The stage-2 group may not end at a person as written.** Its reason reads `the user is asked through
   intercom-verify-request.sh --campaign gap-ask` (for `need_more`) or `--campaign uvn-status` (for
   `no_document`). That is a customer ask, not a staff queue. Whether those asks were SENT is not measured:
   it needs the verify ledger, which I have not read. If they were not sent, the row ends at nobody, which
   is the same failure under another name. The stage-2 verdicts that do end at a person are counted inside
   `proof on file: human review`, not here.
2. **The score group is 97% shadow rows** (1,169 of 1,206). The score arm records them in shadow mode, so
   most of this group is a record of what the arm would do, not an armed hold.
3. **24 of the score rows are a daily cap** (`defer`, re-read the next day). They do not end at a person.
4. **The ledger's latest row is not the request's live status.** I have not joined these rows to core, so
   some of them may already be approved or closed by another path. Every count above is ledger state.
5. **Three open PRs change the same `decide.py` holds**:
   https://github.com/Muso-AI/hydra/pull/1961 (AI proof-review verdicts, the `proof on file` hold),
   https://github.com/Muso-AI/hydra/pull/1962 (ladder v2 ends at no person) and
   https://github.com/Muso-AI/hydra/pull/1967 (never approve a request the validator has on hold). I have
   not read their diffs. A fourth change to the same lines will conflict with whichever lands first.
6. **The brief asks for "six numbers".** Three reasons by three outcomes is nine. I will report nine.

Nothing was unreachable. No query ran long.

## Not done yet

- The approve / decline / ask split per reason (needs the proof store and the doc-verify store on node-8).
- Whether the stage-2 asks were sent (verify ledger).
- The join to core's live status.
- Any code change. The worktree holds this report and the measuring tool only.

## One thing I did on node-8

My first exploration copied a read-only script to node-8 `/tmp/hph-explore.py`. I removed that one file in
the next command. Nothing else was written there.

---

# The approve / decline / ask split: PARTIAL (added on inbox 003)

Status: the per-USER split is **not measured** for any of the three groups. What is measured is the
evidence on file, counted per (request, role) pair. No query is running; the time since the last commit
went on reading the two evidence stores and the code that reads them, not on a slow query.

## About the earlier human-review figure

The previous lane's 4,690 rows / 608 users is not what the ledger holds. Use 7,966 rows / 857 users. I could
not reproduce 4,690 from any slice, so I cannot say whether it was wrong when it was measured or the ledger
has moved since. The one candidate I have (the 3,153 rows written by the #1959 hand-off) is still unchecked.

## What was read

- `tools/evidence.py`, piped over ssh to node-8 at about 09:00Z on 2026-11-14, read-only, about 11 s.
  Its output was read in the terminal and NOT saved to a file; the numbers below are copied from it.
- The same 10,558 paid held requests as the census (7,966 human review, 1,206 score, 1,386 stage 2).
- Stage-2 store: `/var/lib/hydra-credit-verify/proof.sqlite` `stage2_shadow`, latest row per (request, role).
- Doc-verify store: `/var/lib/hydra-credit-verify/doc-verify.sqlite` `dv_outcomes`, latest row per
  (request, role). Latest, not best: a pair whose newest row is `unknown` may have an older real verdict.

## Evidence on file, per (request, role) pair

Stage 2, latest outcome:

| Group | Requests with a stage-2 row | approve | need_more | no_document | review | human | undetermined |
|---|---|---|---|---|---|---|---|
| human review | 5,695 of 7,966 | 2 | 10,582 | 627 | 292 | 6 | 167 |
| score not now | 34 of 1,206 | 0 | 82 | 14 | 0 | 0 | 0 |
| stage 2 judged | 1,386 of 1,386 | 0 | 3,043 | 192 | 18 | 14 | 0 |

Doc-verify, latest outcome (`unverifiable` split by the document it says is needed):

| Group | Requests with a doc-verify row | verified | forged | distributor dashboard with code | readable document | counterparty signed or registered | issuer email from official domain | unknown (not read) |
|---|---|---|---|---|---|---|---|---|
| human review | 3,134 of 7,966 | 0 | 28 | 3,899 | 426 | 297 | 313 | 661 |
| score not now | 329 of 1,206 | 0 | 0 | 486 | 103 | 91 | 71 | 22 |
| stage 2 judged | 1,163 of 1,386 | 3 | 0 | 2,039 | 249 | 383 | 124 | 68 |

No pair has `contradicted`. No pair has `account_hold` set. One of the three `verified` pairs and 156 of the
distributor pairs are older `dv-1` rows; the approval class accepts `dv-4` only.

## What that says about the split

| Group (users) | Approve | Decline with a reason | Ask |
|---|---|---|---|
| human review (857) | not measured in users. Evidence for it: 2 pairs. | not measured in users. Evidence: 28 forged pairs, plus the 606 rows / 42 users whose hold is a validator reject rule. | not measured in users. Almost every other pair. |
| score not now (208) | not measured in users. Evidence for it: 0 pairs. | not measured in users. Evidence: the 11 rows / 3 users on the deny / fraud / hold list. | not measured in users. Every pair with evidence is an ask. |
| stage 2 judged (225) | not measured in users. Evidence for it: 3 pairs (2 on `dv-4`). | not measured in users. Evidence: 0 pairs. | not measured in users. Almost every other pair. |

The shape is already clear even without user counts: the evidence on file supports an approval for at most
a handful of requests in all three groups together. Nearly everything becomes an ask.

## What it takes to finish the split

One more read-only query of the same three stores, no new source:

1. Join the pairs to each request's claimed roles and take one outcome per request (approve only when every
   claimed role has approving evidence), then count distinct users per outcome. Users can fall in more than
   one outcome, so the three numbers per group will not sum to the group.
2. Use the newest verdict that is not `unknown` instead of the newest row.
3. Decide what the 2,271 human-review requests and 1,172 score requests with NO stage-2 row are asked. I
   have not looked at them.
4. Read the verify ledger for asks already sent. An ask the 90-day re-ask lock forbids cannot be sent.

## Found while measuring, and open

- **Three reasons by three outcomes is nine numbers**, not six. I will report nine.
- **751 pairs are `unknown`**: the reader has not read the document. That is not a verdict and not an ask;
  it is a wait on an automated job.
- **508 pairs need `issuer_email_from_official_domain`**, which `need_asks.py` cannot send today
  (`NOT_YET`: verify@ is off). For those requests the specific ask exists and has no sender.
- **A decline rule conflicts with a standing rule.** AGENTS.md records a captain decision of 2026-11-11:
  refusals are not autonomous and go to a named human. The 2026-11-13 rule in this lane's brief says deny
  with the reason and never a person. Both cannot hold for the validator-reject and forged-document rows.
  This lane records only, so nothing is denied by it, but the PR needs to say which rule it follows.
- The deny / fraud / hold list is one list. A row on it for "hold" is not a decline; I counted all 11 as
  decline evidence and have not separated them.

---

# Conclusion (added on inbox 004; the lane stops here)

No query was started after the last commit and none is running. No code was changed by this lane. The PR
the brief asked for was not built: firstmate took the design call on inbox 004.

## The split, as far as it was measured

Paid users whose latest ledger row is one of the three holds: human review 857, score approval "not now"
208, stage 2 judged 225; 1,138 in any group; 10,558 requests.

| Group (users) | Approve | Decline with a reason | Ask |
|---|---|---|---|
| human review (857) | evidence on 2 (request, role) pairs | 28 forged pairs; 606 rows / 42 users held on a validator reject rule | the rest |
| score not now (208) | evidence on 0 pairs | 11 rows / 3 users on the deny / fraud / hold list | the rest |
| stage 2 judged (225) | evidence on 3 pairs, 2 of them on `dv-4` | 0 pairs | the rest |

Units differ by cell on purpose: each number is in the unit it was measured in. None of them is a count of
users the AI decision would approve, decline or ask.

## What could not be measured, and what simply was not

These are two different things and the report keeps them apart.

**Not measured, though the stores carry it.** The per-user approve / decline / ask split. The ledger has the
user and the claimed roles of every request and the two evidence stores have an outcome per (request, role),
so one more read-only query would give it. It was not run. I am not recording it as unmeasurable, because
that would be untrue; inbox 004 describes it that way and I am correcting that here.

**Not on file anywhere, so no query gives it.** These are the limitations:

1. **What a person decided.** Nothing I read holds a person's verdict on any of these requests. The earlier
   audit (`humanless-audit/report.md` in firstmate's data) says the one table a reviewer would write,
   `verify_proof_reviews`, has no rows at all; I did not re-check that on the ledger. So "the decision the
   reviewer would have made" has no record to copy and cannot be measured against.
2. **The proof itself.** For the pairs marked `unverifiable`, doc-verify's own answer is that the document
   on file does not prove the credit and names the document that would. That document is with the customer.
   No reader, person or model, can approve from what is on file without stepping around the coded checks.
3. **What to ask where no document was read for the credit.** 2,271 human-review requests and 1,172 score
   requests have no stage-2 row. The stores name no missing document for them. I did not look at them, so
   this is the store's silence plus my own gap.

## What a person would have added that an AI decision cannot

This is read from the code and the stores, not observed: no review by a person is on record to compare.

- **Acceptance of a document the checks call unverifiable.** That is the only thing the "human review" hold
  left room for. It is a judgement with no outside source behind it, which is exactly what the coded gates
  refuse (unknown never approves). An AI decision cannot add it either without becoming the thing the gates
  exist to stop. The way off a person for these rows is the ask doc-verify already names, not a new approver.
- **A source the system does not hold**, for the score arm's holds: an outside anchor, the popularity of a
  track stored as 0, proof for a label or publisher role. A person could look one up. The AI decision has
  only what was fetched, so these are asks too.
- **Nothing**, for the stage 2 group. Its hold already names a customer ask. Whether those asks were sent
  is not measured.

So the evidence on file supports an approval for a handful of requests at most, a decline for the forged
documents and the validator-reject rows, and an ask for nearly everything else.

## Still open for whoever designs from this

- The 2026-11-11 rule (a refusal goes to a named human) against the 2026-11-13 rule (deny with the reason,
  never a person). The decline rows cannot follow both.
- 508 pairs need an issuer email from an official domain, an ask `need_asks.py` cannot send while verify@ is off.
- 751 pairs are `unknown`: the reader has not read the document. A wait on an automated job, not a verdict.
- An ask is only an ask if it can be sent. Asks already sent inside the 90-day re-ask lock were not counted.
- The earlier 4,690 rows / 608 users for human review is not what the ledger holds and was never reproduced.
- https://github.com/Muso-AI/hydra/pull/1961, https://github.com/Muso-AI/hydra/pull/1962 and
  https://github.com/Muso-AI/hydra/pull/1967 touch the same holds; their diffs were not read.
