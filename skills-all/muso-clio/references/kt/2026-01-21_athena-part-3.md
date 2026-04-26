# KT Session: Athena Part 3 - Pipelines & Operational Knowledge

> ⚠️ **HISTORICAL DOC** — This was knowledge transfer about AWS Athena. AWS Athena was retired on **2026-04-25** in favor of Trino on OVH. The data model concepts described below are still valid (same SQL engine family, same tables), but execution commands and DB names have changed. See [trino-query-reference.md](../trino/trino-query-reference.md) for current syntax.


**Date:** 2026-01-21
**Presenter:** Oleg Mamchich
**Attendees:** Jay Ruffing, Serhii Ostapchuk, Ihor Shchuruk
**Meeting ID:** `2026-01-21_athena-part-3`

## Summary

Final Athena-focused session covering MWAA pipeline development, the `calcul` database structure, persist mechanism for data transactionality, LMC operations tables, and operational monitoring. Oleg also introduced a new SQL knowledge base initiative in the platform-data-processing repo.

---

## MWAA Pipeline Overview

**97 total pipelines** in the platform-data-processing repo, orchestrated by Amazon MWAA (Managed Workflows for Apache Airflow).

### Pipeline Ownership

| Folder | Owner | Purpose |
|--------|-------|---------|
| `src/merge/` | Oleg | Business logic - merging, aggregations, SLA |
| `src/export_dags/` | Oleg | Data exports to partners, spreadsheets |
| Everything else | Andre | Import, materialize, calculate, persist |

### Key Oleg Pipelines

| Pipeline | Purpose |
|----------|---------|
| `capture_*` | Process external data → industry processing queue or direct DB insert |
| `capture_daily_sla` | Schedule IDs for capture service to scrape daily |
| `export_zite_input` | Generate scraping input for Zyte (3M track limit/day) |
| `export_vip_customer` | Export roster data to spreadsheets |
| `run_merge_catalog_analytics_maintenance_populate_track_daily_v2` | **Critical** - daily streaming stats |

---

## Development & Deployment Workflow

### No Local Testing

MWAA cannot be run locally. Development workflow:

```
1. Create branch
2. Create/modify pipeline
3. Deploy to dev MWAA
4. Test in dev environment
5. Deploy to prod MWAA
```

### Environment Identification

| Environment | Visual Indicator | URL |
|-------------|------------------|-----|
| Production | No banner | Via AWS Console → MWAA → prod |
| Development | **Green banner at top** | Via AWS Console → MWAA → dev |

### Deployment Process

**Manual S3 sync** (no CI/CD for platform):

```bash
# Deploy to dev
./deploy.sh dev

# Deploy to prod
./deploy.sh prod
```

The script syncs files to S3 bucket that MWAA watches:
- `s3://platform-data-processing-lake-prod/dags/`
- `s3://platform-data-processing-lake-dev/dags/`

---

## The `calcul` Database

### Purpose

Stores intermediate and final results of Andre's calculations, accessible via Athena before data reaches Aurora/MongoDB.

### Key Characteristics

- **Most tables are partitioned by date**
- Contains analytics cubes, profile aggregations, milestones, LMC results
- If a calculation result is missing, ask Andre to create the Athena table

### Important Table Patterns

| Pattern | Example Tables | Purpose |
|---------|----------------|---------|
| Candidate pairs | `calc_link_profile`, `calc_link_tracks` | All possible merge/link candidates |
| Positive pairs | `calc_link_profile_positive`, `calc_link_track_positive` | Candidates that passed threshold |
| History tables | `profile_aggregations_history`, `milestone_generation_history` | Partitioned by date |
| Cubes | `analytics_cube_*`, `industry_stat_cube_*` | Pre-aggregated analytics |

### Querying calcul Tables

**Always filter by partition:**

```sql
-- CORRECT - filter by date partition
SELECT * FROM calcul_prod.milestone_generation_history
WHERE date = '2026-01-20'
LIMIT 100;

-- WRONG - scans entire table
SELECT * FROM calcul_prod.milestone_generation_history
LIMIT 100;
```

---

## Persist Mechanism

### How Data Gets to Aurora/MongoDB

Oleg's pipelines compute data on S3, then trigger Andre's persist pipeline:

```python
# In Oleg's DAG
persist_task = TriggerDagRunOperator(
    task_id='persist_track_daily',
    trigger_dag_id='run_persist_stats',
    conf={
        'format': 'parquet',
        's3_location': 's3://bucket/calc_athena/track_daily/',
        'destination_table': 'track_daily',
        'bucket_by': 'date',  # Partition column
        'primary_keys': ['track_id', 'date'],
        'write_mode': 'upsert'  # Update if exists, insert if not
    }
)
```

### Transactionality Pattern

**Problem:** How to ensure incomplete data isn't used by the codebase?

**Solution:** Config table updated ONLY at pipeline end:

```
Pipeline execution:
1. Calculate data on S3 (calcul steps)
2. Persist to Aurora (persist steps)
3. Update config table with new date ← LAST STEP

Codebase behavior:
- Reads "latest_date" from config table
- Until config updated, uses previous day's date
- Ensures only complete data is served
```

**Example:** `stats_config` table holds the latest successful date for track_daily. Until the pipeline completes, codebase thinks Jan 20 is latest even if Jan 21 data is partially written.

---

## LMC (Link-Merge-Create) Operations

### Operation Types

| Operation | Description |
|-----------|-------------|
| **Link** | Connect raw entity (e.g., Spotify artist) to existing catalog entity |
| **Merge** | Combine two catalog entities into one |
| **Create** | Create new catalog entity from raw entity (no good link candidate) |

### Table Pairs

Each operation has candidate and positive tables:

| Operation | Candidate Table | Positive Table |
|-----------|-----------------|----------------|
| Profile Link | `calc_link_profile` | `calc_link_profile_positive` |
| Profile Merge | `calc_merge_profile` | `calc_merge_profile_positive` |
| Track Link | `calc_link_tracks` | `calc_link_track_positive` |
| Track Merge | `calc_merge_tracks` | `calc_merge_track_positive` |

### Matching Rules (Profiles)

```
Merge if:
  - Name similarity > 80% Levenshtein AND name length > 5 chars
  - AND ln(isrc_intersection) / ln(isrc_count) > 0.5
  - AND isrc_count between 2 and 500
```

---

## Milestone Generation

### Two-Table Pattern

| Table | Contains | Purpose |
|-------|----------|---------|
| `milestone_generation` | All users | Full calculation |
| `milestone_generation_pro_users` | Pro users only | Filtered for Growth SQS |

**Flow:**
1. Platform calculates milestones for ALL profiles
2. Filters to pro users only
3. Sends filtered milestones to Growth SQS for notifications

---

## Profile Aggregations

### Fields Calculated

| Field | Description |
|-------|-------------|
| `track_popularities` | Track counts by popularity range |
| `years_active` | MAX(release_year) - MIN(release_year) |
| `genres` | All genres with track counts |
| `top_collaborators` | Top 4 by track popularity |
| `common_credits` | Top 3 credit categories |

### Dual Storage

Profile aggregations are:
1. Stored in `profile_aggregations_history` (Athena/S3)
2. **Also inserted into Aurora catalog database** for API access

---

## External Partner Data Onboarding

### Workflow

```
1. Partner provides data (S3 bucket or SFTP)
2. Ask Andre to create Athena tables from raw data
3. Oleg explores data structure with ad-hoc queries
4. Confirm data quality and usefulness
5. Create automated pipeline for daily processing
```

### Current Partners

| Partner | Database | Data Type |
|---------|----------|-----------|
| Anghami | `platform_anghami_bi_prod` | Streaming stats |
| Qobuz | `platform_qobuz_bi_prod` | Streaming stats |
| MLC | `platform_industry_mlc_bi_prod` | Recording identifiers |
| Audiomack | `platform_industry_audiomack_bi_prod` | Streaming stats |
| Zyte | `platform_industry_zyteig_bi_prod` | Scraped analytics data (Spotify streams, Instagram video/streams) |

---

## Operational Monitoring

### Pipeline Alerts

**Slack Channel:** `#pipeline-alerts`

- All pipeline failures posted here
- Owner tagged in failure message
- Some pipelines post success metrics (counts of processed entities)

### Success Metrics Examples

| Pipeline | Reports |
|----------|---------|
| Andre's LMC | Profiles/tracks/releases merged, linked, created |
| Oleg's SLA | Tasks sent to each capture queue |

### Critical Pipelines

**If these fail, react immediately:**

| Pipeline | Impact |
|----------|--------|
| `run_merge_catalog_analytics_maintenance_populate_track_daily_v2` | Analytics missing for that day |
| Andre's LMC pipeline | New entities not linked/merged |

### Dependency Cascade

If parent pipeline fails:
- Child pipelines don't run (no input data)
- Children run next day IF parent succeeds
- One failure = one day of missing data in downstream

---

## SQL Knowledge Base Initiative

### Location

`platform-data-processing/docs/oleg-sql-ai/`

### Contents

- Categorized SQL queries extracted from pipelines
- Examples of common patterns (capture, export, aggregation)
- Key columns documentation
- Ad-hoc query templates

### Usage

Point Claude/Cursor at this folder when asking Athena query questions:
> "There's a knowledge dump in oleg-sql-ai. I need to solve X problem. How do I do it?"

---

## Formula Documentation

All calculation formulas documented in:
`platform-data-processing/docs/formulas/`

### Creating New Calculations

1. Describe business logic and desired SQL to Claude
2. Generate MD formula file
3. Hand off to Andre for pipeline creation
4. Andre deploys to dev, Ihor tests
5. Deploy to prod

---

## Key Insights

1. **No local MWAA testing** - always use dev environment
2. **Manual S3 deployment** - no CI/CD for platform pipelines
3. **Config table pattern** - ensures transactionality by updating date last
4. **Candidate vs positive tables** - LMC stores both for debugging
5. **Milestones calculated for all, sent for pro only**
6. **Profile aggregations dual-stored** - Athena AND Aurora
7. **Pipeline failures cascade** - one day lost per failure
8. **SQL knowledge base** - reusable query patterns in oleg-sql-ai/

---

## Related Documentation

- Athena Part 2: `kt/2026-01-20_athena-part-2.md`
- Data platform overview: `data-platform/overview.md`
- Formulas reference: `data-platform/formulas.md`
- Query writer skill: `skills/muso-query-writer/`
