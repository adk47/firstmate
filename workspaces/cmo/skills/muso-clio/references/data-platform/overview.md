# Platform Data Processing Architecture

## Airflow/Spark Platform (platform-data-processing repo)

The **platform-data-processing** repo contains the Apache Airflow-based data pipeline infrastructure.

### Tech Stack

| Component | Technology |
|-----------|------------|
| Orchestration | Apache Airflow 2.10.3 |
| Compute | Apache Spark 4.0.0 on Kubernetes |
| Language | Python 3.11 |
| Infrastructure | AWS EKS |
| Storage | AWS S3 (Data Lake) |

### Data Flow Architecture

```text
Sources
  - MongoDB Atlas (industry)
  - RDS Postgres (core/analytics)
  - Streaming platforms (Spotify/YouTube/Qobuz/Audiomack/Anghami)
  - Social platforms (TikTok/Instagram)
  - Other (MLC, Amplitude, Zyte)

Airflow (on EKS)
  Industry Orchestrator (daily 00:05 UTC) triggers:
    Import DAGs -> Materialize DAGs -> Calculate DAGs -> Persist DAGs
  Export DAGs -> Google Sheets

S3 Data Lake stages
  Import DAGs      -> databaseslake/ (raw imports)
  Materialize DAGs -> materialize_v2/ (normalized inputs)
  Calculate DAGs   -> Spark jobs -> calc_athena/ (calculated tables)

Destinations (via Persist DAGs)
  - MongoDB Atlas
  - Postgres DWH (stats, catalog, olap)
  - Elasticsearch
  - SQS (notifications)
  - Segment
```

### DAG Categories

| Category | DAGs | Description |
|----------|------|-------------|
| **Import** | ~15 | Pull data from MongoDB, RDS, Spotify, Qobuz, Audiomack, Anghami, Amplitude, MLC, Zyte |
| **RDS Export** | 3 | Snapshot core/analytics/stats databases to S3 |
| **Materialize** | 7 | Transform raw data into standardized "input contracts" |
| **Calculate** | 6 | Run Spark jobs: Default, Common, LMC, OLAP, Realtime |
| **Persist** | 10 | Write to MongoDB, Elasticsearch, PostgreSQL, SQS, Segment |
| **Export** | 10 | Google Sheets, VIP exports, partner data, reports |

### Key DAGs

| DAG | Schedule | Description |
|-----|----------|-------------|
| `Run_Industry_Orchestrator_V2` | Daily 00:05 UTC | Master orchestrator - triggers all pipelines |
| `Run_Import_Industry_DB` | Weekly Fri 11:00 | MongoDB Atlas snapshot export |
| `Run_Import_Qobuz` | Daily 14:00 | Qobuz streaming data |
| `Run_Import_Amplitude` | Daily 02:00 | User analytics events |
| `Run_Calculate_Industry_DB_Default` | Orchestrated | Main industry calculations |
| `Run_Calculate_Industry_DB_OLAP` | Orchestrated | OLAP cube calculations |
| `Run_Persist_MongoDB` | Orchestrated | Write results to MongoDB |
| `Run_Persist_Elasticsearch` | Orchestrated | Update search indices |

### EKS Node Groups (Specialized)

| Node Group | Purpose |
|------------|---------|
| `platform-industry-calculation-{env}` | Default calculations |
| `platform-industry-calculation-lmc-{env}` | Link/Merge/Create calculations |
| `platform-industry-olap` | OLAP calculations |
| `platform-industry-rt-calculations` | Real-time calculations |
| `platform-industry-persist-catalog` | Catalog persistence |
| `platform-industry-persist-olap` | OLAP persistence |

### Database Connections

| Database | Host | Purpose |
|----------|------|---------|
| `core` | db-core-backend-prod.muso.ai | Core backend data |
| `industry_calculations` | platform-stats-prod cluster | Calculation results |
| `analytics` | analytics-prod cluster | Analytics sources |
| `stats` | platform-stats-prod cluster | Statistics data |
| `catalog` | platform-stats-prod cluster | Music catalog DWH |
| `olap` | platform-stats-prod cluster | OLAP cubes |
| MongoDB Atlas | product-api-prod.nynwt.mongodb.net | Industry database |

## MLC Track Linking Workflow

The MLC (Mechanical Licensing Collective) public database is critical for linking tracks across platforms.

### MLC Data Ingestion

**DAG**: `Run_Import_MLC` (managed by Andre)
- **Schedule**: Daily at 06:00 UTC
- **Source**: SFTP server (MLC publishes ~weekly)
- **Behavior**: Skips if no new data available

```
MLC SFTP Server
      │
      │ Daily check (Run_Import_MLC)
      ▼
┌─────────────────┐
│  New snapshot?  │──No──► Skip (pink in Airflow)
└────────┬────────┘
         │ Yes
         ▼
┌─────────────────┐
│ Download & ETL  │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  Athena: mlc.recording_identifiers      │
│                                         │
│  Columns:                               │
│  - isrc                                 │
│  - original_provider_name (Spotify,     │
│    YouTube, Apple Music, Amazon, etc.)  │
│  - provider_recording_id                │
└─────────────────────────────────────────┘
```

### Cross-Platform Linking

The `recording_identifiers` table enables linking tracks without direct ISRC:

**Example**: Link YouTube video to Muso track
1. Muso has Spotify track with ISRC `USRC12345678`
2. MLC shows same ISRC linked to YouTube ID `dQw4w9WgXcQ`
3. Muso can now attribute YouTube stats to the track

**Coverage by Provider** (from MLC):

| Provider | Records |
|----------|---------|
| Spotify | Highest |
| YouTube | High |
| Apple Music | High |
| Amazon Music | Medium |
| Tidal | Medium |
| Pandora | Medium |
| Google Play | Low |

### Pipeline: `Run_Calculate_New_Links`

Uses MLC data to discover new platform IDs for existing tracks:
1. Query MLC `recording_identifiers` for ISRCs in Muso catalog
2. Find provider IDs not yet in Muso
3. Add to capture queue for stats collection
