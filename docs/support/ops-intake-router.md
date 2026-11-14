# ops-intake: the `operations` Slack account's ask router

Status: **live on main, writes disabled by config** (`OPS_INTAKE_WRITES` is unset).
Owner: firstmate lane `jan-asks-intake-router-j2` (extends `cs-systemic-c3` and the
#1702 action-audit ledger work). Related lanes: `jan-asks-watch-w1` (the overdue
escalation tick), `jan-proof-review-coded-p1`, `jan-summarize-resolve-s1`.

## Why this exists

The 14-day census (`jan-asks-intake-fable-j1`, 2026-10-21 → 2026-11-04) measured
what the Ops bot actually did with Jan's asks:

| fact | number |
|---|---|
| asks addressed to the Ops bot (Jan) | **301** |
| replies saying "queued for FirstMate" | **≥ 24**, behind no queue at all |
| credit verdicts written by the Ops/QA agent's own model turn, labelled "Firstmate" | 4 |
| profile hides via `DELETE /admin/profile` | **21 ids / 15 replies** (all 404 afterwards) |
| profile merges, self-approved via the tier-2 god-mode allowlist | **≈ 39** |
| ClickUp writes | **134** |
| credit-request rejections in one agent write | **420** |
| writes with a recorded inverse | **0** |

So: a free-form agent turn with root exec answered staff asks, judged credits it
was not allowed to judge, performed irreversible writes on request text, and told
the asker it had queued work that did not exist. A prompt cannot fix that; the
model is the thing being constrained. Hence a plugin hook plus a coded router.

## The flow

```
Slack (operations account)
   │  inbound_claim  ← plugins/ops-intake (account + channel filter, no bot/echo)
   ▼
router.py claim  ── classify (regex table) + write the ask row ──► claimed?
   │ yes (class != other, or quarantined)                    │ no  → agent turn (class `other`)
   ▼
router.py intake  (detached child; off the gateway's inbound path)
   1 identity   event.user → policies/ops-requesters.json   (text is NEVER identity)
   2 classify   scripts/ops_intake/classes.py (10 classes, first match wins)
   3 ids        scripts/ops_intake/ids.py (full uuids typed by keyword; truncated ≠ write handle)
   4 W2 gate    any irreversible action named anywhere → refuse the WHOLE ask + page
   4b imperson.  a STAFF name quoted by a non-staff sender → refuse + page
   5 quarantine HIGH injection hit on a message the agent would see → quarantined + page
   6 row        ops_asks insert (idempotent on channel+ts), due_at = ts + 30 min
   7 conflict   requester-linked half of the fraud lens (profiles AND requests)
                → refuse + page; an UNMEASURED link refuses too
   8 answer     the coded answerer for the class (no model, no agent)
   9 write      tier → full fraud lens → burst caps → ledger plan → execute → applied
  10 reply      the row's state is recorded FIRST, then one contract line is posted IN
                THE ASKER'S THREAD; a post failure keeps the row and pages
```

A message that carries no stable Slack `ts` cannot become an ask row: `(channel, ts)`
is the register's idempotency key, and a constant would fold every such message into
one row and answer the second asker with the first ask's reply. It is still CLAIMED
(so no agent turn sees it), answered with the `no-ask-row` fail-closed line, and
paged once per day.

Files: `plugins/ops-intake/` (the hook), `scripts/ops_intake/` (every decision),
`policies/ops-requesters.json` (who), `policies/ops-intake-actions.json` (what,
caps, lens, quarantine, reply contract).

## The ten classes and what answers them

| class | answerer | notes |
|---|---|---|
| `proof-review` | `_proof_review_answer` when the ask carries an Intercom conversation id, else `answer_proof_review` | with exactly one conversation: the coded review (`scripts/ops_intake/proof_review.py`, dry run) renders the card and verdict — see `docs/credit-verification/proof-review-coded.md`. With several conversations, or several accounts on one ask (a review is one conversation and one account): the ask stays `ask` with the split instruction, and the refusal states itself as the answer's own evidence since no card is rendered. Without a conversation: verdict from coded `dv_outcomes` ONLY; no verdict = `open` with a due time |
| `summarize-resolve` | `answer_summarize_resolve` | a facts card from code reads plus a LOOKUP in `policies/ops-resolutions.json`; executes nothing (returns a `WriteRequest`) — see `docs/support/ops-summarize-resolve.md` |
| `gdpr-hide` | `answer_gdpr_hide` | only the reversible HIDDEN_ENTITY_IDS PR, only on a register-hide-eligible page |
| `clickup-categorize` | `answer_clickup` | counts from code; status moves are W1 |
| `status-report` | `answer_status_report` | measured counts or "no coded count" |
| `fraud-scan` | `answer_fraud_scan` | reports the lens band; removal is W2 |
| `billing` | `answer_billing` | trace only; a refund is W2 |
| `profile-edit` | `answer_profile_edit` | rename is W1: the plan records the new display name the ask names verbatim, and the previous name as its inverse |
| `relay` | `answer_relay` | the ask row IS the queue; `due_at` names when the watcher escalates |
| `other` | the agent turn | the ONLY class an agent sees, and only if not quarantined |

`python3 -m unittest -v tests.test_ops_intake` pins the classifier at ≥ 95 %
agreement with the 269-row census fixture, with the residual pinned by name.

## Tiers

* **R** — read-only answers. Every staff id, and every unknown id: an unknown id
  gets a coded answer to a read-only ask, and every write is refused. A read-only
  ask that **names a profile or request** is refused when the conflict-of-interest
  check cannot be measured (an unknown id has no Slack email, so it cannot be
  shown to be someone other than the account owner) — unmeasured never passes.
* **W1** — reversible write with a recorded inverse: Intercom internal note,
  answer-bank customer reply, ClickUp status move, profile rename, request → UVN,
  register row, hide-PR open. Granted to `U038BM16T7W` (Jan), `U0AL36NADEY`
  (Nick), `U7RP6HKUZ` (Aaron) — and to nobody else.
* **W2** — irreversible / not-yet-invertible: `DELETE /admin/profile`, a merge
  without an unmerge manifest, credit approve, credit removal, refund, account
  delete. **Granted to nobody, including the captain.** The reply names the human
  path (`scripts/credit-retro.py`, `scripts/gdpr-pipeline.py`, a named human
  session, a captain decision).

Burst caps, counted from the action ledger: **20 W1 writes / requester / hour**
and **3 writes / target profile / day**; over a cap the ask is `held` and paged.

## What is (and is not) switched on

* **On:** intake, classification, coded answers, the conflict-of-interest check,
  quarantine, pages, the digest, the daily red-team replay — on `main`. This is not
  a claim that the router intercepts on node-8: measured on 2026-11-12 it claimed
  nothing (`ops_asks` 0 rows, against Jan's 7 asks of 2026-11-11) and `ops-intake`
  was absent from the gateway's plugin list. The measurement, its limits and the
  unmerged fix branch are in `data/jan-intercom-5-answers-j1/report.md` §3.
* **Off by config:** W1 execution. Without `OPS_INTAKE_WRITES=1` a W1 write is
  recorded as a ledger plan (with its inverse) and marked `no writer wired for
  <action>`; the reply says so and names the ledger row. Turning it on is a
  captain decision, after a live day of reading the plans.
* **Off by config:** the optional summary model call (`OPS_INTAKE_MODEL=1`). The
  coded summary needs no model at all.

### What the coded answerers can read today

`scripts/ops_intake/sources.py` wires the two coded reads that exist:

* **`dv_outcomes`** (`/var/lib/hydra-credit-verify/doc-verify.sqlite`) for
  proof-review; the newest row per request id, and `MIXED` only when two
  DIFFERENT requests land on different verdicts (history is not a disagreement).
  This is the fallback answerer; an ask carrying an Intercom conversation id goes
  to the coded proof review, which additionally reads H3, the DSP anchor and the
  fraud lens (`docs/credit-verification/proof-review-coded.md`).
* **Intercom conversation parts** for the summary (`credit_verify/proof/intercom.py`).

**Not wired yet, on purpose:** ClickUp counts and the status-report counts. A
fabricated count is exactly the census failure ("1,860-ticket Waiting list, 73
relevant", never reconciled), so those classes answer `open` with a due time and
the watcher escalates until a coded producer is chosen. The same applies to any
W1 writer: see §"Enabling W1 execution".

## Failure modes (all fail closed)

| failure | behaviour |
|---|---|
| policy file missing/unparseable | router exits 3, plugin claims the message + posts "no action taken", agent turn stays out |
| plugin cannot reach the router (crash/timeout) | claim + `router-unavailable` reply in the thread + a detached `page-unavailable` child that pages #clio_devops once per 30-minute outage window; no agent turn |
| fraud lens cannot measure (Trino/proof store/register down) | **refuse** — "unknown" is never "clean" |
| a `fraud-scan` ask that names no full id (only a truncated prefix, or none) | `ask` naming the missing id — no page, so the watcher escalates it; only a lens that was actually attempted and failed pages |
| an id the lens cannot query (not a uuid, 8-hex prefix or Intercom id) | dropped and reported as unmeasured, so the lens refuses instead of reading as clean |
| HIGH injection hit in fetched text | `quarantined` (one screen, rule names in the verdict), the model never sees it, page |
| canary token in a model output | `failed`, page (the call needed no retry: it is a prompt-frame breach) |
| burst cap | `held` + page |
| fraud-lens HOLD (held/watch band, or a reused-document H3 F2 signal) | `held`/`refused` + page — the strongest fraud evidence always reaches the on-call |
| a hide ask whose target page the lens did not measure | the lens is built from exactly the ids a hide could act on (typed profile ids, else the untagged ones, plus request ids), so this cannot arise; an untagged id is measured but never written |
| a hide ask whose uuid is not typed as a profile id | `ask` — no write and no ledger row; the requester is asked to name it as a profile |
| requester-linked account | `refused` (W2) + page |
| requester link UNMEASURED (Trino down, no Slack email, no resolvable owner) | `refused` + page — on reads and writes alike |
| staff name quoted by a non-staff sender | `refused` + page; forwarded instructions are not actions |
| message with no Slack `ts` | claimed, so no agent turn sees it, but no row can be written; the plugin posts the `no-ask-row` fail-closed line and spawns a detached `page` child that pages once per day. The claim path stays network-free |
| the reply post fails (rate limit, missing token, channel gone) | the answer is already recorded: retried once, then the row keeps its state and `reply-post-failed:<error>` in `note`, plus a page. A Slack retry of that message re-attempts the post; on success `reply_ts` is recorded and only that marker is removed from `note` |
| a W1 write whose inverse could not be executed | `refused` before the plan (missing inverse params). A write that HAPPENED but returned no deferred handle records `result=applied`, `undo_state=unavailable` (so it still counts against the burst caps and `revert()` says why it cannot run) + page |
| one of several named pages has no register row | `UNKNOWN` → `ask`/`refuse`; a registered neighbour never carries the rest |
| register rows that disagree about the same page | the MOST RESTRICTIVE verdict wins, folded with `gdpr_pipeline.identity.ROW_ORDER` (the register's own order, not alphabetical); a verdict outside that order, or any `UNKNOWN` among them, is `UNKNOWN` → `ask`/`refuse` |
| a Slack retry while the first `intake` child is still running | the retry RESUMES it: no second answerer run, no second contract line, no second ledger row. The lease is a row in `ops_intake_lease` (primary key `ask_id`, **2 min**, renewed before the coded answerer and before the write step) acquired with ONE conditional insert, so two children can never both win it; a child whose renewal fails has been superseded and stops before the answerer/write/reply; past the lease a dead child's lease is taken over and the retry re-runs the pipeline |
| a `profile-edit` ask that names no new display name | `ask` — nothing planned; the register stores only a hash of the body, so a rename whose target value was never captured has no faithful plan. The name is the text after the FIRST "to" (else "as") that follows the rename phrase, on that line or the next (so an id on its own line still works), a quote that STARTS the name position is taken verbatim (an embedded quote is refused); otherwise the name is the rest of that line after the first "to"/"as", cut at a uuid/`profile`/`reason`/`because`/colon, with a trailing politeness word removed. A lowercase " for "/" to " connector, a colon, a newline or more than six words is `None` (ask, never a wrong name), so "Born To Die" and "Waiting For The Sun" are captured whole while "John Smith for GDPR" is refused; an UNQUOTED name carrying a trailing instruction joined by a lowercase connector (" and ", " then ", " also ", " plus ", " so ", " but ") or a comma followed by a word is `None` too, so "change profile name to Franki Love and update the user" asks for the exact name instead of recording "Franki Love and update the user" (the quoted form still captures "Simon and Garfunkel"); a result that is empty, multi-line, colon-bearing, longer than 6 words or starts with a determiner is `None` (ask, never a wrong name). A name that would trip the reply guards is still recorded in the ledger, just not printed |
| class `other` (the agent turn's) | `claim()` records the row `open` with `verdict_source=agent-handoff` (only while it is still open/ask, so a re-delivered event never reopens a closed row) — a hand-off is not an answer, and the digest does not count it as agent-handled. The watcher closes it (`answered`, `verdict_source=agent`) only when the bot actually posted in the thread — a contract line for a DIFFERENT ask does not count — and escalates + pages when it did not (or when the thread cannot be read) |

## Reply contract

```
<class> · <ask_id> · <verdict or state> · <evidence ids> · <next coded step> · <ledger row id>
```

Every user-derived fragment (a profile display name, Intercom text, a ClickUp
title) is mrkdwn-escaped at that one boundary, so `<!channel>` or
`<https://evil|label>` in user text renders as characters and never as a ping or
a link; the code-owned fields (class, ask id, state, ledger row) are untouched.
The same helper runs at the PAGE boundary (`router._page`, the no-ts page, the
watcher's escalation page), so a quoted staff header or a lens reason cannot
inject a live mention into #clio_devops either. A lens `page` flag is turned into
a message by `answer.page_for_lens`; `Answer.page` refuses anything but a string.

`answer.render()` **refuses** to produce a line that would claim something the row
cannot support: "queued"/"pending" without a due time and a ledger row, any credit
judgement whose `verdict_source` is not coded, any "Firstmate" attribution without
a ruling file, any unmeasured claim ("credits remain intact", "profile-only hide",
"refunded"), or no evidence field at all. On refusal the router posts
`render_minimal` (`state: contract-fallback`) and pages.

## Operations

* Register: `/var/lib/hydra/ops-intake/asks.sqlite` (`OPS_INTAKE_DB` overrides).
  States: `open, answered, held, quarantined, refused, ask, escalated, failed`.
* Action ledger: `/var/lib/hydra/ops-intake/actions.sqlite` (the #1702 row shape:
  action, target, params, inverse, undo state). A ledger row is written BEFORE the
  write; `revert()` executes the RECORDED inverse and nothing else. A transient
  inverse failure keeps `result=applied`/`undo_state=available` and bumps
  `undo_attempts`, so the inverse stays retryable. An inverse that
  could not run is never recorded: `plan()` refuses an incomplete inverse, a rename
  refuses without the profile's previous display name, and a hide records the PR
  number the write returned before the row is marked applied.
* `python3 scripts/ops_intake/router.py digest` — today's counts by class/state.
* `python3 scripts/ops_intake/watcher.py digest --post` — posts the daily line to
  #clio_devops (`ops-intake-digest.timer`, 07:00 UTC), including `orphaned-plans`:
  ledger plans older than an hour with no applied/failed result, i.e. a write that
  may have run without a marked plan. The escalation tick reports the same list.
* `python3 scripts/ops_intake/watcher.py overdue [--post]` — escalates open asks
  past `due_at`. Without `--post` it is an INSPECTION: it prints the backlog and
  changes nothing, so reading the queue never consumes it. The reported `overdue`
  count is the true backlog; class-`other` rows it will not escalate without the
  thread check are listed separately as `handoffs_awaiting_agent`. With `--post`
  it first reads each class-`other` thread (`conversations.replies`) and closes
  the ones the agent actually answered; a hand-off is never escalated without
  that check, and a row only moves to `escalated` when the page was delivered.
  **Scheduling belongs to `jan-asks-watch-w1`**; the digest reports
  `open-past-due` so an unowned tick cannot hide.
* `python3 scripts/ops_intake/redteam.py --quiet` — replay the corpus (CI + the
  `ops-intake-redteam.timer`, 06:40 UTC, which pages on any failing case or a
  lower pass count than yesterday).
* `bash scripts/check-ops-intake-policy.sh` — the policy guard. It runs in CI
  (`scripts/tests/check-ops-intake-policy.bats`); it is NOT wired into
  `scripts/deploy.sh`, so run it by hand before merging a policy edit.
* The plugin needs **no shell**: it spawns the router as a child process; the
  `operations` agent's `full` exec posture is not extended for this work.

## Enabling W1 execution (captain decision)

1. Read a live day of `actions.sqlite` rows: the action, the target, the inverse.
2. Wire the adapter(s) in `scripts/ops_intake/router.py::_production_writers` —
   one per action, each returning the data its inverse needs. That function is
   called only when `OPS_INTAKE_WRITES=1`; the reads, the reply and the page are
   wired either way.
3. Set `OPS_INTAKE_WRITES=1` in the gateway's env file for `main`.
4. Watch the first day at +15 min / +1 h / +6 h, then confirm the 7-day invariant:
   zero credit judgements inside an Ops/QA agent turn.

## Why each guard is load-bearing (do not "simplify" these)

* **Envelope identity.** A message beginning `*Jan Delmo* [12:09 AM]` was seen on
  2026-11-02; any name-scraping resolver would have attributed a forged hide to Jan.
  A non-staff sender quoting a staff name is refused outright, not answered.
* **W2 before any read.** "refund it and add a note" must not get the note.
* **One ts, one row.** A repeated `(channel, ts)` is a Slack retry; a shared
  constant would be two different asks answered with one reply. The pair is a
  UNIQUE index on `ops_asks`, so two concurrent claims cannot both create a row
  (an older database is migrated by keeping the oldest row per pair).
* **Unmeasured refuses.** A hide was executed while the register said UNKNOWN.
* **Ledger before write.** #1702 exists because 14 days of writes left no inverse.
* **Contract renderer.** The three false sentences in the census were all produced
  by an agent composing prose; the reply must be assembled from measured fields.
