# Delivery velocity: where the hours go, and the standing rules

Measured with `scripts/cycle-time.py` (forge timestamps only; an unfinished stage prints
`>=N open`, an unmeasured one prints `unmeasured` and joins no total). Evidence and the
full table: `data/fleet-velocity-fable-v1/` (PRs #1882-#1886, recorded 2026-11-12T01:51Z).

## What the table says

| Rank | Stage | Hours over 5 PRs | What it was |
|---|---|---|---|
| 1 | QA GO -> merge | 34.6, 2 still open | A GO head waiting for a person. #1885 had four GO verdicts on one unchanged head and sat 15.4 h. |
| 2 | merge -> deployed | 25.7, 3 still open | No deploy run had succeeded since 2026-11-09 23:09Z. 4 of 5 nightly deploys were refused in their first second. |
| 3 | first verdict -> GO on the shipped head | 22.3 | 22 NO-GO verdicts over 21 heads; #1883 alone took 14 over 10 heads. |

Refuted: the CI runner pool. The longest queue for a job was 15 s. One validation round
is about 44 minutes of wall time, and 19 rounds cost 14.0 h, so the cost is the number
of rounds, not the wait for a runner.

Not measured, and so not claimed: brief -> worker start, start -> first commit, deployed
-> first effect, and the local gate rounds before a PR opens.

## What changed

- **Deploy, 2026-11-16 (firstmate 074).** The prewait and the boundary gate below are gone:
  sleeping to a tick boundary walked the deploy into that tick's apply (run 43807967494 slept
  329s and was refused at 05:11:00Z). `deploy.sh` now takes the outbound tick's flock and the
  apply lock itself (`scripts/lib/main-prune-lock.sh`, `flock -w 600` each, waits logged, the
  last 24h of tick lengths logged on a refusal), holds both for the run, and rebuilds the claim
  list on the new head before it releases them. The history below is kept for the measurements.
- **Deploy (rank 2).** The nightly run moved from 04:00Z, a send tick boundary, to
  05:00Z (05:38Z since 2026-11-13, below), and `deploy.sh` now waits up to 15 minutes for a
  tick before it takes any lock (`scripts/lib/deploy-send-tick-wait.sh`, removed 2026-11-16) instead of refusing
  in the same second.
  Before: refused on 11-07, 11-08, 11-10 and 11-11. After: not yet measured on the host.
  The first scheduled run after this merges is the measurement; re-run
  `cycle-time.py record` and read the `merge -> deployed` column.
  **Limit:** a tick may use 115 minutes (`TICK_HARD_S`), which was 115 of its 120-minute
  cadence and is now longer than the hourly one. A tick still running at 05:38Z is waited
  on, and refused if it outlasts the prewait. The lasting fix is the tick yielding to a
  deploy (#1756).
  **2026-11-13:** the send tick went hourly (`scripts/install-aux-units.sh`), so every hour
  is a boundary and the nightly run moved again, to 05:38Z; the guard's cadence default
  went from 7200 to 3600 with it. The tick's 115-minute deadline did not change, so a
  05:00Z tick may still be running at 06:55Z. A run that starts at or after :50 waits up to 660s
  to the boundary and then polls the tick's flock until the 900s prewait runs out (about
  06:05Z for a :50 start), and is refused if the tick is still running. A start before
  :50 is not refused at that prewait, but it is still refused if the 05:00Z tick is still
  in flight when it starts, and the gate under the locks reads the clock again after up
  to 1500s of lock waits, so a :48 start carried past :50 is refused there. A 17-20
  minute deploy started late is still running at 06:05-06:08Z when the next tick begins.
  A dispatched deploy meets a boundary twice as often as before: it waits, or is
  refused, from ten minutes before each hour until that hour's tick ends. Not yet
  measured on the host.
- **CI round (rank 3): tried, measured, no gain, reverted.** Putting the two longest
  bats files one per shard moved the slow shard and saved nothing: the round's bats step
  was 39m41s and 42m19s before and 40m32s after (run 43172883117). The floor is one file.
  `credit-verify-outbound.bats` took 35m10s alone on the 2-CPU pod, 120 cases in series,
  so no shard order gets a round under that. The fix is to split that file, in the lane
  that owns it. The other shard ran 24m24s without it.
  **2026-11-13, second pass:** the shard is CPU-bound, not order-bound. That file took 630 s
  alone on 2 pinned CPUs and 1,168 s with three other jobs on the same two, which is what a
  shard at `--jobs 4` gives it. Bats now runs in four shards, so the long pole shares its
  pod with half as much other work. Before / after and the other six causes of a stuck PR:
  `data/pr-pipeline-unblock-f1/report.md`.
- **Rank 1 has no code fix here.** It is a waiting-for-a-person cost; rules 1 and 2 are
  the fix.

## The rules

1. **GO on the shipped head with required checks green means merge now.** One verdict
   per head: a head that has not changed is not reviewed again.
2. **Ask for a named approval when the PR opens, not after GO.** If a guard needs one
   (for example `credit-approval-guard`), the ask goes out with the head sha at open.
3. **A recorded decision on a finding is closed.** A later round reopens it only with
   evidence the decision did not have: a measurement, a log line or a failing test.
   "This change is unnecessary" is not evidence.
4. **One push per round.** Address every finding of the round, run the touched test
   files locally, then push once. Each push costs a full validation round.
5. **Merged is not deployed.** A task is done when a deploy run succeeded on a head that
   contains the merge and the change had its first observable effect. Cite the run id.
   For a fix that matters today, dispatch the deploy instead of waiting for 05:38Z.
6. **Read the standing facts file before measuring.** One per domain
   (`data/verif-deterministic-env-p1/plan.md` is the pattern). Add what you learn to it.
7. **One lane per file region.** Before dispatch, check open branches for the same
   lines. On 11-11 two branches each wrote the scoped re-read in `owing_proof.py`, and
   two more carried an identical `need_asks.py` change.

## What is never traded for speed

- A test that was mutation-proven stays mutation-proven: break the code, watch it fail.
- "Could not measure" is never rendered as zero, healthy or done.
- The Fable copy gate and the duplicate-ask checks stay on every send.
- No `--yes` on a gate, and no check removed or weakened to pass a round.
