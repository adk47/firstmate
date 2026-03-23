---
name: muso-query-writer
description: |
  Muso.AI query and analytics expert. Write queries for Athena, MongoDB, and Aurora.

  Use when: writing Athena/Presto queries, analyzing streaming stats, finding profiles,
  auditing MLC gaps, business metrics, or any data lake queries.

  Triggers: "athena", "query", "sql", "stats", "streaming", "analytics", "data lake"
compatibility: |
  Optional: AWS CLI configured for Muso (e.g., `muso-flagship-readonly` profile) for running commands.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Muso Query Writer

Write efficient, cost-aware queries against Muso.AI's data infrastructure.

## Quick Start

**AWS Profile:** `muso-flagship-readonly` | **Region:** `us-west-2` | **Workgroup:** `primary`

### CRITICAL: Region Policy

**All Muso resources (dev AND prod) are in `us-west-2`. Do NOT search other regions.**

If a query returns empty results, report "no resources found" — do not search other regions. Resources in eu-west-1, us-east-1, etc. are abandoned staging/test artifacts from 2022.

### AWS CLI Access

```bash
# Athena queries (Flagship account)
aws athena start-query-execution \
    --query-string "SELECT * FROM ..." \
    --work-group primary \
    --profile muso-flagship-readonly \
    --region us-west-2

# List saved queries (50+ available)
aws athena list-named-queries --profile muso-flagship-readonly --region us-west-2

# List Glue databases (91 databases)
aws glue get-databases --profile muso-flagship-readonly --region us-west-2
```

### Workgroups

| Workgroup | Engine | Use For |
|-----------|--------|---------|
| `primary` | Athena v3 | Standard SQL queries |
| `data-engineering` | Athena v3 | Data team queries |
| `growth-dev` | Athena v3 | Growth analytics |
| `Spark_primary` | PySpark v3 | Spark notebooks/jobs |

### Most Used Tables

| Table | Database | Rows | Use For |
|-------|----------|------|---------|
| `matvw_catalog_profile` | platform-industry-bi-prod | 29M | Profile lookup, credits |
| `matvw_catalog_track` | platform-industry-bi-prod | 190M | Track metadata, ISRCs |
| `matvw_stats_track_daily` | platform-industry-bi-prod | 3.3B | Streaming analytics |
| `public_users` | platform-core-backend-export-prod | 339K | User data |
| `public_subscriptions` | platform-core-backend-export-prod | 60K | Subscription status |

## Reference Files

| File | Content |
|------|---------|
| [athena-schemas.md](./athena-schemas.md) | **Real schemas, costs, CTEs** - Actual table definitions, 13 reusable query patterns, performance checklist |
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

**Athena is READ-ONLY (SELECT only).** When users ask to UPDATE or change data:

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
> "Athena can't UPDATE data - it's read-only. Profile metadata lives in MongoDB (`catalog_profile` collection).
> To change this profile's `profile_type` to 'Producer Collective, Artist':
> - **Admin UI**: https://admin-production.muso.ai/ (if you have access)
> - **MongoDB**: `db.catalog_profile.updateOne({_id: 'UUID'}, {$set: {profile_type: 'Producer Collective, Artist'}})`
> - **DB Access Guide**: https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19"

## All Data Sources (Athena Databases)

Data freshness: daily dumps in 99% of cases.

### MongoDB Snapshots (Catalog DB)
| Database | Description |
|----------|-------------|
| `platform-industry-bi-prod` | Materialized views (`matvw_*`) - weekly dump + daily deltas. Faster/cheaper than full snapshots |
| `platform-industry-db-industry-prod` | Full weekly MongoDB snapshot (slower, complete) |

### PostgreSQL Snapshots
| Database | Description |
|----------|-------------|
| `platform-core-backend-export-prod` | Growth Core DB - users, teams, subscriptions, claiming |
| `platform-stats-export-prod` | Aurora Stats DB - analytics processing, raw data for Industry APIs |
| `platform-feed-export-prod` | Feed DB - currently only "follow" table |
| `platform-industry-calculations-export-prod` | Milestones, calculations |
| `platform-catalog-export-prod` | Aurora Catalog DB |

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
| `platform-industry-mlc-bi-prod` | MLC mechanical licensing data |
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
4. **Athena costs ~$5/TB scanned** - be mindful of table sizes
5. **Filter-before-join** - Filter stats in CTE *before* joining to profiles
6. **Never join on names** - Resolve to IDs first, then query by ID
7. **Use `approx_distinct()`** instead of `COUNT(DISTINCT)` on huge tables

## Common Queries

### Find a profile
```sql
SELECT _id, name, popularity, credits_count
FROM "platform-industry-bi-prod".matvw_catalog_profile
WHERE lower(name) LIKE '%drake%' AND NOT is_deleted
ORDER BY popularity DESC
LIMIT 20
```

### Get profile's streaming stats (last 30 days)
```sql
WITH profile_tracks AS (
    SELECT t._id AS track_id
    FROM "platform-industry-bi-prod".matvw_catalog_track t
    CROSS JOIN UNNEST(t.profiles) AS p(profile)
    WHERE profile.profile_id = 'PROFILE_ID' AND NOT t.is_deleted
)
SELECT SUM(streams) AS total_streams
FROM "platform-industry-bi-prod".matvw_stats_track_daily s
JOIN profile_tracks pt ON s.track_id = pt.track_id
WHERE s.date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d')
```

### Check if profile is claimed/pro
```sql
WITH claimed AS (
    SELECT profileid AS profile_id FROM "platform-core-backend-export-prod".public_claiming
    WHERE status = 'processed' GROUP BY 1
),
pro AS (
    SELECT seatid AS profile_id FROM "platform-core-backend-export-prod".public_roster_seats
    WHERE status = 'active' GROUP BY 1
)
SELECT
    p._id, p.name,
    cl.profile_id IS NOT NULL AS is_claimed,
    pr.profile_id IS NOT NULL AS is_pro
FROM "platform-industry-bi-prod".matvw_catalog_profile p
LEFT JOIN claimed cl ON cl.profile_id = p._id
LEFT JOIN pro pr ON pr.profile_id = p._id
WHERE p._id = 'PROFILE_ID'
```

See [athena-schemas.md](./athena-schemas.md) for 13 more reusable CTE patterns.
