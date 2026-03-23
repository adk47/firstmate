# Industry Data Processing Monitoring

This doc captures **how we monitor** the `industry-data-processing` service (API + workers) and what signals matter.

## Scope

- **API**: response codes, latency distribution (P99), request volume, outliers
- **Workers / SQS**: queue depth by priority and stage (raw/catalog/analytics), processing backlogs, DLQs

## CloudWatch metrics (API)

Track at least:
- **Response codes**: 2xx/4xx/5xx rate
- **Latency**: average + **P99** + max
- **Volume**: requests/min

### Observations from KT (2026-01-28)

From `skills/muso-clio/references/kt/2026-01-28_industry-processing-1.md`:
- Example period discussed: **P99 ~187ms**, **avg ~20ms**, **max ~8s** (outliers). Volume described as **~100k requests / 15 min** (~6–7k/min).

### Outliers (why “max” can spike)

Also from the KT session:
- “Max” latency spikes are often outliers caused by **very large profiles** + **complex queries** (e.g., sorts/searches on huge result sets).
- You can’t fully eliminate outliers; treat **P99 trending up** as the stronger signal for regressions.

## CloudWatch dashboards

### Main dashboards (names + purpose)

| Dashboard | Purpose | Link |
|---|---|---|
| `core-backend-sqs-prod` | SQS queue processing (esp. analytics) | TODO |
| `core-backend-api-prod` | Core-backend services, ECS, RDS, Redis | TODO |
| `industry-data-processing-prod` | Industry-proc workers, API, EKS | TODO |
| `data-capture` | Data-capture services, logs, EKS | TODO |
| `analytics` | Analytics-capture services, logs, EKS | TODO |
| `platform-data-processing-performance-prod` | Platform-data-processing metrics | TODO |

### CloudWatch alarms

CloudWatch alarms follow the naming pattern: `[env][service]`.

Examples:
- `[prod][core]` — Core services
- `[prod][user-analytics]` — User analytics

## SQS queue monitoring

This service uses **priority queues** and **pipeline stage queues** (raw → catalog → analytics).

### What to monitor

- **Queue depth** per queue (high vs normal)
- **Age of oldest message** (if available) / backlog growth rate
- **Worker concurrency** (KEDA/HPA behavior) and error rates
- **DLQ depth** (should generally be 0; investigate any sustained non-zero)

### Thresholds / alerting (TODO)

Fill in with the actual configured thresholds and intended behavior:
- Alert thresholds currently configured: TODO
- Desired targets / “SLA” for queue drain times: TODO

## DLQ handling (TODO)

Document the real procedure (don’t guess):
- Where DLQs live (names)
- How we inspect messages
- When/how we replay messages
- When to create an incident vs manual fix

## Notion-derived targets (needs citations)

These were reported as found in Notion (add the Notion page URLs + titles):
- SLA target: **99.9% availability**, **99.9% of profile calls within 1 second**
- Typical latency: **~0.5s average** (P99 varies)
- Alerting note: “Not all system critical components like RDS and API health have alerts”
- ECS console (prod): `https://us-west-2.console.aws.amazon.com/ecs/v2/clusters/core-prod/services`
