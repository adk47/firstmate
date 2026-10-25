# credit-trust-decide: trust-yet-verify on the held queue

Captain, 2026-10-15 ~22:12Z (verbatim): "i want AI live now - we have too many credits to approve and to
get supporting data for - let users know where there was a credit given and that it needs support (trust
yet verify approach)".

Wiring: Fable's `live-tonight.md`, Piece 1. Code: `scripts/credit_review/decide.py`, CLI
`scripts/credit-review.py decide|explain|export-decisions|revert`. Cron: `credit-trust-decide-15m`
(`*/15`, operations, command-shaped: exit code = run status), shipped `enabled: true` from the repo. Registered as `credit-trust-decide` in
`policies/credit-approval-automation.json`. Tests: `python3 scripts/tests/test_credit_trust_decide.py`.

## What one run does

Each run takes held (`unverified`) rows, **paying users first**, then the rest, oldest first within each
group: up to 500 rows, 120 web checks and about 12 minutes of evidence building.

**Paying users first.** The paying signal is the hourly read-only export another lane publishes on
node-8: `CREDIT_TRUST_PAYING_USERS_FILE` (default `/var/lib/credit-trust/paying-users.json`), shape
`{"generated_at": ISO-8601 UTC, "source", "definition", "count": int, "counts_by_basis": {...}, "ids":
[int core user id, ascending]}`. If the file is missing, unreadable, malformed (including
`count != len(ids)`), older than 3h or dated more than 5 min in the future, paying status is UNKNOWN: the run keeps
the plain oldest-first order and logs one line saying why. Paying status changes the **order only**, never
a decision (no paid shortcut to approval, no deny). Each decision row records `paid_priority`
(1 / 0 / NULL = unknown).

**Never re-ask** (captain standing order 2026-10-16: "make sure you arent asking for things from users
that already submitted documents and we approved. dont piss anyoen off"). A support request is the UVN
write that makes core-backend send Knock's "more info needed" notice, so every support decision is
filtered before it is written:

| Filter | Result |
|---|---|
| The user (or the request) has a document on file: approved, pending review, or approved by a human after documents. Read from the hourly proof-on-file export `CREDIT_TRUST_PROOF_ON_FILE` (default `/var/lib/credit-trust/proof-on-file.json`; `{generated_at, sources: [{name, generated_at, count, stale?, missing?}], users, entries: [{user_id, request_id or null, kind: approved_doc / pending_doc / human_approved_after_doc, source, ref}]}`). A user in ANY entry of ANY kind is covered. | **hold**: no write, reason `proof on file: human review` |
| The request already received a support write (or one that may have landed, `error:unverified:`) in any earlier run, per `decision_outcomes`. | **hold**: a credit is asked about once, ever |
| The user received a support write in the last 24h. | **defer**: one ask per user per window; the user's further rows go out together in the next window |
| The proof-on-file export is missing, unreadable, malformed, older than 3h or dated in the future, or flags any of its sources `missing` / `stale` (a proof only that source holds would be asked for again). | **defer** every support row, reason `proof_status_unknown`: no support request at all this run |

Rows a filter stopped are not rebuilt every 2h: a credit held as already asked is never re-decided (a
human looks), a proof-on-file hold is looked at again after 24h, and a row deferred for the per-user
window waits until that user's window ends, so ALL of the user's waiting rows come back in the same run
and go out as one batch. When proof status becomes unknown the run announces `PROOF-ON-FILE STATUS
UNKNOWN ...` ONCE, and `PROOF-ON-FILE status restored` once when it comes back (tracked in the ledger's
`state` table); the runs in between stay quiet, so a stopped producer is visible without a post every 15
minutes.

Provisional approvals are never affected by these filters, and proof on file is never itself a reason to
approve. The run line reports support rows before the filters, held for proof on file, held as already asked, deferred for the window, deferred for unknown
proof status (including documentation-required approvals, below), and sent.

| Outcome | When | Write |
|---|---|---|
| **Approve (provisional)** | All of the conditions in the list below hold. | `approved` (Knock's "approved" notice) |
| **Request support** | Everything decided against: big track (including a popularity the catalog does not carry), validator conflict, a trusted or verified-web contradiction (one-person roles flagged `n1`), red flags, NOT_FOUND, deny-listed user/profile, the editorial rules below. | `user_verification_needed` (Knock "more info needed"; the credit stays held) |
| **Defer** | The track is not ingested yet. Catalog or evidence is unreadable this run, including a track or a linked artist's profile that could not be read (a failed read never becomes a support request; a 404 is the exception after 3 deferred runs, below). A source fetch failed and nothing was fetched. The web check could not run (Codex down or capped and Jev did not answer; the paid fallback is off or over its cap). The web-check cap was hit. The user hit 200 approvals today. The never-re-ask per-user window, or unknown proof-on-file status. | none; retried after 2h |
| **Hold** | A validator `reject_*` rule fired (any `rule_risk_percent` key starting `reject_` with a number > 0; the reason names the rule): never approved and never asked by automation. It is checked on the request row before any evidence is read, so no evidence error or catalog 404 can turn such a row into a support request. A support request the never-re-ask filters stop: proof on file, or the credit was already asked about. An approval of a documentation-required row with no approved proof on file for that request. | none; a human looks |

A row is approved only if all of these hold:
- no validator `reject_*` rule fired (`policy.validator_rejected_rules`, the SAME predicate the approval
  auditor uses, so the two cannot drift);
- no validator conflict;
- not a big track;
- the user and the profile are not deny-listed (a missing, null or mistyped `deny_user_ids` /
  `deny_profile_ids` in `policies/credit-trust-decide.json` refuses the whole run);
- no red flags;
- ONE evidence kind:
  - all claimed roles trusted-confirmed (Spotify/Tidal/MLC/Jaxsta);
  - or a trusted footprint of ≥ 3 earlier trusted-confirmed claims in **each** claimed role family
    (a Producer footprint does not vouch for a Mix claim on the same request); a decider claim counts
    only once the server approved it in apply mode, never a shadow, deferred or server-skipped one;
  - or web CREDIBLE: Codex on server-fetched sources says APPROVE with ≥ 0.85 confidence,
    **verified quoted** citations on ≥ 2 independent domains (`WEB_CONFIRM_MIN_DOMAINS`), and no
    contradiction. MusicBrainz and Wikipedia are crowd-edited (a claimant can add themselves), so
    they only corroborate: a supporting set made only of them is not CREDIBLE;
- the user has fewer than 200 approvals today.

**Validator conflict** mirrors core-backend `agentApprovalGuard.validatorConflict`: any `review_*` ≥ 30,
`rule_errors._hold_on_error`, or track_credit ≥ 70 together with collaborations ≥ 90. The server refuses
agent approvals of these rows anyway; the decider never sends them.

**Big track** means catalog pop ≥ 60, a linked artist ≥ 90, or unknown popularity. A popularity that
was read but is not in the catalog counts as big (support request). A row that is big only because a
linked artist's profile could not be read this run is deferred and retried.

**A 404 is UNKNOWN, never "missing".** core-backend's `/admin/track/:id` and `/admin/profile/:id`
answer 404 whenever their own catalog (industry API) read returns nothing, which includes industry-API
timeouts and 5xx. So the decider re-reads a 404 once in the same run. If it is still 404 the row is
deferred (nothing is written to the server) with a reason starting `catalog_unreadable`. After 3 such
deferred runs for that request (counted from the `decisions` ledger, same mode) it goes to support with
reason `catalog_unreadable`, so a human checks the catalog. A row is never approved or denied on a 404. Only CONSECUTIVE 404 deferrals count: a later run that
reads the catalog and decides the row on any other basis resets the count. A run that did not read the
catalog (proof status unknown, the per-user window, another unreadable read) neither counts nor resets.

**Editorial roles are high risk** (captain 2026-10-15 ~23:42Z: "also some abusers of editorial roles - we
need this to be verified on high risk too"). A claimed role with a word starting with one of the
`editorial_role_terms` in `policies/credit-trust-decide.json` (edit, compil, assembl, pro tools: Editor,
Vocal Editing, Compilation, Pro Tools Editing ...; `roles.is_editorial`; `roles.family_of` still folds
them into `engineer` for the auditor) is approved only on trusted catalog confirmation on a track under pop 30, never on footprint
or web evidence; at pop ≥ 30 it gets a support request. Its profile's velocity counts double: 24h × 2
≥ 50 or 7d × 2 ≥ 150 is a support request. The reason is recorded on the decision row.

**Jev** is the evidence combiner when Codex is unavailable for a row that has fetched sources. It
never searches and never approves: its one typed answer can only turn the row into a support request
(the sources name someone else, or are silent) or leave it deferred for Codex.

**Never approved:** the PULL / HOLD / RE-VERIFY accounts, the retro HOLD users and the fleet-scan
profiles in `policies/credit-trust-decide.json`. There are **no named-user rules**: a high-risk case
(for example big-track claims a trusted source credits to someone else) is caught by the score - big
track, conflicts, red flags - exactly like anyone else; the tests use such claims only as anonymous
fixtures.

Adding an id there is always safe. Removing one needs Fable or a named admin.

**Documentation required.** Every support request except web NOT_FOUND (big track, validator
conflict, contradiction, red flags, editorial, deny-listed, catalog_unreadable) is recorded with
`doc_required = 1` on its `decisions` row, in apply mode only (a shadow run never marks a row). If the
decider later approves such a row it must rely on a proof: an `approved_doc` /
`human_approved_after_doc` entry for that request in the proof-on-file export. Its id (`<source>:<ref>`)
is written to the `proof_id` column of the decision row BEFORE the PUT, and the approval auditor reads it
from there (core-backend's `metadata.approval` carries no proof id). With no such proof in a known export the row is held,
never approved; while the export's status is unknown it is deferred (`proof_status_unknown`) and retried.

`uvn-under30-cron.py` approves UVN rows on popularity < 30 alone, so it reads the same policy file and
this ledger: its `qualifies_for_approval` refuses any row of these users and profiles, any editorial
role (the same `editorial_role_terms`), and any request id the decider marked `doc_required`. Its
ticket comment labels those rows `excluded: ...`. The cron fails closed (approves nothing) when the
policy file or the ledger's marker is unreadable. Without that, a row this decider moved to
`user_verification_needed` for documents could be approved by the under-30 lane after the user opened
a ticket.

## Safety layers (outermost first)

1. **Registry.** `decide --mode apply` re-reads the registry and runs as shadow, writing nothing,
   unless `credit-trust-decide` is `approved: true` with `approved_by` and `approval_ref`.
   `check-credit-approval-automation.sh` fails CI on an enabled, unregistered cron.
2. **Wrapper.** `muso-admin-api.sh` lets the decider approve only through its standing
   authorization, which requires all of these:
   - `CREDIT_TRUST_DECIDE=1` and requester `credit-trust-decide@hydra-ops`. Exactly those calls also
     carry `X-Credit-Automation-Id: credit-trust-decide`. core-backend (T12, core #10595) binds that
     grant to the decider's own account `agent-credit-decider@muso.ai` (identity `credit-decider`),
     not `agent-hydra-main@`; `Requester` is still sent until T12 removes that alias;
   - `PUT /admin/credit-requests/conditional-status`, `expectedStatus: unverified`;
   - ≤ 50 unique UUIDs;
   - the registry entry, re-checked at the write boundary.

   Any near miss falls back to the normal evidence gate.

   **Own admin identity.** The decider sets `MUSO_ADMIN_IDENTITY=credit-decider` in its own process
   (uvn-under30 sets `uvn-cron`). The wrapper then logs in with that identity's credentials from
   `/etc/openclaw/agents/<identity>.env` (provisioned from Vault by H-DevOps #4131; `MUSO_ADMIN_EMAIL=` / `MUSO_ADMIN_PASSWORD=`
   lines; parsed, never sourced) with a token cache of its own. `credit-decider` is
   `agent-credit-decider@muso.ai` (core user 1407251) and `uvn-cron` is `agent-uvn-cron@muso.ai`
   (1407252): core-backend binds each automation's grant to its own account, and
   `agent-hydra-main@` holds neither (firstmate 012, decision A1 on core-backend #10594; contract
   H-DevOps #4131). There is no fallback to the shared gateway credentials: an unknown identity or a
   missing or incomplete file fails before any request.

   **Deploy order.** Hydra deploys this only after core-backend #10595 (live since 2026-10-17 02:22Z)
   and the credit-automation role rows for both accounts exist, and after both identity files are on
   node-8. Until then both automations write nothing.

## Money

**Codex is $0.** The paid OpenRouter fallback is **off** by default (`--paid-fallback` enables it), and
`decide --provider openrouter` is refused: the metered judge runs only as that capped fallback.

Measured 2026-10-15 on 60 real held rows: the free sources covered none of them, and the grok fallback
cost **$1.86 for one approval**. 55 of the rows got the same support request they get without it.

When enabled, the fallback is hard-capped by `decide.CappedJudge`, the single owner of these caps: per
run (`--budget-usd`, $2) and by the captain's shared **$25/day** verifier budget (`--daily-budget-usd`). The daily count covers the credit-review audit's
spend plus every decide run that day. Over the cap a row defers; it never gets a support request.

## Shadow numbers, node-8, 2026-10-15 22:48Z

200 oldest held rows, $0:
- **6 provisional approvals**, all catalog-confirmed;
- **156 support requests**:
  - 120 NOT_FOUND: no free source covers these obscure tracks, so there was nothing to cite;
  - 21 Muso-only identity on an established release;
  - 13 validator conflicts;
  - 2 big tracks;
- 38 deferred: web-check cap.

Codex was never needed, because no row had a fetched source. **Approval coverage on this queue will stay
low until a general search engine exists that does not captcha node-8.** That means either a SearXNG
deploy or a Brave API key (`docs/credit-verification/credit-trust-llm.md`).

## Operating it

```bash
python3 /opt/hydra/scripts/credit-review.py decide --mode shadow --max-rows 100    # dry run, records decisions only
python3 /opt/hydra/scripts/credit-review.py explain <credit-request-id>             # every decision + server outcome
python3 /opt/hydra/scripts/credit-review.py export-decisions --since 2026-10-15T00:00:00Z > decisions.jsonl
python3 /opt/hydra/scripts/credit-review.py revert --run <run-id>            # list a run's provisional approvals
python3 /opt/hydra/scripts/credit-review.py revert --run <run-id> --apply    # attempt approved -> unverified
```

**About `revert`.** The only legal backward transition is `approved → unverified`, and core-backend lets
only a **named human** take an approved credit back (firstmate decision 023, `requireRemovalAuthority`).
From the agent token, `revert --apply` is therefore refused per profile, and that is reported. The id
list is what a human (Jan, Nick, Aaron) takes back in the admin UI.

**Live Spotify + Tidal rule (captain 2026-10-23, firstmate 104/105/106).** `approved → unverified`
hides the credit, and nothing is hidden or removed on Muso until a live check in the same run shows,
on BOTH Spotify and Tidal (every Tidal country agreeing; UNKNOWN never counts), that the track can't
be played or the person's credit in that role family is gone. That check is core-backend's removal
gate (#10765/#10767), not live yet, so `revert --apply` now refuses with `live_dsp_gate_required`
before any write (`scripts/credit_review/dsp_gate.py`). The listing (`revert --run` without `--apply`)
is unchanged. The credits stay visible, held for Ops.

**Kill switches.**
- `/etc/hydra/credit-trust-decide.disabled`: nothing is decided.
- `/etc/hydra/credit-review.disabled`: stops this and the audit.
- `approved: false` in the registry: the wrapper refuses every approval.
- cron `enabled: false` **in a repo PR**. `deploy.sh` re-syncs the live cron file from `cron-jobs.json`
  on every deploy, so a live toggle is reverted by the next deploy; use the kill-switch file for an
  immediate stop.

## Owned elsewhere

This change (T01) is the Codex ladder and the trust-yet-verify decider. These parts of the captain's
ask are owned by other tickets:
- the daily Ops-channel Slack message on high-risk rows to review: T09 (daily digest);
- email and Intercom channels for credit verification documents and proof: T06 / E-IN (support relies
  on the existing Knock UVN notice until then);
- removing the 403 blocks on credit requests and deletes: T04;
- deletes that must prove removal from Spotify/Tidal or a different same-name profile, and fixing past
  approvals (retro execution, the HTML report): T05 / retro.

**Daily ask cap.** At most `max_ask_users_per_day` distinct users (policy file; 100 for the first 48h of go-live, firstmate 031) get a support request per UTC day, counting users already asked that day. A user admitted under the cap gets all of their rows in that run as one batch; the rest are deferred with reason `daily ask cap:` and go out on a later day. The cap is re-checked under the shared credit-write lock immediately before each support batch, on the UTC day that batch is sent (after the approval writes); outcomes are booked at the time the PUT returned, so a request in flight across midnight counts on the later day, so overlapping runs or a run crossing midnight cannot exceed it (rows trimmed there get outcome `deferred:daily_ask_cap`, or `deferred:per_user_window` when another run asked that user meanwhile).

**Server approval guard mirror (T12).** core-backend refuses an agent approval of a validator-declined row unless the row is inside the automation's scope, judged on the row as the server stores it (`spotifyPopularity`, `metadata`, `verificationData`). `credit_review.policy.server_approval_refusal` (decider, scope not-big-no-hold) and `server_band_a_refusal` (uvn-under30, scope band A) mirror that rule, so neither automation sends an approval the server will refuse:
- a stored popularity of 0 is unattributed, not big: the row goes to a human, never a proof ask (firstmate 036);
- a stored popularity >= 60, unknown, client-sourced metadata or a server proof requirement (validator hold, risk 100, band hint not A, high/critical profile risk, a `proofRequest` marker) gets a support request;
- anything else the server would refuse is held for a human.
If the server still answers `agent_cannot_approve_declined`, it wrote nothing: the decider records the refused rows as `skipped:agent_cannot_approve_declined:<reasons>` and sends the rest of the batch once more; uvn-under30 clears its unresolved-attempt blocker and leaves the rows held.


**Support@ contacts are never asked (firstmate 041).** Every user in the export's top-level `gmail_contacts_90d` (a list, or `{generated_at, source, user_ids}`) emailed support@ in the last 90 days: their support rows are held for a human, never asked, even when no document was found. A missing or malformed list makes proof status UNKNOWN, so nobody is asked.

**One proof-on-file rule.** The decider reads the export through `credit_review.proof_parts`, the same completeness rule as the verify notes, the take-back gate and Caroline's support tool (pinned by `scripts/tests/fixtures/proof-parts-contract.json`, which the decider now answers too): `core`, `cs-intercom` and `cs-gmail` must all be present, unflagged and fresh by their own stamps, no other part may be flagged, entries must be well-formed and `users` consistent; anything else is UNKNOWN and no proof request is sent. The decider is stricter on top, never looser: integer user ids only, and a readable `gmail_contacts_90d` list (its users are held, never asked).


**Credit backlog rulings (Fable, data/captain-calls-fable-d5/credit-backlog-1019.md; firstmate 072).**
- Order (ruling 6): every run sorts PAID with rows older than 24h, then PAID within 24h, then FREE, oldest-created first inside each (`order_rows`); decisions are re-sorted the same way before the ask cap, so the cap admits paid users first.
- Ask cap (ruling 1): 400 distinct users per UTC day (`max_ask_users_per_day`), with the existing invariants: one batched ask per user per day, never a user with a document on file or a support@ contact, never re-ask.
- Paid provisional approval (ruling 4): a PAID user's small/medium row whose web check is NOT_FOUND (so no contradiction, no red flag, no validator conflict, no editorial rule, not big) is approved with `evidence_kind = provisional_paid` instead of asked; the verify note then tells the user the credit is live and asks for a document, with no threat and no date. **Never auto-removed** (amendment, firstmate 073; captain rule 10-15: a delete must confirm removal at Spotify/Tidal or prove a different profile, no new lowering classes): after 30 days without a document the row goes to the Ops review list (`credit-review.py provisional-review`), still live; any later removal follows the normal proof rule with notice and reason. At most 20 per user per UTC day. Free users stay on the ask path; big tracks stay strict; core's T12 mirror and the documentation-required rule still apply after it.
