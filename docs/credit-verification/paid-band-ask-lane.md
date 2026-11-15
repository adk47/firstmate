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
owes-proof audience the `uvn-status` gate already consumes), keeps only the users who carry band rows, drops the ones
the send gate would not ask (`uvn_status.still_owing`, see "The count is an upper bound on what the send gate
sends"), and caps the list. It re-signs the facts header for exactly the users kept, so `owing_proof.verify_facts` still passes at send
time.

Bounds — none of them a new switch:

- **Row predicate** (`BAND_SQL`): `status = user_verification_needed`, `deletedat IS NULL`, `is_approved`,
  `total_risk_percent < 30`, `band_hint IN ('A','B')`, `spotifypopularity BETWEEN 1 AND 59`,
  `metadata.proofRequest IS NULL`.
- **Cap**: `max_ask_users_per_day` from `policies/credit-trust-decide.json` (**400** distinct users/day, one knob
  shared with the decider). Unreadable, malformed or ≤ 0 is a **refusal** — nothing is listed. `--max-users` may
  lower the cap, never raise it.
- **Paid only** by default; the shared send order (`audience_order`): paying at-risk, then paying, then free; the
  oldest owed request first; the user id last.
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
listed, 0 deferred, 7 users dropped by the sender's own 90-day ask lock** (1,017 users carry band rows at all).
**That 201 counted users the send gate does not ask** — see the next section: the old builder said 213 on
2026-11-13, of whom 18 owed proof. The cohort still fits inside one 400-user day; it is an order of magnitude
smaller than the number this section first reported.

## Two filters that are load-bearing (QA 1886)

`class == "uvn"` — `owing_proof` also lists a `uvn_new_rows` follow-up class (already asked, but rows no ask named),
and `uvn-status` drops those as `already_sent` before spending budget. Counting them would spend the 400-user cap on
messages that never leave and make any drain estimate false. The never-told class is the whole cohort: excluding
the follow-up class moved the audience from 474 names to 201 listed users (the pre-2026-11-13 builder's number;
only 18 of the 213 it listed that day owed proof).

The sender's 90-day lock (`verify_ledger.asked_within`, the same function the sender calls) is applied at build
time. It is the last filter this builder applies on its own: the gate's list-side rules are applied too, and its
per-send rules can still hold a listed name (next section).

## The count is an upper bound on what the send gate sends (2026-11-13)

"No core `proofRequest` marker" is not "owes proof". The send gate drops two more kinds of user before it
messages anyone, and until 2026-11-13 the builder applied neither, so `candidates` was measured one filter before
the gate. On node-8 that day the builder said **213** and the gate's dry run of that list said **15 would be
messaged** (the apply sent 3). Read-only, on the same list:

| of the 213 listed | users | the gate's reason |
|---|---|---|
| documents already on file, no stage-2 verdict releasing the credits | 68 | `documents_on_file` |
| every listed row on the approval path or already on the profile | 127 | `nothing_to_ask` |
| **still owe proof** | **18** | |

(116 of the 145 without a blocking document had documents on file that a stage-2 verdict released. The
documents rule keeps them; at least 98 of them are among the 127.) The documents rule alone would have left
145. The larger part of the error is the second row: a band row meets the first three conditions of
`uvn_status.approval_path_admits` by its own predicate (validator-approved, risk under 30, popularity 1-59), and
the ask never names a row the approval path admits. A band user is asked only when one of their listed rows
fails the path's remaining conditions or is not a band row at all.

**Those 127 are not told anything by this lane and are not approved either** (`approve_arm` is `false`). The
builder now reports them instead of counting them as asks; what they are owed is a decision this lane does not
make.

`scope()` now runs `uvn_status.still_owing` **before the cap**. That function is the gate's own
`list_hold` + `owed_ask` (the gate's scan, its batch build and its pre-send re-read call the same two), fed by the
reads the gate makes: the proof-on-file snapshot, the stage-2 verdict store, the per-role splits and the users'
pending rows. The builder never re-implements a rule, and `test_paid_band_ask.py` runs the real gate's dry run
over the builder's list to pin the two counts together for the rules the gate decides **from the list**.

`candidates` is an **upper bound**, not the sendable number. The gate also decides per send — the fraud lens,
the 7-day message window, Intercom-side deferrals and the daily cap — and those holds stay in the gate alone,
never in the builder. On 2026-11-13 they were 1 fraud-lens hold and 20 deferrals on the old list, and 3 deferrals
on the 16-user list. Two measured pairs:

| measurement | builder | gate would message | actually sent |
|---|---|---|---|
| node-8, 2026-11-13T15:08Z | **16** candidates | **13** (3 deferred by the 7-day window) | — |
| node-8, earlier list 2026-11-13 | **213** listed | **15** | **3** |

- `candidates` and `listed` keep their meaning and now count people who still owe proof. The summary gains one
  key, **`not_owed`**: users dropped per gate reason, e.g. `{"documents_on_file": 68, "nothing_to_ask": 128}`
  on the 2026-11-13T15:08Z run (`127` on the earlier 213-user list; the two are separate reads, so the parts need
  not sum to the same total).
- An unreadable or stale proof-on-file snapshot is a **refusal** (`{"error": ...}`, exit 2, no list): "could not
  read the documents" is never "nobody has documents". An unreadable verdict store releases nobody, as in the
  gate, and `not_owed` then carries `"stage2_unreadable": 0` to say so.
- The build makes one more replica read (the listed users' pending rows) and reads two more local files. It still
  writes only its `--out` list.

The 2026-11-13T15:08Z run, in full: `candidates` **16** (`not_owed`: 68 `documents_on_file`, 128
`nothing_to_ask`; 1,145 users with band rows). The 3 the window deferred owe proof and are asked on a later day;
the count does not predict the window.

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
