# Muso.AI Data Model

This directory contains the authoritative data model documentation for Muso.AI.

## Contents

| File | Description |
|------|-------------|
| `data-dictionary.md` | UI-facing field definitions, sources, and quirks |
| `source-map.md` | Entity → backend store mapping |
| `backend-architecture.md` | Database systems and data flow |
| `ddl/` | Schema-only exports (no data) |
| `queries/` | Ad hoc query notes and references |
| `saved-queries/` | Reusable query templates for exports |

## Quick Reference

### Databases

| Database | Type | Purpose | Scale |
|----------|------|---------|-------|
| `core_backend` | PostgreSQL RDS | Users, teams, subscriptions, roster | Medium |
| `analytics` | PostgreSQL RDS | Capture scheduling | Small |
| `platform_stats` | Aurora PostgreSQL | Analytics aggregations | Massive (~1B ops/day) |
| `platform_industry_DB` | MongoDB Atlas | Catalog entities (profile, track, release) | 4M+ profiles |
| `platform_industry_BI` | MongoDB Atlas | Pre-aggregated BI data | Weekly snapshots |

### Key Collections/Tables

| Store | Entity | Purpose |
|-------|--------|---------|
| MongoDB `catalog_track` | Track | Central entity - credits stored inside for query efficiency |
| MongoDB `catalog_profile` | Profile | Music professionals |
| MongoDB `catalog_release` | Release | Albums/releases |
| Postgres `track_daily` | Stats | **Source of truth** for analytics (date + track_id granularity) |
| Postgres `analytics_link` | Link | Maps source IDs (Spotify/YouTube) to Muso track_id |

### Data Flow

```
External Sources (Spotify, YouTube, etc.)
    │
    ▼
Capture Service (5000 proxies, SQS queues)
    │
    ▼
MongoDB raw_* tables (data as-is from source)
    │
    ▼
Catalog Processing (merge/dedupe)
    │
    ▼
MongoDB catalog_* tables (unified entities)
    │
    ▼
Analytics Processing
    │
    ▼
Aurora track_daily (aggregated stats)
    │
    ▼
S3 Data Lake → Athena queries
```

## Related Resources

- Clio entry point: `../../SKILL.md`
- Capabilities planning: `../capabilities-needed.md`
- Architecture docs: `../architecture/`
