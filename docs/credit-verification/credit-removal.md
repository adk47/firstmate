# Credit removal: two intents, one executor, no humans in the loop

> Captain, 2026-11-04: "credit removal — a Fable plan that works for users and Caroline, without
> humans involved". The app modal asks two things: *this is me, hide it* and *this isn't me*. This
> document is **H1** of that plan (`data/credit-removal-flow-fable-r2/report.md` §4–§7): the hydra
> side — Caroline's intake and the drainer that executes both intents.

Code: `scripts/clickup_drain/credit_removal.py` (ClickUp side), `scripts/credit_review/removal_executor.py`
(the two intents, the core writes, the ledger), `scripts/credit_review/proof_verifications.py`
(`credit_proof_verifications` + Codex proof grading). Tests:
`scripts/tests/test_credit_removal.py`, `scripts/tests/test_credit_removal_redteam.py`. Registry entry:
`policies/credit-approval-automation.json` → `credit-removal-executor` (`approved: false` on merge).

## The one model

| the customer chose | what it means | what runs | who decides |
|---|---|---|---|
| **this is me, hide it** (`hide_mine`) | their own credit, off their own profile | the served-visibility hide (core C1) | nobody: the profile owner's right, no verification, no catalog delete |
| **this isn't me** (`not_me`) | a credit on a profile names the wrong person | a removal claim on the core removal gate (core C2), which hides it at once | the deterministic public-credit rule (Spotify + Tidal live reads), and Codex only to grade a proof the gate asks for |

Both intents come through ONE ticket kind (`credit-removal`, `details.intent`), ONE executor, ONE
ledger, and ONE set of outcome tags. A removal asked in Caroline's chat is identical to a removal
asked in the app: same request, same gate, same record.

**What this automation may never do.** It decides no removal and calls no catalog delete. There is no
code path in it to `removeSongCredits`, to an admin credit PUT or to a credit-approval route; the
`not_me` intent files a claim on the gate and reports the gate's own state, and `hide_mine` writes a
served-visibility marker only.

## Identity comes from the account, never from the message

A ticket body is text a stranger controls: it may name a profile, a track, an intent, and may even
say "approve this". None of that is identity. The account is resolved from the ticket's Intercom
conversation contact (`external_id`) through `credit_review.identity_resolver` (r5: professional id,
Auth0 subject, a **processed** claim's profile, or the representation profile — nothing else), and the
ticket's own profile link is only a *candidate*:

* exactly one account must own that external id (0 or 2+ ⇒ `identity_unlinked`);
* that account must OWN the candidate profile (`identity_resolver.owns`: its own
  `neptuneprofessionalid`, a processed non-deleted claim, or its representation profile). Both intents
  are performed on the customer's own profile, so the account's own professional id counts as owned;
  a profile the account merely names is not its own, and an id two accounts own is not either.

An `identity_unlinked` ticket writes nothing: no hide, no claim, no tag beyond `needs-customer`, and
the customer's words go into the digest for a human.

**A read that did not complete is never `identity_unlinked`.** `identity_resolver` unpacks fixed-width
replica rows, so a malformed row raises `ValueError`; a Trino timeout raises too. `identity_unlinked`
is a DURABLE `needs-customer` tag that `why_excluded` honours on every later run, so answering it from
a broken read would park a valid ticket forever, even after the replica recovers. Both the lookup and
the ownership read therefore raise `RunError` (which stops the run and tags nothing); only a
*completed* read may say "not linked".

## The executor's ladder (any failure stops the row, none is skipped)

1. **Deliberate non-automation** — `--apply` needs the registry entry `approved: true` *with* an
   `approved_by` and an `approval_ref`, AND `/etc/hydra/credit-removal-executor.live`. Absent either,
   the run decides and reports and writes nothing. The cron ships dry-run and `enabled: false`.
2. **Identity linked** — see above. Never inferred from text.
3. **Intent and track** — `details.intent` ∈ {`hide_mine`, `not_me`}; each track must be one of the
   profile's OWN credits (by id or an exact title match). An ambiguous or absent match is
   `track_unresolved`, never a guess. The tracks are read from `details.track_ids[]`, then
   `details.track_urls[]`, then `details.track_titles[]` — never from the customer's prose, so a
   title that lives only in `customer_verbatim_request` is a ticket that names no track and it parks
   for a human. Both skills that file this kind must populate `track_titles[]` when a title is all the
   customer gave.
4. **Idempotency** — the ledger's latest state for `(ticket, profile, track, intent)` decides. A
   `hide` or a gate `removed` is `no_change` on the next run. A *filed claim* is not done: every run
   READS it (`removal_request`, a GET) and adopts the gate's own state, and a row that already has a
   claim on file is never re-filed — only a row with no claim on file ever POSTs, and that check is
   re-read under the write lock so two overlapping runs cannot both file one. A row that was attempted
   before (a POST whose response was lost) has the gate READ first, and an existing claim is adopted
   instead of filing a second one. `proof_required`,
   `checking` and `kept` are recorded as row state for exactly that reason. A claim an operator
   WITHDREW is never re-filed: the reverted ticket is a human's, and the row reports `needs_customer`
   without calling core at all. Only claim-bearing outcomes count as the claim's state, so a
   read/write failure (`refused`, `authority_unavailable`, `authority_refused`) never erases a claim
   that is on file.
5. **The write, under the shared credit-write lock** — then a **read-back**. For `hide_mine` the
   profile's credits must come back with the track hidden (a missing `hidden` field is NOT proof of a
   hide; a credit that is ABSENT from the list is not shown, so it is a success). For `not_me` the gate
   request must come back with a state. **The credits read is a PAGE WALK, never one page.**
   `/admin/profile/:id/credits` is page-based (it ignores `offset` and echoes page 1 back), so a
   single-page read is not a harmless truncation: a credit on page 2+ looks ABSENT, and absent is
   exactly how this module reads "not shown", so a hide that did not take would read back as a
   success. A walk that cannot finish is a read that did not answer, never a short list — the same
   rule governs track resolution, where a short list would report a track the customer really holds
   as `track_unresolved`, a DURABLE `needs-customer` tag. **A 200 is not a credits list**: a body
   with no recognized envelope (`data`/`items`/`results`/`credits`) carries no list at all, so it says
   nothing about the track and must never be read as "the profile has no credits". A write whose
   read-back **answered and disagreed** is `partial`, which is never reported as done and never
   closed. A read-back that never answered (5xx, an unrecognizable 200, or the wrapper could not make
   the call) is `transient` instead: it says nothing about the write, so it tags nothing and the next
   run retries — a transient failure must never park a customer ticket. A busy lock is `lock_busy`:
   nothing was written, so it tags nothing and the next run retries.

A **dry run** probes the route with a read-only GET, so while C1/C2 are absent every row reports
`authority_unavailable` (with the HTTP status) instead of pretending a write would land. It still
writes nothing: no POST, no ledger line, no tag, no proof row.

| server answer | disposition | `customer-outcome` |
|---|---|---|
| 2xx + read-back agrees (`hide_mine`) | `hide` | `complete` |
| 2xx + gate state `removed` | `removed` | `complete` |
| 2xx + gate state `checking` | `gate_filed` | none (the ticket stays in the queue) |
| 2xx + gate state `listed` | `proof_required` | one internal ask for proof, ticket stays |
| 2xx + gate state `kept` | `kept` | `needs-customer` (the fixed resolve note says "all sorted" — it must not carry that) |
| 404/405 | `authority_unavailable` | `blocked` (C1/C2 is not deployed here) |
| 401/403 | `authority_refused` | `blocked` |
| other 4xx | `refused` (the server's words) | `blocked` |
| 5xx, or the wrapper could not make the call (status 0) | `transient` | none (a transient failure says nothing about the request; the next run retries) |
| 2xx + read-back answered and disagrees | `partial` | `partial`, never closed |
| 2xx + read-back never answered (5xx / status 0) | `transient` | none (the write landed; the next run re-reads it) |
| the credit-write lock is busy | `lock_busy` | none (nothing was written; the next run retries) |
| a proof is on file but the proof route is absent | `proof_awaiting_gate` | none (the proof is graded and waiting; the ask is not repeated) |

A ticket gets ONE tag, from the worst row it has, and **an in-flight row outranks every terminal tag**
(`needs-customer`, `partial` and the refusals included). A two-track `not_me` ticket with one track
`kept` and the other still `gate_filed` is therefore left untagged: any tag is durable, `why_excluded`
would skip the ticket on every later run, and the in-flight claim's result would never be read or
delivered. The in-flight row is retried next run and the digest still names it; the tag lands once
every row is final. `proof_required` is the one exception to "in flight means no tag": it produces the
internal ask and still leaves the ticket on the board.

## Proof follow-ups

The gate asks for a proof when the public sources still list the claimant. A proof LINK the customer
sends is recorded in `credit_proof_verifications`
(`/var/lib/hydra/credit-review/proof-verifications.sqlite3`, append-only; a second attempt appends a
new row) and graded **deterministic first**. A given link is graded ONCE per profile, track, link and
prompt hash: the same evidence reuses the stored verdict instead of appending a duplicate row or
making a second model call, while two profiles of the same person keep their own rows. There is no
document/screenshot lane: URL proofs only.

**Where the link is read from.** A proof the customer sends AFTER the ticket is filed never reaches
the ticket's description: `create_ticket` dedupes a same-conversation, same-kind follow-up onto the
open ticket and posts `buildFollowupComment`, which carries its own
`---ACTION-REQUEST-UPDATE---` block in a ClickUp COMMENT. The drainer therefore reads the ticket's
comments on every run (dry run included, because a dry run must decide on the same facts) and takes
`details.proof_urls[]` from every update block, oldest first, deduped and capped at 5. **The links
ACCUMULATE across updates; a later comment never replaces an earlier one's.** A customer who sends
link A and then link B before the next drain has sent two proofs, and keeping only the newest would
silently drop A: if B is unreadable and A shows the right person, A is the one that settles the claim.
Only `proof_urls` is taken: the intent and the tracks stay the ones the ticket was filed with, because
the intent is the customer's ONE choice and a later comment must never be able to flip a `not_me`
claim into a hide. A comment read that fails, or a malformed block, is ignored rather than fatal, so
one unreadable comment cannot stop the run.

1. the link's host class comes from `policies/proof-link-hosts.json` (`credit_verify.proof.links`). A
   shortener, a Muso page, or an unlisted host is never fetched and can never be evidence:
   `unreadable`.
2. an allowlisted outside source is fetched through the same audited, SSRF-safe transport (bounded,
   pinned to a checked public address). The text is used only as input to the grading prompt; the row
   stores the link, the verdict, and the model's verbatim quoted passage — never the page.
3. **Codex on node-8** (`credit_trust.llm.Provider`, a tool-less call through
   `scripts/lib/codex-judge-exec.sh`; the metered OpenRouter rung is the same shared ladder every other
   credit judgement uses) answers `SUPPORTS | CONTRADICTS | UNREADABLE` plus the passage it read. A
   verdict with no quoted passage is `UNREADABLE`, because a page that simply does not list the
   claimant would otherwise read as "different person". A model failure is `pending` — reported, never
   acted on, never cached as a grade, and never sent to the gate as evidence. So is a proof whose
   claimant name could not be read: with no baseline name to compare against, any page would read as
   "different person", so the row is `pending` ("claimant name unreadable") and the next run retries.
4. the graded proof is **POSTed to the gate's own proof route**
   (`POST /admin/profile/:pid/credits/removal-requests/:request_id/proofs`) as evidence on the
   EXISTING claim, under the shared credit-write lock, once per (request, link, grade identity): the
   row records `submitted_at`/`submitted_run_id`, and a submission is skipped when the same evidence
   was already POSTed for that request — so a retried run never submits the same evidence twice, even
   when the row is re-appended (an unfetchable link is not cached), while a re-graded link is new
   evidence and is submitted. **The skip is scoped to the request the evidence went to**: a cached
   grade carries the `request_id` it was POSTed against, and a row submitted to a DIFFERENT request is
   submitted again, because that request may have been withdrawn and the new one has no evidence yet.
   The submission then MOVES the row to the new request (the store holds one request per proof row,
   and the gate allows one live claim per profile and track), so the next run has nothing left to
   send. The claim is never re-filed. A `409` means the
   claim no longer takes evidence: the gate's returned state is adopted and no further proof is sent
   for it. A `404` means the route is not deployed yet: nothing is written, the row reports
   `proof_awaiting_gate` ("proof received, graded X, awaiting gate"), and the internal ask for proof
   is NOT repeated while the proof waits on the gate. Once the gate answers `listed` again, the ask
   is decided per TICKET from the rows that actually need a proof (`disposition: proof_required`; a
   row that is not asking never influences it): it is suppressed only when EVERY such row's proof is
   graded `different` (it names the right person, so the gate has what it needs for all of them); any
   `same` or `unreadable` verdict asks again, and the ask is worded as a RETRY when any of them is
   `unreadable` (the link on file could not be read, so one more is needed). The graded proof is evidence,
   never an approval: the gate decides, and nothing here removes a credit.

The page is fenced in the prompt and named as untrusted data: a page telling the model what to answer
is evidence about the page, never about the claim.

## Every write is revertible

`/var/lib/hydra/credit-removal/ledger.jsonl` is append-only and fsync'd. Each write is three lines: a
`reserved` intent (so a crash mid-call is visible), an `accepted` line the instant core answers 2xx
(before the read-back, so an accepted write is never invisible to the cap or to a revert), and the
outcome line. Both the accepted and the outcome line carry the **inverse**:

* `hide_mine` → `{"action": "unhide", profile_id, track_id}`
* `not_me` → `{"action": "withdraw", profile_id, request_id}` (undoing a filed claim is withdrawing it;
  the hide the gate applied belongs to the gate)

An inverse is recorded **only on a line for a write this run performed**. A run that merely ADOPTED a
claim another run filed — and possibly POSTed a proof onto it — records `{"action": "none"}`, because
`--revert <run_id>` undoes this run's writes and never another run's: recording a withdraw there would
let reverting a proof-only run drop the customer's removal request that the first run filed. The proof
POST has no inverse of its own (the gate keeps the evidence).

A run's id is unique per run, not per second. The drainer names its rows file
`rows-<UTC stamp>-<6 hex>.json` and hands that same name to the executor as its `run_id`, so a manual
`--ticket` run beside the hourly cron in the same second can neither overwrite the other's batch
before the executor opens it nor share an id that one `--revert` would undo for both. The executor's
own default (the second-resolution timestamp) is only reached by a caller that passes no `run_id`.

`scripts/clickup_drain/credit_removal.py --revert <run_id>` replays ONE inverse per row, decided from
that row's NEWEST record in the run (a `partial` write and an `accepted` line with no outcome line are
writes too, so they are revertible). A row whose newest record is already `reverted`/`withdrawn` is
skipped, so re-running `--revert <run_id>` does nothing — including after the customer deliberately
re-hid the credit in a later run. What a revert leaves behind differs by intent: a reverted
`hide_mine` row may be hidden again by a later run (the customer's own choice), while a reverted
`not_me` claim is a human's — the automation never re-files a claim an operator withdrew, and the row
reports `needs_customer`. A `revert_failed` line is not final: the next `--revert <run_id>`
falls through to the write it could not undo and retries it. Every undo is read back, the
`reverted`/`withdrawn`/`revert_failed` lines are appended, the run's proof rows are marked
`reverted_by`, and the affected tickets are untagged so they are a human's again. A revert is a write:
it needs the same registry approval and live flag.

**A revert takes the SAME shared credit-write lock the forward write takes, and holds it across the
ledger read, every undo and the ticket untag.** Without that, a concurrent apply run can read the
credit as hidden, decide `no_change`, and tag the ticket `complete` while the revert is un-hiding it:
the credit is visible again and the ticket says done. The untag is a callback the executor invokes
inside that critical section for exactly this reason, so the ticket transition cannot be interleaved.
A revert that cannot take the lock writes nothing and reports `stopped` with the lock reason.

**The forward direction needs the same treatment, and it is the drainer that owns it.** The executor
releases the lock when it finishes a row, so a drainer that tagged the ticket afterwards would leave
exactly the gap above, just mirrored: apply hides the credit, a revert lands in the gap and unhides
and untags, and apply then re-tags and resolves `complete` with the credit visible again. So
`credit_removal.run()` holds the shared credit-write lock across the executor call AND the tag/ask/
close loop, passing a pass-through to the executor so the nested acquisition cannot deadlock the run
against itself. The two directions now serialize on one lock and whichever arrives second sees the
other's result. A run that cannot take the lock tags nothing and reports `stopped`.

**A claim this automation filed stays revertible even when its POST's response was lost.** A
`reserved` line is written the instant before the POST. If the response is lost (a timeout, a 5xx),
the run records `transient` and no acknowledgement, so the ledger cannot say whether the claim landed
— but a live claim on the gate is exactly what a landed POST looks like. When a later run adopts that
claim and the ledger has our `reserved` line with no acknowledgement, it records the `withdraw`
inverse, because the alternative is a claim this automation filed that no `--revert` can ever
withdraw. A claim with no `reserved` line of ours (a human's, or another system's) stays inverse-free,
and so does a claim another run already acknowledged — that run's own line carries the inverse.

**Only an UNANSWERED POST can make a live claim ours, and the answer that counts is the one to the
ATTEMPT, never the row's newest line.** The last `reserved` line is the write attempt and the line
after it is that attempt's answer. A `refused` or `authority_*` answer means core answered and did
*not* file our claim, so a live claim on the gate is somebody else's and must stay inverse-free. The
unanswered answers are `transient` (no answer at all), nothing at all (the run died between the
reservation and the answer), and `accepted` **with no request id** — a 2xx whose body did not name the
request is an acknowledgement we could not name, so if the run stopped before the read-back supplied
the id, the claim is ours and no `--revert` could withdraw it. An `accepted` line that DOES carry an id
already has the withdraw inverse on it, so the adopting run must not claim it.

**Reading the newest line instead would lose the claim for good.** A run that adopts the claim and
cannot name it yet records `gate_filed` with no id; if that line were read as the answer, the next run
would see a definite answer, record `none`, and the claim would stay live with no `--revert` able to
withdraw it. So ownership survives every recovery line until an id is bound.

**The inverse is bound to the run that FILED the claim, not to the run that read the id back.**
`--revert <run_id>` undoes a run's writes, and the claim is the filing run's write. When a later run
supplies the id, it appends a line under the FILING run's id repeating that run's own answer with the
withdraw inverse attached, so `--revert <the run that filed it>` replays the undo. The line repeats an
outcome the row already had, so the row's state does not change, and it is written once per row.

**The adopting run's own line records `none`, and that is the point.** It read the claim and may have
sent proof, but it did not file the claim, so `--revert <the adopting run>` must undo nothing. Giving
it the withdraw inverse would let reverting a read-only run drop the filing run's live claim and
reopen a ticket nobody asked to reopen.

**A 2xx on an undo is an acknowledgement, not proof.** Core can accept an unhide or a withdraw and not
apply it, and recording `reverted` then would reopen the ticket while the credit is still hidden (or
the claim still active) — the customer is told nothing and the row is never looked at again. So an
`unhide` is confirmed by reading the profile's credits back (paged) and finding the track not hidden
or absent, and a `withdraw` by reading the gate request back and finding it gone (404) or in a
terminal state. A read that disagrees, or never answers, stays `revert_failed` and is retried; that is
safe because re-issuing an undo is a no-op (unhiding an unhidden credit, withdrawing a withdrawn
claim).

## Caroline

`workspaces/support/skills/verification-handoff/SKILL.md` carries the one approved question and the
two intents; `workspaces/support/skills/action-request/SKILL.md` carries the ticket contract.
`credit-removal` is now an action type in both `ticket-format.ts` copies (tier 1, agent lane,
`handoff:credit-status`), and `resolve-notify.py` / `overdue-verification-notifier.py` allowlist it, so
a `complete` ticket gets the approved note and its conversation is closed.

Her authority is unchanged: she asks, files, and hands off. She never says "hidden", "removed" or
"done", and she never picks the intent for the customer.

## What is not built here (and what the drainer does until it is)

C1 (`profile_credit_hides` + the hide route) and C2 (the removal gate on the user path) live in
core-backend (`#10765` / `#10767` are still open). The executor calls the routes through
`WrapperCore` at `HIDE_PATH` / `REMOVAL_PATH` — the agent-facing twins of C1's
`POST/DELETE /v4/workspace/:ws/profile/:pid/credits/hide` and C2's `intent=not_me` claim. Until those
routes answer, every row is `authority_unavailable`: the run reports it, the ticket is tagged
`blocked` on an apply run, and **nothing is written and nothing is claimed to be done**. There is no
fallback to the legacy deletion path. The removal notices (N1) are a separate copy-pack PR; until they
land, `kept` deliberately goes to a human rather than wearing the fixed "all sorted" note.
