# Database Schema

## Core Entities (PostgreSQL)

```text
Core entities (simplified)

User
  fields: id (PK), email, auth0UserId, stripeCustomerId, neptuneProfessionalId
  relationships:
    - has many: Subscription
    - belongs to: Team (via TeamUsers)
    - manages: UserProfiles
    - has: UserReferrals

Team
  fields: id (PK), name, stripeCustomerId, inhouseAnalyticsEnabled
  relationships:
    - has many: TeamUsers
    - contains: RosterSeats
    - owns: Lists
    - has: Subscription
    - processes: Claiming

Subscription
  fields: id (PK), userId (FK), teamId (FK), service, status, plan, profileSeatsLimit
  relationships:
    - logs: SubscriptionHistory
    - records: PaymentHistory

RosterSeats
  fields: id (PK), teamId (FK), entityType, entityId
  relationships:
    - grants: ProfileAccess

Lists
  relationships:
    - contains: ListSeats
    - shares: ListAccess
```

## Key Tables (Core Backend - PostgreSQL)

| Table | Description |
|-------|-------------|
| `users` | User accounts (email, auth0UserId, stripeCustomerId) |
| `teams` | Workspaces (name, billing, settings) |
| `team_users` | User-to-team membership with roles (owner, admin, member) |
| `subscriptions` | Active subscriptions (plan, limits, status) |
| `subscription_history` | Transaction records |
| `roster_seats` | Profiles/orgs assigned to workspace roster |
| `lists` | Custom profile lists |
| `list_seats` | Profiles within lists |
| `claiming` | Profile claiming requests |
| `profile_access` | User access to profiles |
| `profile_milestones` | Achievement milestones |
| `profile_analytics_stats_history` | Historical analytics |
| `orders` | Physical product orders (posters, plaques) |
| `payment_history` | Payment transactions |
| `spotify_accounts` | Linked Spotify accounts |
| `action_log` | System action logs |
| `user_action_log` | User activity audit |

## MongoDB Collections (Industry DB)

### Raw Collections (Source-Specific Data)

| Collection | Purpose |
|------------|---------|
| `raw_profile` | Artist/professional profiles from sources |
| `raw_release` | Albums/releases from sources |
| `raw_recording` | Tracks/recordings from sources |
| `raw_release_credit` | Credits on releases |
| `raw_recording_credit` | Credits on recordings |

### Catalog Collections (Unified, Deduplicated)

| Collection | Purpose |
|------------|---------|
| `catalog_profile` | Unified artist/professional profiles |
| `catalog_track` | Unified tracks with embedded credits |
| `catalog_release` | Unified albums/releases |
| `catalog_release_credit` | Release credits |

### Dictionary Collections

| Collection | Purpose |
|------------|---------|
| `dict_credit` | Credit type definitions |
| `dict_source` | Source metadata |
| `dict_genre` | Genre definitions |
| `dict_role` | Role definitions |
| `dict_credit_category_rule` | Credit categorization rules |

## Aurora PostgreSQL (Stats/OLAP)

### Stats Schema

| Table | Purpose |
|-------|---------|
| `analytics_link` | Streaming links (Spotify, YouTube, etc.) |
| `analytics_video` | Social video data (TikTok, Instagram) |
| `track_daily` | Daily streaming statistics |
| `profile_track` | Profile-track relationships |

### Catalog Schema (Spark-Managed)

| Table | Purpose |
|-------|---------|
| `catalog_member` | Band/group membership |
| `catalog_member_period` | Membership time periods |

### OLAP Cubes

These live in the **`postgresql_olap`** catalog and are **sharded** by entity index
(`cube_analytics_<dimension>_<index>`, e.g. `cube_analytics_album_627`). Query the daily-rotated
**view** (e.g. `postgresql_olap.public.cube_analytics_album_view`), not a numbered shard; see
`references/kt/2026-01-20_athena-part-2.md` for shard/view resolution.

| Table | Purpose |
|-------|---------|
| `cube_analytics_profile` | Profile analytics aggregations |
| `cube_analytics_track` | Track analytics aggregations |
| `cube_analytics_list` | List analytics aggregations |
| `cube_analytics_credit` | Credit analytics |
| `cube_analytics_album` | Album analytics |
| `cube_analytics_collaborator` | Collaborator analytics |

## Data Store Summary

| Store | Type | Used By |
|-------|------|---------|
| RDS Postgres (core) | Relational | Core Backend, Workers |
| RDS Postgres (analytics) | Relational | Analytics workloads |
| Aurora Postgres | Relational | Stats, Catalog, OLAP |
| ElastiCache Redis | Cache/Queue | Core Backend, Feed Service |
| MongoDB Atlas | Document | Industry Processing, Catalog API |
| S3 | Object storage | Assets, data lake, logs |
| Elasticsearch | Search | Profile/track search |

## Why Aurora for Analytics (Stats DB)

**Problem:** Analytics capture refreshes ~80 million tracks per day. MongoDB IOPS costs became prohibitive at this scale.

**Cost Comparison (similar instance size):**
| Database | Approximate IOPS |
|----------|------------------|
| MongoDB | ~10,000 |
| Aurora | ~120,000 |

This 12x difference in write throughput per dollar drove the architectural decision.

**Aurora Stats DB handles:**
- Analytics data (links, videos, track stats)
- Aggregated tables from Platform processing
- Heavy write workloads that would be cost-prohibitive on MongoDB

**MongoDB remains ideal for:**
- Graph-like entity relationships (profiles, tracks, releases)
- Search with embedded documents (fewer joins)
- Read-heavy catalog queries with complex filtering/sorting

**Key insight:** We started with everything in MongoDB, hit cost/performance walls on writes, then moved analytics to Aurora. The hybrid approach optimizes for each workload's characteristics.

Source: [DevOps KT Meeting (Jan 19, 2026)]
