# Verification sends at scale: design, cutover and ceilings

Lane `verif-bulk-throughput-v1`, written 2026-11-12. This page is the PR body. Operator detail:
`docs/credit-verification/bulk-send-queue.md`.

## What is replaced, and what is not

Only the apply/transport step. The decision ladder, the gate (`intercom-verify-request.sh`), the copy, the caps,
the tick and `verify_notify`'s accounting are unchanged.

The old apply kept every outcome in memory and wrote them when the run ended, so a run killed at its timeout lost
them (39 sends at 15:05Z and 79 at 17:24Z on 2026-11-04). Now each message is a durable row with its own commit.

## Two queues, one protocol

| | `apply_queue.py` (TEMPORARY, on in this PR) | `bulk_queue.py` (general, unarmed) |
|---|---|---|
| Sends through | the existing gate call, unchanged | send-gateway email, one exec per batch |
| Family | `claim-proof-ask` first notes only | status notes; any family once it has an email template |
| Switch | `policies/apply-queue.json` row + kill file | `policies/bulk-send-queue.json` (`enabled: false`) |
| Journal | `apply-queue.sqlite3` beside the verify ledger | `/var/lib/hydra/bulk-send-queue/queue.sqlite` |

**Schema.** One row per intent: `idem_key` (primary key), campaign, user, request key, `state`
(`queued`, `attempted`, `sent`, `uncertain`), worker, lease, attempts, ledger row, provider id, timestamps. An
append-only event table records every transition. Triggers refuse a `sent` with no recorded attempt, a rewrite of
a `sent` row, and any delete.

**Idempotency key.** `sha256(campaign, user id, request ids)` in the gate queue; `sha256(user, stage, message
class)` in the bulk queue, with `UNIQUE (user, stage)`. Enqueue is `INSERT OR IGNORE`.

**Claim protocol.** One `BEGIN IMMEDIATE` transaction reads the row and commits `attempted` with a lease before
the send. Any number of threads or processes can race; exactly one gets the row. This is SQLite's equivalent of
`SELECT ... FOR UPDATE SKIP LOCKED`.

**Drain loop.** Settle expired leases, claim, commit `attempted`, send, commit the outcome when the provider
answers. No process holds outcomes in memory.

**After a kill.** The gate queue reads the truth from the verify ledger, never from stdout: a `sent` ledger row
is sent; an `attempted` ledger row is `uncertain` and is never sent again; no ledger row means the gate never
claimed, so the intent is queued again. `uncertain` is cleared only by a named person (`resolve --by NAME`).

## Proof (scratch files, ak47)

| Run | Result |
|---|---|
| Gate queue, 1,000 intents, 8 workers, 4 killed with 8 in flight | 997 sent, 3 uncertain, 0 delivered twice, 0 orphans |
| Bulk queue, 2,046 jobs, 8 workers, 4 killed with 109 in flight | 2,046 sent, 0 delivered twice, 0 orphans |
| Bulk queue decisions | 100,000 people in 0.349 s, one SQL statement |
| Bulk queue drain | 6,327 sends a minute at 8 workers against a fake provider |

Existing suites pass with the gate queue on: `test_claim_proof_ask.py` 63, `test_credit_verify_notify.py` 187,
`test_apply_queue.py` 23 (five hand mutants all caught), `test_bulk_queue.py` 26.

## Ceilings, with sources

| Limit | Number | Source |
|---|---|---|
| Claim asks per day | 500, shared by both claim campaigns | `policies/credit-verify-outbound.json` `shared_daily_cap.claim` |
| Claim asks per tick | 25 per segment | node-8's own policy file only; the repo has no such row |
| Gate speed | about 20 sends a minute at 6 workers (19 sends, 17:22:53Z to 17:23:51Z, 2026-11-12) | node-8 verify ledger rows 13548-13566 |
| Intercom API | 10,000 calls a minute per workspace for private apps, in 10-second windows | Intercom rate-limiting reference |
| Email, credit status | 2,500 per UTC day | send-gateway `WARMUP_CEILINGS` notify 3,000; read live 17:41Z |
| Mailgun API | 80,000 calls per 10 seconds on `/messages` | Mailgun API overview |
| Our chat | no batch send | core-backend `ChatBackend` has no Muso-to-user send; rooms are created encrypted |

**Measurement method.** Documented limit first, then the live value: `GET /v1/warmup` in the send-gateway pod for
email, and the gate's own send timestamps in the verify ledger for Intercom. No real send burst was run, so the rate
Mailgun or Intercom actually accepts from us is unmeasured.

**What this means for claim asks today.** 222 claims (216 people) are waiting for a first ask. The binding limit
was the 25-per-segment tick cap and tick order, not transport: of the five ticks that started between 14:00Z and
19:30Z on 2026-11-12, one reached the claim group, because the credit families ran first and ended the others.
#1919 (on node-8 since 21:56Z that day) now runs the claim group first, in its own 1,500 s slice, which leaves the
25-per-segment cap as the limit. The queue changes neither. It makes each send's outcome durable, which is the
precondition for raising that cap.

## Cutover

1. **This PR.** `claim-proof-ask` first notes go through the gate queue when `policies/apply-queue.json` says
   `enabled: true` and `/etc/hydra/apply-queue.disabled` is absent. Anything else, an unreadable policy or an
   unopenable journal included, uses the direct path. Merging and deploying this PR turns the queue on for that
   one family.
2. **Acceptance.** After the first 100 sends, `apply_queue.py verify --ledger <ledger>` must show
   `requests_with_two_notes`, `orphans` and `sent_without_ledger_row` all 0.
3. **Next families.** One policy row per PR, each after the one before passed step 2. Each caller needs the same
   one-line `queue=` argument `claim_proof_ask.run` got.
4. **Removal.** Delete `apply_queue.py` and its policy when the bulk queue's email route carries the family. That
   needs a reviewed claim-ask template in send-gateway and its sha256 pinned in `policies/bulk-send-queue.json`.

## Files

New: `scripts/credit_review/apply_queue.py`, `scripts/credit_review/bulk_queue.py`, `policies/apply-queue.json`,
`policies/bulk-send-queue.json`, `scripts/tests/test_apply_queue.py`, `scripts/tests/test_bulk_queue.py`,
`docs/credit-verification/bulk-send-queue.md`, this page.
Changed: `scripts/credit_review/verify_notify.py` (`send_all` takes `queue=`),
`scripts/credit_review/claim_proof_ask.py` (passes it on apply), `policies/outbound-copy-senders.json`,
`.github/workflows/pr-validate.yml`, `AGENTS.md`.

## Riskiest part

The moment between the gate's POST and its ledger write. A worker killed there leaves a message that may have
been delivered with no confirmed outcome.

Mitigation: `attempted` is committed in both the journal and the verify ledger before the POST, so that row is
found on the next run and becomes `uncertain`. Nothing re-sends an `uncertain` row. The verify ledger's own
`claim()` still refuses a second note for the same request, so the queue sits in front of the existing
at-most-once rule rather than replacing it. Cost: a few customers per kill are not asked until a person resolves
the row (3 of 1,000 in the kill run).

## Not in this PR

- **No production send has gone through either queue.** The 100-send acceptance needs this PR merged and
  deployed; this lane can do neither. node-8 runs `fa1c3072c`, which has neither file.
- **Email for asks.** send-gateway has no claim-ask template, so asks stay on the gate. The template is a
  muso-messaging change plus an H-DevOps routed-key change, outside this repo. That is the piece that can slip.
- **The tick still reads the outcomes file.** A run killed at its timeout still leaves the tick without that
  file; the journal now holds the outcomes, but nothing rebuilds the file from it yet.
- **Other families** (`uvn-status`, `proof-need-ask`, status notes) are not wired to the gate queue.
- **node-8's policy file differs from the repo** (three extra `tick_cap` rows, hourly cron instead of two-hourly).
  The file kept its 11:27Z modification time and its three rows through the deploys at 16:35Z and 21:56Z on
  2026-11-12, so a deploy does not overwrite it and the 25-per-segment claim cap stays until someone edits it on
  the host.
