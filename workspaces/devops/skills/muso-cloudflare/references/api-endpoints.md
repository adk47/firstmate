# Cloudflare API Endpoints Reference

All endpoints are GET-only (read-only token). Base: `https://api.cloudflare.com/client/v4`

## Constants
- Account ID: `3a4e37c6c9b4822d6f29b5ec98666b53`
- Zone ID (muso.ai): `0e22833a0ee96130f67c1a994a3d2226`
- Plan: Business Website
- Token env var: `CLOUDFLARE_API_TOKEN`

## Account & Zone

| Endpoint | Description |
|----------|-------------|
| `/accounts` | List accounts |
| `/accounts/{acct}/members` | Account members |
| `/zones` | List all zones |
| `/zones/{zone}` | Zone details |
| `/zones/{zone}/settings` | All zone settings (SSL, cache, security, etc.) |

## DNS

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/dns_records` | List DNS records (144 total) |
| `/zones/{zone}/dns_records?type=A` | Filter by type (A, AAAA, CNAME, MX, TXT, SRV, etc.) |
| `/zones/{zone}/dns_records?name=app.muso.ai` | Filter by name |
| `/zones/{zone}/dns_records/{id}` | Single record details |

Pagination: `?page=N&per_page=100` (max 100/page)

## Security & Firewall

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/firewall/rules` | Legacy firewall rules |
| `/zones/{zone}/rulesets` | WAF rulesets (managed + custom) |
| `/zones/{zone}/rulesets/{id}` | Ruleset details with rules |
| `/zones/{zone}/firewall/access_rules/rules` | IP access rules |
| `/zones/{zone}/settings/security_level` | Security level setting |
| `/zones/{zone}/settings/challenge_ttl` | Challenge TTL |
| `/zones/{zone}/settings/waf` | WAF on/off |

## SSL/TLS

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/settings/ssl` | SSL mode (currently: full) |
| `/zones/{zone}/settings/min_tls_version` | Min TLS (currently: 1.2) |
| `/zones/{zone}/settings/tls_1_3` | TLS 1.3 (currently: on) |
| `/zones/{zone}/custom_certificates` | Custom SSL certificates |
| `/zones/{zone}/ssl/verification` | SSL verification status |
| `/zones/{zone}/ssl/certificate_packs` | Certificate packs |

## Performance & Caching

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/settings/cache_level` | Cache level (aggressive) |
| `/zones/{zone}/settings/browser_cache_ttl` | Browser cache TTL (14400s = 4h) |
| `/zones/{zone}/settings/edge_cache_ttl` | Edge cache TTL (7200s = 2h) |
| `/zones/{zone}/settings/always_online` | Always Online (off) |
| `/zones/{zone}/settings/brotli` | Brotli compression (off) |
| `/zones/{zone}/settings/minify` | Minification settings |
| `/zones/{zone}/settings/rocket_loader` | Rocket Loader (off) |
| `/zones/{zone}/settings/polish` | Image optimization (off) |
| `/zones/{zone}/settings/webp` | WebP (off) |
| `/zones/{zone}/pagerules` | Page Rules |

## Analytics

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/analytics/dashboard` | Zone analytics dashboard |
| `/zones/{zone}/analytics/dashboard?since=-1440` | Last 24h (minutes) |
| `/zones/{zone}/analytics/dashboard?since=-10080` | Last 7 days |
| `/zones/{zone}/analytics/colos` | Per-colo analytics |
| `/zones/{zone}/dns_analytics/report` | DNS analytics |

Query params: `since` (negative minutes or ISO date), `until`, `continuous=true`

## Analytics (GraphQL — preferred for detailed queries)

POST to `https://api.cloudflare.com/client/v4/graphql` with body:
```json
{
  "query": "{ viewer { zones(filter: {zoneTag: \"ZONE_ID\"}) { httpRequests1dGroups(limit: 7, filter: {date_gt: \"2026-03-04\"}) { dimensions { date } sum { requests cachedRequests bytes threats } } } } }"
}
```

Common datasets:
- `httpRequests1dGroups` — daily HTTP request stats
- `httpRequests1hGroups` — hourly HTTP request stats
- `firewallEventsAdaptiveGroups` — firewall/WAF events
- `healthCheckEventsGroups` — origin health check results

## Workers

| Endpoint | Description |
|----------|-------------|
| `/accounts/{acct}/workers/scripts` | List worker scripts (currently 0) |
| `/accounts/{acct}/workers/scripts/{name}` | Worker script details |
| `/accounts/{acct}/workers/scripts/{name}/schedules` | CRON triggers |

## Network

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/settings/http2` | HTTP/2 (on) |
| `/zones/{zone}/settings/http3` | HTTP/3 (off) |
| `/zones/{zone}/settings/websockets` | WebSockets (on) |
| `/zones/{zone}/settings/ipv6` | IPv6 (on) |
| `/zones/{zone}/settings/ip_geolocation` | IP Geolocation header (on) |
| `/zones/{zone}/settings/proxy_read_timeout` | Proxy read timeout (100s) |
| `/zones/{zone}/load_balancers` | Load balancers (0) |

## Access (Zero Trust)

| Endpoint | Description |
|----------|-------------|
| `/accounts/{acct}/access/apps` | Access applications |
| `/accounts/{acct}/access/policies` | Access policies |
| `/accounts/{acct}/access/groups` | Access groups |
| `/accounts/{acct}/access/identity_providers` | Identity providers |

## Rate Limiting

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/rate_limits` | Rate limiting rules |

## Spectrum (TCP/UDP proxy)

| Endpoint | Description |
|----------|-------------|
| `/zones/{zone}/spectrum/apps` | Spectrum applications |
