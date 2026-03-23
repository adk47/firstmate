# Capture Service Architecture

The capture service is a multi-component system for collecting analytics and catalog data from streaming/social platforms. It consists of three main services that work together.

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CAPTURE SERVICE ARCHITECTURE                         │
└─────────────────────────────────────────────────────────────────────────────┘

    Orchestration Layer                    Scheduling Layer
    ──────────────────                    ────────────────
    ┌──────────────┐                      ┌──────────────────────┐
    │ core-backend │                      │  Analytics Scheduler │
    │   Airflow    │                      │    (Daily Cron)      │
    └──────┬───────┘                      └──────────┬───────────┘
           │                                         │
           │ SQS messages                            │ Reads DB, sends
           │ (entity IDs + priority)                 │ scheduled tasks
           ▼                                         │
    ┌──────────────────────────────────────────────────────────────┐
    │                   Analytics Interface Service                 │
    │                                                               │
    │  Actions: new_releases | search | catalog | stats            │
    │                                                               │
    │  Priority Routing:                                            │
    │  ├─ HIGH priority ──────────────────────► Direct to Worker   │
    │  └─ Other priorities ───► PostgreSQL DB (for scheduling)     │
    └──────────────────────────────────────────────────────────────┘
                              │
                              │ SQS (per source + priority)
                              ▼
    ┌──────────────────────────────────────────────────────────────┐
    │                    Analytics Worker (EKS)                     │
    │                                                               │
    │  Per-Source Queues:           Processors:                     │
    │  ├─ spotify-high/medium       ├─ SpotifyProcessor            │
    │  ├─ youtube-high/medium       ├─ YouTubeProcessor            │
    │  ├─ tiktok-high/medium        ├─ TikTokProcessor             │
    │  ├─ shazam-high/medium        ├─ ShazamProcessor             │
    │  ├─ soundcloud-high/medium    ├─ SoundCloudProcessor         │
    │  ├─ catalog-spotify-*         ├─ TidalProcessor              │
    │  └─ catalog-tidal-*           └─ GeniusProcessor             │
    └──────────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌──────────────────────────────────────────────────────────────┐
    │                      Output Layer                             │
    │  ├─ S3 Data Lake (raw JSON: capture/{source}/{action}/)      │
    │  ├─ PostgreSQL (operational metadata)                         │
    │  └─ SQS Results Queue → Industry Data Processing             │
    └──────────────────────────────────────────────────────────────┘
```

## Analytics Interface Service

**Repo**: `analytics-interface` (last updated 2+ years ago — stable/legacy)

The interface service is the entry point for capture requests. It receives SQS messages and routes them based on action type and priority.

### Actions Supported

| Action | Scheduling | Description |
|--------|------------|-------------|
| `new_releases` | No | Monitor new album releases |
| `search` | No | Cross-platform entity search |
| `catalog` | No | Metadata capture (artist/album/track) |
| `stats` | Yes | Streaming metrics — uses scheduler |

### Priority Routing Logic

```python
# Simplified routing logic
if action == 'stats' and scheduling_enabled:
    if priority == 'high':
        # Send directly to worker queue
        send_to_worker_queue(source, entity_id, priority)
    else:
        # Store in PostgreSQL for batch scheduling
        store_in_scheduling_db(source, entity_id, priority)
else:
    # Non-stats actions go directly to worker
    send_to_worker_queue(source, entity_id, priority)
```

### Message Format

```json
{
  "action": "stats",
  "entity_type": "album",
  "entity_id": "4aawyAB9vmqN3uQ7FjRGTy",
  "source": "spotify",
  "priority": 2
}
```

## Analytics Scheduler Service

**Repo**: `analytics-scheduler`

The scheduler reads the PostgreSQL database daily and dispatches tasks to worker queues based on priority SLAs.

### Priority SLAs

| Priority | Refresh Frequency | Use Case |
|----------|-------------------|----------|
| 1 | Every 2 days | High-activity profiles |
| 2 | Every 7 days | Active profiles |
| 3 | Every 45 days | Moderate activity |
| 4 | Every 180 days | Low activity |
| 5 | Every 365 days | Minimal activity |

### Scheduling Configuration

Located in `scheduling_processor.py`:

```python
# Example: Daily scheduling limits per source/priority
SCHEDULING_CONFIG = {
    'soundcloud': {
        'priority_1': 50000,
        'priority_2': 400000,
        'priority_3': 30000,
    },
    # ... other sources
}

MAX_DAILY_ENTITIES = 500000  # Hard cap across all sources
```

### Planned Deprecation

Oleg noted this service should be deprecated in favor of:
1. Moving all scheduling logic to Airflow DAGs (platform-data-processing)
2. Eliminating the dedicated PostgreSQL database
3. Having pipelines send tasks directly to worker queues

This simplification would:
- Remove a dedicated service to maintain
- Consolidate scheduling logic in one place
- Reduce infrastructure complexity

## Analytics Worker

See `overview.md` for full worker documentation.

The worker is the actual processing component that:
1. Consumes messages from per-source SQS queues
2. Routes to appropriate platform processor
3. Makes API calls / scrapes data
4. Validates output against contracts
5. Stores results in S3 and sends to downstream queues

## Infrastructure

All capture services run on the **catalog EKS cluster**:

| Namespace | Service |
|-----------|---------|
| `analytics-controller` | Interface service |
| `analytics-scheduler` | Scheduler service |
| `analytics-worker` | Worker pods (KEDA-scaled) |

Separate clusters exist for dev and prod environments.

## Related Documentation

- `overview.md` - Worker architecture and supported platforms
- `configuration.md` - Deployment and proxy configuration
- `patterns.md` - Processor implementation patterns
- `gotchas.md` - Platform-specific issues
