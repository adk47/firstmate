# Data Platform API & Interfaces

## DAG Triggering

### Orchestrator Pattern

The master orchestrator triggers downstream DAGs:

```python
# Run_Industry_Orchestrator_V2
# Triggers at 00:05 UTC daily

trigger_import >> trigger_materialize >> trigger_calculate >> trigger_persist
```

### Manual Triggering

```bash
# Via Airflow CLI
airflow dags trigger Run_Import_Qobuz

# With config
airflow dags trigger Run_Import_Qobuz --conf '{"date": "2024-01-15"}'

# Via Airflow UI
# Admin -> DAGs -> Click play button
```

## S3 Data Lake Structure

```
s3://muso-data-lake-{env}/
├── databaseslake/           # Raw imports
│   ├── mongodb/
│   │   ├── professionals/
│   │   ├── tracks/
│   │   └── albums/
│   ├── rds/
│   │   ├── core/
│   │   ├── analytics/
│   │   └── stats/
│   └── streaming/
│       ├── spotify/
│       ├── qobuz/
│       └── audiomack/
│
├── materialize_v2/          # Transformed contracts
│   ├── professionals/
│   ├── tracks/
│   ├── albums/
│   └── stats/
│
└── calc_athena/             # Calculation outputs
    ├── default/
    ├── lmc/
    └── olap/
```

## Spark Job Submission

```python
# Using SparkKubernetesOperator
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator

calculate_task = SparkKubernetesOperator(
    task_id='calculate_default',
    namespace='spark',
    application_file='spark/default_calculation.yaml',
    kubernetes_conn_id='kubernetes_default',
    do_xcom_push=True,
)
```

## Database Access Patterns

### PostgreSQL (via Airflow hooks)

```python
from airflow.providers.postgres.hooks.postgres import PostgresHook

def extract_profiles(**context):
    hook = PostgresHook(postgres_conn_id='core_db')
    df = hook.get_pandas_df("""
        SELECT id, display_name, neptune_professional_id
        FROM profiles
        WHERE updated_at > %(since)s
    """, parameters={'since': context['data_interval_start']})
    return df
```

### MongoDB (via PyMongo)

```python
from pymongo import MongoClient

def extract_from_mongo(**context):
    client = MongoClient(Variable.get('MONGO_URI'))
    db = client['industry_db']
    
    docs = db.professionals.find({
        'updated_at': {'$gte': context['data_interval_start']}
    })
    return list(docs)
```

## Output Destinations

### Elasticsearch

```python
from elasticsearch import Elasticsearch

def index_profiles(profiles):
    es = Elasticsearch([Variable.get('ES_HOST')])
    
    for profile in profiles:
        es.index(
            index='profiles',
            id=profile['id'],
            body=profile,
        )
```

### SQS Notifications

```python
import boto3

def send_notifications(events):
    sqs = boto3.client('sqs')
    
    for event in events:
        sqs.send_message(
            QueueUrl=Variable.get('NOTIFICATIONS_QUEUE'),
            MessageBody=json.dumps(event),
        )
```

## Monitoring

### Airflow Metrics

- DAG run duration
- Task success/failure rates
- SLA misses
- Queue depth

### Spark Metrics

- Job duration
- Executor count
- Memory usage
- Shuffle read/write

Access via:
- Airflow UI: `https://airflow.muso.ai`
- Spark UI: Kubernetes port-forward to driver pod
- CloudWatch: Log groups for each component
