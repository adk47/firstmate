# The coded proof review: "ask firstmate to review the proof" answered by code

Module: `scripts/ops_intake/proof_review.py` · tests: `scripts/tests/test_proof_review.py`
· fixtures: `scripts/tests/fixtures/proof_review/` · route policy: `policies/proof-review-route.json`

## Why this exists

jan-asks-intake-fable-j1's census (2026-10-21 → 11-04) counted **35 proof asks**, 23 of them
top-level, and **10 of the 23 top-level asks had no verdict in the thread**. Where a verdict
landed the median was **31 minutes, max 74**, and one case waited five days. Three different
things were called "Firstmate": the Ops agent judging the proof **inside its own model turn**
(four times, 4–11 min), the QA agent doing the same once, and firstmate hand-posting six coded
verdicts from `proof.sqlite` / `doc-verify.sqlite` on 11-04 18:48–18:49Z.

The first two violate the standing rule that credits are never judged in an OpenClaw agent
turn. The third is the right thing done by hand. This module is that hand, in code: one
verdict per credit request, one next step, one reply card, every time, in about a second.

Captain's ask (Jan, 2026-11-04 19:43Z, verbatim): *"tell firstmate to approved the credits if
its sufficient if not, then send a message to the user asking for more proof"*. The standing
rule stands on top of it: **nothing approves without a recorded captain decision, and UNKNOWN
never approves.**

After this change neither action in that sentence happens by code: approval waits on the
captain's approval route (`policies/proof-review-route.json`, `mode: off`) and the ask for more
proof waits on the stage-2 sender jobs, which stay disabled until their canary is verified.
What this change delivers is the coded verdict and the card it renders.

## What it answers

```
python3 scripts/ops_intake/proof_review.py review --conversation <intercom id> [--mode apply]
python3 scripts/ops_intake/proof_review.py review --request-ids <uuid,...> --user-id <id>
python3 scripts/ops_intake/proof_review.py board [--day YYYY-MM-DD]
```

`review` prints the card (and `--json` the evidence behind it). Dry run is the default: it
sends nothing and writes nothing. `--mode apply` takes the one coded next step and records the
card in `/var/lib/hydra-credit-verify/proof-review.sqlite`.

The fraud lens is measured by default (it needs the core replica); **a lens that fails to answer
holds every account on the ask**, and so does an account the lens simply left out of its answer:
an unmeasured account is never a cleared one. `--no-lens`
is for an offline review of a frozen fixture, where nothing is inferred from a lens nobody
measured. `--file` first files the conversation's attachments into H3
(`credit-proof.py file --apply`); it does not trigger doc-verify's read, which is a metered model
call under its own daily cap and its own cron — a brand-new document therefore reads UNKNOWN
(nothing asked, nothing approved) until that cron reaches it.

## The verdict, per credit request × role

Read from the judges that already ran — H3's `proof_intake` / `forensics` / `stage2_shadow`,
doc-verify's `dv_outcomes`, dsp-verify's `dsp_verdicts.anchor` — plus the fraud lens. Nothing
is re-judged here and no model is called; a document's text is data.

| # | verdict | when | what happens |
|---|---|---|---|
| 1 | **HOLD** | the fraud lens holds the account; a document on file is one *another account* already sent (H3 F2 hard, or an F2 "shared but the claimant is undetermined" signal); doc-verify read a document as forged; stage 2 recorded `reject_hold`, `review` or `human` | nothing to the user; the router persists the ask row **`held`** (never `answered`) and pages a person, who decides the hold |
| 2 | **DECLINE-RECOMMENDED** | a document *contradicts* the claim (doc-verify `contradicted`) | nothing to the user; the ask row is **`held`** and a named human is paged — a refusal is a person's decision |
| 3 | **SUFFICIENT** | every **claimed** role (the decider's own `decisions.claimed_roles`) is covered by a document of record **and** the request carries a same-run Spotify **and** Tidal anchor | nothing to the user; the ask stays **open** in the queue (`ask`, chased by the overdue-ask tick) waiting for a captain decision — see "the route" below |
| 4 | **SUFFICIENT-ON-MERITS, NO ROUTE** | every role covered, no DSP anchor (the 11-04 "El Güero" state) | same as 3: the ask stays `ask`, open and chased |
| 5 | **UVN-STATUS** | nothing readable on file, `no_document`, unreadable in two runs, or the only documents are screenshots of a catalog panel / DAW session | the approved uvn-status ask |
| 6 | **GAP-ASK** | the evidence is there and does not cover the claim (`need_more`, or `unverifiable` with a named need) | the approved gap ask |
| — | **UNKNOWN** | one unreadable read, no judge has looked, the claim was never recorded, only part of it has been judged, or a supporting read names a document that is not on file for the account | nothing asked, nothing approved, and the ask does NOT close: an all-UNKNOWN review leaves the ask row `ask` (open, chased by the overdue-ask tick) naming the uvn-status campaign — the "we could not read your document, please send a clear copy or a link" line, which is approved and unlocked today, so the single sender can put it on the wire as soon as `run()` is invoked in apply mode, subject only to its own population/placeholder/identity gates |

Per role a later doc-verify read may **promote** an unapproved role and never **demote** one
stage 2 already approved. The only downgrade a newer read can produce is
`unverifiable`/`unknown` ("we could not read it"), which is already a non-approval, so it buys
no safety — while it is customer-facing, because an unsupported role routes into the gap ask.
The real safety signals fire from their own arms whatever that rule returns: `forged` → HOLD,
`contradicted` → DECLINE-RECOMMENDED, `reject_hold`/`review`/`human` → HOLD. A document whose
extracted text carries an instruction pattern can neither approve nor deny a claim: its doc-verify
read counts as `unverifiable` and the hit is named in the why, and a stage-2 `approve` of a tainted
document supports nothing either — both judges read the same text, so tainted text is never why a
role is covered (`forged` stays a HOLD). A read that supports a role must name a document **on file**
for the account: the row records the proof id it read (stage 2's approved document, doc-verify's latest),
and a row citing an id that is on no filing in scope — or a screenshot, which is not a document of
record — covers nothing and is **UNKNOWN**, not SUFFICIENT. A judge row is not a document.
Stage 2's document and doc-verify's latest document are
kept apart, so a hit on the document stage 2 approved still reaches that approval when doc-verify
has since read a different one. The ledger is searched back to the
**oldest** filing of each document (one document per sha, however many conversations it appears in,
stamped with its earliest filing), and a document whose filing time cannot be read means no bound at
all — including when only one of its filings is undated: the stamp is then unknown, never the dated
duplicate's. The window is unknown, never the youngest readable age. A ledger that cannot be read is not
a quiet day: no document is evidence and every request holds.

**Completeness is measured against the claim, never against the rows a judge happened to write.**
The request's claimed roles are the decider's own `decisions.claimed_roles` (latest row per request);
stage 2 writes one row per claimed role and doc-verify reads the role it is given, so a request whose
`Producer` row was never written looks exactly like a request that claims `Composer` alone. A judged
role list that is shorter than the claim is a partial read: those requests are **UNKNOWN** (nothing
asked, nothing approved). A request the decider never decided has no recorded claim at all, which is
the same UNKNOWN — an unrecorded claim is never "every role covered".

The latest stage-2 row under the **current** `analyzer_version` is the read: stage 2's own load
filters on it, so a new analyzer version re-judges every request and a later row under a new
version — `approve` or `need_more` — can replace an earlier `reject_hold`/`review`/`human` and
clear that HOLD arm. No HOLD here is permanent against a re-read under a new analyzer version;
lifting a real hold is a human's decision, not a re-read's, which is why this module never
clears one itself — it only reads what the latest row says. The two judges' other signals
follow their own latest-read rules too: a later `verified` read of the same role clears an
earlier doc-verify `forged`, and a re-analysis under a new `analyzer_version` clears an H3
hard-F2 reuse row.

The deny/route half of the intent is satisfied: an insufficient proof always becomes a coded
ask and a sufficient proof never approves; the approval half is blocked on the captain's
approval route and this lane does not implement it.

Two boundaries worth knowing:

- H3's `document_kind` is a keyword count, so `distributor_portal` / `pro_portal` are **not**
  treated as screenshots (a real contract naming DistroKid three times reads that way —
  `docverify/gate.py`'s own warning). Only `catalog_page`, `dsp_for_artists` and `daw_session`
  are, which are the brief's three examples. A kind of `unknown` (most documents) says nothing.
- `unverifiable` with `need=distributor_dashboard_with_code` is the gate saying the document is
  not a document of record, but the need code does not carry the document's type, so today that
  reads **GAP-ASK** unless H3 recorded a screenshot kind. When doc-verify exposes the extracted
  `doc_type` on an outcome, tighten this rather than guess from a need code: a wrong UVN-STATUS
  tells a user who *did* send something that nothing is on file.
- A store that cannot be read is the same kind of unmeasured: every store read raises
  `ProofReviewError` (never an empty evidence set that reads as "nothing on file"), so the router
  answers `failed` and pages the lane instead of producing a verdict.

## The one coded next step

- **GAP-ASK / UVN-STATUS** → the single sender, `credit-review.py uvn-status --campaign
  gap-ask|uvn-status --from-stage2 --mode apply`, which owns the copy, the identity gate, the
  20-day idempotency, the fraud holds, the daily caps and the verify ledger. The review names
  the campaign and nothing else; it never builds a customer message. It restricts the sender to
  this account by naming it in `--only-users`, the sender's own positive narrowing, so the sender
  filters the population it reads at send time — a user who became eligible after the review's own
  read can never take the page ahead of the account that was asked. A send is reported only when the
  sender's `--outcomes-json` record names this account and no other; a record naming any other
  account is `sent: none` with that reason. If the sender refuses, the card says
  `sent: none (<the sender's reason>)` — no fallback message is ever improvised.
- **SUFFICIENT / SUFFICIENT-ON-MERITS** → **no customer message** beyond the existing on-file
  status; the review state is `waiting_route` and the router keeps the ask row **`ask`** — open and
  chased by the overdue-ask tick — because no decision was taken and closing it `answered` would
  retire the row the captain decision is owed on. There is **no proof-backed
  approval route in production** (2026-11-04 18:37Z: core answers `needs_human_review` even for
  Jan and Nick; the IDP validator alone approves). That route is a captain decision, not this
  lane's.
- **HOLD / DECLINE** → nothing to the user. A HOLD or a DECLINE anywhere in the ask
  stops every message for it (an account with a forensic hold is never sent an ask), and the
  router persists the ask row **`held`** with a page: un-holding a forged document or refusing a
  claim is a named human's decision, so the row must not read as `answered`.
- **UNKNOWN (every role)** → nothing asked and nothing approved yet, so the ask stays **open**:
  the review's state is `ask`, the campaign is `uvn-status`, and the router answers `ask` with a
  next step naming doc-verify's next read (or the stage-2 write) — the ask is never persisted
  `answered`. The customer line is the uvn-status "we could not read your document, please send a
  clear copy or a link": its copy lock is **open** (`UVN_STATUS_COPY_APPROVED=1` since 2026-10-29),
  so the one sender can put it on the wire as soon as `run()` is invoked in apply mode, subject only
  to the sender's own population / placeholder / identity gates. `gap-ask`'s copy lock
  (`GAP_ASK_COPY_APPROVED=0`) is the one still closed. A MIXED ask is unchanged: one campaign per
  run, gap-ask before uvn-status, and a HOLD or a DECLINE silences everything.
- **When the row closes** → an ask is `answered` only when the work it names was actually done. A
  review that chose a campaign (`ask` state, `gap-ask` or `uvn-status`) keeps the row **`ask`**
  while no send is recorded, because the router answers in `mode="dry-run"` and nothing has reached
  the customer: the next step names the sender invocation that is missing. The same review with the
  sender's record naming this account (`sent: <campaign>` on the card) is `answered`. This is the
  same rule as `waiting_route` and `held` above: closing a row is a claim that someone was asked or
  a person decided.

Also enforced by code: the kill switch `/etc/hydra/credit-verify.disabled` stops every send,
and **at most 3 cards per account per UTC day** so a burst of re-sends cannot page the lane
repeatedly.

**One ask, one account, one conversation.** The sender takes a single account and this lane
renders no verdict across two: an ask carrying more than one account is refused by `review()`
before any verdict, because the documents are loaded for the ask as a whole, so a filing belonging
to one account would read as on-file for another account's request. Nothing is decided, **no reply
card is rendered at all** (a card would repeat that pooling: one account hash over both accounts'
document shas), and `sent: none` is recorded with a gate reason saying a person must split the ask
and that an approved customer line is on file but the sender campaign that renders it does not
exist yet, so no message is sent. No campaign is ever printed as sent for accounts it did not
reach. `run()` also applies the `collision_owner` check itself, so the refusal does not depend on
which entry point called it. With no card to publish, the router states the refusal as the
answer's own evidence — `proof-review <ask id> · acct <hash> · refused: <gate reason> · sent: none`
— so an empty evidence never degrades the Slack reply to `contract-fallback` and staff still see
the account count and the split instruction. The router answers an ask that names more than one
Intercom conversation the same way (one conversation per ask), so the second conversation's proof
is never silently skipped.

**The customer line for that case is approved, and still locked.** The captain asked firstmate
for "We received documents from two different Muso accounts…"; the outbound copy gate ruled that
draft `rewrite` (rubric rules 1 and 2 — naming two accounts, and "so we can match it", hints at a
check and at suspicious activity) and **approved its own replacement** on 2026-11-14T10:31:53Z:
verdict `ocv-49139bdc4dfc3e75`, reviewer `mac-pool/claude-fable-5-1`, default rubric. The approved
bytes live in `scripts/intercom-verify-request.sh` as `SPLIT_ACCOUNT_COPY_BODY` /
`SPLIT_ACCOUNT_COPY_SUBJECT`, and `scripts/tests/test_split_account_copy.py` fails if either moves
by one byte — a verdict is bound to a hash, so an edit silently voids it. `SPLIT_ACCOUNT_COPY_APPROVED`
is **0**: the sender campaign that renders it does not exist yet (a follow-up lane adds the
campaign, its recipient rules and its dry run), so the refusal above still records the reason and
sends nothing rather than claiming a send it did not make. Splitting the ask by a person remains a
correct outcome in the meantime — it is what makes the approved line sendable at all.

## The route (`policies/proof-review-route.json`)

`approval_route.mode` is `off | log | on`, default `off`; **missing, unreadable or malformed
reads OFF**, because a broken policy file must never look like a lifted gate. `on` does not
approve anything either: this lane has no approval writer, so flipping the file changes nothing
until a reviewed PR adds one and records `approved_by` + `approval_ref` in
`policies/credit-approval-automation.json`. A sufficient proof review is evidence, not a
decision — the card never says "approved" unless a decision ledger row exists for the request.

## The reply card (the contract from j2)

```
proof-review <ask id> · acct <contact hash> · N requests: k sufficient / g gap-ask / u uvn-status / h hold / c contradicted · documents: <sha8>(<reuse flag>) … · sent: <campaign|none> (<gate reason>) · ledger <row> · sla <n>m
```

- No account names, no emails, no professional ids: the account is H3's contact hash, and the
  vocabulary is ids and counts (there is a test for it).
- `unknown` gets its own count only when it is non-zero — a silent zero would read as "the code
  looked and found nothing".
- `documents:` lists the sha8 of what is on file with the reuse flag that matters (the holding
  signal first) and `(screenshot)` / `(injection:<severity>)` where those apply.
- `sla` is minutes since the ask (pass `--asked-at`); over 30 the CLI also writes an escalation
  line to stderr. The lane must post inside 15 minutes.

## The first run on the backlog (acceptance)

`census-asks-1104.json` freezes the evidence for all twelve census §5 conversations plus one
real verified read, and pins what the precedence must produce. Where a human hand-posted a
verdict on 11-04, the fixture records **MATCHES** or **DIVERGES with the reason** — the
divergences are the interesting part:

- **215476642230886 — MATCHES** the human's HOLD: another account sent the filed document and
  it does not say whose it is.
- **215476632987122 — DIVERGES**: the human read it as "sufficient on the merits, no route";
  the stored evidence today has the role `unverifiable` with `need=distributor_dashboard_with_code`
  and no DSP anchor, so the code asks for the gap. If the human was right, the stored verdict is
  missing a verified read — check this first whenever the lane disagrees with a person.
- **215476490898367 — DIVERGES**: the human saw a "reused file"; no F2 reuse signal is recorded
  for that account today, so nothing holds it and the code asks for the gap.
- **215476629616641 / 215476495717959** — nothing is filed anywhere for these conversations, so
  the card says `unfiled` and names the filing step; a zero here would be a lie about what the
  filer has.

## What is live, and what is not

**Live:** the verdict and the card. `scripts/ops_intake/router.py` is the wired entry point — a
`proof-review` ask that carries exactly one Intercom conversation id is answered by
`proof_review.build_ask` + `proof_review.run(mode="dry-run")`, so the verdict and the card come
from code on every such ask, never from an agent turn. An ask naming several conversations stays
open with "split the ask" rather than answering from the first one.

**Not live:** sending from the router (the customer send stays on the `credit-review.py
uvn-status` / `intercom-verify-request.sh` path, gated by the single sender, the gap-ask /
uvn-status idempotency, the kill switch, the caps and the route policy), and approval (the
captain's route).

## What this lane does not build

- **The ask ledger** belongs to jan-asks-intake-router-j2; this module takes an ask id,
  a conversation id or request ids and stores its own ask rows and cards
  (`proof-review.sqlite`) so a re-run is idempotent and the board is readable.
- **Document auto-approval and verification** belong to docs-approve-t0t1-b2 and
  doc-verify-build-b1. This module reads their outcomes and never re-judges a document.
- **The approval writer.** A captain decision, and a reviewed PR.
- **The SLA pager.** Past 30 minutes the CLI says so on stderr; the intake lane (j-w1) owns the
  escalation.
