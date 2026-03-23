# MEMORY.md — DEVOPS Agent

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned
_(none yet — agent will populate during operation)_

## Key Context
_(initialized 2026-03-22)_

## Migrated from Clio (2026-03-23)

### Aurora PostgreSQL Usage Map

| Database | Type | Consumers | R/W | Notes |
|----------|------|-----------|-----|-------|
| Industry DB | PostgreSQL RDS | Industry API, Industry Processing, Capture Services | R/W | Catalog entities, raw entities, credits, relationships |
| Core Backend DB | PostgreSQL RDS | Core Backend API, Growth team | R/W | User accounts, auth, payments, subscriptions, teams |
| Stats DB (platform-stats-prod) | Aurora PostgreSQL | Airflow Pipelines, Industry API, Athena | R/W | `track_daily` (3.3B rows), `analytics_link`, `analytics_video` |
| Feed Service DB | PostgreSQL RDS | Feed Service | R/W | `activity`, `feed`, `reaction`, `follow`. Only `follow` snapshotted. |
| Industry Calculations DB | PostgreSQL RDS | Platform Pipelines | R/W | Computed metrics, milestones. Only `milestones` snapshotted. |
| Analytics DB (analytics-prod) | PostgreSQL RDS | Analytics Scheduler, Analytics Worker | R/W | Scheduler dispatch state |
| MongoDB Atlas | MongoDB 8.0 | Core Backend API, Industry Processing | R/W | 19 collections, `catalog_profile` 29.9M docs. ~$24K/mo. |

### Infrastructure Notes

#### AWS Infrastructure (068358774785)
- **EKS**: core-dev/prod, platform-data-processing-pipelines-dev/prod
- **RDS**: analytics-dev/prod, core-backend-dev/prod (postgres), platform-stats-dev/prod-1 (aurora-postgresql)
- **ElastiCache**: core-backend-dev/prod (redis)
- **MWAA**: platform-data-processing-pipelines-dev/prod (Airflow managed)
- **S3**: 20+ buckets, 27TB data lake at `platform-capture-data-lake-prod`
- **Steady-state cost**: ~$530/day, ~$15,700/mo. Top: RDS (27%), EC2 (22%), S3 (10%), MWAA (8%)

#### Key Architecture Notes
- `platform-data-processing-pipelines` NOT in Terraform — managed via shell scripts in `deploy/eks/`. Core-prod IS fully Terraform-managed.
- Proxy infra: Webshare (100 datacenter @ $26.62/mo + 250GB residential @ $742.19/mo) + Thordata rotating
- KEDA autoscaling: up to 100 pods/queue for analytics workers
- SQS volumes: ~3.5M msgs/day across all queues

#### MongoDB Atlas
- Prod: product-api-prod (R60), Dev: product-api-dev (R40). MongoDB 8.0.19, ReplicaSet.
- Org: 6358f82168ec0b732bec2543, Project: 6358f894f47fc018ab2ad7bd
- API: Digest auth, base: `https://cloud.mongodb.com/api/atlas/v2`

#### EKS/KEDA Incident (Feb 24)
- Cluster-autoscaler cordoned both `eks-core-prod-system` nodes (2x c3.large spot, 100% spot)
- KEDA, metrics-server, LB controller all became unschedulable
- SQS queues backed up: 820k YouTube, 230k Shazam, 150k Jaxsta
- Root cause: CA marked nodes as `toBeDeleted/unschedulable` but ASG min=2 prevented termination → stuck cordoned
- Fix PRs: terraform-module-keda#3 (HA), devops#411 (scale_down_disabled), platform-data-processing#1552 (EKS auth mode)

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
- 7-node K3s cluster: 3 control-plane + 4 agent (app-serving, data-read, data-write, mongodb)
- 152 cores / 304 threads, 1,398GB RAM, ~15TB raw NVMe
- CI/CD: Cron-based on OVH node-1 (GitHub Actions blocked due to adk47 billing)
- api.muso.ai now on OVH. ~90% AWS independent.
- Remaining AWS: S3/CDN assets (CloudFront), Auth0 callbacks

### Database Changes (RDS Scaling, Partitioning, Stored Functions)
- Stats DB `track_daily`: 3.3B rows. MUST use date partition filter for any query.
- `calc_analytics_stats_period`: stored function for pre-aggregated track stats (all/1y/ytd/3m/1m/1w/1d). Use `ce_streams` for cumulative. Much cheaper than scanning `track_daily`.
- 8 checkpoint files deprecated (Andrey dropping March 2026).
- After resuming realtime import, checkpoint tasks fail for ~1hr (catching up) — not new failures.
