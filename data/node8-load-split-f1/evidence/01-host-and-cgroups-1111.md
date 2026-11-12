# Evidence 01 - host totals and per-service cgroups (read-only)

Source: `ssh root@40.160.32.80` (ovh-node-8), 2026-11-11 16:30-16:35Z. Nothing was written on the host.
Deployed sha at measurement: `/opt/hydra/.deployed-sha` = `87027e7404d56b5e97f7029933fc54c908a08228`.

## Host, instantaneous (16:30:33Z)

- 24 CPUs, up 139 days, load average 4.87 / 3.95 / 3.60
- Memory: 63,904 MiB total, 28,909 used, 33,121 buff/cache, **34,994 available**
- Swap: 4,095 MiB total, **3,244 used** (vmstat over 20 s: si 0-22, so 0-47 pages/s, i.e. resident but not thrashing)
- PSI cpu `some` avg10 5.17 / avg60 4.48 / avg300 2.81, `full` 0.00
- PSI memory `some` and `full` 0.00 on all three windows
- PSI io `some` avg300 0.59, `full` avg300 0.55
- Disk `/` (nvme0n1p3): 875G, 630G used, 200G free, 76%

## Host, 11 days of sar (10-minute samples, `/var/log/sysstat/sa01..sa11`)

| day | samples | CPU busy avg % | p95 % | max % | iowait max % | load1 avg | load1 p95 | load1 max | samples load1 > 24 | samples busy > 50% |
|---|---|---|---|---|---|---|---|---|---|---|
| Nov-01 | 144 | 14.7 | 20.7 | 31.72 | 1.59 | 3.2 | 5.7 | 7.97 | 0 | 0 |
| Nov-02 | 144 | 13.1 | 20.9 | 33.86 | 10.94 | 2.8 | 5.3 | 9.29 | 0 | 0 |
| Nov-03 | 144 | 20.0 | 36.9 | 55.68 | 13.92 | 4.4 | 8.7 | 15.62 | 0 | 2 |
| Nov-04 | 144 | 22.5 | 32.7 | 39.82 | 6.74 | 4.7 | 7.8 | 9.86 | 0 | 0 |
| Nov-05 | 144 | 18.0 | 25.4 | 30.09 | 3.12 | 3.9 | 6.4 | 8.93 | 0 | 0 |
| Nov-06 | 144 | 21.0 | 27.3 | 35.98 | 11.62 | 4.5 | 7.3 | 12.60 | 0 | 0 |
| Nov-07 | 144 | 15.2 | 21.5 | 26.04 | 1.22 | 3.3 | 6.2 | 8.45 | 0 | 0 |
| Nov-08 | 144 | 13.4 | 20.5 | 25.14 | 5.23 | 2.9 | 5.4 | 6.58 | 0 | 0 |
| Nov-09 | 144 | 14.3 | 23.1 | 28.37 | 4.84 | 2.7 | 4.8 | 10.14 | 0 | 0 |
| Nov-10 | 144 | 13.7 | 20.5 | 26.56 | 4.70 | 2.6 | 4.7 | 5.61 | 0 | 0 |
| Nov-11 (to 16:40Z) | 100 | 13.0 | 19.0 | 20.72 | 2.84 | 2.6 | 4.1 | 6.91 | 0 | 0 |

Limit of this table: sar samples are 10-minute averages, so a burst shorter than that is flattened.
Zero of 1,540 samples had load1 above the core count (24).

## Top-level cgroups (16:31Z)

| slice | memory.current MiB | 90 s CPU rate (cores, 16:32:40Z) |
|---|---|---|
| whole host (`/sys/fs/cgroup`) | - | 2.60 |
| system.slice | 28,497 | 1.75 |
| kubepods.slice (k3s pods) | 7,844 | 0.95 |
| user.slice (root ssh sessions) | 14,651 | 0.01 |

`memory.current` includes page cache charged to the cgroup, so it is an upper bound on anonymous memory.

## Per-service cgroups (16:31Z)

CPU avg = cumulative `cpu.stat usage_usec` / seconds since `ActiveEnterTimestamp`, in cores.
Filter: services with memory.current >= 20 MiB or > 600 CPU-seconds cumulative.

| unit | active for (s) | CPU avg cores since start | CPU cores, 90 s window | mem now MiB | mem peak MiB | swap MiB | MemoryMax | tasks |
|---|---|---|---|---|---|---|---|---|
| openclaw-gateway-main | 44,185 | 0.627 | 1.03 | 10,241 | 18,848 | 604 | max | 830 |
| cron (every host cron child) | 12,092,628 | 0.241 | 0.23 | 7,032 | 11,221 | 38 | max | 91 |
| openclaw-gateway-edge | 44,159 | 0.104 | 0.01 | 3,241 | 4,444 | 422 | max | 115 |
| k3s-agent (agent + containerd, not the pods) | 669,531 | 1.744 | 0.15 | 1,186 | 23,813 | 96 | max | 743 |
| actions.runner hydra-node8 | 8,378,538 | 0.089 | not sampled | 889 | 5,784 | 58 | max | 22 |
| actions.runner hydra-node8-2 | 8,378,538 | 0.082 | not sampled | 759 | 5,731 | 64 | max | 20 |
| actions.runner hydra-node8-3 | 8,663,153 | 0.080 | not sampled | 680 | 5,458 | 55 | max | 21 |
| actions.runner hydra-node8-4 | 697,180 | 0.042 | not sampled | 584 | 3,461 | 69 | max | 21 |
| actions.runner hydra-node8-5 | 697,180 | 0.036 | not sampled | 380 | 6,516 | 72 | max | 20 |
| actions.runner hydra-node8-dispatch | 2,570,680 | 0.039 | not sampled | 246 | 4,005 | 53 | max | 20 |
| actions.runner hydra-node8-6 | 697,179 | 0.033 | not sampled | 206 | 3,599 | 61 | max | 21 |
| credit-thread-reply-tick | 59,453 | 0.000 | not sampled | 86 | 86 | 0 | max | 1 |
| docker | 12,092,627 | 0.000 | not sampled | 80 | 370 | 24 | max | 97 |
| containerd | 12,092,628 | 0.001 | not sampled | 75 | 6,577 | 9 | max | 69 |
| gdpr-pipeline-tick | 59,453 | 0.001 | not sampled | 59 | 108 | 0 | max | 27 |
| muso-mcp-cloudflared | 11,518,057 | 0.000 | not sampled | 18 | 43 | 4 | max | 24 |

Caveats that matter for reading this table:

- **No service has a memory limit** (`MemoryMax=max` on every row).
- The `cron` row's 7,032 MiB is the cgroup charge; the processes in it at 16:32Z summed to about
  200 MiB RSS (largest: `kubectl` 132 MiB, `plan.py` 31 MiB, `owing_proof.py` 25 MiB). The rest is
  page cache charged to that cgroup, not resident process memory. Not yet split with `memory.stat`.
- The `k3s-agent` average of 1.744 cores since start is not reproduced in the 90 s window (0.15).
  One of the two is unrepresentative; not yet resolved.
- `user.slice` 14,651 MiB with 0.01 cores: 26 logged-in root sessions. Not yet split into
  anonymous vs cache.

## Largest processes by RSS (16:33Z)

| RSS MiB | %CPU lifetime | cgroup | process |
|---|---|---|---|
| 5,530 | 16.0 | openclaw-gateway-main | `node openclaw --profile main gateway --port 18789` |
| 2,731 | 9.2 | openclaw-gateway-edge | `node openclaw --profile edge gateway --port 18810` |
| 999 | 2.6 | kubepods (besteffort) | `longhorn-manager` |
| 989 | 4.0 | kubepods (burstable) | `argocd-application-controller` |
| 695 | 7.1 | kubepods (burstable) | `node exporter.mjs` |
| 482 | 2.0 | paperclip.slice | `paperclipai run -d /srv/paperclip/data` |
| 338 | 5.7 | k3s-agent | `k3s agent` |
| 315 | 32.5 | kubepods (burstable) | `cilium-agent` |
| 292 / 235 / 225 / 190 / 136 | 0.0-3.8 | openclaw-gateway-main | five `codex app-server` children |
| 223 | 0.1 | docker container | `uvicorn server:app --port 18793` (promptguard) |
| 155 | 0.5 | openclaw-gateway-edge | one `codex app-server` child |
| 126 | 7.3 | openclaw-gateway-main | `python3 /opt/hydra/scripts/credit-review.py decide --mode judge` |

Observed directly: `credit-review.py decide --mode judge` runs as a child of the **main gateway's**
cgroup, and `credit_review/owing_proof.py` runs under host **cron** (`credit-verify-outbound.sh`).
Those are two different schedulers touching the credit-verification path.

## Not yet measured (carried to the next steps)

- Which volume each service reads and writes (open files, env-driven store paths).
- Sizes and writers of `/var/lib/credit-trust/ledger.sqlite3` and `/var/lib/hydra-credit-verify/proof.sqlite`.
- Per-pod CPU and memory inside `kubepods.slice`.
- systemd timers and `/etc/cron.d` entries, each with its own CPU and memory.
- Gateway cron wall times (`cron_run_receipts`).
