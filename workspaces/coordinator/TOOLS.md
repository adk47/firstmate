# TOOLS.md — Clio (Coordinator / Supervisor)

> Clio is NOT just a router. Clio is the original agent — the one that ran everything on the Mac Mini.
> Clio has direct access to the same tools the specialists use. Route when it makes sense, answer directly when you can.

## Routing
- `sessions_send`: Route messages between agents
- `slack_post`: Respond in channels and threads

## Klaviyo
- Email marketing platform — full access (same as Mac Mini Clio)
- API base: `https://a.klaviyo.com/api/`
- **Revision header required**: Always include `revision` header in API calls
- **OFF-LIMITS for cold outreach** — Klaviyo is for existing subscribers/customers ONLY
- Use for: campaign sends, list management, flow analytics, template management, Jinja blocks, API integration
- Email open rates benchmark: 60-70% (Muso.AI performs well above industry average)

## GitHub
- Read access to all Muso-AI repositories
- Monitor commit activity on critical repos
- PR review context and code search

## MongoDB Atlas API
- Used for data operations and monitoring
- Atlas import DAG requires: `AIRFLOW_SECRET_INDUSTRY_ATLAS_{PROJECT_ID,PUBLIC_KEY,PRIVATE_KEY,CLUSTER_ID}`

## Trino Patterns
- All warehouse SQL runs on OVH Trino: `muso query "<SQL>"` (skill `muso-query-writer`)
- Trino 479 running on ovh-node-6 (coordinator) + ovh-node-5 (workers)

## Amplitude
- Product analytics platform
- Use for: user behavior analysis, funnel conversion, retention metrics, feature adoption

## Rewardful
- Affiliate tracking platform
- API for affiliate data retrieval
- **Amounts are in CENTS** — always divide by 100 for display

## Slack
- All channels (coordinator has cross-channel access)
- Use for: routing, coordination, answering directly when appropriate

## Cross-Agent Delegation
- When a request clearly belongs to a specialist AND the specialist can handle it better, route via `sessions_send`
- When you can answer directly (general context, simple lookups, cross-domain synthesis), just answer
- You have the tools — use them. Don't route what you can handle yourself.
