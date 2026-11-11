# Verification at 1,000s per minute — the scale design

Captain, 2026-11-11: "we need to scale that to faster more parallel 1000s a min".
Written by the read-only session; the Fable seat confirms the rulings at dispatch.

## The arithmetic first, because it changes the goal

| Quantity | Number |
|---|---|
| Total requests with a declared state | 92,861 |
| ASKED | 61,228 |
| OPEN_UNASKED | 23,247 |
| DUPLICATE | 6,631 |
| PROOF_RECEIVED | 1,755 |
| Approved by precedent with no asking | 9,465 |

These are the census figures the design started from. Measured against the live sources
on 2026-11-11 the ladder approves 3,294, queues 1,324 for a human and asks 91,229 of
96,703; the duplicate and proof shares above do not survive contact with the real data.
See "What the ladder decides on the real snapshot" in
`docs/credit-verification/scale-drain.md`.

At **1,000/min** the entire 92,861 is done in **93 minutes**. At 100/min it is
15.5 hours. So this is not a throughput problem to be sustained forever — it is a
**one-time drain** that must finish in about an hour and then stay current.

That reframes the work: the goal is not a faster loop, it is **a batch decision
pass over all 92,861 requests**, then a small continuous tail.

## Why it is slow today, measured

The side window measured **1.4 minutes per user** for the route call.
`muso-admin-api.sh` does three round trips per user:

1. token resolve
2. account resolve
3. route

At 1.4 min/user, even perfect batching gives ~1,000/day. The per-user round trip
is the entire ceiling.

## The design — four changes, in dependency order

### 1. Hoist the per-user work out of the loop

- **Token resolve: once per run.** It does not change per user.
- **Account resolve: batched.** One query for N ids, not N queries.
- **Route: batched.** One call for a page of users, not one call each.

This alone takes the per-user cost from 84 seconds to single-digit milliseconds.
Nothing else matters until this is done, because every later optimisation
multiplies this number.

### 2. Decide deterministically, in rank order, without a model

For each request, in this order, stop at the first match:

| Order | Rule | Outcome | Share of the 92,861 |
|---|---|---|---|
| 1 | duplicate of a decided request | close DUPLICATE | 6,631 |
| 2 | precedent match (this claimant already decided for this claim) | approve / queue for a tier-2 approver | smaller than 9,465 |
| 3 | proof received + verdict already computed | approve / refuse on the verdict | 1,755 |
| 4 | expired (no proof by `expires_at`) | queue for a tier-2 approver | the aged tail |
| 5 | none of the above | ask, once | 23,247 |
| — | a present fact the ladder cannot resolve | `unmatched` — counted, never written, never asked | the residual after wiring the real sources |

The facts come from the real sources, not from `verificationData`: `duplicate_of` from
core, precedence from the decided population keyed per claimant on userid + track +
claimed roles (`claim:<sha256>`), and proof verdicts joined from the proof store, newest
verdict per request winning even when it is a soft one. Precedent is never class-level:
one account's approval must never approve a different account, so the precedent
population is materially smaller than the 9,465 class-level figure. A row whose fact
cannot be resolved is `unmatched` and surfaced, never silently converted into an ask.

Every rule is a SQL predicate. No model in the hot path. A model is used only to
**review a sample** and to propose rule changes — never to decide a single row.
That is the captain's 2026-10-29 ruling and it is also what makes 1,000/min
possible: a model call is 1-3 seconds, a predicate is microseconds.

### 3. Shard by id range, one idempotency key per request

- Shard the work into N contiguous id ranges (start with 16, tune to 32).
- Each worker owns a shard for the whole pass, so there is no coordination cost
  per row.
- Every write carries `decision_key = sha256(request_id || rule || version)`.
  A re-run cannot double-apply, and a crash resumes without duplicates.
- Apply is idempotent and resumable: a worker that dies is replaced and skips
  every row already in the ledger.

### 4. Parallelise the read, keep the write ordered

- The **dry run / decision computation** is read-only and safe to parallelise
  hard: 32 workers.
- The **apply** is a write; keep it to a bounded pool (6-8) against the same
  API, and let the read pool run ahead. This is the side window's own Day 3
  note and it is right.

## The target, restated as a checkable line

> The full 92,861-request pass completes in **under 90 minutes** wall clock, with
> zero duplicate sends, zero orphaned requests, and a re-run producing byte-identical
> decisions.

If the pass takes longer than 90 minutes, the per-user round trip is back — that
is the one number to watch, and it is the first thing to instrument.

## What is NOT the bottleneck, so stop working on it

- **Asking.** 7,838 asked → 177 replied (2.3%) → 93 proofs (1.2%) → 0 acknowledged.
  Asking has a 2.3% response rate. Improving the ask cannot move the drain.
- **The model.** 9,465 were approved by precedent with zero asking. The decisions
  are already deterministic; the model is only a reviewer.
- **The email sender.** At 1,000/min decisions, the send is the tail, not the head.

## Guardrails

- Never lower a served number; the never-lower rule still holds.
- No duplicate send: the idempotency key is the proof.
- Major-label / publisher check before any removal or ban.
- No legal letters. A GDPR reply is the removal list, scoped to the requested
  window, and nothing else.
- A refusal names the reason code, and the user is told once.
- Re-runnable: `kill -9` in the middle must leave no duplicates and no orphans.

## Rollout

1. Instrument per-user cost. One number: seconds per request, end to end.
2. Hoist token/account/route. Re-measure. Expect < 100 ms.
3. Run the decision pass on a 1,000-row sample, verify byte-identical re-run.
4. Full pass, 16 shards, read pool ahead of a 6-wide apply.
5. Re-run the whole pass and diff: must be identical.
6. Continuous tail: new requests decided on arrival, p95 < 1 hour.

---

## Compression: 7 days is wrong, and the ordering is wrong

Captain, 2026-11-11: "7 days is too long. you should be able to move quicker."

He is right, and the fault is ordering rather than effort. The 7-day march
serialises things that do not depend on each other and puts the throughput unlock
on **Day 3** when it is the only thing that makes any later day cheap. With the
applier still at 1.4 min/user, Days 2, 4, 5 and 6 all run at 1,000/day — so five
days of the plan are spent waiting on a fix scheduled for the middle of it.

### What the dependencies actually are

```
throughput (hoist token/account/route)  ──┬─> full decision pass (93 min)
decision predicates + idempotency key   ──┘        │
                                                   ├─> OPEN_UNASKED drains
expiry + refuse path ──────────────────────────────┤
                                                   └─> inbound loop becomes the tail
chaos test ── can be written alongside, it tests the two above
```

Only two things are genuinely sequential: throughput before the pass, and the
pass before the tail. Everything else runs in parallel.

### The 48-hour sequence

**Block A — 3 hours, 2 workers in parallel.**
- A1: hoist the token resolve to once per run, batch account resolve, batch route.
  Instrument seconds-per-request before and after. **Exit: < 100 ms/user.**
- A2: the rank-order decision predicates as SQL (duplicate → precedent → proof
  verdict → expired → ask). **Exit: a dry run over 1,000 real rows produces
  decisions, and running it twice produces byte-identical output.**
- These touch different files and do not block each other.

**Block B — 2 hours, 1 worker.**
- Full decision pass, 16 shards, idempotency key per request, 32-wide read,
  6-wide apply. **Exit: 92,861 requests decided in under 90 minutes; re-run is
  byte-identical; zero duplicates.**

**Block C — 3 hours, 2 workers in parallel.**
- C1: `expires_at` column + the refuse path with a reason code. **Exit:
  rejections in 24 h > 0, and every refusal names its code.**
- C2: the inbound loop — proof arrives, verdict computed, receipt sent.
  **Exit: p95 < 1 hour from proof received to user told.**

**Block D — 2 hours, 1 worker.**
- Chaos test: `kill -9` every worker mid-pass, restart, verify zero duplicates
  and zero orphans. **Exit: two clean kills, identical final state.**

**Total: ~10 hours of work, 48 hours wall clock with slack.** Not 7 days.

### What actually sets the floor

- The 93-minute pass is arithmetic, not effort.
- The API is the ceiling: whatever rate `muso-admin-api` will sustain for a 6-wide
  apply. Measure it in Block A and let it size the shard count.
- Nothing else is slow. The rest is code that already has a design.

### The rule for this plan

Do not schedule a day that is waiting on another day's fix. If a step cannot
start until another finishes, they are one step, and the later one runs first if
it is the cheaper and more constraining.
