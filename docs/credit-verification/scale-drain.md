# Verification scale drain — 1,000s per minute

Design of record: [`data/verification-scale-plan.md`](../../data/verification-scale-plan.md).
Captain, 2026-11-11: *"we need to scale that to faster more parallel 1000s a min"*.

## The arithmetic that reframes the work

92,861 requests carry a declared state (ASKED 61,228; OPEN_UNASKED 23,247; DUPLICATE 6,631;
PROOF_RECEIVED 1,755), and 9,465 were already approved by precedent with zero asking.

At **1,000/min** the whole population is done in **93 minutes**. This is a one-time drain,
not a forever-throughput problem, and then a small continuous tail. Only two things are
genuinely sequential: throughput before the pass, the pass before the tail.

### What the ladder decides on the real snapshot (measured 2026-11-11 15:14Z)

The figures above are the census the design started from. Run against the live replica,
the verify ledger and the proof store, the plan over all 96,703 pending requests is:

| rule | outcome | reason code | requests | users |
|---|---|---|---|---|
| `precedent` | `approve` | `precedent_match` | 3,291 | 672 |
| `proof_verdict` | `approve` | `proof_verdict_approve` | 3 | 3 |
| `precedent` | `queue_tier2` | `precedent_refuse` | 1,165 | 215 |
| `proof_verdict` | `queue_tier2` | `proof_verdict_refuse` | 159 | 31 |
| `duplicate` | `unmatched` | `already_on_profile` | 856 | 183 |
| `ask` | `ask` | `proof_on_file_undecided` | 9,839 | 887 |
| `ask` | `ask` | `no_rule_matched` | 81,390 | 7,219 |
| `expired` | | | 0 | |
| `duplicate` | `close_duplicate` | | 0 | |

`close_duplicate` is an outcome the ladder had on that date too. It is gone (see "A
duplicate is never closed" below), and it never matched a row.

`queue_tier2` is the outcome name the ladder had on 2026-11-11; it no longer emits it (see
"No outcome is a person" below). The 1,324 rows applied under that name are still in the
ledger's `applied` table, each with a `told` row and no message behind it.

**So this pass approved 3,294 requests, queued 1,324 for a named human, and left 91,229
as asks. It is not a pass that decides the backlog**, and an `ask` row is not a decision:
`apply` writes nothing for it. Two rules are zero for different reasons:

- **`expired` is genuinely zero today.** The earliest ask on record is 2026-10-24, so the
  first 30-day window closes on 2026-11-23.
- **No pending row names a request as its duplicate.** `verificationData.duplicate_of` is
  never a request id in production: the only non-null values are 856 maps of
  `{"<track uuid>|<role>": "<credit id>"}`, the credits already on the profile (measured
  again 2026-11-15: every non-null value in core, pending or decided, is a map). The
  same-claimant-already-decided population the census called DUPLICATE is what
  `precedent` catches (4,456 rows).

Not fixed here, and it understates "asked": 2,285 pending requests are named only by sent
notes whose `sent_at` is NULL, which the ask-history read does not count.

The measured ceiling was **1.4 minutes per user** end to end, because
`muso-admin-api.sh` did three round trips per user (token resolve, account resolve, route).
At that cost even perfect batching tops out near 1,000/day.

## The four changes

| # | Change | Where |
|---|---|---|
| 1 | Hoist the per-user work: token once per run, account resolve batched, route out of the decision path | `scripts/credit_review/batch_admin.py`, `muso-admin-api.sh call-batch` |
| 2 | Decide deterministically in rank order, no model in the hot path | `scripts/credit_review/scale_drain.py` |
| 3 | Shard by contiguous id range, one idempotency key per request | `scale_drain.shard_bounds` / `decision_key` |
| 4 | Parallelise the read, keep the write ordered | `scale_drain.apply` (write pool 6), `batch_admin.READ_POOL` 32 |

### 1. The hoist

**The bulk read is the replica, not the admin list.** The admin list refuses unfiltered
paging past offset 20,000 (`enforce_admin_list_bounds`), and its own refusal text names
the fix: *"Use an updatedAt window, a filter, or Trino."* 92,861 rows at `limit=200` is
page 465, so the admin API cannot enumerate the population at all. `snapshot` reads
`postgresql_core.public.credit_requests` in one query — the same surface
`uvn_status.uvn_requests` already reads — and joins the verify ledger for ask history
(core has no `asked_at` column; only the ASK campaigns count, so a removal notice is not
an ask). Ask history is keyed by **request**, from the `request_ids_json` the note actually
named — keyed by account, an old unasked request could be marked expired because a
*different* request for the same user had been asked (QA review 2 of hydra#1883). The admin API stays the **write** path, where the gate chain matters.

The snapshot is one document carrying **all** the ladder's facts, so the documented
`snapshot` then `plan --snapshot` sequence needs no extra flag:

- the pending population (status `user_verification_needed` / `unverified`, not deleted)
  with its `trackid` and `credits` role array;
- the **decided** population (`approved` / `rejected`), which is the source of precedent
  and of whether the request a row names as its original is decided;
- **proof verdicts**, joined read-only from the proof store
  (`scripts/credit_verify/proof/store.py`, table `verdicts`). A verdict that is a
  decision (`GENUINE` / `VERIFIED` → approve, `FORGED_LIKELY` / `INCONSISTENT` → refuse)
  is mapped; a soft verdict (`SUSPECT`, `UNDETERMINED`, `PLAUSIBLE`) is not a decision
  and is not mapped. **The newest verdict per claim wins, including a soft one**: a
  newer `PLAUSIBLE` clears an older `GENUINE`, so a re-analysis under a newer analyzer
  can never resurrect an approval the current analyzer refuses to make.

  **The store keys a verdict by claim, `<request uuid>#<Role>`, not by request**
  (`stage2.py` writes one claim per role). Looked up by the bare request id, as this
  code first did, all 326,611 bound verdicts matched nothing: the proof rule could never
  fire and 10,559 pending requests with a document on file read as "nothing on file".
  `proof_claims` splits the key; `proof_fact` then decides the REQUEST, because the
  write approves a whole request:
  - any role whose newest verdict is a refusal → `refuse`, which `_resolve` turns into an
    `ask` with reason `proof_verdict_refuse`: a refusal waits on the customer, and nothing
    queues it for a person (a refusal may only become a `reject` behind the guard item 3
    builds, which this PR does not);
  - every claimed role's newest verdict an approval, all on ONE proof → `approve`,
    anchored on that proof. Each claimed role needs its **own** claim: a verdict keyed by
    the bare request id names no role and does not stand in for one (production has no
    such row; honouring one would make it the single row that approves any role set);
  - anything else → no verdict, but **`proof_received_at` is still set**. That row stays
    an `ask` with reason `proof_on_file_undecided`, and can never become
    `expired_no_proof`: a user who sent a document is never recorded as having sent none.

  An `ask` row sends nothing by itself. `need_asks.py --from-drain` asks only a user
  whose latest doc-verify outcome names a specific sendable document, and lists everyone
  else as `wait:` or `skip:` — so `proof_on_file_undecided` is the population the
  reviewed ask path exists for, not a re-ask of documents already sent.
- **`duplicate_of` is classified, not trusted to be a request id**
  (`classify_duplicate`). A string is the request id it claims to be. The production
  map means "already a credit on this profile": the row keeps rank one, comes out
  `unmatched` / `already_on_profile`, and is neither written nor asked (the same call
  `uvn_status.ask_class` makes). Bound raw, that map crashed the whole plan.

There is no precedent table in the tree, and the original precedent matcher never
recorded its key. **Precedent is per-claimant, never per-class**: it means "this claimant
was already approved for this claim", not "this track+role class is legitimate". The key
is the claimant plus its track and exact claimed role set (`claim_key`:
`claim:<sha256(userid + track + roles)[:32]>`). A claimant+claim with an approved row sets
an `approve` precedent citing that request; a claimant+claim with only rejected rows sets
a `refuse` precedent. A pending row whose claimant has no prior decision for that claim
does not match precedent at all and falls through the ladder normally.

The residual uncertainty is real and it is the safe direction: the derived key is
narrower than whatever the original matcher used, so it can under-match (fewer rows
approve on precedent than the 9,465 the intent names) but it cannot approve one account
on another account's evidence.

`--decided` / `--precedent` remain as optional overrides (a backfill, a replay);
`snapshot` writes both populations into the document itself.


`muso-admin-api.sh call-batch` is ONE process, ONE token resolve, N requests, with the
same gate chain every single `call` runs. `BatchAdmin.get_many` is that one process;
`BatchAdmin.resolve_accounts` asks for N profile ids in one
`/admin/credit-requests?profilesIds=…` call instead of N calls.

The route call is **not** in the decision path. The plan is explicit that the sender is
the tail, not the head, so `route_many` exists for the tail and records its measured
per-user cost; the drain's decision pass never calls it.

A batch client that spoke HTTP directly would be faster and would also bypass the
credit-approve, reject, removal, tier-2, pace, merge-reverse, enrich-link and
bulk-destructive gates. Speed is not worth a second ungated write path, so the batch goes
through the wrapper.

### 2. The ladder

Stop at the first match. Every rule is a SQL predicate (`scale_drain.LADDER_SQL`):

| Rank | Rule | Condition | Outcome | Reason code |
|---|---|---|---|---|
| 1 | `duplicate` | `duplicate_of` is a map of credits already on the profile, or names a request that is **not** decided | **`unmatched`: counted, never written, never asked** | `already_on_profile` / `unmatched_duplicate` |
| 2 | `precedent` | `precedent_key` has a recorded outcome, and for a `refuse` outcome nothing on file is newer than that refusal | approve / **cannot confirm** | `precedent_match` / `precedent_refuse` |
| 3 | `proof_verdict` | a readable verdict (`approve`/`refuse`) exists | approve / **ask** | `proof_verdict_approve` / `proof_verdict_refuse` |
| 4 | `expired` | **asked** (`asked_at` set), `expires_at <= now`, no evidence on file (`evidence_at` empty) | **cannot confirm** | `expired_no_proof` |
| 5 | `ask` | nothing matched | ask | `no_rule_matched`, or `proof_on_file_undecided` when evidence is on file |
| — | `unmatched` | a row carries a fact the ladder cannot resolve (an undecided duplicate original, an unmapped proof verdict, a precedent row with no outcome, an approve with no anchor) | **none: counted, never written, never asked** | `unmatched_duplicate` / `unmatched_precedent` / `unmatched_proof_verdict` |

A model reviews a sample and proposes rule changes; it never decides a single row
(Aaron's 2026-10-29 ruling). A fact the ladder cannot resolve is not a decision **and
not an ask either**: a row that was already decided by precedent must never be turned
into a fresh "please verify" ask to that user. Such a row gets the `unmatched` outcome,
`apply` does not write or commit it, `verify` lists it, and the CLI prints the count.
The two rules are separate on purpose: `ask` means "no fact, and asking is the right
action"; `unmatched` means "a fact is present but unreadable, so it is counted and left to
the next pass": not written, not asked, and not a human's queue.

**An approve for a request on a hold core's guard does not act on is `unmatched` /
`held_by_validator`.** Core's guard holds an agent approval on three facts of the
validator's stored verdict: a `review_*` rule at 30 or more, the class C signature, and
`rule_errors._hold_on_error`. A request can list a hold with none of them: on 2026-11-13
two requests listing `track_pending_capture` at risk 100 were approved 17 minutes after
the hold was set. `verify_anchor.uncovered_holds(verdict)` returns the verdict's hold
codes in that case (every code counts, and a list that cannot be read is
`verdict_unreadable`), and nothing when the guard itself holds. It is used twice:

- **At plan time**, from the replica snapshot (`requests.uncovered_holds`): the row is
  counted, never written and never asked.
- **At the write gate**, from the live request: the approve is refused, and a request
  listed without `verificationData` is refused as unreadable. The plan already leaves out
  every such row the snapshot shows, so the gate meets only a hold set after the snapshot.
  Its refusal is a wrapper-layer failure in `apply`, not a core refusal: it is never
  routed to an ask, the row is retried on the next run, and it counts toward the breaker.

Where the guard does hold, nothing here applies: the row stays `approve`, carries
`hold_causes`, goes to core, and core's `validator_hold` refusal is routed as described
under "The write path". The gate runs as a script and cannot import `policy.py`, so it
reads the guard's three facts itself; `GuardReaderTests` holds that reader to
`policy.validator_conflict`. `snapshot --source admin` does not carry `uncovered_holds`,
so a plan built from it has the gate's stop only.

**An expiry may only reach a request we actually asked.** A never-asked request falls
through to `ask`, because the 23,247 OPEN_UNASKED rows are the drain's population, not
its expiry pile: an expiry is the record of a window the customer was given and did not
answer, and an unasked request has no such window. `expired_no_proof` is the reason code
for the asked-and-expired case only.

A precedent carries its own outcome: an `approve` precedent approves, and a `refuse`
precedent is `cannot_confirm` (`precedent_refuse`), never a rejection. The ladder selects
the row; `_resolve` makes the row's verdict binding. `cannot_confirm` rows are committed to
the ledger; they are not asks, so `need_asks.py` never sends to them.

**A refuse precedent is not final** (decision 2026-11-15, `SET_ASIDE_SQL`). The precedent
key holds the claimant, so a refuse precedent is the same account's earlier refusal of the
same claim. It holds a request only while nothing on file is newer than that refusal:

- `requests.evidence_at` is the newest evidence on the request whatever its kind: a proof
  verdict (`proof_received_at`), a filed document (`proof_intake`, every request the
  filing names), or a DSP anchor (`dsp_anchors` with outcome `built` or `written`; a
  `refused` anchor is the record of no anchor). `evidence_times` reads the two stores.
- A link reply (`proof_link_intake`) is **not** read, so a link filed after a refusal
  neither sets the refusal aside nor stops an expiry. Measured 2026-11-15 02:11Z: the
  production proof store held 0 `proof_link_intake` rows, and no enabled proof cron passes
  `--links`. Whoever turns link filing on must add that read to `evidence_times` in the
  same change.
- `precedent.decided_at` is the newest `updatedat` among that claim's rejected requests.
  Core has no decided-at column, and `updatedat` is never earlier than the decision, so
  it can only make a refusal look newer than it is. A time that cannot be read is not
  measured, and an unmeasured refusal does not stand over evidence.
- Evidence strictly newer than the refusal takes the request out of the `precedent` rule.
  The lower rules then decide it: an approve verdict approves, anything else is an `ask`
  (`proof_on_file_undecided`), and the plan row names the refusal it set aside in
  `superseded_precedent`. An `approve` precedent is never set aside.
- A store that exists and cannot be read, or holds a time that cannot be read, stops the
  snapshot. A store that does not exist is no evidence of that kind.

The same `evidence_at` is what stops an expiry, so a filed document with no verdict yet
keeps an asked request out of `expired_no_proof`.

### A duplicate is never closed

The drain writes one status, `approved`. It writes no `rejected`, for a duplicate or for
anything else (`WRITE_STATUS`; the writer refuses any other mapping before the wrapper is
spawned).

Until 2026-11-15 a request whose `duplicate_of` named an already-decided request was
closed: `PUT /admin/credit-requests/conditional-status` with `status: "rejected"`, on
the reasoning that the original decision stood and the close was deduplication. Three
things that reasoning did not hold against, each read in core or measured:

- **core tells the customer "rejected".** core sends its rejection notice on every move
  to `rejected` (`updateStatus.js`, `creditRequestsRejected`), and refuses
  `notify: false` on that move (`parseNotifyFlag` allows it only for a move to
  processing, unverified or verification-needed). The status enum has no duplicate
  status, so there is no quieter way to close.
- **The close came back as a refusal of the claim.** Precedent is read from core's
  decided rows (`DECIDED_SQL`: `approved` / `rejected`). A close written as `rejected`
  is one of them, so the next snapshot read it as this claimant's refusal of this claim,
  dated the day of the close: newer than every document already on file, which is the
  one thing that sets a refuse precedent aside.
- **It added nothing the ladder did not already decide.** The close was accepted only
  when the original matched on claimant, track and roles, and that is the precedent key.
  Without the close an approved original approves the request on precedent, and a
  refused original holds it at `cannot_confirm` until newer evidence is on file.

So a request that names a decided original is decided by the rules below `duplicate`, as
if it named nothing. The `duplicate` rule keeps only the rows it cannot resolve (the
profile-credit map, an original that is not decided), and those stay `unmatched`.

A plan made before this change may still carry `close_duplicate` rows. `apply` refuses
such a plan whole, before it records or writes any row (`RETIRED_OUTCOMES`): make a new
plan from a new snapshot. Neither wrapper copy has a duplicate-close predicate any
longer, so a `rejected` body from the drain's identity meets the reject gate like any
other caller's and is refused there.

Measured on core's replica 2026-11-15 09:37Z: no request, pending or decided, carries a
request id in `duplicate_of`, and the drain's ledger holds no `close_duplicate` row. The
close had never written anything; this removes the path before it could. The reads behind
that measurement, and core's own notification and status code, are in
`data/nohumans-drain-n1/item1-duplicates.md`.

**No outcome is a person** (captain 2026-11-14: "there should be no humans involved
except the customers giving proof and their statements"). The ladder no longer emits
`queue_tier2`. What it emits instead is an interim state, and this section says what that
state does and does not do:

| was `queue_tier2` for | now | what `apply` does with it |
|---|---|---|
| asked, expired, no proof (`expired_no_proof`) | `cannot_confirm` | a ledger row; no API write, no message |
| a `refuse` precedent (`precedent_refuse`) | `cannot_confirm` | a ledger row; no API write, no message |
| a `refuse` proof verdict (`proof_verdict_refuse`) | `ask` | a ledger row; the row is in the `asks` audience like any other ask |

**`cannot_confirm` is recorded and nothing else.** The customer is told nothing and core
still holds the request as pending, so the next plan decides the row again from that
snapshot. New evidence reopens both reasons:

- `expired_no_proof` requires no evidence on file (`evidence_at IS NULL`), so a document,
  anchor or verdict that arrives later moves the row to `proof_verdict` or `ask` on the
  next plan.
- `precedent_refuse` holds only while nothing on file is newer than the refusal, so
  evidence that arrives later moves the row the same way.

The rule and the outcome are in the ledger key, so a reopened row gets a new key and is
applied again; the old `cannot_confirm` row stays in `applied`.

**What is still missing: nothing tells the customer.** No message goes out for a
`cannot_confirm` row, so the customer does not learn that sending evidence would reopen
it. Measured on the production replica 2026-11-15 01:23Z (102,432 pending requests), of
the 1,172 requests with a refuse precedent:

| | requests | users |
|---|---|---|
| set aside by later evidence, now `ask` / `proof_on_file_undecided` | 178 | 44 |
| still `cannot_confirm` / `precedent_refuse` | 994 | 176 |

Of the 994, 984 have no evidence on file at all (734 of them were never asked, 250 were)
and 10 have evidence that is not newer than the refusal. Of the 178 set aside, `asks`
offers 57 (28 users) to the ask path and holds 121 (17 users) for a cause no document
clears (`ask_hold`: 76 fraud, 40 band C, 4 impersonation, 1 velocity). The DSP anchor
store held no `built` or `written` row on that date, so the anchor branch has run on
fixtures only. The same plan moved 15,292 `ask` rows from reason `no_rule_matched` to
`proof_on_file_undecided`: each is named by a filed document and has no verdict. Their
rule, outcome and ledger key are unchanged, and the approve set is the same 3,365
requests. Do not report `cannot_confirm` rows as decided or as told.

`tier2-queue` still parses and exits 0, and lists no row whatever the ledger holds.

Never lower a served number.

`expires_at` does not exist on credit requests in core, so the snapshot derives it from
`asked_at` + `ASK_WINDOW_DAYS` (30), keeps a core-supplied value when one appears, and
leaves it NULL for a request that was never asked.

**The window runs from the ask, not from creation.** Keying it on `created_at` expires a
request the moment we finally ask it: a row created 2026-01-01 and asked 2026-11-10 would
have been queued for a refusal on 2026-11-11, one day after the customer was asked, which
is a denial of a request we never actually gave them time to answer (QA review 3 of
hydra#1883). Rank 4 therefore requires `asked_at IS NOT NULL` as well as an elapsed
window, and an unasked row can never reach it - it falls to `ask`.

### 3. Idempotency and shards

`decision_key = sha256(request_id || rule || outcome || version)`. It is the primary key of
the ledger's `applied` table, so a re-run cannot double-apply and a restarted worker skips
every row already in the ledger.

The **outcome** is in the key, which the original sketch did not have. Without it a decision
that CHANGES keeps its key and `apply` skips it: a row recorded as `cannot_confirm` that
later becomes an approval would be silently dropped (QA review 2 of hydra#1883). With it, a
changed decision is a new key and gets applied, while an unchanged one is byte-identical. A
request may therefore hold more than one ledger row over its life; `verify` counts a
double-apply as the same request applied twice **for the same outcome**, not as two rows. Shards are contiguous slices of the **sorted** id list,
so the shard assignment is deterministic regardless of input order. Start at 16, tune to
32.

The ledger is append-only (triggers refuse `UPDATE`/`DELETE`), `synchronous=FULL`, and
each row commits in its own transaction — a `kill -9` leaves a prefix of committed rows
and nothing half-written.

### The write path

`apply` performs a **real API side effect** through the one reviewed path
`muso-admin-api.sh` already exposes and the lobster MVP already uses: a
`PUT /admin/credit-requests {"requestIds":[…],"status":…}` through the wrapper, so the
full gate chain still runs. No new endpoint, no direct HTTP client.

| outcome | status written |
|---|---|
| `approve` | `approved`, with `--evidence-excerpt` set to a `drain-signal:` digest |
| `cannot_confirm` | **no write**, and no message: recorded in the ledger only |
| `ask` | **no write** — the send belongs to `need_asks.py` |

#### The drain does not disable the approve gate

The drain is an agent-driven caller, so it must not set `CV_APPROVE_GATE_DISABLED` — that
variable skips *every* evidence requirement and its own comment says it must not be set by
hand or by an agent. Instead the wrapper carries a fifth registered predicate,
`is_scale_drain_approval`, alongside the four that already exist for the other autonomous
approvers. It admits exactly one caller and it **checks the evidence** rather than skipping
the check:

- `SCALE_DRAIN=1`, requester `scale-drain@hydra-ops`, `PUT /admin/credit-requests`;
- kill file `/etc/hydra/scale-drain.disabled` absent;
- `policies/credit-approval-automation.json` has `automations["verification-scale-drain"]`
  with `approved: true` and a non-empty `approved_by` + `approval_ref`;
- the body is exactly `{requestIds, status: approved}` with **exactly one** request id;
- `EVIDENCE_EXCERPT` matches
  `^drain-signal:(precedent|proof_verdict);[a-z_]+;v[0-9]+;(<uuid>|<64-hex-proof-id>);(<uuid>|-)$`;
- **and the anchor is then VERIFIED**, not merely parsed.

That last clause is the one that makes the gate do work: the digest must name an
**auto-approvable rule** and a **row-specific anchor** — the request that set the precedent,
for a precedent approve, or the proof id, for a proof-verdict approve. A row that cannot
produce an anchor is not auto-approvable: the ladder leaves it `unmatched` with reason code
`unmatched_precedent` / `unmatched_proof_verdict` rather than approving on a rule name
alone. A proof id is a sha256 hex digest, not a UUID, which is why the predicate accepts
both. `refuse` needs no anchor;
the approve gate is the gate that exists, and refusing is not the direction that needs
evidence.

##### A digest is a claim; the anchor is a fact

Parsing a digest is not verification. `SCALE_DRAIN`, `--requester` and
`--evidence-excerpt` are all caller-supplied, so a predicate that only checked their shape
would let anyone who can invoke the wrapper approve an arbitrary UUID by writing a
well-formed string. That is a labelled bypass, not a narrow one (QA review of hydra#1883,
2026-11-11).

So the predicate hands the parsed parts to `scripts/credit_review/verify_anchor.py`, which
answers from a source the caller does not control:

| rule | verified against | the check |
|---|---|---|
| `precedent` | **one** admin-API GET for the claimant's profile | the anchor is `approved`, and matches this request on claimant, track and claimed roles |
| `proof_verdict` | the root-owned proof store (`/var/lib/hydra-credit-verify/proof.sqlite`) **and one** admin-API GET for the claimant's profile | the request is still pending; the **newest** verdict of every claim on file for the REQUEST is a decision (`GENUINE`/`VERIFIED`) and is the anchored proof; and **every role the live request claims has its own verdict** |

The proof check is keyed on the **request**, not on the supplied proof id. Keyed on the
proof id it failed open: the real schema defaults `request_id` to `''`, so an old `GENUINE`
row with no bound request verified any pending target, and a newer `PLAUSIBLE` for a
different proof was ignored (QA review 2 of hydra#1883).

**The roles are read from the request as it stands, not from the plan.** The store holds
only the claims stage 2 has analysed, so a check that walks the store approves on
whatever happens to be on file: a Composer + Producer request with one `GENUINE` Composer
verdict and nothing for Producer passed, on a stale or hand-edited plan (QA review 6 of
hydra#1883). `verify_proof_live` now makes the same one GET the precedent path makes,
refuses a request that is no longer pending, and requires a verdict for each role in the
request's `credits` (a request claiming no role needs the store's `unknown` claim). Roles
that could not be read are `Unavailable`, never an empty list. Two consequences: a proof
approve needs a profile id in its digest (all 96,703 pending rows in the 2026-11-11
snapshot carry one; a `-` is refused), and it costs one admin GET like a precedent
approve. The three proof approves in that snapshot pass the stricter check and the plan
bytes are unchanged.

A verifier that cannot run is a **refusal**, never a pass: a missing verifier, an
unreadable proof store or a list response with no `items[]` all refuse the write.

**Neither the verifier's path nor the proof store is caller-controlled.** `HYDRA_ROOT` and
`CREDIT_PROOF_STORE` are environment variables, so a caller could point the check at a
substitute verifier or at a SQLite file it wrote itself and fabricate a `GENUINE` verdict —
which is the same forgeable approval in a different costume (QA review 3 of hydra#1883).
So the wrapper derives the verifier from **its own location**: `scale_drain_root()` walks up
from `$(dirname "${BASH_SOURCE[0]}")` until it finds `scripts/credit_review/verify_anchor.py`,
and the proof store path is a constant in the verifier. The walk starts from the wrapper's
**resolved** path (`realpath`), so a symlink to the deployed wrapper, made inside a tree
the caller owns, still trusts the deployed tree and not the one the symlink sits in.

**Nor is the approval registry.** Both predicates read
`<that same root>/policies/credit-approval-automation.json` through one helper,
`scale_drain_registry()`. It used to be `${CREDIT_APPROVAL_REGISTRY:-${HYDRA_ROOT:-/opt/hydra}/policies/…}`,
so a caller could bring a registry of its own that said `approved: true` while the
deployed one had authorised nothing (QA review 5 of hydra#1883). A
`CREDIT_APPROVAL_REGISTRY` or `HYDRA_ROOT` that resolves to any other file is **refused,
not ignored**. A value that resolves to the pinned file is let through, because the
operations wrapper defaults `CREDIT_APPROVAL_REGISTRY` at file scope for its older
predicates and a host may export `HYDRA_ROOT=/opt/hydra`; the file that is read is the
pinned one either way. Consequence for a checkout that is not `/opt/hydra`: the operations
copy's file-scope default names `/opt/hydra/policies/…`, which is not that checkout's
registry, so the drain's predicates refuse there until one of the two variables names the
checkout's own registry. The other predicates in that wrapper (`credit-trust-decide`,
`credit-trust-score-approve`, `fable-decider`) predate this PR and still honour the
variable; they are not changed here.

**Nor is the admin API the verifier reads.** The verifier used to build its batch client
with no script, and the batch client takes `CREDIT_REVIEW_ADMIN_SCRIPT` from the
environment the wrapper passes down - so a caller could name a script of its own, have it
print "the anchor is approved", and the verifier would believe it (QA review 4 of
hydra#1883). The verifier now reads through exactly one wrapper, found from **its own
location** (`<root>/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh`,
i.e. `/opt/hydra/...` on node-8), and a `CREDIT_REVIEW_ADMIN_SCRIPT` that resolves anywhere
else is **refused, not ignored**: the write fails and the reason names the variable. The
other credit tools still honour that variable; only the gate's verifier does not.

**The wrapper runs the verifier as a file: `python3 -I verify_anchor.py`.** It is not a
package module there, so it loads `batch_admin.py` from its own directory by path. A
relative import (`from . import batch_admin`) raised `ImportError` on every invocation and
both gates refused every write, while the suite stayed green because no test executed the
file the way the wrapper does. `-I` also keeps the caller's `PYTHONPATH` and working
directory off `sys.path`. `RealEntrypointTests` (`scripts/tests/test_scale_drain.py`) runs
`bash <wrapper>` at its real path, with only `curl` replaced, and asserts a verified
approve reaches the API. Since an approve also needs the root-only token (below), the
passing cases run in a mirror of the tree - both skill directories, the verifier, its
batch client and the registry at their real relative paths - in which exactly one line
per wrapper differs, the token literal; `test_the_mirror_is_the_real_tree_but_for_the_token_path`
holds the mirror to that diff. The checked-in files are run unmodified for the half that
can run anywhere: against the real pinned path, a caller's own token is refused.

The profile id in the digest is what makes the precedent check one round trip: core's list
endpoint filters on `profilesIds`, so one GET returns every request on that profile —
target and anchor together. A caller who lies about the profile id gets nothing, because
the target will not be in that profile's list.

##### An approval presents the drain's identity too

`SCALE_DRAIN=1`, `--requester scale-drain@hydra-ops` and the digest are all values a
caller sets, so before QA review 5 the only thing between "can invoke the wrapper" and an
approval was the verified anchor. That is the stronger control - it is per row, and it is
answered by the admin API or the proof store - but it left the approve path with no
execution identity at all.

An approval now goes through one check, `scale_drain_token_ok`, before the registry or the
verifier is consulted: `SCALE_DRAIN_TOKEN` must equal the contents of
`/etc/hydra/scale-drain.token`, **mode 600, owned by the user the wrapper runs as** (root
in production). The path is one literal, in that one helper; `SCALE_DRAIN_TOKEN_FILE` set
to anything refuses the write.

**What this is and is not.** It raises the bar from "can invoke the wrapper" to "can read
that file". It does **not** make the path non-forgeable, and it is not claimed to: any
process running as root on node-8 can read the file, and that includes every agent whose
exec posture is `full`. It also does nothing against a caller who controls the wrapper's
whole process environment rather than its documented variables - `PATH`, `BASH_ENV` or an
exported function can replace `python3`, `jq` or `stat` underneath any bash gate, and
`MUSO_API_URL` plus the admin credentials are the wrapper's inputs by design, so a caller
holding those does not need the wrapper. A stronger identity than a root-readable file
means the drain running as its own uid (a file only that uid reads, or a systemd
credential), which is a host change, not something a wrapper can assert about itself.

**An approve therefore needs the token file to exist.** Nothing creates it: not the
deploy, not this PR. Until an operator places it (`install -m 600 -o root /dev/stdin
/etc/hydra/scale-drain.token`), `apply` refuses every approve
with `…/scale-drain.token is missing`, and writes nothing.

**Cost.** Only approve rows are verified, and the approve population is small: 3,294 of
96,703 on the 2026-11-11 snapshot (the precedent and proof-verdict approves), not the
whole backlog. Measured locally, the verifier's own
overhead is ~26 ms/row (python start + one indexed SQLite read); every verified row -
precedent or proof verdict - adds one admin GET. **The end-to-end pass time has not been measured on prod** — this
worktree has no prod access — so no figure is claimed here. The operator's first real run
is what produces it.

##### The token path is pinned

**The path is a literal in the wrapper and in the drain.** It was overridable with
`SCALE_DRAIN_TOKEN_FILE`, which reduced the check to "the caller can write a mode-600
file and read it back" (QA review 4 of hydra#1883). Setting that variable - to anything,
including the real path or an empty string - now **refuses** the write, and a
`SCALE_DRAIN_TOKEN` that is not exactly the pinned file's contents is refused before the
verifier is consulted. This **raises the bar** from "can invoke the wrapper" to "can
read that file". It does **not** make the path non-forgeable, and it is not claimed to
(captain decision, 2026-11-11). Tests that need a passing approve rewrite the literal in
a scratch copy; there is no environment seam.

To see how many rows that moves from approve to unmatched on a real snapshot:

```bash
python3 -m credit_review.scale_drain plan --snapshot snap.jsonl --out plan.jsonl
jq -r 'select(.outcome=="unmatched") | .reason_code' plan.jsonl | sort | uniq -c
```

Every precedent row carries its anchor (a decided request always has an id), so the
population this moves is the proof-verdict rows with no `proof_id` — a verdict with nothing
behind it. `scripts/check-credit-approval-automation.sh` enumerates the wrapper's
`is_*_approval` predicates — in all three Bash spellings (`name()`, `name ()`,
`function name()`), because matching only the first let the other two evade the scan — and
fails CI if any of them has no registry entry naming it in
`wrapper_predicate`, so a new approve path cannot ship unregistered the way this one
almost did.

**Intent, write, confirm.** The ledger hears about a side effect before the API does:

1. `apply` commits an **intent** row (`intents`: decision key, request, outcome,
   `planned_at`, state `planned`);
2. it makes the API write, through the wrapper and its gate;
3. it commits the `applied` row and the intent's `confirmed` in one transaction.

A process that dies between 2 and 3 leaves a request the product has moved and an intent
nobody confirmed. The earlier write-then-commit order could not recover from that: the
retry is refused by the gate, correctly, because the request is no longer pending, so the
row was reported missing forever (QA review 5 of hydra#1883). Now the next run **reads
before it writes**. For every open intent it asks the verifier's pinned admin source what
happened to the live request (`verify_anchor.reconcile`):

| the live request | what `apply` records |
|---|---|
| holds the status this decision sets, changed at or after `planned_at`, and the decision's own anchor still verifies | `confirmed`, resolution `reconciled` |
| is still pending | the write is retried through the gate, then `confirmed` / `written` |
| was decided the other way | `abandoned`, `target_<status>` — never overwritten |
| held that status before the intent existed | `abandoned`, `decided_before_intent` |
| holds that status but this decision's anchor does not verify | `abandoned`, `anchor_unverified` |
| could not be read | nothing: the intent stays open, an error is counted |

There is no blind retry. A failed or timed-out write also leaves its intent open, because
a failure does not prove the write missed. `verify` reports open intents as `unconfirmed`
(the ledger is not `ok` while one exists) and abandoned ones under `abandoned` with their
reason.

The gate itself is unchanged: it refuses a decided request either way. It now exits **3**
when the request already holds the status the write would set and **1** for any other
refusal, so the two are told apart without reading prose.

**What reconciliation cannot know.** The admin API names no actor on a request. A request
somebody else moved to the same status after our intent, on a claim our anchor also
supports, is indistinguishable from our own write and is recorded as ours. It is always
recorded as `reconciled`, never `written`, so those rows can be listed and audited.

#### A failed write names its layer, and a refusal is not sent twice

The 11 November run left 3,326 approve intents `planned` and nothing else: one stderr
line per row, an exit code of 1, and no record of why. Four layers were blamed in turn
(the wrapper, `MUSO_API_URL`, the token file, "HTTP 400"). Every failed write is now a row
in the ledger's append-only `write_failures` table:

| `layer` | the write stopped |
|---|---|
| `local` | in the writer, before anything was spawned (a hand-edited plan row) |
| `token` | at `/etc/hydra/scale-drain.token`: missing, unreadable or redirected |
| `wrapper` | in the wrapper, before an HTTP answer (a gate refused, a setting is missing) |
| `transport` | after the call left, with no HTTP answer: it may have landed |
| `api` | at the API, which answered non-2xx; `http_status`, `error_code` and the row's `reasons` are kept verbatim |
| `response` | at a 2xx that does not name the row in `updatedIds` |
| `readback` | at a 2xx naming the row, when the live request does not hold the status |
| `unknown` | nowhere nameable: any other exception in the writer, recorded rather than lost |

Five bounds follow from that record:

- **A 2xx is not a granted credit.** After a write the API accepted, `apply` reads the
  live request through the same pinned read the reconciler uses and confirms the row only
  when it holds the status. A read that does not show it leaves the intent open
  (`readback`), and the next run reads again. `--report` says `granted` only for a row
  that was read back.
- **A row the API refused is held.** A 4xx carrying an `errorCode` that is the API's
  answer to that exact call says nothing was written. Later runs skip the row with no read
  and no write (`refused_held`). `--redrive-refused N` is the only way to send it again,
  for at most N rows, and is for after whatever refused it has changed. A timeout, a 5xx,
  a gate that could not run, and **`401`, `403`, `408`, `425` or `429`** prove nothing
  about the row (the session lapsed, the credential rotated, or the API is throttling the
  run) and keep the read-then-retry path: `429, 408, 425, 401, 403` are never held.
- **A row core judged keeps core's reason as its outcome.** `core_row_refused` is
  recorded in the append-only `core_refusals` table as `refused_by_core:<reason>`, never
  left as `approve`: nothing downstream may read a refused approval as still in flight.
  Where the reason is one an ask answers - `proof_required`, `no_sound_precedent` - the
  row is routed to the ask path (`refused_to_ask`; `asks --plan P --out FILE` emits that
  audience for `need_asks.py build --from-drain`, the one reviewed sender). Any reason
  not named there stays held (`refused_held`), never asked, never queued to a person. No
  tier-2 or person queue exists for a refused approval.
- **`validator_hold` beside an ask reason is asked unless the hold's cause is one no
  document clears**
  (owner decision 2026-11-14). Core lists `validator_hold` first on a proof row and never
  says which hold it is, so `snapshot` reads the cause from the request's own stored
  verdict (`hold_causes()`) and the plan carries it on every approve row (`hold_causes`).
  Two readings are joined there: core's `validatorConflict` (a `review_*` rule at 30 or
  more, the class C score signature, `rule_errors._hold_on_error`), and the validator's
  own band C, taken from `credit_trust_bands.json` at run time (`band_c_causes()`:
  `band_c_rules` and `band_c_error_keys`) wherever the verdict records it - a rule that
  fired in `rule_risk_percent`, a key in `rule_errors`, a code in `hold_reason_codes` -
  plus the validator's `fraud_hold`. Core's reading alone never shows a `reject_*` rule
  or `validation_error`: they are not `review_*`.
  A document answers the validator's own proof rules and the class C score signature
  (`ASKABLE_HOLD_CAUSES`), so those rows are asked. A velocity rule is the bands' band B
  only on an editing burst (`proof_required.editing_burst_rules` on a role the bands'
  `high_risk_roles` calls editing); the plan carries that answer as `editing_burst` (read
  from the request's `claimed_roles` against the bands at run time), so an editing-burst
  hold is asked and every other velocity hold is held, as is one whose roles could not be
  read.
- **On the refusal route, a band C cause is never asked, alone or under a hold that would
  be, and with or without core's `validator_hold`** (`never_asked_cause()`; review of
  #1976, 2026-11-14). The same reading holds the ladder's own ask rows and every sender's
  audience (see "No ask names a held request" below).
  Band C is the validator's "held for a reason the claimant cannot answer", so an ask
  there is one no document clears. Core answers `validator_hold` only for its own
  reading, so a row whose only hold is a `reject_*` rule is refused `proof_required`
  with no `validator_hold` at all, and it is held all the same. The list is the band
  table's, never a copy in this file: a rule added to `band_c_rules` holds with no change
  here, and a table that cannot be read holds every refused row and every ask audience
  (`bands_table_unreadable`). An entry that is not a rule name (null, a number, an empty
  string) makes the whole table unreadable, never a shorter list. `HARD_HOLD_CAUSES` only names the class a few of them are
  recorded under. `core_refusals.hold_note` says which cause held the row:

  | Class | Cause | Why it is not asked |
  | --- | --- | --- |
  | `fraud` | `review_held_submitter`, `fraud_hold` (decision `hold`) | the account is on the credit hold list |
  | `impersonation` | `review_role_credited_to_other_at_trusted_source` | a trusted source credits the role to someone else |
  | `legal` | `review_operations_tombstone` | Muso Operations removed this credit earlier |
  | `already_held` | `review_duplicate_of_approved_credit` | the profile already has this credit approved or in flight: a proof ask would ask for a credit the customer has |
  | `unmeasured` | `_hold_on_error`, `_no_signal`, `validation_error` (the table's `band_c_error_keys`), a `fraud_hold` present but not a mapping with a decision | the validator could not complete a check |
  | `band_c` | every other rule of `band_c_rules`: `reject_deleted_catalog_track`, `reject_high_risk_profile`, `reject_artist_credit`, `reject_individual_org_credit`, `reject_publisher_label_credit`, and any rule added there later | the validator's own table says the claimant cannot answer it |
  | `band C velocity` | `review_high_velocity_profile`, `review_hourly_velocity_profile` on a non-editing role (`band_c_velocity`) | a velocity hold is the bands' band B only on an editing burst |
  | `unmeasured velocity` | the same two rules with roles that could not be read (`velocity_roles_unmeasured`) | unmeasured is not an ask |

  Any of those causes named in the verdict's `hold_reason_codes` is treated exactly like
  the cause it names, because that list is the validator's own machine record of why a
  verdict was not an approval. Its score codes (`score:*`,
  `risk_score_at_or_above_threshold`) ride every askable row and are not causes.
  A `review_*` rule counts from 30 up (core's threshold); any other band C rule counts
  as soon as it fired (a score above 0).

  Not in the band table, so not held by this rule: `reject_high_velocity_profile`. It is
  at 100 on 1,533 of the ask-route rows (143 users), mostly on verdicts from March to
  July 2026. Whether that rule belongs in band C is the band table owner's call (IDP and
  the hydra mirror change together).

  Not measured is not an ask: a plan row whose `hold_causes` could not be read from the
  snapshot (a plan made before the field existed, or a verdict that could not be read) is
  `hold_cause_unmeasured`, a hold core reports that the snapshot does not show is
  `hold_cause_not_in_snapshot`, and a rule this code has never classified is
  `unclassified:<rule>` - those three hold only beside core's `validator_hold`, while on a
  row core did not hold they are asked. A cause no document clears holds either way. On a
  row core did NOT hold, only a never-asked cause is consulted: an askable cause, a
  `hold_causes` that could not be read or an unclassified cause does not hold a row core
  says is waiting on a document. A test fails when
  `credit_trust_bands.json` names a `review_*` rule that is in none of those lists. The
  cause is as old as the snapshot, so plan from a fresh one: a plan file written by an
  earlier version of this code carries `hold_causes` built from core's reading alone and
  therefore omits every band C cause, so after this deploys, build a new snapshot and plan
  before any apply; the send gate's own account-hold
  read (`comm_state`) is still made at send time. A route already recorded as `hold` is
  not rewritten.
- **On the ask route is not the same as asked.** `need_asks.py` sends the per-need ask
  only where a document was read and names a sendable need; every other row is listed as
  `wait:no_sendable_document` and nothing is sent from this path. Measured 2026-11-14
  with this code on the 3,326 approve intents (core's answer re-derived from the replica,
  not core's own; no approve has been sent under it):
  2,774 would be refused `proof_required` (483 users). 634 of them carry `validator_hold`:
  112 (37 users) go to the ask route and 522 (128 users) stay held - 300 velocity on a
  non-editing role, 127 `already_held`, 65 `fraud`, 29 `impersonation`, 1 `legal`. The
  other 2,140 carry no `validator_hold`: 2,034 go to the ask route and 106 (38 users) are
  held on a band C cause core does not report - 87 `reject_publisher_label_credit`, 9
  `validation_error`, 8 `reject_individual_org_credit`, 2 `reject_deleted_catalog_track`.
  In all, 2,146 on the ask route (343 users) and 628 held (163 users). None of the 112 has
  a band C cause beneath its askable hold. Of the 112, 52 (17 users) have a document with
  a sendable need and 60 (20 users) have none; 75 (24 users) have never been sent any ask.
- **No ask names a held request, in the ladder or in any sender** (owner 2026-11-14:
  "fraud or impersonation means no ask, ever"; other band C causes are asked only where an
  ask can clear them, and the bands table says none can). The reading is one function,
  `policy.never_ask(verdict, claimed_roles)` in `scripts/credit_review/policy.py`, which
  also owns `hold_causes`, `never_asked_cause`, the cause classes and the bands read;
  `scale_drain` imports them. Where it is applied:

  | Audience | How | Counter |
  |---|---|---|
  | drain, refused approve | `core_refusal_route` (above) | `held_by_core`, `hold_note` |
  | drain, ladder `ask` row | `plan()` keeps the causes on `ask` rows too; `asks --plan` drops a held row (`split_asks`) | `held_never_asked`, `held_by_class` |
  | `uvn_status` (uvn-status, gap-ask, uvn-new-rows) | the request is `NEVER_ASKED`, one of `NO_ASK`; it outranks the approval path and the proof-required override | `never_asked` |
  | `need_asks.build` and its send-time read | a held request is left out of the list, the drain wait list and the payload | `skip_never_asked`, `skip_never_asked_<class>`, `drain_asks_never_asked` |
  | `claim_proof_ask`, first note and reminder | by USER: any undecided request of the claimant (`user_verification_needed` or `unverified`) under fraud or impersonation, or while the band table cannot be read (`uvn_status.never_ever_users`, classes `policy.NEVER_EVER_HOLD_CLASSES`) | `never_asked` |

  A request can carry several causes and the answer names one: fraud first, then
  impersonation, then the others in name order. The account hold reads the class of that
  one answer, so the order is the rule, not a display choice: named by name order alone,
  an impersonation finding beside `reject_publisher_label_credit` read as `band_c` and the
  claimant was not held.

  A held request is not locked, closed or tagged: it is read again on every run, so a
  hold that lifts is asked then. A verdict nobody can read names no cause and is asked as
  before; a bands table nobody can read holds every request. A plan written before ask
  rows carried causes offers its ask rows as before, so build a new snapshot and plan
  after this deploys. Not changed: status notes (`status-*`, `claim-status`) are not asks
  and still name the request; the claim sender holds on fraud and impersonation only,
  because another band C cause is about one credit and says nothing about a claim, and,
  like every other sender, it holds every claimant while the bands table cannot be read.
  A claimant with no undecided credit request is still asked.
  `doc-result` is not a sender in this repo: the 37 `doc-result-1` messages of 2026-11-11
  came from `/root/doc_result.py` on node-8, a one-off that posts to Intercom directly
  with no send gate and no copy gate, on no timer. It reads none of this; if it is run
  again it must go through a repo sender first.
  Why: read from the verify ledger 2026-11-14 12:57Z, 26 of the 480 users with an
  impersonation-flagged pending request were sent a verify message between 10 and 14
  November (22 by uvn-status, 3 by that one-off, 1 by proof-need-ask); 8 of the 23 asks
  named a flagged request. None of the 22 fraud-flagged users was sent one. Exposure
  measured from the core replica 12:46Z: of 101,415 pending requests (8,245 users), 13,157
  (1,319 users) carry a non-velocity band C cause or a fraud hold, and 3,266 of those were
  in that day's `need_asks` audience.
  Projected with this code against production, read-only, 2026-11-14 14:16Z and 14:33Z
  (nothing was sent, and it is not a measurement of a deployed run): `need_asks.build`
  named none of the 3,443 fraud- or impersonation-flagged undecided requests (1,566 and
  1,877; 500 users) and listed none as a wait, leaving 8,136 held requests out
  (`skip_never_asked`: 4,229 velocity, 2,155 other band C, 1,058 fraud, 584 impersonation,
  76 already held, 33 unmeasured, 1 legal); the uvn-status read marked every flagged
  request it saw `never_asked`; and `never_ever_users` held 500 of the 500 flagged users.
  2,303 of those 3,443 requests are `unverified`, not `user_verification_needed`, which
  is why the account hold reads both statuses: read from `user_verification_needed` alone
  it held 242 of the 500.
- **`--max-writes N`** is the most API writes one run may start. This is the bounded
  batch: `--max-writes 25 --report batch.jsonl` gives 25 rows with request, user and result.
- **The breaker** stops the run after 10 failed writes in a row with no success between
  (`--breaker`, `stop_reason: breaker`). One layer failing every row is a broken path.
  A row core judged and refused on its own facts (`core_row_refused`) does not count:
  core answering "not this row" 20 times and granting 5 is the path working.

`apply` exits 1 only when something is left undone by a failure: an error, a stop
(`stop_reason`), or an unread intent. It always says why in one stderr line
(`APPLY INCOMPLETE: {...}`). A **held** row is not an incomplete run - the API judged it
and nothing was written - so it is printed in the stats and `apply` exits 0: `refused_held`,
`refused_to_ask` (waiting on the ask path), and `held_by_core` (the run that met core's
refusals; `errors` stays 0 for those, while a missing registration is still an error and
still exits 1). `failures --ledger L` counts what is still not written by layer,
status, error code and reasons, and separates the rows waiting on an ask from the held
ones; `--rows` lists every row.

#### Why the approve bucket never landed

Measured 2026-11-13, not inferred:

- **The 11 November run never reached the API.** The wrapper's result log for that day
  holds no drain write. The intents were planned at 18:41Z and
  `/etc/hydra/scale-drain.token` is dated 19:05Z, so the writer most likely stopped at the
  `token` layer before spawning anything - but that run kept no record, which is the
  defect above, so this is the reading that fits and not a measurement.
- **With the token in place the API refuses.** The first real approve (00:38:08Z, requester
  `scale-drain@hydra-ops`, anchor verified, wrapper gate passed):
  `PUT /admin/credit-requests {"requestIds":["000decc0-…"],"status":"approved"}` →
  **HTTP 400** `agent_cannot_approve_declined`, reasons
  `validator_not_approved, no_registered_automation`, "nothing was written". A second row
  answered `proof_required, validator_hold, high_risk_score, validator_band_hint`.
- **Why.** core-backend `src/services/credit-requests/agentApprovalGuard.js` lets an agent
  token approve a validator-declined or proof-required row only as a registered
  automation: an `X-Credit-Automation-Id` header, listed in `AUTOMATION_APPROVAL_SCOPES`,
  bound to the token's account, on a row inside that automation's scope. It registers
  four (`uvn-under30`, `credit-trust-decide`, `credit-trust-score-approve`,
  `fable-decider`). The drain was none of them and the wrapper sent no header for it. The
  hydra registry row (`verification-scale-drain`, `approved: true`) is hydra's gate only.
- **How many are approvable now: 0 of 3,326.** All 3,326 were still pending at 02:51Z
  (683 users). Applying the guard's rules to each row's `verificationdata` on the replica:
  2,775 need the claimant's own proof (risk at or above 100, a band hint other than A, a
  `review_*` hold, or proof already requested), which no registered scope lifts except
  for a validator-approved low-risk row; 551 are validator-declined with no proof flag
  and need a registered automation. That count is this repo's re-read of the guard's
  rules, not core's own answer for each row.

So the fix was not in this repo. Ruled 2026-11-13 (firstmate `[key=drain-approve-core-guard]` = A):
core registers the drain as its own automation, on its own account, under a scope the server
judges for itself. Widening the claimant-proof rule was rejected.

#### The precedent scope (core-backend #11378 on develop, #11379 on master)

core registers `verification-scale-drain` with scope `precedent`, bound to
`agent-scale-drain@muso.ai`. It admits a validator-declined row only when core itself finds:

- the track is known small (server-read popularity 1 to 59, not client-sourced) and no
  current `reject_*` rule fired;
- the same user already holds an approved request for the same profile, track and role
  set, and that approval is one core stands behind: it passes today's rule on its own
  stored verdict, or it was approved before 2026-05-18, or a named human approved it since
  the 2026-10-11 guard. An approval that rests only on the inverted batch rule (05-18 to
  10-11) is not a precedent;
- no removal is on record for that profile and track.

The request names no precedent. core finds it, re-reads it inside the approving UPDATE
(holding a row lock on it, so a take-back that commits mid-write is seen) and records the
request it stood on in `metadata.approval.precedentRequestId`. A row that needs the
claimant's own proof is refused before the scope is read.

Measured against the replica 2026-11-13 14:09Z, by this repo's re-read of that rule and
not by core's answer: **400 of the 3,326 (152 users)** would be admitted. The rest: 2,775
claimant proof, 78 inverted-window precedents only, 42 big tracks, 36 popularity 0, 16
no same-profile precedent, 1 removal (the last five overlap).

**This repo's half.** An approve sets `MUSO_ADMIN_IDENTITY=scale-drain`, so the operations
wrapper signs in with `/etc/openclaw/agents/scale-drain.env` and sends
`X-Credit-Automation-Id: verification-scale-drain`. The header goes out only with
`SCALE_DRAIN=1`, the drain's requester, that identity, and `PUT /admin/credit-requests`.
The `skills-all` wrapper copy has no identity loader and
sends no automation header for anyone, so it is unchanged.

**Order, and what does not exist yet.** Nothing approves until all of these are true:

1. both core PRs are merged and deployed;
2. the account `agent-scale-drain@muso.ai` exists in core with the `credit-automation` role;
3. `/etc/openclaw/agents/scale-drain.env` is on node-8 (from Vault, as H-DevOps #4131 does
   for the other three identities). On 2026-11-13 16:18Z that directory held
   `credit-decider.env`, `fable.env` and `uvn-cron.env` only;
4. this repo is deployed.

Before step 3 the wrapper stops every approve at the identity file (layer `wrapper`, no
request sent). Never point the drain at another automation's account or header: an
approval borrowed that way is recorded under a scope that never judged it.

### 4. Read wide, write ordered

The decision pass is read-only and safe to run 32 wide. The apply is a write: a bounded
pool of 6 against the same API, with the ledger serialised under one lock and the API
writer running outside it.

## Running it

On the hydra host (the only place with the admin API):

```bash
# build the snapshot from the core replica (one query for the whole population)
python3 -m credit_review.scale_drain snapshot --out /var/lib/hydra/credit-review/snap.jsonl

# the dry-run decision pass (read-only)
python3 -m credit_review.scale_drain plan --snapshot snap.jsonl --out plan.jsonl

# the apply (idempotent, resumable). Start with a bounded batch and read its report.
python3 -m credit_review.scale_drain apply --plan plan.jsonl \
  --ledger /var/lib/hydra/credit-review/drain.sqlite \
  --max-writes 25 --report batch.jsonl

# what is still not written, and why (layer / HTTP status / API error code / reasons)
python3 -m credit_review.scale_drain failures --ledger /var/lib/hydra/credit-review/drain.sqlite

# prove it: duplicates and orphans. `verify` counts as an orphan EVERY applied key the
# plan it is given does not name, so its count is meaningful only for the plan that was
# applied. On the production ledger that set includes at least the 1,324 queue_tier2 rows
# applied on 2026-11-11 and the 3 proof_verdict / reject rows applied on 2026-11-14: no plan
# this code makes can name them (the ladder emits cannot_confirm for an expiry or a refuse
# precedent and ask for a refuse verdict, and the outcome is part of the decision key), so
# the drain's own rows have to leave it. That is a FLOOR, not an expected count - any other
# applied key absent from the plan you replay from is in it too. `verify` has not been run
# on the production ledger, so the real count is not measured. On a scratch ledger built
# and applied by the same pass, expect zero.
python3 -m credit_review.scale_drain verify --plan plan.jsonl --ledger …

# kill -9 every worker mid-pass, restart, prove identical final state
# chaos takes NO --ledger and makes its own scratch SQLite in a fresh temp dir.
python3 -m credit_review.scale_drain chaos --plan plan.jsonl --kill-after 500

# the one number: seconds per request
python3 -m credit_review.scale_drain bench --snapshot snap.jsonl
```

`plan` writes canonical JSONL: sorted by `request_id`, sorted keys, no timestamp, no run
id, no shard number. That is what makes "run it twice, diff the bytes" a real test.

### A bounded snapshot (`snapshot --max-rows N`)

The full replica snapshot reads the whole decided population (5,559,206 rows on
2026-11-13) to derive precedent, which is too much to hold in memory for a rehearsal on
node-8. `--max-rows N` bounds it:

- the pending read asks the replica for at most N rows. The statement has no order, so
  which N is the replica's choice and two bounded snapshots are not the same rows;
- the decided read is **filtered**, not cut: every decided request on the tracks those N
  rows claim, 200 tracks a statement, plus the decided requests they name as their
  duplicate, by id. A claim key holds the track, so those are all the decided rows that
  can set a precedent for the N rows. The plan decides each of them as the full plan
  would;
- N counts pending rows. The decided and precedent rows are written after them and are
  not counted against it. The summary line carries `"bounded": N`.

There is no `LIMIT` on a decided read, and there must never be one (pinned by
`ReplicaSnapshotTests` in `scripts/tests/test_scale_drain.py`). A decided population
cut short does not only lose approvals: a claim rejected once and approved later reads as
**refused** when the cut falls between the two, and the plan records it as
`cannot_confirm` (`precedent_refuse`) instead of approving it. A decided request
read only as a duplicate target sits on a track whose other decisions
were not read, so it is carried as a decided row and sets no precedent. A track id that
is not a UUID stops the run when its statement is built, before that statement is sent;
a duplicate target that is not a UUID names no request and is simply not read.

Measured on node-8, 2026-11-14 19:50Z: 400 pending rows in 2.1 s, their 388 tracks in two
statements of 2.2 s and 2.1 s returning 162 decided rows, 22 MB resident. Without
`--max-rows` the two statements are the ones above, unchanged.

### What `apply` needs, and what it says when a write fails

`apply` writes through `muso-admin-api.sh`, and the wrapper refuses every `call`/`call-batch`
without `MUSO_API_URL`, `MUSO_ADMIN_EMAIL` and `MUSO_ADMIN_PASSWORD`. `MUSO_ADMIN_IDENTITY`
does not stand in for them: the wrapper loads that account only on `login|call|upload`, while
the verifier's anchor read and the read-back both go through `call-batch`, which loads no
identity. A login shell on the host does not carry the env. On
2026-11-11 `apply` was started from such a shell: it recorded 3,326 approve intents, every
write died in the wrapper's `check_env` before the gate ran, and the summary said only
`errors`. Those intents are still `planned` in the ledger; none was granted.

So `apply` now asks once, before it records an intent, whether this process can write at
all (`admin_preflight`: the admin env, the approve's identity file when an approve is left,
the token file, the kill file, the wrapper). A miss
prints one `PREFLIGHT <class>: ...` line per cause and exits 2 with nothing recorded. It
reads no secret and calls nothing, so it cannot tell a wrong credential from a right one;
a wrong one fails at the first write, which stops the run instead of repeating itself.

Every failed write carries a class, and the summary counts them in `error_classes`:

| class | whose failure | what it means |
| --- | --- | --- |
| `admin_script_missing`, `admin_env_missing`, `drain_token`, `drain_kill_file` | the run | preflight found it: `apply` exits 2 with nothing recorded |
| `drain_registry` | the run | the wrapper's registry check refused mid-run; `apply` stops (`stopped_reason`) |
| `anchor_unverified`, `drain_gate_refused`, `approve_gate_refused` | the row | the wrapper's gate refused this write; nothing reached core |
| `core_automation_not_registered` | the row | the write passed hydra's gate and **core** refused it (`agent_cannot_approve_declined`) with the reason `no_registered_automation` |
| `core_row_refused` | the row | the same code with the row's own reasons (`no_sound_precedent`, `not_known_small`, `proof_required`, ...): core judged the row. Recorded as `refused_by_core:<reason>`, counted in `held_by_core` (not in `errors`), never by the breaker, and routed by that reason: `proof_required` / `no_sound_precedent` go to the ask path (`refused_to_ask`) - also beside `validator_hold`, unless a hold keeps the row (`hold_blocks_ask`, `refusal_hold`, `never_asked_cause`, recorded in `hold_note`). WHICH causes hold, and each named, is owned by "On the refusal route, a band C cause is never asked" above; it is not repeated here. Everything else (an unnamed reason) is held. The route has one source, the recorded `core_refusals` row: a refusal whose route could not be recorded is held, never reported as waiting on an ask, and STOPS the run (`stop_reason` `ledger`) so no later approval is sent while its refusals record nothing |
| `http_error`, `wrapper_failed`, `writer_exception` | the row | any other non-2xx or crash |
| `unreconciled`, `ledger_error` | the row | an open intent could not be read back, or the ledger refused |

`core_automation_not_registered` is not a retry. core lets an agent token approve a row
its validator did not approve only for an automation registered in **core's own** table
(`AUTOMATION_APPROVAL_SCOPES` in core-backend `agentApprovalGuard.js`), bound to the admin
account the call logged in as and named in the `X-Credit-Automation-Id` header. hydra's
`verification-scale-drain` registry entry and `/etc/hydra/scale-drain.token` satisfy the
wrapper's gate and are never sent to core. The drain's half is in this repo: the approve
signs in as `MUSO_ADMIN_IDENTITY=scale-drain` and the operations wrapper sends
`X-Credit-Automation-Id: verification-scale-drain` for it. core's half is the `precedent`
scope (core-backend #11378, with #11380 and the master twin #11379) and the account it is
bound to; until both are deployed and the account exists, core answers
`no_registered_automation`. The preflight also asks for
`/etc/openclaw/agents/scale-drain.env` when an approve is left to make
(`admin_env_missing`): the wrapper refuses a missing identity file before any request and
there is no fallback account. The verifier's read and the read-back still sign in with the
admin env, so an approving run needs both.

A global flag goes **before** the command. `call PUT <path> '<body>' --evidence-excerpt X`
was once read as a call with no excerpt, and the gate answered "--evidence-excerpt is
required" to a caller that had passed it. The wrapper now refuses a flag after the body by
name (`scripts/tests/muso-admin-api-trailing-flag.bats`).

### Reading the plan before you apply it

The plan is the whole forecast, so the numbers that matter are one `jq` away:

```bash
# what the pass actually does, by outcome and reason (`plan` prints the same as by_reason)
jq -r '"\(.outcome)/\(.reason_code)"' plan.jsonl | sort | uniq -c

# how many rows the ladder cannot confirm (recorded only: no write, no message)
jq -r 'select(.outcome=="cannot_confirm") | .reason_code' plan.jsonl | sort | uniq -c

# how many rows carry a fact the ladder could not resolve (counted, never written, never asked)
jq -r 'select(.outcome=="unmatched") | .request_id' plan.jsonl | wc -l
```

A request whose `duplicate_of` points at a request that is not decided is **not** asked:
it is `unmatched` (`unmatched_duplicate`), and `apply` counts it and writes nothing. One
that points at a decided request is decided by the rules below `duplicate`.

## The one reviewed ask path

`verify-ask-wiring-h2` (hydra PR #1845, `scripts/credit_review/need_asks.py`) and this
work touch different files in the same domain. The reconciliation is that there is
**exactly one reviewed ask/notify path, and it is `need_asks.py`**:

- the drain decides **who** is asked: the ladder's `ask` rows plus the rows core refused
  back onto the ask path, emitted together as one audience by
  `scale_drain.py asks --plan PLAN --out FILE`;
- `need_asks.py build --from-drain AUDIENCE` takes that audience and still decides **which
  document** each ask names, and still owns the send through
  `intercom-verify-request.sh --campaign proof-need-ask` (the copy lock, the go-live
  guards, the send-time `comm_state` read).

A drain ask with no sendable document is listed as `wait:no_sendable_document` with a
`due_at`, never dropped. A drain ask with no user id is refused loudly. The drain grows
no second sender.

## Definition of done, and where each part is proven

| Criterion | Proof |
|---|---|
| 1,000-row dry run produces decisions, twice byte-identical | `test_scale_drain.ByteIdenticalTests` (in-process **and** two separate processes) |
| full 92,861 pass under 90 minutes | `test_scale_drain.ScaleTests` pins the decision cost (< 100 ms/request); the wall clock is the API's, measured by `bench` and `snapshot` stats on the host |
| zero duplicate sends, zero orphans, re-run byte-identical | `ApplyTests` + `verify` |
| `expires_at` exists; a refusal names its reason code and is told once | `ExpiresAtTests`, `ToldOnceTests` |
| an unasked request is asked, never expired | `UnaskedIsAskedTests` |
| apply performs a real API side effect through the reviewed path | `ReviewedWritePathTests` |
| chaos: `kill -9` every worker, restart, zero duplicates/orphans, two kills identical | `ChaosTests` + `chaos` subcommand |
| tail: p95 under 1 hour proof-received → user told | the tail is `need_asks.py send` on the outbound tick; the drain's `ask` rows are its audience |

## Guardrails

- **Never lower a served number.** The ladder only approves on
  precedent or a verdict, records an expiry or a refuse precedent with nothing newer on file as
  `cannot_confirm`, or asks. It
  never reduces a credit.
- **The idempotency key is the proof against a duplicate send.**
- Major-label/publisher check before any removal or ban; no legal letters; a GDPR reply
  is the removal list scoped to the requested window and nothing else.

## Repos touched

- **hydra** — `scripts/credit_review/scale_drain.py` (the ONE CLI: `snapshot`, `plan`,
  `apply`, `verify`, `chaos`, `bench`), `scripts/credit_review/batch_admin.py`,
  `scripts/credit_review/need_asks.py` (`--from-drain`), `policies/credit-approval-automation.json`
  (the `verification-scale-drain` entry), `scripts/check-credit-approval-automation.sh`,
  tests, this doc, `data/verification-scale-plan.md`.
- **H-DevOps** — `muso-admin-api.sh` `call-batch` (the hoist) and the tick units that run
  the drain. The wrapper change is mirrored in both in-repo copies
  (`skills-all/muso-ops-admin/…` and `workspaces/operations/skills/muso-ops-admin/…`) and
  `scripts/check-admin-api-gate-parity.sh` still passes.
