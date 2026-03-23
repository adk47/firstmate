# Industry Data Processing Architecture

## Industry Data Processing (industry-data-processing repo)

The **industry-data-processing** repo runs the SQS-driven workers and FastAPI API that build and serve the unified industry catalog used across Muso.AI.

#### Pipeline Stages (SQS Workers)

```text
SQS raw queues
  -> process_raw.py
     -> MongoDB raw_*
     -> SQS catalog queues
        -> process_catalog.py
           -> MongoDB catalog_*
           -> SQS analytics queues
              -> process_analytics.py
                 -> PostgreSQL stats

FastAPI /api/v1
  -> reads MongoDB catalog_*
  -> reads PostgreSQL stats
```

- Raw worker: `industry-proc-raw-{env}` and `industry-proc-raw-high-{env}` queues, writes `raw_*` collections.
- Catalog worker: `industry-proc-catalog-{env}` and `industry-proc-catalog-high-{env}` queues, writes `catalog_*` collections (sync, merge, link, aggregate).
- Analytics worker: `industry-proc-analytics-{env}` and `industry-proc-analytics-high-{env}` queues, writes stats tables in PostgreSQL.

#### Data Sources
- Spotify, MLC, Muso, Tidal, Genius, Jaxsta, YouTube Music

#### Stores, Models, and Patterns
- MongoDB Atlas (raw, catalog, dict collections) via MongoEngine
- Aurora/PostgreSQL (stats, catalog, olap schemas) via SQLAlchemy
- Soft deletes (`deleted_timestamp`), merge tracking (`merged_to_id`), and source priority resolution

#### API (FastAPI)
- Core endpoints: `/api/v1/profile/{id}`, `/api/v1/track/{id}`, `/api/v1/album/{id}`, `/api/v1/search`, `/api/v1/stats`, `/health`
- Runs on port `8000`, serves catalog lookups and limited stats queries

#### Deployment and CI/CD
- EKS deployments with Helm chart at `ops/helm/industry-data-processing/`
- KEDA scales worker pods on SQS depth; API uses HPA
- `.version` drives Jenkins builds, image tagging, and dev-to-prod promotion

#### Monitoring
- See `monitoring.md` for CloudWatch/API/SQS signals and operational follow-ups.

#### Local Development and Testing
- Python 3.10+, `config_local.ini`, venv, `process_raw.py`, `process_catalog.py`, `process_analytics.py`
- API run: `uvicorn api.main:app --reload --port=8000`
- pytest uses real MongoDB Atlas test DB and PostgreSQL container (no DB mocking)

---
