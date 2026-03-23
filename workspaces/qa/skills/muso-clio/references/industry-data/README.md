# Industry Data Processing

SQS-driven workers and FastAPI API for building the unified industry catalog.

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `industry-data-processing` |
| **Language** | Python 3.12+ |
| **API** | FastAPI |
| **Queue** | AWS SQS |
| **Databases** | MongoDB Atlas, Aurora PostgreSQL |
| **Scaling** | KEDA on EKS |

## When to Load

Load this reference when:
- Working with catalog processing workers
- Modifying the FastAPI industry API
- Working with MongoDB raw/catalog collections
- Implementing new data sources
- Managing SQS message processing

## Pipeline Architecture

```
Raw SQS Queues                    Catalog SQS Queues              Analytics SQS Queues
       │                                  │                                │
       ▼                                  ▼                                ▼
process_raw.py                    process_catalog.py              process_analytics.py
       │                                  │                                │
       ▼                                  ▼                                ▼
MongoDB raw_*                     MongoDB catalog_*               PostgreSQL stats
collections                       collections                     tables
```

## Pipeline Stages

### Raw Worker
- Queues: `industry-proc-raw-{env}`, `industry-proc-raw-high-{env}`
- Script: `process_raw.py`
- Output: `raw_*` collections in MongoDB
- Sources: Spotify, MLC, Muso, Tidal, Genius, Jaxsta, YouTube Music

### Catalog Worker
- Queues: `industry-proc-catalog-{env}`, `industry-proc-catalog-high-{env}`
- Script: `process_catalog.py`
- Output: `catalog_*` collections in MongoDB
- Operations: sync, merge, link, aggregate

### Analytics Worker
- Queues: `industry-proc-analytics-{env}`, `industry-proc-analytics-high-{env}`
- Script: `process_analytics.py`
- Output: PostgreSQL stats tables

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/profile/{id}` | GET | Profile details |
| `/api/v1/track/{id}` | GET | Track details |
| `/api/v1/album/{id}` | GET | Album details |
| `/api/v1/search` | GET | Search profiles/tracks |
| `/api/v1/stats` | GET | Statistics queries |
| `/health` | GET | Health check |

## Data Sources

- Spotify
- MLC (Mechanical Licensing Collective)
- Muso (internal)
- Tidal
- Genius
- Jaxsta
- YouTube Music

## Deployment

- EKS deployments via Helm: `ops/helm/industry-data-processing/`
- KEDA scales workers on SQS queue depth
- API uses HPA for HTTP traffic

## Related References

- `api.md` - FastAPI endpoints and patterns
- `configuration.md` - Setup and environment
- `monitoring.md` - CloudWatch + SQS monitoring and operational signals
- `patterns.md` - Worker and data patterns
- `gotchas.md` - Common issues
