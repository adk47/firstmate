# Muso Ads API Reference

## Authentication

The admin API uses JWT Bearer token auth. The token must contain `roles: ['admin']`.

### Getting an Admin Token

```bash
curl -s -X POST "$MUSO_API_URL/w/admin/user/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"$MUSO_ADMIN_EMAIL","password":"$MUSO_ADMIN_PASSWORD"}' \
  | jq -r '.data.user.token'
```

Environment variables required (in `~/.zshrc`):
- `MUSO_API_URL` — prod API base URL (e.g. `https://api.muso.ai`)
- `MUSO_ADMIN_EMAIL` — admin user email
- `MUSO_ADMIN_PASSWORD` — admin user password

Token is a JWT signed with `appSecret.key`. Include as: `Authorization: Bearer <token>`

## Endpoints

### Create Ad
`POST /w/admin/ads`  
Auth: `Bearer <admin-token>`, ACL: `admin` role  
Content-Type: `multipart/form-data` (requires file upload middleware)

**Required files:**
- `advertiserLogo` — square logo image (jpeg/png/gif/webp), min 200×200px
- `primaryMedia` — main banner/creative image (jpeg/png/gif/webp)

**Required fields:**
- `advertiserName` (string, max 255) — brand display name
- `callToActionLabel` (string, max 100) — CTA button text

**Optional fields:**
- `slug` (string, max 64) — URL-safe ID, auto-generated via nanoid(10) if omitted
- `advertiserVertical` (string, max 255) — business vertical text below name
- `adHeadline` (string, max 60) — short hook text
- `adBody` (text) — full description, supports markdown
- `badgeLabel` (string, max 255) — overlay badge (e.g. "-20%", "New")
- `promoCode` (string, max 100) — redemption code
- `destinationUrl` (text) — click-through URL
- `industryCategory` (string, max 100) — business category
- `advertiserWebsiteUrl` (text) — advertiser's website
- `mediaUrls` (JSONB array) — additional creative image URLs
- `profileId` (string, max 255) — Muso profile UUID to anchor to (auto-populates name/logo from profile)
- `placementType` (TEXT[]) — placement surfaces (default: `['NEWS_FEED']`)
- `isActive` (boolean) — soft-disable flag (default: true)

**Note:** `targetingCriteria` and `targetingJustification` exist in the DB model but the current `createAd` endpoint does NOT accept them. They must be set via direct DB update until an update endpoint is built.

**Response:** `{ data: { ad: { ...adFields } } }`

### List Ads (User-Facing)
`GET /c/v4/amp?placementType=NEWS_FEED,PERSONALIZED_FOR_YOU`  
Auth: any authenticated user

Returns active ads matching the placement type filter.

### Get Ads by Profile
`GET /c/v4/amp/profile/:profileId`  
Auth: any authenticated user

Returns personalized ads for the viewer + profile-owned ads.

### Track Ad Event
`POST /c/v4/amp/:adSlug`  
Body: `{ "eventType": "click" }` or `{ "eventType": "view" }`

Clicks deduplicated within 60-min window (Redis).

### No Update/Delete Endpoints Yet
The current admin API only has `POST /admin/ads` (create). There are NO update or delete endpoints in the codebase. Updates require direct Aurora DB access.

## Database Schema

### `ads` table (Aurora PostgreSQL)

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | BIGINT | PK, auto-increment | | |
| slug | VARCHAR(64) | NOT NULL, UNIQUE | nanoid(10) | URL-safe identifier |
| advertiserName | VARCHAR(255) | NOT NULL | | |
| advertiserLogoUrl | TEXT | NOT NULL | | S3 path: `images/ads/advertiser-logo/{uuid}` |
| primaryMediaUrl | TEXT | NOT NULL | | S3 path: `images/ads/primary-media/{uuid}` |
| mediaUrls | JSONB | NOT NULL | `[]` | Additional creative URLs |
| advertiserVertical | VARCHAR(255) | NOT NULL | `''` | |
| adHeadline | VARCHAR(60) | NULL | | Max 60 chars |
| adBody | TEXT | NOT NULL | `''` | |
| badgeLabel | VARCHAR(255) | NULL | | |
| promoCode | VARCHAR(100) | NULL | | |
| destinationUrl | TEXT | NULL | | |
| industryCategory | VARCHAR(100) | NULL | | |
| callToActionLabel | VARCHAR(100) | NOT NULL | | |
| placementType | TEXT[] | NOT NULL | `{NEWS_FEED}` | Array of placement types |
| targetingCriteria | JSONB | NULL | | Targeting rules |
| targetingJustification | VARCHAR(500) | NULL | | "Why you see this ad" text |
| advertiserWebsiteUrl | TEXT | NULL | | |
| profileId | VARCHAR(255) | NULL | | Muso profile UUID |
| isActive | BOOLEAN | NOT NULL | `true` | |
| createdAt | TIMESTAMP | | | |
| updatedAt | TIMESTAMP | | | |

### `ad_events` table

| Column | Type | Notes |
|--------|------|-------|
| id | BIGINT | PK |
| adId | BIGINT | FK → ads.id (CASCADE) |
| userId | BIGINT | FK → users.id (CASCADE) |
| eventType | VARCHAR(32) | "click" or "view" |
| createdAt | TIMESTAMP | |
| updatedAt | TIMESTAMP | |

Indexes: `(adId, userId, eventType, createdAt)`, `(userId)`

## Placement Types

- `NEWS_FEED` — native ad in Following feed
- `PERSONALIZED_FOR_YOU` — personalized slot in AMP shop
- `MARKETPLACE_ITEM` — horizontal scroll tile in shop carousel
- `SPONSORED_TILE` — sponsored tile variant in shop
- `FEATURED_BOOST` — high-visibility sticky banner at top of AMP
- `EMAIL_NEWSLETTER` — injected into email digest
- `PUSH_NOTIFICATION` — push notification
- `SOCIAL_MEDIA_POST` — external social post

## Targeting Criteria Schema

JSONB object. Each key maps to a user profile field. ALL criteria must match (AND logic).

### Numeric Fields (support `min` and `max`)
- `profileStreams` — total streams
- `profileCreditsCount` — total credits
- `profileCreditsCount1y` — credits in last year
- `profileCreditsReleased30d` — releases in last 30 days
- `profileCreditsReleased60d` — releases in last 60 days
- `profileCreditsReleased6m` — releases in last 6 months
- `profileCreditsReleased1y` — releases in last year

### Boolean Fields (use `values: ["true"]` or `values: ["false"]`)
- `profileIsClaimed` — profile is claimed/verified
- `profileIsPro` — user is a Pro subscriber

### String Fields (use `values` array, case-insensitive partial match)
- `profilePrimaryGenre` — e.g. `["Electronic", "Hip-Hop", "Pop"]`
- `profileRoles` — e.g. `["Producer", "Artist", "Songwriter"]`
- `userAmplitudeCountry` — ISO country codes, e.g. `["US", "GB", "DE"]`

### Example
```json
{
  "profileStreams": { "min": 100000 },
  "profileIsClaimed": { "values": ["true"] },
  "profilePrimaryGenre": { "values": ["Electronic", "Hip-Hop"] },
  "profileRoles": { "values": ["Producer"] },
  "userAmplitudeCountry": { "values": ["US", "GB"] }
}
```

## S3 Image Upload Paths

- Advertiser logos: `images/ads/advertiser-logo/{uuid}`
- Primary media: `images/ads/primary-media/{uuid}`
- Valid MIME types: `image/jpeg`, `image/png`, `image/gif`, `image/webp`

## User Profile Matching

Pre-computed `ads_user_profile_details` table in Aurora (industry_calculations DB) provides targeting data per user. Fallback chain for new users:
1. Check Aurora table
2. If not found → `user_identity_resolution` → enrich from Catalog API
3. If no identity → onboarding fields only (role, country)
4. `@muso.ai` emails get mock profile (always matches everything)
