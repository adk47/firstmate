# TOOLS.md -- CTO Agent

## GitHub
- Read access to all Muso-AI repositories.
- **Write access is via branch + PR only** — you can author fixes in any Muso-AI
  repo you have push access to (verified at runtime by `cto-codex-coding`), but
  you NEVER merge and NEVER push to a default branch. A human merges after QA.
- **Base branch is determined at runtime** (`gh repo view Muso-AI/<repo> --json
  defaultBranchRef`), NOT from the Repository Map below — that table is a hint and
  can drift. core-backend/web-credits are `develop`, customer-api-mcp is `master`,
  hydra is `main`.
- **Key GitHub handles**: Serhii -> `liflovs`, Artem -> `Korpyc`, Mariia -> `azure-kirin`,
  Aaron -> `adk47`, Nick -> `nsollazzo`. Andrey Morskoy has left Muso. Verify anyone else
  in slack-people.json — only `current: true` entries are current staff.
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

## Trino Patterns
- All warehouse SQL runs on OVH Trino: `muso query "<SQL>"` (skill `muso-query-writer`)
- Bucket join pattern: critical for analytics -- understand before modifying
- Trino 479 running on ovh-node-6 (coordinator) + ovh-node-5 (workers)

## Data Model Expertise
- **Analytics worker architecture**: 3-layer pipeline (ingestion -> processing -> serving)
- **Priority system**: Tasks have priority levels that affect queue ordering
- **KEDA scaling**: Autoscaling based on queue depth for analytics workers

## Our email + analytics stack (replaces Klaviyo / Amplitude reads, stack swap Oct 2026)
- READ ONLY, via `bash /opt/hydra/scripts/muso-stack-read.sh` (run `coverage` first: it says what our stack holds today)
- Email: skill `muso-email` (send log + engagement in ClickHouse `messaging.email_events`, consent/suppressions in preferences, campaigns/lists in Listmonk)
- Product analytics: skill `muso-analytics` (event router query API = Amplitude's Dashboard API paths; ClickHouse `product_events`)
- Read from both while a stream overlaps, prefer ours, and name the source of every number

## Klaviyo (legacy; until each stream cuts over, marketing ~28 Oct)
- Email marketing platform — full access for template management, API integration, and engineering support
- API base: `https://a.klaviyo.com/api/`
- **Revision header required**: Always include `revision` header in API calls
- **OFF-LIMITS for cold outreach** — Klaviyo is for existing subscribers/customers ONLY
- Use for: template updates, Jinja blocks, API integration, flow debugging, webhook configuration
- Email open rates benchmark: 60-70% (Muso.AI performs well above industry average)
- Cross-reference with CMO agent for campaign strategy and list management

## Slack
- Bound channels: #engineering, #architecture, #eng-backend
- Use for: code review discussions, architecture decisions, sprint planning

## Andrey Working Rules
- Don't bluff -- he'll catch incomplete analysis. Investigate root cause thoroughly.
- Branch + PR for every code change (you never merge — a human does); a ClickUp ticket is good practice but not a gate for god-mode requesters (Nick/Aaron)
- Prefer bucket join pattern for analytics queries
- Be precise with data model references
