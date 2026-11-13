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

**So this pass approves 3,294 requests, queues 1,324 for a named human, and leaves 91,229
as asks. It is not a pass that decides the backlog**, and an `ask` row is not a decision:
`apply` writes nothing for it. Two rules are zero for different reasons:

- **`expired` is genuinely zero today.** The earliest ask on record is 2026-10-24, so the
  first 30-day window closes on 2026-11-23.
- **The `duplicate` rule's request-id predicate matches nothing in production.** No
  pending row carries a request id in `verificationData.duplicate_of`: the only non-null
  values are 856 maps of `{"<track uuid>|<role>": "<credit id>"}`, the credits already
  on the profile. `close_duplicate` therefore closes nothing on this data. The
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
- the **decided** population (`approved` / `rejected`), which is both the duplicate index
  and the source of precedent;
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
  - any role whose newest verdict is a refusal → `refuse` (queued for a human);
  - every claimed role's newest verdict an approval, all on ONE proof → `approve`,
    anchored on that proof. Each claimed role needs its **own** claim: a verdict keyed by
    the bare request id names no role and does not stand in for one (production has no
    such row; honouring one would make it the single row that approves any role set);
  - anything else → no verdict, but **`proof_received_at` is still set**. That row stays
    an `ask` with reason `proof_on_file_undecided`, and can never become
    `expired_no_proof`: a user who sent a document is not refused for sending none.

  An `ask` row sends nothing by itself. `need_asks.py --from-drain` asks only a user
  whose latest doc-verify outcome names a specific sendable document, and lists everyone
  else as `wait:` or `skip:` — so `proof_on_file_undecided` is the population the
  reviewed ask path exists for, not a re-ask of documents already sent.
- **`duplicate_of` is classified, not trusted to be a request id**
  (`classify_duplicate`). A string is the request id it claims to be. The production
  map means "already a credit on this profile": the row keeps rank one, comes out
  `unmatched` / `already_on_profile`, and is neither written (there is no decided
  original for the gate to verify) nor asked (the same call `uvn_status.ask_class`
  makes). Bound raw, that map crashed the whole plan.

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
| 1 | `duplicate` | `duplicate_of` names a request that is already decided | close | `duplicate_of_decided` |
| 2 | `precedent` | `precedent_key` has a recorded outcome | approve / **queue for tier-2** | `precedent_match` / `precedent_refuse` |
| 3 | `proof_verdict` | a readable verdict (`approve`/`refuse`) exists | approve / **queue for tier-2** | `proof_verdict_approve` / `proof_verdict_refuse` |
| 4 | `expired` | **asked** (`asked_at` set), `expires_at <= now`, no proof received | **queue for tier-2** | `expired_no_proof` |
| 5 | `ask` | nothing matched | ask | `no_rule_matched` |
| — | `unmatched` | a row carries a fact the ladder cannot resolve (an undecided duplicate original, an unmapped proof verdict, a precedent row with no outcome, an approve with no anchor) | **none: counted, never written, never asked** | `unmatched_duplicate` / `unmatched_precedent` / `unmatched_proof_verdict` |

A model reviews a sample and proposes rule changes; it never decides a single row
(Aaron's 2026-10-29 ruling). A fact the ladder cannot resolve is not a decision **and
not an ask either**: a row that was already decided by precedent must never be turned
into a fresh "please verify" ask to that user. Such a row gets the `unmatched` outcome,
`apply` does not write or commit it, `verify` lists it, and the CLI prints the count.
The two rules are separate on purpose: `ask` means "no fact, and asking is the right
action"; `unmatched` means "a fact is present but unreadable, so this needs a human".

**Expiry may only refuse a request we actually asked.** A never-asked request falls
through to `ask`, because the 23,247 OPEN_UNASKED rows are the drain's population, not
its refuse pile, and refusing a customer we never asked is a customer-facing denial we
do not do. `expired_no_proof` is the reason code for the asked-and-expired case only.

A precedent carries its own outcome: an `approve` precedent approves, and a `refuse`
precedent is queued for a named tier-2 approver (`precedent_refuse`) rather than being
rejected autonomously. The ladder selects the row; `_resolve` makes the row's verdict
binding. `queue_tier2` rows are committed to the ledger and listed by `tier2-queue`; they
are not asks, so `need_asks.py` never sends to them.

### The split: duplicate closes are autonomous, refusals are not

These two outcomes look alike at the API — both write `status:"rejected"` — and they are
**not** the same thing (captain decision 2026-11-11).

**A duplicate close is autonomous.** A duplicate of an already-decided request is not a
new decision: the original decision stands and the customer's outcome is unchanged, so
closing it is deduplication, not a denial. It goes through
`PUT /admin/credit-requests/conditional-status` with
`EVIDENCE_EXCERPT=drain-dup:<original-request-uuid>;<reason>;v<n>`, and the wrapper's
`is_scale_drain_duplicate_close` refuses the write unless that digest names a UUID. The
ladder only reaches the `duplicate` rule when `duplicate_of` points at a request that is
already decided, so the original is provable, and the ledger row carries `duplicate_of`.
The close is audited exactly like a human reject, with the original request id as the
approval reference.

**A refusal is not autonomous.** Expired-with-no-proof, a `refuse` proof verdict and a
`refuse` precedent are customer-facing denials, and the wrapper is right to demand a tier-2 approver for them.
The drain does not add a bypass: those rows get the `queue_tier2` outcome, no API write
happens, and the ledger records the reason code. `tier2-queue` lists them for a named
human, who runs the wrapper with `--confirmed-by` and `--approval-msg-id` — the drain
never supplies those, because supplying them would be the bypass.

```bash
python3 -m credit_review.scale_drain tier2-queue --ledger /var/lib/hydra/credit-review/ledger.sqlite3
```

Never lower a served number, and never deny a customer autonomously.

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
that CHANGES keeps its key and `apply` skips it: a refusal queued for a tier-2 approver that
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
| `close_duplicate` | `rejected` via `conditional-status`, with a `drain-dup:` digest naming the decided original |
| `queue_tier2` | **no write** — a refusal belongs to a named tier-2 approver (`tier2-queue`) |
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
execution identity at all, while the less consequential duplicate close had one.

Both writes now go through one check, `scale_drain_token_ok`, before the registry or the
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
/etc/hydra/scale-drain.token`), `apply` refuses every approve and every duplicate close
with `…/scale-drain.token is missing`, and writes nothing.

**Cost.** Only approve rows are verified, and the approve population is small: 3,294 of
96,703 on the 2026-11-11 snapshot (the precedent and proof-verdict approves), not the
whole backlog. Measured locally, the verifier's own
overhead is ~26 ms/row (python start + one indexed SQLite read); every verified row -
precedent, proof verdict or duplicate - adds one admin GET. **The end-to-end pass time has not been measured on prod** — this
worktree has no prod access — so no figure is claimed here. The operator's first real run
is what produces it.

##### Duplicate closes: a token AND a verified original

A duplicate close is not an approval, so it does not need the approve gate's evidence. It
needs two things, and it closes **exactly one request per call**: one digest names one
original, and the verifier is handed one target. The predicate used to accept up to 50
ids while verifying only the first, so a real duplicate in front carried every other
pending request in the body to `rejected` - an unexamined customer-facing denial (QA
review 6 of hydra#1883). A second id, the same id twice or an empty list now refuses
before the verifier is consulted; the drain has always sent one id per close.

1. **An execution identity** the caller cannot simply assert: the same token check an
   approval makes (above) - a token file at
   `/etc/hydra/scale-drain.token`, **mode 600, owned by the drain's own user** (root in
   production), whose contents must equal `SCALE_DRAIN_TOKEN`. This **raises the bar** from
   "can invoke the wrapper" to "can read that file". It does **not** make the path
   non-forgeable, and it is not claimed to (captain decision, 2026-11-11).
   **The path is a literal in the wrapper and in the drain.** It was overridable with
   `SCALE_DRAIN_TOKEN_FILE`, which reduced the check to "the caller can write a mode-600
   file and read it back" (QA review 4 of hydra#1883). Setting that variable - to anything,
   including the real path or an empty string - now **refuses** the close, and a
   `SCALE_DRAIN_TOKEN` that is not exactly the pinned file's contents is refused before the
   verifier is consulted. Tests that need a passing close rewrite the literal in a scratch
   copy of the predicate; there is no environment seam.
2. **A verified original.** The `drain-dup:<original>;<reason>;v<n>;<profile>` digest is
   handed to the same verifier, which fetches that profile in one GET and checks the named
   original is **decided** (`approved`/`rejected`) and matches this request on claimant,
   track and claimed roles. The token alone let a caller close an unrelated pending request
   as a "duplicate" (QA review 2 of hydra#1883).

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

# the apply (idempotent, resumable)
python3 -m credit_review.scale_drain apply --plan plan.jsonl \
  --ledger /var/lib/hydra/credit-review/drain.sqlite

# prove it: zero duplicates, zero orphans
python3 -m credit_review.scale_drain verify --plan plan.jsonl --ledger …

# kill -9 every worker mid-pass, restart, prove identical final state
# chaos takes NO --ledger and makes its own scratch SQLite in a fresh temp dir.
python3 -m credit_review.scale_drain chaos --plan plan.jsonl --kill-after 500

# the one number: seconds per request
python3 -m credit_review.scale_drain bench --snapshot snap.jsonl
```

`plan` writes canonical JSONL: sorted by `request_id`, sorted keys, no timestamp, no run
id, no shard number. That is what makes "run it twice, diff the bytes" a real test.

### What `apply` needs, and what it says when a write fails

`apply` writes through `muso-admin-api.sh`, and the wrapper refuses every call without
`MUSO_API_URL`, `MUSO_ADMIN_EMAIL` and `MUSO_ADMIN_PASSWORD` (or `MUSO_ADMIN_IDENTITY`,
which loads the account itself). A login shell on the host does not carry them. On
2026-11-11 `apply` was started from such a shell: it recorded 3,326 approve intents, every
write died in the wrapper's `check_env` before the gate ran, and the summary said only
`errors`. Those intents are still `planned` in the ledger; none was granted.

So `apply` now asks once, before it records an intent, whether this process can write at
all (`admin_preflight`: the admin env, the token file, the kill file, the wrapper). A miss
prints one `PREFLIGHT <class>: ...` line per cause and exits 2 with nothing recorded. It
reads no secret and calls nothing, so it cannot tell a wrong credential from a right one;
a wrong one fails at the first write, which stops the run instead of repeating itself.

Every failed write carries a class, and the summary counts them in `error_classes`:

| class | whose failure | what it means |
| --- | --- | --- |
| `admin_script_missing`, `admin_env_missing`, `drain_token`, `drain_kill_file` | the run | preflight found it: `apply` exits 2 with nothing recorded |
| `drain_registry` | the run | the wrapper's registry check refused mid-run; `apply` stops (`stopped_reason`) |
| `anchor_unverified`, `drain_gate_refused`, `approve_gate_refused` | the row | the wrapper's gate refused this write; nothing reached core |
| `core_automation_not_registered` | the row | the write passed hydra's gate and **core** refused it (`agent_cannot_approve_declined`) |
| `http_error`, `wrapper_failed`, `writer_exception` | the row | any other non-2xx or crash |
| `unreconciled`, `ledger_error` | the row | an open intent could not be read back, or the ledger refused |

`core_automation_not_registered` is not a retry. core lets an agent token approve a row
its validator did not approve only for an automation registered in **core's own** table
(`AUTOMATION_APPROVAL_SCOPES` in core-backend `agentApprovalGuard.js`), bound to the admin
account the call logged in as and named in the `X-Credit-Automation-Id` header. hydra's
`verification-scale-drain` registry entry and `/etc/hydra/scale-drain.token` satisfy the
wrapper's gate and are never sent to core. As of 2026-11-13 core registers no scale-drain
automation and the wrapper sends no such header for the drain, so a precedent or
proof-verdict approve of a row the validator declined is refused there. Closing that is a
registration in core plus a decision on which admin account the drain logs in as; neither
is a change this repo can make on its own.

A global flag goes **before** the command. `call PUT <path> '<body>' --evidence-excerpt X`
was once read as a call with no excerpt, and the gate answered "--evidence-excerpt is
required" to a caller that had passed it. The wrapper now refuses a flag after the body by
name (`scripts/tests/muso-admin-api-trailing-flag.bats`).

### Reading the plan before you apply it

The plan is the whole forecast, so the two numbers that matter are one `jq` away:

```bash
# how many duplicates close on the first pass (0 on the 2026-11-11 snapshot: no pending
# row names a request as its duplicate)
jq -r 'select(.outcome=="close_duplicate") | .request_id' plan.jsonl | wc -l

# what the pass actually does, by outcome and reason (`plan` prints the same as by_reason)
jq -r '"\(.outcome)/\(.reason_code)"' plan.jsonl | sort | uniq -c

# how many rows go to a tier-2 approver instead of being refused autonomously
jq -r 'select(.outcome=="queue_tier2") | .reason_code' plan.jsonl | sort | uniq -c

# how many rows carry a fact the ladder could not resolve (needs a human, never asked)
jq -r 'select(.outcome=="unmatched") | .request_id' plan.jsonl | wc -l
```

A duplicate whose `duplicate_of` points at a request that is not decided is **not** a
duplicate by this ladder and is **not** asked either: it is `unmatched`
(`unmatched_duplicate`), because there is no standing decision to deduplicate against and
the user was already decided once. `apply` counts it and writes nothing.

## The one reviewed ask path

`verify-ask-wiring-h2` (hydra PR #1845, `scripts/credit_review/need_asks.py`) and this
work touch different files in the same domain. The reconciliation is that there is
**exactly one reviewed ask/notify path, and it is `need_asks.py`**:

- the drain's ladder decides **who** is asked (its `ask` rows);
- `need_asks.py build --from-drain PLAN` takes that audience and still decides **which
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

- **Never lower a served number.** The ladder only closes duplicates, approves on
  precedent or a verdict, queues an expiry or refusal for a named human, or asks. It
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
