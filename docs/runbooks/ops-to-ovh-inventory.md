# Recurring ops: Mac → OVH inventory (ops-to-ovh-m1, 2026-10-26)

Captain, 26 Oct ~21:15Z: *"make sure all of the operations activities for credits etc
actually runs on OVH not my computer"*. This is the read-only inventory of every recurring
job found on the captain's Mac at 22:00–22:40Z, where each one runs after the move, and
the rule used to decide what has to move.

Sources read (read-only): `crontab -l`, `launchctl list` + every
`~/Library/LaunchAgents/ai.*.plist`, `ps -axo pid,ppid,etime,command` (orphaned `nohup`
/ `setsid` loops traced to their cwd with `lsof -d cwd`), the firstmate `data/*/` scripts
those loops run, and node-8's `/etc/cron.d`, root crontab and `systemctl list-timers`.

## The rule

| class | what it is | where it must run |
|---|---|---|
| **OPS** | does something outside the Mac: writes a prod/node-8 file another job reads, sends or queues a user message, posts to Slack/Intercom/a board, pushes a metric, approves/holds/closes anything, or produces a report a person or job other than firstmate reads | **OVH**: node-8 `/etc/cron.d` (hydra) or a k8s CronJob (H-DevOps) |
| **FEED** | only reads OVH state and appends to a firstmate `state/*.status` / inbox on the Mac (a supervisor wake-up). If the Mac is asleep, firstmate is asleep too, so nothing is lost | may stay on the Mac (firstmate supervision, firstmate 002) |
| **DEV** | Mac-local tooling: proxies, wiki, orca/pane hygiene, the firstmate supervisor itself, lane ticks that only ring an agent pane | stays on the Mac |
| **ONE-SHOT** | a dated single run or a loop with a hard end inside 7 days, owned by a live lane, mid-wave | finish where it is; never moved mid-batch |

AI inside OVH ops jobs: default OpenRouter `deepseek/deepseek-v4.1-flash-1017`
(cost + speed). CLIProxyAPI token pool only where Fable/Opus-class reasoning is needed,
stated per job. Never `better-ccflare` (:8080), never `litellm` (:4000), never the Mac.
**None of the OPS jobs below makes an AI call** (checked: no OpenRouter / Anthropic /
cliproxy / :8080 / :4000 reference in any of their scripts), so none needs a model.
Credit-trust judgement keeps its own ladder (`scripts/credit_trust/llm.py`, Codex on the
subscription → capped OpenRouter fallback) and is unchanged by this move.

## Before / after — OPS jobs (credits, claims, merges, support, messages, sentinels, reports, fraud lens, steward ticks)

| # | job (owner lane) | cadence | before (22:00Z) | calls | AI | after | how |
|---|---|---|---|---|---|---|---|
| 1 | **Proof-on-file feed** `cs-proofs.json` for the credit-trust decider (cs-systemic-c2, ex cs-systemic-issues-lane-c1) | hourly :21 | **Mac** launchd `ai.muso.fmc1.proof-hourly` (KeepAlive loop); pulled the Intercom token from Vault **to the Mac** every hour | Intercom API, support@ Gmail via `gog` on node-8, replica `users` (psql via node-1), hydra ledger (ssh), writes node-8 `/var/lib/credit-trust/inputs/cs-proofs.json` | none | **node-8** `/etc/cron.d/hydra-cs-proof-feed` → `scripts/cs-proof-feed.sh` | this PR; state moved to `/var/lib/hydra/cs-proof-feed/`; kill switch `/etc/hydra/cs-proof-feed.disabled`; logs `journalctl -t hydra-cs-proof-feed` |
| 2 | Claim-proof code check + board digest (claim-lane-resume-c2) | daily 07:30Z | **Mac** crontab `claim-lane-resume-c2/work/proof-check/proof-check-cron.sh` | node-8 send log, core-backend claim modules, prod claim-proof secret (on the Mac), credit-trust-board ingest | none | **node-8** `/etc/cron.d/claim-proof-check-c2` (installed by c2 21:30Z, `/opt/claim-lane-c2/core-backend/scripts/claim-proof-check-cron.sh`) | Mac crontab line must go before 07:30Z or the digest posts twice; durable form = the c2 core-backend PR |
| 3 | Claim-proof code check, superseded copy (claim-flow-fix-fable-c1) | daily 07:30Z | **Mac** crontab `claim-flow-fix-fable-c1/work/proof-check-cron.sh` (reads a stale local `asked-claims.jsonl`) | same as #2 | none | **retired** (re-pointed to #2 by firstmate 008) | remove the Mac crontab line |
| 4 | Paid queues daily line + backlog/silence gauges (paid-sla-closer) | daily 09:02Z (hourly :02, gated to 09Z) | **Mac** crontab `~/.cache/muso/psc/daily-0900.sh` | Trino replica via ssh node-1, Prometheus | none | **reclassified FEED, stays on the Mac** | its only output is a line in firstmate's `state/paid-sla-closer.status` + a local TSV; the same paid queues reach the captain every 30 min from node-8 (#8). Firstmate may overrule; the port is ~40 lines |
| 5 | Fraud-lens hourly tick (fraud-lens-monitor-f1) | hourly :01 | Mac `scratch/fraud/loop.sh` **stopped 22:02Z** (RUN file removed; last Mac tick 22:00Z) | replica via `kubectl exec core-backend-api`, in-cluster industry-api | none | **node-8** root crontab `1 * * * * /opt/firstmate/fraud-lens/cron_tick.sh` (lane, 22:02Z) | durable form: follow-up (see below) |
| 6 | Verification-ops steward probe (verification-ops-steward-s1) | :07/:37 | moved by the lane 21:12Z | Trino, ledgers ro, Intercom search, ClickHouse | none | **node-8** `/etc/cron.d/hydra-verification-steward` | durable form: follow-up (see below) |
| 7 | Daily credit-status run (paid-wave-runner-p2) | 00:30Z + 15:00Z | already node-8 (hand-installed 19:23Z) | credit-review.py runner, Intercom, email route | none | **node-8** `/etc/cron.d/hydra-paid-status` | durable form: follow-up; sends held under `[key=p2-spam-guard]` |
| 8 | Captain 30-min queue DM + 5-min backlog sentinel (verif-slack-report-r1) | */30, */5 | already node-8 | Trino, ledger ro, Slack DM | none | **node-8** `/etc/cron.d/verification-queue-report` | codified in https://github.com/Muso-AI/hydra/pull/1371 |
| 9 | G9 paid never-contacted gauge (credit-lane-relief-c3) | */30 | **Mac** `nohup g9/loop.sh` (48 runs, ends ~05:45Z 10-27) | node-8 ledger, core-backend-api exec, Pushgateway | none | **k8s CronJob** https://github.com/Muso-AI/H-DevOps/pull/4449 (open) | ONE-SHOT stop-gap until #4449 merges; if it is not merged by ~05:45Z the gauge goes stale (alerts on it) |
| 10 | Credit-system steward tick (cmux-credit-system-lane) | :03/:33 | **Mac** launchd `ai.muso.lane-tick-credit` rings an agent pane; the agent measures SLA / never-contacted / held queue | — (agent turn on the Mac) | the lane agent's own model | **measurement now on OVH**: #8 (queues + sentinel), #6 (steward scoreboard), #9 (never-contacted). The ring itself is DEV (an agent tick, no side effect of its own) | firstmate: unload the launchd once the lane confirms nothing else in its tick writes outside the Mac (lane silent since 06:54Z) |
| 11 | CS systemic-class hourly tick (cs-systemic-c2) | hourly :05 | **Mac** launchd `ai.muso.lane-tick-cs-systemic` rings an agent pane | — (agent turn) | lane agent | the recurring data part is #1 (proof feed) + node-8 `intercom-intake-watchdog` / `cs-selfserve-backlog` timers; the "drive a fix" part is agent work (DEV) | firstmate: keep as a DEV ring or retire; it no longer carries an ops job |

## Verified state, 2026-10-27 08:15Z

| # | job | runs on | evidence |
|---|---|---|---|
| 1 | proof-on-file feed | **node-8** `/etc/cron.d/hydra-cs-proof-feed` | 9/9 hourly runs 23:21Z→07:21Z `installed cs-proofs.json` in `journalctl -t hydra-cs-proof-feed`; trial 22:29Z identical to the Mac's 22:22Z output (82,758 entries, 0 diff); Mac launchd unloaded, plist renamed `.moved-to-node8` |
| 2 | claim-proof check c2 | **node-8** `/etc/cron.d/claim-proof-check-c2` | cron fired 07:30:01Z; Mac crontab line removed |
| 3 | claim-proof check c1 (superseded) | **Mac** crontab, `30 7` local = 11:30Z | still present; no-op (empty `asked-claims.jsonl`, exits before the board post) — owner/firstmate to delete the line |
| 4 | paid-sla daily line | Mac (FEED) | see #4 above |
| 5 | fraud-lens tick | **node-8** root crontab | ticks 07:01Z, 08:01Z in `/opt/firstmate/fraud-lens/ticks/` |
| 6 | steward probe | **node-8** cron.d | `ticks.jsonl` current (proof_on_file 07:12Z) |
| 7 | daily credit-status | **node-8** cron.d | `daily.log` 01:56Z run |
| 8 | queue DM + sentinel | **node-8** cron.d | `/var/log/verification-queue-report.log` current |
| 9 | G9 never-contacted gauge | **nowhere** since 05:48Z | Mac stop-gap ended at run 48 (05:48Z); https://github.com/Muso-AI/H-DevOps/pull/4449 still OPEN — gauge is stale until it merges |
| 10, 11 | lane-tick-credit / cs-systemic | Mac (DEV ring) | measurement moved (#1, #6, #8); rings remain, firstmate's call |

**Mac ops count: 11 → 1** (#3, a no-op line awaiting deletion). Plus #9 which is on neither host until H-DevOps #4449 merges.

**Bridge caveat.** #1's code sits under `/var/lib/hydra/cs-proof-feed/bin/` — hand-staged 22:28Z, byte-identical to this PR's `scripts/cs-proof-feed.sh` + `scripts/cs_proof_feed/`. That is a script copy outside a deploy. On deploy, `install-aux-units.sh` rewrites `/etc/cron.d/hydra-cs-proof-feed` to `/opt/hydra/scripts/cs-proof-feed.sh`; then delete `/var/lib/hydra/cs-proof-feed/bin/`. #5, #6 and #7 are hand-installed by their lanes in the same way.

## Second pass, 2026-10-27 20:15Z (captain: "make this a durable process that does not rely on my computer")

User communication itself does **not** depend on the Mac. The daily status/ask run is
`/etc/cron.d/hydra-paid-status` on node-8, running repo code `/opt/hydra/scripts/paid-status/daily.sh`
(https://github.com/Muso-AI/hydra/pull/1384, deployed). The hand-installed `/var/lib/hydra/paid-status/bin` copy is unused.
It is **not** caught up, though. At 19:37Z the steward counted 139 paid / 1,492 free users with open credit
requests who have never been told anything, and 116 paid / 988 free pending claims with no note.
The senders are held on OVH, not on the Mac: the 20:01Z run STOPPED on a failed send, `[key=sender-map-1027]`
freezes them, `/var/lib/hydra/paid-status/daily.lock` is held by a stop-switch, and
`/etc/hydra/verification-queue-report.disabled` + `backlog-sentinel.disabled` are set. Owners:
verify-ask-wiring-h2 / paid-wave-runner-p2, decision firstmate/Fable.

| Mac job | class | decision | evidence / PR |
|---|---|---|---|
| crontab `claim-flow-fix-fable-c1/.../proof-check-cron.sh` | superseded ops | **deleted 20:15Z** | node-8 `claim-proof-check-c2` fired 07:30Z; crontab backup `data/ops-to-ovh-m1/crontab.before-20261027T2015Z` |
| crontab `~/.cache/muso/psc/daily-0900.sh` | fleet report (writes only firstmate status) | stays with the fleet; the same paid queues run on node-8 (`verification-queue-report`, currently disabled) | — |
| crontab encore `tracker/refresh.sh` | dev page on 127.0.0.1:8787 | stays (localhost only) | — |
| launchd `lane-tick-credit`, `-cs-systemic`, `-infra-monitor`, `-feed` | agent-fleet ticks (fm-send to a pane) | stay with the fleet | their measurements are on node-8 (#1, #6, #8) |
| launchd `pr-flow` | fleet: reads Fable verdict logs, fm-send, firstmate state | stays with the fleet | H-DevOps `scripts/pr-flow/pr_flow.py` docstring |
| launchd `sentry-bridge`, `fm-deadman`, `orca-cleanup`, `ccflare-access-sync` | firstmate / Mac tooling | stay | — |
| launchd `lane-data-system-guards` | **ops actuator**: the 2119(c) trip dispatches `paid-sync-guard` | **move**: node-1 `lane-guards.timer` (H-DevOps `scripts/devops-agent/lane-guards.sh`) already pages, but has been shadow-only since 10-05; promote it to live dispatch | asked cmux-data-system-lane 20:1xZ |
| nohup `fanout-paced-loop-gated.sh` / `fanout-paced-16-gated.sh` / `paidsync-guard-window.sh` | **ops**: drives the paid fan-out shards | **move** after the 1820Z-1027 wave | asked cmux-data-system-lane |
| feed chain `ledger_to_send.sh` → `paced_send.sh` | **user-facing** feed posts | **move** (CronJob/timer on publish) after the running ds | asked cmux-feed-lane |
| G9 never-contacted gauge | ops metric | **done**: CronJob `monitoring/credit-never-contacted-pusher` live (last run 20:06Z) | https://github.com/Muso-AI/H-DevOps/pull/4449 |

## FEED — stays on the Mac (firstmate supervision)

| job | cadence | what it does |
|---|---|---|
| `catalog-new-credit-lane-f1/mac-scripts/paced_reporter.sh` | 5-min poll | tails node-1 `/root/fmcnl_drive/paced.log` (the replay driver itself runs on node-1) → firstmate status |
| `messaging-monitoring-m1/mail-watch.sh loop` | hourly :05, ends 10-30 23:59Z | Mailgun stats + Prometheus alerts read on node-1 → `mail-watch-log.md` + status line on a gate breach |
| `fm-daily-pr-digest/digest/self-ring.sh` | daily 05:00Z | builds the PR digest from GitHub into firstmate data |
| `sentry-bridge/run.sh` (launchd) | 5 min | firstmate's own Sentry poll → firstmate inbox |
| `fraud-lens-monitor-f1/scratch/fraud/relay.sh` | on demand | copies node-8 fraud-lens outputs into firstmate data |
| `dunning-recovery-retain-r1/scratch` v5 probe loop | 6 h × 13 | read-only core probe → lane log |
| `encore-goal-loop-e2/tracker/refresh.sh` (crontab @hourly) | hourly | regenerates a localhost:8787 tracker page (read-only probes via node-1) |

## DEV — Mac-local tooling, stays

`ai.cliproxyapi`, `com.better-ccflare.server`, `ai.litellm.proxy`, `ai.muso.ccflare-access-sync`,
`ai.claude-pool-health`, `ai.llm-wiki.reconcile*`, `ai.muso.orca-cleanup`, `ai.muso.orca-privacy-env`,
`ai.muso.fm-deadman`, `ai.muso.cmux-fleet-supervise`, `ai.muso.fleet-window`,
`ai.muso.goal-status-refresh`, `ai.muso.lane-autocompact`, `ai.muso.pr-flow` (firstmate 002:
firstmate's own supervision), `ai.muso.aa-checkin`, and the agent-ring launchd ticks
`ai.muso.lane-tick-{dags,data-system,dev,drift,encore,feed,infra-monitor,killer,nowcasting,platform,topic-infra,v4,www}`
(each only delivers a prompt to an Orca pane through `fm-send.sh`).

## Data-pipeline / infra watchers (second priority, not credits/claims/support)

These are lane-owned infra watchers, most of them dated. They are listed so the Mac count
is honest; none touches credits, claims, merges, support or user messages.

| job | lane | ends | note |
|---|---|---|---|
| `cmux-data-system-lane/bin/{thordata-watch,lane-guards,heartbeat,livefeed}.sh` (launchd KeepAlive) | cmux-data-system-lane | standing | read-only cluster vitals → lane pane / status; FEED-shaped. `lane-guards` can engage a paid-sync pause (OPS) — candidate for an H-DevOps CronJob |
| `fanout-paced-loop-gated.sh` / `fanout-paced-16-gated.sh`, `paidsync-guard-window.sh` | cmux-data-system-lane | window-bound | drives a paced fan-out with gates — OPS, mid-wave; move at the next window boundary |
| `free-track-streams-recompute-f1/tsr-watchdog3.sh` | free-track-streams-recompute-f1 | plan-bound | recompute watchdog |
| `~/.config/muso/pdp-cert/{nowcast5xx_capture,launch_watch_v4}.sh` | cmux-nowcasting-lane | standing | read-only log capture |
| `fm-api-reliability-lane/lane/{rollwatch.sh,sched_notes.sh,ra_watch.py,s3_partner_watch.py}` | api-reliability-lane | standing | read-only → lane status (FEED) |
| `v4-freshness-fix-f1/ops/ptc_tue_0400.sh`, `/tmp/fm-v4-freshness-fix-f1/d3_seq.sh` | v4-freshness-fix-f1 | Tue 27 06:00Z | ONE-SHOT; `d3_seq` applies manifests |
| `node49_v3_watch.sh` ×2 | mlc-import-off-node49-p1, v4-lane-r2 | Tue 27 12:00Z | ONE-SHOT read-only sampler |
| `cmux-feed-lane/tools/{ledger_to_send,paced_send}.sh` (ds 2026-10-24) | cmux-feed-lane | when the chain drains | ONE-SHOT paced feed send, mid-wave — must not be interrupted |

## Follow-ups (owners named)

- **Durable form for #5, #6, #7.** They already run on OVH (node-8), installed by hand by
  their lanes. Folding them into `scripts/install-aux-units.sh` means vendoring each lane's
  code into hydra. #7 is a user-facing send pipeline under an open decision
  (`[key=p2-spam-guard]`) and its owner asked for it to become a `credit-review.py`
  subcommand + timer; that is a separate PR, not a copy. #5 and #6 are read-only.
  Never hot-patch them under `/opt/hydra` (deploy drift guard): they live under
  `/var/lib/hydra/...` and `/opt/firstmate/...`, which the deploy does not touch.
- **#3** — delete the Mac crontab line `30 7 * * * .../claim-flow-fix-fable-c1/work/proof-check-cron.sh`.
- **#9** — merge https://github.com/Muso-AI/H-DevOps/pull/4449; the gauge has been stale since 05:48Z.
- **#1** — after this PR deploys, `rm -r /var/lib/hydra/cs-proof-feed/bin` (the cron line no longer points at it).
