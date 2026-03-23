# Analytics Worker

Queue-based microservice for capturing analytics from streaming and social platforms.

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `analytics-worker` |
| **Language** | Python 3.11.9 |
| **Database** | SQLAlchemy 2.0 + PostgreSQL |
| **Queue** | AWS SQS |
| **Storage** | AWS S3 |
| **Scaling** | KEDA on EKS |

## When to Load

Load this reference when:
- Adding support for new streaming platforms
- Modifying stats capture logic
- Working with S3 data lake storage
- Configuring KEDA autoscaling
- Debugging platform API integrations

## Architecture

```
Orchestration (core-backend, Airflow)
       │
       ▼
SQS Input Queues (per source + priority)
       │
       ▼
Platform Processors (Spotify, YouTube, TikTok, etc.)
       │
       ├──► S3 Data Lake (capture/{source}/{action}/)
       ├──► PostgreSQL (operational metadata)
       └──► SQS Output Queues (results)
              │
              ▼
        Downstream Services
```

## Supported Platforms (10 Sources)

| Category | Platforms |
|----------|-----------|
| Music Streaming | Spotify, YouTube Music, SoundCloud, Tidal |
| Music Discovery | Shazam, Genius |
| Social Platforms | YouTube, TikTok, Instagram |
| Industry Data | Jaxsta (music credits) |

## Action Types

| Action | Description |
|--------|-------------|
| `stats` | Streaming metrics (plays, views, likes) |
| `catalog` | Metadata (artist profiles, albums, tracks) |
| `search` | Cross-platform entity search, ISRC/UPC lookup |
| `new_releases` | Monitor new album releases |

## Queue Structure

Each source has high/medium priority queues:

| Source | High Priority | Medium Priority |
|--------|---------------|-----------------|
| Spotify | `QUEUE_SPOTIFY_HIGH` | `QUEUE_SPOTIFY_MEDIUM` |
| YouTube | `QUEUE_YOUTUBE_HIGH` | `QUEUE_YOUTUBE_MEDIUM` |
| TikTok | `QUEUE_TIKTOK_HIGH` | `QUEUE_TIKTOK_MEDIUM` |
| Catalog-Spotify | `QUEUE_CATALOG_SPOTIFY_HIGH` | `QUEUE_CATALOG_SPOTIFY_MEDIUM` |
| Catalog-Jaxsta | `QUEUE_CATALOG_JAXSTA_HIGH` | `QUEUE_CATALOG_JAXSTA_MEDIUM` |

## Production Scaling (KEDA)

| Worker | Max Replicas |
|--------|--------------|
| YouTube Medium | 50 |
| Shazam Medium | 25 |
| SoundCloud Medium | 20 |
| Catalog-Jaxsta Medium | 20 |
| TikTok Medium | 17 |
| Catalog-Spotify Medium | 15 |

## S3 Data Lake Structure

```
s3-bucket/
├── capture/{source}/
│   ├── stats/           # Analytics data
│   ├── stats_search/    # Search results  
│   ├── stats_socials/   # Social media data
│   ├── catalog/         # Metadata catalog
│   ├── new_releases/    # New release data
│   └── others/          # Miscellaneous
```

## Related References

- `capture-service-architecture.md` - Full capture system (interface, scheduler, worker)
- `api.md` - Message formats and processing
- `configuration.md` - Setup, environment, proxy config, deployment
- `patterns.md` - Processor implementation patterns, scraping approaches
- `gotchas.md` - Platform-specific issues
- `spotify-data-flow.md` - Spotify API architecture, credential rotation (470 apps), data pipeline flow
