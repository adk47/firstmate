# Data Processing Platform (Airflow/Spark)

Apache Airflow-based data pipeline infrastructure for Muso.AI.

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `platform-data-processing` |
| **Orchestration** | Apache Airflow 2.10.3 |
| **Compute** | Apache Spark 4.0.0 on Kubernetes |
| **Language** | Python 3.11 |
| **Infrastructure** | AWS EKS |
| **Storage** | AWS S3 (Data Lake) |

## When to Load

Load this reference when:
- Creating or modifying Airflow DAGs
- Working with Spark jobs
- Managing data imports/exports
- Configuring calculation pipelines
- Working with the S3 data lake

## Data Flow Architecture

```
External Sources (MongoDB, RDS, Streaming APIs)
       │
       ▼
Import DAGs (pull data)
       │
       ▼
S3 Data Lake (Raw: databaseslake/)
       │
       ▼
Materialize DAGs (transform to contracts)
       │
       ▼
S3 Data Lake (Materialized: materialize_v2/)
       │
       ▼
Calculate DAGs (Spark on K8s)
       │
       ▼
S3 Data Lake (Calculated: calc_athena/)
       │
       ▼
Persist DAGs (write to destinations)
       │
       ▼
Destinations (MongoDB, PostgreSQL, Elasticsearch)
```

## DAG Categories

| Category | Count | Description |
|----------|-------|-------------|
| **Import** | ~15 | Pull from MongoDB, RDS, Spotify, Qobuz, Audiomack, Anghami, Amplitude, MLC, Zyte |
| **RDS Export** | 3 | Snapshot core/analytics/stats to S3 |
| **Materialize** | 7 | Transform raw data into standardized input contracts |
| **Calculate** | 6 | Run Spark jobs: Default, Common, LMC, OLAP, Realtime |
| **Persist** | 10 | Write to MongoDB, Elasticsearch, PostgreSQL, SQS, Segment |
| **Export** | 10 | Google Sheets, VIP exports, partner data, reports |

## Key DAGs

| DAG | Schedule | Description |
|-----|----------|-------------|
| `Run_Industry_Orchestrator_V2` | Daily 00:05 UTC | Master orchestrator |
| `Run_Import_Industry_DB` | Weekly Fri 11:00 | MongoDB Atlas snapshot |
| `Run_Import_Qobuz` | Daily 14:00 | Qobuz streaming data |
| `Run_Import_Amplitude` | Daily 02:00 | User analytics events |
| `Run_Calculate_Industry_DB_Default` | Orchestrated | Main calculations |
| `Run_Calculate_Industry_DB_OLAP` | Orchestrated | OLAP cubes |
| `Run_Persist_MongoDB` | Orchestrated | Write to MongoDB |
| `Run_Persist_Elasticsearch` | Orchestrated | Update search indices |

## EKS Node Groups

| Node Group | Purpose |
|------------|---------|
| `platform-industry-calculation-{env}` | Default calculations |
| `platform-industry-calculation-lmc-{env}` | Link/Merge/Create |
| `platform-industry-olap` | OLAP calculations |
| `platform-industry-rt-calculations` | Real-time calculations |
| `platform-industry-persist-catalog` | Catalog persistence |
| `platform-industry-persist-olap` | OLAP persistence |

## Database Connections

| Database | Host | Purpose |
|----------|------|---------|
| `core` | db-core-backend-prod.muso.ai | Core backend data |
| `industry_calculations` | platform-stats-prod cluster | Calculation results |
| `analytics` | analytics-prod cluster | Analytics sources |
| `stats` | platform-stats-prod cluster | Statistics data |
| `catalog` | platform-stats-prod cluster | Music catalog DWH |
| `olap` | platform-stats-prod cluster | OLAP cubes |
| MongoDB Atlas | product-api-prod.nynwt.mongodb.net | Industry database |

## Related References

- `formulas.md` - **Comprehensive calculation formulas** (Credit Score, Popularity, Linking/Merging, Milestones, Charts, etc.)
- `api.md` - DAG triggers and interfaces
- `configuration.md` - Airflow and Spark setup
- `patterns.md` - DAG development patterns
- `gotchas.md` - Common pipeline issues
