---
name: muso-ads-manager
description: >
  Create, update, list, and manage Muso AMP ads via the core-backend admin API.
  Guided conversational workflow for ad management — targeting, placements, scheduling,
  creative uploads, and performance monitoring.
  
  WRITE ACCESS: Aaron (U7RP6HKUZ), Serhii (U03TYGJF1N3), and Nick (U0AL36NADEY) ONLY.
  All other users are blocked entirely.
  
  CHANNEL RESTRICTION: Only responds to ad management requests in #clio_analyst (C0ADREBPNQ2).
  
  Use when: creating new ads, updating ad targeting/placements, listing active ads,
  toggling ads on/off, checking ad performance, managing AMP feed content.
  
  Triggers: "create ad", "new ad", "ads manager", "manage ads", "update ad",
  "ad targeting", "ad placement", "amp ads", "feed ad", "ad campaign",
  "toggle ad", "deactivate ad", "ad performance", "ad stats"
---

# Muso Ads Manager

Conversational ad management for Muso AMP, Feed, and Personalized For You placements.

## Access Control (MANDATORY — check FIRST)

Verify `sender_id` from inbound metadata before ANY operation:
- `U7RP6HKUZ` (Aaron) → full access → email: `aaron@muso.ai`
- `U03TYGJF1N3` (Serhii) → full access → email: `serhii@muso.ai`
- `U0AL36NADEY` (Nick) → full access
- Anyone else → politely decline: "Ad management is restricted. Ask Aaron for access."

Channel restriction: only process ad management requests from `C0ADREBPNQ2` (#clio_analyst).
If triggered elsewhere, respond: "Ad management is available in #clio_analyst only."

## Requester Attribution (MANDATORY — every write operation)

Every admin API call MUST include the `Requester` and `Service` headers so the backend
knows which human initiated the change (same pattern as Retool's admin panel).

- `Requester: <user's muso email>` — resolved from the sender_id → email mapping above
- `Service: clio` — identifies that the change came through Clio (vs Retool, web UI, etc.)

**How it works:**
1. Check `sender_id` from inbound metadata
2. Map to email using the table above
3. Pass `--requester <email>` to all API script calls

Example:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ads-manager/scripts/muso-ads-api.sh \
  --requester aaron@muso.ai create --logo /tmp/logo.png --media /tmp/banner.jpg ...
```

For the shared admin API:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester aaron@muso.ai call PUT "/w/admin/ads/123" '{"isActive": false}'
```

**Never make a write call without `--requester`.** This is the backend's audit trail.

## Environment Setup

Required env vars — **CONFIGURED AND WORKING:**
- `MUSO_API_URL` — prod API base (e.g. `https://api.muso.ai`)
- `MUSO_ADMIN_EMAIL` — admin account email
- `MUSO_ADMIN_PASSWORD` — admin account password

**Location on hydra:** `/etc/openclaw/main.env` (loaded as a systemd
`EnvironmentFile` by `openclaw-gateway-main.service`). These are NOT in
`~/.zshrc` — the gateway runs as a daemon and does not source an
interactive shell. If you see "admin API credentials are not configured"
from the ads manager, check that both vars are present in that file and
restart the unit with `systemctl restart openclaw-gateway-main`.

If any are missing, tell Aaron what's needed. Never display credential values.

## API Script

Wrapper: `bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ads-manager/scripts/muso-ads-api.sh <command>`

Commands: `login`, `create`, `list`, `get <slug>`, `events <slug>`

For full API details (auth flow, endpoints, schema, targeting criteria): read `references/api-reference.md`.

## Guided Workflows

### Create New Ad

Walk the user through each field conversationally. Collect in this order:

1. **Advertiser basics** — name, vertical, website URL
2. **Creative** — headline (≤60 chars!), body copy, badge label, promo code
3. **CTA** — button text + destination URL
4. **Images** — ask user to upload logo + primary media image
5. **Placement** — which surfaces (show the 8 options, explain each)
6. **Targeting** — build criteria interactively:
   - Streams threshold? Credits count?
   - Genre filter? Role filter? Country filter?
   - Pro-only? Claimed-only?
   - Show preview of targeting JSON before confirming
7. **Targeting justification** — suggest auto-generated text, let user override
8. **Profile anchor** — optionally link to a Muso profile UUID
9. **Review** — show full summary, get confirmation
10. **Execute** — call create API, report result with ad slug

### Update Ad

`PUT /w/admin/ads/:adId` — Update endpoint EXISTS in codebase (verified 2026-03-07 from index.w.js).

```bash
# Get admin token first, then:
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/w/admin/ads/<ad_id>" '{"field":"value"}'
```

Note: The `updateAd` handler exists at `src/apis/_admin/ads/updateAd.js`. Check its accepted fields before using.

### Toggle Ad Active/Inactive

```sql
UPDATE ads SET "isActive" = <true|false>, "updatedAt" = NOW() WHERE slug = '<slug>';
```

### List & Search Ads

Use the API list command or query Aurora directly:
```sql
SELECT id, slug, "advertiserName", "adHeadline", "placementType", 
       "isActive", "targetingCriteria", "createdAt"
FROM ads ORDER BY "createdAt" DESC;
```

### Ad Performance

Query `ad_events` table:
```sql
SELECT a.slug, a."advertiserName",
       COUNT(CASE WHEN e."eventType" = 'view' THEN 1 END) as views,
       COUNT(CASE WHEN e."eventType" = 'click' THEN 1 END) as clicks,
       ROUND(COUNT(CASE WHEN e."eventType" = 'click' THEN 1 END)::numeric / 
             NULLIF(COUNT(CASE WHEN e."eventType" = 'view' THEN 1 END), 0) * 100, 2) as ctr
FROM ads a LEFT JOIN ad_events e ON a.id = e."adId"
WHERE a."isActive" = true
GROUP BY a.id, a.slug, a."advertiserName"
ORDER BY views DESC;
```

## Placement Types Quick Reference

| Type | Surface | Description |
|------|---------|-------------|
| `NEWS_FEED` | Following feed | Native ad card in user's feed (default) |
| `PERSONALIZED_FOR_YOU` | AMP shop | Targeted slot in "For You" section |
| `MARKETPLACE_ITEM` | AMP shop | Horizontal carousel tile |
| `SPONSORED_TILE` | AMP shop | Sponsored tile variant |
| `FEATURED_BOOST` | AMP top | High-visibility sticky banner |
| `EMAIL_NEWSLETTER` | Email | Injected into digest emails |
| `PUSH_NOTIFICATION` | Mobile | Direct push to device |
| `SOCIAL_MEDIA_POST` | External | Social media post |

## Targeting Fields Quick Reference

**Numeric** (min/max): `profileStreams`, `profileCreditsCount`, `profileCreditsCount1y`, `profileCreditsReleased30d/60d/6m/1y`

**Boolean** (values array): `profileIsClaimed`, `profileIsPro`

**String** (values array, partial match): `profilePrimaryGenre`, `profileRoles`, `userAmplitudeCountry`

## Important Notes

- `adHeadline` max 60 characters — enforce this during creation
- `slug` is auto-generated if not provided (nanoid, 10 chars)
- Images must be uploaded as multipart form files, not URLs
- `@muso.ai` users always match all targeting (mock profile for testing)
- Click dedup: 60-min Redis window per user+ad+event
- The `ampEnabled` feature flag is currently `false` in prod config — ads may only be visible in non-prod or if overridden. Flag Aaron if this is blocking.
- `targetingCriteria` and `targetingJustification` are NOT accepted by the create endpoint — they're DB-only fields until the API is extended
