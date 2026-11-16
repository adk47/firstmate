# Decisions persisted per minute, with a proof row per applied conclusion: the measurement and its dry run

Firstmate 017 (2026-11-16 12:02Z): once hydra #2000 lands, a sustained run (30 minutes or more) measuring
decisions persisted per minute plus a proof row per applied conclusion; until then, build the measurement and dry-run
it on the ledger copy. This file is the measurement's definition and its dry run. It is not the sustained run.

Tool: `tools/ledger_rate.py` (stdlib, read-only: every store opened `mode=ro`, output is counts, minutes and ledger
row ids only).

## What it counts

Per UTC minute, from the credit-review ledger and the scale-drain ledger:

| source | a decision persisted | an applied conclusion | its proof row |
|---|---|---|---|
| `decide` | a `decisions` row, by `decided_at` | an apply-mode `approve` / `approve_partial` whose `decision_outcomes` row (same run and request) reads `approved` | that outcome row (the writer's read-back of core), and the decision names its `evidence_kind` |
| `drain` | an `applied` row, by `applied_at` | outcome `approve` or `close_duplicate` | its `intents` row `confirmed`, resolution `written` or `reconciled` |
| `ask` | a `verify_messages` row finalized `sent`, by `sent_at` | every such row | a provider receipt on the row (`message_id`, or `send-gateway:<id>` in `api_log`) |

An apply-mode approve whose outcome row says `skipped:*` or `error:*` was recorded but not applied (core moved first,
or core's guard refused): counted by reason, not as applied and not as a gap. An apply-mode approve with no outcome row
at all is the gap. `--check` exits 1 unless some run of `--sustain` consecutive minutes is at or above `--target` and
no applied conclusion lacks its proof row. A store that cannot be read is `absent`, never a zero.

The fixture check (a scratch ledger built from `decide.SCHEMA` and `scale_drain.LEDGER_SCHEMA`) flags exactly the
three rows it should: an approve with no outcome row, an applied approve with no evidence kind, and an outcome row
filed under another run. A lost race counts as not applied, and a shadow decision is persisted but never applied.
Both stores are byte-identical after the run.

## Dry run: a backup copy of node-8's production ledgers, 2026-11-16 12:07Z

The copies were deleted after the run. Read time was 2.1 s for 24 h and 9.7 s for 7 days.

| window | decisions persisted | applied | applied without proof | recorded, not applied | asks sent (no receipt) | drain applied |
|---|---:|---:|---:|---:|---:|---:|
| 24 h | 99,155 | 719 | 0 | 1,325 lost race, 34 core guard | 1,099 (0) | 0 |
| 7 d | 375,362 | 954 | 0 | 1,359 lost race, 34 core guard | 3,743 (0) | 92,398 rows, 0 that write |

Applied in 24 h, by evidence: 544 `validator_low_risk`, 71 `validator_low_risk_trusted`, 104 `precedent`.

**What the rate looks like today:** the 24 h median is 0 decisions a minute, and no two consecutive minutes reached
1,000. The peaks are batch stamps, not throughput. The busiest minute (06:52Z, 1,711 rows) holds 2 distinct
`decided_at` seconds: one decide run wrote its whole batch at 06:52:01Z and 06:52:02Z. The 7 d drain total is one
backfill: 92,386 rows stamped 2026-11-11T18:41, in one second. So a per-minute count can be met by one write a minute
that stamps 1,000 rows, and the sustained run must say so. The output carries, per minute, how many distinct seconds its rows
were stamped in (`stamped_seconds`), and counts the minutes at the target stamped in under 10 seconds, so a stamped
batch is never read as a sustained rate.

**What 1,000 a minute needs:** at the decision layer, a decider that writes a row per decision as it decides, for 30
minutes. At the action layer (what the captain counts: a decision written AND told, or an ask sent), the bulk ask lane
measured 1,000 sends a minute for 12 minutes on a copy of this ledger (`report.md`). The live ceiling is still the
gateway's 3,000 a day, and the email ask is switched off by captain decision.

## The sustained run (Aaron, firstmate 018: the minute the shards are live after deploy 8)

Installed on node-8 at `/root/verif1000/measure/` (`ledger_rate.py` + `tools/sustained.sh`). Start it the minute the
shards are live:

```
/root/verif1000/measure/sustained.sh            # window = next whole UTC minute + 30 min, target 1000/min
```

It waits out the window plus 60 s, reads the live ledgers read-only under `MemoryMax=2G`, writes
`/root/verif1000/sustained/rate-<start>.json` and prints the evidence: the total and min/median/max per minute, the
longest run at 1,000 or more, how many of those minutes were one stamped batch, applied conclusions and how many lack
a proof row, each source, and every minute as `HH:MM=<rows>/<distinct seconds>s`. It exits 0 only when 30 consecutive
minutes reach 1,000 with every applied conclusion proved.

Tried on node-8, 12:20Z, on a past 3-minute window: rc 1, 704 decisions (12:10 = 702 rows stamped in 1 second), 2
applied (asks sent, both with a receipt), 0 without proof. Nothing was written: the run only reads.

Whether the shards write their decisions to these two files is the deploy's to say. A shard writing elsewhere would
measure 0 here, and the tool reports a store it cannot read as `absent`, never as a zero. Point `LEDGER`/`DRAIN` in
`sustained.sh` at the shard store if it differs.
