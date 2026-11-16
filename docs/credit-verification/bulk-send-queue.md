# The bulk send queue

Code: `scripts/credit_review/bulk_queue.py`. Policy: `policies/bulk-send-queue.json`. Tests:
`scripts/tests/test_bulk_queue.py`.

**Status: built and proven on scratch files. It is not wired to production and sends nothing.** The policy ships
`enabled: false`, no email template is pinned, and no cron or timer runs it. The existing apply path
(`verify_notify.py` → `intercom-verify-request.sh`) is unchanged, and so are its per-tick caps.

## What it replaces, and why

Captain, 2026-11-12: "we need to be able to verify and run this process in the thousands per min". The measured
rate was 60 messages a day.

The apply step is one long-lived subprocess per message that writes its outcomes when the run ends. A run that
outlives its timeout loses them: 39 sends at 15:05Z and 79 at 17:24Z on 2026-11-04
(`policies/credit-verify-outbound.json`, `tick_cap`). The per-tick caps exist to stay under that. Raising them
sends more and records less.

The queue holds no outcome in memory. Each step is a committed row.

| Step | What it is | What makes it safe |
|---|---|---|
| `decide` | One SQL statement (`DECIDE_SQL`) over the `people` table. One verdict per (person, stage). | A `send` verdict is final (trigger). Every other verdict is re-decided on the next pass. |
| `enqueue` | One SQL statement. Each `send` verdict with no job becomes one queued job. | Key = sha256(user, stage, message class). `UNIQUE (user_key, stage)`: one job per person per stage, ever. |
| `work` | N processes. Each claims a batch, commits `attempted`, sends, commits each outcome as it arrives. | The claim is one `BEGIN IMMEDIATE` transaction. `sent` is refused unless `attempted` was recorded first (trigger). |
| `recover` | Run by every worker on every loop. Settles rows whose lease ran out. | See "A killed worker" below. |

The database refuses, whatever the caller does: a job with no `send` verdict, a second job for the same user and
stage, `sent` without a recorded attempt, any rewrite of a settled job, and any edit of the event log.

It is a transport. It writes no copy, approves no credit, writes no credit status and reads or changes no served
number.

## The person row

`load` takes JSONL, one person per line. The builder that writes it owns identity, the fraud lens and the copy.

| Field | Meaning |
|---|---|
| `user_key`, `user_id`, `email`, `email_confirmed` | The account. Email needs all of the last three. |
| `stage` | Where this person's work sits. Only stages in the policy's `stages` get a message. |
| `request_ids` | Their requests. The view `row_verdicts` gives every request its person's verdict. |
| `hold` | Why this person must not be messaged. `unmeasured` when the builder could not read the fraud lens. Any value holds. |
| `told` | Stages any other sender already told them about. |
| `body`, `subject`, `data`, `copy_data` | The reviewed line, the template data, and the customer-supplied words the copy gate should excuse. |
| `chat_reachable`, `intercom_thread` | Route facts. |

**That builder is not in this change.** Until one exists the queue has no production input.

## The decision, in rank order

First match wins.

1. `hold` is set → `hold:<reason>`
2. already told for this stage → `skip:already_told`
3. no open requests → `skip:nothing_open`
4. the stage has no message class → `hold:no_class_for_stage`
5. no reviewed line → `hold:no_copy`
6. no route → `hold:no_route`
7. otherwise → `send`

Only the two on-us stages are mapped: `doc_received` → `status-doc-received`, `team_review` → `status-team-review`.
An ask is `need_asks.py`'s and is never sent from here.

A `send` verdict is final, so `decide` cannot take one back. The worker therefore reads the person again after it
claims a job and before it sends: a stage that moved on ends the job as `stale_stage`, a stage another sender has
told since the job was queued ends it as `already_told`, and a hold that appeared gives the claim back. A job a
dead worker had already attempted becomes `uncertain` instead, because it may have been sent. The re-read and the
send are not one transaction: a sender that records `told` after the re-read is not seen by that batch.

## Routes

Captain's order, 2026-11-12: our own chat, then email, then Intercom only where a thread already lives there.

| Route | Batch send | Why |
|---|---|---|
| chat | **No** | There is no Muso-to-user send. `ChatBackend` (core-backend) mints a room only for an accepted connection between two users, every room is created Megolm-encrypted (`TuwunelMatrixService.ts:108-113`), and the homeserver is one replica by design. |
| email | Yes | send-gateway `/v1/send` is at-most-once per `idempotency_key`; a repeat answers the first send's row. |
| intercom | No | Intercom keeps no key of ours, so a send with no recorded outcome can never be retried safely. People reachable only there stay on `intercom-verify-request.sh`. |

So a `send` verdict means email today. "Move the customer to our chat on contact" is not built: there is nothing
to send into.

### The email route

- **One `kubectl exec` per claimed batch**, not per message. Payloads go in as JSON lines; one answer line comes
  back per payload as it completes, and is committed on arrival.
- **Every distinct body in a batch is asked of the copy gate** (`lib/copy_gate.require`) with the frame
  `email-template:<key>@<sha256>`. A held body gives its claim back, burns no attempt and is offered again after an
  hour. It is never handed to the exec.
- **The template is pinned.** No pin in `template_sha256`, or a pod whose live template hashes differently, sends
  nothing. The in-pod check is the one in `request_comms/channels.py`.
- **The provider key is `credit-status:<class>:<user id>`**, the shape `paid-status/email_route.py` already sends.
  The gateway therefore answers `duplicate` for a person either sender already mailed in that class.
- **The gateway's ceiling parks the route.** A `would_send` with gate `route_ceiling` defers the job and stops every
  worker claiming email until the next UTC day.

## A killed worker

| Row left behind | What `recover` does |
|---|---|
| `claimed`, never `attempted` | Back to `queued`. Nothing left this host. |
| `attempted`, no outcome, provider de-duplicates (email) | Back to `queued` and presented again under the same key, up to 5 times, then `uncertain`. |
| `attempted`, no outcome, provider keeps no key | `uncertain`. No code path sends it again. |

`uncertain` leaves only by `resolve --idem KEY --as sent|rejected --by NAME`: a named person reads the provider
and records what it shows.

A live worker extends its leases as outcomes arrive, so only a dead worker's rows expire.

## Measured

On ak47 (32 cores), 2026-11-12, at `fa1c3072c` plus this change. Scratch files only.

**Decisions.** `bulk_queue.py bench`, 100,000 synthetic people holding 200,000 requests:

| | Result |
|---|---|
| `decide` | 0.349 s → 17.2 million decisions per minute |
| `enqueue` | 88,000 jobs in 0.617 s |
| Second `decide` + `enqueue` | 0.333 s, 0 jobs added |

**Drain.** `bench --people 20000 --workers 8 --latency-ms 2`: 17,600 sends in 166.9 s, **6,327 per minute**. Every
outcome is its own fsynced commit. Provider held 17,600 keys, none twice.

**Kill -9 mid-batch.** `chaos --jobs 2000 --workers 8 --latency-ms 2`: 2,046 jobs, 4 of 8 workers killed at 30%
sent, then recovery and a fresh drain.

| | Provider de-duplicates (email) | Provider keeps no key |
|---|---|---|
| In flight at the kill | 109 | 111 |
| Final | 2,046 sent | 2,005 sent, 41 uncertain |
| Keys the provider delivered | 2,046 | 2,008 |
| Keys delivered twice | **0** | **0** |
| Presented a second time | 2 (answered from the provider's record) | 0 |
| Orphans, jobs with no verdict, `sent` with no attempt | 0 | 0 |

In the second column, 3 of the 41 uncertain jobs had reached the provider and 38 had not. The queue cannot tell
which, so it sends none of them again.

## The provider ceiling

**Chat: no batch send exists.** Email is the route.

**Email: 2,500 messages a day for credit status, which is about 1.7 a minute.** That is our own gateway's
warm-up ceiling. It is far below thousands a minute, and it is the real limit.

| Layer | Limit | Source |
|---|---|---|
| Mailgun API | 80,000 calls per 10 s per account on `/messages` | [Mailgun API overview](https://documentation.mailgun.com/docs/mailgun/api-reference/api-overview), "Rate Limits" |
| send-gateway, `notify` route | 3,000 batch sends per UTC day: 2,500 credit, 500 claim, 0 spare | H-DevOps `k8s/prod/messaging/78-send-gateway.yaml:174` (`WARMUP_CEILINGS`), read live below |
| Route pause | Batch stops when 24 h hard bounces pass 1% or complaints pass 0.1% | same file, lines 192-193 |

Read live from `GET /v1/warmup` inside a send-gateway pod, 2026-11-12 17:41Z:

- `notify`: ceiling 3,000, used today 0. Last 24 h: 1,495 sent, 0 hard bounces, 15 soft, not paused.
- `mail`: ceiling 100. Last 24 h: 519 sent, 5 hard bounces (0.96%), just under the 1% pause bar.
- `news`: ceiling 1,000. `digest`: 0.

Our own transport is not the limit:

- 64 authenticated reads of the gateway at concurrency 8 took 318 ms (12,075 a minute).
- A bare `kubectl exec` into the pod took 213-223 ms. One exec per message caps a worker near 280 a minute; one
  exec per batch removes that.

**No real send burst was run.** A burst is real email on a route with no spare budget, and it cannot be unsent.
So the rate Mailgun actually accepts from us per minute is not measured. It would not change the answer: the
gateway refuses batch mail past its ceiling whatever Mailgun would take.

Raising the ceiling is a warm-up decision in H-DevOps, not a change here.

## The gate queue (temporary)

`scripts/credit_review/apply_queue.py`, switched on per campaign in `policies/apply-queue.json`. Only
`claim-proof-ask` is on. It exists because send-gateway has no claim-ask template, so an ask can only leave
through `intercom-verify-request.sh`; this module puts a durable row around that one call. Delete it when the
email route above carries the family.

It changes no cap, audience, copy or tick, and `verify_notify`'s report is the same with it on (pinned by
`scripts/tests/test_apply_queue.py`). Reminders are never queued.

| Step | What it does |
|---|---|
| `enqueue` | One intent per (campaign, user, request ids), key = sha256 of the three. `INSERT OR IGNORE`. |
| `begin` | One `BEGIN IMMEDIATE` claims the intent and commits `attempted` before the gate runs. One caller per key. |
| `finish` | Commits the outcome when the gate answers, read from the verify ledger, not from stdout. |
| `settle` | On the next run, settles a dead worker's `attempted` row from the same ledger. |

| Verify ledger says | The intent becomes |
|---|---|
| a `sent` row for the request | `sent` |
| an `attempted` row (the POST may have landed) | `uncertain`; nothing sends it again |
| no row (the gate never claimed) | `queued` again |
| ledger unreadable | stays `attempted`; never read as "nothing was sent" |

The journal is `apply-queue.sqlite3` beside the verify ledger. If it cannot be opened the run prints
`APPLY QUEUE UNAVAILABLE` and uses the direct path. `touch /etc/hydra/apply-queue.disabled` does the same for
every family.

```bash
L=/var/lib/hydra/credit-review/ledger.sqlite3
python3 scripts/credit_review/apply_queue.py status --ledger $L
python3 scripts/credit_review/apply_queue.py verify --ledger $L     # the acceptance read
python3 scripts/credit_review/apply_queue.py resolve --ledger $L --idem KEY --as sent --by NAME
python3 scripts/credit_review/apply_queue.py chaos                  # scratch files only
```

Acceptance for a family is its first 100 sends with `requests_with_two_notes`, `orphans` and
`sent_without_ledger_row` all 0 in `verify`. No production send has gone through it yet.

Kill run, 1,000 intents, 8 workers, 4 killed with 8 in flight (ak47, 2026-11-12): 997 sent, 3 uncertain (all 3
had in fact been delivered), 0 requests delivered twice, 0 orphans.

What bounds claim asks today is not this queue. It is the shared claim day cap in
`policies/credit-verify-outbound.json` (`shared_daily_cap.claim` - 200 a day since 2026-11-16, `verif-caps-arm-c1`, inside the warm-up ceiling's 500 claim allocation;
25 before that, and always under send-gateway's 500-a-day claim ceiling) plus a per-segment per-tick clamp: a claim
family with no `FULL_CAP_FROM` date is held at `FIRST_CAP` (100), and `tick_cap` rows of 25 on `claim-proof-ask` pin
that family lower. The repo copy carries all of these.
Tick order was a third bound that day: the credit families ran first and ended four of the five ticks that started
between 14:00Z and 19:30Z before the claim group ran; #1919 now runs the claim group first in its own 1,500 s
slice. The gate itself sent 19 asks in 58 seconds at 6 workers. Intercom documents 10,000 API calls a minute per workspace for private apps. The design
and cutover are in `data/verif-bulk-throughput-v1/design.md`.

## Running it

```
bulk_queue.py init    --db FILE                 # schema + policy
bulk_queue.py load    --db FILE --people P.jsonl
bulk_queue.py decide  --db FILE
bulk_queue.py enqueue --db FILE
bulk_queue.py drain   --db FILE --workers 8 --apply    # refused unless the policy arms the route
bulk_queue.py status  --db FILE
bulk_queue.py verify  --db FILE                 # exit 1 when a guardrail count is not 0
bulk_queue.py bench | chaos                     # scratch files; neither takes --db
```

Stop it: `touch /etc/hydra/bulk-send-queue.disabled`. Each worker checks before every claim and exits 3.

To arm it, in one reviewed PR: a builder for `people`, the template pins, `enabled: true` at both levels of the
policy, and a timer. Each campaign's mode in the copy gate stays the gate's own table.
