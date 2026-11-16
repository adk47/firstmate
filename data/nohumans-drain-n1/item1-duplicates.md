# Item 1: a duplicate is never closed

Read and measured 2026-11-15 09:37Z to 11:58Z. node-8 and core's replica were read only;
nothing was written to either.

## What the drain did

A request whose `verificationData.duplicate_of` named an already-decided request was
planned as `close_duplicate` and written as core `rejected`, through
`PUT /admin/credit-requests/conditional-status` and a wrapper predicate of its own
(`is_scale_drain_duplicate_close`).

## The four questions

**Does core notify on a move to `rejected`? Yes, always.**
`src/apis/_admin/credit-requests/updateStatus.js` calls
`executeNotificationProcedure(creditsRejected, creditRequestsRejected)` for every request
that moves to `rejected`. `creditRequestsRejected`
(`src/services/credit-requests/events/index.js`) sends the `CREDIT_REQUESTS_REJECTED`
event with a link to the customer's rejected submissions. The caller cannot switch it
off: `parseNotifyFlag` (`src/services/credit-requests/revalidateNoNotify.js`) answers 400
to `notify: false` on a move to `rejected`. The one suppression is a per-profile
notification preference, which hydra cannot set. Read at core-backend `51c55906d7`.

**What does the status enum offer? Nothing quieter.**
`pending`, `processing`, `unverified`, `approved`, `rejected`, `user_verification_needed`
(`src/models/credit-requests.js`). There is no duplicate or closed status.

**How is `precedent_outcome` derived? From core's `rejected` rows.**
`DECIDED_SQL` reads every request with `status IN ('approved', 'rejected')`. A claim
(claimant, track, roles) with an approved request is an `approve` precedent; a claim with
only rejected requests is a `refuse` precedent, dated by the newest `updatedat` among
them. A close written as `rejected` is one of those rows. On the next snapshot it is the
claimant's own refusal of the claim, dated the day of the close, and that date is what
later evidence must postdate to set the refusal aside.

**`SELECT status, count(*)`, and how many rows the close touched: none.**

| measure (core replica, 2026-11-15 09:37Z) | count |
|---|---|
| requests in `rejected` | 180,602 (13,455 users) |
| of those, with a `duplicate_of` value | 2, both a map |
| requests in any status whose `duplicate_of` is a request id | 0 |
| `approved` with a `duplicate_of` map | 12,723 |
| `user_verification_needed` with a `duplicate_of` map | 856 |
| claims with only rejected requests | 143,082 (168,055 requests) |
| claims with both an approved and a rejected request | 10,789 |

`duplicate_of` is a map of `{"<track>|<role>": "<credit id>"}` wherever it is set, never a
request id, so the close matched no row. The drain's ledger on node-8 agrees
(`/var/lib/hydra/credit-review/drain.sqlite`, 11:58Z): `applied` holds 91,071 `ask`,
1,324 `queue_tier2` and 3 `reject` rows and no `close_duplicate`; `intents` holds 3,326
planned approves and nothing else. No customer was told "rejected" by this path.

## What changed

- The ladder has no close. A request that names a decided original falls through to the
  rules below `duplicate`: an approved original of the same claim approves it on
  precedent, a refused one holds it at `cannot_confirm` until newer evidence is on file.
  The `duplicate` rule keeps only what it cannot resolve (the profile-credit map, an
  original that is not decided), and those rows stay `unmatched`.
- The drain writes `approved` and no other status. `WRITE_STATUS` has one entry and the
  writer refuses any other mapping before the wrapper is spawned.
- `apply` refuses, whole, a plan that still carries `close_duplicate`.
- Both wrapper copies lost `is_scale_drain_duplicate_close`. A `rejected` body from the
  drain's identity now meets the reject gate and is refused there.
- `verify_anchor.py` has no `duplicate` rule and never reconciles a `rejected` request as
  a write of the drain's.

## What the tests show

`DuplicateIsNeverARefusalTests` (`scripts/tests/test_scale_drain.py`) runs plan, apply
and plan again against a fake core that applies a status write, stamps `updatedat` and
records a notice on every move to `approved` or `rejected`. The same scenario on `main`'s
`scale_drain.py` and on this branch, one claimant with a refused request (100), a second
request naming it as its duplicate (1) and a third for the same claim (2), both with a
document filed after the refusal:

| | `main` | this branch |
|---|---|---|
| first plan, request 1 | `close_duplicate` | `ask` / `proof_on_file_undecided` |
| first plan, request 2 | `ask` / `proof_on_file_undecided` | the same |
| status writes | request 1 to `rejected` | none |
| core notices | one `rejected` | none |
| second plan, request 2 | `cannot_confirm` / `precedent_refuse` | `ask`, unchanged |

On `main` the close made request 2 unanswerable: its document was filed before the close,
so it no longer postdated the newest refusal.

All six tests of that class fail on `main`'s `scale_drain.py`. The two wrapper tests
(bats cases 30 and 31, and their two `RealEntrypointTests` twins) fail on `main`'s
wrappers: there, the drain's identity with a valid token and a verifier that says yes
gets a `rejected` through the reject gate.

Suites on this branch: `test_scale_drain` 295, `test_verify_anchor` 125,
`test_need_asks` 154, all passing; 73 bats cases across the scale-drain gate, the reject
gate, the gate probe and call-batch, none failing.

## What this does not do

- It moves no row. No pending request names a request as its duplicate today.
- The 856 pending requests whose `duplicate_of` is the profile-credit map are unchanged:
  `unmatched` / `already_on_profile`, not written and not asked.
- A request held at `cannot_confirm` by its own earlier refusal is still told nothing.
  That is item 2 and item 4.
- Nothing was run against production with this code. The comparison above is a fixture.
