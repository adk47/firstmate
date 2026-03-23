# Data Platform Patterns

## DAG Pattern

```python
# dags/import_qobuz.py
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.amazon.aws.operators.s3 import S3CreateObjectOperator

default_args = {
    'owner': 'data-team',
    'depends_on_past': False,
    'email_on_failure': True,
    'email': ['data-alerts@muso.ai'],
    'retries': 3,
    'retry_delay': timedelta(minutes=5),
}

with DAG(
    'Run_Import_Qobuz',
    default_args=default_args,
    description='Import Qobuz streaming data',
    schedule_interval='0 14 * * *',  # Daily at 14:00 UTC
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=['import', 'streaming'],
) as dag:
    
    extract = PythonOperator(
        task_id='extract_data',
        python_callable=extract_qobuz_data,
    )
    
    transform = PythonOperator(
        task_id='transform_data',
        python_callable=transform_data,
    )
    
    load = S3CreateObjectOperator(
        task_id='load_to_s3',
        s3_bucket='{{ var.value.S3_DATA_LAKE_BUCKET }}',
        s3_key='databaseslake/streaming/qobuz/{{ ds }}/data.parquet',
        data='{{ ti.xcom_pull(task_ids="transform_data") }}',
    )
    
    extract >> transform >> load
```

## Orchestrator Pattern

```python
# dags/industry_orchestrator.py
from airflow import DAG
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.sensors.external_task import ExternalTaskSensor

with DAG('Run_Industry_Orchestrator_V2', ...) as dag:
    
    # Trigger imports in parallel
    import_mongo = TriggerDagRunOperator(
        task_id='trigger_import_mongo',
        trigger_dag_id='Run_Import_Industry_DB',
        wait_for_completion=True,
    )
    
    import_qobuz = TriggerDagRunOperator(
        task_id='trigger_import_qobuz',
        trigger_dag_id='Run_Import_Qobuz',
        wait_for_completion=True,
    )
    
    # Wait for all imports
    wait_imports = ExternalTaskSensor(
        task_id='wait_for_imports',
        external_dag_id='Run_Import_*',
        mode='reschedule',
    )
    
    # Then materialize
    materialize = TriggerDagRunOperator(
        task_id='trigger_materialize',
        trigger_dag_id='Run_Materialize_All',
        wait_for_completion=True,
    )
    
    # Then calculate
    calculate = TriggerDagRunOperator(
        task_id='trigger_calculate',
        trigger_dag_id='Run_Calculate_Industry_DB_Default',
        wait_for_completion=True,
    )
    
    [import_mongo, import_qobuz] >> wait_imports >> materialize >> calculate
```

## Spark Job Pattern

```python
# spark/calculate_default.py
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

def main():
    spark = SparkSession.builder \
        .appName("IndustryCalculation") \
        .getOrCreate()
    
    # Read from S3
    profiles = spark.read.parquet(
        "s3a://muso-data-lake/materialize_v2/professionals/"
    )
    
    tracks = spark.read.parquet(
        "s3a://muso-data-lake/materialize_v2/tracks/"
    )
    
    # Calculate aggregations
    profile_stats = tracks.groupBy("artist_id").agg(
        F.count("*").alias("track_count"),
        F.sum("streams").alias("total_streams"),
        F.avg("streams").alias("avg_streams"),
    )
    
    # Join and enrich
    result = profiles.join(
        profile_stats,
        profiles.id == profile_stats.artist_id,
        "left"
    )
    
    # Write output
    result.write \
        .mode("overwrite") \
        .parquet("s3a://muso-data-lake/calc_athena/default/profile_stats/")
    
    spark.stop()

if __name__ == "__main__":
    main()
```

## Incremental Load Pattern

```python
def extract_incremental(**context):
    """Extract only records changed since last run."""
    hook = PostgresHook(postgres_conn_id='core_db')
    
    # Use data_interval_start/end for incremental
    df = hook.get_pandas_df("""
        SELECT * FROM profiles
        WHERE updated_at >= %(start)s
          AND updated_at < %(end)s
    """, parameters={
        'start': context['data_interval_start'],
        'end': context['data_interval_end'],
    })
    
    return df
```

## Idempotent Write Pattern

```python
def write_to_destination(data, partition_key, **context):
    """Write with partition-based idempotency."""
    s3_path = f"s3://{bucket}/data/{partition_key}/"
    
    # Overwrite the partition
    data.write \
        .mode("overwrite") \
        .partitionBy("date") \
        .parquet(s3_path)
    
    # Same run with same data = same result
```

## Error Handling Pattern

```python
from airflow.exceptions import AirflowFailException, AirflowSkipException

def process_with_error_handling(**context):
    try:
        result = do_processing()
        
        if not result:
            raise AirflowSkipException("No data to process")
        
        return result
        
    except ConnectionError as e:
        # Retry-able error
        raise AirflowFailException(f"Connection failed: {e}")
        
    except ValueError as e:
        # Skip on bad data
        context['ti'].xcom_push(key='skipped_reason', value=str(e))
        raise AirflowSkipException(f"Invalid data: {e}")
```

## XCom Pattern

```python
# Push data
def extract(**context):
    data = fetch_data()
    context['ti'].xcom_push(key='extracted_data', value=data)

# Pull data
def transform(**context):
    data = context['ti'].xcom_pull(
        task_ids='extract',
        key='extracted_data'
    )
    return transform_data(data)
```

## Pipeline Development Workflow

**MWAA cannot run locally.** All testing happens in the dev environment.

### Development Steps

```
1. Create feature branch
2. Modify/create pipeline in src/merge/ or src/export_dags/
3. Deploy to dev: ./deploy.sh dev
4. Test in dev MWAA (green banner = dev)
5. Fix issues, redeploy to dev
6. Deploy to prod: ./deploy.sh prod
```

### Environment Identification

| Environment | Visual Indicator |
|-------------|------------------|
| Production | No banner |
| Development | **Green banner at top of Airflow UI** |

### Deployment Script

```bash
# deploy.sh syncs to S3 - MWAA watches this bucket
aws s3 sync ./dags s3://platform-data-processing-lake-${ENV}/dags/
```

**No CI/CD exists for platform pipelines** - deployment is manual via S3 sync.

## Persist Mechanism

Data flows from Oleg's calculations on S3 to Aurora/MongoDB via Andre's persist pipelines.

### Triggering Persist

```python
persist_task = TriggerDagRunOperator(
    task_id='persist_track_daily',
    trigger_dag_id='run_persist_stats',
    conf={
        'format': 'parquet',
        's3_location': 's3://bucket/calc_athena/track_daily/',
        'destination_table': 'track_daily',
        'bucket_by': 'date',
        'primary_keys': ['track_id', 'date'],
        'write_mode': 'upsert'
    }
)
```

### Write Modes

| Mode | Behavior |
|------|----------|
| `upsert` | Update if primary key exists, insert if not |
| `append` | Always insert (for history tables) |
| `overwrite` | Replace entire table |

### Transactionality Pattern

**Problem:** Prevent codebase from using incomplete data during pipeline execution.

**Solution:** Update config table ONLY at pipeline end:

```python
# Pipeline structure:
# 1. calcul_* tasks (compute on S3)
# 2. persist_* tasks (write to Aurora)
# 3. config_update task (mark date complete) ← LAST

def update_config(**context):
    """Only runs after ALL persists succeed."""
    hook = PostgresHook('stats_db')
    hook.run("""
        UPDATE stats_config
        SET latest_date = %(date)s
        WHERE key = 'track_daily'
    """, parameters={'date': context['ds']})
```

**Codebase reads `latest_date` from config** - until updated, it uses previous day's data.

## External Partner Data Onboarding

### Workflow for New Data Sources

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Partner provides data                                     │
│    - S3 bucket access OR                                     │
│    - SFTP credentials                                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Ask Andre to create Athena tables                         │
│    - He handles raw → parquet conversion                     │
│    - Creates database: platform-{partner}-bi-prod            │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Exploratory queries (Oleg)                                │
│    - Understand table structure                              │
│    - Check data quality and completeness                     │
│    - Identify useful fields                                  │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Create automated pipeline                                 │
│    - Map partner ISRCs to Muso tracks                        │
│    - Aggregate metrics                                       │
│    - Send to industry processing or direct DB insert         │
└─────────────────────────────────────────────────────────────┘
```

### Current Partner Databases

| Partner | Athena Database | Data Type |
|---------|-----------------|-----------|
| Anghami | `platform-anghami-bi-prod` | Streaming stats |
| Qobuz | `platform-qobuz-bi-prod` | Streaming stats |
| MLC | `platform-industry-mlc-bi-prod` | Recording identifiers |
| Audiomack | `platform-industry-audiomack-bi-prod` | Streaming stats |
| Zyte | `platform-industry-zyteig-bi-prod` | Scraped analytics data (Spotify streams, Instagram video/streams) |

### Database Naming Convention

Some partner databases only have `prod` (no `dev`) because partners only provide production data:

```python
# In merge_config.py
DATABASES = {
    'anghami': 'platform-anghami-bi-prod',  # No env suffix - always prod
    'stats': f'platform-stats-{ENV}',        # Has env suffix
}
```

## Create Table Task Group Pattern

Oleg's abstraction for table recreation in pipelines:

```python
def get_create_table_task_group(
    table_name: str,
    select_sql: str,
    s3_location: str,
    partition_cols: list = None
) -> TaskGroup:
    """
    Creates task group that:
    1. Drops old table (metastore + S3)
    2. Creates new table from SELECT
    """
    with TaskGroup(f'create_{table_name}') as group:
        start = EmptyOperator(task_id='start')

        drop = PythonOperator(
            task_id='drop_table',
            python_callable=drop_athena_table,
            op_kwargs={'table': table_name, 's3_path': s3_location}
        )

        create = AthenaOperator(
            task_id='create_table',
            query=f"""
                CREATE TABLE {table_name}
                WITH (
                    external_location = '{s3_location}',
                    format = 'PARQUET'
                )
                AS {select_sql}
            """
        )

        start >> drop >> create

    return group
```

**Why delete + create instead of INSERT OVERWRITE?**
- Athena doesn't support UPDATE/DELETE
- Cleaner than managing partitions manually
- S3 cleanup prevents orphaned files
