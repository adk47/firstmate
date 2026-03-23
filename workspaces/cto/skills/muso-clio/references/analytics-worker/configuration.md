# Analytics Worker Configuration

## Environment Setup

### Prerequisites
- Python 3.11.9+
- PostgreSQL
- AWS credentials (SQS, S3)
- Platform API credentials

### Local Development

1. Clone the repository:
```bash
cd analytics-worker
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

4. Copy environment template:
```bash
cp .env.example .env
```

5. Configure environment variables

## Environment Variables

### Core
```
ENVIRONMENT=development
LOG_LEVEL=INFO
```

### AWS
```
AWS_REGION=us-west-2
AWS_ACCESS_KEY_ID=<key>
AWS_SECRET_ACCESS_KEY=<secret>
S3_BUCKET=muso-analytics-dev
```

### Queue URLs
```
QUEUE_SPOTIFY_HIGH=https://sqs.us-west-2.amazonaws.com/xxx/spotify-high-dev
QUEUE_SPOTIFY_MEDIUM=https://sqs.us-west-2.amazonaws.com/xxx/spotify-medium-dev
QUEUE_YOUTUBE_HIGH=https://sqs.us-west-2.amazonaws.com/xxx/youtube-high-dev
QUEUE_YOUTUBE_MEDIUM=https://sqs.us-west-2.amazonaws.com/xxx/youtube-medium-dev
QUEUE_RESULTS=https://sqs.us-west-2.amazonaws.com/xxx/results-dev
QUEUE_RESULTS_CATALOG=https://sqs.us-west-2.amazonaws.com/xxx/results-catalog-dev
```

### Database
```
DATABASE_URL=postgresql://user:pass@localhost:5432/analytics
```

### Platform APIs
```
SPOTIFY_CLIENT_ID=<id>
SPOTIFY_CLIENT_SECRET=<secret>
YOUTUBE_API_KEY=<key>
TIKTOK_SESSION_COOKIE=<cookie>
SHAZAM_API_KEY=<key>
```

## Running Workers

```bash
# Run specific source worker
python -m workers.spotify

# Run with specific queue
QUEUE_NAME=QUEUE_SPOTIFY_HIGH python -m workers.spotify

# Run all workers (docker-compose)
docker-compose up
```

## KEDA Autoscaling

```yaml
# ops/keda/scaledobject.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: analytics-worker-spotify
spec:
  scaleTargetRef:
    name: analytics-worker-spotify
  minReplicaCount: 1
  maxReplicaCount: 50
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: ${QUEUE_SPOTIFY_MEDIUM}
      queueLength: "5"
      awsRegion: us-west-2
```

## Docker Build

```dockerfile
# Dockerfile
FROM python:3.11.9-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .
CMD ["python", "-m", "workers.main"]
```

## Testing

```bash
# Run tests
pytest

# With coverage
pytest --cov=workers --cov-report=html

# Test specific platform
pytest tests/test_spotify.py
```

### Manual End-to-End Testing

The `test_scripts/` folder contains per-source test scripts for manual validation:

```bash
# Activate virtual environment
source venv/bin/activate

# Run as module (required)
python -m test_scripts.catalog_debug.spotify.spotify_artist_test
python -m test_scripts.catalog_debug.genius.genius_artist_test
python -m test_scripts.catalog_debug.soundcloud.soundcloud_test
```

These scripts are the primary debugging tool since automated E2E tests are unreliable due to proxy rotation randomness.

## Proxy Configuration (WebShare)

The service uses [WebShare](https://www.webshare.io/) for proxy rotation.

### Proxy Pool

| Setting | Value |
|---------|-------|
| Total Proxies | 5,000 |
| Refresh Cycle | Monthly ($346/mo) |
| Ideal Refresh | Weekly ($577/mo) |
| Countries | European only (Albania, Belgium, Switzerland, Germany, Ukraine, Sweden, Netherlands, Latvia, Poland) |

**Why European proxies?** Trial and error showed US and Asian IPs get blocked more frequently by streaming platforms. European countries with diversified subnets reduce blocking risk.

### Proxy File Format

Proxies are stored in `proxies.txt`:

```
username:password@proxy1.webshare.io:port
username:password@proxy2.webshare.io:port
...
```

Export from WebShare dashboard → regex replace → paste into `proxies.txt`

### Worker Proxy Rotation Logic

The worker implements custom rotation with blacklist tracking:

```python
# Simplified logic
class ProxyRotator:
    def __init__(self, proxies: list):
        self.proxies = proxies
        self.blacklist = {}  # {source: set(failed_proxies)}

    def get_proxy(self, source: str) -> str:
        available = [p for p in self.proxies
                     if p not in self.blacklist.get(source, set())]
        return random.choice(available)

    def mark_failed(self, proxy: str, source: str):
        # Cache failed proxy for this source during runtime
        if source not in self.blacklist:
            self.blacklist[source] = set()
        self.blacklist[source].add(proxy)
```

**Note**: Blacklist is in-memory only — resets when worker restarts. This prevents repeatedly hitting known-bad proxies for a specific source during a single worker lifecycle.

### Alternative: WebShare Rotating Endpoint

WebShare offers a `-rotate` endpoint that handles rotation automatically. Not currently used because:
- Custom logic allows per-source blacklist tracking
- More control over retry behavior

## Deployment

### Version Bumping

Every deployment requires incrementing the version in `.version` file:

```
1.0.175
```

Versioning convention:
- Patch (175 → 176): Minor fixes, config changes
- Minor (0 → 1): New source, significant refactoring
- Major (1 → 2): Architecture changes (only bumped once at production launch)

### Helm Configuration

Worker scaling is configured in `ops/helm/analytics-worker/`:

| File | Environment |
|------|-------------|
| `values.yaml` | Development |
| `values-prod.yaml` | Production |

Example configuration:

```yaml
workers:
  shazam:
    high_priority:
      min_replicas: 1
      max_replicas: 10
      resources:
        requests:
          cpu: 100m
          memory: 64Mi
        limits:
          cpu: 512m
          memory: 512Mi
    medium_priority:
      min_replicas: 1
      max_replicas: 25

  tiktok:
    high_priority:
      max_replicas: 3   # Reduced due to frequent blocks
    medium_priority:
      max_replicas: 17  # Reduced from 30

  # ... other sources
```

### KEDA Autoscaling

Workers scale based on SQS queue depth:

```yaml
# Triggered by SQS queue length
triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: ${QUEUE_SHAZAM_HIGH}
      queueLength: "300"  # 1 worker per 300 messages
```

### Jenkins CI/CD Pipeline

1. **Bump version** in `.version` file
2. **Push to main** → auto-deploys to dev
3. **Monitor** in `#cicd-notifications` Slack channel
4. **Approve prod deployment** by clicking approval link in Slack (2-hour timeout)

```
# Slack notification format
analytics-worker 1.0.175 deployed to dev
Please review changes and approve deploying to prod: [link]
```

### Testing PR on Dev

Before merging, you can deploy a PR branch to dev:

1. Go to Jenkins → Backend → analytics-worker → Pull Requests
2. Select your PR
3. Click "Build with Parameters" → "Deploy to Dev"

### Deployment Monitoring

After deployment, check CloudWatch dashboard:
- High priority queue visible messages (should be 0)
- Age of oldest message per queue
- Error logs per source
