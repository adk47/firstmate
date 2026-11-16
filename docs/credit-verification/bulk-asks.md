# The bulk first ask by email

Code: `scripts/credit_review/bulk_asks.py`. Policy: `policies/bulk-asks.json` (the ramp) and
`policies/bulk-send-queue.json` (stage `ask` -> class `uvn-status` -> template `credit_status_uvn_ask`).
Tests: `scripts/tests/test_bulk_asks.py`. Measurement: `data/verif-1000-per-min-r1/report.md`.

**It ships unarmed.** `enabled: false`, no template pin, no approval: `run --apply` refuses until all three are
set, and the email ask itself is off by a recorded captain decision (`scripts/paid-status/daily.sh`, firstmate 024).
Arming it is a captain decision made in a PR, never a merge side effect.

## What it is

The one sender that can carry 1,000 first asks a minute. Every other ask sender is an hourly, serial tick (one
Intercom message per person, 20 to 30 s each). This one is a minute tick in front of the bulk send queue
(`bulk_queue.py`), whose idempotent workers post to send-gateway `/v1/send`, which de-duplicates on our key.

It is a transport, not a decider and not a second ask path for documents:

- **Who** is the scale drain's `ask` rows (`scale_drain.py asks --plan P --out F`; held never-asked rows are not
  in that output) plus measured account facts. `select` keeps one row per person, never-asked first, then paid,
  then user id, and drops a person whose fact is unmeasured (`unmeasured:<fact>`, never read as clear), held, with
  a document on file (`proof_on_file`: that person is waiting on our reader, not on an ask), or with no usable
  address (`no_email`, `email_unconfirmed`, `email_shared`).
- **What** is one reviewed template rendered with the same data for everyone. The copy gate is asked on every
  job's bytes, and an `observed` pass is a hold here: only a signed approve sends. Which document an Intercom ask
  names stays `need_asks.py`'s.
- **Whether a person may be messaged now** is the shared verify ledger: the copy gate is asked on the exact bytes
  the jobs would send BEFORE anyone is claimed, so a held body claims nobody and leaves no ledger row, and everyone
  released on that tick is given exactly the bytes the gate approved (an already-claimed person keeps the bytes their
  job was gated on); then each
  person is CLAIMED with `verify_ledger.claim` before a job exists (one message per user per UTC day, the 7-day
  cooldown, the 90-day ask lock, one ask per request).

## One commit point

**The ledger claim is the only commit point.** Nothing this lane writes before or beside it (no reservation, no
intent row) has to agree with it, so there is no crash window to repair. One pass, `derive`, reads this lane's own
`attempted` verify-ledger rows (its campaign, email, and exactly its approval: another sender's claim is never read
as this lane's) and makes the queue and the audience agree with them:

- a claim whose job settled is finalized `sent` or `rejected`;
- a claim whose job the worker's copy gate holds has the job cancelled (`bulk_queue.cancel_held`, only while it is
  still queued and never attempted), and only a cancelled job's claim is given back (`verify_ledger.give_back_claim`:
  a `deferred` log, never a lock), so nothing can leave without the claim that records it; a job a worker already
  took settles like any other;
- a claim with no job gets exactly one, scoped to the people holding such a claim (`bulk_queue.enqueue(only=...)`),
  on the bytes the copy gate approved this tick. When the gate holds the copy now, no audience row names the person,
  or the queue's own decide refuses them, the claim is given back and the person offered again (a terminal skip
  closes them). A given-back person's standing `send` verdict can therefore never become a job before a fresh claim;
- a job made for an EARLIER claim never settles a later one: that claim is given back and the person closed;
- an audience row still saying `claimed` with no live claim behind it (a kill between a ledger write and its note) is
  written down from the queue: the settled outcome, or offered again when there is no job.

`derive` runs at the start of every tick and again right after the tick's claims. It is idempotent and reads only
the ledger and the queue, so a kill at any step - before or after a claim, after the release, after the enqueue,
before or after a finalize, after a cancel or a give-back - is finished by the next tick: the person is sent once,
under one claim, or offered again. `KillTests` kills a child process (`os._exit`) at each of those points. There is
no grace window, and the ramp store's `synchronous = NORMAL` is a throughput choice, not a correctness one: what it
can lose is a note `derive` rebuilds. A deferral (`recent:*`, `daily_cap`, `no_channel`) is offered again when its
lock lapses; only a terminal result (`already_notified`, `user_done`) closes the person.

## The ramp

Each minute: sample gateway health (`GET /v1/warmup` from inside the pod), ask the copy gate, derive, judge, claim, derive.

- The rate starts at `floor_per_min` (100) and doubles, up to `max_per_min` (1,000), only after a clean window:
  `window_s` has passed since the last step, the window reached its rate, and the health read (which lags by
  `health_lag_s`, the gateway's 5-minute cache) counts our sends.
- It goes to 0 and holds on: hard bounces, complaints or soft bounces over their bars (`rate_hold_s`, then it
  restarts at the floor), a paused or unreadable route, a ceiling refusal, an `uncertain` job, or a health read that
  does not count the sends we made. A rate hold stands for `rate_hold_s` from when it was proved: an unreadable or
  paused sample in between does not restart the ramp early. The hard-bounce and complaint bars are the gateway's own
  pause bars; the soft-bounce bar and the hold length are this policy's own and nobody has ruled on them.
- **The tick runs on its health sample's clock.** Sampling after the settle stamped a late read with the tick's
  early time, so the next minute saw no new sends against 400 the queue had made and held (rehearsal, 2026-11-15).
- Release is capped by the backlog: a minute the workers did not finish is not added to.

## What bounds it that this code does not

- **The gateway's warm-up ceiling**: 3,000 batch emails per UTC day on `notify` today (H-DevOps
  `78-send-gateway.yaml` `WARMUP_CEILINGS`). 1,000 a minute for ten minutes is 10,000; the whole ramp is about
  25,000. Raising the ceiling is H-DevOps's change and a decision.
- **Supply**: one message per person per day, so 1,000 a minute is a one-time drain of the never-asked population,
  then a small daily tail.

## The ledger's per-user read

Every claim reads `capped`, `uvn_user_done` and `no_channel` inside the write lock every sender shares, and each of
those is `_same_user`. Without an index on `verify_messages(account_id)` the OR was a full scan: about 45 ms of
reads per claim on node-8's ledger. With `verify_messages_account` (created by `verify_ledger.py migrate` at
deploy) it is about 6 ms, identical answers on 383 users. `LedgerIndexTests` pins the plan.

## Commands

```
bulk_asks.py pin      --templates-dir <reviewed checkout>      # the pin, body and subject to put in the policy
bulk_asks.py select   --plan ASKS.jsonl --accounts ACCTS.jsonl --out AUDIENCE.jsonl
bulk_asks.py load     --audience AUDIENCE.jsonl [--ramp-db F]
bulk_asks.py run      --apply [--workers 8] [--memory-mb 256]  # refused while unarmed
bulk_asks.py status | minutes | verify                         # verify exits 1 when any count is not 0
bulk_asks.py rehearse --people N --workers W [--seed-ledger PROD --tmp-root DIR]
```

Kill file: `/etc/hydra/bulk-asks.disabled` stops the tick and every worker (exit 3). A worker over its memory cap
exits 5 and the supervisor replaces it; a worker that refuses because the lane is no longer armed (exit 2) stops the
supervisor and the tick, rather than being re-spawned every second.

`rehearse` takes no `--db` and no `--ledger`: it makes its own scratch directory, real queue, real verify ledger and
real worker processes against a fake provider. `--seed-ledger` starts the scratch ledger as a read-only backup of
another file (production's, for a measurement at real size); rehearsal user ids start at 9,000,000,001 so no claim
meets a real person's rows, the seed is never opened for writing, and the copy is deleted with the rest. A ramp that
stays held for twelve consecutive ticks ends the rehearsal with exit 4 and the hold in `stop_reason`, so a hold that
does not clear reads as a stop rather than a hang.

`verify` must print all zeros: no job without a claim of this lane's or without a send verdict, no sent job whose
claim is not `sent`, no claim of this lane's left `attempted` with no job, no person messaged twice in a day and no
request asked twice in the ledger.
