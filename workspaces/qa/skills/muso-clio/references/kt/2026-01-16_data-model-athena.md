# KT Session: Data Model & Athena Deep Dive

**Date:** 2026-01-16
**Presenter:** Oleg Mamchich
**Attendees:** Jay Ruffing, Serhii Ostapchuk (background)
**Meeting ID:** `2026-01-16_part-2`

## Summary

Deep dive into the data model architecture, Athena query engine, and data flow from capture to catalog to analytics. Covers MongoDB structure, PostgreSQL snapshots, and key architectural decisions.

---

## Data Sources Overview

### Where Data Comes From

| Source Type | Examples | Notes |
|------------|----------|-------|
| **MongoDB** | industry DB, BI DB | Core data model |
| **PostgreSQL Snapshots** | analytics, core_backend, platform_stats | RDS instances |
| **Platform Tables** | Temporary tables from pipelines | Stored in data lake |
| **AWS Tables** | WAF logs, load balancer logs | Internal analytics |
| **External Tools** | Stripe, Apple, Google, Amplitude | Payment + analytics |

**Note:** Klaviyo is NOT dumped to the data lake. Only Amplitude.

---

## Athena Query Engine

### Workgroups

| Workgroup | Purpose | State |
|-----------|---------|-------|
| `primary` | Main queries | ~256 queries, 4 years old, many outdated |
| `growth_dev` | Marketing/Eher work | New, clean |

### Presto Compatibility

Athena is a fork of **Presto** (open-source query engine). 99% of Presto functions work in Athena. Use [Presto documentation](https://prestodb.io/docs/current/) for SQL reference.

---

## MongoDB Architecture

### Two Databases Dumped

| Database | Purpose | Update Pattern |
|----------|---------|----------------|
| `platform_industry_BI_prod` | Pre-aggregated views | Weekly snapshot |
| `platform_industry_DB_industry_prod` | Full data model | Weekly snapshot + daily deltas |

**Why weekly + deltas?** MongoDB to AWS integration is non-scalable. A full daily snapshot takes **16 hours** - not enough time to process. Weekly snapshot + daily deltas is the workaround.

### Collection Prefixes

| Prefix | Meaning | Example |
|--------|---------|---------|
| `raw_` | Data exactly as received from source | `raw_recording`, `raw_profile` |
| `dict_` | Dictionaries/mappings | `dict_credit_mapping` |
| `catalog_` | Merged Muso entities | `catalog_track`, `catalog_profile` |

### Raw Entities (5 types)

- `raw_profile` - Person/artist from source
- `raw_recording` - Track from source
- `raw_release` - Album from source
- `raw_recording_credit` - Recording to Profile relationship
- `raw_release_credit` - Release to Profile relationship

**Credit granularity:** profile + release/recording + actual credit role. Same person credited twice = two entries.

### Catalog Entities (3 main types)

- `catalog_profile` - Merged person/artist
- `catalog_track` - Merged recording (deduplication layer)
- `catalog_release` - Merged album

**Note:** `catalog_release_credit` exists but is NOT used. All credits are track-level only.

---

## Key Architectural Decisions

### Credits Inside Tracks (Denormalization)

**Decision:** Store credits inside `catalog_track.profiles` array, not in separate collection.

**Rationale:** The profile credits page requires:
1. Get all tracks for a profile
2. Sort by track popularity

With a separate credits collection, this required expensive joins. With embedded credits:
```javascript
// Query pattern now possible with single collection
db.catalog_track.find({
  "profiles.profile_id": "some-id"
}).sort({ popularity: -1 })
```

**Indexes:** `(profiles.profile_id, popularity)` and `(profiles.profile_id, release_date)`

### Catalog Processing Flow

```
1. Raw entities stored (from capture)
   |
   v
2. Catalog processing triggered
   |
   v
3. Multiple raw entities merged -> one catalog entity
   - Many Spotify recordings -> one Muso track
   - Raw entities linked via `raw_recording_ids` array
   |
   v
4. When ANY raw entity refreshes -> catalog entity refreshes
   - Collects info from all linked raw entities
   - Sorts by priority
   - Decides whether to update catalog fields
```

### Default Raw Recording

Each `catalog_track` has a `default_raw_recording` field. This determines:
- Which image to show
- Which Spotify URL to use

Sorting mechanism on catalog side decides which raw is "default."

---

## Credit Mapping System

### dict_credit Tables

External sources have thousands of credit types. Muso maps them to internal system:

| Source Credit | Muso Parent | Muso Child | Instrument |
|---------------|-------------|------------|------------|
| Spotify "claron" | Musician | Clarinet | Clarinet |

**Purpose:** Simplify 6,000+ source credits into manageable Muso taxonomy.

### Decredit Category Rule (Chart Config)

MongoDB table used as **config for chart formulas**:

```javascript
{
  "category": "Producer",
  "profile_types": ["artist", "professional"],
  "child_credits": ["producer", "executive producer", "co-producer"]
}
```

- Used by platform formula to calculate weekly chart scores
- Easily changeable in MongoDB
- Formula picks up changes on next week's run

---

## PostgreSQL Snapshots

### RDS Instances

| Instance | Database | Purpose | Owner |
|----------|----------|---------|-------|
| analytics_dev/prod | analytics | Capture scheduling | - |
| core_backend_dev/prod | core_backend | Users, payments, subscriptions | Serhii |
| platform_stats_dev/prod | platform_stats | Pre-aggregated analytics | - |

### platform_stats (Aurora)

**Massive database** - billions of rows, ~1 billion operations/day.

Key table: `public.track_daily`
- Granularity: `(date, track_id)`
- Source of truth for all analytics
- Fields: streams, shazams, views, videos + per-source breakdowns

### Dimension Tables

| Table | Purpose |
|-------|---------|
| `profile_track` | Profile to Track relationship |
| `album_track` | Album to Track relationship |

### analytics_link Table

Behaves like a "raw" table for analytics:
- Maps external source IDs to Muso track IDs
- Handles duplicate detection and merging
- `merged_to_id` field tracks when duplicates found

**Duplicate Detection:** Common with Spotify and Shazam. When two external IDs report same stats, system detects and merges to prevent stream duplication.

### analytics_video Table

Relevant only for YouTube, TikTok, Instagram:
- Stores individual videos within a "link" (music)
- `link_id` references the music track
- Used when platforms report video-level stats

---

## Capture Service Details

### Request Deduplication

`capture_request` table prevents infinite loops:
- **TTL: 24 hours**
- Before sending capture request, check if ID was requested recently
- If already requested in last 24 hours, skip

### Scraper Infrastructure

- **~5,000 proxies** in rotation
- Kubernetes cluster deployment
- **5 retries** by default before error
- **No dead letter queues** - SLAs ensure eventual retry
- **Active blocking happens daily** (normal operation)

### Error Handling Philosophy

**System does NOT actively fix broken data.**

Flow:
1. Try scrape a few times
2. If fails, log error, move to next task
3. SLAs ensure entity will be retried later

Accepts: "We just can't scrape some entity for a very long time" as valid state.

---

## Key Insights

1. **Weekly + daily deltas** is a workaround for slow MongoDB to AWS integration
2. **Credits embedded in tracks** for query performance, not normalization purity
3. **24-hour TTL** on capture requests prevents recursive loops
4. **No dead letter queues** because SLAs handle retry
5. **Duplicate detection** critical for Spotify/Shazam stream accuracy
6. **Chart formulas** configured via MongoDB `decredit_category_rule` table

---

## Related Documentation

- Athena schemas: `skills/muso-query-writer/athena-schemas.md`
- Capture service: `skills/muso-clio/references/analytics-worker/overview.md`
- Data dictionary: `skills/muso-clio/references/data-model/data-dictionary.md`
