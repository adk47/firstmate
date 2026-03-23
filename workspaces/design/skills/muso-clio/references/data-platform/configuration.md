# Data Platform Configuration

## Environment Setup

### Prerequisites
- Python 3.11+
- Docker (for local Airflow)
- kubectl configured for EKS
- AWS CLI configured

### Local Development

1. Clone the repository:
```bash
cd platform-data-processing
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

4. Start local Airflow:
```bash
docker-compose up -d
```

5. Access Airflow UI: `http://localhost:8080`

## Airflow Configuration

### airflow.cfg Key Settings

```ini
[core]
executor = KubernetesExecutor
dags_folder = /opt/airflow/dags
parallelism = 32
max_active_tasks_per_dag = 16

[kubernetes]
namespace = airflow
worker_container_repository = muso/airflow
worker_container_tag = 2.10.3

[scheduler]
dag_dir_list_interval = 60
min_file_process_interval = 30
```

### Connections (Airflow Admin -> Connections)

| Connection ID | Type | Host |
|---------------|------|------|
| `core_db` | PostgreSQL | db-core-backend-{env}.muso.ai |
| `analytics_db` | PostgreSQL | analytics-{env} cluster |
| `stats_db` | PostgreSQL | platform-stats-{env} cluster |
| `mongo_atlas` | MongoDB | product-api-{env}.mongodb.net |
| `elasticsearch` | HTTP | es-{env}.muso.ai |
| `aws_default` | AWS | (uses IAM role) |

### Variables (Airflow Admin -> Variables)

| Variable | Description |
|----------|-------------|
| `ENVIRONMENT` | dev/staging/prod |
| `S3_DATA_LAKE_BUCKET` | Data lake bucket name |
| `MONGO_URI` | MongoDB connection string |
| `SLACK_WEBHOOK` | Alert notifications |
| `SPARK_DRIVER_MEMORY` | Default: 4g |
| `SPARK_EXECUTOR_MEMORY` | Default: 8g |

## Spark Configuration

### spark-defaults.conf

```properties
spark.master                     k8s://https://kubernetes.default.svc
spark.kubernetes.namespace       spark
spark.kubernetes.container.image muso/spark:4.0.0
spark.driver.memory              4g
spark.executor.memory            8g
spark.executor.instances         3
spark.sql.shuffle.partitions     200
```

### Spark Job YAML Template

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: industry-calculation
  namespace: spark
spec:
  type: Python
  mode: cluster
  image: muso/spark:4.0.0
  mainApplicationFile: s3a://muso-spark-jobs/calculate_default.py
  sparkVersion: "4.0.0"
  driver:
    cores: 2
    memory: "4g"
    nodeSelector:
      node-group: platform-industry-calculation
  executor:
    cores: 2
    instances: 5
    memory: "8g"
    nodeSelector:
      node-group: platform-industry-calculation
```

## EKS Node Groups

| Node Group | Instance Type | Min | Max | Purpose |
|------------|---------------|-----|-----|---------|
| platform-industry-calculation | r5.2xlarge | 0 | 10 | Default calcs |
| platform-industry-calculation-lmc | r5.4xlarge | 0 | 5 | LMC calcs |
| platform-industry-olap | r5.2xlarge | 0 | 5 | OLAP calcs |
| platform-industry-rt-calculations | r5.xlarge | 1 | 3 | Real-time |

## Testing

```bash
# Test DAG syntax
python -c "from dags.my_dag import dag"

# Run DAG locally
airflow dags test Run_Import_Qobuz 2024-01-15

# Test single task
airflow tasks test Run_Import_Qobuz extract_data 2024-01-15
```

## Deployment

```bash
# Sync DAGs to S3
aws s3 sync dags/ s3://muso-airflow-dags-{env}/dags/

# Restart scheduler to pick up changes
kubectl rollout restart deployment airflow-scheduler -n airflow
```
