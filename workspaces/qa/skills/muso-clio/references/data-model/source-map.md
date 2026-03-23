# Source Map: Entity → Backend Store

Maps UI entities/fields to their authoritative backend stores.

## Quick Reference Links

| Resource | URL |
|----------|-----|
| **Admin Panel (Prod)** | https://admin-production.muso.ai/ |
| **Admin Panel (Dev)** | https://admin-nonproduction.muso.ai/ |
| **Retool (Internal)** | [Notion: Retool](https://www.notion.so/af5412b08fc9409e81cdce6a017c8fdf) |
| **How To: Athena** | [Notion: How To Athena](https://www.notion.so/2e90aeed21ad80a1ab79eb14fffbe739) |
| **DB Tunneling** | [Notion: Oleg Paste - Tunneling](https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19) |
| **MongoDB Access** | [Notion: Connect to MongoDB Atlas](https://www.notion.so/adb0059a507743bd8120be793a6648df) |
| **Oleg Knowledge Transfer** | [Notion: Oleg KT](https://www.notion.so/2ed0aeed21ad80a28eedffdc9fcb1f96) |
| **Useful Queries (GitHub)** | [platform-data-processing/docs/oleg-sql-ai](https://github.com/Muso-AI/platform-data-processing/tree/main/docs/oleg-sql-ai) |

## Legend

| Prefix | Store Type |
|--------|------------|
| `mongo:` | MongoDB Atlas |
| `pg:` | PostgreSQL (RDS or Aurora) |
| `es:` | Elasticsearch |
| `s3:` | S3 Data Lake |
| `athena:` | Athena query |

---

## Operational Rules (Invariants)

**Athena is READ-ONLY (SELECT only).** When users ask to UPDATE or change data, guide them to the correct source system:

| Entity | Source of Truth | How to Update |
|--------|-----------------|---------------|
| Profile metadata (name, bio, image, `profile_type`) | MongoDB `catalog_profile` | Admin UI or direct MongoDB |
| Profile claimed status | PostgreSQL `core_backend.profiles` | Admin UI or Aurora |
| User data (email, auth) | PostgreSQL `core_backend.users` | Admin UI or Aurora |
| Track/Album data | MongoDB `catalog_track`/`catalog_release` | Automated pipelines (rarely manual) |
| Streaming stats | PostgreSQL `platform_stats.track_daily` | Automated pipelines only |
| **Credits** | MongoDB `catalog_track.profiles[]` | User API, CSV import, or MongoDB → re-materialize (see Credit Update Guide below) |

---

## Credit Update Guide

Credits are the relationship between a **profile** (person) and a **track**, with specific **roles** (producer, engineer, songwriter, etc.).

### Where Credit Data Lives

| Layer | Location | Purpose |
|-------|----------|---------|
| **Catalog (Display)** | `mongo:catalog_track.profiles[]` | Nested for query efficiency - what users see |
| **Raw (Source)** | `mongo:raw_recording_credit` | Credit data as-is from external sources |
| **Muso Source** | `mongo:source_muso.profile_credit` | User-submitted credits |
| **Dictionary** | `mongo:dict_credit` | Credit type definitions (parent/child hierarchy) |

### Credit Structure (in catalog_track)

```json
{
  "profiles": [
    {
      "profile_id": "uuid",
      "catalog_credits": [
        { "category": "Producer", "credit": "Executive Producer" }
      ],
      "added_by": "jaxsta|spotify|muso|user"
    }
  ]
}
```

### How to Update Credits

#### 1. User Self-Submission (Web/Mobile)

**API:** `POST /api/m/v3/profile/{profile_id}/add-track-credit`

Users can submit credits from the web app. Credits go through **verification** before appearing in catalog.

**Verification Rules (50% threshold triggers rejection):**

| Rule | Max Risk | What It Checks |
|------|----------|----------------|
| Popularity mismatch | 20% | Low-profile popularity + high-track popularity |
| Release date outlier | 20% | Track released far outside profile's normal range |
| New collaborators | 30% | Credit adds many unknown collaborators |
| Unusual credit type | 20% | Profile rarely has this type of credit |
| Multiple mixing/mastering | 20% | Track already has mixing/mastering engineer |
| Scary roles | 10% | Producer/Songwriter (royalty implications) |

**Auto-approve:** Organization profiles, credits that exist in raw sources

**Auto-reject:** Artist credit submissions (use artist linking instead)

#### 2. Bulk Import (CSV)

**SQS Task:** `importProfileCreditsCsv`

For operations team to bulk-add credits. Triggers via core-backend worker queue.

#### 3. Admin Manual Fix

**How to:** Direct MongoDB update to `source_muso.profile_credit`, then trigger materialization.

Steps:
1. Connect to MongoDB Atlas (see [MongoDB Access](https://www.notion.so/adb0059a507743bd8120be793a6648df))
2. Update `source_muso.profile_credit` collection
3. Trigger credit materialization pipeline (Airflow DAG or manual)

#### 4. Automated Pipelines (Primary Path)

Most credits come from external sources, processed automatically:

| Source | Data | Pipeline |
|--------|------|----------|
| **Jaxsta** | Professional credits | Analytics Worker → `catalog-jaxsta` queue |
| **Spotify** | Artist/album credits | Analytics Worker → `catalog-spotify` queue |
| **Tidal** | Catalog metadata | Analytics Worker → `catalog-tidal` queue |
| **MLC** | Work-rights data | Weekly Airflow DAG |
| **Genius** | Supplementary credits | Analytics Worker |

### Credit Lifecycle

```
User submits credit  →  Verification scoring  →  Accept/Reject
                              ↓
                    source_muso.profile_credit
                              ↓
External sources  →   raw_recording_credit   →  Materialization
                              ↓
                    catalog_track.profiles[]
                              ↓
                    Profile credit_count updated
```

### Troubleshooting Credit Issues

| Issue | Check | Fix |
|-------|-------|-----|
| Credit not showing | Verification status | Check if rejected, review in Admin |
| Wrong credit count | Materialization | Re-trigger profile recalculation |
| Duplicate credits | Multiple sources | Check `added_by` field, dedupe logic |
| Missing source credit | Raw data | Check `raw_recording_credit` for source |

### Related Worker Tasks

| Task | Purpose |
|------|---------|
| `updateProfileCreditRequest` | Process individual credit updates |
| `importProfileCreditsCsv` | Bulk CSV import |
| `processProfileNewCreditsNotifications` | Notify users of new credits |
| `processPendingCredits` | Process credits awaiting verification |

---

## Profile Entity

| Field | Backend Source | Collection/Table | Notes |
|-------|---------------|------------------|-------|
| Profile ID | `mongo:catalog_profile._id` | catalog_profile | Muso internal UUID |
| Profile Name | `mongo:catalog_profile.name` | catalog_profile | |
| Biography | `mongo:catalog_profile.biography` | catalog_profile | |
| Location | `mongo:catalog_profile.location` | catalog_profile | City + Country |
| Profile Picture | `mongo:catalog_profile.image_url` | catalog_profile | Should be Muso-hosted |
| Social Links | `mongo:catalog_profile.social_links` | catalog_profile | |
| Popularity | `mongo:catalog_profile.popularity` | catalog_profile | **Calculated** |
| Rank | `mongo:catalog_profile.rank` | catalog_profile | Derived from popularity |
| Credit Count | `mongo:catalog_profile.credit_count` | catalog_profile | Aggregated |
| Artist Associations | `mongo:catalog_profile.artist_ids` | catalog_profile | Links to catalog_artist |
| Claimed Status | `pg:core_backend.profiles.claimed` | profiles | Boolean |
| Verification Status | `pg:core_backend.users.verified` | users | ID verification |
| Subscription Status | `pg:core_backend.subscriptions` | subscriptions | User subscription tier |

---

## Artist Entity

| Field | Backend Source | Collection/Table | Notes |
|-------|---------------|------------------|-------|
| Artist ID | `mongo:catalog_artist._id` | catalog_artist | |
| Artist Name | `mongo:catalog_artist.name` | catalog_artist | From Spotify |
| Artist Picture | `mongo:catalog_artist.images` | catalog_artist | Spotify CDN URLs |
| Spotify ID | `mongo:catalog_artist.spotify_id` | catalog_artist | |
| Popularity | `mongo:catalog_artist.popularity` | catalog_artist | From Spotify |
| Rank | `mongo:catalog_artist.rank` | catalog_artist | Calculated |
| Genres | `mongo:catalog_artist.genres` | catalog_artist | From Spotify |
| Followers | `mongo:catalog_artist.followers` | catalog_artist | From Spotify |
| Member Profiles | `mongo:catalog_artist.member_profile_ids` | catalog_artist | Links to profiles |

---

## Track Entity

| Field | Backend Source | Collection/Table | Notes |
|-------|---------------|------------------|-------|
| Track ID | `mongo:catalog_track._id` | catalog_track | Muso internal UUID |
| Track Title | `mongo:catalog_track.name` | catalog_track | From Spotify |
| Spotify ID | `mongo:catalog_track.spotify_id` | catalog_track | |
| ISRC | `mongo:catalog_track.isrc` | catalog_track | |
| Duration | `mongo:catalog_track.duration_ms` | catalog_track | Milliseconds |
| Popularity | `mongo:catalog_track.popularity` | catalog_track | From Spotify |
| Rank | `mongo:catalog_track.rank` | catalog_track | Calculated |
| Key | `mongo:catalog_track.key` | catalog_track | Numeric, needs mapping |
| Tempo | `mongo:catalog_track.tempo` | catalog_track | BPM |
| Preview URL | `mongo:catalog_track.preview_url` | catalog_track | Spotify CDN |
| Release Date | `mongo:catalog_track.release_date` | catalog_track | May be year-only |
| Album ID | `mongo:catalog_track.album_id` | catalog_track | Links to catalog_release |
| Artist IDs | `mongo:catalog_track.artist_ids` | catalog_track | Array |
| **Credits** | `mongo:catalog_track.profiles` | catalog_track | **Nested array for efficiency** |
| Raw Recording IDs | `mongo:catalog_track.raw_recording_ids` | catalog_track | Links to raw sources |

### Credits Structure (inside catalog_track)

```json
{
  "profiles": [
    {
      "profile_id": "uuid",
      "catalog_credits": [
        {
          "category": "Producer",
          "credit": "Executive Producer"
        }
      ],
      "added_by": "source_name"
    }
  ]
}
```

---

## Album/Release Entity

| Field | Backend Source | Collection/Table | Notes |
|-------|---------------|------------------|-------|
| Album ID | `mongo:catalog_release._id` | catalog_release | |
| Album Name | `mongo:catalog_release.name` | catalog_release | |
| Spotify ID | `mongo:catalog_release.spotify_id` | catalog_release | |
| UPC | `mongo:catalog_release.upc` | catalog_release | |
| Album Type | `mongo:catalog_release.album_type` | catalog_release | |
| Release Date | `mongo:catalog_release.release_date` | catalog_release | |
| Popularity | `mongo:catalog_release.popularity` | catalog_release | |
| Rank | `mongo:catalog_release.rank` | catalog_release | |
| Track Count | `mongo:catalog_release.total_tracks` | catalog_release | |
| Images | `mongo:catalog_release.images` | catalog_release | Spotify CDN URLs |
| Copyrights | `mongo:catalog_release.copyrights` | catalog_release | C-line, P-line |
| Artist IDs | `mongo:catalog_release.artist_ids` | catalog_release | |

---

## Analytics/Stats

| Field | Backend Source | Table | Notes |
|-------|---------------|-------|-------|
| **All Daily Stats** | `pg:platform_stats.track_daily` | track_daily | **SOURCE OF TRUTH** |
| Total Streams | `pg:platform_stats.track_daily.streams` | track_daily | Sum across sources |
| Spotify Streams | `pg:platform_stats.track_daily.spotify_streams` | track_daily | |
| YouTube Streams | `pg:platform_stats.track_daily.youtube_streams` | track_daily | |
| Shazams | `pg:platform_stats.track_daily.shazams` | track_daily | |
| SoundCloud Streams | `pg:platform_stats.track_daily.soundcloud_streams` | track_daily | |
| Views | `pg:platform_stats.track_daily.views` | track_daily | |
| Videos | `pg:platform_stats.track_daily.videos` | track_daily | |
| Link to Source IDs | `pg:platform_stats.analytics_link` | analytics_link | Maps Spotify/YouTube ID → Muso track_id |
| Video Details | `pg:platform_stats.analytics_video` | analytics_video | YouTube/TikTok/Instagram |

### track_daily Granularity

- **Primary Key**: `(date, track_id)`
- **Retention**: Historical (years of data)
- **Scale**: ~1 billion operations/day

---

## User/Team Entity

| Field | Backend Source | Table | Notes |
|-------|---------------|-------|-------|
| User ID | `pg:core_backend.users.id` | users | |
| Email | `pg:core_backend.users.email` | users | PII |
| Auth0 ID | `pg:core_backend.users.auth0_id` | users | |
| Team ID | `pg:core_backend.teams.id` | teams | |
| Subscription | `pg:core_backend.subscriptions` | subscriptions | |
| Roster Seats | `pg:core_backend.roster_seats` | roster_seats | Team → Profile links |

---

## Raw Data (Pre-Catalog)

| Collection | Source | Purpose |
|------------|--------|---------|
| `raw_spotify_artist` | Spotify API | Artist data as-is |
| `raw_spotify_track` | Spotify API | Track data as-is |
| `raw_spotify_album` | Spotify API | Album data as-is |
| `raw_jaxsta_*` | Jaxsta | Credits data |
| `raw_genius_*` | Genius | Lyrics/metadata |
| `raw_tidal_*` | Tidal | Additional source |
| `raw_mlc_*` | MLC | Mechanical licensing data |

---

## Dictionary Tables

| Collection | Purpose |
|------------|---------|
| `dict_credit_category_rule` | Maps credit categories → child credits for charts |
| `dict_roles` | Role definitions |
| `dict_sources` | Data source definitions |
| `dict_genres` | Genre mappings |

---

## Search

| Index | Entity | Purpose |
|-------|--------|---------|
| `es:profiles` | Profile | Full-text search |
| `es:tracks` | Track | Full-text search |
| `es:releases` | Album | Full-text search |

---

## S3 Data Lake / Athena

| Path | Purpose | Query Via |
|------|---------|-----------|
| `s3://muso-data-lake/capture/` | Raw capture data | Athena |
| `s3://muso-data-lake/analytics/` | Analytics exports | Athena |
| Athena Workgroups: `primary` (~256 saved queries), `growth_dev` (marketing) | | |

---

## Data Source Hierarchy for Profiles

### Source Priority (highest to lowest)
1. **Muso** — User-submitted data (always trusted)
2. **Spotify** — Primary for artists, labels
3. **Title** — Primary for comprehensive credits
4. **Tidal** — Supplementary credits
5. **MLC** — Songwriting/publisher (organizations only)
6. **Genius/Jaxsta** — Minor sources (may retire)

### Profile Creation Rules by Source

| Source | Creates Profiles? | Condition | Notes |
|--------|-------------------|-----------|-------|
| **Muso** | Yes | Always | User-submitted profiles |
| **Spotify** | Yes | Always | For artist-type entities |
| **Title** | Yes | `raw_profile.type = 'professional'` | BTS credits only |
| **Tidal** | Yes | `raw_profile.type = 'professional'` | Prevents artist duplicates |
| **MLC** | Organizations only | N/A | Cannot create person profiles |
| **Genius** | No | N/A | Links to existing only |
| **Jaxsta** | No | N/A | Links to existing only |

**Note**: The `professional` type check prevents creating duplicate profiles for artists who already exist via Spotify.

### User Credit Submission Flow
When a user adds a missing credit via web/mobile:
1. Credit submitted via `POST /api/m/v3/profile/{id}/add-track-credit`
2. System queues Spotify capture task for the track (high priority SQS)
3. Capture worker fetches track metadata from Spotify API
4. If Title is not linked to the track (no `raw_recording_id` from Title), only user-added credit appears
5. Full credits appear once Title data is linked (automated via ISRC matching)

**See also**: `industry-data/gotchas.md` → Entity Creation Guardrails for detailed source rules.

Source: KT 2026-02-02
