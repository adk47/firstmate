# The paid-band ask lane (captain r4 GO 3, firstmate 413)

Status: **builder shipped, nothing sent by it.** The send path stays the existing `uvn-status` campaign.

## The gap it closes

On 2026-11-11 the score-approve band (validator-approved, `total_risk_percent < 30`, `band_hint` A/B, stored
popularity 1–59, no proof ask or only the `validator_band_hint` stamp) held **5,782 rows / 1,593 users**, of which
**2,763 rows / 772 users were paying customers**. Measured on the core replica and node-8's verify ledger:

| fact | measure |
|---|---|
| band rows whose status is `unverified` | **0** — every band row is `user_verification_needed` |
| paid band rows with **no** core `metadata.proofRequest` | 1,655 rows / 476 users |
| …of those rows ever appearing in the decider ledger at all | 207 (support 65, hold 20, defer 170, approve 1) |
| …of those 476 users ever receiving any Intercom message | 188 (≈70 ever asked for proof; **288 never told anything**) |
| decider `approve` rows written in the 24h to 2026-11-11 | **0** (last approve ever 2026-10-26T23:10Z) |

Two structural reasons, both verified in code:

1. `decide.held_rows()` pages `list_requests(status=UNVERIFIED)`. Every band row is `user_verification_needed`, so
   the **decider's support/ask lane cannot reach a band row** — not a cap problem, a candidate-source problem.
2. The lane built to tell `user_verification_needed` users (`uvn-status`, `owing_proof`) is bounded per run and
   carries the shared one-ask-per-user-per-90-days lock, so an untouched cohort starves unless someone names it.

So for those ~474 users the captain's rule — *every request ends approved or the user is told* — failed in both
directions: not approved (`approve_arm: false`, score-approve cron disabled) and not told.

## What ships

`scripts/credit_review/paid_band_ask.py` (read-only): takes `owing_proof`'s signed build (the never-told +
owes-proof audience the `uvn-status` gate already consumes), keeps only the users who carry band rows, and caps the
list. It re-signs the facts header for exactly the users kept, so `owing_proof.verify_facts` still passes at send
time.

Bounds — none of them a new switch:

- **Row predicate** (`BAND_SQL`): `status = user_verification_needed`, `deletedat IS NULL`, `is_approved`,
  `total_risk_percent < 30`, `band_hint IN ('A','B')`, `spotifypopularity BETWEEN 1 AND 59`,
  `metadata.proofRequest IS NULL`.
- **Cap**: `max_ask_users_per_day` from `policies/credit-trust-decide.json` (**400** distinct users/day, one knob
  shared with the decider). Unreadable, malformed or ≤ 0 is a **refusal** — nothing is listed. `--max-users` may
  lower the cap, never raise it.
- **Paid only** by default; paid first, oldest owed request first.
- A user already asked (sent `uvn-status`) or holding a core `proofRequest` is out of the `owing_proof` build
  already, so this lane can never re-ask them.
- It names **users**, not rows: one ask per user, ever, so the note names the user's owed rows.

## Operating it

```bash
# dry run: counts only, writes nothing (re-reads the replica)
PYTHONPATH=/opt/hydra/scripts python3 scripts/credit_review/paid_band_ask.py --dry-run

# build the day's list, then send through the existing campaign (its copy, gate, ledger and caps)
python3 scripts/credit_review/paid_band_ask.py --out /var/lib/hydra/credit-review/paid-band-ask-$(date -u +%Y%m%d).json
python3 scripts/credit-review.py uvn-status --campaign uvn-status --list <the file> --max-users 400 --dry-run
```

Measured on prod 2026-11-11 (`--dry-run`, after the never-told and 90-day-lock filters): **201 candidates, 201
listed, 0 deferred, 7 users dropped by the sender's own 90-day ask lock** (1,017 users carry band rows at all). The
cohort fits inside a single 400-user day, so it completes on the first run — inside the captain's ~1.2-day
expectation with room to spare.

## Two filters that are load-bearing (QA 1886)

`class == "uvn"` — `owing_proof` also lists a `uvn_new_rows` follow-up class (already asked, but rows no ask named),
and `uvn-status` drops those as `already_sent` before spending budget. Counting them would spend the 400-user cap on
messages that never leave and make any drain estimate false. The never-told class is the whole cohort: excluding
the follow-up class moved the audience from 474 names to 201 reachable users.

The sender's 90-day lock (`verify_ledger.asked_within`, the same function the sender calls) is applied at build
time, so a listed name is a name a message can actually reach.

## Why the build read is batched

`owing_proof.REPLICA_SQL` streams every non-terminal credit request (77k+ rows). Unnarrowed, and even narrowed to
the whole cohort in one `IN` list, it is killed by the cluster's statement timeout (486s measured). The build is
therefore restricted to the band users and read 100 users at a time: 50 ids answer in ~5s, the full 1,017-user
cohort answers in **~1m47s**. `owing_proof.verify_facts` compares per listed user, so restricting the read yields
the same list — the test that re-signs and re-verifies through `verify_facts` pins that.

## What this is not

Not an approval path. `approve_arm` stays `false`, `credit-trust-score-approve-15m` stays disabled, and
`/etc/hydra/credit-trust-decide-provisional-paid.disabled` is untouched. The GO-1 band gate still lives in
https://github.com/Muso-AI/hydra/pull/1368 and prod still has no `backup_level` in
`scripts/credit_review/decide.py`.
