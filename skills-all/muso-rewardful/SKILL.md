---
name: muso-rewardful
description: |
  Rewardful affiliate/referral program management - READ ONLY. Query campaigns, affiliates, referrals, commissions, payouts.
  CRITICAL: This skill is READ-ONLY. Never create, update, or delete data without Aaron's explicit approval.

  Use when: checking affiliate stats, referral conversions, commission payouts,
  campaign performance, or affiliate lookup.

  Triggers: "rewardful", "affiliate", "referral program", "referral link", "commission", "payout"
compatibility: |
  Requires REWARDFUL_API_SECRET env var. Read-only (GET requests only).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
allowed-tools:
  - Bash
---
# Rewardful Skill — READ ONLY

Rewardful affiliate/referral program management for Muso.AI.
**CRITICAL: This skill is READ-ONLY. Never create, update, or delete data without Aaron's explicit approval.**

## Authentication

- API Secret: `$REWARDFUL_API_SECRET` env var in `/etc/openclaw/main.env` (loaded as a systemd `EnvironmentFile` by `openclaw-gateway-main.service`; not `~/.zshrc`)
- API Key: `$REWARDFUL_API_KEY` env var (used for JS snippet, not REST API)
- Auth method: HTTP Basic Auth — API Secret as username, no password
- Base URL: `https://api.getrewardful.com/v1`

```bash
curl -s -u "$REWARDFUL_API_SECRET:" "https://api.getrewardful.com/v1/{endpoint}"
```

## Resources

### Campaigns
Program offers with commission rules that affiliates promote.
- `GET /v1/campaigns` — list all campaigns
- `GET /v1/campaigns/{id}` — retrieve campaign
- Expandable: affiliates

### Affiliates
People who promote Muso.AI via referral links.
- `GET /v1/affiliates` — list affiliates (sorted by creation date, newest first)
- `GET /v1/affiliates/{id}` — retrieve affiliate
- Filter params: `campaign_id`, `state` (applying/approved/denied/deactivated)
- Expandable: campaign
- SSO: `GET /v1/affiliates/{id}/sso` — magic login link

### Referrals
Unique visits to muso.ai via affiliate links.
- `GET /v1/referrals` — list referrals (sorted by creation date, newest first)
- `GET /v1/referrals/{id}` — retrieve referral
- Filter params: `affiliate_id`, `conversion_state` (lead/conversion)
- Expandable: affiliate, campaign

### Commissions
Rewards issued to affiliates for referred customer payments.
- `GET /v1/commissions` — list commissions (sorted by creation date, newest first)
- `GET /v1/commissions/{id}` — retrieve commission
- Filter params: `affiliate_id`, `campaign_id`, `state` (pending/due/paid)
- Expandable: affiliate, campaign, sale

### Payouts
Bundles of payable commissions for a single affiliate.
- `GET /v1/payouts` — list payouts
- `GET /v1/payouts/{id}` — retrieve payout
- Expandable: affiliate, commissions

## Pagination

All list endpoints return `{ pagination: {...}, data: [...] }`.
- Default limit: 50 per page
- Use `?page=N&limit=N` to paginate
- `pagination.total_count` gives full count

## Expanding Objects

Use `?expand=affiliate` or `?expand[]=affiliate&expand[]=campaign` to inline related objects.

## Rate Limits

45 requests per 30-second window. Add delays for batch operations.

## Common Queries

```bash
# Total affiliates
curl -s -u "$REWARDFUL_API_SECRET:" "https://api.getrewardful.com/v1/affiliates?limit=1" | jq '.pagination.total_count'

# Active campaigns
curl -s -u "$REWARDFUL_API_SECRET:" "https://api.getrewardful.com/v1/campaigns" | jq '.data[] | {name, id, commission_percent: .commission_percent}'

# Recent conversions
curl -s -u "$REWARDFUL_API_SECRET:" "https://api.getrewardful.com/v1/referrals?conversion_state=conversion&limit=10&expand[]=affiliate" | jq '.data'

# Pending commissions
curl -s -u "$REWARDFUL_API_SECRET:" "https://api.getrewardful.com/v1/commissions?state=pending&expand[]=affiliate" | jq '.data'
```

## Triggers

"rewardful", "affiliate", "referral program", "referral link", "commission", "payout"
