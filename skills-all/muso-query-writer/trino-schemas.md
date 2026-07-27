---
name: muso-trino-query
description: Write Trino SQL queries against Muso.AI's OVH data platform (replaces AWS Athena, retired 2026-04-25). Use when analyzing music industry data, streaming stats, profiles, credits, MLC gaps, or business metrics.
---

# Muso.AI Trino Query Writer

Write correct, efficient Trino SQL queries for Muso.AI's OVH data platform (Hive on OVH S3 IO + PostgreSQL connectors). AWS Athena was retired 2026-04-25; the SQL grammar is essentially identical (Trino is the engine Athena v3 was built on), but catalog/schema names and execution differ.

## Quick Reference

### Primary Databases

| Database | Purpose | Key Tables |
|----------|---------|------------|
| `hive."platform-industry-bi-prod"` | Industry analytics (main) | catalog_track, catalog_profile, stats_track_daily |
| `postgresql_core.public` | Users, teams, subscriptions | public_users, public_teams, public_subscriptions |
| `postgresql_analytics.public` (legacy bare `"bi".`) | Business intelligence | marketing_*, reporting_weekly_* |
| `hive.audit` | Catalog audits | audit_profile, audit_track, audit_isrc |
| `postgresql_stats.public` | Streaming/analytics stats (live PG; legacy `platform-stats-export-prod`) | track_daily, profile_track, album_track |
| `postgresql_olap.public` | OLAP analytics cubes (per-profile/track, lifetime + windowed) | cube_analytics_profile_view (ce_streams = lifetime streams @ period='all') |

### Table Naming Convention

- Tables in `hive."platform-industry-bi-prod"` use prefix `matvw_` (materialized view)
- Tables in `postgresql_core.public` use prefix `public_`
- Always use double quotes for database names with hyphens

## Deprecated / Dead Tables (do NOT read)

**Rule: anything matching `*v3*` is suspect — do NOT read it.** These tables were frozen
2026-06-06 and return stale data. Resolve to the live cube instead.

| Dead table | Status | Live replacement |
|---|---|---|
| `postgresql_core.public.profile_v3_lifetime` | FROZEN 2026-06-06 | `postgresql_olap.public.cube_analytics_profile_view` (`period='all'`) |
| `postgresql_core.public.profile_v3_tracks` | FROZEN 2026-06-06 | `postgresql_olap.public.cube_analytics_profile_view` (`period='all'`) |

Column crosswalk: `streams`→`ce_streams`, `spotifystreams`→`ce_spotify_streams`,
`youtubestreams`→`ce_youtube_streams`, `creditcount`→`profile_credits_count`,
`trackswithdata`→`tracks_count`. `ce_streams` at `period='all'` is the per-artist lifetime
total the muso.ai profile page shows (native bigint, recomputed continuously). **For
per-artist lifetime totals, prefer the `muso-streams-lookup` skill over hand-written SQL.**

## Core Tables Schema

### matvw_catalog_track (190M tracks)
```sql
SELECT
    _id,                        -- Track ID (string)
    title,                      -- Track title
    isrcs,                      -- array<string> of ISRCs
    artists,                    -- array<struct> with catalog_profile_id, name
    profiles,                   -- array<struct> with credits info
    release_timestamp,          -- Unix timestamp
    duration,                   -- Duration in ms
    popularity,                 -- Popularity score
    rank,                       -- Rank score
    default_release,            -- struct with album info
    default_release_label,      -- Label name
    audio_features,             -- struct with acousticness, energy, etc.
    images,                     -- array<struct> of cover images
    preview_url,                -- Spotify preview URL
    is_deleted                  -- Soft delete flag
FROM hive."platform-industry-bi-prod".matvw_catalog_track
WHERE is_deleted = false
```

### matvw_catalog_profile (29M profiles)

> Column list verified against the live cluster 2026-07-24 (information_schema +
> direct SELECT). The Athena-era columns `credits_count_1y`, `top_collaborators`,
> `child_roles`, `genres`, `primary_genre`, `decades`, `years_active` do NOT exist
> on the OVH matview — a SELECT naming them fails with "Column cannot be resolved".

```sql
SELECT
    _id,                        -- Profile ID (string)
    name,                       -- Display name
    first_name, last_name,      -- Name parts
    legal_name,                 -- Legal/real name
    known_as_names,             -- array<string> of aliases
    profile_type,               -- 'artist', 'professional', 'organization', 'person', 'band', 'compilation_profile', 'non_music_profile'
    profile_sub_type,           -- More specific type
    roles,                      -- array<string> of roles
    common_credits,             -- array<string> of common credits
    credits_count,              -- Total credits
    collaborations_count,       -- Number of collaborators
    popularity, rank,           -- Scoring
    country, state, city,       -- Location
    ipis,                       -- array<bigint> of IPI numbers
    images,                     -- Profile images
    about,                      -- Bio text
    merged_to_id,               -- Set when this profile was merged away
    raw_profile_ids,            -- Source raw IDs
    created_timestamp, updated_timestamp,
    is_deleted                  -- Soft delete flag
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE is_deleted = false
```

### matvw_stats_track_daily (3.3B rows)
```sql
SELECT
    track_id,                   -- Links to catalog_track._id
    date,                       -- Date string 'YYYY-MM-DD'

    -- Platform-specific streams
    spotify_streams,
    youtube_streams,
    soundcloud_streams,
    audiomack_streams,
    anghami_streams,
    qobuz_streams,

    -- Social/discovery
    shazam_shazams,
    tiktok_views,
    tiktok_videos,
    youtube_views,
    youtube_videos,
    instagram_views,
    instagram_videos,

    -- Aggregates
    streams,                    -- Total streams
    shazams,                    -- Total shazams
    views,                      -- Total video views
    videos                      -- Total video count
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
```

### public_users (339K users)
```sql
SELECT
    id,                         -- User ID (bigint)
    email,
    firstname, lastname, fullname,
    createdat,                  -- Creation timestamp
    lastactivetime,             -- Last activity
    defaultteamid,              -- Primary workspace
    stripecustomerid,
    auth0userid,
    isadmin,
    emailconfirmed,
    referralcode,
    referredbyuserid
FROM postgresql_core.public.users
```

### public_teams (339K teams/workspaces)
```sql
SELECT
    id,                         -- Team ID (string UUID)
    name,
    email,
    createdat,
    stripecustomerid,
    isdefault,                  -- Is personal workspace
    inhouseanalyticsenabled
FROM postgresql_core.public.teams
```

### public_subscriptions (60K subscriptions)
```sql
SELECT
    id,
    userid,
    teamid,
    service,                    -- 'stripe', 'apple', 'paypal', 'google'
    status,                     -- 'active', 'canceled', etc.
    plan,                       -- Plan name
    profileseatslimit,          -- Profile seats included
    organizationseatslimit,     -- Org seats included
    userslimit,                 -- User limit
    externalsubid,              -- External subscription ID
    createdat, updatedat
FROM postgresql_core.public.subscriptions
```

## Common Query Patterns

### Find profile by name
```sql
SELECT _id, name, roles, credits_count, popularity
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE lower(name) LIKE lower('%drake%')
  AND is_deleted = false
ORDER BY popularity DESC
LIMIT 20
```

### Get tracks for a profile
```sql
SELECT t._id, t.title, t.isrcs, t.release_timestamp
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
WHERE profile.profile_id = 'PROFILE_ID_HERE'
  AND t.is_deleted = false
ORDER BY t.release_timestamp DESC
```

### Calculate streaming stats for a profile
```sql
WITH profile_tracks AS (
    SELECT t._id as track_id
    FROM hive."platform-industry-bi-prod".matvw_catalog_track t
    CROSS JOIN UNNEST(t.profiles) AS p(profile)
    WHERE profile.profile_id = 'PROFILE_ID_HERE'
      AND t.is_deleted = false
)
SELECT
    SUM(s.spotify_streams) as total_spotify,
    SUM(s.youtube_streams) as total_youtube,
    SUM(s.streams) as total_streams
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN profile_tracks pt ON s.track_id = pt.track_id
WHERE s.date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d')
```

### Find tracks by ISRC
```sql
SELECT _id, title, artists, release_timestamp
FROM hive."platform-industry-bi-prod".matvw_catalog_track
WHERE contains(isrcs, 'USRC12345678')
  AND is_deleted = false
```

### Top tracks by streams (last 30 days)
```sql
SELECT
    t._id,
    t.title,
    t.artists[1].name as primary_artist,
    SUM(s.streams) as total_streams
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN hive."platform-industry-bi-prod".matvw_catalog_track t ON s.track_id = t._id
WHERE s.date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d')
  AND t.is_deleted = false
GROUP BY t._id, t.title, t.artists[1].name
ORDER BY total_streams DESC
LIMIT 100
```

### Active subscribers by plan
```sql
SELECT
    plan,
    service,
    COUNT(*) as subscriber_count
FROM postgresql_core.public.subscriptions
WHERE status = 'active'
GROUP BY plan, service
ORDER BY subscriber_count DESC
```

### User growth by month
```sql
SELECT
    date_trunc('month', date_parse(createdat, '%Y-%m-%d %H:%i:%s')) as month,
    COUNT(*) as new_users
FROM postgresql_core.public.users
WHERE createdat IS NOT NULL
GROUP BY 1
ORDER BY 1
```

### Profile claiming status
```sql
SELECT
    c.status,
    COUNT(*) as profile_count
FROM hive."platform-industry-bi-prod".matvw_muso_claiming c
GROUP BY c.status
```

## Working with Nested Data

### Unnest arrays
```sql
-- Get all ISRCs from a track
SELECT t._id, isrc
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.isrcs) AS i(isrc)
WHERE t._id = 'TRACK_ID'

-- Get all artists from tracks
SELECT t._id, artist.catalog_profile_id, artist.name
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.artists) AS a(artist)
```

### Access struct fields
```sql
-- Audio features
SELECT
    _id,
    title,
    audio_features.energy,
    audio_features.danceability,
    audio_features.tempo
FROM hive."platform-industry-bi-prod".matvw_catalog_track
WHERE audio_features IS NOT NULL
```

## Query Cost & Performance

### CRITICAL: Know Your Table Sizes

Athena charges ~$5 per TB scanned. These tables can be expensive:

| Table | Rows | Size | Full Scan Cost |
|-------|------|------|----------------|
| `matvw_stats_track_daily` | **3.3 BILLION** | ~95 GB | ~$0.50 |
| `matvw_capture_spotify_stats` | **753 MILLION** | ~217 GB | ~$1.10 |
| `matvw_catalog_track` | 190 million | ~107 GB | ~$0.55 |
| `matvw_mlc_worksrecordings` | 298 million | ~4 GB | ~$0.02 |
| `matvw_catalog_profile` | 29 million | ~2 GB | ~$0.01 |
| `public_users` | 339K | ~58 MB | negligible |
| `public_subscriptions` | 60K | ~7 MB | negligible |

### Development Query Rules

**ALWAYS do these when developing/testing queries:**

```sql
-- 1. ALWAYS use LIMIT when exploring
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track
LIMIT 100;  -- Never omit during development

-- 2. Test JOINs on small subsets first
WITH sample_tracks AS (
    SELECT _id FROM hive."platform-industry-bi-prod".matvw_catalog_track
    LIMIT 1000  -- Sample first!
)
SELECT s.*
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN sample_tracks t ON s.track_id = t._id
LIMIT 100;

-- 3. Use date filters on stats tables IMMEDIATELY
SELECT * FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= '2025-01-01'  -- Always filter date first!
  AND date <= '2025-01-07'  -- Narrow window for testing
LIMIT 100;

-- 4. Check row counts before full queries
SELECT COUNT(*) FROM hive."platform-industry-bi-prod".matvw_catalog_track
WHERE lower(title) LIKE '%beatles%';  -- Know what you're dealing with
```

### Dangerous Patterns to Avoid

```sql
-- BAD: Full table scan on 3.3B rows
SELECT SUM(streams) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily;

-- GOOD: Filter by date range
SELECT SUM(streams) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= '2025-01-01' AND date < '2025-02-01';

-- BAD: Cross join without limits during development
SELECT * FROM matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile);

-- GOOD: Add LIMIT while developing
SELECT * FROM matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
LIMIT 100;

-- BAD: JOIN two massive tables without filters
SELECT * FROM matvw_stats_track_daily s
JOIN matvw_catalog_track t ON s.track_id = t._id;

-- GOOD: Filter both sides first
SELECT * FROM matvw_stats_track_daily s
JOIN matvw_catalog_track t ON s.track_id = t._id
WHERE s.date >= date_format(date_add('day', -7, current_date), '%Y-%m-%d')
  AND t.popularity > 90
LIMIT 100;
```

### Query Development Workflow

1. **Estimate scope first**
   ```sql
   -- How many rows will this touch?
   SELECT COUNT(*) FROM my_table WHERE my_conditions;
   ```

2. **Develop with LIMIT 100**
   - Get the query structure right on small data

3. **Test with LIMIT 10000**
   - Verify performance at moderate scale

4. **Remove LIMIT for production**
   - Only after confirming the query is correct and filtered

### Partitioned Tables

These tables have `date` partitions - **always filter on date**:
- `matvw_stats_track_daily` (partitioned by date)
- `matvw_capture_spotify_stats` (partitioned by date)
- `matvw_capture_*` tables (generally partitioned)

```sql
-- Partition filter reduces data scanned dramatically
WHERE date >= '2025-01-01' AND date < '2025-02-01'
```

### Column Selection

Athena is columnar - selecting fewer columns = less data scanned:

```sql
-- BAD: Scans all columns
SELECT * FROM matvw_catalog_track LIMIT 100;

-- GOOD: Only scan needed columns
SELECT _id, title, popularity FROM matvw_catalog_track LIMIT 100;
```

### Performance Checklist

Before running any query, verify:
- [ ] Using `LIMIT` if developing/exploring
- [ ] Date filters on time-series tables (use actual partition column `date`, not `created_at`)
- [ ] `is_deleted = false` on catalog tables
- [ ] Selecting only needed columns
- [ ] JOINs have appropriate filters on both sides
- [ ] No accidental cross joins on large tables
- [ ] Filter stats CTE *before* joining to profiles (filter-before-join)
- [ ] Using `approx_distinct()` instead of `COUNT(DISTINCT)` on huge tables
- [ ] IDs are quoted (UUIDs are strings, not integers)

## Gold Rules

### 1. Filter-Before-Join (Critical for Performance)

**Never join 190M tracks to 3.3B stats rows without filtering first.**

```sql
-- BAD: Join then filter (memory explosion)
SELECT p.name, SUM(s.streams)
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN hive."platform-industry-bi-prod".matvw_catalog_track t ON s.track_id = t._id
CROSS JOIN UNNEST(t.profiles) AS pr(profile)
JOIN hive."platform-industry-bi-prod".matvw_catalog_profile p ON p._id = profile.profile_id
WHERE p._id = 'TARGET_PROFILE_ID'
GROUP BY 1;

-- GOOD: Filter in CTE first, then join
WITH target_tracks AS (
    SELECT t._id AS track_id
    FROM hive."platform-industry-bi-prod".matvw_catalog_track t
    CROSS JOIN UNNEST(t.profiles) AS pr(profile)
    WHERE profile.profile_id = 'TARGET_PROFILE_ID'
      AND NOT t.is_deleted
),
filtered_stats AS (
    SELECT track_id, SUM(streams) AS total_streams
    FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
    WHERE date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d')
    GROUP BY 1
)
SELECT SUM(fs.total_streams)
FROM target_tracks tt
JOIN filtered_stats fs ON fs.track_id = tt.track_id;
```

### 2. Filter Before Unnesting (Avoid Row Explosion)

190M tracks × avg 5 credits = 1B+ rows if you unnest first.

```sql
-- BAD: Unnest all 190M tracks then filter
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
WHERE profile.profile_id = 'TARGET_ID';

-- GOOD: Filter tracks first using contains(), then unnest
SELECT t._id, t.title, profile.profile_id, credit.child AS role
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
CROSS JOIN UNNEST(profile.catalog_credits) AS c(credit)
WHERE contains(transform(t.profiles, x -> x.profile_id), 'TARGET_ID')  -- Filter first!
  AND profile.profile_id = 'TARGET_ID'
  AND NOT t.is_deleted;
```

### 3. Never Join on String Names

Always resolve names to IDs first, then perform analysis via IDs.

```sql
-- BAD: Joining on artist name (inconsistent, slow)
SELECT * FROM tracks WHERE artist_name = 'Drake';

-- GOOD: Resolve name to ID first, then use ID
WITH target_profile AS (
    SELECT _id FROM hive."platform-industry-bi-prod".matvw_catalog_profile
    WHERE lower(name) = 'drake' AND NOT is_deleted
    ORDER BY popularity DESC LIMIT 1
)
SELECT t.*
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
WHERE profile.profile_id = (SELECT _id FROM target_profile)
  AND NOT t.is_deleted;
```

### 4. Use TABLESAMPLE for Discovery

`LIMIT` doesn't reduce data scanned in aggregates. Use `TABLESAMPLE` instead.

```sql
-- BAD: Still scans full table despite LIMIT
SELECT COUNT(*), AVG(streams)
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
LIMIT 1000;

-- GOOD: Sample 0.1% of data for exploratory queries
SELECT COUNT(*) * 1000 AS estimated_count, AVG(streams)
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
TABLESAMPLE BERNOULLI (0.1);
```

### 5. Use approx_distinct() for Unique Counts

`COUNT(DISTINCT)` on 3.3B rows will exhaust memory.

```sql
-- BAD: Memory explosion on huge tables
SELECT COUNT(DISTINCT track_id) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily;

-- GOOD: ~2% error but 10x faster
SELECT approx_distinct(track_id) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d');
```

## Data Cleaning Helpers

### ISRC Normalization

ISRCs from external sources are often dirty (hyphens, mixed case).

```sql
-- Normalize ISRC for matching
SELECT UPPER(REPLACE(isrc, '-', '')) AS normalized_isrc

-- Match external CSV to our data
WITH external_isrcs AS (
    SELECT UPPER(REPLACE(isrc, '-', '')) AS isrc FROM external_data
)
SELECT t._id, t.title, e.isrc
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.isrcs) AS i(isrc)
JOIN external_isrcs e ON UPPER(REPLACE(i.isrc, '-', '')) = e.isrc
WHERE NOT t.is_deleted;
```

### IPI Normalization

IPIs may have leading zeros in some sources.

```sql
-- Normalize IPI (remove leading zeros for comparison)
SELECT CAST(CAST(ipi AS BIGINT) AS VARCHAR) AS normalized_ipi

-- Or pad to consistent length
SELECT LPAD(CAST(ipi AS VARCHAR), 11, '0') AS padded_ipi
```

## Terminology Clarification

| Term | Table | Meaning |
|------|-------|---------|
| **User** | `public_users` | Person using the Muso.AI app (has email, login) |
| **Profile** | `matvw_catalog_profile` | Music industry entity (artist, producer, label) |
| **Claimed Profile** | `public_claiming` | Profile verified/owned by a User |
| **Pro Profile** | `public_roster_seats` | Profile with active paid subscription |
| **Team/Workspace** | `public_teams` | Organization unit for billing and collaboration |

**Common confusion:** "Get all users" usually means `public_users`. "Get all artists" means `matvw_catalog_profile WHERE profile_type = 'artist'`.

## AWS CLI Query Execution

### AWS Profiles

| Profile | Account | Resources |
|---------|---------|-----------|
| `(retired 2026-04-25)` | Flagship | Athena, Glue (91 DBs), Route53, Lambda, ECS, EKS |
| `muso-readonly` | Plaque | S3 buckets |

### CRITICAL: Region Policy

**All Muso resources (dev AND prod) are in `us-west-2`. Do NOT search other regions.**

- Both dev (`*-dev`) and prod (`*-prod`) environments are in us-west-2
- If a query returns empty results in us-west-2, report "no resources found"
- Do NOT automatically search eu-west-1, us-east-1, or other regions
- Resources in other regions are abandoned staging/test artifacts from 2022 or earlier

### Workgroups

| Workgroup | Engine | Use For |
|-----------|--------|---------|
| `primary` | Athena v3 | Standard SQL queries |
| `data-engineering` | Athena v3 | Data team queries |
| `growth-dev` | Athena v3 | Growth analytics |
| `Spark_primary` | PySpark v3 | Spark notebooks/jobs |

### Running Queries

```bash
# Run a query (synchronous; CSV to stdout). Use modern catalog.schema names —
# muso query does NO legacy Athena→modern rewrite (errors carry the modern-name
# hint; muso agent-docs has the legacy→modern table). For SQL with quotes/parens,
# use the stdin heredoc form. For saved queries still on bare legacy names, run
# bash /opt/hydra/scripts/trino-query.sh "<SQL>" (it still rewrites).
muso query "SELECT * FROM hive.\"platform-industry-bi-prod\".matvw_catalog_profile LIMIT 10"

muso query - <<'SQL'
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_profile LIMIT 10
SQL

# RETIRED 2026-04-25 — Trino returns synchronously; no separate status/get-results step
# (legacy: aws athena start-query-execution / get-query-execution / get-query-results)
```

### Exploring Resources

```bash
# List saved queries (50+ available)
# RETIRED 2026-04-25 — saved queries now in skills-all/muso-query-writer/saved-queries/
# (legacy: aws athena list-named-queries) 

# Get a specific saved query
# RETIRED 2026-04-25 — see skills-all/muso-query-writer/saved-queries/
# (legacy: aws athena get-named-query) --named-query-id QUERY_ID 

# List Glue databases (91 databases)
# RETIRED 2026-04-25 — use: muso query "SHOW SCHEMAS FROM hive"
# (legacy: aws glue get-databases)

# Get tables in a database
# RETIRED 2026-04-25 — use the heredoc form (quoted schema name):
#   muso query - <<'SQL'
#   SHOW TABLES FROM hive."platform-industry-bi-prod"
#   SQL
# (legacy: aws glue get-tables --database-name platform-industry-bi-prod)
```

## Reusable CTEs & Patterns

These patterns are extracted from 230+ saved queries used by the Muso.AI team.

### Claimed Profiles CTE
Get profiles that have been claimed by users:
```sql
WITH claimed AS (
    SELECT
        profileid AS profile_id,
        TRUE AS is_claimed,
        min_by(t.email, c.createdat) AS claim_email,
        min_by(teamid, c.createdat) AS claim_team_id
    FROM postgresql_core.public.claiming AS c
    JOIN postgresql_core.public.teams AS t ON (c.teamid = t.id)
    WHERE c.status = 'processed'
    GROUP BY 1
)
```

### Pro/Active Seats CTE
Get profiles with active pro subscriptions:
```sql
WITH pro AS (
    SELECT
        seatid AS profile_id,
        TRUE AS is_pro,
        BOOL_OR(type = 'organization') AS is_org
    FROM postgresql_core.public.roster_seats
    WHERE status = 'active'
    GROUP BY 1
)
```

### Team Subscription Status CTE
Check subscription status for teams:
```sql
WITH team_subs AS (
    SELECT
        teamid,
        count_if(status = 'active') > 0 AS has_active_sub,
        count_if(status = 'active' AND json_extract_scalar(details, '$.autoRenew') = 'false') > 0 AS is_suspended,
        count_if(status = 'canceled') > 0 AS is_canceled
    FROM postgresql_core.public.subscriptions
    GROUP BY 1
)
```

### Profile with Raw IDs
Expand profiles to their raw source IDs:
```sql
-- Get Spotify IDs for profiles
SELECT
    _id AS profile_id,
    split_part(rid, ':', 2) AS spotify_id
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
CROSS JOIN UNNEST(raw_profile_ids) AS r(rid)
WHERE NOT is_deleted
  AND rid LIKE 'spotify:%'

-- Get all raw profile mappings
SELECT
    _id AS profile_id,
    rid AS raw_profile_id,
    split_part(rid, ':', 1) AS source
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
CROSS JOIN UNNEST(raw_profile_ids) AS r(rid)
WHERE NOT is_deleted
```

### Track Credits Unnest
Get profiles credited on tracks:
```sql
SELECT
    t._id AS track_id,
    t.title,
    profile.profile_id,
    credit.parent AS credit_category,
    credit.child AS credit_role
FROM hive."platform-industry-bi-prod".matvw_catalog_track AS t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
CROSS JOIN UNNEST(profile.catalog_credits) AS c(credit)
WHERE NOT t.is_deleted
```

### Track Artists Unnest
Get primary artists from tracks:
```sql
SELECT
    t._id AS track_id,
    t.title,
    artist.catalog_profile_id AS artist_id,
    artist.name AS artist_name
FROM hive."platform-industry-bi-prod".matvw_catalog_track AS t
CROSS JOIN UNNEST(t.artists) AS a(artist)
WHERE NOT t.is_deleted
```

### MLC Party Matching by IPI
Match profiles to MLC parties via IPI numbers:
```sql
WITH mlc_parties AS (
    SELECT
        cast(feedproviderspartyid AS varchar) AS mlc_party_id,
        ipinamenumber AS ipi,
        fullname AS mlc_name
    FROM hive."platform-industry-mlc-bi-prod".parties
    WHERE ipinamenumber > 0
)
SELECT
    p._id AS profile_id,
    p.name,
    m.ipi,
    m.mlc_name
FROM hive."platform-industry-bi-prod".matvw_catalog_profile AS p
CROSS JOIN UNNEST(p.ipis) AS i(ipi)
JOIN mlc_parties AS m ON (i.ipi = m.ipi)
WHERE NOT p.is_deleted
```

### Company Roster via Members
Get profiles managed by a company (label, publisher, manager):
```sql
WITH company_roster AS (
    SELECT DISTINCT
        profile_id AS company_id,
        member_id AS profile_id,
        membership_type  -- 'record_label', 'manager', 'publisher'
    FROM hive."platform-industry-bi-prod".matvw_catalog_member
    WHERE NOT is_deleted
      AND membership_type IN ('record_label', 'manager', 'publisher')
)
SELECT
    cr.company_id,
    cr.membership_type,
    p._id AS profile_id,
    p.name,
    p.popularity
FROM company_roster cr
JOIN hive."platform-industry-bi-prod".matvw_catalog_profile AS p ON (p._id = cr.profile_id)
WHERE NOT p.is_deleted
```

### Popularity Ranking
Rank profiles by popularity within categories:
```sql
WITH ranked_profiles AS (
    SELECT
        _id AS profile_id,
        name,
        popularity,
        profile_type,
        ROW_NUMBER() OVER (
            PARTITION BY profile_type
            ORDER BY popularity DESC, credits_count DESC
        ) AS popularity_rank
    FROM hive."platform-industry-bi-prod".matvw_catalog_profile
    WHERE NOT is_deleted
      AND profile_type IN ('organization', 'artist', 'professional')
)
SELECT * FROM ranked_profiles WHERE popularity_rank <= 100
```

### Date Conversion from Timestamps
Convert Unix timestamps to dates:
```sql
-- Release timestamp (milliseconds)
SELECT
    _id,
    title,
    DATE(FROM_UNIXTIME(release_timestamp / 1000)) AS release_date,
    YEAR(FROM_UNIXTIME(release_timestamp / 1000)) AS release_year
FROM hive."platform-industry-bi-prod".matvw_catalog_track

-- Filter tracks released this year
WHERE FROM_UNIXTIME(release_timestamp / 1000) >= DATE_TRUNC('year', current_date)

-- Anniversary calculations
SELECT
    _id,
    title,
    YEAR(CURRENT_DATE) - YEAR(FROM_UNIXTIME(release_timestamp / 1000)) AS years_since_release
FROM hive."platform-industry-bi-prod".matvw_catalog_track
```

### JSON Extraction from Details
Parse JSON fields in subscription/settings data:
```sql
SELECT
    id,
    teamid,
    status,
    json_extract_scalar(details, '$.autoRenew') AS auto_renew,
    json_extract_scalar(details, '$.created') AS created_timestamp,
    FROM_UNIXTIME(TRY_CAST(json_extract_scalar(details, '$.periodStart') AS bigint) / 1000) AS period_start,
    FROM_UNIXTIME(TRY_CAST(json_extract_scalar(details, '$.expiresAt') AS bigint) / 1000) AS expires_at
FROM postgresql_core.public.subscriptions
```

### Array Operations
Common array functions used in queries:
```sql
-- Concatenate array to string
SELECT array_join(transform(artists, a -> a.name), ', ') AS artist_names

-- Filter array elements
SELECT filter(profiles, p -> p.profile_id = 'TARGET_ID') AS matching_profiles

-- Check if array contains value
SELECT cardinality(filter(profiles, p -> p.profile_id = 'TARGET_ID')) > 0 AS has_profile

-- Count array elements matching condition
SELECT cardinality(filter(catalog_credits, c -> c.parent = 'Songwriter')) AS songwriter_credits

-- Aggregate distinct values
SELECT array_agg(DISTINCT source) AS sources

-- Get first element
SELECT artists[1].name AS primary_artist
```

### Current Stats Snapshot
Get latest streaming stats:
```sql
WITH current_stats AS (
    SELECT
        track_id,
        streams
    FROM postgresql_industry.public.industry_data_processing_analytics_maintenance_daily_v2_track_stats_to_insert
)
SELECT
    t._id,
    t.title,
    s.streams
FROM hive."platform-industry-bi-prod".matvw_catalog_track AS t
LEFT JOIN current_stats AS s ON (s.track_id = t._id)
WHERE NOT t.is_deleted
```

### Combining Multiple CTEs (Full Example)
Common pattern for profile analysis with claiming, pro status, and stats:
```sql
WITH claimed AS (
    SELECT profileid AS profile_id, TRUE AS is_claimed
    FROM postgresql_core.public.claiming
    WHERE status = 'processed'
    GROUP BY 1
),
pro AS (
    SELECT seatid AS profile_id, TRUE AS is_pro
    FROM postgresql_core.public.roster_seats
    WHERE status = 'active'
    GROUP BY 1
),
profile_tracks AS (
    SELECT
        profile.profile_id,
        t._id AS track_id
    FROM hive."platform-industry-bi-prod".matvw_catalog_track AS t
    CROSS JOIN UNNEST(t.profiles) AS p(profile)
    WHERE NOT t.is_deleted
),
profile_stats AS (
    SELECT
        pt.profile_id,
        SUM(s.streams) AS total_streams
    FROM profile_tracks pt
    JOIN hive."platform-industry-bi-prod".matvw_stats_track_daily AS s ON (s.track_id = pt.track_id)
    WHERE s.date >= date_format(date_add('day', -365, current_date), '%Y-%m-%d')
    GROUP BY 1
)
SELECT
    p._id AS profile_id,
    p.name,
    p.popularity,
    COALESCE(cl.is_claimed, FALSE) AS is_claimed,
    COALESCE(pr.is_pro, FALSE) AS is_pro,
    COALESCE(ps.total_streams, 0) AS streams_last_year
FROM hive."platform-industry-bi-prod".matvw_catalog_profile AS p
LEFT JOIN claimed AS cl ON (cl.profile_id = p._id)
LEFT JOIN pro AS pr ON (pr.profile_id = p._id)
LEFT JOIN profile_stats AS ps ON (ps.profile_id = p._id)
WHERE NOT p.is_deleted
  AND p.popularity >= 50
ORDER BY p.popularity DESC
LIMIT 100
```

## Related Tables Quick Reference

| Domain | Tables |
|--------|--------|
| **Catalog** | matvw_catalog_track, matvw_catalog_profile, matvw_catalog_release, matvw_catalog_member |
| **Stats** | matvw_stats_track_daily, matvw_capture_spotify_stats, matvw_capture_youtube_stats |
| **MLC** | matvw_mlc_worksrecordings, matvw_mlc_workrightshares |
| **User** | matvw_muso_claiming, matvw_muso_lists, matvw_muso_roster_seats |
| **Raw** | matvw_raw_profile, matvw_raw_recording, matvw_raw_recording_credit |
| **Audit** | audit_profile, audit_track, audit_isrc (in audit-prod db) |
| **BI** | marketing_*, bi_reporting_weekly_* (in bi db) |
| **Platform Calc** | calcul_common.calc_analytics_history, calcul_common.calc_profile_track_credits |

## Platform Calculated Tables

These tables are computed by the platform team's Airflow/Spark pipelines and stored in the data lake.

### calcul_common Database

Tables computed early in the daily platform process for reuse in downstream calculations.

#### calc_analytics_history

**Critical for historical analytics queries.** Stores streaming history for key sources.

```sql
SELECT
    capture_date,              -- Partition key (date)
    source,                    -- 'spotify', 'shazam', 'soundcloud', 'youtube'
    track_id,                  -- Muso track ID
    streams,                   -- Stream count at capture time
    -- Additional source-specific fields
FROM calcul_common.calc_analytics_history
WHERE capture_date >= '2026-01-01'
  AND source = 'spotify'
```

**Coverage:**
- **Spotify**: ~4M records/day
- **SoundCloud**: ~260K records/day
- **YouTube**: ~500K records/day (streams only, not views)
- **Shazam**: ~100K records/day

**Data Source:** JSON files stored in S3 by capture service. Original files cleaned after 30 days, but these partitions retained forever.

#### calc_profile_track_credits

Profile ↔ Track relationship with credit details.

```sql
SELECT
    master_track_id,           -- NOTE: This is actually track_id (legacy naming)
    profile_id,
    recording_credit_ids       -- Additional credit metadata
FROM calcul_common.calc_profile_track_credits
```

### OLAP Cubes (Views)

OLAP cubes live in the **`postgresql_olap`** catalog (NOT `postgresql_analytics`). They are **rebuilt daily** by Spark — always query **views**, not the numbered shard tables.

| View | Dimensions |
|------|------------|
| `cube_analytics_album_view` | profile_id + album_id |
| `cube_analytics_collaborator_view` | profile_id + collaborator_id |
| `cube_analytics_track_view` | profile_id + track_id |

**Partition:** All cubes partitioned by period (`1d`, `1w`, `1m`, `3m`, `1y`, `all`, `ytd`)

**Why views?** Andre creates new tables daily (e.g., `cube_analytics_album_565`), adds indexes, then switches the view pointer. Querying the view abstracts this daily rotation.

## Legacy Naming Gotchas

### master_track_id = track_id

Anywhere you see `master_track_id` or `master_id` in older tables, it means `track_id`.

**History:** Original design anticipated merging tracks into "master tracks" with a separate deduplication layer. This was never implemented, but the naming persists in:
- `calc_profile_track_credits.master_track_id`
- Some legacy platform tables
- Older saved queries

**Always treat `master_track_id` as `track_id`.**
