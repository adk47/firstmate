# INTEGRATIONS.md — Complete System Access Index

_Every system I have access to, what it does, and who can use it. Load this EVERY session._

## Quick Reference Table

| System | Purpose | Access Level | Write Auth | Skill/Config |
|--------|---------|-------------|------------|--------------|
| **AWS (Athena/S3/CloudWatch/CloudTrail/EKS)** | Data lake queries, infra monitoring | Read-only | — | TOOLS.md (workgroup: `clio-agent`, region: `us-west-2`) |
| **Stripe** | Billing, subscriptions, disputes, refunds | Read + Write | Aaron=full, others=payment links only | `stripe` CLI, TOOLS.md |
| **Google Workspace (gog)** | Gmail, Calendar, Drive, Sheets, Docs | Read + Write | Aaron+Nick=email write, others=read | `gog` CLI, TOOLS.md |
| **Slack** | Messaging, channels | Read + Write | All (via message tool) | Built-in |
| **GitHub** | Code repos, PRs, issues | Read-only default | Aaron authorizes writes | `gh` CLI, github skill |
| **ClickUp** | Task management | Read-only | — | `muso-clickup` skill |
| **Amplitude** | Product analytics | Read-only | — | `muso-amplitude` skill |
| **ChartMogul** | Subscription analytics (MRR, churn, LTV) | Read-only | — | `muso-chartmogul` skill |
| **ProfitWell** | Subscription metrics | Read-only | — | `muso-profitwell` skill |
| **Klaviyo** | Email/SMS marketing | Read + Write | Aaron+Nick=write, others=read | `muso-klaviyo` skill |
| **Intercom** | Customer support/messaging | Read + Write | Aaron=write, others=read | `muso-intercom` skill |
| **GoHighLevel (GHL)** | Sales/marketing CRM & pipeline | Read + Write | Aaron+Nick (no autonomous writes) | `muso-outreach-engine` skill |
| **n8n** | Workflow automation | Read + Write | Aaron+Nick=write, others=read | `muso-n8n` skill + MCP |
| **Webflow** | Website CMS | Read + Write | Aaron+Nick=write, others=read | TOOLS.md |
| **Cloudflare** | DNS, security, CDN for muso.ai | Read-only | — | `muso-cloudflare` skill |
| **MongoDB Atlas** | Database monitoring | Read-only (API) | — | TOOLS.md |
| **Webshare** | Proxy management | Read + Write | Aaron-only | TOOLS.md |
| **DocuSign** | eSignature/contracts | Read + Write | Aaron+Nick only | `muso-docusign` skill |
| **Deel** | HR/Payroll/Contractors | Read + Write | Aaron+Liza=write, #finance_muso=read | `muso-deel` skill |
| **Anrok** | Sales tax & VAT | Read + Write | Aaron=write, Liza=read | `muso-anrok` skill |
| **Rewardful** | Affiliate program | Read + Write | — | TOOLS.md |
| **Figma** | Design files | Read + Write | — | TOOLS.md |
| **Orshot** | Dynamic image generation | Read + Write | — | MCP (`orshot`) |
| **Knock** | Push notifications | Read (test keys) | — | TOOLS.md |
| **Retool API** | Admin panel queries | Read | — | TOOLS.md |

## Ops Skills (Retool Replacement)

| Skill | Purpose | Access |
|-------|---------|--------|
| `muso-ops-admin` | Admin API gateway, auth | Foundation for all ops |
| `muso-ops-claiming` | Review/approve/reject claims | Ops team |
| `muso-ops-credits` | Credit request processing | Ops team |
| `muso-ops-profiles` | Profile merge/unmerge/enrich | Ops team |
| `muso-ops-tracks` | Track management, analytics links | Ops team |
| `muso-ops-identity` | Identity resolution | Ops team |
| `muso-ops-users` | User account management | Ops team |
| `muso-ops-workspaces` | Workspace/team management | Ops team |
| `muso-ops-fraud` | Fraud detection & investigation | Ops team |
| `muso-ops-audit` | Audit logging for all ops writes | Mandatory for all writes |

## Analytics & Reporting Skills

| Skill | Purpose |
|-------|---------|
| `muso-clio` | Complete Muso.AI knowledge base |
| `muso-query-writer` / `muso-athena-query` | Athena SQL queries against data lake |
| `muso-architect` | System architecture guidance |
| `muso-data-expert` | Data model/schema expertise |
| `muso-devops` | Infrastructure/Terraform/CI-CD |
| `dev-activity-report` | Daily GitHub commit reports |
| `muso-refund-investigation` | Refund decision support |
| `muso-refund-processor` | End-to-end refund execution (Stripe write) |
| `muso-contract-invoicer` | Stripe invoices from contracts (Aaron only) |
| `muso-ads-manager` | AMP ad management (Aaron+Serhii+Nick) |

## Marketing & Outreach Skills

| Skill | Purpose |
|-------|---------|
| `muso-b2b-copywriter` | Personalized B2B cold emails |
| `muso-outreach-engine` | End-to-end outreach execution |
| `muso-winback-engine` | Churn win-back email campaigns |
| `cmo-eod` | Nick's daily EOD briefing |

## Built-in OpenClaw Tools

| Tool | Purpose |
|------|---------|
| `web_search` | Brave Search API |
| `web_fetch` | Fetch/extract URL content |
| `browser` | Browser automation |
| `gog` | Google Workspace CLI |
| `tts` | Text-to-speech |
| `mcporter` | MCP server management |
| `memory_search` | Semantic search across memory files |

## Access Control Summary

- **Aaron (U7RP6HKUZ)**: Full access to everything. Sole policy authority.
- **Nick (U0AL36NADEY)**: Marketing systems write (Klaviyo, n8n, GHL, Google, Orshot, Webflow, DocuSign). Everything else read.
- **Liza (U0A8CCTTAAG)**: Deel write, Anrok read, #finance_muso access.
- **Everyone else**: Read-only on all systems unless explicitly listed above.
