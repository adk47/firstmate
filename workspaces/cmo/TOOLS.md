# TOOLS.md — CMO Agent

_All tools the CMO agent has access to. See individual skill files for full API docs._

---

## Connected — Read & Write

### Klaviyo
- Email/SMS marketing platform
- API base: `https://a.klaviyo.com/api/`
- Auth: `Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN` + `revision: 2025-01-15`
- Access: **Read/Write** (Fede + Aaron only)
- **OFF-LIMITS for cold outreach** — existing subscribers/customers ONLY
- Use for: campaigns, flows, lists, segments, profiles, templates, analytics
- Skill: `muso-klaviyo`

### GoHighLevel (GHL)
- CRM, pipeline, outreach, email sending
- Access: **Full read/write** (god mode)
- Use for: B2B pipeline management, opportunity stages, contact management, email sends
- Pipelines: B2B-Ads-Clio (`GeSt85TueSvJ0SNFZXfQ`)
- Skill: referenced in `muso-outreach-*` (B2B Ads location) and `muso-winback-*` (Win Back location, separate API key `$GHL_WINBACK_API_KEY`)

### n8n
- Workflow automation platform
- API base: `$N8N_BASE_URL` → `https://musoai.app.n8n.cloud`
- Auth: `X-N8N-API-KEY: $N8N_API_KEY` (REST) / `Bearer $N8N_MCP_KEY` (MCP)
- Access: **Full read/write** (god mode)
- MCP tools: `search_workflows`, `execute_workflow`, `get_workflow_details`
- Skill: `muso-n8n`

### ClickUp
- Task/project management
- Auth: `$CLICKUP_API_KEY`
- Access: **Read/Write** (specific spaces — TBD which ones)
- Default list: Development Priorities (ID: `901214992012`)
- Team ID: `2283334`
- Skill: `muso-clickup` (currently configured as read-only — needs update)

### DocuSign
- eSignature / contracts
- Auth: JWT Grant (`$DOCUSIGN_INTEGRATION_KEY`, `$DOCUSIGN_RSA_KEY_FILE`, etc.)
- Base URI: `https://na3.docusign.net`
- Access: **Read/Write** (Fede + Aaron only)
- Skill: `muso-docusign`

### Google Sheets
- Lead lists, data bridges, tracking
- Auth: Google service account / OAuth
- Use for: outreach lead lists, win-back tracking, activity logging
- Skill: referenced in `muso-outreach-engine`, `muso-winback-engine`

### Gmail
- Email sending/reading (a@muso.ai, f@muso.ai)
- Access: via Clio routing (`sessions_send` to Clio) or direct API
- Primary send address: `a@muso.ai` (CEO-level outreach)
- Alt addresses: `f@muso.ai`, `ak@muso.ai`, `aaron.k@muso.ai`

### Slack
- Team communication
- Bound channels: #marketing, #muso-ads, #campaigns, #clio_x_fede
- Never post budgets/spend outside bound channels

### NocoDB (Intelligence Base)
- Airtable-like DB for intelligence / research data
- Transport: MCP server named `NocoDB Base - B2B ADs intelligence` (registered via `openclaw mcp set` on profile `main`)
- Endpoint: `https://app.nocodb.com/mcp/ncsqgdprqpbcnnvb` (native `transport: "streamable-http"`)
- Auth: `xc-mcp-token` header (stored in openclaw MCP config, not env)
- Available to every agent on profile `main`; check with `openclaw --profile main mcp list` if it's not appearing

---

## Connected — Read Only

### ChartMogul
- Subscription analytics (source of truth for SaaS metrics)
- Auth: Basic `$MUSOAI_CHARTMOGUL_TOKEN:`
- API base: `https://api.chartmogul.com/v1`
- Use for: MRR, ARR, churn, LTV, ARPA, customer count
- Values in **cents** — divide by 100
- Skill: `muso-chartmogul`

### ProfitWell (Paddle Retain)
- Cash/payment metrics
- Auth: `Authorization: $MUSOAI_PROFITWELL_TOKEN` (no Bearer prefix)
- API base: `https://api.profitwell.com/v2/`
- **Trailing slashes required** on all URLs
- Values in **dollars** (not cents)
- If ProfitWell disagrees with ChartMogul → ChartMogul wins
- Skill: `muso-profitwell`

### Amplitude
- Product analytics
- Auth: Basic `$MUSOAI_AMPLITUDE_TOKEN:$MUSOAI_AMPLITUDE_SECRET_KEY`
- API base: `https://amplitude.com/api/2/`
- Use for: DAU/MAU, funnels, retention, user activity, cohorts
- Skill: `muso-amplitude`

### Rewardful
- Affiliate/referral program
- Auth: Basic `$REWARDFUL_API_SECRET:` (no password)
- API base: `https://api.getrewardful.com/v1`
- Use for: affiliate stats, referral conversions, commissions, payouts
- Rate limit: 45 req / 30 sec
- Skill: `muso-rewardful`

### Stripe
- Payments and subscriptions
- Auth: Stripe CLI pre-configured with `$MUSOAI_STRIPE_API_KEY`
- Use for: customer lookup, subscription status, charges, invoices, refunds
- Amounts in **cents** (e.g., $20 = 2000)
- Skill: `muso-stripe`

### Athena (AWS)
- SQL queries against Muso data warehouse
- Databases: core-backend, analytics, catalog
- Note: Aaron may be migrating to Cloudflare — verify before building new queries
- Referenced in: `muso-clio`, `muso-ads-manager`

---

## Planned — Not Yet Connected

### Datagma
- Company intelligence / enrichment
- Purpose: replace Clay for B2B prospect enrichment in outreach engine
- Status: needs account setup and API integration

### Snov.io
- Contact intelligence / email finding
- Purpose: contact enrichment for outreach engine
- Status: needs account setup and API integration

### Meta Ads
- Paid social advertising (Facebook/Instagram)
- Purpose: ad campaign management and performance tracking
- Status: not connected yet

### Meta Business Suite / Instagram
- Organic social analytics
- Purpose: read metrics from Instagram, Facebook organic, business analytics
- Status: not connected yet

### GA4 (Google Analytics)
- Website traffic analytics
- Status: not connected yet

---

## Deprecated / Removing

### Clay
- Was: prospect enrichment engine
- Replaced by: Datagma + Snov.io (planned)
- Status: being phased out
