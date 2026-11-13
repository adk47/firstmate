# node8-fly-gate-v2: where a gate call's seconds go, before and after

Four runs of the `uvn-status` paid check on node-8 (`--mode dry-run --check-recipients`, nothing sent), same list
(`/root/h2-runs/sched/20261112T2159Z/owing-uvn.json`), same page (`--start-entry 762 --max-entries 200`), same
`--max-users 50`, under `../tools/proc_sampler.py`:

| file | code | read-only workers | when (UTC) |
|---|---|---|---|
| `before-w1.txt` | deployed 66491d552 | 1 | 2026-11-12 22:36-22:47 |
| `before-w4.txt` | deployed 66491d552 | 4 (the tick's setting) | 2026-11-12 23:12-23:17 |
| `after-w4.txt` | this change, from a scratch mirror of `/opt/hydra/scripts` | 4 | 2026-11-13 00:16-00:22 |
| `after-w1.txt` | this change, same mirror | 1 | 2026-11-13 00:23-00:32 |

Each file is `proc_sampler.py summarize` on the run (per-person lines left out) followed by counts from the check's
outcome file. No user id is in these files; the raw samples and outcome files are on node-8 in `/root/fly-gate-v2`
(mode 700).

Reading the "after" files: `trino invocations per user` counts every time a helper called its replica command.
After this change that command is `replica-serve.sh`, which answered all of them from the read in 0.05 s. The real
round trips are the `gate_facts read` lines: one per person.

The mirror differed from the deployed tree in the six files of this change, with the two new pinned paths
(`PROD_GATE_FACTS_HELPER`, `PROD_REPLICA_SERVE`) pointed at the mirror. `core_notice.py` and `comm_state.py` were the
deployed (hand-edited) copies. The mirror was removed after the runs.

These runs added load to node-8 while scheduled ticks were running. A tick's `claim-proof-ask-paid` check hit the
unmeasured bar at 00:20:37Z, during `after-w4`; this measurement cannot be excluded as a contributor.

What the numbers say is in `docs/credit-verification/gate-replica-read.md`.
