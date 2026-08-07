# Industry Data Configuration

## Environment Setup

### Prerequisites
- Python 3.12+
- MongoDB Atlas access
- PostgreSQL access
- AWS credentials (SQS)

### Local Development

1. Clone the repository:
```bash
cd industry-data-processing
```

2. Create virtual environment:
```bash
python -m venv venv
source venv/bin/activate
```

3. Install dependencies:
```bash
pip install -r requirements.txt
```

4. Create config file:
```bash
cp config_example.ini config_local.ini
```

5. Configure `config_local.ini` with credentials

## Configuration File

```ini
# config_local.ini

[mongodb]
uri = mongodb+srv://user:pass@cluster.mongodb.net/
database = industry_db

[postgres]
host = localhost
port = 5432
database = stats
user = postgres
password = password

[aws]
region = us-west-2
sqs_raw_queue = industry-proc-raw-dev
sqs_raw_high_queue = industry-proc-raw-high-dev
sqs_catalog_queue = industry-proc-catalog-dev
sqs_catalog_high_queue = industry-proc-catalog-high-dev
sqs_analytics_queue = industry-proc-analytics-dev
sqs_analytics_high_queue = industry-proc-analytics-high-dev

[api]
host = 0.0.0.0
port = 8000
workers = 4
```

## Running Workers

```bash
# Raw worker
python process_raw.py

# Catalog worker
python process_catalog.py

# Analytics worker
python process_analytics.py
```

## Running the API

```bash
# Development
uvicorn api.main:app --reload --port=8000

# Production
uvicorn api.main:app --host=0.0.0.0 --port=8000 --workers=4
```

## MongoDB Collections

### Raw Collections (raw_*)
- `raw_spotify_artists`
- `raw_spotify_tracks`
- `raw_mlc_works`
- `raw_genius_artists`
- `raw_jaxsta_credits`
- `raw_tidal_artists`

### Catalog Collections (catalog_*)
- `catalog_profiles`
- `catalog_tracks`
- `catalog_albums`
- `catalog_credits`

### Dictionary Collections (dict_*)
- `dict_roles`
- `dict_sources`
- `dict_genres`

## PostgreSQL Schemas

### stats schema
<!-- trino-sql-gate: skip (PostgreSQL DDL — CREATE TABLE — not Trino SQL) -->
```sql
-- Profile stats
CREATE TABLE stats.profile_stats (
    profile_id VARCHAR(64),
    source VARCHAR(32),
    metric VARCHAR(32),
    value BIGINT,
    captured_at TIMESTAMP,
    PRIMARY KEY (profile_id, source, metric, captured_at)
);

-- Track stats
CREATE TABLE stats.track_stats (
    track_id VARCHAR(64),
    source VARCHAR(32),
    metric VARCHAR(32),
    value BIGINT,
    captured_at TIMESTAMP
);
```

## Testing

```bash
# Run tests (uses real MongoDB test DB, no mocking)
pytest

# With coverage
pytest --cov=src --cov-report=html

# Specific test file
pytest tests/test_raw_processor.py
```

## Deployment

Version is controlled by `.version` file:
```bash
# Bump version
echo "1.2.3" > .version

# Jenkins picks up .version for image tagging
git add .version && git commit -m "Bump to 1.2.3"
```

## Helm Chart

```bash
# Deploy to dev
helm upgrade --install industry-proc \
  ./ops/helm/industry-data-processing \
  -n industry-proc \
  -f values-dev.yaml

# Deploy to prod
helm upgrade --install industry-proc \
  ./ops/helm/industry-data-processing \
  -n industry-proc \
  -f values-prod.yaml
```
