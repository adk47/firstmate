# node-8 contention map

Measured 2026-11-11 and 2026-11-12 on ovh-node-8 (`ssh root@40.160.32.80`), read-only. This is the
map only: what runs there, what it costs, what it touches, and what ties it to the host. It is not
a plan. The measurements behind every number are in `evidence/01` to `evidence/07`.

## First: the host is not saturated

The premise of this work was that node-8 is the bottleneck. The measurements do not support that.

| measure | value | when |
|---|---|---|
| CPUs / memory | 24 / 63,904 MiB | |
| CPU busy, daily average | 13.0% to 22.5% | 11 days, 11-01 to 11-11 |
| CPU busy, worst 10-minute sample | 55.68% | 11-03 |
| load average above 24 | 0 of 1,540 ten-minute samples | 11 days |
| memory in use by processes | 14,993 MiB of 63,904 | 11-12 16:26Z |
| memory pressure (PSI) | 0.00 on every window | 11-11 16:30Z |
| swap | 3,244 of 4,095 MiB used, not being paged in or out | 11-11 |
| root disk | 630 G of 875 G (76%) | 11-11 |
| load average | 2.15 / 2.79 / 2.97 | 11-12 20:04Z |

Ten-minute averages hide shorter bursts, and no day in the window had the CI wave the 10-27 report
described (load 21 to 39). What the measurements do show is concentration, not exhaustion:

- One process, the main gateway, has peaked at 18,848 MiB and no service on the host has a memory
  limit.
- A deploy of this repository restarts both gateways. On 11-12 that closed Caroline's gateway to new
  work for 34 s and the main gateway for 98.5 s, and cut off a credit job 37 minutes into its run
  (evidence 04).
- The decision ledger was open in some process for 87% of a sampled hour, the proof store for 89%
  (evidence 07).

## How to read the labels

| label | meaning here |
|---|---|
| **correctness-coupled** | It writes the decision ledger or the proof store, or takes one of the host-local locks that keep two writers apart, or writes the kill files other jobs obey. Run it on another host and the write fails or the exclusion silently disappears. |
| **data-pinned** | It does not write those, but it reads a file that exists only on node-8's disk and that something else there produces: the ledger or proof store read-only, a gateway's own directory, another job's output. It can move only with that data, or once that data can be reached over a network. |
| **habit-pinned** | Neither. Everything it needs it reaches over the network, plus at most a private state directory, a kill file of its own and secrets from an env file, all of which travel with it. Nothing found requires node-8. |
| not established | I could not back any of the three. The reason is given. |

Basis for each label: **O** = observed in the 65-minute samples (evidence 07); **S** = read from the
script and the Python files it imports (evidence 05 and the pass described under "Limits");
**U** = from the unit or cron line only.

Two limits on the labels, stated once:

- **O is one hour.** A job that did not run, or did not open a store, in that hour can still open
  one on another day.
- **S misses a path built at run time.** `request-comms` is the proof: the static pass found no
  store in it, the sampler saw it writing `/var/lib/hydra/request-comms/state.sqlite`. So
  "habit-pinned (S)" means nothing was found, not that nothing exists.

## The volume

There is one. Every host path below is on `/dev/nvme0n1p3` (ext4, mounted `/`). A second 894 G
device, `nvme1n1`, has no partition and no mount point; what uses it was not determined.

| what | path | size | can it live elsewhere as built |
|---|---|---|---|
| decision ledger | `/var/lib/hydra/credit-review/ledger.sqlite3` | 833 MiB, 1,012,654 decisions, WAL | No. Opened as a local SQLite file by every reader and writer; nothing serves it. |
| proof store | `/var/lib/hydra-credit-verify/proof.sqlite` | 1,214 MiB, rollback-journal mode | No, same reason. |
| model-call log | `/var/lib/hydra/credit-trust/ledger.sqlite3` | 17 MiB | No, same reason. |
| other credit stores | `doc-verify.sqlite` 2,580 MiB, `dsp-verify.sqlite` 772 MiB, `name-index.sqlite` 238 MiB | | No, same reason. |
| write locks | `/var/lib/hydra/credit-status-writes.lock`, `credit-review/apply.lock`, `clickup-drain.lock`, per-job `tick.lock` | | No. A file lock excludes only processes on the same host. |
| kill and enable files | `/etc/hydra/*.disabled`, `*.enabled` | 23 entries | No. A job on another host cannot see them. |
| main gateway state | `/root/.openclaw-main` | 93.9 GiB (agents 83.4) | With the gateway only. |
| edge gateway state | `/root/.openclaw-edge` | 21.8 GiB | With the gateway only; its token-refresh lock is a symlink into the main gateway's directory (read 20:04Z). |
| deployed code and agent workspaces | `/opt/hydra` | 172.5 GiB (workspaces 140.8, audit 28.9) | Code can be anywhere. Workspaces are read and written by agents in the main gateway. |
| pod volumes | Longhorn CSI devices `sda` to `sde`, 1 to 2 G each | | Not established: replica placement was not read. |

The brief placed the ledger at `/var/lib/credit-trust/ledger.sqlite3`. That path does not exist.

There is no transaction spanning the ledger and the proof store anywhere in the code (no
`ATTACH DATABASE` outside tests). A job that writes both makes two separate commits.

## Map A: long-running services

CPU is cores. "Since start" is the service's own counter divided by its uptime; "window" is a
measured interval. Memory is process memory (anon), not page cache.

| service | CPU | memory MiB (peak) | what it touches | must sit with ledger or proof store | label |
|---|---|---|---|---|---|
| `openclaw-gateway-edge` (Caroline) | 0.066 over 40 min once started; 0.104 over 12 h on 11-11; 886 CPU-s in the 16 min after a restart | 2,110 to 2,139 (4,444) | `/root/.openclaw-edge`; tool scripts under `/opt/hydra/workspaces/support`; reads `/var/lib/credit-trust/proof-on-file.json`; appends `/var/lib/hydra/injection-watch/ledger.jsonl`; token lock inside the main gateway's directory | Not seen: no process in its cgroup opened either in the hour, and the plugin code names neither. Its tool scripts did not run in the hour and three of the four are not in this checkout, so for them: not established. | **data-pinned** (O, S) |
| `openclaw-gateway-main` (the process) | 0.115 over 40 min; 0.627 over 12 h on 11-11; 0.76 over the 3 h 27 min life of the process replaced at 16:28Z | 5,130 (18,848 on 11-11; 14.8 GiB for the replaced process) | `/root/.openclaw-main`; `/opt/hydra/workspaces`; the one login store for the model subscription | No. It opened neither. It is the parent of the jobs that do (Map B). | **data-pinned** (O) |
| `cron` | 0.172 over the hour for its children; 0.24 since start | 251 to 2,050 (11,221) | whatever its children touch (Map B) | per child | per child |
| `k3s-agent` and its 58 running pods | pods 1.2 (0.96 of that is cilium and two coredns); agent 0.15 over 60 s but 1.56 to 1.74 since start, unexplained | pods 6,544 by `kubectl top`; agent 602 (23,813) | Longhorn volumes; container images on the root disk | None found. The pods are `muso-dev`, ArgoCD, monitoring, Longhorn and cluster plumbing; no `muso-prod` pod runs here. One pod, `monitoring/credit-trust-export` (665 MiB), has a name that suggests it reads credit data; whether it mounts a host path was not read. | **habit-pinned** (O), `credit-trust-export` not established |
| runner `hydra-node8` (ran the deploy) | 0.089 since start; 0.021 in the hour | 352 (5,784) | writes `/opt/hydra`, signals both gateways | Not as a writer of either. It has to be on the host it deploys to. | **data-pinned** (O) |
| six other GitHub runners | 0.031 to 0.082 each since start | 34 to 43 each idle (3,461 to 6,516) | runner work directories, not measured | Which workflows they still run was not enumerated. `AGENTS.md` says the repository's PR checks moved to in-cluster runners on 10-27 and that deploy pre-flight, QA hand-off and dispatch stay here because they read this host. | not established |
| `paperclip` | 0.052 over 35 days | 611 (846) | `/srv/paperclip/data`, size not measured | None seen | **habit-pinned** (U) |
| `muso-mcp-gate` and `muso-mcp-cloudflared` | 5.7 CPU-s in 20 days | 11 and 14 | `/opt/muso-mcp-gate/data/muso-mcp-auth.db` | None seen. What it forwards to was not read. | **habit-pinned** (O, U) |
| `hydra-promptguard` (Docker) | 0.11% of a core | 201 of a 1 GiB limit | none seen | No. It listens on 127.0.0.1:18793 only, so its callers reach it by a loopback address. | **habit-pinned** (U) |
| `intercom-webhook` | 4.5 CPU-s in 8.3 days | 1 (12) | `/etc/hydra/intercom-webhook.env` | None seen. It is idle. | **habit-pinned** (U) |
| Docker `cto-pg-9925` (postgres:17), `silly_keldysh` (mongo:7) | 0.00% and 0.26% | 5 and 23 | not read | Owner and contents unknown. The Mongo container is published on every interface, port 33313. | not established |

Fifteen further running services are the operating system. They belong to the host.

## Map B: scheduled work

Work is started four ways: the main gateway's own scheduler (37 recurring jobs), host cron (8
crontab lines, 51 lines in `/etc/cron.d`), 71 systemd timers, and by hand from a login session
(evidence 06). CPU and memory are from the hour sampled unless marked; "-" means the job did not
run, or used under 1 CPU-s, in that hour. "Wall" is elapsed time per day from the gateway's run
receipts; it is mostly waiting, not processor.

### Correctness-coupled

| job (started by) | CPU-s in the hour, peak MiB | what it opened or names | basis |
|---|---|---|---|
| `credit-trust-decide-15m` (main gateway): `credit-review.py decide` | 49, 133; wall 6.56 h/day | ledger read-write 375 s; model-call log read-write; takes `credit-status-writes.lock` | O, S |
| `credit-review-shadow-4h` (main gateway): `credit-review.py review` | 2, 62; wall 0.77 h/day | ledger read-write 447 s; model-call log read-write | O |
| `credit-verify-proof-file` (main gateway): `credit-proof.py file-recent` | 9, 239; wall 5.45 h/day; 17 of 65 runs hit the 3,000 s limit | proof store read-write 3,396 s of the 3,899 s sampled | O |
| `credit-verify-proof-stage2` (main gateway) | 2, 92 | proof store read-write 27 s | O |
| `credit-verify-proof-intercom` (main gateway) | - | names the proof store; same entry script as the two above | S |
| `credit-approval-auditor-hourly`, `credit-approval-audit-digest-daily`, `credit-approval-audit-metrics-weekly`, `credit-provisional-tracker-0600` (main gateway) | - | subcommands of `credit-review.py`, which names ledger and proof store. Which of these subcommands write was not resolved; labelled on the cautious side. | S |
| `credit-dsp-verify-d5b`, `credit-profile-link-proposals` (main gateway) | - | names the ledger (`link_proposals` is a ledger table) and `dsp-verify.sqlite` | S |
| `credit-verify-outbound` (host cron, every 2 h when these figures were measured; hourly since 2026-11-13; also started from login sessions at 16:33Z and 17:03Z on 11-12) | not in the CPU sample when run by hand | ledger read-write (`uvn-status`, `claim-proof-ask`); model-call log read-write (`credit-batch-judge.py`); holds `ledger.sqlite3.credit-group.run.lock` 729 s and `tick.lock`; obeys and writes its own kill file | O |
| `hydra-paid-status`, `hydra-claim-status` (host cron) | - | `paid-status/daily.sh` names the ledger. Read or write not resolved; labelled on the cautious side. | S |
| `sentinel-demote`, `sentinel-demote-fast`, `sentinel-propose` (timers) | - | writes the kill files in `/etc/hydra` that the credit jobs obey | S |
| `clickup-drain-profile-claim` and the other `clickup-drain-*` timers | - | coupled to each other, not to the ledger: they share `/var/lib/hydra/clickup-drain.lock` and one daily write budget | S |

### Data-pinned

| job (started by) | CPU-s in the hour, peak MiB | what ties it | basis |
|---|---|---|---|
| `hydra-verification-steward`, 7 cron lines, scripts kept in `/var/lib/hydra/verification-steward/bin` outside the repository | under 5 in total | `s1_tick.py` had the ledger open read-only for 2,343 s; `throughput.py`, `comms.py`, `monitor.py`, `awards.py`, `c2class.py`, `rates.py` read ledger, proof store, `doc-verify.sqlite`, `dsp-verify.sqlite` read-only | O |
| `ops-completeness` (host cron): `completeness-snapshot.py` | - | ledger read-only 390 s | O |
| `verification-queue-report` (host cron) | 5, 90 | ledger read-only | O |
| `credit-decider-support-watch` (host cron); `hydra-approval-stamps-audit`, `hydra-refund-confirm-audit` (timers) | - | name the ledger | S |
| `hydra-churn-risk` (host cron): `cancel_alert.py` and the nightly | 2, 177 | `churn/support-state.sqlite` read-only 627 s; `churn/sources.py` names ledger and proof store | O, S |
| `credit-doc-verify` (main gateway) | -; wall 0.91 h/day | `doc-verify.sqlite` (2,580 MiB) | S |
| `credit-decide-watchdog-hourly`, `-shadow-daily`; `credit-digest-dm-0800-ny`; `credit-jan-tray-0700`; `credit-verification-fraud-muso-only-snapshot` (main gateway) | - | read or write credit output files under `/var/lib/hydra*` that other jobs here produce or consume | S |
| `hydra-cs-proof-feed` (host cron); `cs-credit-proof-file`, `cs-email-filing-watch`, `cs-zero-request-watch`, `cs-proof-quota-guard`, `cs-novelty-watch` (host cron, scripts in `/usr/local/bin` outside the repository) | under 1 | proof store or ledger read-only, or a credit kill file. `cs-novelty-watch` is switched off by a date test in its cron line. | S |
| fraud lens (root crontab, hourly, scripts in `/opt/firstmate/fraud-lens` outside the repository) | 3, 66 | `hold_silent.sh` names the ledger; the rest is network. Who reads its output was not traced. | S |
| `gdpr-pipeline-tick`, `gdpr-hide-batch`, `clickup-drain-data-deletion` (timers) | 5, 41 | share `/var/lib/hydra-gdpr/erasure.sqlite` (1.7 MiB), written by the tick. Tied to each other, not to the ledger. | O, S |
| `ops-intake-digest`, `ops-intake-redteam` (timers) | - | `/var/lib/hydra/ops-intake`, shared with the ops-intake plugin inside the main gateway | S |
| 17 agent-turn and heartbeat jobs, and the one-shot jobs including QA reviews (both gateways) | inside the gateway process | they are turns of an agent in the gateway; they go where it goes | O |
| watchers of the gateways (host cron): `openclaw-watchdog`, `stuck-lane-watchdog`, `cron-health-watchdog`, `fallback-swallow-watchdog`, `slack-freeze-miss-check`, `codex-keepalive`, `codex-quota-refresh`, `caroline-rag-index-watchdog`, `agent-soul-delivery-guard`, `memory-health-check` | `openclaw` CLI calls from cron: 45 in total | read this host's journal, `systemctl`, or a gateway's directory | S |
| gateway housekeeping (timers): `codex-canonical-refresh`, `codex-edge-mirror`, `hydra-main-prune-restart`, `hydra-peer-labels`, `hydra-session-thread-retention@main`, `@edge`, `model-chain-watchdog`, `hydra-daily-audit`, `hydra-tmp-reaper`, `hydra-weekly-cleanup`, `hydra-jev-shadow-prune`, `clickup-todo-dedupe` | under 3 | same | S |
| `cs-selfserve-backlog`, `-collect`; `caroline-safety-daily`; `merge-outcome-notify`; `qa-review-reconcile`; `qa-approval-retry`; `support-changelog-sync`; `sync-app-pricing`; `sync-platform-llms` (timers) | under 1 | read Caroline's session files, or files shared with a gateway plugin, or write into agent workspaces, or the QA queue at `/var/lib/hydra-qa/queue.sqlite` | S |

### Habit-pinned

Nothing was found that ties these to node-8. None of them is among the 45 largest CPU users in the
sampled hour; the daily ones did not fire in it.

| job (started by) | what it carries if it moves | basis |
|---|---|---|
| `intercom-backlog-count-2h` (main gateway), wall 1.19 h/day | an env file | S |
| `Ad screening` (main gateway, every 5 min) | its own kill file | S |
| `cron-muso-outreach-monday`, `ads-inquiry-watchdog`, `stale-ticket-watchdog`, `ghl-api-watchdog`, `mercury-token-watchdog`, `refund-credit-overlap-watchdog`, `merge-landing-watchdog`, `prod-log-alert-watchdog`, `sentry-issue-watchdog` (host cron) | alert-stamp files; an env file; `prod-log-alert-watchdog` its own kill file; `sentry-issue-watchdog` reads settings from the main gateway's config file | S |
| `hydra-verifier-eval` (host cron) | its output directory and kill file | S |
| `merge-queue-census`, `merge-queue-variant-queue` (host cron, scripts in `/root/q1` outside the repository) | the scripts themselves | S |
| `cs-systemic-support-intake` (host cron, scripts in `/root/fmc1-intake` outside the repository) | the scripts and a kill file | S |
| `clickup-sla-digest`, `close-merged-tickets`, `intercom-legal-unanswered-watchdog`, `intercom-rights-holder-watchdog` (timers) | nothing found | S |
| `cs-sla-report`, `cs-needs-human-digest`, `cs-needs-human-digest-delta`, `resolve-notify`, `resolution-matcher`, `close-resolved-conversations`, `close-duplicate-conversations`, `overdue-verification-notifier`, `intercom-intake-watchdog`, `caroline-behavior-digest` (timers) | a Slack token, which they read by default from the main gateway's config file (`SLACK_NOTIFY_CONFIG` overrides it) | S |
| `request-comms` (timer, hourly) | a private 178 MiB SQLite store; nothing else opened it in the hour | O |
| `hydra-release-watch`, `hydra-release-digest` (timers) | `/var/lib/hydra-release` (2.5 GiB) and an env file | S |
| services from Map A: the 58 k3s pods, `paperclip`, `muso-mcp-gate` with `muso-mcp-cloudflared`, `hydra-promptguard`, `intercom-webhook` | see Map A | |

By weight the habit-pinned set is the pods (1.2 cores, 6.5 GiB, of which 0.96 cores is cluster
networking that exists on any node) and `paperclip` (0.05 cores, 0.6 GiB). The scheduled jobs in it
are too small to measure in an hour. **The two things that use the most on this host, the main
gateway and the credit jobs it starts, are not in it.**

### Not established

| job | why |
|---|---|
| 141 short `kubectl` runs under host cron: 487 CPU-s in the hour (0.125 cores), 0.9 to 1.6 GiB each for 5 to 10 s | The largest scheduled CPU user after the gateways. Their parent job was not captured (evidence 07). |
| `Realtime MRR Movement`, `Daily SaaS Recap`, `Weekly SaaS Recap` (main gateway) | scripts live under `workspaces/finance`, not in this checkout |
| `claim-proof-check-c2` (host cron; 8 CPU-s, 518 MiB) | script in `/opt/claim-lane-c2`, not read |
| `hydra-audit-push` (root crontab, every 10 min; `rsync` 41 CPU-s), `infra-sweep-mon`, `post-release-watch` | scripts outside the repository, not read |
| `credit-precedent` (timer, every 15 min), `hydra-company-finder-cache-refresh`, `devops-envset-vault-renew` | command is inline in the unit; body not resolved |
| `claim-list-build`, `caroline-monitor`, `support-resolution-daily`, `credit-outbound-watchdog` | scripts newer than this checkout's base |

## Limits

- The process sample is one hour (16:16Z to 17:21Z on 11-12) with a deploy inside it, covers
  `system.slice` only, and dropped processes older than two hours and shell wrappers. The labels
  marked O rest on that hour.
- The static pass follows Python imports fully and shell scripts two calls deep, and ignores
  comments. It cannot see a path assembled at run time or supplied by an env file.
- Read versus write was resolved only where the sampler saw the file open. Where a row says "names
  the ledger", the mode is unknown and the label is the cautious one.
- Scripts outside the repository (`/var/lib/hydra/verification-steward/bin`, `/usr/local/bin/cs-*`,
  `/opt/firstmate/fraud-lens`, `/root/q1`, `/root/fmc1-intake`) were scanned for store names on the
  host, not read line by line.
- Line numbers and file lists are from this branch's base (`466feac87`). node-8 ran `8b9e7568` and
  then `fa1c3072` during the measurement.
- Not measured at all: network traffic between services, disk I/O per service, and per-pod figures
  beyond one `kubectl top` reading.
