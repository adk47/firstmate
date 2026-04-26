# KT Session: Athena Part 2 - Database Deep Dive

> ⚠️ **HISTORICAL DOC** — This was knowledge transfer about AWS Athena. AWS Athena was retired on **2026-04-25** in favor of Trino on OVH. The data model concepts described below are still valid (same SQL engine family, same tables), but execution commands and DB names have changed. See [trino-query-reference.md](../trino/trino-query-reference.md) for current syntax.


**Date:** 2026-01-20
**Presenter:** Oleg Mamchich
**Attendees:** Jay Ruffing, Serhii Ostapchuk, Ihor Shchuruk, Federico Cappuccilli
**Meeting ID:** `2026-01-20_athena-part-2`

## Summary

Detailed walkthrough of Aurora database architecture including Stats DB, Feed service, Industry Calculations, OLAP cubes, and Catalog database. Covers snapshot policies, table partitioning strategies, and the calc_analytics_history table for historical data.

---

## Aurora Databases Overview

### Stats DB (Aurora PostgreSQL)

**Fully snapshotted to data lake.**

| Table | Purpose |
|-------|---------|
| `public.track_daily` | Daily streaming stats by track |
| `analytics_link` | External platform ID → Muso track ID |
| `analytics_video` | Video-level stats for YouTube/TikTok/Instagram |
| `profile_track` | Profile → Track relationship |
| `album_track` | Album → Track relationship |

### Feed Service DB

**Only `follow` table snapshotted.** Contact Andre to add other tables.

| Table | Purpose | Snapshotted |
|-------|---------|-------------|
| `activity` | Raw activity data with JSON details | No |
| `feed` | Activity copies for each follower (no details, just sorting) | No |
| `reaction` | Likes/reactions (not currently used) | No |
| `follow` | Who follows whom | **Yes** |
| `feed_stats` | Helps deprioritize posts during sync | No |

**Architecture Note:** The `feed` table doesn't contain activity details - it's purely for sorting. Join `feed` → `activity` to get content.

### Industry Calculations DB

**Only `milestones` table snapshotted.** Other data available via Andre's calculated tables.

| Table | Purpose | Snapshotted |
|-------|---------|-------------|
| `profile_feed` | Feed pre-calculations | No |
| `fit_historical` | Historical fit scores | No |
| `feed_category` | Category assignments | No |
| `genre` | Genre calculations | No |
| `credit_score` | Credit scoring | No |
| `charts` | Chart positions | No |
| `milestones` | Profile/track milestones | **Yes** |

### OLAP Database

**NOT snapshotted** - computed daily by platform, stored in S3.

Stores analytics cubes with this structure:
- All cubes include `profile_id` as aggregation dimension
- Additional dimensions: `album`, `collaborator`, `track`, etc.
- Partitioned by **period**: `1d`, `1w`, `1m`, `3m`, `1y`, `all`, `ytd`

**Table Naming Convention:**
```
cube_analytics_<dimension>_<index>   (e.g., cube_analytics_album_565)
```

**View Pattern:**
- Andre creates new table daily with Spark
- Adds indexes after data insertion
- Switches view to point to new table
- Example: `cube_analytics_album_view` → `cube_analytics_album_565`

**Always query views, never tables directly.**

### Catalog Database

**Only `catalog_member` snapshotted** - rest computed by platform.

| Table | Purpose | Snapshotted |
|-------|---------|-------------|
| `catalog_profile_collaboration` | Pre-aggregated collaborator data | No |
| `catalog_profile_track` | **Most important table** - analytics with filters | No |
| `catalog_label_profile` | Label → Profile mapping | No |
| `catalog_publisher_profile` | Publisher → Profile mapping | No |
| `catalog_member` | Roster membership | **Yes** |

#### catalog_profile_track Details

This table was created because:
1. MongoDB IOPS limits prevent analytics-heavy queries
2. Aurora handles high-computation tasks better
3. Enables indexes on streams, genres, credits, etc.

**Partitioning Strategy:**
- 30 buckets via hash on `profile_id`
- Enables parallel Spark upserts (no lock contention)
- Query with bucket + profile_id scans 10M rows instead of 300M

---

## Platform Calculated Tables

### calcul_common (Computed Early)

Tables computed early in daily process for reuse:

| Table | Purpose |
|-------|---------|
| `calc_analytics_history` | Streaming history for key sources |
| `calc_profile_track_credits` | Profile ↔ Track relationships |
| `profile_collaborations_full` | All collaborations with partition |
| `collaboration_deletes` | Formula support table |

### calcul_normal (Computed in Parallel)

Cubes, feed data, milestones - computed in parallel branches after common.

---

## calc_analytics_history

**Critical table for historical analytics queries.**

- Stores history of streams for: **Spotify, Shazam, SoundCloud, YouTube**
- Partitioned by `capture_date`
- Source: JSON files from S3 capture bucket
- Retention: Original capture files cleaned after 30 days, partitions retained forever

```sql
SELECT source, COUNT(*)
FROM calcul_common.calc_analytics_history
WHERE capture_date = '2026-01-18'
GROUP BY source;

-- Results (example):
-- Spotify: 4M records
-- SoundCloud: 260K
-- YouTube: 500K
-- Shazam: 100K
```

---

## Legacy Naming: master_track_id

Anywhere you see `master_track_id` or `master_id`, it means `track_id`.

**History:** Original design anticipated merging tracks into "master tracks" - never implemented. Legacy naming persists in older tables and code.

---

## S3 Lifecycle Policies

| Path | Retention | Notes |
|------|-----------|-------|
| Capture JSON files | 30 days | Auto-cleaned via Terraform lifecycle |
| calc_analytics_history partitions | Forever | Retained for historical queries |

---

## Key Insights

1. **OLAP views abstract daily table switching** - always use views, not numbered tables
2. **catalog_profile_track is "most important table in Muso"** - enables analytics at scale
3. **30-bucket partitioning** on profile_id enables parallel writes and faster queries
4. **calc_analytics_history** stores forever what capture JSON retains for 30 days
5. **master_track_id = track_id** - legacy naming from abandoned design
6. **Feed table has no details** - join to activity for content

---

## Adding Snapshots

To add missing tables to snapshots, contact **Andre**. He manages:
- Snapshot scheduling
- Table selection
- S3 export paths

---

## Related Documentation

- Athena schemas: `skills/muso-query-writer/athena-schemas.md`
- Data platform overview: `skills/muso-clio/references/data-platform/overview.md`
- Data expert reference: `skills/muso-data-expert/reference.md`
