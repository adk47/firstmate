# Drain time for the 2,598 documented users, and what bounds the batch

Read 22:45-22:50Z on 2026-11-13 from node-8. Nothing was changed; the cap stays at 10.

## The number

**About 3 days from the first deployed run.** Days, not weeks.

| | rate | how it was read |
|---|---|---|
| decider: users given a hold | 900 a day | 90 `judge` runs a day x 10 users. Runs per UTC day, 5 to 13 November: 90, 95, 91, 91, 90, 89, 91, 90, 83 (the 13th to 22:42Z). The cron is `*/15`; a run takes 12 to 14 minutes, and one that passes 15 costs the next slot. |
| stage 2: users given a verdict | about 890 a day | hourly at :20, `--max-users 40`, so 960 at most; its normal intake took 70 users on 13 November. |

All 2,598 are held after 260 runs, 2.9 days. Stage 2 takes them about as fast as they arrive, so the
last verdict is about 3 days after the first run.

Queries:

```sql
-- decider runs a day: ledger, primary-key range, no scan of the 1.07 M rows
SELECT substr(decided_at,1,10), count(DISTINCT run_id), count(*) FROM decisions
WHERE id > (SELECT max(id) FROM decisions) - 400000 AND mode='judge' GROUP BY 1 ORDER BY 1 DESC LIMIT 9;
-- stage 2, per run: users, requests, seconds from first to last verdict (stage2_shadow, 49,946 rows)
SELECT run_id, count(DISTINCT user_id), count(DISTINCT request_id), min(judged_at), max(judged_at)
FROM stage2_shadow GROUP BY run_id;
```

Stage 2 at a full queue: 34 runs took exactly 40 users (14 on 20 October, 8 on the 21st, 11 on the
22nd, 1 on 3 November), 331 to 1,283 seconds from first to last verdict, against a 3,300 second kill.
Since 10 November it has averaged 38 seconds a user (121 users, 9 runs of 6 or more).

### What could make it longer

- On its three full-queue days stage 2 recorded verdicts in 14, 9 and 23 of 24 hourly runs. The store
  does not say whether the other hours had an empty queue or a failed run. At 9 runs a day the drain
  is about 7 days.
- A user stage 2 picks and cannot finish (a document it cannot fetch) stays unjudged and is picked
  again. How often that happens was not measured.
- The pass runs last in a decider run. A run killed at 20 minutes before it reaches the pass holds
  nobody; the next run takes the same users. The pass has not been timed on node-8.
- Merging does not deploy. The clock starts at the first run on a deployed head.

## Someone outside the 10

They wait, and the order is fixed, not arbitrary. Each run reads the whole population again (there
is no cursor to lose) and ranks users: paying first, then the user whose oldest selected request is
oldest, then user id. It takes the first 10 whole users and reports the requests left over in its run line as
`still to hold`. If the paying-users list cannot be read that run, the order is oldest request first
for everyone.

Two consequences of that order:

- a paying user who files a document tomorrow goes ahead of every free user still waiting;
- a free user whose requests are all recent is last, about day 3.

## Can the batch be raised

It can, and by itself it buys nothing.

| what bounds it | measured | does it bind at 10? |
|---|---|---|
| ledger writes | about 11 rows a user (28,688 / 2,598), so 110 rows added to a run that writes 500 | no |
| the pass's fixed cost | one replica read, 3.5 s; one index probe per covered request, 0.14 s for 32,644; the same at any batch size | no |
| **stage 2's intake** | 40 users an hour | **yes** |

The decider supplies 10 x 3.75 runs = 37.5 users an hour and stage 2 takes 40. Any batch above 10
moves the wait from "not yet held" to "held, not judged": no verdict comes sooner. A larger held
queue has two costs:

- stage 2 looks up the status of every unjudged hold on every run, 100 requests per query of about
  2 seconds. All 28,688 held at once is 287 queries, about 10 minutes of each hourly run until the
  queue is gone;
- the order becomes stage 2's (paying first, then the oldest hold). Holds written in one run share
  one instant, so oldest-request-first is lost for whatever is held together.

The lever that shortens the drain is stage 2's `--max-users`, raised together with this cap:

| decider cap | stage 2 `--max-users` | drain | what it risks |
|---|---|---|---|
| 10 | 40 (today) | about 3 days | nothing new |
| 20 | 80 | about 1.5 days | a stage-2 run of 80 users is 11 to 43 minutes by the measurements above, against a 55 minute kill; its slowest 40-user run doubled is 43 |
| 40 | 160 | under a day | by the same measure a slow run is killed before it finishes |

Not checked: what a stage-2 run costs in model calls or Intercom reads per user. That belongs in
the decision to raise `--max-users`.

**Recommendation: leave both where they are.** Three days is short against requests that have sat
in this status since 2024, and it needs no second change. Raising to 20 and 80 saves a day and a half and
spends most of stage 2's time margin.
