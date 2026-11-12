# Evidence 04 - k3s pods, memory split, disk trees, and one restart observed live

Source: `ssh root@40.160.32.80` (ovh-node-8), 2026-11-12 16:25-16:30Z.

## Disclosure: one command wrote to the host

Every other step in this lane only read. One did not. At 16:25:25Z a per-namespace join created
two temp files, `/dev/shm/.n8pods.<pid>` and `/dev/shm/.n8top.<pid>` (pod names and `kubectl top`
output, no secrets), and removed them with `rm -f` in the same command. That contradicts the
"nothing was written on the host" line in evidence 01-03 for this one command, and it is an `rm`
against a `/dev/*` path on node-8, which the repo's `AGENTS.md` forbids.

Checked immediately afterwards (16:25:39Z): `/dev/null` is a character device 1:3 mode 666,
`/opt/hydra/scripts/assert-host-devnull.sh` exits 0, `/dev/zero`, `/dev/random`, `/dev/urandom`,
`/dev/tty` and `/dev/full` are character devices, `/dev/shm` is a tmpfs directory mode 1777, and no
`.n8*` file remains. The join was redone locally with no files on the host; the table below is
from that second run. The first run's totals are discarded (its `join` hit unsorted input).

## k3s pods on this node (16:25:54Z)

142 pods are scheduled on `ovh-node-8`: **58 Running**, 84 Succeeded (finished jobs, holding no
CPU or memory). All 58 running pods had a metrics row.

| namespace | running pods | CPU millicores | memory MiB |
|---|---|---|---|
| muso-dev | 28 | 41 | 2,220 |
| longhorn-system | 5 | 72 | 1,316 |
| argocd | 7 | 17 | 1,007 |
| monitoring | 4 | 37 | 869 |
| kube-system | 5 | 969 | 495 |
| ads-dev | 3 | 3 | 309 |
| muso-system | 1 | 13 | 192 |
| queuing-dev | 1 | 4 | 42 |
| messaging-dev | 1 | 1 | 34 |
| velero | 1 | 1 | 31 |
| databases-dev | 1 | 2 | 16 |
| muso-chat | 1 | 42 | 13 |
| **total** | **58** | **1,202** | **6,544** |

- Largest by memory: `longhorn-manager` 1,008 MiB, `argocd-application-controller` 852 MiB,
  `monitoring/credit-trust-export` 665 MiB, `cilium` 350 MiB.
- Largest by CPU: `cilium` 519 m, two `coredns` pods 225 m and 220 m. Those three are 964 m of the
  1,202 m total, so the workload pods themselves were using about a quarter of a core.
- Scheduler view (`kubectl describe node`): CPU requests 9,740 m (40%), CPU limits 41 cores (170%),
  memory requests 10,690 MiB (16%), memory limits 43,912 MiB (68%).
- `kubectl top node`: 5,956 m (24%), 19,653 MiB (30%). That figure is the whole host as the kubelet
  sees it, not just pods.

No running pod here is in `muso-prod` or `default`: the four `muso-prod` and 43 `default` pods
scheduled on this node are all in the Succeeded state. The running set is dev workloads
(`muso-dev`, `ads-dev`, `*-dev`) plus cluster plumbing (Longhorn, ArgoCD, Cilium, CoreDNS,
monitoring, Traefik, Velero).

## Memory split by cgroup (16:26:13Z, MiB)

`memory.current` counts page cache and kernel memory charged to the cgroup, so it overstates what
a service needs. `anon` is the part that has to exist wherever the service runs.

| cgroup | current | anon | file cache | kernel slab | swap |
|---|---|---|---|---|---|
| openclaw-gateway-main | 11,227 | **5,130** | 5,593 | 318 | 486 |
| openclaw-gateway-edge (2 min after a restart) | 2,325 | **2,110** | 146 | 8 | 0 |
| cron (all host cron children) | 4,431 | **251** | 3,544 | 631 | 112 |
| k3s-agent (agent + containerd) | 1,481 | **594** | 481 | 380 | 91 |
| kubepods (all pods) | 7,579 | **5,777** | 822 | 504 | 1 |
| user.slice (root ssh sessions) | 16,780 | **344** | 2,104 | 14,296 | 645 |
| system.slice (all services) | 27,623 | **8,872** | 14,642 | 3,782 | 2,024 |

This resolves three open items from evidence 01:

- The `cron` cgroup's multi-gigabyte charge is page cache (3,544 MiB) from files its children read.
  Its resident process memory is 251 MiB.
- `user.slice` is 14,296 MiB of kernel slab (directory and inode cache charged to login sessions)
  and 344 MiB of process memory. This lane's own `du` and `find` reads run in that slice and add
  to it; the slice total was already 14,651 MiB the day before.
- Anonymous memory across `system.slice` + `kubepods.slice` + `user.slice` is 14,993 MiB
  (14.6 GiB) on a 63,904 MiB host.

Largest swap holders by process: promptguard `uvicorn` 298 MiB, two `MainThread` (the gateway node
processes) 141 and 134 MiB, `mongod` 61 MiB, three `Runner.Listener` 31-36 MiB each.

## CPU, 60-second window (16:26Z)

| host total | gateway-main | gateway-edge | cron | k3s-agent |
|---|---|---|---|---|
| 4.13 cores | 0.55 | 1.41 | 0.32 | 0.15 |

- The edge figure was taken two to three minutes after the restart described below, so it is
  probably start-up work, not steady state. In the 90-second window a day earlier it was 0.01 cores.
- `k3s-agent` is 0.15 cores in both short windows. Its 1.744-core average since start
  (2026-11-03 22:32Z, no restarts) therefore reflects bursts outside these windows, not its steady
  state. What those bursts were was not established.

## The three large trees on the root disk

| path | size MiB | largest children |
|---|---|---|
| `/opt/hydra` | 172,508 | `workspaces` 140,821; `audit` 28,929; `plugins` 2,707 |
| `/root/.openclaw-main` | 93,919 | `agents` 83,438; `media` 5,117; `extensions` 3,105; `browser` 1,150 |
| `/root/.openclaw-edge` | 21,755 | `agents` 11,200; `media` 8,676; `extensions` 1,209 |

Together 288 GiB of the 630 GiB used. For comparison, every `/var/lib/hydra*` store put together is
about 16 GiB (evidence 02). What is inside `/opt/hydra/workspaces` (141 GiB) was not broken down.

## Observed live: a deploy restarted both gateways during the measurement

Correction (16:34Z): an earlier version of this section said the restart "was not a new deploy
landing" because `/opt/hydra/.deployed-sha` had not changed. That inference was wrong. The sha file
is written at the end of a deploy; the deploy was still running. What was measured:

- GitHub Actions run `43257759792`, workflow `Deploy HYDRA`, event `workflow_dispatch`, branch
  `main`. The runner on node-8 logged `Running job: deploy` at 16:21:30Z. At 16:33:37Z the run was
  still `in_progress` and `.deployed-sha` still read `8b9e7568` (file last written 13:08:35Z).
- Who dispatched the run was not looked up.

### Edge gateway (Caroline)

From the journal:

| time (UTC) | event |
|---|---|
| 16:23:27 - 16:23:30 | five `Reloading requested from client ... ('systemctl')`, each attributed by systemd to unit `actions.runner.Muso-AI-hydra.hydra-node8.service` |
| 16:23:33.472 | edge: `[admission] closed: restart-signal fence` |
| 16:23:33.475 | edge: `[gateway] received SIGUSR1; restarting` |
| 16:23:38 | `openclaw-gateway-edge.service: Deactivated successfully` |
| 16:23:50 | `openclaw-pre-start-heal.sh` runs `codex-edge-mirror` (converged, nothing written) |
| 16:23:59 | service started (new main pid) |
| 16:24:06.076 | `http server listening (5 plugins ...)` |
| 16:24:07.466 | `[gateway] ready` |

- Admission was closed for **34.0 seconds** (16:23:33.472 to 16:24:07.466).
- It was the third edge restart of the day (also 12:54:45Z and 12:56:04Z).
- The five reloads fall inside the deploy job's run (started 16:21:30Z) and are attributed by
  systemd to that runner's unit. That the deploy script sent the SIGUSR1 is the reading that fits;
  the script line that did it was not traced.
- Not established: what happened to customer messages that arrived in those 34 seconds.

### Main gateway (every other agent, the QA reviews, 22 scheduled command jobs)

| time (UTC) | event |
|---|---|
| 16:28:32.994 | main: `[admission] closed: restart-signal fence` |
| 16:28:32.996 | `received SIGUSR1; restarting`, `reason=gateway.restart.safe force=true` |
| 16:28:33.000 | `draining active work before restart with timeout 0ms: 1 active cron run(s)` then `forced restart requested; skipping active work drain` |
| 16:28:40 | `Deactivated successfully`. systemd: `Consumed 2h 37min 28.846s CPU time, 14.8G memory peak, 487.6M memory swap peak` |
| 16:29:02 | service started (new main pid) |
| 16:30:08.369 | `http server listening (7 plugins ...)` |
| 16:30:11.453 | `[gateway] ready` |

- Admission was closed for **98.5 seconds** (16:28:32.994 to 16:30:11.453).
- The process it replaced had run 3 h 27 min (since 13:01:49Z) and used 2 h 37 min of CPU, an
  average of 0.76 cores, with a 14.8 GiB memory peak.
- **One scheduled job was killed by it.** `credit-verify-proof-file` (agent `operations`) started at
  15:51:32Z and its receipt ends 16:28:35Z with status `error`, text `Gateway shutting down.` It had
  been running 37 minutes. This is the same job that evidence 03 shows timing out at 3,000 s in
  17 of 65 runs.
- It was the third main restart of the day: SIGTERM at 02:30:27Z, SIGUSR1 at 13:01:04Z and
  16:28:32Z.
- Also seen in the same read: 18 receipts for already-deleted one-shot jobs (15 `clio`, 3 `qa`)
  have status `running` and no end time. Only clock times were printed, not dates. Two of them
  (16:52:39 and 17:11:00) are later in the day than the read itself, so those two are at least a
  day old; the age of the rest is not established.

### What this section does and does not show

This lane did not cause either restart. It sent no signal and ran no `systemctl` verb other than
`show`, `is-enabled`, `list-units` and `list-timers`; its last read under `/root/.openclaw-edge`
before the edge restart was at 16:15:40Z.

It shows that a deploy of this repo restarts the customer-service gateway and the gateway that
runs the credit jobs, one after the other, and that a credit job in flight is cut off without a
drain. Both follow from the deploy, the two gateways and the scheduled credit jobs being one unit
on one host.

It does not show a capacity problem. Nothing above was caused by CPU or memory running short.

## Long-running services (16:30:13Z)

Every systemd service in state `running`, with what it listens on. Taken 71 s after the main
gateway came back and 6 min after the edge gateway did, so the two gateway rows are start-up
numbers; their steady figures are in evidence 01 and the memory table above.

| service | up | CPU cores, average since start | anon MiB | peak MiB | listens on | what it runs |
|---|---|---|---|---|---|---|
| openclaw-gateway-edge | 6 min | 1.243 | 2,139 | 2,355 | 18810 | `openclaw --profile edge` |
| openclaw-gateway-main | 71 s | 0.619 | 1,256 | 5,803 | 18789 | `openclaw --profile main` |
| cron | 141 d | 0.244 | 2,050 | 11,221 | - | host cron and every child it starts |
| k3s-agent | 8.7 d | 1.562 | 602 | 23,813 | 6444, 10248-10250, 10256 | `k3s agent` |
| paperclip | 35 d | 0.052 | 611 | 846 | 3100 | `paperclipai run -d /srv/paperclip/...` |
| actions.runner hydra-node8 | 98 d | 0.089 | 352 | 5,784 | - | GitHub runner (the one that ran the deploy) |
| actions.runner hydra-node8-2 | 98 d | 0.082 | 35 | 5,731 | - | GitHub runner |
| actions.runner hydra-node8-3 | 101 d | 0.079 | 37 | 5,458 | - | GitHub runner |
| actions.runner hydra-node8-4 | 9.1 d | 0.039 | 34 | 3,461 | - | GitHub runner |
| actions.runner hydra-node8-5 | 9.1 d | 0.034 | 43 | 6,516 | - | GitHub runner |
| actions.runner hydra-node8-6 | 9.1 d | 0.031 | 38 | 3,599 | - | GitHub runner |
| actions.runner hydra-node8-dispatch | 30.8 d | 0.039 | 41 | 4,005 | - | GitHub runner |
| docker | 141 d | 0.000 | 50 | 370 | - | `dockerd` |
| containerd | 141 d | 0.001 | 35 | 6,577 | - | `containerd` |
| muso-mcp-cloudflared | 134 d | 0.000 | 14 | 43 | 20241 | `cloudflared tunnel run` |
| muso-mcp-gate | 20 d | 0.000 | 11 | 89 | 9000 | `node server.mjs` |
| hydra-promptguard | 6.4 d | 0.000 | 5 | 86 | (container, below) | `docker run hydra-promptguard` |
| intercom-webhook | 8.2 d | 0.000 | 1 | 12 | 18792 | `node /opt/hydra/scripts/intercom-webhook.js` |

The remaining 15 running services are the operating system (journald, logind, sshd, resolved,
networkd, udevd, rsyslog, dbus, iscsid, smartd, timesyncd, rpcbind, upower, getty, the root user
manager), each at or under 0.001 cores and, apart from logind (159 MiB), under 10 MiB of process
memory.

The `cron` row shows 2,050 MiB of process memory at 16:30Z against 251 MiB at 16:26Z. The cron
daemon itself is a few MiB, so the difference is whatever children were running at that minute.
16:30 is a minute on which the `*/5`, `*/10`, `*/15` and `*/30` lines all fire; which children
accounted for it was not captured in this read (the process sampler covers it, evidence 07).

Seven GitHub runners are still registered and running on this host. Between them they hold 580 MiB
of process memory while idle and each has peaked between 3.5 and 6.5 GiB.

Docker containers (outside k3s):

| container | image | up | published port | CPU | memory |
|---|---|---|---|---|---|
| `hydra-promptguard` | `hydra-promptguard:latest` | 6 days | 127.0.0.1:18793 | 0.11% | 201 MiB of a 1 GiB limit |
| `cto-pg-9925` | `postgres:17` | 6 weeks | 127.0.0.1:55442 | 0.00% | 5 MiB |
| `silly_keldysh` | `mongo:7-jammy` | 3 months | **0.0.0.0:33313** and [::]:33313 | 0.26% | 23 MiB |

The Mongo container has an auto-generated name and is published on every interface. What it
holds, who started it, and whether a firewall in front of the host blocks port 33313 were not
established. Outside the k3s pods, `hydra-promptguard` is the only workload on this host with a
memory limit.
