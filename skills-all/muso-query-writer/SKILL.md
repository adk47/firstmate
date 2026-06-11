---
name: muso-query-writer
description: |
  Muso.AI query and analytics expert. Write queries for Trino (on OVH), MongoDB, and PostgreSQL.

  Use when: writing Trino/Presto SQL queries, analyzing streaming stats, finding profiles,
  auditing MLC gaps, business metrics, or any data lake queries.

  Triggers: "trino", "query", "sql", "stats", "streaming", "analytics", "data lake"
compatibility: |
  Run queries with `muso query "<SQL>"` from node-8 (main gateway / HYDRA host).
  AWS Athena was retired 2026-04-25; this skill targets the new OVH Trino cluster only.
  NOTE: `muso query` does NO legacy Athena→modern name rewrites. Use modern
  catalog.schema names; for SQL that still carries bare legacy names (see "Legacy
  names: muso does no rewrites" below), keep `bash /opt/hydra/scripts/trino-query.sh`.
metadata:
  version: "2.0"
  source-repo: "Muso-AI/muso-skills"
---

# Muso Query Writer

Write efficient, cost-aware Trino queries against Muso.AI's OVH data platform.

## Quick Start

**Engine:** Trino on OVH | **Cluster:** `trino.data-processing.svc.cluster.local:8080` | **Runner:** `muso query "<SQL>"` (CSV output)

### Trino access (replaces Athena)

```bash
# Run a query (modern catalog.schema names; CSV to stdout)
muso query "SELECT * FROM hive.\"platform-industry-bi-prod\".matvw_catalog_profile LIMIT 10"

# SQL with quotes/parens → stdin heredoc (no shell escaping):
muso query - <<'SQL'
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_profile LIMIT 10
SQL

# Discovery
muso query "SHOW CATALOGS"
muso query "SHOW SCHEMAS FROM hive"
muso query - <<'SQL'
SHOW TABLES FROM hive."platform-industry-bi-prod"
SQL
muso query - <<'SQL'
DESCRIBE hive."platform-industry-bi-prod".matvw_catalog_profile
SQL

# JSON rows instead of CSV:
muso query --format json "SHOW CATALOGS"

# Saved queries are checked into the repo at:
ls /opt/hydra/skills-all/muso-query-writer/saved-queries/
```

### Legacy names: muso does no rewrites

`muso query` sends SQL to Trino verbatim — it does NOT auto-rewrite the legacy
Athena DB names that `trino-query.sh` rewrites (`"platform-stats-export-prod"` →
`postgresql_stats.public`, `"platform-feed/catalog/...-export-prod"`, bare `"bi".`
→ `postgresql_analytics.public`, `hive.mlc.` → `hive."platform-industry-mlc-bi-prod"`,
`"audit-prod"` → `hive.audit`, and the Glue `public_` table-name prefix). A query
using a bare legacy name will fail; muso's error carries the modern-name hint, and
`muso agent-docs` has the full legacy→modern table.

- **New work / discovery:** use modern names with `muso query` (the examples in
  this skill already use `hive."platform-industry-bi-prod"` and `postgresql_*`).
- **Saved queries still on bare legacy names** (most of `saved-queries/` — e.g.
  anything referencing `"platform-stats-export-prod"`, `"bi".`, `hive.mlc.`,
  `"audit-prod"`): either modernize the names first, or run them through
  `bash /opt/hydra/scripts/trino-query.sh "<SQL>"`, which still performs the
  rewrite. trino-query.sh remains available for exactly this case.

### What changed from Athena (2026-04-25 cutover)
- ❌ AWS Athena workgroups (`primary`, `data-engineering`, `growth-dev`) → ✅ Single Trino cluster
- ❌ AWS Glue databases (91 of them) → ✅ `hive.*` schemas + `postgresql_*` connectors
- ❌ `aws athena start-query-execution` (async, poll for results) → ✅ Synchronous `muso query`
- ❌ `--profile muso-flagship-readonly --region us-west-2` → ✅ No AWS auth needed

### Most Used Tables

| Table | Catalog.Schema | Rows | Use For |
|-------|----------------|------|---------|
| `matvw_catalog_profile` | | 29M | Profile lookup, credits |
| `matvw_catalog_track` | | 190M | Track metadata, ISRCs |
| `matvw_stats_track_daily` | | 3.3B | Streaming analytics |
| `users` | postgresql_core.public | 339K | User data (live, no export delay) |
| `subscriptions` | postgresql_core.public | 60K | Subscription status (live) |

## Reference Files

| File | Content |
|------|---------|
| [trino-schemas.md](./trino-schemas.md) | **Real schemas, costs, CTEs** - Actual table definitions, 13 reusable query patterns, performance checklist |
| [reference.md](./reference.md) | **Architecture & concepts** - Data flow, when to use MongoDB vs Athena, troubleshooting |
| muso-clio → `references/data-model/source-map.md` | **Entity → source of truth mapping** - Where data lives (MongoDB, PostgreSQL, ES, S3) |
| muso-clio → `references/data-model/data-dictionary.md` | **Field definitions** - What each field means, quirks, sources |

## When You Don't Know Something

**If the Notion MCP tool is available in this Openclaw deployment, use it before giving up.**

```
Search Notion for: "profile update MongoDB"
```

Key Notion pages to search:
- "How To: Athena" - Data sources, database mapping, useful queries
- "CTO Knowledge Transfer" - Services, architecture, common tasks
- "MongoDB Performance tests" - Query optimization patterns

GitHub reference (useful-queries):
- https://github.com/Muso-AI/platform-data-processing/blob/main/docs/oleg-sql-ai/useful-queries.md

If Notion search is not available (tool not configured/allowed), do **not** ask users for API keys in Slack. Instead:
- Use the curated docs under `muso-clio/references/`
- Ask a DevOps/admin to wire the Notion MCP server into Openclaw for this instance

## Mutations (Updates/Deletes)

**Trino is READ-ONLY (SELECT only).** When users ask to UPDATE or change data:

1. Look up the entity in muso-clio’s `references/data-model/source-map.md`
2. Guide them to the correct system with a source link:

| Entity | Source of Truth | How to Update |
|--------|-----------------|---------------|
| Profile metadata (name, bio, image, `profile_type`) | MongoDB `catalog_profile` | [Admin UI](https://admin-production.muso.ai/) or direct MongoDB |
| Profile claimed status | PostgreSQL `core_backend.profiles` | [Admin UI](https://admin-production.muso.ai/) or Aurora |
| User data (email, auth) | PostgreSQL `core_backend.users` | [Admin UI](https://admin-production.muso.ai/) or Aurora |
| Track/Album data | MongoDB `catalog_track`/`catalog_release` | Automated pipelines (rarely manual) |
| Streaming stats | PostgreSQL `platform_stats.track_daily` | Automated pipelines only |
| **Credits** | MongoDB `catalog_track.profiles[]` | User API, CSV import, or MongoDB → re-materialize (see Credit Update Guide below) |

### Credit Updates

Credits link profiles to tracks with roles (producer, songwriter, engineer).

| Method | When to Use |
|--------|-------------|
| **User API** | `POST /api/m/v3/profile/{id}/add-track-credit` - goes through verification (50%+ risk = rejected) |
| **Bulk CSV** | SQS task: `importProfileCreditsCsv` - for operations team |
| **Manual MongoDB** | Update `source_muso.profile_credit`, then trigger materialization pipeline |
| **Automated** | Pipelines from Jaxsta/Spotify/Tidal/MLC/Genius (how most credits arrive) |

**Credit verification rules** check: popularity mismatch, collaborator changes, duplicate mixing/mastering, scary roles (producer/songwriter have royalty implications).

**Full guide:** See `muso-clio/references/data-model/source-map.md` → "Credit Update Guide"

**Key Resource URLs (always include in responses):**

| Resource | URL |
|----------|-----|
| Admin Panel (Prod) | https://admin-production.muso.ai/ |
| Admin Panel (Dev) | https://admin-nonproduction.muso.ai/ |
| DB Tunneling Guide | https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19 |
| MongoDB Access | https://www.notion.so/adb0059a507743bd8120be793a6648df |

**Example response for update requests:**
> "Trino can't UPDATE data - it's read-only. Profile metadata lives in MongoDB (`catalog_profile` collection).
> To change this profile's `profile_type` to 'Producer Collective, Artist':
> - **Admin UI**: https://admin-production.muso.ai/ (if you have access)
> - **MongoDB**: `db.catalog_profile.updateOne({_id: 'UUID'}, {$set: {profile_type: 'Producer Collective, Artist'}})`
> - **DB Access Guide**: https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19"

## All Data Sources

> **AWS Athena was retired 2026-04-25 → OVH Trino.** Query via `muso query "<SQL>"` (CSV output).
> Use the modern Trino `catalog.schema` name (the "Trino reference" column below). `muso query`
> does NOT rewrite the legacy Athena DB names — only `bash /opt/hydra/scripts/trino-query.sh "<SQL>"`
> still does (use it for saved queries that carry bare legacy names). See "Legacy names: muso does
> no rewrites" above.

Data freshness: daily dumps in 99% of cases.

### MongoDB Snapshots (Catalog DB)
| Database | Description |
|----------|-------------|
| `hive."platform-industry-bi-prod"` | Materialized views (`matvw_*`) - weekly dump + daily deltas. Faster/cheaper than full snapshots |
| `platform-industry-db-industry-prod` | Full weekly MongoDB snapshot (slower, complete) |

### PostgreSQL Snapshots
| Legacy Athena DB | Trino reference | Description |
|----------|----------|-------------|
| `postgresql_core.public` | `postgresql_core.public` | Growth Core DB - users, teams, subscriptions, claiming |
| `platform-stats-export-prod` | `postgresql_stats.public` | Aurora Stats DB - analytics (e.g. `track_daily` streaming stats) |
| `platform-feed-export-prod` | `postgresql_feed.public` | Feed DB (`activity*` tables) |
| `platform-industry-calculations-export-prod` | `postgresql_industry.public` ⚠️ | Milestones, calculations — Trino role lacks SELECT grant (permission denied); grant pending |
| `platform-catalog-export-prod` | `postgresql_catalog.public` | Aurora Catalog DB |

### Platform Tables (Pipeline-generated)
| Database | Description |
|----------|-------------|
| `platform-industry-calc-common-prod` | Common calculations |
| `platform-industry-calc-prod` | Main calculation tables (Andrey's formulas) |

### External Data Imports
| Database | Description |
|----------|-------------|
| `platform-industry-amplitude-bi-prod` | Amplitude analytics export |
| `platform-import-payments-prod` | Stripe, Apple, Google payments |
| `hive."platform-industry-mlc-bi-prod"` | MLC mechanical licensing data |
| `platform-industry-zyteig-bi-prod` | Zyte scraped data |
| `platform-anghami-bi-prod` | Anghami streams |
| `platform-qobuz-bi-prod` | Qobuz streams |
| `platform-industry-audiomack-bi-prod` | Audiomack streams |

### Other
| Database | Description |
|----------|-------------|
| `aws-admin` | CloudFront and WAF tables |

## Critical Rules

1. **Always use `LIMIT`** when developing queries
2. **Always filter by date** on `matvw_stats_track_daily` (3.3B rows!)
3. **Always filter `is_deleted = false`** on catalog tables
4. **Mind table sizes** - unbounded scans on the big hive tables are slow on the Trino cluster (the old per-TB Athena billing is gone, but the wall-clock cost isn't)
5. **Filter-before-join** - Filter stats in CTE *before* joining to profiles
6. **Never join on names** - Resolve to IDs first, then query by ID
7. **Use `approx_distinct()`** instead of `COUNT(DISTINCT)` on huge tables

## Common Queries

### Find a profile
```sql
SELECT _id, name, popularity, credits_count
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE lower(name) LIKE '%drake%' AND NOT is_deleted
ORDER BY popularity DESC
LIMIT 20
```

### Get profile's streaming stats (last 30 days)
```sql
WITH profile_tracks AS (
    SELECT t._id AS track_id
    FROM hive."platform-industry-bi-prod".matvw_catalog_track t
    CROSS JOIN UNNEST(t.profiles) AS p(profile)
    WHERE profile.profile_id = 'PROFILE_ID' AND NOT t.is_deleted
)
SELECT SUM(streams) AS total_streams
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN profile_tracks pt ON s.track_id = pt.track_id
WHERE s.date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d')
```

### Check if profile is claimed/pro
```sql
WITH claimed AS (
    SELECT profileid AS profile_id FROM postgresql_core.public.claiming
    WHERE status = 'processed' GROUP BY 1
),
pro AS (
    SELECT seatid AS profile_id FROM postgresql_core.public.roster_seats
    WHERE status = 'active' GROUP BY 1
)
SELECT
    p._id, p.name,
    cl.profile_id IS NOT NULL AS is_claimed,
    pr.profile_id IS NOT NULL AS is_pro
FROM hive."platform-industry-bi-prod".matvw_catalog_profile p
LEFT JOIN claimed cl ON cl.profile_id = p._id
LEFT JOIN pro pr ON pr.profile_id = p._id
WHERE p._id = 'PROFILE_ID'
```

See [trino-schemas.md](./trino-schemas.md) for 13 more reusable CTE patterns.
