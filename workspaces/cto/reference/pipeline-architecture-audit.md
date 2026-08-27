> ⚠️ **HISTORICAL — describes the AWS-era pipeline as of 2026-03-09. Do not act on this document.**
> The architecture audited here is AWS-era and fully decommissioned (April 2026): read every
> Aurora/RDS as self-hosted **PG17** (primary node-17, replica node-19; node-18 is gone), every
> MWAA as self-hosted **Airflow 2.10.3** in namespace `data-processing`, every Athena as
> **Trino**, every SQS as **Redpanda/Kafka**, and every EKS as **OVH K3s** — so Part 5's cost
> analysis (~$21,500/mo) prices a bill that no longer exists, and the recommendations in
> Parts 6–8 push analytics *into* the relational store, the opposite of the current north star
> (ClickHouse takes analytics OFF PG-17). Part 8 additionally assigns work to people who have
> since left Muso and proposes V3 DAG-schedule and OLAP-cube changes that are forbidden without
> an explicit brief — doubly so while cube promotion is frozen. Current state:
> `/opt/hydra/shared-reference/AGENT_CURRENT_TRUTH.md`. Part 3 (the V3 calculation dependency
> tree) is the only section still worth reading, and only as archaeology.
> Retained for history only. Verified stale 2026-08-26.

# Muso.AI Data Pipeline Architecture Audit

**Date:** 2026-03-09
**Requested by:** Aaron Kaufman
**Purpose:** Figure out how to keep every track fresh, get new catalog data, process everything efficiently, and make it available throughout the app — without burning AWS resources.

---

## TL;DR — The Whole Picture

Aaron, here's what I found after reading through all six repos end to end. Your system is actually well-designed — the team built a solid architecture. The problem isn't the architecture itself, it's that **you have a batch pipeline trying to serve a real-time use case**, and some things got turned off that created gaps. Here's the full story.

---

## Part 1: How Data Flows Through Your System (End to End)

### The Five-Layer Pipeline

```
Layer 1: SCRAPING (analytics-worker)
   Scrapes Spotify, YouTube, TikTok, Shazam, SoundCloud, etc.
   Sends results via SQS to industry-data-processing
   ↓
Layer 2: REAL-TIME PROCESSING (industry-data-processing)
   Three SQS workers: raw, catalog, analytics
   Writes to MongoDB (catalog) + Aurora PostgreSQL (stats)
   This is FAST — seconds after scraping
   ↓
Layer 3: BATCH CALCULATIONS (platform-data-processing / Airflow)
   Daily orchestrator runs 60+ Spark calculations
   Reads from MongoDB + Aurora, computes credit scores, OLAP cubes, 
   milestones, profile aggregations, track popularity, etc.
   Writes results to S3 as Parquet → Glue crawlers → Athena tables
   Also persists to Aurora OLAP tables + MongoDB
   ↓
Layer 4: SERVING (industry-data-processing API)
   FastAPI serving catalog from MongoDB + stats from Aurora OLAP tables
   The stats API tries OLAP cubes first, falls back to Aurora direct
   ↓
Layer 5: APP (core-backend → frontend/mobile)
   core-backend calls industry API for all catalog + stats data
   Also reads directly from its own PostgreSQL (users, workspaces, subscriptions)
   Redis for caching
```

### What This Means

**Your scraping is fast.** analytics-worker can process 50M+ messages/day across all platforms. You scaled this massively — 20 threads per pod, KEDA autoscaling up to 100 pods per queue, circuit breakers, multi-provider proxy system. This is powerful.

**Your real-time path is fast.** When analytics-worker scrapes a track's streams from Spotify, within seconds that data lands in Aurora's `analytics_link` table via industry-data-processing. The raw stat is "live."

**Your batch calculations are slow.** The daily orchestrator (`Run_Industry_Orchestrator_V2`) runs at 00:05 UTC and takes hours to complete all 60+ Spark calculations. This is where credit scores, OLAP cubes, profile aggregations, milestones, and chart entities get computed. Until this finishes, the app shows yesterday's calculated values.

**The bottleneck is between Layer 2 and Layer 4.** The scraped data is fresh in Aurora, but the app reads from OLAP cube views that are only rebuilt once per day.

---

## Part 2: What the App Actually Reads

This is critical — I traced every API call from core-backend through industry-data-processing to the actual database tables:

### Stats (Streaming Numbers)
- **Entry point:** `core-backend/src/components/catalog-api/getStats.js` → calls `{INDUSTRY_API_URL}/v1/stats/{group}`
- **Served by:** `industry-data-processing/api/v1/routers/stats/router.py`
- **Data source:** 
  - Primary: **OLAP cubes** in Aurora (`cube_analytics_profile_view`, `cube_analytics_track_view`, etc.) — via `AnalyticsCubeQueryProcessor`
  - Fallback: **Aurora stats tables** directly (`profile_track`, `analytics_link`) — via `AnalyticsAuroraQueryProcessor`
- **Freshness:** OLAP cubes rebuilt daily by Spark. Aurora stats tables updated in real-time by SQS workers.
- **Config flag:** `USE_ANALAYTICS_CUBES=True` (production default) — means the app uses the daily-rebuilt cubes, NOT the real-time Aurora data

### Profile Stats (Industry Stats Page)
- **Entry point:** `core-backend/src/components/catalog-api/getProfileStats.js` → calls `{INDUSTRY_API_URL}/v1/profile/{id}/stats`
- **Served by:** `industry-data-processing/api/v1/routers/profile/get_profile_stats.py`
- **Data source:** `cube_analytics_industry_stat_profile_view` (Aurora OLAP table)
- **Freshness:** Rebuilt daily — this is a 7th-level calculation dependency

### Catalog (Credits, Profiles, Tracks)
- **Entry point:** `core-backend/src/components/catalog-api/getProfile.js`, `getTrack.js`, etc.
- **Served by:** industry-data-processing FastAPI → MongoDB queries
- **Data source:** MongoDB Atlas (`catalog_profile`, `catalog_track`, `catalog_release`)
- **Freshness:** Updated in real-time by industry-data-processing catalog worker (SQS)
- **But:** Calculations like `profile_aggregations` (credit counts, collaborations, popularity) are batch-only

### What This Means for "Freshness"

| What the User Sees | Source | Freshness |
|---|---|---|
| Track stream counts | OLAP cubes (daily rebuild) | **24h stale** |
| Profile total streams | OLAP cubes | **24h stale** |
| Credit score | Batch calculation | **24h stale** |
| Credit list (who worked on what) | MongoDB catalog | **Real-time** |
| Profile name/image/bio | MongoDB catalog | **Real-time** |
| Milestones | Batch calculation (6th level) | **24h stale** |
| Charts (Top 200) | Batch calculation | **Weekly** (Tuesdays) |
| Track links (Spotify/YouTube URLs) | Aurora `analytics_link` | **Real-time** |

**The irony:** The raw stream numbers ARE fresh in Aurora's `analytics_link` and `track_daily` tables. But the app reads from OLAP cubes that are only rebuilt once per day.

---

## Part 3: The Daily Calculation Pipeline (Where the Complexity Lives)

The `Run_Industry_Orchestrator_V2` DAG is the master pipeline. Here's what it does every night:

### Step 1: Input Collection (Parallel)
- `Run_Capture_Aggregate` — reads analytics-worker S3 capture/ files, writes Parquet (THIS IS WHAT YOU'RE ELIMINATING via ADR-012)
- `Run_RDSExport_Snapshot` (x3) — exports core_backend, analytics, and stats PostgreSQL databases to S3 for Athena access

### Step 2: Sunday-Only Full MongoDB Materialize
- `Run_Full_Materialize_Industry_DB` — full MongoDB Atlas snapshot to S3 → Glue → Athena (Sundays only, `import_dow=6`)

### Step 3: Sequential Materializations
- `Run_Full_Materialize_Muso_DB` — materializes core-backend data (teams, users, roster seats)
- `Run_Full_Materialize_Stats_DB` — materializes Aurora stats data
- `Run_Full_Materialize_Feed_DB` — materializes feed data
- `Run_Full_Materialize_Catalog_DB` — materializes catalog data
- `Run_Full_Materialize_Analytics_DB` — materializes analytics data

### Step 4: Industry Serving Layer
- `Run_Industry_Serving_Layer` — runs Spark jobs for each input contract, writes Parquet to S3, runs Glue crawler to make it queryable via Athena

### Step 5: Calculations (Dataset-Triggered)
- `Run_Calculate_Industry_DB_Common` → triggers:
  - `Run_Calculate_Industry_DB_Default`
  - `Run_Calculate_Industry_DB_LMC`  
  - `Run_Calculate_Industry_DB_OLAP`
- → then `Run_Crawl_Calculate_Industry_DB` (runs after all three complete)

### The Calculation Dependency Tree (60+ calculations)

```
Level 0 (Common — run first):
  ProfileTrackCredits, ProfileCollaborations, AnalyticsHistory, TrackPopularity

Level 1 (No dependencies):
  CreditScore, ProfileCompilationMark, AudiomackStreamStats, LabelProfileRelation,
  PublisherProfileRelation, ProfileFeed, CommonCredits, ProfileCreditsCount (x3),
  ProfileRecentCreditsCount, ProfileChildRoles, ProfileCollaborationsCount,
  ProfileTopCollaborators, ProfilePrimaryGenre, ProfileGenres, ProfileYearsActive,
  ProfileAuditStats, ProfileTrackPopularities

Level 2:
  MusoChartEntities, ProfilePopularity, CreditScoreChartsEntries,
  ProfileAggregations, ProfileTrack, ProfileTrackDeletes, AnalyticsLinksMerge,
  LinkProfile, MergeProfile, LinkTrack, MergeTrack

Level 3:
  CreditScoreCharts, ProfileAggregationsDeletes,
  LinkProfilePositive, MergeProfilePositive, LinkTrackPositive, MergeTrackPositive,
  AnalyticsStatsDaily

Level 4:
  CreateFromRawProfile, UnionLinkMergeCreate, AnalyticsStatsPeriod

Level 5:
  UnionLinkMergeCreatePositive,
  13 OLAP cubes (AnalyticsCubeProfile, AnalyticsCubeTrack, etc.)

Level 6: MilestoneGeneration
Level 7: MilestoneGenerationProUsers, AnalyticsIndustryStatCubeProfile (+Roster)
Level 8: MilestoneGenerationDeletes, MilestoneGenerationNotify, ProfileMilestoneFeed
```

### What Persists Where

After calculations, results are persisted to:
- **Aurora OLAP tables** (via `Run_Persist_OLAP`) — the OLAP cube views the app reads from
- **MongoDB** (via `Run_Persist_MongoDB`) — profile aggregations, chart entities, milestones
- **S3 Parquet / Athena** (via serving layer Glue crawlers) — for Athena queries
- **SQS triggers** (via `Run_Persist_SQS`) — to notify downstream systems

---

## Part 4: What's Broken / Turned Off

### Things Aaron Turned Off

1. **S3 capture/ writes** — You started canary-rolling `SKIP_S3_CAPTURE=true` (currently enabled on shazam-medium only). This is GOOD — it saves $7,500/mo per ADR-012. But the `analytics_links_merge` calculation still depends on `AnalyticsHistory` which reads from capture/ data. Until the redirect to Aurora is done (Phase 1 of ADR-012), link merge may be getting stale or empty input for shazam.

2. **S3 lifecycle reduced from 30→14 days** — Less historical data available for any process still reading capture/ files.

3. **Unknown other S3 things** — Aaron mentioned turning off "some S3 things" to save money. Need to check if any other S3 event notifications, lifecycle policies, or bucket configurations were changed.

### Things That Were Already Disabled

4. **`Run_Realtime_Calculations` DAG** — Schedule is `None` in both prod and dev. This DAG was designed to run calculations between Atlas snapshots but is currently disabled. This means ALL calculations are batch-only — no intra-day refreshes.

5. **Full MongoDB materialize only runs on Sundays** — The orchestrator's `gate_dow` check (day-of-week = 6 = Sunday) means the full Atlas → S3 → Athena snapshot only happens weekly. The hourly `Run_Import_Industry_Realtime` covers incremental changes for a subset of collections, but not all.

### Not Broken but Suboptimal

6. **RDS Snapshot Export costs $1,300/mo** — Three RDS exports run daily at $43/day just to make PostgreSQL data available in Athena. These run as part of the orchestrator even on days when the data isn't heavily used.

7. **OLAP cubes are rebuilt fully every day** — Even if only 1% of profiles had stats changes, all 13 cube tables get fully recomputed.

---

## Part 5: The Cost Picture (March 1-8, 2026)

### Monthly Projected Costs (based on 8 days of data)

| Service | 8-Day Cost | Monthly Projected | What It's Doing |
|---|---|---|---|
| RDS (Aurora + PostgreSQL) | $1,477 | **$5,540** | Aurora OLAP tables, core_backend DB, analytics scheduler DB |
| S3 | $1,082 | **$4,060** | Capture writes ($2,340/mo PUT), storage ($1,000/mo), data transfer |
| EC2 Compute | $794 | **$2,980** | EKS worker nodes (mostly Spot), analytics-worker pods |
| EC2 Other | $744 | **$2,790** | NAT Gateway, EBS volumes, data transfer |
| MWAA (Airflow) | $392 | **$1,470** | Managed Airflow environment |
| CloudWatch | $370 | **$1,390** | Logs, metrics, alarms |
| SQS | $191 | **$720** | All message queues |
| Savings Plans | $180 | **$680** | Committed spend discount |
| VPC | $131 | **$490** | NAT Gateway, VPN |
| Athena | $123 | **$460** | Query scanning |
| WAF | $84 | **$315** | Web application firewall |
| ELB | $82 | **$305** | Load balancers |
| EKS | $76 | **$285** | Kubernetes control plane |
| **Total** | | **~$21,500/mo** | |

### Cost Breakdown Insights

- **S3 PUT requests ($2,340/mo projected)** — This is the capture/ writes. ADR-012 will eliminate this, but it's lower than the $7,500 projected in the ADR because SKIP_S3_CAPTURE is already partially rolled out.
- **RDS Snapshot Export ($1,300/mo)** — Three daily exports to make PostgreSQL data available in S3/Athena. This is expensive for what it does.
- **Aurora IO-Optimized ($783/mo projected)** — You're on IO-Optimized tier which means no per-IO charges but higher base cost.
- **Spot instances ($794 total compute, ~60% Spot)** — Good cost optimization already in place.

---

## Part 6: The Optimal Architecture (Recommendations)

### Principle: "Real-time where it matters, batch where it doesn't"

Not everything needs to be fresh every second. Credit lists don't change hourly. But stream counts do. Here's what I'd prioritize:

### Tier 1: IMMEDIATE — Do These Now

#### 1A. Complete ADR-012 (Eliminate S3 Capture Writes)
- **Status:** Canary on shazam-medium. Gzip compression already implemented in results_sender.py.
- **Next steps:** 
  - Redirect `analytics_links_merge` to read from `analytics_stats_daily` instead of `AnalyticsHistory` (2 files to change in platform-data-processing)
  - Roll out `SKIP_S3_CAPTURE=true` to ALL workers
  - Remove `dag_capture_aggregate` and `dag_full_materialize_capture` from orchestrator
- **Savings:** ~$2,300/mo immediately (capture PUT costs), growing to $8K+/mo at full scale
- **Risk:** Low — only one calculation depends on capture data, and the redirect is straightforward

#### 1B. Enable Intra-Day OLAP Cube Refresh
- **Problem:** Stream counts shown in the app are 24h stale because OLAP cubes are rebuilt once daily.
- **Solution:** Re-enable `Run_Realtime_Calculations` with a 4-6 hour schedule. This was designed exactly for this — it runs a subset of calculations (CreditScoreChartsEntries, CreditScoreCharts) between full daily runs.
- **Enhancement:** Extend `realtime_calculations()` in CalculationRegistry to include `AnalyticsStatsDaily`, `AnalyticsStatsPeriod`, and the OLAP cubes. These are the calculations that make stream counts visible in the app.
- **Cost:** Moderate Spark compute cost, but far cheaper than rebuilding everything.

#### 1C. Bypass OLAP Cubes for Single-Entity Queries
- **Problem:** When a user views ONE profile or ONE track, the app reads from pre-computed OLAP cubes. But the Aurora `analytics_link` table already has the real-time data.
- **Solution:** For single-entity lookups, query Aurora stats tables directly instead of OLAP cubes. The `AnalyticsAuroraQueryProcessor` already exists as a fallback — make it the primary for single-entity requests.
- **Change:** In `industry-data-processing/api/v1/routers/stats/router.py`, add logic: if `len(ids) <= 5`, use `AnalyticsAuroraQueryProcessor` directly. Keep OLAP cubes for bulk/aggregate queries (charts, lists, leaderboards).
- **Cost:** Slightly more Aurora read load, but for single-entity queries it's negligible.

### Tier 2: SHORT TERM — This Week

#### 2A. Reduce RDS Snapshot Export Frequency
- **Problem:** Three RDS snapshot exports run daily ($1,300/mo) to make PostgreSQL data available in Athena.
- **Solution:** Run core_backend export weekly (data doesn't change that fast — users, teams, subscriptions). Keep analytics and stats exports daily since they feed calculations.
- **Savings:** ~$400/mo

#### 2B. Incremental OLAP Cube Updates
- **Problem:** All 13 OLAP cubes are fully rebuilt daily even if only a small percentage of data changed.
- **Solution:** Change the OLAP cube persist to use UPSERT instead of full table replacement for the most expensive cubes (profile, track). Only write rows where stats actually changed since last run.
- **How:** The persist driver (`persist/drivers/olap_ddl/`) already supports different write modes. Change from REPLACE to UPSERT for cubes where the primary key is stable.
- **Savings:** Less Spark compute time, faster DAG completion, lower Aurora IO.

#### 2C. Move Hourly Realtime Import to Use Change Streams Instead of Full Collection Scans
- **Problem:** `Run_Import_Industry_Realtime` runs hourly, doing Spark jobs that scan MongoDB collections to find changes.
- **Solution:** Use MongoDB Change Streams (already supported by Atlas) to capture deltas. Only import what actually changed since last import.
- **Savings:** Less Spark compute, faster imports, less MongoDB read load.

### Tier 3: MEDIUM TERM — This Month

#### 3A. Eliminate the Double-Path Architecture
- **Current:** Scraped data flows through two paths — SQS→Aurora (real-time) AND S3→Spark→Athena (batch).
- **Target:** Single path through SQS→Aurora, with Spark calculations reading directly from Aurora (not from materialized S3 snapshots).
- **What this eliminates:** 
  - Most materialize DAGs (no need to snapshot data to S3 if Spark can read Aurora directly)
  - Glue crawlers for materialized data
  - S3 storage for intermediate Parquet files
- **Prerequisite:** ADR-012 complete, and verify all Spark calculations can read from Aurora/MongoDB directly instead of materialized Athena tables.

#### 3B. Priority-Aware Calculation Scheduling
- **Problem:** The daily orchestrator runs ALL 60+ calculations every night regardless of what data changed.
- **Solution:** Track which entities had stats updates since last calculation run. Only recalculate affected profiles/tracks.
- **Implementation:** Add a `last_calculated_at` column to Aurora stats tables. Spark calculations filter to entities where `updated_at > last_calculated_at`.
- **Savings:** Could reduce daily Spark compute by 80%+ on quiet days.

#### 3C. Redis Caching for Stats API
- **Problem:** Every profile/track view hits Aurora OLAP tables or does a stats query.
- **Solution:** Cache calculated stats in Redis with TTL matching the refresh interval (4-6 hours). core-backend already has Redis — just needs a caching layer in front of industry API calls.
- **Savings:** Dramatic reduction in Aurora read load.

### Tier 4: LONG TERM — Next Quarter

#### 4A. Direct-to-Aurora from analytics-worker (ADR-008 Phase B)
- **What:** analytics-worker writes stats directly to Aurora, bypassing the SQS→industry-data-processing hop entirely.
- **Why not now:** Needs RDS Proxy for connection pooling (675 pods × 20 threads = 13,500 potential connections). Higher blast radius.
- **Savings:** Eliminates SQS costs (~$720/mo) + industry-data-processing analytics worker compute.

#### 4B. Replace Spark with Lightweight Scheduled Queries
- **What:** Many of the 60+ Spark calculations are essentially SQL aggregations. Could be replaced with scheduled Aurora SQL procedures or lightweight Python scripts.
- **Why:** Spark on EKS is expensive (node scaling, MWAA overhead). For calculations that read and write within Aurora, a SQL procedure running every 4 hours would be instant and free.
- **Candidates:** CreditScore, TrackPopularity, ProfileCreditsCount, AnalyticsStatsDaily — all of these are SQL aggregations.

---

## Part 7: The Catalog Story (Separate from Stats)

### How New Catalog Data Gets In

1. **analytics-worker scrapes** Spotify/YouTube/etc. for artist info, album credits, track details
2. Results go to `industry-proc-catalog` SQS queue
3. industry-data-processing **catalog worker** processes: creates/updates `catalog_profile`, `catalog_track`, `catalog_release` in MongoDB
4. **MLC import** (daily at 06:00 UTC) brings in composition/work data from the Mechanical Licensing Collective
5. **Distributors import** (daily at 15:00 UTC) brings in label/distributor data
6. **DataHub enrichment** (daily at 07:00 UTC) enriches profiles from external sources

### Catalog Freshness

Catalog data (credits, profiles, tracks) is **already real-time** for anything that comes through the SQS pipeline. The bottleneck is:
- **Calculated aggregations** (credit counts, collaborations, popularity) — batch-only
- **Full MongoDB → Athena sync** — weekly (Sundays only)
- **MLC cross-references** — daily, can trigger capture spikes (MLC recordingidentifiers maps ISRCs to YouTube/Shazam/SoundCloud IDs)

### Discovery & Fan-Out (ADR-013)

You recently enabled `DISCOVERY_FANOUT_ENABLED` which means when analytics-worker processes an artist, it automatically discovers featured artists from their albums/tracks and schedules them for catalog capture. This is how the catalog grows organically.

---

## Part 8: Concrete Action Plan

### Week 1 (Immediate)

| # | Action | Who | Effort | Impact |
|---|---|---|---|---|
| 1 | Complete ADR-012 Phase 1: redirect analytics_links_merge to Aurora | Dev (Serhii/Andrey) | 2 days | Unblocks S3 elimination |
| 2 | Roll out SKIP_S3_CAPTURE=true to all workers | Aaron/DevOps | 1 hour | **-$2,300/mo** |
| 3 | Make AnalyticsAuroraQueryProcessor primary for single-entity queries | Dev | 1 day | **Real-time stats for users** |
| 4 | Re-enable Run_Realtime_Calculations every 4 hours | DevOps | 1 hour | Fresher OLAP cubes |

### Week 2

| # | Action | Who | Effort | Impact |
|---|---|---|---|---|
| 5 | Reduce core_backend RDS export to weekly | DevOps | 1 hour | **-$400/mo** |
| 6 | Clean up dead capture DAGs (Phase 4 of ADR-012) | Dev | Half day | Simpler pipeline |
| 7 | Add stats caching to industry API or core-backend | Dev | 2 days | Lower Aurora load |

### Month 1

| # | Action | Who | Effort | Impact |
|---|---|---|---|---|
| 8 | Incremental OLAP cube updates | Andrey/Serhii | 1 week | **-$500/mo compute** |
| 9 | Priority-aware calculation scheduling | Andrey | 1 week | **-$300/mo compute** |
| 10 | Evaluate replacing Spark calculations with Aurora SQL procedures | Andrey | 2 weeks | Potential to eliminate MWAA ($1,470/mo) |

### Expected Total Savings

| Timeframe | Monthly Savings | Cumulative |
|---|---|---|
| Week 1 | $2,300 (S3 PUTs) | $2,300 |
| Week 2 | $400 (RDS exports) | $2,700 |
| Month 1 | $800 (compute optimization) | $3,500 |
| Quarter 1 | $2,000+ (MWAA reduction) | $5,500+ |

**Plus:** Real-time stream counts for individual profiles/tracks, fresher OLAP cubes (4-6h instead of 24h), faster daily pipeline.

---

## Part 9: What You Need to Verify

Things I couldn't determine from code alone:

1. **What exactly did you turn off?** — You mentioned turning off "some S3 things." Can you check if any S3 event notifications or bucket policies were modified beyond the SKIP_S3_CAPTURE flag and lifecycle changes?

2. **Is the orchestrator DAG actually succeeding?** — ~~I don't have MWAA console access.~~ **Corrected 2026-08-26:** MWAA is retired; Airflow is self-hosted at `airflow.ak.muso.ai` (namespace `data-processing`) and is directly queryable, so this is no longer a blocked check. Check if `Run_Industry_Orchestrator_V2` has been completing successfully. If capture_aggregate is failing (because S3 data is missing for shazam), it could be blocking the entire downstream pipeline.

3. **Are OLAP cubes actually being rebuilt?** — Check the `Run_Persist_OLAP` DAG status. If this isn't running, the app would show stale data everywhere.

4. **MongoDB Atlas costs** — You mentioned ~$5K/mo for Atlas. With the hourly realtime imports doing Spark scans of MongoDB collections, that could be a significant read load. Worth checking Atlas metrics.

---

## Summary

**Your scraping capacity is ahead of your processing capacity.** You can pull 50M+ data points per day, but the batch pipeline only processes them once every 24 hours for the app to see. The fixes are:

1. **Short-circuit single-entity queries** to read real-time Aurora data instead of OLAP cubes
2. **Run calculations more frequently** (re-enable realtime calculations every 4h)
3. **Eliminate the S3 capture path** (finish ADR-012 — gzip is done, redirect links_merge, flip the flag)
4. **Over time**, replace batch Spark with incremental/SQL approaches and move toward a single data path

The system isn't broken — it's just throttled by batch scheduling. The data is there. It's fresh in Aurora. You just need to let the app read it directly for the most common use cases, and refresh the aggregate calculations more often.
