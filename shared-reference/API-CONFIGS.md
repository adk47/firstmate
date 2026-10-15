# API-CONFIGS.md — Extended API Reference

_Load this file when working with any of these systems. Core configs (Stripe, GHL, Klaviyo, AWS, email) are in TOOLS.md. Our email/analytics stack (Klaviyo/Amplitude/Knock replacement): skills `muso-email`, `muso-analytics`._

## MongoDB Atlas

- Keys: `MONGODB_ATLAS_PUBLIC_KEY` / `MONGODB_ATLAS_PRIVATE_KEY` | Auth: HTTP Digest
- Base: `https://cloud.mongodb.com/api/atlas/v2` | Project: `6358f894f47fc018ab2ad7bd`
- Clusters: `product-api-dev`, `product-api-prod` (MongoDB 8.0.19)

## Webshare Proxy

- Key: `WEBSHARE_API_KEY` | Base: `https://proxy.webshare.io/api/v2/`
- Datacenter plan: 12872577 (100 proxies, $26.62/mo) | Residential plan: 12872082 (250GB, $742.19/mo)
- 🔒 Aaron-only for ALL Webshare operations. Residential proxies especially untouchable.

## Webflow

- Key: `WEBFLOW_API_TOKEN` | Base: `https://api.webflow.com/v2`
- Site: `69b0ade1e3ef1b969b405265` | Collections: Artists `69b0ade1e3ef1b969b405279`, Companies `69b0ade1e3ef1b969b405296`, Testimonials `69b0ade1e3ef1b969b4052b1`
- Write: Aaron + Nick. Everyone else read-only.

## Cloudflare (READ-ONLY)

- Key: `CLOUDFLARE_API_TOKEN` | Base: `https://api.cloudflare.com/client/v4`
- Zone: `0e22833a0ee96130f67c1a994a3d2226` (muso.ai) | Wrapper: `cf-api.sh`

## DocuSign

- Auth: JWT Grant | Keys in `~/.zshrc`: `DOCUSIGN_USER_ID`, `DOCUSIGN_ACCOUNT_ID`, `DOCUSIGN_BASE_URI`, `DOCUSIGN_INTEGRATION_KEY`
- RSA keypair: `~/.docusign/` | Currently SANDBOX
- Access: Aaron + Nick only.

## Deel (HR/Payroll) — Contains PII

- Key: `DEEL_API_TOKEN` | Base: `https://api.letsdeel.com/rest/v2`
- Org: 34076 | Legal entity: Muso.AI Inc
- Query access: #finance_muso members. Write: Aaron + Liza only. Never expose in shared channels.

## Anrok (Sales Tax)

- Key: `ANROK_API_KEY` (format: `sellerId/apiKeyId/secret`) | Base: `https://api.anrok.com/v1/seller/`
- All requests POST with JSON. Rate limit: 10/sec. Premium features (list, validate, filings) not enabled.
- Write: Aaron only. Liza = read-only.

## Rewardful (Affiliates)

- Keys: `REWARDFUL_API_KEY`, `REWARDFUL_API_SECRET` | Base: `https://api.getrewardful.com/v1/`
- Auth: HTTP Basic (secret as username) | Rate limit: 45/30sec
- Amounts in cents. State field: `state` (not `status`).

## Figma

- Key: `FIGMA_ACCESS_TOKEN` | Base: `https://api.figma.com/v1` | Auth: `X-Figma-Token` header
- SMM Instagram Design file: `u3nPdFYcHjHD3NcekYccZy`

## n8n

- Key: `N8N_API_KEY` | Base: `https://musoai.app.n8n.cloud/api/v1` | Auth: `X-N8N-API-KEY`
- ⚠️ `N8N_API_KEY` **expired 2026-03-31**. Assume every n8n call fails until a human
  re-mints it; do not report an n8n failure as an outage. MCP registered as `n8n`.
  _(corrected 2026-08-26: was "Key expires: 2026-03-31." — written as a future date, it
  has read as "still valid" ever since it lapsed.)_
- Write: Aaron + Nick.

## Orshot (Dynamic Images)

- Key: `ORSHOT_API_KEY` | MCP server: `orshot` | Workspace: Federico's (ID: 2879)
- Usage: `mcporter call orshot.<tool_name> key=value`

## Knock (Notifications) — being replaced

- Keys: `KNOCK_PUBLIC_KEY`, `KNOCK_SECRET_KEY` (test env) | Base: `https://api.knock.app/v1`
- Note: Test keys only. Knock is being replaced by notify-gateway + Novu (stack swap, Oct 2026); do not build on it.
- A user's bell, read-only from our store (mirrors Knock's last 30 days, then the new path):
  `bash /opt/hydra/scripts/muso-stack-read.sh pg notify "SELECT workflow_key, inserted_at, read_at, seen_at FROM notify.feed_items WHERE user_id = '<user_id>' ORDER BY inserted_at DESC LIMIT 20"`

## Retool API

- Key: `RETOOL_ACCESS_TOKEN` | For admin panel lookups.

## Product Analytics Lookup Rule (our stack first, Amplitude as fallback)

Always use Muso internal user ID (numeric) for searches — NOT email. Get user ID from the admin API / `muso users search`.
Use the `muso-analytics` skill (`muso-stack-read.sh router '/api/2/usersearch?user=<id>'`); fall back to Amplitude (`muso-amplitude`) only for windows `muso-stack-read.sh coverage` says are not covered yet.

## Industry Realtime Import Checkpoints

- Location: `s3://platform-data-processing-lake-prod/industry/materialize_realtime_checkpoints/`
