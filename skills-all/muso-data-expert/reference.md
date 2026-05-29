# Muso Data Expert Reference

## Overview

The **muso-data-expert** skill provides comprehensive knowledge of Muso.AI's data architecture, including database schemas, data pipelines, entity relationships, and data flow patterns. Use this skill when working with Muso's data infrastructure, writing queries, understanding data lineage, or troubleshooting data-related issues.

## Key Concepts

**Catalog Entity**: A unified representation of music industry data (tracks, profiles, releases) aggregated from multiple raw data sources. Catalog entities are the canonical version of data exposed to users.[^1]

**Raw Entity**: Platform-specific data captured directly from external sources (Spotify, Tidal, etc.) before aggregation. Multiple raw entities can map to a single catalog entity.[^2]

**Analytics Link**: A connection between an external platform ID and a Muso track ID, used to associate streaming statistics with catalog tracks.[^3]

**Capture Request**: A database record tracking the need to fetch data for entities not currently in the Muso system, with a 24-hour TTL to prevent duplicate requests.[^4]

**Industry Database (Industry DB)**: The primary PostgreSQL database storing catalog entities, raw entities, credits, and relationships between music industry data.[^5]

**Stats DB**: An Aurora PostgreSQL database containing pre-aggregated analytics data including daily track statistics, analytics links, and video data.[^6]

**Data Lake**: S3-based storage containing raw data dumps and snapshots from various databases, queryable via Trino for analytics and exploration (AWS Athena retired 2026-04-25).[^7]

**ISRC (International Standard Recording Code)**: A key identifier for catalog tracks used to link recordings across different platforms.[^8]

## Architecture

### Team Structure

Muso.AI's engineering organization consists of three teams:[^9]

- **Growth Team**: Focuses on user-facing features, client-side interactions, public APIs, and revenue generation. Owns user credentials, payments, and subscription data.
- **Catalog Team**: Handles data capture, processing, and storage of music industry information. Manages the Industry DB and data quality.
- **Platform Team**: Provides infrastructure services to both Growth and Catalog teams, including data pipelines, pre-aggregation, and shared services.

### Database Architecture

```text
Primary Databases
  - Industry DB (PostgreSQL RDS)
  - Core Backend DB (PostgreSQL RDS)
  - Stats DB (Aurora PostgreSQL)
  - Feed Service DB (PostgreSQL RDS)
  - Industry Calculations DB (PostgreSQL RDS)

Processing
  Capture Services       --> Industry DB (raw data)
  Industry Processing    --> Industry DB (processed data)
  Airflow Pipelines (88) --> Stats DB (pre-aggregation)

Data Lake
  Industry DB --> S3 (daily snapshots)
  Core DB     --> S3 (daily snapshots)
  Stats DB    --> S3 (full snapshot)
  S3          --> Trino (query, OVH — Athena retired 2026-04-25)
```

### Key Database Instances

**Industry DB (PostgreSQL RDS)**[^5]
- Stores catalog entities (tracks, profiles, releases)
- Contains raw entities from external platforms
- Manages credits, collaborations, and relationships
- Includes dictionary tables for credit ID mapping
- Tracks operations history from Retool admin actions

**Core Backend Database (PostgreSQL RDS)**[^10]
- Stores user accounts, authentication, and credentials
- Manages payment and subscription information
- Contains team and roster data
- Owned by Growth team

**Stats DB (Aurora PostgreSQL)**[^6]
- Contains `public.track_daily` table with daily analytics (streams, views, Shazam counts)
- Stores `analytics_link` table connecting external platform IDs to Muso track IDs
- Includes `analytics_video` table for YouTube, TikTok, and Instagram video data
- Contains dimension tables (`profile_track`, `album_track`) for statistical joins
- Receives pre-computed data from Platform team's Airflow pipelines

**Feed Service Database (PostgreSQL RDS)**[^11]
- Manages user activity feeds
- Contains `activity`, `feed`, `reaction`, and `follow` tables
- Only `follow` table currently snapshotted to data lake

**Industry Calculations Database (PostgreSQL RDS)**[^12]
- Stores computed metrics and milestones
- Currently only `milestones` table is snapshotted

### Data Flow Architecture

```text
Data Capture
  Capture Scheduler --> Capture Interface (SQS queue) --> Analytics Worker

Storage + Processing
  Analytics Worker --> Raw Entities --> triggers --> Industry Processing --> Catalog Entities
  Industry Processing --> (missing data) --> Capture Interface (SQS queue)
  Platform Pipelines --> (pre-aggregated) --> Stats DB
```

## Entity Reference

### Catalog Entities

#### Catalog Track

**Primary Identifier**: `track_id` (internal Muso ID)

**Key Attributes**:[^8]
- `isrc`: International Standard Recording Code
- `title`: Track name
- `duration`: Track length
- `release_date`: Original release date
- `explicit`: Content rating flag

**Relationships**:
- One-to-many with Raw Recording entities[^13]
- Many-to-many with Catalog Profile (via recording credits)[^14]
- Many-to-one with Catalog Release
- One-to-many with Analytics Links[^3]

**Data Sources**: Aggregated from Spotify, Tidal, Deezer, and other platform raw recordings[^2]

#### Catalog Profile

**Primary Identifier**: `profile_id` (internal Muso ID)

**Key Attributes**:
- `name`: Artist/contributor name
- `verified`: Verification status
- `profile_type`: Artist, producer, songwriter, etc.

**Relationships**:
- Many-to-many with Catalog Track (via recording credits)[^14]
- Many-to-many with Catalog Release (via release credits)[^15]
- One-to-many with Raw Profile entities[^16]

**Merge Behavior**: When profiles are merged, raw IDs transfer to the target profile[^17]

#### Catalog Release

**Primary Identifier**: `release_id` (internal Muso ID)

**Key Attributes**:
- `title`: Album/EP/Single name
- `release_date`: Publication date
- `release_type`: Album, EP, Single, etc.
- `label`: Record label

**Relationships**:
- One-to-many with Catalog Track
- Many-to-many with Catalog Profile (via release credits)[^15]

### Raw Entities

#### Raw Recording

**Purpose**: Platform-specific track data before aggregation

**Key Attributes**:
- `source`: Platform identifier (spotify, tidal, deezer, etc.)
- `external_id`: Platform's native track ID
- `last_captured`: Timestamp of last data refresh

**Refresh Trigger**: When a raw entity is refreshed, it triggers a catalog entity refresh that collects and sorts information from all linked raw entities[^18]

#### Raw Profile

**Purpose**: Platform-specific artist/contributor data

**Synchronization**: Raw profiles are synchronized to create a single catalog profile[^16]

### Analytics Entities

#### Analytics Link

**Purpose**: Connects external platform IDs to Muso track IDs with associated statistics[^3]

**Schema**:
- `link_id`: Internal identifier
- `track_id`: Muso catalog track ID
- `source`: Platform name
- `external_id`: Platform's track/video ID
- `stats`: Aggregated statistics object

**Duplicate Handling**: The system detects and merges duplicate external IDs that report the same statistics to prevent stream duplication, particularly common between Spotify and Shazam[^19]

#### Analytics Video

**Purpose**: Video-specific analytics for YouTube, TikTok, and Instagram[^20]

**Schema**:
- `video_id`: Internal identifier
- `link_id`: Reference to analytics_link (the music itself)
- `platform`: youtube, tiktok, instagram
- `video_url`: External video URL
- `views`: View count
- `metadata`: Platform-specific video details

#### Track Daily Stats

**Location**: `public.track_daily` table in Stats DB[^21]

**Granularity**: Date + Track ID[^22]

**Metrics**:[^23]
- Streams (by source)
- Views (by source)
- Shazam counts
- Platform-specific breakdowns

### Dictionary Tables

**Purpose**: Map external source credit IDs to Muso's internal credit identification system[^24]

**Naming Convention**: Tables with `dict_` prefix

**Credit System**: Muso uses a parent-child-instrument hierarchy to simplify credit tracking across different external sources[^25]

**Example**: Spotify's "Producer" role maps to Muso's standardized "Producer" credit type

### Operations History

**Purpose**: Track administrative actions performed in Retool[^26]

**Schema**:
- `operation_id`: Unique operation identifier
- `user_id`: Admin who performed action
- `action_type`: merge, unmerge, update, etc.
- `entity_type`: profile, track, release
- `entity_id`: Affected entity
- `timestamp`: When action occurred
- `details`: JSON payload with operation specifics

## Data Pipeline Patterns

### Capture and Processing Flow

**1. Scheduled Capture**[^27]

Capture Scheduler determines which entities to capture based on:
- Priority level (user-requested > system-scheduled)
- Last capture timestamp
- Data staleness thresholds

**2. On-Demand Capture**[^28]

External requests can trigger capture from:
- Industry Processing (recursive data needs)
- Platform services (user-initiated refreshes)
- Retool (admin-initiated updates)

**3. Recursive Data Capture**[^29]

When Industry Processing identifies missing entity details:
1. Sends capture request to Capture Interface Service
2. Request queued in SQS with priority
3. Analytics Worker fetches data from external platform
4. Raw data stored in Industry DB
5. Industry Processing aggregates into catalog entity
6. If still incomplete, process repeats for related entities

**TTL Protection**: Capture requests have 24-hour TTL to prevent infinite loops[^4]

**4. Data Aggregation**[^18]

When raw entity refreshes:
1. Trigger catalog entity refresh
2. Collect data from all linked raw entities
3. Sort and merge information using priority rules
4. Update catalog entity with aggregated result
5. Propagate changes to dependent systems

### Pre-Aggregation Pipeline

**Airflow Management**: 88 active data pipelines managed by Andre[^30]

**Stats DB Population**:[^31]
1. Raw analytics data captured daily
2. Platform pipelines aggregate by track and date
3. Pre-computed results inserted into Aurora Stats DB
4. Growth team queries pre-aggregated tables for fast response

**Use Case Example**: Sorting tracks by stream count uses pre-aggregated Aurora tables rather than querying raw data[^32]

### Data Lake Snapshots

**Update Frequency**: Most data sources updated daily[^33]

**Snapshot Types**:
- **Full Snapshots**: Complete database dumps (Stats DB, Feed follow table)
- **Delta Snapshots**: Incremental changes (Core Backend exports)
- **Weekly Dumps**: Large dataset exports to S3[^34]

**Trino Access**: Raw data stored in OVH S3 is queryable via Trino — `bash /opt/hydra/scripts/trino-query.sh "<SQL>"` — for statistical analysis (AWS Athena was retired 2026-04-25)[^35]

## Service Integration

### Capture Services

**Components**:[^36]

1. **Capture Scheduler Service**
   - Determines capture priority and timing
   - Manages capture queue
   - Database: Analytics dev/prod RDS instance[^37]

2. **Capture Interface Service**
   - Handles external requests via SQS
   - Routes tasks to workers based on priority[^38]
   - Manages 24-hour TTL for capture requests

3. **Analytics Worker**
   - Executes capture jobs (catalog + analytics)
   - Uses proxy rotation for external requests[^39]
   - Stores results in Industry DB

**Job Types**:[^40]
- **Catalog Jobs**: Gather entity information (tracks, profiles, releases)
- **Analytics Jobs**: Fetch statistics (streams, views, Shazam counts)

### Industry Services

**Industry API**[^41]
- Separate repository from Feed API
- Provides read access to catalog entities
- Queried by Core Backend API for real-time data[^42]

**Industry Data Processing**[^43]
- Contains Industry API and data processing workers
- Aggregates raw entities into catalog entities
- Triggers recursive capture for missing data
- Performs data quality checks

### Platform Services

**Core Backend API**[^44]
- Manages user authentication and authorization
- Handles payment and subscription logic
- Queries Industry API for music data
- Exports data to S3 (weekly dumps + deltas)[^34]

**Feed Service**[^11]
- Manages user activity streams
- Tracks follows, reactions, and interactions
- Separate database from core backend

### Management Services

**Retool**[^45]
- Used by operations team for custom data changes
- Provides super admin update capabilities
- Tracks all operations in history tables[^26]
- Handles manual profile merging/un-merging[^46]

**Approval Workflow**:[^47]
- Automatic approval uses heuristics (credit risk, collaboration risk, track risk)
- High-risk changes require operations team approval via Retool
- Claiming and credits management follow this pattern

## Query Patterns

### Joining Catalog and Analytics Data

```sql
-- Get track stats with catalog information
SELECT 
    ct.track_id,
    ct.title,
    ct.isrc,
    tds.date,
    tds.streams,
    tds.views
FROM catalog_track ct
JOIN analytics_link al ON ct.track_id = al.track_id
JOIN track_daily_stats tds ON al.link_id = tds.link_id
WHERE tds.date >= '2024-01-01'
```

### Profile Aggregation Query

```sql
-- Get all raw profiles for a catalog profile
SELECT 
    cp.profile_id,
    cp.name AS catalog_name,
    rp.source,
    rp.external_id,
    rp.name AS raw_name,
    rp.last_captured
FROM catalog_profile cp
JOIN raw_profile rp ON cp.profile_id = rp.catalog_profile_id
WHERE cp.profile_id = ?
```

### Video Analytics with Track Context

```sql
-- Get video performance for a track
SELECT 
    ct.title,
    av.platform,
    av.video_url,
    av.views,
    al.external_id AS music_id
FROM catalog_track ct
JOIN analytics_link al ON ct.track_id = al.track_id
JOIN analytics_video av ON al.link_id = av.link_id
WHERE av.platform IN ('youtube', 'tiktok', 'instagram')
ORDER BY av.views DESC
```

## Configuration Reference

### Database Instances

| Instance | Type | Purpose | Team Owner |
|----------|------|---------|------------|
| Industry DB | PostgreSQL RDS | Catalog entities, raw data | Catalog |
| Core Backend DB | PostgreSQL RDS | Users, payments, subscriptions | Growth |
| Stats DB | Aurora PostgreSQL | Pre-aggregated analytics | Platform |
| Feed Service DB | PostgreSQL RDS | Activity feeds, follows | Growth |
| Industry Calculations DB | PostgreSQL RDS | Computed metrics, milestones | Platform |
| Analytics Dev/Prod DB | PostgreSQL RDS | Capture scheduling | Catalog |

### Data Refresh Intervals

| Data Type | Refresh Frequency | Notes |
|-----------|------------------|-------|
| Analytics Stats | Daily | Most sources updated daily[^33] |
| Catalog Entities | On-demand + scheduled | Priority-based capture |
| Database Snapshots | Daily | Full and delta snapshots |
| S3 Exports | Weekly + daily deltas | Core backend exports[^34] |

### System Limits

| Resource | Limit | Source |
|----------|-------|--------|
| Capture Request TTL | 24 hours | Prevents duplicate requests[^4] |
| Active Airflow DAGs | 88 pipelines | Production cluster[^30] |
| Customer API Users | 200+ | Mostly free tier[^48] |
| Stats DB Scale | Billions of rows | High daily operations[^49] |

## Known Gaps

- **Missing Entity**: 'Roster Seat' mentioned in bootstrap but not found in extracted items
- **Missing Entity**: 'Claiming Request' mentioned in bootstrap but not found in extracted items

## Source Attribution

[^1]: 2026-01-16_part-2, chunk 8, 00:21:07-00:24:03
[^2]: 2026-01-16_part-2, chunk 8, 00:21:07-00:24:03
[^3]: 2026-01-16_part-2, chunk 14, 00:42:30-00:43:47
[^4]: 2026-01-16_part-2, chunk 11, 00:36:58-00:36:58
[^5]: 2026-01-16_part-2, chunk 4, 00:07:59-00:11:46
[^6]: 2026-01-19_devops-discussion, chunk 4, 00:08:13-00:12:13
[^7]: 2026-01-16_part-2, chunk 1, 00:03:16-00:04:15
[^8]: 2026-01-16_part-2, chunk 9, 00:26:46-00:33:24
[^9]: 2026-01-19_devops-discussion, chunk 0, 00:00:00-00:01:10
[^10]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 6, 00:18:52-00:20:07
[^11]: 2026-01-20_athena-part-2, chunk 2, 00:03:27-00:09:42
[^12]: 2026-01-20_athena-part-2, chunk 3, 00:14:53-00:17:54
[^13]: 2026-01-16_part-2, chunk 9, 00:26:46-00:33:24
[^14]: 2026-01-16_part-2, chunk 7, 00:16:31-00:18:52
[^15]: 2026-01-16_part-2, chunk 7, 00:16:31-00:18:52
[^16]: 2026-01-20_user-requests, chunk 9, 00:21:17-00:23:23
[^17]: 2026-01-20_user-requests, chunk 11, 00:25:39-00:27:19
[^18]: 2026-01-16_part-2, chunk 9, 00:26:46-00:33:24
[^19]: 2026-01-16_part-2, chunk 15, 00:45:25-00:45:25
[^20]: 2026-01-16_part-2, chunk 15, 00:45:25-00:45:25
[^21]: 2026-01-16_part-2, chunk 13, 00:39:43-00:42:30
[^22]: 2026-01-16_part-2, chunk 13, 00:39:43-00:42:30
[^23]: 2026-01-16_part-2, chunk 13, 00:39:43-00:42:30
[^24]: 2026-01-16_part-2, chunk 10, 00:34:27-00:35:39
[^25]: 2026-01-16_part-2, chunk 10, 00:34:27-00:35:39
[^26]: 2026-01-16_part-2, chunk 10, 00:34:27-00:35:39
[^27]: 2026-01-19_devops-discussion, chunk 6, 00:17:39-00:20:19
[^28]: 2026-01-19_devops-discussion, chunk 6, 00:17:39-00:20:19
[^29]: 2026-01-19_devops-discussion, chunk 7, 00:22:54-00:40:35
[^30]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 6, 00:18:52-00:20:07
[^31]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 3, 00:06:59-00:08:16
[^32]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 3, 00:06:59-00:08:16
[^33]: 2026-01-20_athena-part-2, chunk 1, 00:01:44-00:04:49
[^34]: 2026-01-19_devops-discussion, chunk 1, 00:01:10-00:02:38
[^35]: 2026-01-19_devops-discussion, chunk 10, 00:40:35-00:44:22
[^36]: 2026-01-19_devops-discussion, chunk 6, 00:17:39-00:20:19
[^37]: 2026-01-16_part-2, chunk 4, 00:07:59-00:11:46
[^38]: 2026-01-19_devops-discussion, chunk 6, 00:17:39-00:20:19
[^39]: 2026-01-19_devops-discussion, chunk 6, 00:17:39-00:20:19
[^40]: 2026-01-19_devops-discussion, chunk 6, 00:17:39-00:20:19
[^41]: 2026-01-19_devops-discussion, chunk 4, 00:08:13-00:12:13
[^42]: 2026-01-19_devops-discussion, chunk 3, 00:06:05-00:08:13
[^43]: 2026-01-19_devops-discussion, chunk 4, 00:08:13-00:12:13
[^44]: 2026-01-19_devops-discussion, chunk 1, 00:01:10-00:02:38
[^45]: 2026-01-19_devops-discussion, chunk 1, 00:01:10-00:02:38
[^46]: 2026-01-19_devops-discussion, chunk 2, 00:03:48-00:06:05
[^47]: 2026-01-19_devops-discussion, chunk 2, 00:03:48-00:06:05
[^48]: 2026-01-19_devops-discussion, chunk 1, 00:01:10-00:02:38
[^49]: 2026-01-16_part-2, chunk 4, 00:07:59-00:11:46
