# Muso.AI Trino Query Writer

Write correct, efficient Trino SQL queries against Muso.AI's OVH data platform.

**Migration note (2026-04-25):** AWS Athena was retired on 2026-04-25. All historical data, materialized views, and audit tables now live in Trino on OVH (HMS + Hive on OVH S3 IO). SQL syntax is largely identical (Trino is the engine Athena v3 was based on). The main changes are catalog names and how you execute queries.

## Quick Reference

### Athena DB → Trino catalog.schema mapping

| Old Athena DB (Muso-internal name) | New Trino reference | Backed by |
|---------------|---------------------|-----------|
| platform-industry-bi-prod | `hive."platform-industry-bi-prod"` | OVH S3 IO + HMS (matvw_*) |
| platform-core-backend-export-prod | `postgresql_core.public` | OVH PG node-18 (live, no export delay) |
| audit-prod | `hive.audit` | OVH S3 IO + HMS |
| bi | `postgresql_analytics.public` | OVH PG node-18 |
| platform-industry-mlc-bi-prod | `hive.mlc` | OVH S3 IO + HMS |
| platform-data-merging-catalog-prod | `postgresql_industry.public` | OVH PG (live) |
| Aurora platform-stats | `postgresql_stats.public` | OVH PG node-18 |
| Aurora platform-core-backend | `postgresql_core.public` | OVH PG (same as above) |
| Aurora platform-industry-calculations | `postgresql_industry.public` | OVH PG node-18 |
| Aurora platform-industry-olap | `postgresql_olap.public` | OVH PG node-18 |

### Available catalogs
```
hive                  — historical materialized views (matvw_*) on OVH S3 IO
postgresql_core       — core_backend (users, teams, subs, profiles)
postgresql_stats      — analytics_link_*, analytics_video_*
postgresql_analytics  — bi/marketing
postgresql_industry   — industry calculations
postgresql_olap       — olap aggregates
postgresql_catalog    — catalog DB
postgresql_feed       — feed service DB
system, tpcds, tpch   — built-in
```

### Table Naming Convention
- Tables in `hive."platform-industry-bi-prod"` keep the `matvw_` prefix (materialized views from S3/parquet)
- Tables in `postgresql_*` use schema `public` (e.g. `postgresql_core.public.users`)
- Quote catalog/schema/table names if they contain hyphens (rare in Trino — most catalogs are underscore-separated)

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
```sql
SELECT
    _id,                        -- Profile ID (string)
    name,                       -- Display name
    first_name, last_name,      -- Name parts
    legal_name,                 -- Legal/real name
    known_as_names,             -- array<string> of aliases
    profile_type,               -- 'person', 'band', 'organization'
    profile_sub_type,           -- More specific type
    roles,                      -- array<string> of roles
    child_roles,                -- array<struct> with detailed role breakdown
    common_credits,             -- array<string> of common credits
    credits_count,              -- Total credits
    credits_count_1y,           -- Credits in last year
    collaborations_count,       -- Number of collaborators
    top_collaborators,          -- array<struct> with id, name
    popularity, rank,           -- Scoring
    genres,                     -- array<struct> with genre counts
    primary_genre,              -- Main genre
    decades,                    -- array<struct> of active decades
    country, state, city,       -- Location
    ipis,                       -- array<bigint> of IPI numbers
    images,                     -- Profile images
    about,                      -- Bio text
    years_active,               -- Years in industry
    is_deleted                  -- Soft delete flag
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE is_deleted = false
```

### matvw_stats_track_daily (3.3B rows, partitioned by date)
```sql
SELECT
    track_id,                   -- Links to catalog_track._id
    date,                       -- Date string 'YYYY-MM-DD' (partition key)

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
    streams,
    shazams,
    views,
    videos
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= '2026-01-01'  -- ALWAYS filter on date partition
```

### postgresql_core.public.users (live PG, no export delay)
```sql
SELECT
    id,
    email,
    firstname, lastname, fullname,
    createdat,
    lastactivetime,
    defaultteamid,
    stripecustomerid,
    auth0userid,
    isadmin,
    emailconfirmed,
    referralcode,
    referredbyuserid
FROM postgresql_core.public.users
```

### postgresql_core.public.teams
```sql
SELECT
    id,
    name,
    email,
    createdat,
    stripecustomerid,
    isdefault,
    inhouseanalyticsenabled
FROM postgresql_core.public.teams
```

### postgresql_core.public.subscriptions
```sql
SELECT
    id, userid, teamid,
    service,
    status,
    plan,
    profileseatslimit,
    organizationseatslimit,
    userslimit,
    externalsubid,
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

### Active subscribers by plan (LIVE — postgres connector)
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

### Trino cost model (vs Athena)

Trino on OVH does **not charge per-TB scanned** like Athena did. But query efficiency still matters because:
- Coordinator memory is bounded (large unfiltered queries OOM the coordinator)
- Worker memory + spill-to-disk has limits
- Concurrent queries share cluster resources
- The HMS/Hive scan still does I/O against OVH S3 IO (slow if no partition pruning)

### Table sizes (unchanged from Athena era)

| Table | Rows | Approx size |
|-------|------|-------------|
| `hive."platform-industry-bi-prod".matvw_stats_track_daily` | **3.3 BILLION** | ~95 GB |
| `hive."platform-industry-bi-prod".matvw_capture_spotify_stats` | **753 MILLION** | ~217 GB |
| `hive."platform-industry-bi-prod".matvw_catalog_track` | 190 million | ~107 GB |
| `hive."platform-industry-bi-prod".matvw_mlc_worksrecordings` | 298 million | ~4 GB |
| `hive."platform-industry-bi-prod".matvw_catalog_profile` | 29 million | ~2 GB |
| `postgresql_core.public.users` | 339K | ~58 MB |
| `postgresql_core.public.subscriptions` | 60K | ~7 MB |

### Development Query Rules

```sql
-- 1. ALWAYS use LIMIT when exploring
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track
LIMIT 100;

-- 2. Test JOINs on small subsets first
WITH sample_tracks AS (
    SELECT _id FROM hive."platform-industry-bi-prod".matvw_catalog_track
    LIMIT 1000
)
SELECT s.*
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN sample_tracks t ON s.track_id = t._id
LIMIT 100;

-- 3. Use date filters on stats tables IMMEDIATELY
SELECT * FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= '2026-04-01'
  AND date <= '2026-04-07'
LIMIT 100;

-- 4. Check row counts before full queries
SELECT COUNT(*) FROM hive."platform-industry-bi-prod".matvw_catalog_track
WHERE lower(title) LIKE '%beatles%';
```

### Dangerous Patterns to Avoid

```sql
-- BAD: Full table scan on 3.3B rows
SELECT SUM(streams) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily;

-- GOOD: Filter by date range
SELECT SUM(streams) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= '2026-04-01' AND date < '2026-05-01';

-- BAD: Cross join without limits during development
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile);

-- GOOD: Add LIMIT while developing
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
LIMIT 100;

-- BAD: JOIN two massive tables without filters
SELECT * FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN hive."platform-industry-bi-prod".matvw_catalog_track t ON s.track_id = t._id;

-- GOOD: Filter both sides first
SELECT * FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN hive."platform-industry-bi-prod".matvw_catalog_track t ON s.track_id = t._id
WHERE s.date >= date_format(date_add('day', -7, current_date), '%Y-%m-%d')
  AND t.popularity > 90
LIMIT 100;
```

### Partitioned Tables (Hive)
These tables have `date` partitions — **always filter on date**:
- `hive."platform-industry-bi-prod".matvw_stats_track_daily`
- `hive."platform-industry-bi-prod".matvw_capture_spotify_stats`
- `hive."platform-industry-bi-prod".matvw_capture_*`

```sql
WHERE date >= '2026-04-01' AND date < '2026-05-01'
```

### Performance Checklist
- [ ] Using `LIMIT` if developing/exploring
- [ ] Date filters on time-series tables (use partition column `date`)
- [ ] `is_deleted = false` on catalog tables
- [ ] Selecting only needed columns
- [ ] JOINs have appropriate filters on both sides
- [ ] No accidental cross joins on large tables
- [ ] Filter stats CTE *before* joining to profiles
- [ ] Using `approx_distinct()` instead of `COUNT(DISTINCT)` on huge tables
- [ ] IDs are quoted (UUIDs are strings, not integers)

## Gold Rules

### 1. Filter-Before-Join
```sql
-- BAD
SELECT p.name, SUM(s.streams)
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily s
JOIN hive."platform-industry-bi-prod".matvw_catalog_track t ON s.track_id = t._id
CROSS JOIN UNNEST(t.profiles) AS pr(profile)
JOIN hive."platform-industry-bi-prod".matvw_catalog_profile p ON p._id = profile.profile_id
WHERE p._id = 'TARGET_PROFILE_ID'
GROUP BY 1;

-- GOOD
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

### 2. Filter Before Unnesting
```sql
-- GOOD
SELECT t._id, t.title, profile.profile_id, credit.child AS role
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
CROSS JOIN UNNEST(t.profiles) AS p(profile)
CROSS JOIN UNNEST(profile.catalog_credits) AS c(credit)
WHERE contains(transform(t.profiles, x -> x.profile_id), 'TARGET_ID')
  AND profile.profile_id = 'TARGET_ID'
  AND NOT t.is_deleted;
```

### 3. Never Join on String Names
```sql
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
```sql
SELECT COUNT(*) * 1000 AS estimated_count, AVG(streams)
FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
TABLESAMPLE BERNOULLI (0.1);
```

### 5. Use approx_distinct() for Unique Counts
```sql
SELECT approx_distinct(track_id) FROM hive."platform-industry-bi-prod".matvw_stats_track_daily
WHERE date >= date_format(date_add('day', -30, current_date), '%Y-%m-%d');
```

## Data Cleaning Helpers

### ISRC Normalization
```sql
SELECT UPPER(REPLACE(isrc, '-', '')) AS normalized_isrc

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
```sql
SELECT CAST(CAST(ipi AS BIGINT) AS VARCHAR) AS normalized_ipi
SELECT LPAD(CAST(ipi AS VARCHAR), 11, '0') AS padded_ipi
```

## Terminology Clarification

| Term | Table | Meaning |
|------|-------|---------|
| **User** | `postgresql_core.public.users` | Person using the Muso.AI app (has email, login) |
| **Profile** | `hive."platform-industry-bi-prod".matvw_catalog_profile` | Music industry entity (artist, producer, label) |
| **Claimed Profile** | `postgresql_core.public.claiming` | Profile verified/owned by a User |
| **Pro Profile** | `postgresql_core.public.roster_seats` | Profile with active paid subscription |
| **Team/Workspace** | `postgresql_core.public.teams` | Organization unit for billing and collaboration |

**Common confusion:** "Get all users" usually means `postgresql_core.public.users`. "Get all artists" means `hive."platform-industry-bi-prod".matvw_catalog_profile WHERE profile_type = 'artist'`.

## Query Execution

### Quickest path: trino-query.sh wrapper

We ship a wrapper script that auto-rewrites old Athena DB names → Trino catalog.schema. Use it the same way you used `# RETIRED 2026-04-25 — use bash /opt/hydra/scripts/trino-query.sh "<SQL>" instead
# (legacy: aws athena start-query-execution)`:

```bash
# From node-8 (HYDRA host) — wrapper handles kubectl exec into trino-coordinator
bash /opt/hydra/scripts/trino-query.sh "SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_profile WHERE _id = 'X' LIMIT 10"

# Old Athena queries still work — wrapper rewrites the DB names
bash /opt/hydra/scripts/trino-query.sh 'SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track LIMIT 1'
# ↑ rewritten internally to: SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track LIMIT 1

# Output is CSV (matches Athena get-query-results format)
```

### Direct Trino CLI (if shell access)

```bash
kubectl exec -n data-processing trino-coordinator-0 -- trino \
  --catalog hive --schema default \
  --execute "SELECT count(*) FROM matvw_catalog_track WHERE is_deleted=false"
```

### From Python (analytics-worker, scripts)

```python
from trino.dbapi import connect

conn = connect(
    host='trino.data-processing.svc.cluster.local',
    port=8080,
    user='hydra',
    catalog='hive',
    schema='default',
)
cur = conn.cursor()
cur.execute("SELECT count(*) FROM matvw_catalog_track WHERE is_deleted=false")
rows = cur.fetchall()
```

### HTTP API (for curl/JS)

```bash
curl -X POST -H 'X-Trino-User: hydra' -H 'X-Trino-Catalog: hive' \
  -H 'X-Trino-Schema: default' \
  --data 'SELECT count(*) FROM matvw_catalog_track WHERE is_deleted=false' \
  http://trino.data-processing.svc.cluster.local:8080/v1/statement
```

### Discovery commands

```bash
# List all catalogs
trino-query.sh "SHOW CATALOGS"

# List schemas in hive (formerly Glue databases)
trino-query.sh "SHOW SCHEMAS FROM hive"

# List tables in hive."platform-industry-bi-prod"
trino-query.sh "SHOW TABLES FROM hive."platform-industry-bi-prod""

# Describe a table
trino-query.sh "DESCRIBE hive."platform-industry-bi-prod".matvw_catalog_profile"
```

### What changed from Athena CLI?
- ❌ `# RETIRED 2026-04-25 — use bash /opt/hydra/scripts/trino-query.sh "<SQL>" instead
# (legacy: aws athena start-query-execution) --workgroup primary `
- ✅ `trino-query.sh` (no profile, no region, no workgroup)
- ❌ `aws athena get-query-execution --query-execution-id <ID>` (poll for results)
- ✅ Trino CLI/HTTP returns synchronously (no polling needed for sub-1min queries)
- ❌ Workgroups (`primary`, `data-engineering`, `growth-dev`)
- ✅ Single Trino cluster, no workgroups
- ❌ AWS profile / region
- ✅ `kubectl` context (auto-detected on node-8)

## Reusable CTEs & Patterns

### Claimed Profiles CTE
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
```sql
SELECT
    _id AS profile_id,
    split_part(rid, ':', 2) AS spotify_id
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
CROSS JOIN UNNEST(raw_profile_ids) AS r(rid)
WHERE NOT is_deleted
  AND rid LIKE 'spotify:%'

SELECT
    _id AS profile_id,
    rid AS raw_profile_id,
    split_part(rid, ':', 1) AS source
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
CROSS JOIN UNNEST(raw_profile_ids) AS r(rid)
WHERE NOT is_deleted
```

### Track Credits Unnest
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

### MLC IPI Profile Lookup
```sql
SELECT
    _id,
    name,
    is_deleted,
    m.*
FROM hive."platform-industry-bi-prod".matvw_catalog_profile AS p
CROSS JOIN UNNEST(raw_profile_ids) AS pr(rid)
RIGHT JOIN (
    SELECT
        'mlc:' || CAST(feedproviderspartyid AS VARCHAR) AS rid,
        ipinamenumber,
        fullname
    FROM hive."platform-industry-mlc-bi-prod".parties
    WHERE ipinamenumber IN (
        1026291486
    )
) AS m USING(rid)
ORDER BY is_deleted, ipinamenumber, _id
```

### Company Roster via Members
```sql
WITH company_roster AS (
    SELECT DISTINCT
        profile_id AS company_id,
        member_id AS profile_id,
        membership_type
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
```sql
SELECT
    _id,
    title,
    DATE(FROM_UNIXTIME(release_timestamp / 1000)) AS release_date,
    YEAR(FROM_UNIXTIME(release_timestamp / 1000)) AS release_year
FROM hive."platform-industry-bi-prod".matvw_catalog_track

WHERE FROM_UNIXTIME(release_timestamp / 1000) >= DATE_TRUNC('year', current_date)

SELECT
    _id,
    title,
    YEAR(CURRENT_DATE) - YEAR(FROM_UNIXTIME(release_timestamp / 1000)) AS years_since_release
FROM hive."platform-industry-bi-prod".matvw_catalog_track
```

### JSON Extraction from Details
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
```sql
SELECT array_join(transform(artists, a -> a.name), ', ') AS artist_names
SELECT filter(profiles, p -> p.profile_id = 'TARGET_ID') AS matching_profiles
SELECT cardinality(filter(profiles, p -> p.profile_id = 'TARGET_ID')) > 0 AS has_profile
SELECT cardinality(filter(catalog_credits, c -> c.parent = 'Songwriter')) AS songwriter_credits
SELECT array_agg(DISTINCT source) AS sources
SELECT artists[1].name AS primary_artist
```

### Combining Multiple CTEs (Full Example)
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
| **Catalog** | hive."platform-industry-bi-prod".matvw_catalog_track, matvw_catalog_profile, matvw_catalog_release, matvw_catalog_member |
| **Stats** | hive."platform-industry-bi-prod".matvw_stats_track_daily, matvw_capture_spotify_stats, matvw_capture_youtube_stats |
| **MLC** | hive."platform-industry-bi-prod".matvw_mlc_worksrecordings, matvw_mlc_workrightshares (or hive."platform-industry-mlc-bi-prod".* for raw) |
| **User** | hive."platform-industry-bi-prod".matvw_muso_claiming, matvw_muso_lists, matvw_muso_roster_seats |
| **Live PG users/teams** | postgresql_core.public.users, teams, subscriptions, claiming, roster_seats |
| **Raw** | hive."platform-industry-bi-prod".matvw_raw_profile, matvw_raw_recording, matvw_raw_recording_credit |
| **Audit** | hive.audit.audit_profile, audit_track, audit_isrc |
| **BI** | postgresql_analytics.public.marketing_*, bi_reporting_weekly_* |
