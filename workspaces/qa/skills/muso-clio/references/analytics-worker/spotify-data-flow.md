# Spotify Data Flow Architecture

This document describes how the analytics-worker scrapes Spotify data and how it flows through the Muso.AI system.

## ⚠️ IMPORTANT: Spotify API Restrictions (Effective March 9, 2026)

**The current architecture (470 rotating Client IDs) will stop working on March 9, 2026.**

Spotify is restricting Development Mode to:
- One Client ID per developer
- Five authorized users per Client ID
- Requires Spotify Premium account

**Migration Required:**
- Apply for Extended Quota Mode (requires Spotify approval), OR
- Migrate to unauthenticated partner API token extraction (see SpotifyCore implementation below)

See `gotchas.md` for detailed impact analysis and migration paths.

## Overview Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           MUSO.AI SPOTIFY DATA PIPELINE                                  │
└─────────────────────────────────────────────────────────────────────────────────────────┘

                                    ┌──────────────────────┐
                                    │   SPOTIFY WEB API    │
                                    │  api.spotify.com/v1  │
                                    └──────────┬───────────┘
                                               │
                                               │ HTTP/REST
                                               ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              ANALYTICS-WORKER (Python)                                   │
│                                                                                          │
│  ┌─────────────────┐     ┌──────────────────────────────────────────────────────────┐   │
│  │  spotify_creds  │     │                    SpotifyCore                            │   │
│  │    470 apps     │────▶│  • Randomly selects credentials from pool                │   │
│  │  (client_id +   │     │  • Rotates every 25 requests to avoid rate limits        │   │
│  │  client_secret) │     │  • Caches OAuth tokens per client_id                     │   │
│  └─────────────────┘     │  • Handles 401 errors with credential rotation           │   │
│                          └──────────────────────────────────────────────────────────┘   │
│                                               │                                          │
│                                               ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐   │
│  │                         SpotifyProcessor                                          │   │
│  │                                                                                   │   │
│  │  Actions:                          Data Collected:                                │   │
│  │  ├─ stats      ─────────────────▶  Track stream counts (popularity)              │   │
│  │  ├─ catalog    ─────────────────▶  Artist/Album/Track metadata                   │   │
│  │  │   ├─ artist                     • name, images, followers                     │   │
│  │  │   ├─ album                      • tracks, release_date, UPC                   │   │
│  │  │   └─ track                      • ISRC, audio features, preview_url           │   │
│  │  ├─ search     ─────────────────▶  Search results (by ISRC/UPC/name)             │   │
│  │  └─ new_releases ───────────────▶  Latest album releases                         │   │
│  └──────────────────────────────────────────────────────────────────────────────────┘   │
│                                               │                                          │
│                          ┌────────────────────┴────────────────────┐                     │
│                          ▼                                         ▼                     │
│              ┌───────────────────────┐               ┌──────────────────────────┐       │
│              │   S3 Data Lake        │               │   SQS Result Queues      │       │
│              │   (Raw JSON files)    │               │                          │       │
│              │                       │               │  • QUEUE_RESULTS         │       │
│              │  /stats/              │               │    (stats data)          │       │
│              │  /catalog/            │               │                          │       │
│              │  /stats_search/       │               │  • QUEUE_RESULTS_CATALOG │       │
│              │  /new_releases/       │               │    (catalog data)        │       │
│              └───────────────────────┘               └───────────┬──────────────┘       │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                                                   │
                                                                   │ SQS Messages
                                                                   ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                        INDUSTRY-DATA-PROCESSING (Python)                                 │
│                                                                                          │
│  ┌────────────────────┐  ┌────────────────────┐  ┌─────────────────────┐                │
│  │    RAW WORKER      │  │  CATALOG WORKER    │  │  ANALYTICS WORKER   │                │
│  │                    │  │                    │  │                     │                │
│  │ Ingests raw data   │  │ Builds unified     │  │ Generates stats     │                │
│  │ from Spotify       │─▶│ catalog from all   │─▶│ and aggregations    │                │
│  │ (and other sources)│  │ sources (priority  │  │                     │                │
│  │                    │  │ based merge)       │  │                     │                │
│  └─────────┬──────────┘  └─────────┬──────────┘  └──────────┬──────────┘                │
│            │                       │                        │                           │
│            ▼                       ▼                        ▼                           │
│  ┌─────────────────────────────────────────┐    ┌───────────────────────┐               │
│  │         MongoDB Atlas                   │    │  PostgreSQL Aurora    │               │
│  │                                         │    │                       │               │
│  │  raw_profile   ──┐                      │    │  stats.profile_track  │               │
│  │  raw_release     │  ┌────────────────┐  │    │  stats.track_daily    │               │
│  │  raw_recording ──┴─▶│ catalog_profile│  │    │  stats.link           │               │
│  │                     │ catalog_release │  │    │  stats.video          │               │
│  │  (Spotify raw data  │ catalog_track   │  │    │                       │               │
│  │   with source_id)   └────────────────┘  │    │  (Daily stream stats, │               │
│  │                     (Unified entities)  │    │   aggregations)       │               │
│  └─────────────────────────────────────────┘    └───────────────────────┘               │
│                                                                                          │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐   │
│  │                            FastAPI REST API (:8000)                               │   │
│  │                                                                                   │   │
│  │  /api/v1/profile/{id}  ─── Artist profiles with credits                          │   │
│  │  /api/v1/track/{id}    ─── Track details + streaming stats                       │   │
│  │  /api/v1/album/{id}    ─── Album metadata                                        │   │
│  │  /api/v1/search        ─── Cross-platform search                                 │   │
│  │  /api/v1/stats         ─── Analytics queries                                     │   │
│  └──────────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                               │
                                               │ REST API
                                               ▼
                    ┌──────────────────────────────────────────────┐
                    │              MUSO.AI CLIENTS                  │
                    │                                              │
                    │  ┌─────────────┐  ┌─────────────────────┐   │
                    │  │ Mobile App  │  │ Web App (credits)   │   │
                    │  │  (Flutter)  │  │                     │   │
                    │  └─────────────┘  └─────────────────────┘   │
                    │                                              │
                    │  Used for:                                   │
                    │  • Verified music credits for artists        │
                    │  • Track/album metadata lookup               │
                    │  • Streaming statistics display              │
                    │  • Playlist management                       │
                    └──────────────────────────────────────────────┘
```

## Component Summary

| Component | Purpose |
|-----------|---------|
| **470 Spotify Apps** | Credential rotation to handle API rate limits (rotates every 25 requests) |
| **analytics-worker** | Fetches raw Spotify data (streams, metadata, search results) |
| **S3 Data Lake** | Stores raw JSON responses for audit/replay |
| **industry-data-processing** | Normalizes and merges data from Spotify + other sources (Tidal, MLC, Genius, etc.) |
| **MongoDB** | Primary catalog storage (profiles, tracks, releases) |
| **PostgreSQL** | Analytics/stats aggregations |
| **REST API** | Serves unified data to Muso.AI mobile/web apps |

## Credential Management

The `SpotifyCore` class (`processor/spotify_processor/spotify_api_core.py`) manages API authentication:

```python
# Credentials are loaded from credentials/spotify_creds.py (470 apps)
api_cred = random.choice(spotify_creds)

# Token rotation every 25 requests to distribute load
requests_to_refresh_token = 25

# Token caching per client_id to avoid unnecessary auth calls
tokens_cache = {}
```

### Why 470 Apps?

Spotify's API has rate limits. By rotating across many registered applications:
- Each app gets its own rate limit quota
- Random selection distributes load evenly
- Failed/revoked credentials are automatically skipped (30 retry attempts)

## Data Types Collected

### Stats Action
- Track popularity/stream counts
- Collected per album (all tracks)

### Catalog Action
- **Artist**: name, images, followers, genres, external URLs
- **Album**: name, release_date, tracks, UPC, images, label
- **Track**: name, ISRC, duration, audio features (tempo, key, energy, etc.), preview URL

### Search Action
- Query by ISRC (tracks), UPC (albums), or text name
- Returns matching artists, albums, and tracks

### New Releases Action
- Latest album releases by country
- Used for discovery and catalog updates

## Downstream Processing

The Spotify data flows into `industry-data-processing` where it is:

1. **Ingested** as raw data (preserving original Spotify response)
2. **Merged** with other sources (Tidal, MLC, Genius, Jaxsta) using priority-based field selection
3. **Unified** into a single catalog entity per real-world artist/track/album
4. **Aggregated** into analytics tables for reporting

## Key Files

| File | Description |
|------|-------------|
| `credentials/spotify_creds.py` | 337 Spotify app credentials |
| `credentials/spotify_creds_all.py` | 470 Spotify app credentials (full set) |
| `processor/spotify_processor/spotify_api_core.py` | API client with auth/rotation |
| `processor/spotify_processor/spotify_processor.py` | Message processing logic |
| `processor/spotify_processor/spotify_api_parser.py` | Response parsing |
| `controller/results_sender.py` | Sends results to SQS queues |

## Related Documentation

- [analytics-worker/README.md](../README.md) - Worker setup and testing
- [analytics-worker/architecture.md](../architecture.md) - Full worker architecture
- [industry-data-processing/docs/ARCHITECTURE.md](../../industry-data-processing/docs/ARCHITECTURE.md) - Downstream processing
