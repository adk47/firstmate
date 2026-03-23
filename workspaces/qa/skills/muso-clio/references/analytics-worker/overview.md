# Analytics Worker Architecture

The **analytics-worker** is a queue-based microservice that captures analytics from streaming/social platforms.

### Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Python 3.11.9 |
| Database | SQLAlchemy 2.0 + PostgreSQL |
| Queue | AWS SQS |
| Storage | AWS S3 |
| Orchestration | Kubernetes + KEDA autoscaling |

### Architecture

```text
Orchestration
  - core-backend
  - Airflow DAGs
    -> schedule messages -> SQS input queues (per source + priority)

SQS input queues
  spotify-high/medium
  youtube-high/medium
  tiktok-high/medium
  shazam-high/medium
  catalog-spotify/tidal
    -> analytics-worker (EKS)

analytics-worker (EKS)
  Platform processors (Spotify/YouTube/TikTok/Shazam/Tidal/SoundCloud)
    -> Base processor (validation, S3, SQS)

Storage
  Base processor -> S3 data lake: capture/{source}/{action}/
  Base processor -> PostgreSQL (operational metadata)

SQS output queues
  QUEUE_RESULTS
  QUEUE_RESULTS_CATALOG
    -> Downstream services: Data Processor, Industry Processing
```

### Supported Platforms (10 Sources)

| Category | Platforms |
|----------|-----------|
| Music Streaming | Spotify, YouTube Music, SoundCloud, Tidal |
| Music Discovery | Shazam, Genius |
| Social Platforms | YouTube, TikTok, Instagram |
| Industry Data | ~~Jaxsta~~ (deprecated - ceased operations Jan 2026) |

### Source Importance Hierarchy

**Critical for Catalog** (provide full entity objects + credits):
1. **Spotify** — Primary source for track/album/artist metadata
2. **Tidal** — Rich credits data, high-quality metadata

**Critical for Analytics** (streams are always most important):
- Partner feeds: AudioMac, Qobuz, Anghami
- Scraped: Spotify, YouTube, SoundCloud
- **Daily batch (Zyte)**: Spotify stream counts/popularity (~1M/day), Instagram video links/streams/video data
- **Runtime (analytics-worker)**: On-demand scraping for user-triggered/priority requests

**Supplementary Sources**:
- Shazam — Discovery stats, chart positions
- TikTok — Social engagement, sound usage
- Instagram — Video links, streams, video data (handled by Zyte partner)

**Deprecated/Low Priority**:
- Jaxsta — Ceased commercial operations (returns "hibernation" message)
- Genius — Low usage, fragile scraping, can be deprecated

### Action Types

| Action | Description |
|--------|-------------|
| `stats` | Streaming metrics (plays, views, likes) |
| `catalog` | Metadata (artist profiles, albums, tracks) |
| `search` | Cross-platform entity search, ISRC/UPC lookup |
| `new_releases` | Monitor new album releases |
| `track_redirect` | SoundCloud-only: resolve URL to internal ID |

### SoundCloud Track Redirect

SoundCloud URLs don't contain internal IDs. The `track_redirect` action:
1. Input: SoundCloud URL (e.g., `https://soundcloud.com/artist/track-name`)
2. Resolves via SoundCloud API to internal numeric ID
3. Updates database with the resolved ID

This enables linking SoundCloud tracks to the unified catalog.

### Queue Structure

Each source has separate high/medium priority queues:

| Source | High Priority | Medium Priority |
|--------|---------------|-----------------|
| Spotify | `QUEUE_SPOTIFY_HIGH` | `QUEUE_SPOTIFY_MEDIUM` |
| YouTube | `QUEUE_YOUTUBE_HIGH` | `QUEUE_YOUTUBE_MEDIUM` |
| TikTok | `QUEUE_TIKTOK_HIGH` | `QUEUE_TIKTOK_MEDIUM` |
| SoundCloud | `QUEUE_SOUNDCLOUD_HIGH` | `QUEUE_SOUNDCLOUD_MEDIUM` |
| Shazam | `QUEUE_SHAZAM_HIGH` | `QUEUE_SHAZAM_MEDIUM` |
| Catalog-Spotify | `QUEUE_CATALOG_SPOTIFY_HIGH` | `QUEUE_CATALOG_SPOTIFY_MEDIUM` |
| Catalog-Tidal | `QUEUE_CATALOG_TIDAL_HIGH` | `QUEUE_CATALOG_TIDAL_MEDIUM` |

### Production Scaling (KEDA)

| Worker | Max Replicas | Notes |
|--------|--------------|-------|
| YouTube Medium | 50 | |
| Shazam Medium | 25 | |
| SoundCloud Medium | 20 | |
| TikTok Medium | 17 | Reduced due to blocking |
| Catalog-Spotify Medium | 15 | Reduced due to rate limits |

### S3 Data Lake Structure

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

---
