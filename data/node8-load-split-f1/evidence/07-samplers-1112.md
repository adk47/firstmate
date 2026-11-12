# Evidence 07 - 65 minutes of process and open-file samples (read-only)

Source: two loops over `ssh root@40.160.32.80` (ovh-node-8), 2026-11-12. Each printed to its own
standard output only; nothing was written on the host.

- Process sampler: `ps` every 5 s, 16:16:12Z to 17:21:11Z (3,899 s, 774 samples).
- Open-file sampler: `/proc/*/fd` every 3 s, 16:17:34Z to 17:22:33Z (3,899 s, about 1,300 instants),
  for files ending `.sqlite`, `.sqlite3`, `.db`, their `-wal`/`-shm`, and `.lock` under
  `/var/lib/hydra*`.

## What these samples can and cannot show

1. **The process sampler only saw `system.slice`, and only processes younger than two hours.**
   So it covers scheduled jobs and the two gateway processes (both were restarted by a deploy at
   16:24Z and 16:29Z, evidence 04, so both are in). It does not cover: k3s pods, work started from a
   login session (evidence 06), or long-lived daemons (the `k3s agent`, the cron daemon, runner
   listeners, `paperclip`). For those use the cgroup counters in evidence 01 and 04. It also
   dropped every process whose command begins with `bash`, so a shell script's own CPU is missing
   (its children are counted) and a child cannot always be traced to the job that started it.
2. **One hour, on one afternoon, with a deploy in the middle of it.** Daily and weekly jobs did not
   fire in the window. The edge gateway figure is mostly start-up (below).
3. **"Held open" is not "locked".** The open-file sampler records that a process had the file open
   and in which mode. It does not record whether a write transaction was in progress.
4. **A correction to the analyser.** The first pass identified a process by pid plus a 20-second
   start bucket; a process whose start time sat on a bucket edge was counted twice. That doubled
   the edge gateway (2,080 CPU-s reported, 1,047 real). The tables below are from the fixed pass
   (pid plus start time within 3 s). No earlier evidence file quoted the doubled figure. The
   open-file tables were not affected.

## CPU by unit (processes under two hours old, `system.slice`)

| unit | processes | CPU-s | avg cores |
|---|---|---|---|
| openclaw-gateway-edge | 28 | 1,055 | 0.271 |
| openclaw-gateway-main | 1147 | 742 | 0.190 |
| cron | 1375 | 669 | 0.172 |
| actions.runner.Muso-AI-hydra.hydra-node8 | 209 | 80 | 0.021 |
| actions.runner.Muso-AI-hydra.hydra-node8-4 | 47 | 15 | 0.004 |
| actions.runner.Muso-AI-hydra.hydra-node8-dispatch | 55 | 11 | 0.003 |
| actions.runner.Muso-AI-hydra.hydra-node8-3 | 31 | 7 | 0.002 |
| k3s-agent | 62 | 5 | 0.001 |
| gdpr-pipeline-tick | 32 | 5 | 0.001 |
| actions.runner.Muso-AI-hydra.hydra-node8-5 | 12 | 5 | 0.001 |
| hydra-tmp-reaper | 3 | 2 | 0.001 |

total CPU-s attributed: 2,598 = 0.666 cores average

## CPU by command (top 24)

"Process-seconds alive" is samples seen times 5 s; it is how long something existed, not how much
processor it used.

| unit | command | processes | CPU-s | avg cores | peak RSS MiB | process-seconds alive |
|---|---|---|---|---|---|---|
| openclaw-gateway-edge | `index.js` | 1 | 1,047 | 0.269 | 2,887 | 3,405 |
| cron | `kubectl` | 294 | 554 | 0.142 | 1,636 | 4,735 |
| openclaw-gateway-main | `index.js` | 1 | 515 | 0.132 | 2,444 | 3,105 |
| openclaw-gateway-main | `codex app-server (model runtime child)` | 93 | 112 | 0.029 | 301 | 113,115 |
| openclaw-gateway-main | `credit-review.py decide` | 2 | 49 | 0.013 | 133 | 465 |
| actions.runner.Muso-AI-hydra.hydra-node8 | `openclaw-memory` | 14 | 43 | 0.011 | 473 | 70 |
| cron | `rsync` | 21 | 41 | 0.011 | 46 | 170 |
| cron | `openclaw-memory` | 6 | 17 | 0.004 | 446 | 50 |
| openclaw-gateway-main | `find` | 1 | 17 | 0.004 | 7 | 30 |
| cron | `openclaw-sessions` | 15 | 16 | 0.004 | 338 | 75 |
| openclaw-gateway-main | `openclaw-database-verify.worker.js` | 1 | 15 | 0.004 | 125 | 35 |
| openclaw-gateway-main | `rg` | 4 | 14 | 0.004 | 298 | 40 |
| actions.runner.Muso-AI-hydra.hydra-node8 | `openclaw` | 109 | 14 | 0.004 | 454 | 855 |
| cron | `openclaw` | 118 | 12 | 0.003 | 324 | 690 |
| actions.runner.Muso-AI-hydra.hydra-node8-dispatch | `Runner.Worker spawnclient` | 11 | 11 | 0.003 | 145 | 135 |
| actions.runner.Muso-AI-hydra.hydra-node8 | `git` | 4 | 10 | 0.003 | 645 | 30 |
| openclaw-gateway-main | `credit-proof.py file-recent` | 2 | 9 | 0.002 | 239 | 3,510 |
| cron | `claim-proof-check-daily.js` | 2 | 8 | 0.002 | 518 | 460 |
| actions.runner.Muso-AI-hydra.hydra-node8 | `Runner.Worker spawnclient` | 3 | 6 | 0.002 | 146 | 1,060 |
| k3s-agent | `containerd-shim-runc-v2` | 41 | 5 | 0.001 | 17 | 25,770 |
| cron | `verification-queue-report.py` | 11 | 5 | 0.001 | 90 | 315 |
| gdpr-pipeline-tick | `gdpr-pipeline.py tick` | 1 | 5 | 0.001 | 41 | 235 |
| actions.runner.Muso-AI-hydra.hydra-node8-3 | `Runner.Worker spawnclient` | 4 | 5 | 0.001 | 146 | 75 |
| actions.runner.Muso-AI-hydra.hydra-node8-4 | `638c3628-9729-4fe4-bf7b-50d1b6729f37.sh` | 9 | 5 | 0.001 | 317 | 80 |

### The two gateway processes over time

Cumulative CPU seconds of the gateway's own `index.js` process, read from the samples:

| process | started | 16:30 | 16:40 | 16:50 | 17:00 | 17:10 | 17:20 | cores, 16:40 to 17:20 |
|---|---|---|---|---|---|---|---|---|
| edge gateway (Caroline) | 16:24:01Z | 437 | 886 | 941 | 981 | 1,004 | 1,045 | 0.066 |
| main gateway | 16:29:04Z | 16 | 231 | 271 | 342 | 421 | 507 | 0.115 |

The edge gateway used 886 CPU-s in its first 16 minutes and 159 in the next 40. Its 0.27-core
average for the window is therefore a start-up figure. Resident memory of the two processes at
17:20Z: edge 2,374 MiB, main 2,373 MiB.

In the whole window the only processes seen in the edge gateway's cgroup were the gateway itself,
its `codex` model-runtime children, one memory-search child and the pre-start script. No tool
script was started by Caroline in the window, so what her tool scripts open was not observed.

### `kubectl` under host cron

330 `kubectl` processes ran under `cron.service` in the window. 141 of them used 487 CPU-s between
them (0.125 cores averaged over the window): each lived 5 to 10 s, used about 10 CPU-s and reached
0.9 to 1.6 GiB of resident memory. Two ran together at 16:30:04Z. That accounts for the jump in
the cron unit's process memory noted in evidence 04 (251 MiB at 16:26Z, 2,050 MiB at 16:30Z).
**Which scheduled job starts them was not established**: their parent was not in the sample (the
sampler dropped every process whose command begins with `bash`, which is how most of these jobs
start) and their command line shows only `kubectl`.

## Which process had which store open

Window: 16:17:34Z to 17:22:33Z, 3899 s, median step 3 s, 1250 instants with at least one store held (of about 1300)

### Per store
| store | % of window held by someone | % with 2+ holders | % with 2+ read-write holders | max holders | max read-write holders |
|---|---|---|---|---|---|
| `/var/lib/hydra-credit-verify/proof.sqlite` | 89% | 16% | 1% | 5 | 2 |
| `/var/lib/hydra/credit-review/ledger.sqlite3` | 87% | 52% | 3% | 6 | 2 |
| `/var/lib/hydra/credit-trust/ledger.sqlite3` | 19% | 3% | 3% | 2 | 2 |
| `/var/lib/hydra/credit-review/ledger.sqlite3.credit-group.run.lock` | 19% | 0% | 0% | 1 | 1 |
| `/var/lib/hydra/churn/support-state.sqlite` | 16% | 0% | 0% | 1 | 0 |
| `/var/lib/hydra/request-comms/state.sqlite.lock` | 11% | 0% | 0% | 1 | 1 |
| `/var/lib/hydra-credit-verify/doc-verify.sqlite` | 10% | 1% | 0% | 2 | 0 |
| `/var/lib/hydra-gdpr/erasure.sqlite` | 6% | 0% | 0% | 1 | 1 |
| `/var/lib/hydra/request-comms/state.sqlite` | 2% | 0% | 0% | 1 | 1 |
| `/var/lib/hydra-credit-verify/dsp-verify.sqlite` | 0% | 0% | 0% | 1 | 0 |

### Who held `/var/lib/hydra-credit-verify/proof.sqlite`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| openclaw-gateway-main | `credit-proof.py file-recent` | 2 | 3,396 | read-write |
| cron | `throughput.py` | 1 | 222 | read-only |
| login session | `receipts.py` | 2 | 207 | read-only |
| login session | `comm_state.py check` | 43 | 171 | read-only |
| cron | `comms.py` | 1 | 123 | read-only |
| cron | `monitor.py` | 1 | 96 | read-only |
| openclaw-gateway-main | `credit-proof.py stage2` | 1 | 27 | read-write |
| login session | `credit-review.py uvn-status` | 5 | 15 | read-only |
| cron | `awards.py` | 1 | 6 | read-only |
| login session | `reply_due_scan.py` | 1 | 6 | read-only |

overlapping pairs (seconds together, approx):
- 222 s: `cron: throughput.py` with `openclaw-gateway-main: credit-proof.py file-recent`
- 132 s: `login session: receipts.py` with `openclaw-gateway-main: credit-proof.py file-recent`
- 132 s: `login session: comm_state.py check` with `openclaw-gateway-main: credit-proof.py file-recent`
- 123 s: `cron: comms.py` with `openclaw-gateway-main: credit-proof.py file-recent`
- 96 s: `cron: monitor.py` with `openclaw-gateway-main: credit-proof.py file-recent`
- 81 s: `cron: comms.py` with `cron: monitor.py`

### Who held `/var/lib/hydra/credit-review/ledger.sqlite3`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| cron | `s1_tick.py` | 4 | 2,343 | read-only |
| login session | `credit-review.py uvn-status` | 14 | 1,230 | mixed |
| openclaw-gateway-main | `credit-review.py review` | 1 | 447 | read-write |
| cron | `completeness-snapshot.py` | 1 | 390 | read-only |
| openclaw-gateway-main | `credit-review.py decide` | 2 | 375 | read-write |
| login session | `reply_due_scan.py` | 2 | 312 | read-only |
| cron | `throughput.py` | 1 | 222 | read-only |
| login session | `credit-review.py claim-proof-ask` | 3 | 141 | read-write |
| cron | `comms.py` | 1 | 123 | read-only |
| login session | `comm_state.py check` | 32 | 114 | read-only |
| cron | `monitor.py` | 1 | 102 | read-only |
| cron | `c2class.py` | 1 | 84 | read-only |
| login session | `python3 - ` | 2 | 36 | read-only |
| cron | `verification-queue-report.py` | 5 | 15 | read-only |

overlapping pairs (seconds together, approx):
- 720 s: `cron: s1_tick.py` with `login session: credit-review.py uvn-status`
- 402 s: `cron: s1_tick.py` with `openclaw-gateway-main: credit-review.py review`
- 288 s: `cron: completeness-snapshot.py` with `login session: credit-review.py uvn-status`
- 141 s: `cron: s1_tick.py` with `login session: credit-review.py claim-proof-ask`
- 120 s: `cron: s1_tick.py` with `openclaw-gateway-main: credit-review.py decide`
- 120 s: `openclaw-gateway-main: credit-review.py decide` with `openclaw-gateway-main: credit-review.py review`

### Who held `/var/lib/hydra/credit-trust/ledger.sqlite3`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| openclaw-gateway-main | `credit-review.py review` | 1 | 447 | read-write |
| openclaw-gateway-main | `credit-review.py decide` | 2 | 375 | read-write |
| login session | `credit-batch-judge.py judge` | 2 | 27 | read-write |

overlapping pairs (seconds together, approx):
- 120 s: `openclaw-gateway-main: credit-review.py decide` with `openclaw-gateway-main: credit-review.py review`

### Who held `/var/lib/hydra/credit-review/ledger.sqlite3.credit-group.run.lock`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| login session | `credit-review.py uvn-status` | 1 | 729 | read-write |

### Who held `/var/lib/hydra/churn/support-state.sqlite`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| cron | `cancel_alert.py` | 2 | 627 | read-only |

### Who held `/var/lib/hydra/request-comms/state.sqlite.lock`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| request-comms | `request-comms.py tick` | 1 | 414 | read-write |

### Who held `/var/lib/hydra-credit-verify/doc-verify.sqlite`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| cron | `throughput.py` | 1 | 222 | read-only |
| cron | `monitor.py` | 1 | 96 | read-only |
| login session | `reply_due_scan.py` | 2 | 42 | read-only |
| login session | `comm_state.py check` | 7 | 21 | read-only |
| login session | `receipts.py` | 2 | 12 | read-only |
| cron | `awards.py` | 1 | 6 | read-only |
| cron | `l11read-v2.py` | 1 | 3 | read-only |

overlapping pairs (seconds together, approx):
- 15 s: `cron: monitor.py` with `cron: throughput.py`
- 9 s: `cron: throughput.py` with `login session: receipts.py`

### Who held `/var/lib/hydra-gdpr/erasure.sqlite`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| gdpr-pipeline-tick | `gdpr-pipeline.py tick` | 1 | 234 | read-write |

### Who held `/var/lib/hydra/request-comms/state.sqlite`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| request-comms | `request-comms.py tick` | 1 | 96 | read-write |

### Who held `/var/lib/hydra-credit-verify/dsp-verify.sqlite`
| started by | command | processes | seconds held (approx) | mode |
|---|---|---|---|---|
| cron | `awards.py` | 1 | 9 | read-only |
| cron | `rates.py` | 1 | 3 | read-only |


## The login sessions that held a store

Four login sessions held a store open in the hour. Two ran the outbound sender's steps:

| session | run directory | step | first seen to last seen (UTC) | open mode |
|---|---|---|---|---|
| 861539 | `20261112T1633Z` | `receipts.py` | 16:33:24 to 16:35:15 | read-only and read-write files |
| 861539 | `20261112T1633Z` | `reply_due_scan.py` | 16:37:56 to 16:40:33 | same |
| 861539 | `20261112T1633Z` | `credit-review.py uvn-status`, paid then free | 16:40:36 to 17:19:47 | same |
| 861539 | `20261112T1633Z` | `credit-batch-judge.py` | 17:02:44 to 17:22:17 | read-write |
| 861539 | `20261112T1633Z` | `credit-review.py claim-proof-ask`, paid | 17:19:50 to 17:22:33 (sample end) | read-write |
| 861847 | `20261112T1703Z` | `receipts.py` | 17:03:15 to 17:04:51 | read-only and read-write files |
| 861847 | `20261112T1703Z` | `reply_due_scan.py` | 17:04:54 to 17:08:07 | same |
| 861847 | `20261112T1703Z` | `credit-review.py uvn-status`, paid then free | 17:08:10 to 17:13:29 | same |

So a second run of the sender's steps started from another login session at about 17:03Z, while
the 16:33Z run was still in its `uvn-status` step, and ended at about 17:14Z. This matches the
second `credit-verify-outbound.sh` process seen on the host at 17:03:44Z. Whether the second run was
a live run or a dry run, who started it, and how it relates to the sender's `tick.lock` were not
read. The other two sessions (861756, 861929) each ran an inline `python3 -` for about 16 s.

## What this adds to the map

- The decision ledger was open in some process for 87% of the hour and the proof store for 89%.
  Neither is a file that is opened briefly now and then.
- Two or more processes had the ledger open at once for 52% of the hour; two or more **read-write**
  for 3%. For the proof store: 16% and 1%.
- The writers came from two places: children of the main gateway (`credit-review.py decide` and
  `review`, `credit-proof.py file-recent` and `stage2`) and the hand-started sender in a login
  session (`uvn-status`, `claim-proof-ask`, `credit-batch-judge.py`). The scheduled form of that
  sender runs under host cron.
- Everything started from host cron that touched the ledger or proof store opened it read-only.
- No process in the edge gateway's cgroup opened any of these stores.
