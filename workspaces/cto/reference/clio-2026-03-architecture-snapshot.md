# CTO — Clio-era architecture snapshot (March 2026)

> ⚠️ **HISTORICAL — a March-2026, AWS-era snapshot written in the present tense.
> Do not act on it.** Moved here from `MEMORY.md` on 2026-08-26, unchanged apart from
> the dated corrections already inline. It left `MEMORY.md` because that file is
> injected at agent bootstrap under a combined size cap, and a retired architecture
> is the last thing that should be competing for that budget with live authority
> rules. Current state: `AGENT_CURRENT_TRUTH.md` in shared-reference.

> ⚠️ **HISTORICAL — a MARCH-2026, AWS-era snapshot written in the present tense. Do not act
> on it.** Translation: Aurora/RDS → **self-hosted PG17** (primary **node-17**, replica
> node-19, **node-18 decommissioned**) · Athena → **Trino** (no scan limit, so the
> workarounds below solve a problem that no longer exists, and several `matvw_*` tables they
> teach you to query were recorded DEAD on 2026-08-11) · SQS → **Kafka/Redpanda** · MWAA →
> **self-hosted Airflow 2.10.3** · EKS → **OVH K3s** · Atlas → **self-hosted rs0** (PRIMARY
> node-16 at IP **10.0.0.14**). Current state: `AGENT_CURRENT_TRUTH.md`. Verified stale
> 2026-08-26.
>
> Also: **V3 is frozen, V4 is the LIVE spine** — any note here or in `memory/` saying "all
> V4 DAGs were paused" is badly stale. And a dated action item in `memory/` is a session
> plan, not standing authorisation: re-check live state and file the work as a bridge
> request instead of executing a months-old instruction against production.

### ~~Aurora PostgreSQL Usage Map~~ — PG17, self-hosted _(corrected 2026-08-26)_

| Database | Type | Consumers | R/W | Notes |
|----------|------|-----------|-----|-------|
| Industry DB | PostgreSQL RDS | Industry API, Industry Processing, Capture Services | R/W | Catalog entities, raw entities, credits, relationships, dict tables |
| Core Backend DB | PostgreSQL RDS | Core Backend API, Growth team | R/W | User accounts, auth, payments, subscriptions, teams, rosters |
| Stats DB (`platform_stats`) | **self-hosted PG17** | Platform pipelines (Airflow), Industry API, **Trino** | R/W | `track_daily` (3.3B rows), `analytics_link`, `analytics_video`, `profile_track`, `album_track` |
| Feed Service DB | PostgreSQL RDS | Feed Service | R/W | `activity`, `feed`, `reaction`, `follow` tables. Only `follow` snapshotted to lake. |
| Industry Calculations DB | PostgreSQL RDS | Platform Pipelines | R/W | Computed metrics, milestones. Only `milestones` snapshotted. |
| Analytics DB (analytics-prod) | PostgreSQL RDS | Analytics Scheduler, Analytics Worker | R/W | Scheduler dispatch state, entity IDs + priority numbers |
| MongoDB Atlas | MongoDB 8.0 | Core Backend API, Industry Processing | R/W | `catalog_profile` (29.9M docs), 19 collections total. Prod cluster: product-api-prod (R60). Dev: product-api-dev (R40). ~$24K/mo total. |

### Analytics & Data Ops System (Full Technical Details)

#### Architecture
3-layer pipeline, each in a separate repo:
1. **platform-data-processing** (Airflow DAGs) — decides WHAT to scrape and at what PRIORITY. Pro/paid user logic lives here.
2. **analytics-scheduler** (K8s CronJob, midnight UTC) — dispatches entities from PostgreSQL DB to SQS queues by priority. Has NO concept of users.
3. **analytics-worker** (SQS consumer pods, KEDA-scaled up to 100/queue) — scrapes platforms. Blind to users and priorities.

#### Priority System (set by Airflow DAGs)
- **P1** → every 2 days — Active Pro subscribers' profiles + top 10 tracks
- **P2** → every 7 days — Lapsed Pro + other Pro tracks + analytics_link base
- **P3** → every 45 days — Non-Pro high-rank + top 10 tracks by popularity
- **P4** → every 90 days — Non-Pro medium rank
- **P5** → every 180 days — Non-Pro low rank (default for unranked)
- **P6** → every 365 days — Rarely touched
- **+1 penalty** for profiles with >10,000 credits

#### Pro User Detection
- Joins to `public_roster_seats` where `status = 'active'` (via Athena cross-DB query)
- Source: `capture_daily_sla.py` (catalog), `dag_capture_new_sources.py` (analytics)

#### Three Key DAGs (dataset-triggered, daily ~07:30-08:45 UTC)
1. `Run_Merge_Capture_Daily_SLA` (~38 min) — Re-evaluates ALL catalog entity priorities
2. `Run_Merge_Catalog_Analytics_Maintenace_Capture_New_Sources` (~3 min) — Seeds Pro tracks into analytics capture
3. `Run_Merge_Catalog_Analytics_Maintenace_Capture_Missing_Sources` (~10 min) — Backfills missing analytics links

#### Scheduler Daily Dispatch Budgets
- Spotify stats: 600K/day (P1: 50K, P2: 500K, P3: 100K)
- YouTube tracks: 600K/day | YouTube social: 200K/day
- Shazam: 600K/day | SoundCloud: 500K/day | TikTok: 250K/day

#### Timing Quirk
Scheduler CronJob runs midnight UTC, but Airflow DAGs finish ~08:30 UTC. Scheduler always dispatches on yesterday's priority assignments (~8h lag for new Pro users).

#### Performance Metrics (Feb 2026 Overhaul)
- 84 commits in 3 months (Serhii 38, Aaron 34, Oleg 11, Jay 1)
- Changes: self-healing proxy architecture, circuit breakers, death spiral fix, rotating residential migration, multi-provider (Webshare + Thordata), per-platform country targeting, KEDA max 100 pods/queue, SQS batch receive
- ~~SQS volumes: ~3.5M msgs/day across all queues~~ _(corrected 2026-08-26: Kafka/Redpanda topics, not SQS; April-2026 figure)_
- S3 data lake: 27TB, bucket `platform-capture-data-lake-prod`

#### Database Changes
- Stats DB (`platform-stats-prod`): Aurora PostgreSQL, `track_daily` has 3.3B rows — MUST use date partition filter
- RDS scaling: analytics-dev/prod, core-backend-dev/prod (postgres), platform-stats-dev/prod-1 (aurora-postgresql)
- Stored functions: `calc_analytics_stats_period` (pre-aggregated track stats by period) — much cheaper than scanning `track_daily`

#### ADRs Referenced
- ADR-002: AMP naming conventions (in progress)
- Profile_sub_type backfill (backlog)
- Company-Person associations (in progress)
- Entity Pages (backlog)

#### Production Targets
- Priority 1 entities refreshed every 2 days
- Full catalog (~29M profiles) ranked and prioritized
- Zero-downtime proxy rotation with multi-provider fallback

### ~~Athena Patterns~~ — HISTORICAL and actively misleading _(corrected 2026-08-26: Athena is retired; query via Trino. The 30GB-scan workarounds below solve a constraint Trino does not have, and some tables they name were dead as of 2026-08-11 — confirm a table is live before trusting a result.)_
- `calc_analytics_stats_period` (period='all', `ce_streams`) = cheap cumulative streams. Avoid scanning `matvw_stats_track_daily` (3.3B rows).
- `matvw_stats_track_daily` MUST have date partition filter or blows scan limit.
- `child_roles` on `matvw_catalog_profile` = mostly empty. Use `common_credits` instead.
- `matvw_catalog_track.profiles` has no `name` — JOIN to `matvw_catalog_profile`.
- Catalog credits struct: `parent` and `child` fields (not `category`/`credit`).
- For discovery queries: small overlap (3-20 tracks) with large external catalog beats NOT IN (which filters everyone).
- Bucket join pattern for 30GB scan limit: CTAS each side into `tmp_clio.*` bucketed by join key (PARQUET, 16 buckets) → join materialized → DROP temps.
- `profile_type` = 'artist' not 'person'. `roles` array often empty. Use `common_credits` for role identification.

### Credit Request Approval Audit Trail (Technical Flow)
- Flow: User submits credit claim → core-backend API creates claim record → Admin reviews in Retool → approve/reject.
- Data source: Athena `platform-core-backend-export-prod.public_claiming` + `public_teams`.
- 231 rejections in 7 days (as of Feb 28), 72% approval rate.
- 160/231 rejections have no reason logged — potential ops process gap.
- Mobile `FollowersProviderBloc` requires `workspaceId` + `rosterSeatId` — following gated on claimed profile.

### Don't Bluff Lesson
- If you haven't checked something, say so. Be precise about data sources.
- Never claim data freshness or pipeline status without checking actual sources (S3 checkpoints, DAG grid, pod logs).
- Never claim capability you don't have. If you can't verify something directly, say so immediately.
- Don't use confident language to cover a gap. (Learned from Andrey, repeated multiple times.)

### Andrey's Rules (Historical Patterns)
- *Bucket join pattern* for Athena 30GB scan limit — CTAS + bucket + join + drop.
- *Investigate root cause before adding dedup.* CardinalityViolation was an anomaly in years-clean calc — understand WHY before slapping `.distinct()`.
- *Process:* No direct-to-main commits. Always CU ticket + branch + PR, even hotfixes.
- *Never claim capability you don't have.* If you can't verify something directly, say so immediately.

### Infrastructure Notes
- **MongoDB Atlas**: Prod cluster product-api-prod (R60), Dev product-api-dev (R40), ~$24K/mo total. MongoDB 8.0.19, ReplicaSet. Org: 6358f82168ec0b732bec2543, Project: 6358f894f47fc018ab2ad7bd.
- **RDS Instances**: analytics-dev/prod, core-backend-dev/prod (postgres), platform-stats-dev/prod-1 (aurora-postgresql).
- **EKS Clusters**: core-dev/prod, platform-data-processing-pipelines-dev/prod.
- **platform-data-processing-pipelines** NOT in Terraform — managed via shell scripts in `deploy/eks/`. Core-prod IS fully Terraform-managed.
- **Proxy infrastructure**: Webshare (100 datacenter @ $26.62/mo + 250GB residential @ $742.19/mo) + Thordata rotating proxies.
- **S3**: 20+ buckets, 27TB data lake at `platform-capture-data-lake-prod`.
- ~~**MWAA**: Airflow managed~~ **Airflow 2.10.3 is SELF-HOSTED** on OVH K3s, ns `data-processing` _(corrected 2026-08-26; `platform-data-processing-pipelines-*` were EKS CLUSTER names, never Airflow environments)_.
- **ElastiCache**: core-backend-dev/prod (redis).

### Retool Replacement Context
- Retool is the current admin tool for credit request review, profile management, and operations.
- 94 admin endpoints documented under `/w/admin/*`.
- Industry API at `/api/v1/...`, Core Backend at `/api/v4/...`, Customer API at `/api/c/v4/...`.
- Track ID is always at `item.id` (industry-data) or `item.track.id` (core-backend v4). NOT `trackId` or `track_id`.
- Retool replacement should cover: credit claims, profile merging, audit operations, dispute management.
