# TOOLS.md -- CTO Agent

## GitHub
- Read access to all Muso-AI repositories
- **Key GitHub handles**: Serhii -> liflovs, Andrey -> (verify in slack-people.json)
- **Workflow**: Always ClickUp ticket + branch + PR. No exceptions.
- Monitor: commit activity on critical repos (core-backend, web-credits, industry-data-processing, analytics-worker)

## Repository Map
| Image | Repo | Prod Branch |
|-------|------|-------------|
| muso/core-backend | core-backend | develop |
| muso/web-credits | web-credits | develop |
| muso/frontend | website | main |
| muso/web-encore | web-encore | develop |
| muso/ai-chat-api | ai-chat-service | main |
| muso/customer-api-mcp | customer-api-mcp | master |
| muso/feed-service | feed-service | main |
| muso/industry-data-processing | industry-data-processing | main |
| muso/analytics-worker | analytics-worker | main |
| muso/analytics-controller | analytics-controller | main |
| muso/render-service | render-service | develop |

## MongoDB Atlas API
- Used for data operations and monitoring
- Atlas import DAG requires: `AIRFLOW_SECRET_INDUSTRY_ATLAS_{PROJECT_ID,PUBLIC_KEY,PRIVATE_KEY,CLUSTER_ID}`

## Athena/Trino Patterns
- AWS Athena queries being migrated to Trino on OVH
- Bucket join pattern: critical for analytics -- understand before modifying
- Trino 479 running on ovh-node-6 (coordinator) + ovh-node-5 (workers)

## Data Model Expertise
- **Analytics worker architecture**: 3-layer pipeline (ingestion -> processing -> serving)
- **Priority system**: Tasks have priority levels that affect queue ordering
- **KEDA scaling**: Autoscaling based on queue depth for analytics workers

## Slack
- Bound channels: #engineering, #architecture, #eng-backend
- Use for: code review discussions, architecture decisions, sprint planning

## Andrey Working Rules
- Don't bluff -- he'll catch incomplete analysis. Investigate root cause thoroughly.
- Always provide: ClickUp ticket + branch + PR for any code change
- Prefer bucket join pattern for analytics queries
- Be precise with data model references
