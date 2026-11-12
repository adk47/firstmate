# GDPR / DSAR AI handling: report

The measured baseline is in [`baseline.md`](baseline.md). This file records findings and decisions made
while building the automated path.

## Finding 1: node-8 cannot reach the reviewer model

A customer message must carry a reviewer verdict bound to its hash before it sends. The sender runs on
node-8. The reviewer model (Fable) is served only by the token pool on the build box, on loopback. node-8
has no route to it.

Evidence, measured 2026-11-12T01:17Z:

| Check | node-8 (`ovh-node-8`) | Build box |
|---|---|---|
| Listener on tcp 8317 | none (`ss -ltn` shows 0) | `127.0.0.1:8317` listening |
| CLIProxyAPI process | none | `cli-proxy-api` running, owns the listener |
| CLIProxyAPI containers | `cliproxyapi` Exited (0) 6 months ago; `cliproxyapi-oauth-test` Exited (255) 6 months ago | n/a |
| systemd units naming cliproxy | 0 | n/a |

Repo evidence: `scripts/deploy.sh:959` reads "Decommissioned CLIProxyAPI sidecar (PR #224)" and excludes
its two config files from the sync. `policies/egress-allowlist.yaml:31-35` still allows tcp 8317 to
127.0.0.1 for a sidecar that no longer runs, and lines 90-94 deny `api.anthropic.com` directly. So the only
permitted route to the reviewer from node-8 is one that does not exist.

The build box listener is bound to loopback, so node-8 could reach it only through a tunnel from the build
box. That would make every customer send depend on a service that exists only on the build machine.

### Decision (firstmate, 2026-11-12T00:56Z)

Do not make the gate depend on a service on the build box over loopback. Operations run in OVH.

1. **Short term.** node-8 authors the message and holds it unsent with its hash and a pending verdict. A
   puller on the build box (or any host that can reach the pool) fetches pending messages, gets the verdict
   and writes it back. Held unsent is the correct failure mode; unapproved copy never sends.
2. **The real fix.** The gate model stands as a reachable service in OVH, deployed as code, so node-8
   reaches it directly. It need not be Fable: DeepSeek, Grok and the other OpenRouter models are legitimate
   for the mechanical copy checks behind the same verdict contract, with Fable reserved for the
   consequential messages.

### What this lane does

This lane does part 1, on the sending side only: the GDPR pipeline authors each message, records its
sha256, and holds it until a verdict on that exact hash is present. Anything other than an approval is a
hold, including a gate that is missing or cannot run.

This lane does not build a gate. Lane `outbound-copy-fable-gate-v1` is building one
(`scripts/outbound_copy/gate.py`: `check` on the sender, `review` on the reviewer host, a signed statement
over the body hash and the rubric hash). The GDPR pipeline calls that gate's `check`. Lane
`verif-fable-gate-rollout-s6` is wiring the other verification senders to the same gate. Both lanes were
told this directly on 2026-11-12.

Part 2 is not built here. It is the same gate with a different reviewer behind it, so it belongs with
whichever lane owns the gate.

### Open points raised with the gate lane

- That gate's rubric forbids dates and deadlines in customer copy (rule 5). A GDPR acknowledgement must
  state the statutory deadline. GDPR messages need their own rubric, bound into the verdict the same way.
- As of 01:17Z the gate is uncommitted and not on node-8 (`/opt/hydra/scripts/outbound_copy` and
  `/var/lib/hydra/outbound-copy` do not exist). Until it lands, every GDPR message this lane authors holds.

Both points moved on 2026-11-12: the gate lane committed the gate (`7b3b95bbe`) with the four `gdpr-*`
campaigns mapped to a `gdpr` rubric family, and this branch ships that family's rubric
(`policies/outbound-copy-rubric-gdpr.md`). The gate is still not on node-8.

## What is built (branch `fm/gdpr-ai-handling-v1`)

Authoritative description: `docs/support/gdpr-pipeline.md`, section "The DSAR ladder".

| asked for | what exists | where |
|---|---|---|
| a state machine with a due date | `received -> identity_check -> in_progress -> responded -> closed`, derived from recorded facts each run; a request reaches `responded` / `closed` only with a recorded final response | `scripts/gdpr_pipeline/dsar.py` `state_of`, `due` |
| acknowledgement with the statutory date | one per request, stating the date received and the date we answer by (the earlier of one calendar month and 30 days), and the one thing needed | `dsar.owed`, `policies/gdpr-dsar-copy.json` |
| deterministic identity | the three gates of the 2026-11-12 ruling, recorded per request; a name match no longer passes; no message asks for an identity document | `dsar.gates`, `identity.decide_page` |
| status updates | at the halfway point, and every 14 days for a request past its date, each saying what we are doing, what we need and when they hear next | `dsar.owed` |
| AI-authored, reviewer-gated, verdict bound to the hash | copy written by the model and fixed per variant; a body reaches a writer only on an approval of its exact sha256 under the GDPR rubric; anything else holds | `scripts/gdpr_pipeline/copy_gate.py`, `send.deliver` |
| a clock that pages firstmate | every statutory request inside 7 days of its date or past it, named, oldest first; no person is mentioned in the Slack page any more | `dsar clock --line`, `scripts/gdpr-dsar-clock-check.sh` |
| evidence trail | one command rebuilds a request's record from the store: received, checked, each body with hash and verdict, each send | `dsar trail --request N` |

Tests: `tests/test_gdpr_dsar.py` (70 at the first push, 122 now) and `tests/test_gdpr_pipeline.py` (461), both in PR Validation.

## Finding 2: the copy was reviewed by the reviewer model, through the real gate

Run on the build box in a scratch mirror of this branch plus the gate lane's `gate.py` at `7b3b95bbe`.
The real adapter asked the real gate; the gate held each body as pending; `gate.py review` put the 18
enabled bodies to `mac-pool/claude-fable-5-1` under the GDPR rubric; the adapter then read each verdict.

| round | approve | rewrite | refuse | what changed afterwards |
|---|---|---|---|---|
| 1 | 8 | 10 | 0 | status updates now say "still open" and no longer promise the answer by the next-contact date; "one thing" no longer precedes two asks; a representative is asked for a label or management document, or for the person they write for to claim the page |
| 2 | 16 | 2 | 0 | the account ask no longer reads as doubt about the person; the authority option says how to send the document |
| 3 | 18 | 0 | 0 | none: this is the wording in the copy file |

Each round's verdicts, notes and replacement texts are in `copy-review-round1.json` to `-round3.json`
beside this file, with the body hash, verdict id, statement hash, rubric hash and the gate commit.

Two limits on what this proves:

- The statements were signed with a throwaway key that exists only in the scratch mirror. Production
  accepts only the key pinned in `policies/outbound-copy-reviewer.allowed_signers`, so none of these is a
  verdict node-8 would send on. That is the intended boundary.
- The bodies carried example dates. A real body has its own dates, so its own hash, and needs its own
  verdict. The wording is what was approved here, not any real message.

In the same mirror, two scratch requests were then taken through `dsar send` with a stub in place of the
Intercom writer. Both acknowledgements were approved by the gate and handed to the writer once; a second
run sent nothing. The trail for the first shows body `d95462561a09d61d...`, gate result `approved`,
verdict `ocv-05cfe63e6d7253ac`, statement `2a684d1efdb0b596...`, reviewer `mac-pool/claude-fable-5-1`,
and a send row whose `approved_by` is `gate:ocv-05cfe63e6d7253ac`.

## Finding 3: the ladder run against the live register (nothing written, nothing sent)

The live register was copied into process memory on node-8 and the whole ladder was run on the copy: the
identity chain on every open statutory request, then author, then send. No writer was reachable and the
copy was discarded. Run 2, 2026-11-12T03:56Z, all 309 open statutory requests, 0 read errors, 39 minutes
(the catalog reads; the hourly tick only re-decides what changed).

| | all 309 | erasure 281 | access 28 |
|---|---|---|---|
| gate 1, account control | 109 | 86 | 23 |
| gate 2, tied to the page (claimed by that account) | 14 | 5 | 9 |
| gates 1 and 2 | 14 | 5 | 9 |
| gate 2 not decidable: no page named, page already off the site, or a read that failed | 239 | 229 | 10 |
| gate 3, an authority document would settle it | 39 | 30 | 9 |
| gate 3, a document on file | not measurable: nothing stores one | | |

Gate 2 is lower than the baseline's 33 because the baseline counted a claim whatever the page's state.
The chain reads "already hidden" and "gone" first, and such a page ties nobody and needs nothing. That
explanation follows from the code order; the 19 rows were not re-read one by one.

What each request needs, as the chain decides it: a link to the page 131, nothing 103, claim the page or
send a label/management document 38, not yet readable 35, write from the account 1, authority for a
representative 1. No request is asked for an identity document.

Messages owed, before the fourth fix below: 200 (50 acknowledgements, 150 status updates), 140 distinct
bodies, 0 lint problems. All 200 held, reason "the copy gate is not installed". Route: Intercom 134, mail
reply 6, new mail thread 3 (held by design: its lead line and subject are not reviewed copy), **no route
57** (mail requests with no thread and no sender on file; nothing can be sent to them and the clock keeps
naming them).

Four defects surfaced only on live data. Each is fixed with a test that names the request:

1. #52 would have been told "you will have our answer by 12 November" one hour before that date. An
   acknowledgement is now sent only with 3 days or more left; nearer than that, the request gets the
   "still open" update with a next-contact date.
2. 40 gate-2 "passes" in run 1 were pages already hidden or gone; 12 were claims. Such a page now ties
   nobody.
3. An 8-character id prefix that the catalog could not resolve was treated as a fact when the lookup
   itself had failed. It is now "ask for the link" only when the catalog answered.
4. #265 had an ask in the send ledger marked sent on 2026-11-08 and no `ask_sent_at` on its row, so it was
   owed a first acknowledgement. 24 open requests were in that shape. The ladder now reads the ledger as
   well as the row. After the fix, a kinds-only recount on the live register (04:48Z): 47
   acknowledgements and 124 status updates owed, 138 requests owed nothing right now (contacted inside
   the last 7 days), and 0 of the 23 unstamped requests owed a first message.

The 23 unstamped rows are a data defect in the existing path, not repaired here (read-only against
prod). The older ASK chase in `run.py` reads the stamp, so it does not chase them.

## Finding 4: four real requests, their exact messages, reviewed

`real-request-review.json`. The message owed to the four newest open requests that have heard nothing
from us was computed from the live register at 04:48Z, and those exact bytes were put through the real
adapter and the real gate with the reviewer model, in the scratch mirror.

| request | class | received | answer by | need | body sha256 | verdict |
|---|---|---|---|---|---|---|
| #442 | erasure | 2026-11-10 | 10 December 2026 | nothing (signed in, page claimed) | `a780e625687d0b48...` | approve, `ocv-f5bf80456feac416` |
| #464 | erasure | 2026-11-11 | 11 December 2026 | not yet readable | `8c6550d38c57bbe4...` | approve, `ocv-e6711bb7e2a43468` |
| #415 | erasure | 2026-11-08 | 8 December 2026 | not yet readable | `708d0c57003edfeb...` | approve, `ocv-7a37186b80abb904` |
| #483 | access | 2026-11-08 | 8 December 2026 | not yet readable | same body as #415 | same verdict |

Reviewer `mac-pool/claude-fable-5-1`, 2026-11-12T04:55:41Z, rubric family `gdpr`.

**None of the four was sent, and no request has been handled end to end in production.** The verdicts
are signed with the mirror's throwaway key, which production does not accept. The proof asked for (a real
request, its message hash and verdict recorded, sent) is not met. What stands between here and it:

*As read at 2026-11-12T04:48Z. By 14:05Z items 1 and 2 had cleared: node-8 is on `8b9e7568a` and the gate PR
merged at 10:42Z with `gate.py` deployed. Items 3 and 4 stand. The current list is under "Proof of done".*

1. **Production cannot be deployed to.** `Deploy HYDRA` has failed three nights running: 11-10 and 11-11
   refused on an open credit send tick window; 11-12 (run 43152336573) is `DEPLOY BLOCKED`, server and
   repo both changed six paths since `87027e740`, one of them `scripts/gdpr_pipeline/hide_batch.py`.
   node-8 runs the 2026-11-09 tree.
2. **The gate is not merged.** https://github.com/Muso-AI/hydra/pull/1895 carries `gate.py`; its own lane
   says do not merge that head (a QA finding it reproduced).
3. **No review round is scheduled.** Verdicts production accepts come only from `review_pull.py` run on
   the build box with the pinned key.
4. This branch is not merged.

**Merge order mattered** (the gate is on node-8 since 2026-11-12, so this hazard is past; and since the
QA round of `3840a4f43` a held letter delays the older ask by at most 24 h, it does not replace it).
This branch arms the hourly tick with `--ladder`. Once it is deployed, a
statutory request gets its first message from the ladder and the older ask stands down for it (that ask
tells people their name as on their ID is enough, which the 2026-11-12 ruling replaced). If this branch
reaches node-8 before the gate and a scheduled review round do, new statutory requests are authored,
held, and hear nothing until the gate arrives. The clock names every held one with the reason. Deploy it
behind the gate, or set `/etc/hydra/gdpr-dsar-ladder.disabled` until the gate is there (with the kill file
present nothing is authored and the older ask keeps running).

No hand copy to `/opt/hydra` was made. A hand copy of bytes that then change in review is exactly the
"server and repo both changed" state that is blocking the deploy now, and without the gate on node-8
every ladder message would hold anyway. After merge, the copy is safe (the deploy reads matching bytes as
a no-op).

## Since the first push (2026-11-12, 07:09Z to 10:15Z)

Everything above this heading describes the branch as first pushed (head `03d05174b`). Firstmate ruled on the
four open decisions at 07:09Z and QA reviewed that head. What changed, each with a test in
`tests/test_gdpr_dsar.py` (122 tests; 583 with `tests/test_gdpr_pipeline.py`):

**Firstmate's four rulings, as code**

| Ruling | What the code does |
|---|---|
| Lateness: "we are late, we are sorry, here is the date"; no excuse, no cause, no admission | The `late_*` variants say late and sorry once and give no reason. `dsar.lint` refuses a late update with no apology and an apology anywhere else. An answer date is stated only where code alone can produce the answer today (`run.answerable_now`); otherwise `late_none_no_date` states the next contact date |
| Extension only where genuinely needed, ground and new date stated, never to hide lateness | `extension_number` is owed only on a need recorded against the request with its ruling (`dsar extend`), where code cannot send the answer today, for 2 or more open statutory requests from one requester, nothing needed from them, date still ahead and inside 7 days. No need is recorded on any request, so none is owed. One further month. The date moves only when the notice is SENT. `extension_complexity` stays locked: no code can measure complexity |
| No refusal without recorded evidence; default comply | `denial` stays locked. Nothing selects it |
| Build the Art. 15 path | `scripts/gdpr_pipeline/access.py`, `policies/gdpr-access-sources.json`, `gdpr-pipeline.py access build|deliver`. See below |

**The Art. 15 copy: built by code, on real requests, and not sendable yet**

The first copy built by code was request #222 at 2026-11-12T08:05Z: 48 of 48 sources read on the read-only
replica, 156 rows from 17 sources, 19 columns withheld, 133,158 bytes, sha256 `07fb2e08...`. It was built in
memory on node-8, not recorded and not sent.

Run over all 28 open access requests (08:07Z, then 08:59Z for the 11 that needed the wide read):

| | |
|---|---|
| Copy built | 23 |
| Not built: account control not shown | 5 |
| All 48 sources read | 23 (after the wide-read fix; 12 before it) |
| Complete | **0** |
| Size | 41 KB to 25.5 MB; two are over the 18 MB a mail attachment takes |
| Time | about 2 minutes each |

No copy is complete, so no Art. 15 answer has been sent and **none can be until three gaps close**. Every copy
names them:

1. Nine systems that hold personal data are not read: Intercom, the support mailboxes, the payment processor, the
   sign-in provider, the marketing mail tool, in-app messaging, proof documents, tickets, analytics. That list was
   written from the repository, not from a data map, and is not verified to be all of them.
2. The Art. 15(1)(a) to (h) information (purposes, recipients, retention, rights) has no text. It is a legal
   statement, so code does not write it.
3. Nobody has read the included columns for other people's data (Art. 15(4)). The withheld list was written from
   column names.

Two defects found by the live run, fixed: values wider than the CSV reader's default limit dropped
`user_action_log` from 11 copies (`sources.trino_wide`), and a copy too large to attach is now held with that
reason instead of being posted to fail (`access.ATTACH_MAX_BYTES`).

**Found on the live register after the first push, fixed**

- 7 open erasure requests have a `sent` final confirmation in the send ledger and no `confirmed_at` on the row
  (#3, #6, #137, #140, #164, #204, #346). Each would have been told "we are late, and we are sorry" for an answer
  it already had. The final response is now read from the ledger too (`dsar.final_response_at`). The rows are
  not repaired.
- A request reached inside 3 days of its date was owed the late update before the date, saying "we are late"
  when we were not yet. It is now owed nothing until the date passes; the clock names it throughout.
- 64 late erasure requests needing nothing from the requester would each have been told an answer date 14 days
  out. Code can keep that date only where every named page is already hidden: 12 of the 139 late erasure
  requests were in that shape at 09:45Z, and 4 of those 12 turned out to be answered already (the item above).
  Every other one gets the update with the next contact date and no answer date.
- In a run where the ladder authored, a request the ladder was deliberately waiting on could still get the older
  identity ask ("your name as it appears on your ID"). It no longer does: that letter is never sent for a
  statutory request (first by leaving it off the list, `dsar.OLDER_ASK_RETIRED`; since the QA review of
  `7fb67dbd5` by a refusal of its words on the record, `dsar.ASK_WORDING_SUPERSEDED`, below).

**QA review of head `03d05174b` (4 findings, all accepted)**

1. The clock line named 12 requests and said "and N more". It now names every one: 183 of 183 on the live
   register at 10:15Z, in one line of 3,404 characters.
2. A held message was kept on variant and slot alone, so a moved date could be sent stale. `dsar.stale` now
   compares the dates the body states and the rendered wording.
3. The hourly tick arms `--ladder` while the gate is unmerged. On a host with no `gate.py` the ladder now holds
   itself and authors nothing, so the older ask keeps running exactly as today. Residual, stated plainly: with
   the gate installed and no review round running, messages are authored and held, the older ask is stood down,
   and those requests are carried only by the clock line.
4. Tier label and line added: tier 1.

**QA review of head `e80e37f34` (1 critical, 3 important, all accepted)**

1. Critical. The Art. 15 copy was sent to the sign-in address stored in the copy, which is up to 24 hours old.
   An account whose address changed after the build is the same account by id, so the identity check passed and
   the whole copy would have gone to the old address. The address is now read again at send
   (`sources.account_email`); one that differs from the copy's, or cannot be read, holds the copy until it is
   rebuilt. No copy had been sent: none is complete.
2. The copy gate adapter compared the subject hash only for a message with no subject, so a reworded subject
   line rode the verdict given for the old one. It now compares it always.
3. An extension notice was selected on a count of requests and nearness to the date. Neither shows that more
   time is necessary, and with `answerable` required it was selected only where the answer could go at once.
   It now needs a need recorded against the request with the ruling that found it (`dsar extend`), and is never
   selected where code can send the answer today.
4. The firstmate clock check is registered outside this repository, so this PR deploys no alarm to firstmate.
   Not fixable from here. What this PR does: the Slack due-date page, which deploys with the hourly tick and
   names no person, now covers statutory requests from the same 7 days out (it was 3). **Still open: register
   `scripts/gdpr-dsar-clock-check.sh` in the firstmate home after the deploy. Until then no line reaches
   firstmate.**

**Copy review round 4**: 21 of 21 enabled bodies approved (`copy-review-round4.json`), one rewrite of the
Art. 15 cover message adopted on the way. Same caveat as rounds 1 to 3: a throwaway key in a scratch mirror.
These show the wording passes the reviewer. They are not verdicts production accepts.

**Dry run 3** (08:59Z, whole live register in memory, before the last three fixes above): 309 open statutory,
171 messages owed (47 acknowledgements, 124 late updates), 0 extensions, 123 distinct bodies. Routes: Intercom
105, mail 9, **no route 57**. All 171 held: no gate on node-8.

**QA review of head `3840a4f43` (2 important, both accepted)**

1. *Carried forward: the clock check is not registered with firstmate, and a Slack page is not an alarm to
   firstmate.* Agreed, and still not fixable from this repository: registration is a file and a trust record in
   the firstmate home. What changed: the check can now be registered BEFORE the deploy (it says "not deployed"
   once a day until the clock is on the host), and its absence is no longer silent. Each read leaves a mark on
   the host (`dsar clock --line --read-by firstmate`); when requests are inside the window and the mark is more
   than 26 h old, the hourly tick pages "the alarm to firstmate is NOT running", once a day (`dsar.clock_unread`).
   That page says the alarm is missing. It is not the alarm. **Still open, firstmate's to do:**
   `install -m 0700 scripts/gdpr-dsar-clock-check.sh "$FM_HOME/state/gdpr-dsar-clock.check.sh"` then
   `"$FM_HOME/bin/fm-check-register.sh" gdpr-dsar-clock`.
2. *With the gate installed and a message waiting for review, `ladder_ran` stood the older ask down for every
   statutory request, so a new request could get no first contact at all.* Real. `ladder_ran` is gone. The older
   ask is now the bounded fallback (`dsar.older_ask`): it waits 24 h from the first authoring of a held ladder
   message and then goes on its existing approval path; it never goes once the ladder has sent, may have sent, or
   holds an approved message; and `send.deliver` reads the row again at send, so a batch listed earlier cannot put
   a second first message beside the ladder's. **Not closed:** the identity step is never sent for a statutory
   request, because its approved wording ("the name ... as it appears on your ID ... is enough") is no longer
   true under the 2026-11-12 ruling, and there is no other approved wording outside the ladder. Such a request
   still waits for a reviewed ladder message, on the clock. Live register, 2026-11-12T12:29Z: 25 open statutory
   requests carry that verdict and all 25 were asked before today, so none is waiting now; the dry run under this
   branch's identity rules decided 26.

**Firstmate's ruling on that review (2026-11-12T13:40Z): both are fixed in this PR, neither is deferred**

1. **The clock is installed by the deploy and registered with firstmate.** Three parts, and each was run:
   - *The unit.* `install-aux-units.sh` now writes `gdpr-dsar-clock.service` and `gdpr-dsar-clock.timer` (hourly at
     :07, `Persistent=true`, in `AUX_ONFAILURE_UNITS`). It runs `gdpr-pipeline.py dsar clock --watch`: the line to
     the journal, and a page when requests are named and firstmate has not read the clock for 26 h. It is its own
     timer, not a step of the tick: a tick has run 40 minutes and its timer stopped for 11 h on 2026-11-08, and a
     date must not wait on either. The read takes 0.14 s and no run lock. Rendered as the installer writes it,
     `systemd-analyze verify` passes; `scripts/tests/install-aux-units-gdpr-dsar-clock.bats` holds its shape.
     **It is not on node-8: that is the deploy of this PR, which is not this lane's to run.**
   - *The registration.* `scripts/gdpr-dsar-clock-check.sh` is registered in the firstmate home as
     `gdpr-dsar-clock` (14:05:03Z, trust sha256 `28db2eef...e59a29`, the file in this branch byte for byte). Undo:
     `bin/fm-check-unregister.sh gdpr-dsar-clock`. node-8 has no route into the firstmate box, so the read is a
     pull, one ssh round trip (0.65 s measured; the watcher allows 30 s). Trust binds the bytes: a change to the
     script needs the two commands again.
   - *The first line.* The registered script, run at 14:04:35Z against a copy of the live register (store sha
     `9fd1fc53...`, taken at 14:04Z, kept in a mode-700 scratch directory on node-8 and removed after), printed
     one line of 3,654 characters naming every request: **149 past their date, 34 due within 7 d, of 302 open;
     oldest #468, 1,013 d past; closed with no recorded response #13; no first message after 48 h: 33 named
     there and 134 of those already named above.** Run again the same day with the same set: silence. Against
     the default target, where this branch is not deployed, it prints "GDPR clock: not deployed on 40.160.32.80
     yet ..."; that is the line the registered check gives firstmate, once a day, until the deploy. The real
     register was not written: its sha is the same after, and the read mark went beside the copy.
2. **The older ask stands down only for a request the ladder has a letter for.** `dsar.ladder_letter(row, sends,
   msgs)` reads one request and nothing else; `dsar.older_ask` asks it. No letter for this request (the ladder
   owes it nothing, or is held or killed): the ask for a link or an authorisation goes exactly as before the
   ladder existed, whatever is waiting at the gate for other requests. A held letter (pending, refused, or the
   gate could not answer): the ask waits at most 24 h. A sent or approved letter: the ask never goes. The test
   for exactly the case in the finding is
   `test_a_request_with_no_owed_letter_gets_the_older_ask_unchanged_while_the_gate_holds_other_letters`: the ask
   dicts are identical before and after the ladder authors, under a pending verdict and under a refused one.
   **One line that is not "unchanged", and it is a ruling, not the gate:** the identity step (`ASK_IDENTITY`) is
   still never sent for a statutory request. Its approved text says a name "as it appears on your ID ... is
   enough"; the captain ruled on 2026-11-12 that a name match ties nobody to a page, and code no longer passes
   one, so the letter would promise what the next step refuses. Sending it is a decision above this lane. What
   this PR does instead: such a request cannot be quiet and unseen. After 48 h with no message from us it is in
   the clock line by number (`NO_FIRST_MESSAGE_HOURS`), and a test holds that.
3. **Every line this PR deletes that landed on main in the last 14 days is listed in `rebase-deletions.md`**, with
   what replaced it: 49 lines in 30 hunks at `7fb67dbd5`, 52 in 33 at the head after it (the four files the warning named, and two lines of `install-aux-units.sh`). Each is an intended
   replacement (the 2026-11-12 ruling, or the same line extended in place); one 9-line block in `run.py` moved
   byte for byte into `requester_of()`. Five commits from other lanes are touched and
   each one's behaviour is kept. The list is read from the diff and blame, not from a clean rebase.

**What the new alarm found on the live register:** 167 open statutory requests have had no message from us at
all 48 h or more after arriving. 134 of them are also past or near their date and were already named; 33 were in
no alarm until this change.

**QA review of head `7fb67dbd5` (2 important, carried again), and firstmate's ruling of 16:13Z: close both
literally**

1. *"The firstmate check still requires manual registration outside this repository."* It did: the last head
   documented two commands for somebody to type. Now the repository does it and can be asked about it.
   - `scripts/gdpr-dsar-clock-register.sh` installs the check into a firstmate home and binds it to its bytes
     with that home's own `fm-check-register.sh`; `--check` exits 0 only when the home has THESE bytes under a
     trust record that names them; `--unregister` retires it. It refuses to guess a home.
   - It was run for the firstmate home at 2026-11-12T16:51:14Z: `state/a0-gdpr-dsar-clock.check.sh`, sha256
     `e0db0829...2dbf7c`, the same sha as `scripts/gdpr-dsar-clock-check.sh` at this head. The earlier id
     (`gdpr-dsar-clock`, registered 14:05Z) was retired by the same run.
   - **Why the earlier registration never ran, and it was my error to leave it.** The watcher runs a home's
     checks in name order and ends the sweep at the first one with a line. At 57th of 94 the check was not run
     once in 2 h 46 min. I reported that at 14:55Z and declined to register it under a name that sorts first,
     on the ground that it would move the starvation onto other checks. That was wrong: this check prints once
     a day or when the set of requests it names changes, so it costs the others one sweep on those occasions
     and nothing otherwise. The id is now `a0-gdpr-dsar-clock`.
   - **The line firstmate received.** The watcher ran the registered check on its first sweep after that, at
     16:56:49Z, and the line is in firstmate's wake queue: "GDPR clock: not deployed on 40.160.32.80 yet, so no
     statutory date is being watched for firstmate. It starts when this repo's deploy lands there". That is the
     true line today: node-8 is on `8b9e7568a`, without the clock.
   - **The clock line itself.** The registered file (those bytes, from the firstmate state directory) was run at
     16:57:17Z against a copy of the live register in a scratch directory on node-8, 0.64 s: "GDPR clock: 151
     statutory request(s) past their date, 32 due within 7 d, of 302 open. Oldest first: #468 (1013 d past),
     ..." naming 183 requests, then #13, then 34 with no first message after 48 h (and 134 of those named
     above). A second run the same day printed nothing. The scratch directory is removed; the real register's
     sha (`feeb2824...`) and mtime are the same before and after, and no read mark was written beside it.
   - **What merge and deploy change, with no step by a person:** the same registered bytes stop answering "not
     deployed" and answer with the clock line. Nothing is typed anywhere.
   - **What no deploy of this repository can do, and what covers it.** The deploy runs on node-8, which has no
     route into a firstmate box, so a deploy cannot write to one. If the check changes in a later PR, the home
     keeps running the old bytes until the register script is run again. That is no longer silent: the check
     sends its own sha256 with every read, and `gdpr-dsar-clock.timer` pages within the hour, once a day,
     while the reading check is not the deployed one, exactly as it does when nobody reads at all. On the
     scratch copy: the registered bytes reading gives no page; the same read against a different deployed sha
     gives ":rotating_light: GDPR clock: the firstmate check reading the clock is not the one deployed".
2. *"The older ask falls back after 24 h for some verdicts."* The rule is now a table with one row per thing
   the gate can say about a request's letter, `dsar.OLDER_ASK_STANDS_DOWN`, and nothing else decides it: not
   the ask kind, not a run-wide flag.

   | the ladder's letter for this request | the older ask |
   |---|---|
   | sent, or may be out (`sending`, `unknown`) | stands down: it would be a second first message |
   | approved | stands down: the letter goes on this send |
   | pending | stands down for at most 24 h from first authoring, then proceeds |
   | refused | proceeds at once |
   | error (gate not installed, timed out, unreadable, unknown answer) | proceeds at once |
   | missing (authored, no gate answer on record) | proceeds at once |
   | no letter | proceeds, exactly as before the ladder existed |

   The last head waited 24 h on refused, error and missing as well, which is what "some verdicts" named: a
   refused letter is not coming, so there was nothing to wait for. One test per row (`OlderAsk`), one test that
   `ladder_letter` can return nothing outside the table and that every answer the gate can give is a key, and
   `test_each_gate_verdict_decides_the_older_ask_for_the_request_it_is_about` through the store.

   **What this does not give, said plainly.** QA's words were "`ASK_IDENTITY` is permanently retired; a new
   requester needing claim-or-authority verification still gets no first-contact message". The identity step
   is no longer left off the list: it follows the table like every ask. But its approved sentence says a name
   "as it appears on your ID ... is enough", which the captain's 2026-11-12 ruling made untrue, so it is
   refused for its words, on the record (`run.ask_refusal`, a `refused` row in `erasure_sends`), the way an
   ask for a class with no approved copy already is. For the requester the result is the same as before this
   head: that sentence does not reach them. Their first message is the ladder's reviewed
   `ack_claim_or_authority`, which says to claim the page or send a document from the label or management. A
   review round has run every 15 minutes on the reviewer host since the gate PR merged, so that letter gets its
   verdict within a quarter of an hour of the deploy. The case still without a message is one where that
   letter is refused or the gate cannot answer: then the request has a refusal on its trail and is named on the
   clock after 48 h.
   **Closing it is a ruling, not a fix:** the sentence is part of `copy.fingerprint()`, and changing it voids
   both standing rulings (`copy_sha 55648ce0...`), which stops every unattended erasure ask and confirmation
   until they are cut again. Named for firstmate in one line (Decisions, below).

684 tests pass (`tests.test_gdpr_pipeline`, `tests.test_gdpr_dsar`, `tests.test_gdpr_triage_bridge`), bats 24 of 24
on the three GDPR unit files. Nothing was sent and nothing was deployed.

## Proof of done: where it stands

| Asked for | State |
|---|---|
| Measured baseline | Done: `baseline.md` |
| Automated path for acknowledgement and status | Built, tested, reviewed. Not deployed |
| A real request handled end to end, with its message hash and verdict | **Not done.** Nothing has been sent. Four real requests' exact messages were approved by hash in a scratch mirror (Finding 4), under a key production does not accept |
| The clock | Below |

What stands between this branch and the first real send, in order: this PR merges and deploys (node-8 is on
`8b9e7568a`, without the ladder); a review round runs with the pinned reviewer key. The gate PR
https://github.com/Muso-AI/hydra/pull/1895 merged at 2026-11-12T10:42Z and `scripts/outbound_copy/gate.py` is on
node-8, so the merge-order hazard recorded earlier is gone: the ladder will deploy behind an installed gate.

## Decisions that are Aaron's

- **The Art. 15(1) information text.** Purposes, recipients, retention, rights. Without it no Art. 15 answer
  is complete. 13 access requests are past their date.
- **Which other systems are read for an Art. 15 copy, and who confirms the list is all of them.** Nine are
  named and unread.
- **Who reads the included columns for other people's data** before a copy leaves (Art. 15(4)).
- **Whether a ground exists to refuse anything** (Art. 12(4)). Nothing refuses. Default is comply.
- **New words for the identity step, with their ruling** (a reviewer ruling, not Aaron's, unless he wants it):
  replace `copy.IDENTITY_STEP` with the reviewed claim-or-authority wording and cut the two standing rulings
  again for the new `copy_sha`. Until then no statutory request is sent the identity step.

## Not built

- A store and a coded check for an authority document (gate 3). One that arrives is read by nobody in
  code; the request stays on the clock.
- A check that a DSP artist page or social handle the requester controls points at us (the other half of
  gate 2). Only the claim and the page's own website host are checked.
- A coded ask for a track or album page that does not pass through its artist: 15 requests stay
  `JAN_REVIEW`, need "not yet readable".
- A final response for an erasure whose page is already gone (`GONE`): no approved wording exists, so these get
  status updates and no answer date.
- A delivery route for an Art. 15 copy over 18 MB, and for the 57 requests with no route at all.
- The erasure confirmation and the older ask keep their existing approval path. The confirmation carries
  the requester's name and page links, so its bytes cannot be shown to a reviewer outside node-8.
- Nothing runs `access build` on a timer.

## The clock (2026-11-12T14:04Z, live register, this branch's code)

302 statutory requests open. **149 past their date** (136 erasure, 13 access). **34 more reach it within 7
days** (27 erasure, 7 access). Oldest open: #468, erasure, received 2024-01-04, due 2024-02-03, 1,013 days past;
its interim confirmation sits `unknown` in the send ledger since 2026-11-11 and needs the existing `resolve`
step. One request, #13, is closed in the register with no response recorded. **167 have had no message from us
48 h or more after arriving**; 33 of those are in neither of the first two counts.

The 10:15Z reading was 148 past and 35 within 7 days: one request crossed its date in between. The 03:56Z reading was 309 open, 150 past, 40 within 7 days. The difference is the 7 requests whose final
confirmation was in the ledger all along, plus time passing.
