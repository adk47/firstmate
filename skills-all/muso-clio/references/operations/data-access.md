# Data Access & Secret Hygiene

How to safely access Muso.AI databases and manage credentials.

## Golden Rules

1. **Never store secrets in code, docs, or repos**
2. **Use read-only credentials for analytics/exports**
3. **All access via SSH tunnels in production**
4. **Rotate keys periodically** (currently: 2 private keys - dev/prod)

---

## Environment Variable Naming Convention

Use these standardized names in tools and scripts:

```bash
# PostgreSQL - Core Backend
MUSO_DB_CORE_HOST=
MUSO_DB_CORE_PORT=5432
MUSO_DB_CORE_USER=
MUSO_DB_CORE_PASSWORD=
MUSO_DB_CORE_NAME=platform_core_backend_export_prod

# PostgreSQL - Platform Stats (Aurora)
MUSO_DB_STATS_HOST=
MUSO_DB_STATS_PORT=5432
MUSO_DB_STATS_USER=
MUSO_DB_STATS_PASSWORD=
MUSO_DB_STATS_NAME=platform_stats

# PostgreSQL - Analytics
MUSO_DB_ANALYTICS_HOST=
MUSO_DB_ANALYTICS_PORT=5432
MUSO_DB_ANALYTICS_USER=
MUSO_DB_ANALYTICS_PASSWORD=
MUSO_DB_ANALYTICS_NAME=analytics

# MongoDB Atlas
MUSO_MONGO_URI=mongodb+srv://...
MUSO_MONGO_DB_INDUSTRY=platform_industry_DB_industry_prod
MUSO_MONGO_DB_BI=platform_industry_BI_prod

# Elasticsearch
MUSO_ES_HOST=

# Athena
MUSO_ATHENA_WORKGROUP=growth_dev
MUSO_ATHENA_OUTPUT_BUCKET=
```

---

## SSH Tunnel Setup

All database access in production requires SSH tunneling.

### Prerequisites

1. Obtain SSH private key from secure storage (Notion DevOps docs or team)
2. Two keys exist: `dev` and `prod`
3. Keys are shared among engineers (rotation needed)

### Tunnel Commands

```bash
# MongoDB tunnel (from Notion common commands)
ssh -i ~/.ssh/muso-prod.pem -L 27017:localhost:27017 ec2-user@<bastion-host>

# PostgreSQL tunnel
ssh -i ~/.ssh/muso-prod.pem -L 5432:<rds-endpoint>:5432 ec2-user@<bastion-host>

# Keep tunnel alive
ssh -i ~/.ssh/muso-prod.pem -N -L 5432:<rds-endpoint>:5432 ec2-user@<bastion-host>
```

### Connection via Tunnel

```bash
# After tunnel is established
psql -h localhost -p 5432 -U $MUSO_DB_CORE_USER -d $MUSO_DB_CORE_NAME

# MongoDB
mongosh "mongodb://localhost:27017/$MUSO_MONGO_DB_INDUSTRY"
```

---

## Recommended Read-Only Roles

Create dedicated read-only users for analytics/export work:

### PostgreSQL

```sql
-- Create read-only role
CREATE ROLE muso_readonly;
GRANT CONNECT ON DATABASE platform_stats TO muso_readonly;
GRANT USAGE ON SCHEMA public TO muso_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO muso_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO muso_readonly;

-- Create user for business analyst tools
CREATE USER oleg_biz_analyst WITH PASSWORD '<secure-password>';
GRANT muso_readonly TO oleg_biz_analyst;

-- Restrict to specific tables if needed
REVOKE SELECT ON users FROM oleg_biz_analyst;  -- No PII access
```

### MongoDB

```javascript
// Create read-only user
db.createUser({
  user: "oleg_readonly",
  pwd: "<secure-password>",
  roles: [
    { role: "read", db: "platform_industry_DB_industry_prod" }
  ]
});
```

---

## Secret Storage Locations

| Secret Type | Current Location | Recommended |
|-------------|------------------|-------------|
| SSH Keys | Notion + local | AWS Secrets Manager |
| DB Passwords | Notion/local | AWS SSM Parameter Store |
| API Keys | .env files | AWS Secrets Manager |
| Terraform secrets | terraform.tfvars | SSM + terraform data sources |

### Retrieving from AWS SSM (Future)

```bash
# Get secret from SSM
aws ssm get-parameter --name "/muso/prod/db/stats/password" --with-decryption --query "Parameter.Value" --output text

# Set as env var
export MUSO_DB_STATS_PASSWORD=$(aws ssm get-parameter --name "/muso/prod/db/stats/password" --with-decryption --query "Parameter.Value" --output text)
```

---

## Trino on OVH (replaces Athena, 2026-04-25)

AWS Athena, Glue, and workgroups are retired. All queries now go to Trino on OVH (HMS + Hive on OVH S3 IO + PostgreSQL connectors for live PG).

| Catalog | Backed by | Equivalent old Athena DB |
|---------|-----------|--------------------------|
| `hive."platform-industry-bi-prod"` | OVH S3 IO + HMS | `"platform-industry-bi-prod"` (matvw_*) |
| `hive.audit` | OVH S3 IO + HMS | `"audit-prod"` |
| `hive."platform-industry-mlc-bi-prod"` | OVH S3 IO + HMS | `"platform-industry-mlc-bi-prod"` (MLC raw; bare `hive.mlc` does NOT exist) |
| `hive."platform-data-merging-catalog-prod"` | OVH S3 IO + HMS | `"platform-data-merging-catalog-prod"` |
| `postgresql_core.public` | OVH PG node-18 (live) | `"platform-core-backend-export-prod"` |
| `postgresql_analytics.public` | OVH PG node-18 | `bi` |
| `postgresql_industry.public` | OVH PG node-18 (⚠️ SELECT grant pending) | `"platform-industry-calculations-export-prod"` |
| `postgresql_stats.public` | OVH PG node-18 | Aurora `platform-stats` |
| `postgresql_olap.public` | OVH PG node-18 | Aurora `platform-industry-olap` |

### Running Queries

```bash
# Use the trino-query.sh wrapper — auto-rewrites legacy Athena DB names
bash /opt/hydra/scripts/trino-query.sh \
  "SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_profile LIMIT 10"

# Old Athena queries still work — wrapper rewrites the DB names
bash /opt/hydra/scripts/trino-query.sh \
  'SELECT * FROM "platform-industry-bi-prod".matvw_catalog_profile LIMIT 10'

# Direct Trino CLI from any pod that can reach trino.data-processing.svc.cluster.local
kubectl exec -n data-processing trino-coordinator-0 -- trino \
  --catalog hive --schema default \
  --execute "SELECT count(*) FROM matvw_catalog_track WHERE is_deleted=false"

# Discovery
bash /opt/hydra/scripts/trino-query.sh "SHOW CATALOGS"
bash /opt/hydra/scripts/trino-query.sh "SHOW SCHEMAS FROM hive"
bash /opt/hydra/scripts/trino-query.sh "SHOW TABLES FROM hive."platform-industry-bi-prod""
bash /opt/hydra/scripts/trino-query.sh "DESCRIBE hive."platform-industry-bi-prod".matvw_catalog_profile"
```

### What changed from Athena CLI?
- ❌ `aws athena start-query-execution --workgroup primary --profile muso-flagship-readonly --region us-west-2`
  ✅ `trino-query.sh` (no profile, no region, no workgroup)
- ❌ `aws athena get-query-execution --query-execution-id <ID>` (poll for results)
  ✅ Trino returns synchronously
- ❌ Workgroups (`primary`, `data-engineering`, `growth-dev`)
  ✅ Single Trino cluster, no workgroups
- ❌ `aws glue get-databases` (91 Glue DBs)
  ✅ `bash /opt/hydra/scripts/trino-query.sh "SHOW SCHEMAS FROM hive"`

---

## PII Handling Policy

### What is PII in Muso.AI?

| Data | Classification | Handling |
|------|---------------|----------|
| Email addresses | PII | Never export, mask in queries |
| Auth0 IDs | PII | Never expose externally |
| User names | PII | Aggregate only |
| Payment info | PII/PCI | No direct access |
| Profile names | Public | OK to export |
| Track/album data | Public | OK to export |
| Stream counts | Public | OK to export |

### Query Guidelines

```sql
-- BAD: Exposes PII
SELECT email, user_id, subscription_status FROM users;

-- GOOD: Aggregated, no PII
SELECT subscription_status, COUNT(*) as user_count
FROM users
GROUP BY subscription_status;

-- GOOD: Masked
SELECT 
  CONCAT(LEFT(email, 2), '***@***', RIGHT(email, 4)) as masked_email,
  subscription_status
FROM users;
```

---

## Audit Logging

All database queries should be logged for compliance:

1. **Athena**: Automatic query history in workgroup
2. **PostgreSQL**: Enable `log_statement = 'all'` for audit users
3. **Tool usage**: MCP tools should log query + user + timestamp

### Log Format (for tools)

```json
{
  "timestamp": "2025-01-16T10:30:00Z",
  "user": "jay",
  "tool": "clio_sql_query",
  "database": "platform_stats",
  "query_hash": "abc123",
  "rows_returned": 150,
  "duration_ms": 230
}
```

---

## Useful SQL Queries

### Finding Merged Tracks (Stream Count Investigation)

Source: KT 2026-02-04

When users report sudden stream count decreases, check for merged tracks in the last 360 days:

```sql
-- Find merged tracks from last 360 days
-- Useful for explaining sudden stream count changes
-- Run via Trino against or postgresql_core.public

SELECT
    t.id AS track_id,
    t.name AS track_name,
    t.merged_to_id,
    t.merged_at,
    -- Stream counts before/after merge if available
    t.streams AS current_streams
FROM tracks t
WHERE t.merged_at > CURRENT_DATE - INTERVAL '360' DAY
  AND t.merged_to_id IS NOT NULL
ORDER BY t.merged_at DESC
LIMIT 100;
```

**Common findings:**
- Two tracks with similar stream counts (within 30%) merged
- Single release + album version merged
- Duplicate ISRCs from different releases merged

**Note**: Stream merge threshold changed from 10,000 to 1,000 as of 2026-02-04.

---

## Key Contacts

| Area | Expert | Notes |
|------|--------|-------|
| Core Backend DB | Serhii | Users, payments, subscriptions |
| Data Pipelines | Andre | Airflow, 88 pipelines |
| Growth Services | Si | Team lead, full-stack |
| Catalog/Platform | (Oleg) | Transitioning knowledge |
| DevOps/Infra | Notion docs | Ivan's documentation |
