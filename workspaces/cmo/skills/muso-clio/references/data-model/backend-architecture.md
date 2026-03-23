# Backend Architecture

Detailed view of Muso.AI's data infrastructure.

## Database Systems

### PostgreSQL RDS: core_backend

**Purpose**: User management, teams, subscriptions, roster
**Known As**: `platform_core_backend_export_prod`
**Owner**: Serhii (most familiar)
**Scale**: Medium

Key tables:
- `users` - User accounts (auth0_id, email, etc.)
- `profiles` - User profile settings, claimed status
- `teams` - Workspace/team entities
- `subscriptions` - Subscription records
- `roster_seats` - Team → Profile assignments
- `payments` - Payment history

### PostgreSQL RDS: analytics

**Purpose**: Capture service scheduling
**Scale**: Smallest database

Key tables:
- `capture_request` - 24hr TTL, prevents duplicate scrape requests
- Scheduling metadata

### Aurora PostgreSQL: platform_stats

**Purpose**: Analytics aggregations
**Scale**: MASSIVE (~1 billion ops/day, years of historical data)

Key tables:
- `track_daily` - **SOURCE OF TRUTH** for all analytics
  - Granularity: `(date, track_id)`
  - Columns: streams, shazams, views, videos, spotify_streams, youtube_streams, soundcloud_streams, etc.
- `profile_track` - Dimension table linking profiles to tracks
- `album_track` - Dimension table linking albums to tracks
- `analytics_link` - Maps external source IDs (Spotify, YouTube, Shazam) to Muso track_id
  - Handles duplicate detection and merging
- `analytics_video` - YouTube/TikTok/Instagram video-specific data
  - Links to analytics_link via `link_id`

---

## MongoDB Atlas

### platform_industry_DB_industry_prod

**Purpose**: Primary catalog database
**Update Pattern**: Weekly full snapshot + daily deltas

#### Collection Prefixes

| Prefix | Purpose |
|--------|---------|
| `raw_*` | External data stored as-is from source |
| `dict_*` | Dictionaries and mappings |
| `catalog_*` | Muso's merged/unified entities |

#### Main Catalog Collections

| Collection | Entity | Notes |
|------------|--------|-------|
| `catalog_profile` | Profile | 4M+ music professionals |
| `catalog_track` | Track | Central entity - credits nested inside |
| `catalog_release` | Album | Releases |
| `catalog_artist` | Artist | Spotify artists |

#### Relationship Collections

| Collection | Relationship |
|------------|--------------|
| `catalog_recording_credit` | Track ↔ Profile |
| `catalog_release_credit` | Album ↔ Profile |

#### Key Design Decision: Credits Inside Tracks

Credits are stored **inside** `catalog_track.profiles` array rather than in a separate join table. This denormalization improves query efficiency for the most common access pattern (getting a track with its credits).

```javascript
// catalog_track document structure
{
  "_id": "track-uuid",
  "name": "Song Title",
  "spotify_id": "spotify:track:abc123",
  "isrc": "USRC12345678",
  "raw_recording_ids": ["raw_spotify_123", "raw_jaxsta_456"],  // Links to raw sources
  "profiles": [
    {
      "profile_id": "profile-uuid",
      "catalog_credits": [
        { "category": "Producer", "credit": "Executive Producer" },
        { "category": "Songwriter", "credit": "Composer" }
      ],
      "added_by": "jaxsta"
    }
  ]
}
```

### platform_industry_BI_prod

**Purpose**: Pre-aggregated BI data
**Update Pattern**: Weekly snapshots

Used for analytics dashboards and reporting that don't need real-time data.

---

## Capture Service Architecture

### Components

| Component | Purpose |
|-----------|---------|
| `interface` | Receives all tasks, routes to source-specific queues |
| `scheduler` | Schedules capture jobs |
| `worker` (per-source) | High/medium priority queues per source |

### Queue Structure

```
interface_queue
    │
    ├─► spotify_high_queue ──► spotify_worker
    ├─► spotify_medium_queue ──► spotify_worker
    ├─► youtube_high_queue ──► youtube_worker
    ├─► youtube_medium_queue ──► youtube_worker
    └─► ... (per source)
```

### Infrastructure

- ~5000 proxies for scraping
- Kubernetes-based workers
- 5 retries by default
- No dead letter queues (SLAs ensure eventual retry)
- Blocking happens daily (normal operation)

---

## Data Flow: Capture → Catalog → Analytics

```
1. External Source (Spotify, YouTube, etc.)
   │
   ▼
2. Capture Service
   - Interface receives request
   - Routes to source-specific worker
   - Worker scrapes via proxies
   │
   ▼
3. MongoDB raw_* tables
   - Data stored as-is from source
   - raw_recording_ids link raw → catalog
   │
   ▼
4. Catalog Processing (triggered)
   - Merges raw entities into catalog_* entities
   - Deduplication, linking
   - Credits nested into catalog_track
   │
   ▼
5. MongoDB catalog_* tables
   - Unified entities with relationships
   │
   ▼
6. Analytics Processing
   - Extracts stats from catalog
   - Links via analytics_link
   │
   ▼
7. Aurora track_daily
   - Aggregated daily stats
   - Source of truth for all analytics
   │
   ▼
8. S3 Data Lake
   - Historical archives
   - Athena queryable
```

---

## Query Paths by Use Case

### "Get profile with credits"
```
catalog_profile → catalog_track (filter by profiles.profile_id) → join catalog_release
```

### "Get track analytics"
```
track_daily (filter by track_id, date range) → GROUP BY as needed
```

### "Export profile credits with streams"
```
catalog_profile 
  → catalog_track (profiles.profile_id match)
  → JOIN track_daily ON track_id
  → Aggregate streams
```

### "Search profiles"
```
Elasticsearch profiles index → catalog_profile for details
```

### "Marketing analytics"
```
Athena (growth_dev workgroup) → S3 data lake
```

---

## Athena / S3 Data Lake

### Workgroups

| Workgroup | Purpose | Query Count |
|-----------|---------|-------------|
| `primary` | Main queries | ~256 saved queries (4 years) |
| `growth_dev` | Marketing analytics | New workgroup |

### Access Pattern

```sql
-- Example Athena query
SELECT 
  date,
  SUM(streams) as total_streams
FROM track_daily
WHERE track_id IN (SELECT track_id FROM profile_tracks WHERE profile_id = 'xxx')
  AND date >= DATE_ADD('day', -28, CURRENT_DATE)
GROUP BY date
ORDER BY date
```

---

## Connection Info (How to Retrieve)

**DO NOT store credentials in this document.**

See `../ops/data-access.md` for:
- Environment variable naming conventions
- How to retrieve secrets from SSM/Secrets Manager
- Read-only role setup
