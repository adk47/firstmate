---
name: muso-cloudflare
description: |
  Cloudflare DNS, security, caching, analytics, and zone management for muso.ai — READ ONLY.
  Query DNS records, zone settings, firewall/WAF rules, SSL/TLS config, analytics,
  Workers, Access apps, rate limits, and page rules via the Cloudflare API v4.
  CRITICAL: This skill is READ-ONLY. The token has read-all-scopes permission only.
  Never attempt POST/PUT/PATCH/DELETE operations — they will fail.
  Use when: checking DNS records, viewing zone settings, querying traffic analytics,
  reviewing firewall/WAF rules, checking SSL/TLS configuration, debugging DNS resolution,
  auditing security settings, viewing page rules, checking cache config.
  Triggers: "cloudflare", "dns", "dns records", "zone settings", "waf", "firewall rules",
  "ssl settings", "tls", "cache settings", "analytics", "traffic", "page rules",
  "cloudflare analytics", "muso.ai dns", "rate limits", "access apps"
---

# Cloudflare — muso.ai Zone (Read-Only)

## Quick Reference
- **Account:** `3a4e37c6c9b4822d6f29b5ec98666b53` (Aaron@muso.ai)
- **Zone (muso.ai):** `0e22833a0ee96130f67c1a994a3d2226`
- **Plan:** Business Website
- **Token env var:** `CLOUDFLARE_API_TOKEN`
- **144 DNS records**, SSL: full, TLS 1.2+, cache: aggressive

## API Wrapper

Use the wrapper script for all queries:

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-cloudflare/scripts/cf-api.sh GET ENDPOINT [jq-filter]
```

Examples:
```bash
# List all DNS records
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-cloudflare/scripts/cf-api.sh GET \
  "zones/0e22833a0ee96130f67c1a994a3d2226/dns_records?per_page=100"

# Get zone settings
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-cloudflare/scripts/cf-api.sh GET \
  "zones/0e22833a0ee96130f67c1a994a3d2226/settings"

# Filter DNS by type
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-cloudflare/scripts/cf-api.sh GET \
  "zones/0e22833a0ee96130f67c1a994a3d2226/dns_records?type=CNAME&per_page=100"

# 24h analytics
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-cloudflare/scripts/cf-api.sh GET \
  "zones/0e22833a0ee96130f67c1a994a3d2226/analytics/dashboard?since=-1440&continuous=true"
```

Or use `curl` directly:
```bash
curl -s "https://api.cloudflare.com/client/v4/ENDPOINT" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json"
```

## Common Tasks

### DNS Lookup
List records, filter by `?type=`, `?name=`, or `?content=`. Paginate with `?page=N&per_page=100`.

### Security Audit
Check: `settings/security_level`, `settings/waf`, `settings/min_tls_version`, `firewall/rules`, `rulesets`, `firewall/access_rules/rules`

### Traffic Analytics
Use the dashboard endpoint with `?since=-1440` (24h) or `?since=-10080` (7d). For granular data use the GraphQL endpoint — see `references/api-endpoints.md`.

### Cache Review
Check: `settings/cache_level`, `settings/browser_cache_ttl`, `settings/edge_cache_ttl`, `pagerules`

## Full Endpoint Reference

For the complete list of available endpoints, read `references/api-endpoints.md`.

## Guardrails
- **READ ONLY** — only GET requests. The token physically cannot write.
- No credential values in shared channels — refer to "the Cloudflare token" only.
- Analytics queries are lightweight (no cost concern).
