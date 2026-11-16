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

**Documented requests already in `user_verification_needed`** (`hold_documented_uvn`, 2026-11-13). The run
lists `status=unverified` only, and stage 2 (`credit-proof.py stage2`) takes its work only from this ledger's
`proof on file` holds, so a document filed against a request that was already in `user_verification_needed` was
never handed to stage 2. After its normal pass the run reads that status from the replica in one query
(`UVN_REPLICA_SQL`; the admin list refuses that many pages) and records `hold`, `proof on file: human review`,
for each request a document on file covers whose newest decider row is none, an ask or a deferral
(`UVN_TAKE_DECISIONS`). Whole users at a time, paying first, `max_documented_uvn_users_per_run` users a run
(10; 0 turns it off). It writes ledger rows only: no core write, no ask, no approval and no model call in any
mode, and the rows are counted in the run line's own sentence, never as decided rows. A request with no
document on file is not read; a request whose newest row is any other kind is left to that row's reader. A
failed read is reported as `NOT READ`, never as zero, and a row-shaped replica line that does not parse is
counted on the run line (`uvn_rejected`, carried by `UvnRows`) rather than dropped: the counts it reports
cover only the lines that parsed. Measurements: `data/send-families-zero-sends-r1/report.md`.

| Outcome | When | Write |
|---|---|---|
| **Approve (provisional)** | All of the conditions in the list below hold. | `approved` (Knock's "approved" notice) |
| **Approve per role (`approve_partial`)** | The request claims several roles and a trusted source - or a dv-4 verified document's own per-role verdicts - proves some of them but not all. The proven roles are approved, every other claimed role is PENDING with its own proof need. See "Per-role decisions" below. | **none yet** - the write half is `credit-per-role-write-c1` (core-backend); apply mode records the split and refuses the write |
| **Request support** | Everything decided against: big track (including a popularity the catalog does not carry), validator conflict, a trusted or verified-web contradiction (one-person roles flagged `n1`), red flags, NOT_FOUND, deny-listed user/profile, the editorial rules below. | `user_verification_needed` (Knock "more info needed"; the credit stays held) |
| **Defer** | The track is not ingested yet. Catalog or evidence is unreadable this run, including a track or a linked artist's profile that could not be read (a failed read never becomes a support request; a 404 is the exception after 3 deferred runs, below). A source fetch failed and nothing was fetched. The web check could not run (Codex down or capped and Jev did not answer; the paid fallback is off or over its cap). The web-check cap was hit. The user hit 200 approvals today. The never-re-ask per-user window, or unknown proof-on-file status. | none; retried after 2h |
| **Hold** | A validator `reject_*` rule fired (any `rule_risk_percent` key starting `reject_` with a number > 0; the reason names the rule): never approved and never asked by automation. It is checked on the request row before any evidence is read, so no evidence error or catalog 404 can turn such a row into a support request. A support request the never-re-ask filters stop: proof on file, or the credit was already asked about. An approval of a documentation-required row with no approved proof on file for that request. | none; a human looks |

### Per-role decisions (R90 / ruling 149 `[key=anchor-granularity]`)

A request with several claimed roles used to be decided ALL-OR-NOTHING: `Evidence.all_confirmed` is
`all(r.status == CONFIRMED for r in roles)`, so one unproven role blocked every role. A manager who is
provably the Composer and merely unproven as Co-Writer got nothing approved and heard nothing back.

The decision is now per role, and it is the DEFAULT path - not a branch beside the all-or-nothing one:

- **approved** = the claimed roles a trusted source credits THIS profile in (`RoleEvidence.status` is
  `CONFIRMED`), plus the claimed roles a dv-4 verified document's own per-role verdicts prove.
- **pending** = every other claimed role, each with a `pending_proof_need` string saying what would prove
  it. **A role is never rejected for absence of proof** - pending is pending, forever.
- pending empty -> today's `approve` (same reason, same write). approved empty -> today's `support` /
  `defer` (nothing to approve). Both non-empty -> `approve_partial`, with `doc_required=False` for the
  approved roles and one proof need per pending role.

**The whole-request guards run FIRST and still decide the whole request.** A contradiction in ANY role
(`ev.any_contradicted`), the editorial-role documentation rule, `one_person`, red flags, a big track, an
unreadable catalog or a 404 all return before the split, so a partial can never be a way past one of
them. A contradicted role is evidence the CLAIM is wrong, not merely unproven: it blocks the whole
request and `approved_roles` stays empty.

**A document on file that contradicts or flags a role blocks the whole request too.** The dv-4 per-role
verdicts are the second contradiction source (`doc_approve.blocked_role_verdicts`): when any claimed
role's standing verdict is `contradicted` or `forged`, the row is decided `support` with a reason naming
the role and the verdict, before the paid provisional arm and before the split, and the document path
skips it. `verified` does not block, and neither does `unverifiable` nor `unknown` - those are the
statuses that may pend.

**The web check runs before the split too.** `pre_model` never returns a partial: a request with some
roles confirmed and some not falls through to the web check, so a web contradiction on ANY role still
blocks the whole request. Only a NOT_FOUND web verdict leaves a split to decide.

**The whole-request arms run before the split, so they keep what they take.** The paid provisional arm
(`trust yet verify`) and the footprint path approve the WHOLE request and name every claimed role as
approved; a row that qualifies for one of them is never downgraded to a partial - with ONE exception: a
document on file that proves only SOME of the claimed roles (below).

**A partial support document is the split's other source.** A dv-4 document whose own per-role verdicts
prove SOME of the claimed roles approves those and holds the rest pending; one that proves every claimed
role is the whole-request document approval. A document that proves none of the claimed roles leaves the
row to the guard that already decided it. `unverifiable` and `unknown` are the statuses that may pend -
"we could not check it" is neither good nor bad, and `unknown` is what the store writes when the dv-4
tooling itself failed, so a provider outage must not cost the user the roles the document DID prove. A
role the document CONTRADICTS, or one flagged forged, is never approvable and never pendable: the
document is not used at all.

**Neither-never: a partial approves the roles the proof supports AND asks for the rest in the same
pass.** The ask goes out through the ENABLED `uvn-status` sender, not through `held_rows` (which is a
document-intake and shadow-judging surface, not a message). `scripts/paid-status/partial_asks.py` builds
`list-P.json` from the ledger - the latest `apply` decision per request that is `approve_partial`
with a non-empty `pending_roles` and no ask-hold marker on its reason (a `judge`-mode run decides in
shadow and never messages a customer) - listing ONLY those split requests, never another open request
the same user happens to have, and naming only the pending roles in the ask - and `scripts/paid-status/daily.sh`
runs it through the same `runner()` and the same `uvn-status` campaign as every other list, so the
standing captain-approved copy, the kill switch, the fraud lens, the ask caps, the segment's own holds
(`exclude-cs`, support@ 7d, core notice 7d) and the `UVN_STATUS_COPY_APPROVED` send gate all apply
unchanged. The lane has its OWN switch, `PARTIAL_ASKS` (default 0; the installed
`/etc/cron.d/hydra-paid-status` lines leave it unset until the per-role core write ships, so no ask
reaches a customer while the proven roles are still unapproved): `ASKS` is never assigned in `daily.sh`
and stays 0, so the general ask lane remains closed (firstmate 024). Once the write half ships, setting
`PARTIAL_ASKS=1` admits the population the captain ordered.
`uvn_status.partial_pending_roles` is the narrow decider-driven exception (latest `apply` decision only)
that admits those requests to the
list-driven path while their core status is still `unverified` (the per-role write half does not exist
yet); it is not a widening of `PENDING_STATUSES`. The ask never flips the decision - `approve_partial`
keeps its `approved_roles`, `pending_roles` and `pending_proof_need`. Every never-re-ask rule (already
asked, support contacted, the 24h per-user window, the day/run ask caps) still applies and prepends its
own marker, which takes the row out of the vehicle; unknown proof status defers the ASK, never the
approval. The catalog split has its OWN reason prefix (`per-role split:`), so `proof on file` keeps
meaning exactly one thing - a document is on file - and `stage2.held_rows` selects only the
`approve_partial` rows that carry a `proof_id`: stage 2 can only judge a document, and a split row in
that campaign would spend its per-run budget on a row it can never resolve. The `proof on file` reason
prefix is NOT the delivery mechanism: it is the marker
`stage2.held_rows` matches so an incoming document is filed against the row and shadow-judged, and
`verification-queue-report.py` only counts it as "with a person" when the row is a `hold` or carries a
`proof_id` - a catalog split with no document is not a document on file.

**A partial document approves exactly the roles the proof supports: the roles it verified PLUS the
roles a trusted source already confirmed.** `approved = catalog_confirmed ∪ doc_roles`, and every other
claimed role pends. A catalog-confirmed role is never demoted to `pending` - that would ask the customer
to prove a credit the catalog already proves. The document's standing verdict is `partial`, so the commit
passes `partial_ok` for the document it planned with: the role set and the commit agree on the same
document, and nothing is demoted to make them agree.

**The recorded document is the one that proves the most claimed roles.** `doc_approve.pick` orders by
coverage first and recency only as a tie-break, so a newer PARTIAL filing can never shadow an older
fully-verified one - that would ask the customer to prove again something already proven, and would
record the weaker document as the proof.

**A documentation-required request with NO document is held whole.** The `needs_proof` hold and the
`server_approval_refusal` guard cover `approve_partial` as well as `approve`, so an editorial
documentation requirement in ANY role still blocks the whole request - unless the customer has already
sent a document that proves some of the roles, in which case that document IS the proof and those roles
are approved.

**Caps count the request once.** `approvals_today_by_user` counts `COUNT(DISTINCT request_id)`, so a
3-role request with 1 proven role is ONE approval of ONE request, never three.

**The ledger carries the split.** `decisions.approved_roles` / `decisions.pending_roles` are comma-joined
(same convention as `claimed_roles`), added by an additive, idempotent `ALTER TABLE` guarded by
`PRAGMA table_info`; existing rows keep NULL and are never rewritten. `decision_outcomes` books the action
`approve_partial`.

**Shadow only.** `--mode judge` records the split and writes nothing. `--mode apply` REFUSES
`approve_partial` with the reason `partial approval needs the core write half: credit-per-role-write-c1`
and books the outcome `refused:partial_write_half_missing`. Sending a whole-request PUT for a partial
would approve the unproven roles, which is worse than today.

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

**`revert` is NOT gated by the automated writer's kill switch** (qa-review #1717 r10).
`/etc/hydra/credit-trust-decide.disabled` stops the decider approving on its own; an operator arms it
during an incident and then runs `revert --apply` to take back an erroneous approval. Gating the undo
on the stop that halted the thing being undone leaves the credit live and the operator with no lever,
so the compensating revert keeps its own authority: the DSP gate above and the recorded `removal_ref`
in `assert_never_lower`. It still takes the write lock (serializing against the automated writer is
exactly what we want). A rollback whose PUT failed reports `applied: false` with an `error`, and
`cmd_revert` exits 1 - a refusal must never read as success.

**Kill switches.**
- `/etc/hydra/credit-trust-decide.disabled`: nothing is decided.
- `/etc/hydra/credit-review.disabled`: stops this and the audit.
- `approved: false` in the registry: the wrapper refuses every approval.
- cron `enabled: false` **in a repo PR**. `deploy.sh` re-syncs the live cron file from `cron-jobs.json`
  on every deploy, so a live toggle is reverted by the next deploy; use the kill-switch file for an
  immediate stop.

**Lifting a hold is a recorded step, and the proof comes first.** A switch written with its own resume
condition (e.g. `/etc/hydra/credit-trust-score-approve.disabled`, firstmate 2026-11-06) is lifted only by
the step that condition names: `scripts/prove-coded-decider-invalidation.py` produces the proof (the
coded-decider output run twice in a sandbox, the second invalidating the first, no `Errno 13`) and, with
`--host-probe`, the leg the sandbox cannot stand in for: the hold was armed by a permission failure, and
permissions belong to the real directory and the real user, so the probe performs the writer's ladder
(create by tmp+replace, replace over an existing file, the tree's own `_invalidate_coded_output`, unlink)
as the decider's service user (`--service-user`, root: the cron runs inside the gateway) on PROBE-NAMED
files in the live output directory (`/var/lib/hydra/credit-review`), reads the live document's owner, mode
and `os.access` without ever writing it, and fails the proof on any `Errno 13`, the wrong user or a missing
directory. `scripts/credit-approve-hold-lift.sh` is the print-only planner that RUNS that proof itself
against `--tree` (default: its own tree, `/opt/hydra` on node-8; the fixture lives at the deployed path
`scripts/credit_review/fixtures/`) with both legs, refuses unless it exits 0 with a `PROOF: PASS` verdict
line that names the host probe as PASS AND both switches are present, backs up both, records one `kill-lift-<MMDD-HHMM>.evidence` entry and prints the one-line step
for a human to run: `bash <state>/kill-lift-<key>.lift-step.sh`, a sha-pinned script the planner writes
(mode 0700, quoted verbatim in the evidence entry with its sha256). The script appends `lifting`, then
TAKES each switch with an atomic `mv -n` to an aside path and verifies the taken bytes against the sha256 the
plan recorded — take-then-verify, because the decider's `rearm_kill_switch()` writes a new `.disabled`
outside its own write lock, so a check-then-`rm` window cannot be closed by taking that lock; a switch that
changed is put back only if the path is still empty, and a switch re-armed meanwhile is left as found with
its new reason. Only after BOTH takes verify AND neither path has been re-armed meanwhile does it append
`lifted` — the LAST record line of a completed step, written while the aside copies still exist — and only
then discard them. Any other outcome restores every taken switch and appends `ROLLED BACK` with what it
actually observed — restored, `re-armed meanwhile, left as found`, or `RESTORE FAILED, switches may be
absent` — so the record never claims a restore that did not happen, and nothing is ever written after
`lifted`. The planner serializes
the whole plan on a lock, so two planners in the same minute yield one plan and one refusal, never a
truncated record. It has no `--execute`, accepts no handed-in transcript (`--proof` is refused), and one
switch present is a refusal, not a half-lift. The
two files are the second and third stops: the first is the scheduler row's `enabled` flag
(`credit-trust-score-approve-15m`, `enabled: false` in
`cron-jobs.json` and `enabled=0` in the live store since 2026-10-15), which the planner reads (never
writes) and reports as enabled / DISABLED / unknown, so the plan never promises a tick it has not seen
enabled. Re-enabling that row is a `cron-jobs.json` PR, not part of the recorded step — and that PR is
gated: `policies/held-crons.json` names every cron whose `/etc/hydra` kill file is present, and
`scripts/check-held-cron-guard.py` (pre-commit `--staged`, PR Validation `--base origin/main` on the ARC
pod, and `--base origin/main --host` in the node-8 hand-off job) refuses a diff that flips a held cron's `enabled` false→true, changes its schedule or payload, deletes its row, removes
its registry entry without `[key=kill-lift-MMDD-HHMM]` on a commit-message line that names that cron (or
`HELD_CRON_LIFT_KEY=kill-lift-MMDD-HHMM:<cron-name>` at commit time; a key is bound to the cron it names and never
lifts a second entry) AND the executed step's record committed alongside at `data/kill-lift/<key>.evidence`
— the planner's evidence file whose FINAL step record is the human's run's `lifted [key=...]` line and which
names that cron's kill file; a plan that was only planned, a run that rolled back or was re-armed after `lifted`,
an edited (not removed) entry, or a record for another switch, is refused. A committed record is still a
CLAIM, and the ARC-pod run says so (`NOTE ... cannot see the host`): the node-8 run with `--host` is the
check that confirms it — `/etc/hydra/<kill_file>` must be absent there and the step's own record at
`/var/lib/hydra/credit-review/<key>.evidence` (root 750, written only by the step run as root) must be
byte-identical to the committed copy, so a fabricated or edited record is red on the host — or adds a code
line that deletes a literal `.disabled` path. Why a gate and not a pin: on
2026-11-07 an automated review fix inside the print-only planner PR (#1832, commit `dd40d67e9`) flipped
`credit-trust-score-approve-15m` to `enabled: true` "so the lift restores approvals"; a human caught and
reverted it. The guard makes the reviewer structurally unable to commit that again. The audit-sample pause
(`/var/lib/hydra/credit-review/score-approve.paused`) is not one of those switches: its owner clears it
with `credit-review.py score-approve --resume`.

**The durable stop has a POSITIVE half.** A never-lower refusal re-places the switch; when it cannot, it
records the refusal in the ledger (`decider-writer:kill-armed`) and in filesystem sentinels, and every
later run refuses while the switch is absent. But every one of those records is a *negative* fact that
can fail to write at the exact moment of the refusal — and then nothing tells the next run anything
happened. So the write phase also writes `decider-writer:write-in-progress` **before its first batch**,
while storage is still healthy, and clears it only on a clean finish. A marker left behind means a run
started writing and never finished, which is what an unrecordable refusal leaves; `kill_armed_refusal()`
refuses on it, and a writer that cannot write the marker does not write at all (it could not record a
refusal either). Recovery is the same one command: restore the switch, then
`python3 scripts/credit-review.py decide-rearm --clear`, which clears the refusal record, the marker and
the sentinels together.

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

**Core's `lost_race` is read again before score-approve records it (2026-11-15).** Core answers `lost_race` whenever its guarded approve `UPDATE` matches no row. For the low-risk automation that `UPDATE` also carries core's own eligibility guards (engaged claimant, profile burst, cap day), so the one word covers a request another actor rewrote mid-write and a request a core guard refuses. Measured that day on node-8: 1,020 `skipped:lost_race` rows in 39 runs were 51 requests sent 15 to 28 times each; the 34 that were refused on every tick were all still `user_verification_needed`, last updated 1 to 4 days earlier; 17 were approved by an ordinary tick with no re-push. No approval was lost and none of it was a race. `score_approve.settle_lost_race` therefore reads the request again (the same profile-scoped read, both held statuses) and records what that read shows in `decision_outcomes`:

| outcome | what the second read showed | sent again |
| --- | --- | --- |
| `skipped:core_guard_refused` | the request reads as it did when it was decided: status, `updatedAt`, verdict, roles, stamps, popularity and its user, profile and track ids all equal | no, and not for 6 h (`GUARD_REFUSED_COOLDOWN_H`) |
| `skipped:lost_race:retrying`, then that send's own outcome | changed, still held, the same validator verdict, roles, track, profile and user, and `why_not` still clear | once, expecting the status just read |
| `skipped:retry_exhausted:lost_race` | the second send was answered `lost_race` too | no; the next run decides it |
| `skipped:lost_race:decision_stale` | changed, and it is no longer the row that was decided | no; the next run decides it |
| `skipped:lost_race:left_held` | in neither held status | no |
| `skipped:lost_race:state_unread:<why>` | not read (`read_failed`, `time_budget`, `reread_budget`, `page_full`, or the exception's type name when the settle itself raised) | no; not cooled either, unread is not unchanged |
| `skipped:lost_race:changed_not_resent:time_budget` | changed and still approvable, with no room left in the run for a write | no; the next run decides it |
| `error:unverified:re-send raised <Type>` | the second send raised, so whether it committed is unknown | no; the next run reads the row |

A request has one outcome row per send, so a request sent twice in a run has two; every reader of the table takes the newest. The cooldown is keyed on that recorded outcome (`recently_guard_refused`: the newest written outcome of a `score-` run is `skipped:core_guard_refused`), in apply runs only. A cooling request is left out before the profile read: it gets no new decision row and takes no per-run slot, and the run line reports how many were left out (`guard_cooling`), so a run whose only activity is parking them prints that line instead of `NO_REPLY`. Hydra does not copy any core guard to predict the refusal, and never sends a request core's guard refuses in a way that would get past it: when the guard clears, the first send after the cooldown lands. So a request whose guard clears waits up to 6 h longer than it did when every tick re-sent it. Which guard refused is not in core's answer; `skipped:core_guard_refused` says only that nothing moved the request.


**Support@ contacts are never asked (firstmate 041).** Every user in the export's top-level `gmail_contacts_90d` (a list, or `{generated_at, source, user_ids}`) emailed support@ in the last 90 days: their support rows are held for a human, never asked, even when no document was found. A missing or malformed list makes proof status UNKNOWN, so nobody is asked.

**One proof-on-file rule.** The decider reads the export through `credit_review.proof_parts`, the same completeness rule as the verify notes, the take-back gate and Caroline's support tool (pinned by `scripts/tests/fixtures/proof-parts-contract.json`, which the decider now answers too): `core`, `cs-intercom` and `cs-gmail` must all be present, unflagged and fresh by their own stamps, no other part may be flagged, entries must be well-formed and `users` consistent; anything else is UNKNOWN and no proof request is sent. The decider is stricter on top, never looser: integer user ids only, and a readable `gmail_contacts_90d` list (its users are held, never asked).


**Credit backlog rulings (Fable, data/captain-calls-fable-d5/credit-backlog-1019.md; firstmate 072).**
- Order (ruling 6): every run sorts PAID with rows older than 24h, then PAID within 24h, then FREE, oldest-created first inside each (`order_rows`); decisions are re-sorted the same way before the ask cap, so the cap admits paid users first.
- Ask cap (ruling 1): 400 distinct users per UTC day (`max_ask_users_per_day`), with the existing invariants: one batched ask per user per day, never a user with a document on file or a support@ contact, never re-ask.
- Paid provisional approval (ruling 4): a PAID user's small/medium row whose web check is NOT_FOUND (so no contradiction, no red flag, no validator conflict, no editorial rule, not big) is approved with `evidence_kind = provisional_paid` instead of asked; the verify note then tells the user the credit is live and asks for a document, with no threat and no date. **Never auto-removed** (amendment, firstmate 073; captain rule 10-15: a delete must confirm removal at Spotify/Tidal or prove a different profile, no new lowering classes): after 30 days without a document the row goes to the Ops review list (`credit-review.py provisional-review`), still live; any later removal follows the normal proof rule with notice and reason. At most 20 per user per UTC day. Free users stay on the ask path; big tracks stay strict; core's T12 mirror and the documentation-required rule still apply after it.
