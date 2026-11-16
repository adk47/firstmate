# 1,000 asks a minute, measured at the ledger (verif-1000-per-min-r1)

Captain's goal: 1,000 verification actions per minute, measured at the ledger. Model and channel choice:
`throughput-model.md` (only send-gateway email can carry the rate). This file is the measurement.

## What ran

2026-11-16 00:32:07Z to 00:56Z on node-8, under `systemd-run --scope -p MemoryMax=4G nice -n 10`:

```
bulk_asks.py rehearse --seed-ledger /var/lib/hydra/credit-review/ledger.sqlite3 --tmp-root /root/verif1000 \
  --people 18000 --workers 8 --tick-s 60 --window-s 120 --lag-s 30 --minutes-at-max 12 --latency-ms 50
```

- **Ledger**: a backup copy of production's verify ledger (1,051,406,336 bytes, 15,222 messages, 1.2 M decisions;
  copy 3.8 s, opened read-only), so every claim read production-sized tables. The copy was deleted after the run.
- **Real code on the whole path**: `verify_ledger.claim` / `finalize` (with the new `verify_messages_account`
  index), the bulk send queue, 8 real worker processes, the minute tick, the ramp judge.
- **Fake provider**: 50 ms per send instead of send-gateway. No email left node-8. Rehearsal user ids start at
  9,000,000,001, so no claim met a real person's rows.
- Real minutes (`--tick-s 60`); the ramp window was 120 s instead of the policy's 600 s so the ramp fit in 12 minutes.

Raw output: `run1.json` (summary, per-minute counts, verify) and `run1-ticks.jsonl` (one line per tick). Both hold
synthetic ids only.

## Ledger counts per minute

`claimed` = verify-ledger rows created that minute; `sent` = rows finalized `sent` that minute.

| minute (UTC) | claimed | sent |
|---|---:|---:|
| 00:32 | 100 | 0 |
| 00:33 | 100 | 100 |
| 00:34 | 100 | 100 |
| 00:35 | 200 | 100 |
| 00:36 | 200 | 200 |
| 00:37 | 200 | 200 |
| 00:38 | 400 | 200 |
| 00:39 | 400 | 400 |
| 00:40 | 400 | 400 |
| 00:41 | 800 | 400 |
| 00:42 | 800 | 800 |
| 00:43 | 800 | 800 |
| 00:44 | 1,000 | 800 |
| 00:45 | 1,000 | 1,000 |
| 00:46 | 1,000 | 1,000 |
| 00:47 | 1,000 | 1,000 |
| 00:48 | 1,000 | 1,000 |
| 00:49 | 1,000 | 1,000 |
| 00:50 | 1,000 | 1,000 |
| 00:51 | 1,000 | 1,000 |
| 00:52 | 1,000 | 1,000 |
| 00:53 | 1,000 | 1,000 |
| 00:54 | 1,000 | 1,000 |
| 00:55 | 1,000 | 1,000 |
| 00:56 | 0 | 1,000 |

**12 consecutive minutes at 1,000 sent (00:45 to 00:56), 16,500 in total.** The ramp never held.

- Duplicates: 0 at every layer. Provider: 16,500 calls, 16,500 keys, `keys_delivered_twice` 0. `verify`: every
  count 0 (`ledger_users_messaged_twice_in_a_day`, `ledger_requests_asked_twice`, `users_with_two_jobs_in_a_stage`,
  `sent_without_attempt`, `jobs_without_reservation`, `sent_jobs_not_settled`, ...).
- Ledger time per tick at 1,000: 8.8 to 10.3 s (about 9.5 ms per claim at production size). Whole tick: at most
  15.2 s of the 60.
- Bounces: none injected in this run (fake provider). The holds on bounce and complaint rates are pinned by
  `scripts/tests/test_bulk_asks.py` (`JudgeTests`), not by this run.

## What made the ledger fast enough

Every claim reads `capped`, `uvn_user_done` and `no_channel` inside the write lock all senders share; each is
`verify_ledger._same_user`, an OR whose `account_id` arm had no index, so each read scanned `verify_messages`. On a
copy of production: capped 19.9 -> 0.8 ms, uvn_user_done 19.9 -> 4.9 ms, no_channel 6.1 -> 0.2 ms with
`CREATE INDEX verify_messages_account ON verify_messages(account_id)`, identical answers on 383 users. Two rewrites
of the legacy arm and a covering index on `decisions` were measured and were slower or no help. The index is created
by `verify_ledger.py migrate` at deploy (`deploy.sh` `migrate_verify_ledger`). Every sender's claim gets cheaper.

## What this does not show, and what stands between this and a real 1,000 a minute

1. **send-gateway's own rate is unmeasured.** The provider here answered in 50 ms; `/v1/send` latency at 8 parallel
   callers, and what the domain's mailbox providers accept per minute, are not measured.
2. **The ceiling**: notify takes 3,000 batch emails per UTC day today. 1,000 a minute for 10 minutes is 10,000; the
   whole ramp at the policy's 600 s window is about 25,000. The muso-messaging ladder PR (3,000 -> 6,000 -> 12,000
   -> 24,000, one step a day on measured use and rates) takes four days to reach a ten-minute run; a one-day lift is
   H-DevOps's and a decision.
3. **The email ask is off by a captain decision** (`scripts/paid-status/daily.sh`, firstmate 024). The sender ships
   `enabled: false`, with no template pin and no approval; `run --apply` refuses until a PR sets all three.
4. **No timer runs it yet.** "Runs again tomorrow with no human" needs the arming PR to add the unit; adding a
   timer that can only refuse would be a page with nothing behind it.
5. Supply: one message per person per UTC day. 1,000 a minute is a one-time drain of the never-asked population
   (71,204 requests; distinct people unmeasured), then a small daily tail.
