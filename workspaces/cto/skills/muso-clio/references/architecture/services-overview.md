# Muso.AI Services Overview

Source: [Oleg Knowledge Transfer (Notion)](https://www.notion.so/High-Level-Document-2ed0aeed21ad80a28eedffdc9fcb1f96)

## Teams and Ownership

```
                              ┌─────────────────────────────────────────────────────────────┐
                              │                        Muso.AI                               │
                              └─────────────────────────────────────────────────────────────┘
                                                         │
           ┌─────────────────────────────────────────────┼─────────────────────────────────────────────┐
           │                                             │                                             │
           ▼                                             ▼                                             ▼
┌─────────────────────┐                      ┌─────────────────────┐                      ┌─────────────────────┐
│       GROWTH        │                      │      PLATFORM       │                      │      DISCOVERY      │
│                     │                      │                     │                      │                     │
│  Acquire Customers  │                      │   Capture / Ingest  │                      │   Discovery / Gigs  │
│  Add Unique Value   │                      │   Process / Query   │                      │                     │
│  Grow Business $    │                      │   Search / Export   │                      │                     │
│                     │                      │   Clean / Monitor   │                      │                     │
└─────────────────────┘                      └─────────────────────┘                      └─────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                              GROWTH SUB-TEAMS                                                    │
├──────────────────┬──────────────────┬──────────────────┬──────────────────┬──────────────────┬──────────────────┤
│   Acquisition    │   Discography    │   Analytics      │   Payments       │   Operations     │  Update Industry │
│   & Marketing    │                  │                  │                  │                  │                  │
│                  │                  │                  │                  │  Catalog/Credits │ Catalog Metadata │
│                  │                  │                  │                  │  Support         │ Credits Reconcil │
│                  │                  │                  │                  │                  │ Royalties        │
└──────────────────┴──────────────────┴──────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

## Service Ownership by Team

### Growth Services
Owner: Growth Team

| Service | Description | GitHub |
|---------|-------------|--------|
| **Core Backend** | All user-facing APIs, interactions with core DB | [Muso-AI/core-backend](https://github.com/Muso-AI/core-backend) |
| ├─ Core Backend API | User-facing REST API, proxy to other services | - |
| ├─ Main Worker | Background job processing | - |
| ├─ Posters Worker | Poster/tile generation jobs | - |
| └─ Backend Analytics Worker | Daily PRO profile processing, ensures analytics ready | - |
| **Web App (Frontend)** | Nuxt.js credits web application | [Muso-AI/web-credits](https://github.com/Muso-AI/web-credits) |
| **Mobile App (Flutter)** | iOS/Android mobile application | [Muso-AI/mobile](https://github.com/Muso-AI/mobile) |
| **Render Service** | API for tile/plaque generation, stores on S3 | [Muso-AI/render-service](https://github.com/Muso-AI/render-service) |
| **Customer API Docs** | Documentation for developer.muso.ai | [Muso-AI/customer-api-docs](https://github.com/Muso-AI/customer-api-docs) |
| **Static Websites** | Route53 → CloudFront(+WAF) → S3 | - |
| ├─ Muso Website | muso.ai marketing site | - |
| └─ Website Encore | encore.muso.ai | - |

### Catalog Services
Owner: Catalog Team (Oleg)

| Service | Description | GitHub |
|---------|-------------|--------|
| **Data Capture** | Originally designed by Ihor Kopaniev | [Muso-AI/analytics-worker](https://github.com/Muso-AI/analytics-worker) |
| ├─ Capture Scheduler | Schedules capture jobs | - |
| ├─ Capture Interface | Interface for capture system | - |
| └─ Capture Worker | Workers for each source (analytics + catalog). Some services like Spotify have both. | - |
| **Industry Processing** | Biggest Catalog mono-repo (Oleg, Ihor, Eman) | [Muso-AI/industry-data-processing](https://github.com/Muso-AI/industry-data-processing) |
| ├─ Industry API | API on top of all Mongo and Aurora databases | - |
| ├─ Raw Industry Processing | Processes capture sources (Spotify, Tidal, Genius, Jaxsta, MLC). Stores in raw_ Mongo collections | - |
| ├─ Catalog Industry Processing | Processes "sync" (profile/release/recording) and "operations" tasks | - |
| └─ Analytics Industry Processing | Processes capture analytics (Spotify, YouTube, Shazam, TikTok, SoundCloud). Stores in analytics_link/video Aurora stats | - |
| **Feed Service** | Posts, follows, feed retrieval. Tables partitioned by quarter | [Muso-AI/feed-service](https://github.com/Muso-AI/feed-service) |

### Platform Services
Owner: Platform Team (Andrey)

| Service | Description | GitHub |
|---------|-------------|--------|
| **MWAA (Pipeline Orchestrator)** | 90+ pipelines, Airflow on AWS MWAA | [Muso-AI/platform-data-processing](https://github.com/Muso-AI/platform-data-processing) |
| ├─ Persist Products | Persist layer for data products | - |
| ├─ Platform Formulas | Calculation formulas | - |
| └─ Catalog Pipelines | Analytics calculations, SLA scheduling, data quality, external data feeds | [DAG config](https://github.com/Muso-AI/platform-data-processing/blob/main/src/merge/merge_export_dags_config.py) |
| **Spark Cluster** | Apache Spark for large-scale processing | - |

### DevOps
| Service | Description | GitHub |
|---------|-------------|--------|
| **DevOps** | Infrastructure, CI/CD, Terraform | [Muso-AI/devops](https://github.com/Muso-AI/devops) |

## Services Interaction

```
                                    ┌───────────────────┐
                                    │      Clients      │
                                    │  (Web / Mobile)   │
                                    └─────────┬─────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                      Core Backend                                                    │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐               │
│  │ Core Backend API│  │   Main Worker   │  │ Posters Worker  │  │Backend Analytics│               │
│  │                 │  │                 │  │                 │  │    Worker       │               │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘               │
└───────────┼─────────────────────┼───────────────────┼───────────────────┼─────────────────────────┘
            │                     │                   │                   │
            │                     ▼                   ▼                   │
            │              ┌─────────────────────────────────────────┐    │
            │              │            Render Service               │    │
            │              └─────────────────────────────────────────┘    │
            │                                                             │
            ├─────────────────────────────┬───────────────────────────────┤
            ▼                             ▼                               ▼
┌─────────────────────┐      ┌─────────────────────┐         ┌─────────────────────┐
│  Catalog Services   │      │  Industry Services  │         │  Platform Pipelines │
│                     │      │                     │         │                     │
│  - Data Capture     │      │  - Industry API     │         │  Pulls data from    │
│  - Feed Service     │      │  - Raw Processing   │         │  all snapshots      │
│                     │      │  - Catalog Process  │         │                     │
│                     │      │  - Analytics Process│         │  Filters snapshot   │
│                     │      │                     │         │  ids for categories │
└──────────┬──────────┘      └──────────┬──────────┘         │                     │
           │                            │                     │  Runs reconciliation│
           │                            │                     │  process on data    │
           │                            │                     │                     │
           └────────────────────────────┴─────────────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
           ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
           │   MongoDB    │    │   Postgres   │    │      S3      │
           │  (raw_*,     │    │  (stats,     │    │  (data lake, │
           │   catalog_*) │    │   core)      │    │   assets)    │
           └──────────────┘    └──────────────┘    └──────────────┘
```

## Recursive Data Capture Flow

The Capture and Industry Processing services work in a recursive loop to ensure complete data. This is the primary mechanism for building and maintaining the music industry database.

```
Capture (new artist "Oleg")
    │
    ▼
Raw Processing receives artist + album IDs (no album details yet)
    │
    ▼
Industry Processing: "I need album details for these IDs"
    │
    ▼
Capture Controller receives request → Capture returns albums + track IDs
    │
    ▼
Industry Processing: "I need track details for these IDs"
    │
    ▼
Capture returns tracks + collaborator IDs (e.g., "Serhii")
    │
    ▼
Industry Processing: "I need collaborator 'Serhii' profile"
    │
    ▼
Capture returns collaborator profile
    │
    ▼
All entities now synced to catalog ✓
```

**Why this design:** Instead of waiting for perfect data (which requires complex distributed retries and dead letter queues), the system stores whatever it can and self-heals asynchronously.

**Failure handling:**
- If any entity fails to capture, data appears corrupted in UI (e.g., collaborator doesn't show on track)
- Platform data quality checks detect corruption daily
- Corrupted entities are automatically rescheduled for recapture
- This is why capture failures self-heal over time without manual intervention

**Volume:** The system refreshes ~80 million tracks per day through this recursive flow.

Source: [DevOps KT Meeting (Jan 19, 2026)](../../kt/2026-01-19_devops-discussion.md)

## Service API Communication

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              Real-Time Communication over APIs                           │
│                                                                                          │
│   ┌──────────────┐                                                                      │
│   │  Service API │◄────────────────────────────────────────────────────────────────┐   │
│   │              │                                                                  │   │
│   └──────────────┘                                                                  │   │
│          │                                                                          │   │
│          ├──────────────────┬──────────────────┬──────────────────┐                │   │
│          ▼                  ▼                  ▼                  ▼                │   │
│   ┌────────────┐     ┌────────────┐     ┌────────────┐     ┌────────────┐         │   │
│   │   User     │     │   Admin    │     │  Third     │     │  Other     │         │   │
│   │            │     │            │     │  Party     │     │  Service   │─────────┘   │
│   └────────────┘     └────────────┘     └────────────┘     └────────────┘             │
│                                                                                          │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                              Non-Real-Time (SQS Queues)                                  │
│                                                                                          │
│   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐      │
│   │  Service A   │────▶│     SQS      │────▶│  Service B   │────▶│   Storage    │      │
│   │  (Producer)  │     │    Queue     │     │  (Consumer)  │     │              │      │
│   └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘      │
│                                                                                          │
│   ┌──────────────┐                          ┌──────────────┐                            │
│   │ Other Service│────────────────────────▶│ Other Service│                            │
│   │    (Caller)  │     Direct API Call      │  (Callee)    │                            │
│   └──────────────┘                          └──────────────┘                            │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## AWS Infrastructure

### ECS Core Cluster
[AWS Console](https://us-west-2.console.aws.amazon.com/ecs/v2/clusters/core-prod/services?region=us-west-2)

| Service | Purpose |
|---------|---------|
| `core-backend-api` | Main API |
| `ai-chat-api` | AI chat |
| `core-worker` | Background jobs |
| `website` | Next.js website |
| `credits` | Nuxt.js credits app |
| `core-posters` | Poster generation |
| `render-service` | Media rendering |

### EKS Catalog Cluster
[AWS Console](https://us-west-2.console.aws.amazon.com/eks/clusters/core-prod?region=us-west-2&selectedResourceId=deployments&selectedTab=cluster-resources-tab)

| Workload | Purpose |
|----------|---------|
| `analytics-scheduler` | Orchestration scheduling |
| `analytics-controller` | Worker orchestration |
| `industry-prod` | Industry API |
| `raw-processing` | Raw data processing |
| `analytics-processing` | Stats processing |
| `platform-data-api` | Platform data API |

### EKS Platform Cluster
[AWS Console](https://us-west-2.console.aws.amazon.com/eks/clusters/platform-data-processing-pipelines-prod?region=us-west-2&selectedResourceId=deployments&selectedTab=cluster-resources-tab)

| Workload | Purpose |
|----------|---------|
| Airflow webserver | Pipeline orchestration UI |
| Airflow scheduler | DAG scheduling |
| Spark applications | Data processing jobs |

### MWAA (Managed Airflow)
[AWS Console](https://us-west-2.console.aws.amazon.com/mwaa/home?region=us-west-2#environments)

90+ pipelines including:
- Analytics calculations
- SLA scheduling to Capture Catalog queues
- Data quality checks
- External data feed population
- Export pipelines

## Important Docs

| Document | Purpose |
|----------|---------|
| [DevOps Knowledge Transfer](https://www.notion.so/1df0f087197f4669a0aaa8026ffc13cd) | Infrastructure understanding |
| [Oleg/Team Tunneling](https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19) | Tunneling for DBs and APIs |
| [Muso.AI Data Feed Documentation](https://www.notion.so/1260aeed21ad807985cfe92e2821bca1) | Data feed specs |
| [SSO through Muso.AI](https://www.notion.so/41c221870ba44fa49bda6d1554c5e53b) | SSO documentation |
| [How To: Athena](https://www.notion.so/2e90aeed21ad80a1ab79eb14fffbe739) | Athena query guide |
| [Events Tracking](https://www.notion.so/6633e467a6124882a06b216905017af4) | Event tracking specs |
| [How To: Engineering Onboarding](https://www.notion.so/0391f529fada47c5977954c22779dc70) | New engineer setup |

## Internal Diagram Resources (Restricted)

We have additional architecture diagrams stored in a shared diagrams tool.

- Treat diagram links/exports as **internal-only**; do not paste public editor/render links into Slack.
- If you need access, ask Eng/DevOps for the current location and permissions.

---
Last updated: 2026-01-31
