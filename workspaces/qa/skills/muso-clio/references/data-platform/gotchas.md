# Data Platform Gotchas

## DAG Parse Errors

DAGs are parsed every 30 seconds. Parse errors break the entire DAG:

```python
# WRONG - import error crashes DAG parsing
from my_module import broken_function  # If this fails, DAG won't load

# CORRECT - defer imports to task execution
def my_task():
    from my_module import my_function
    return my_function()
```

## XCom Size Limits

XCom is stored in Airflow's metadata DB. Large data will fail:

```python
# WRONG - pushing large dataframe
context['ti'].xcom_push(key='data', value=large_df.to_dict())  # Will fail

# CORRECT - write to S3, push path
s3_path = f"s3://{bucket}/temp/{context['run_id']}/data.parquet"
large_df.to_parquet(s3_path)
context['ti'].xcom_push(key='data_path', value=s3_path)
```

## Catchup Behavior

By default, Airflow will backfill all missed runs:

```python
# DANGEROUS - will create 365 runs if DAG was paused for a year
with DAG('my_dag', catchup=True, ...) as dag:

# SAFE - only runs for current interval
with DAG('my_dag', catchup=False, ...) as dag:
```

## Timezone Confusion

Airflow uses UTC internally. Schedule intervals are in UTC:

```python
# This runs at 14:00 UTC, not local time!
schedule_interval='0 14 * * *'

# Use pendulum for timezone-aware scheduling
from pendulum import timezone
schedule_interval='0 14 * * *'  # Still UTC
# But access context['data_interval_start'] which is timezone-aware
```

## Spark Memory Issues

Spark jobs fail silently on memory issues:

```yaml
# WRONG - not enough memory for large joins
executor:
  memory: "2g"
  
# CORRECT - size for your data
executor:
  memory: "8g"
  # Also set memoryOverhead for off-heap
  memoryOverhead: "2g"
```

## S3 Eventual Consistency

S3 is eventually consistent. Immediate reads after writes may fail:

```python
# RISKY - write then immediately read
s3.put_object(Bucket=bucket, Key=key, Body=data)
result = s3.get_object(Bucket=bucket, Key=key)  # Might fail

# SAFER - add delay or use S3 strong consistency (default now)
# Or use versioned buckets
```

## Spark Partition Skew

Uneven partitions cause stragglers:

```python
# WRONG - one partition gets all the data
df.repartition(1).write.parquet(...)

# CORRECT - partition by a good key
df.repartition(200, "date").write.parquet(...)

# For skewed joins
df.hint("skew", "artist_id").join(...)
```

## Connection Pool Exhaustion

Too many tasks hitting the same DB:

```python
# WRONG - each task opens a connection
def task_1(): PostgresHook('db').run(...)
def task_2(): PostgresHook('db').run(...)
# 100 parallel tasks = 100 connections

# CORRECT - use connection pooling or limit parallelism
with DAG(..., max_active_tasks=10) as dag:  # Limit concurrent tasks
```

## Task Dependency Race Conditions

```python
# WRONG - external task sensor might miss the run
sensor = ExternalTaskSensor(
    external_dag_id='other_dag',
    # If other_dag runs at different time, this hangs forever
)

# CORRECT - specify execution_delta or execution_date_fn
sensor = ExternalTaskSensor(
    external_dag_id='other_dag',
    execution_delta=timedelta(hours=0),  # Same schedule
    mode='reschedule',  # Don't block worker
    timeout=3600,  # Fail after 1 hour
)
```

## Spark S3 Credentials

Spark needs AWS credentials configured:

```python
# WRONG - credentials not propagated
spark.read.parquet("s3a://bucket/path")  # AccessDenied

# CORRECT - use IAM role on EKS nodes
# Or explicitly set in SparkSession
spark = SparkSession.builder \
    .config("spark.hadoop.fs.s3a.aws.credentials.provider", 
            "com.amazonaws.auth.WebIdentityTokenCredentialsProvider") \
    .getOrCreate()
```

## DAG Naming Conventions

DAG IDs must be unique across the entire Airflow instance:

```python
# WRONG - generic name might conflict
dag_id='import_data'

# CORRECT - namespaced
dag_id='Run_Import_Qobuz'  # Prefix with Run_, category
```

## Retry vs Skip

Know when to retry vs skip:

```python
# Retry on transient failures
retries=3
retry_delay=timedelta(minutes=5)

# Skip on data issues (don't retry forever)
if not data:
    raise AirflowSkipException("No data for this interval")
```

## Pipeline Failure Monitoring

### Slack Alerts

**Channel:** `#pipeline-alerts`

All pipeline failures post to this channel with:
- Pipeline name
- Task that failed
- **Owner tagged** (Andre or Oleg depending on pipeline)

### Success Metrics

Some pipelines also post success metrics:

| Pipeline | Reports |
|----------|---------|
| Andre's LMC | Profiles/tracks/releases merged, linked, created |
| Oleg's SLA | Tasks sent to each capture queue |

### React Quickly to Failures

Failures in `#pipeline-alerts` require immediate attention because of dependency cascades.

## Pipeline Dependency Management

### Dependency Graph

Pipelines form a dependency graph - if parent fails, children don't run:

```
Import → Materialize → Calculate → Persist
           │
           └── If Import fails, nothing downstream runs
```

### Failure Impact

| Scenario | Impact |
|----------|--------|
| Parent fails | Children skip (no input data) |
| Parent fixed next day | Children run with next day's data |
| Result | **One day of missing data** in downstream tables |

### Critical Pipelines

**React immediately if these fail:**

| Pipeline | Consequence of Failure |
|----------|------------------------|
| `run_merge_catalog_analytics_maintenance_populate_track_daily_v2` | Analytics missing for that day |
| Andre's LMC pipeline | New entities not linked/merged |
| `Run_Import_Industry_DB` | No fresh MongoDB data for calculations |

### No Automatic Recovery

MWAA doesn't automatically retry failed pipelines for previous days. Options:
1. Fix issue, wait for next scheduled run
2. Manually trigger with specific execution date
3. Ask Andre to backfill if critical

## calcul Database Query Gotchas

### Always Filter by Partition

Most `calcul` tables are partitioned by date. **Always include partition filter:**

```sql
-- WRONG - scans entire table (expensive!)
SELECT * FROM calcul_prod.milestone_generation_history
LIMIT 100;

-- CORRECT - filter by partition
SELECT * FROM calcul_prod.milestone_generation_history
WHERE date = '2026-01-20'
LIMIT 100;
```

### Candidate vs Positive Tables

LMC tables come in pairs - don't confuse them:

| Table | Contains |
|-------|----------|
| `calc_link_profile` | ALL candidate pairs (most won't match) |
| `calc_link_profile_positive` | Only pairs that PASSED threshold |

Query positive tables for actual results, candidate tables for debugging.

### Missing Tables

If a calculation result isn't in Athena, it might not be exposed:
1. Check if table exists in `calcul_prod`
2. If not, **ask Andre** to create the Athena table
3. He can expose any Spark calculation output to Athena
