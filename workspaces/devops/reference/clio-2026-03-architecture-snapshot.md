# DevOps — Clio-era architecture snapshot (March 2026)

> ⚠️ **HISTORICAL — a March-2026, AWS-era snapshot written in the present tense.
> Do not act on it.** Moved here from `MEMORY.md` on 2026-08-26, unchanged apart from
> the dated corrections already inline. It left `MEMORY.md` because that file is
> injected at agent bootstrap under a combined size cap, and a retired architecture
> is the last thing that should be competing for that budget with live authority
> rules. Current state: `AGENT_CURRENT_TRUTH.md` in shared-reference.

### ~~Aurora PostgreSQL Usage Map~~ → PostgreSQL 17, self-hosted _(corrected 2026-08-26: "Aurora"/"RDS"/"Athena" are retired AWS names. PG17 primary **node-17**, replica node-19, **node-18 DECOMMISSIONED**; query path is **Trino**. Mongo is self-hosted rs0, PRIMARY node-16 at IP **10.0.0.14**, not Atlas.)_

| Database | Type | Consumers | R/W | Notes |
|----------|------|-----------|-----|-------|
| Industry DB | PostgreSQL RDS | Industry API, Industry Processing, Capture Services | R/W | Catalog entities, raw entities, credits, relationships |
| Core Backend DB | PostgreSQL RDS | Core Backend API, Growth team | R/W | User accounts, auth, payments, subscriptions, teams |
| Stats DB (`platform_stats`) | self-hosted PG17 | Airflow pipelines, Industry API, **Trino** | R/W | `track_daily` (3.3B rows), `analytics_link`, `analytics_video` |
| Feed Service DB | PostgreSQL RDS | Feed Service | R/W | `activity`, `feed`, `reaction`, `follow`. Only `follow` snapshotted. |
| Industry Calculations DB | PostgreSQL RDS | Platform Pipelines | R/W | Computed metrics, milestones. Only `milestones` snapshotted. |
| Analytics DB (analytics-prod) | PostgreSQL RDS | Analytics Scheduler, Analytics Worker | R/W | Scheduler dispatch state |
| MongoDB rs0 (**self-hosted, not Atlas**) | Mongo 8.3.2 | Core Backend API, Industry Processing | R/W | PRIMARY node-16 (**IP 10.0.0.14**), SECONDARY node-13. mongot live since 2026-06-07. Decision 2026-08-18: **KEEP Mongo**. |

### Infrastructure Notes

#### AWS Infrastructure — DECOMMISSIONED (2026-04-27)
_Muso is fully off AWS as of April 2026. All services migrated to OVH K3s cluster._
_Previous cost was ~$530/day (~$15,700/mo). Now $0._
_Historical reference only — EKS, RDS, ElastiCache, MWAA, S3 all shut down._

#### Key Architecture Notes
- ~~All workloads now on OVH K3s cluster (7 nodes).~~ **10 K3s nodes + 3 bare-metal** _(corrected 2026-08-26; heavy Spark tier = node-49-pdp/node-50-pdp, +ovh-node-29 for V4)_. No remaining AWS dependencies.
- Proxy infra: Webshare (100 datacenter @ $26.62/mo + 250GB residential @ $742.19/mo) + Thordata rotating
- KEDA autoscaling: up to 100 pods/queue for analytics workers

#### ~~MongoDB Atlas~~ — HISTORICAL _(corrected 2026-08-26: Mongo is self-hosted rs0; the Atlas control plane is not how it is operated)_
- ~~Prod: product-api-prod (R60), Dev: product-api-dev (R40). MongoDB 8.0.19, ReplicaSet.~~
- Org: 6358f82168ec0b732bec2543, Project: 6358f894f47fc018ab2ad7bd
- API: Digest auth, base: `https://cloud.mongodb.com/api/atlas/v2`

#### EKS/KEDA Incident (Feb 24) — HISTORICAL, AWS decommissioned
- _Preserved for postmortem reference only. EKS no longer in use._

### Analytics Pipeline Performance Metrics
- Scheduler daily dispatch budgets: Spotify 600K, YouTube tracks 600K, YouTube social 200K, Shazam 600K, SoundCloud 500K, TikTok 250K
- 3 key DAGs run daily ~07:30-08:45 UTC (dataset-triggered)
- Scheduler CronJob at midnight UTC → ~8h lag for new Pro user priority updates
- 84 commits in 3 months (Serhii 38, Aaron 34, Oleg 11, Jay 1)
- Queue backlogs: cat-spotify peaked 7.4M, TikTok 3.7M, YouTube 3.8M

### Infra Pulse Rule
- **NEVER post recurring monitoring to shared channels more than 1x/day unless it's an alert.**
- Clio posted 27+ Infra Pulse messages to #clio_devops in a single day. Andrey called it out. Aaron told it to stop.
- Root cause: monitoring ran on every heartbeat (every few minutes), kept regenerating even after "removal."
- This rule is absolute. No exceptions. No resurrections under any name.

### H-DevOps Migration Context
- AWS ($22,600/mo) → OVH ($1,939/mo) — 91% cost reduction
- ~~7-node K3s cluster: 3 control-plane + 4 agent~~ _(corrected 2026-08-26 — see above)_
- ~~152 cores / 304 threads, 1,398GB RAM~~ _(retired April topology — do not quote)_
- ~~CI/CD: Cron-based on OVH node-1 (GitHub Actions blocked due to adk47 billing)~~ **CI/CD is GitHub Actions**, self-hosted ARC runners (builder node-19, runner hosts node-8); deploys are workflows in `Muso-AI/H-DevOps`. _(corrected 2026-08-26 — believing the old line means building a cron instead of a workflow, or calling a deploy impossible. A few node-1 crons remain for agent housekeeping only.)_
- api.muso.ai on OVH. 100% AWS independent as of April 2026.
- AWS fully decommissioned — no remaining services.

### Database Changes (RDS Scaling, Partitioning, Stored Functions)
- Stats DB `track_daily`: 3.3B rows. MUST use date partition filter for any query.
- `calc_analytics_stats_period`: stored function for pre-aggregated track stats (all/1y/ytd/3m/1m/1w/1d). Use `ce_streams` for cumulative. Much cheaper than scanning `track_daily`.
- 8 checkpoint files deprecated (Andrey dropping March 2026).
- After resuming realtime import, checkpoint tasks fail for ~1hr (catching up) — not new failures.
