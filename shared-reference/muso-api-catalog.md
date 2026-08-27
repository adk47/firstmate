# Muso.AI API Catalog

> ⚠️ **SNAPSHOT, NOT AUTHORITY.** ~5 months stale. A starting point for finding a route,
> never proof that a route, its auth, or its response shape is current. Validate against
> live code before quoting a contract. Known INCOMPLETE — see §10 "Surfaces missing from
> this catalog".
>
> ~~Generated from source code on 2026-02-20. Last updated: 2026-03-22. This is the authoritative reference for all API endpoints.~~
> **Corrected 2026-08-26:** generated 2026-02-20, last updated 2026-03-22 — it was never
> re-generated, so "authoritative reference" has been false since roughly then.

---

## 1. Core Backend (`Muso-AI/core-backend`)

Express.js monolith serving multiple API namespaces.

### Route Mounting (from `src/services/index.js`)

| Mount Path | Router File | Purpose |
|---|---|---|
| `/api/v4/` | `index.v4.js` | Main web app API (authenticated) |
| `/api/v5/` | `index.v5.js` | Common v5 search router (added 2026-03-14, ADR-005) |
| `/api/c/v4` | `index.v4.c.js` | Customer/Partner API (API key auth) |
| `/api/c/v5` | `index.v5.c.js` | Customer API v5 (API key auth, ADR-005) |
| `/api/c/v4a` | `index.v4a.c.js` | Customer API with Auth0 (OAuth token) |
| `/api/m/v2` | `index.m.js` | Mobile app API |
| `/api/w/v2` | `index.web.js` | Web app (analytics, payments) |
| `/api/v3/` | `index.w.js` | Admin API |
| `/api/i/` | `index.i.js` | Integration API |
| `/api/wh/` | `index.wh.js` | Webhooks |

---

### `/api/v4/` — Main Web App API

Auth: JWT token (via `TokenValidation` middleware). Public routes above the middleware.

#### Public (no auth)
- `GET /api/v4/roles` — All credit roles
- `GET /api/v4/organization-roles` — Organization roles
- `GET /api/v4/rising-profiles` — Top/rising profiles
- `GET /api/v4/rising-companies` — Top/rising companies

#### Profile
- `GET /api/v4/profile/:profileId/credits` — Profile credits (see response shape below)
- `GET /api/v4/profile/:profileId/credits/history` — Credit history
- `GET /api/v4/profile/:profileId/collaborators` — Collaborators
- `GET /api/v4/profile/:profileId/albums` — Albums
- `GET /api/v4/profile/:profileId/available-roles` — Available roles
- `GET /api/v4/profile/:profileId/memberships` — Profile memberships
- `GET /api/v4/profile/:profileId/members` — Profile members
- `GET /api/v4/profile/:profileId/stats` — Profile stats
- `GET /api/v4/profile/:profileId/affiliations` — Profile affiliations

#### Track
- `GET /api/v4/track/:trackId/credits` — Track credits
- `GET /api/v4/track/:trackId/albums` — Track albums
- `GET /api/v4/track/:trackId/stats` — Track stats

#### Album
- `GET /api/v4/album/:albumId/credits` — Album credits
- `GET /api/v4/album/:albumId/stats` — Album stats

#### Search
- `GET /api/v4/search` — Global search

#### User
- `GET /api/v4/user` — Get current user
- `PUT /api/v4/user` — Update user
- `PUT /api/v4/user/image` — Upload avatar
- `GET /api/v4/user/invites` — User invites
- `POST /api/v4/user/reset-password` — Reset password
- `GET /api/v4/user/referrals` — Referrals

#### Workspace (nested under `/api/v4/workspace/:workspaceId/`)
- `PUT /` — Update workspace
- `PUT /image` — Upload workspace logo
- `GET /members` — Team members
- `GET /members-full` — Full team member details
- `DELETE /members/:userUUID` — Remove member
- `PUT /members/:userUUID` — Update member
- `POST /invite` — Invite users
- `GET|PATCH /notification-preferences` — Notification prefs
- `GET /entities` — Roster entities
- `POST /entities/upsert` — Upsert entities
- `PATCH /entities/profiles/:profileId` — Update profile entity
- `DELETE /entities/profiles/:profileId` — Remove profile from roster
- `GET /entities/lists` — List entities
- `POST /entities/lists` — Create list entity
- `POST /entities/lists/:listId/duplicate` — Duplicate list
- `POST /entities/company` — Add company
- `DELETE /entities/company` — Remove company
- `GET /entities/profiles/in-app-views` — Roster profile views
- `POST /claimings` — Claim profile
- `POST /profile` — Create profile
- `DELETE /profile/:profileId/credits` — Remove credits
- `POST /profile/:profileId/credits` — Request credits
- `GET /profile/:profileId/credits-submissions` — Credit submissions
- `POST /profile/:profileId/credits/test` — Test credit submission
- `GET /profile/:profileId/tile` — Profile tile
- `GET /profile/:profileId/tile/options` — Tile options
- `PUT /profile/:profileId` — Update profile
- `POST /request-payment-email` — Request payment email
- `GET /exports` — Profile exports
- `POST /exports/:profileId` — Generate export
- `GET /profile/:profileId/audit/summary` — Audit summary
- `GET /profile/:profileId/audit/tracks` — Audit tracks
- `GET /profile/:profileId/audit/collaborators` — Audit collaborators
- Subscription endpoints (`/subscription/*`) — billing, plans, checkout, cancel, etc.

#### Other
- `GET /api/v4/spotify/search` — Spotify entity search
- `GET /api/v4/charts/profile/:profileId/chart/:chartId/tile` — Chart tile
- `GET /api/v4/poster/:profileId/preview` — Poster preview

---

### ⭐ Profile Credits Response Shape (`/api/v4/profile/:profileId/credits`)

**Source:** `src/apis/profile/common/v4/getProfileCredits.js`

Query params: `filter[]`, `keyword`, `sortKey` (artists|title|releaseDate|popularity|rank|credits), `sortDirection`, `limit`, `offset`, `auditStatuses[]`, `collaboratorIds[]`, `genres[]`, `streamsBracket`, `popularityBracket`, `year`

```json
{
  "hasMoreToLoad": true,
  "limit": 20,
  "offset": 0,
  "totalCount": 9632,
  "items": [
    {
      "credits": ["Producer", "Engineer"],
      "track": {
        "id": "abc123-...",          // ← THIS IS THE TRACK ID
        "title": "Song Title",
        "popularity": 75,
        "rank": 12,
        "previewUrl": "https://...",
        "spotifyId": "4iV5W9..."
      },
      "album": {
        "id": "def456-...",
        "title": "Album Title",
        "avatarUrl": "https://...",
        "avatarUrl_640_640": "https://..."
      },
      "releaseDate": "2024-01-15",
      "artists": [{"id": "...", "name": "Artist Name"}]
    }
  ]
}
```

**Key finding:** The track ID is at `item.track.id` — NOT `item.trackId` or `item.track_id`.

---

### `/api/v5/` — Common v5 Search Router (added 2026-03-14)

Auth: TBD (shares core-backend auth context). Part of ADR-005 Search v2 rollout.

New common v5 namespace providing unified search endpoints (not scoped to customer API).

- `POST /api/v5/search` — Global search
- `GET /api/v5/search/autocomplete` — Autocomplete endpoint

**Note:** This mirrors the `/api/c/v5/search` and `/api/c/v5/search/autocomplete` endpoints but at the common (non-customer) API level — likely for the web app frontend to consume directly.

---

### `/api/c/v4` — Customer/Partner API

Auth: API key via `x-api-key` header → **Kong** → `x-api-gw-auth` header. Max page size: 50.
_(corrected 2026-08-26: was "API Gateway", which read as AWS API Gateway. The gateway is
**Kong OSS, self-hosted, 3 replicas** — there is no AWS API Gateway. ~270 legacy Kong
consumers exist on this surface.)_

- `GET /api/c/v4/profile/:profileId` — Profile details
- `GET /api/c/v4/profile/:profileId/credits` — Profile credits
- `GET /api/c/v4/profile/:profileId/collaborators` — Collaborators
- `GET /api/c/v4/profile/:profileId/charts` — Profile charts
- `POST /api/c/v4/profile` — Create profile
- `GET /api/c/v4/profiles/search` — Search profiles
- `GET /api/c/v4/album/:idKey/:idValue` — Album by ID type
- `GET /api/c/v4/album/:idKey/:idValue/credits` — Album credits
- `GET /api/c/v4/track/:idKey/:idValue` — Track by ID type
- `GET /api/c/v4/track/:idKey/:idValue/albums` — Track albums
- `POST /api/c/v4/search` — Search
- `GET /api/c/v4/roles` — Roles

#### Customer Credits Response Shape

**Source:** `src/apis/profile/customer/v4/getProfileCredits.js`

```json
{
  "limit": 20,
  "offset": 0,
  "totalCount": 500,
  "items": [
    {
      "credits": [{"child": "Producer", "parent": "Production"}],
      "track": {
        "id": "abc123-...",          // ← TRACK ID
        "title": "Song Title",
        "popularity": 75,
        "isrcs": ["USRC12345678"],
        "spotifyPreviewUrl": "https://...",
        "spotifyId": "4iV5W9..."
      },
      "album": {
        "id": "def456-...",
        "title": "Album Title",
        "albumArt": "https://..."
      },
      "releaseDate": "2024-01-15",
      "artists": [...],
      "publisher": null,
      "label": "Record Label",
      "c_line": "© 2024...",
      "p_line": "℗ 2024..."
    }
  ]
}
```

---

### `/api/c/v5` — Customer API v5 (ADR-005 Search v2) — Added 2026-03-12

Auth: API key via `x-api-key` header (same as v4 customer API).

New v5 namespace with `profileTypes` filter on search and dedicated autocomplete endpoint.

- `GET /api/c/v5/profile/:profileId` — Profile details
- `GET /api/c/v5/profile/:profileId/credits` — Profile credits
- `GET /api/c/v5/profile/:profileId/collaborators` — Collaborators
- `GET /api/c/v5/profile/:profileId/charts` — Profile charts
- `POST /api/c/v5/profile` — Create profile
- `GET /api/c/v5/profiles/search` — Search profiles (**new: `profileTypes` query param filter**)
- `GET /api/c/v5/album/:idKey/:idValue` — Album by ID type
- `GET /api/c/v5/album/:idKey/:idValue/credits` — Album credits
- `GET /api/c/v5/track/:idKey/:idValue` — Track by ID type
- `GET /api/c/v5/track/:idKey/:idValue/albums` — Track albums
- `POST /api/c/v5/search` — Search
- `GET /api/c/v5/search/autocomplete` — **NEW: Autocomplete endpoint** (ADR-005)
- `GET /api/c/v5/roles` — Roles

**Key differences from v4:**
- `profiles/search` supports `profileTypes` array filter
- New `search/autocomplete` GET endpoint for lightweight autocomplete queries

---

### `/api/c/v4a` — Customer API with Auth0

Auth: Auth0 OAuth token via `customerTokenValidation` middleware.
Middleware: `workspaceUsageLog` + `workspaceRateLimit` (added 2026-03-07, 100 req/60s per workspace, Redis-backed, returns `X-RateLimit-*` headers, 429 on exceed).

- `GET /api/c/v4a/user` — Get user
- `GET /api/c/v4a/user/roster` — User roster
- `POST /api/c/v4a/user/claiming/sessions` — Create claiming session
- `GET /api/c/v4a/analytics/profile/:profileId` — Profile analytics summary
- `GET /api/c/v4a/analytics/profile/:profileId/tracks` — Analytics tracks
- `GET /api/c/v4a/analytics/profile/:profileId/collaborators` — Analytics collaborators
- `GET /api/c/v4a/analytics/profile/:profileId/albums` — Analytics albums
- `GET /api/c/v4a/analytics/profile/:profileId/credits` — Analytics credits
- `GET /api/c/v4a/profile/:profileId/credits` — Catalog credits
- `GET /api/c/v4a/profile/:profileId/collaborators` — Catalog collaborators
- `GET /api/c/v4a/profile/:profileId` — Profile details
- `GET /api/c/v4a/profiles/search` — Search profiles
- `GET /api/c/v4a/profiles/credits` — Credits by profile IDs
- `GET /api/c/v4a/workspace/roster` — Workspace roster
- `GET /api/c/v4a/album/:idValue` — Album details
- `GET /api/c/v4a/track/:idValue` — Track details

---

### `/api/w/v2` — Web App (Analytics & Payments)

Auth: JWT token.

- `GET /api/w/v2/analytics/:profileId/summary` — Analytics overview
- `GET /api/w/v2/analytics/:profileId/catalogue` — Profile catalogue
- `GET /api/w/v2/analytics/:profileId/profile/tracks` — Profile tracks
- `GET /api/w/v2/analytics/:profileId/profile/albums` — Profile albums
- `GET /api/w/v2/analytics/:profileId/profile/collaborators` — Collaborators
- `GET /api/w/v2/analytics/:profileId/profile/credits` — Profile credits
- `GET /api/w/v2/analytics/:profileId/profile/credit/tracks` — Credit tracks
- `POST /api/w/v2/analytics/:profileId/track/:trackId/sources` — Add track source
- `DELETE /api/w/v2/analytics/:profileId/track/:trackId/sources` — Remove track source
- `GET /api/w/v2/analytics/:profileId/track/:trackId/sources` — Get track sources
- `GET /api/w/v2/analytics/:profileId/:group/:entityId/tracks` — Entity tracks
- `GET /api/w/v2/analytics/:profileId/profiles/ratio` — Profiles ratio
- `GET /api/w/v2/analytics/:profileId/profile/profiles` — List profiles
- Payment webhooks: Stripe, PayPal, Apple, Google, Prodigi

---

### `/api/m/v2` — Mobile API

Auth: JWT token.

- `GET /api/m/v2/analytics/:profileId/summary` — Analytics summary
- `GET /api/m/v2/analytics/:profileId/profile/tracks` — Profile tracks
- `GET /api/m/v2/analytics/:profileId/profile/albums` — Profile albums
- `GET /api/m/v2/analytics/:profileId/profile/collaborators` — Collaborators
- `GET /api/m/v2/analytics/:profileId/profile/credits` — Credits
- `GET /api/m/v2/analytics/:profileId/profile/credit/tracks` — Credit tracks
- Source management (add/remove/get track sources)

---

### `/api/v3/` — Admin API

Auth: JWT token + admin role.

- User management (CRUD, impersonation, password reset)
- `POST /api/v3/admin/user/:userId/backfill-profile` — Backfill user profile (added 2026-02-25)
- Claiming management (list, verify, reject, revert)
- Profile management (create, merge, search, enrich, export)
- Settings management

#### Admin Feed — `/api/v3/admin/feed/` (added 2026-03-19)
- `DELETE /api/v3/admin/feed/activities/:activityId` — Delete a feed activity (admin only, added 2026-03-19). Proxies to feed-service `DELETE /activities/:activityId`. Returns feed-service response (cascades: deletes reactions + feed entries). Returns 404 if activity not found.

#### Identity Resolution — `/api/v3/admin/identity-resolution/` (added 2026-03-05, ADR-003)

Admin-only endpoints for user identity resolution (linking user accounts to profiles).

- `GET /api/v3/admin/identity-resolution` — List identity resolution records
- `GET /api/v3/admin/identity-resolution/:userId` — Get identity resolution by user
- `PUT /api/v3/admin/identity-resolution/:id/confirm` — Confirm identity resolution
- `PUT /api/v3/admin/identity-resolution/:id/reject` — Reject identity resolution

Auth: JWT + admin ACL. Model: `user-identity-resolution` (Sequelize). Migration: `20260226120000-create-user-identity-resolution`. Worker process: `resolveAndSeed` (runs in main-worker).

### AMP (Ads) API — `/api/v4/amp/` (added 2026-02-25, updated 2026-03-11)

Auth: JWT token for checkout only. All read endpoints are now public (guest-accessible as of 2026-03-13).

- `GET /api/v4/amp/ads` — Get ads (**public** — guest access allowed since 2026-03-11)
- `GET /api/v4/amp/ads/offer/:offerId` — Resolve offer (**now public** — ACL removed 2026-03-13, was `deny(['guest'])`)
- `GET /api/v4/amp/ads/profile/:profileId` — Get ads by profile (**now public** — ACL removed 2026-03-13, was `deny(['guest'])`)
- `GET /api/v4/amp/ads/:adId` — Get single ad (**now public** — ACL removed 2026-03-13, was `deny(['guest'])`)
- `POST /api/v4/amp/ads/:adId` — Track ad event (public, always was)
- `POST /api/v4/amp/checkout` — Marketplace checkout (auth required, added 2026-03-06)

#### Admin Force-Cancel Subscription — `/api/v3/admin/subscription/:subscriptionId/force-cancel` (added 2026-03-22)
- `POST /api/v3/admin/subscription/:subscriptionId/force-cancel` — Force-cancel a subscription by ID (admin only, added 2026-03-22). Auth: JWT + admin ACL. Added by Serhii in PR #8457.

#### Admin Credit Request Status Transitions (updated 2026-03-17)
- Credit requests now allow `approved → unverified` transition. Previously, once approved, a credit request could not revert. This enables "unapproving" credits that were approved in error.

#### Admin Workspace Key — `/api/v3/admin/workspace/:workspaceId/key` (added 2026-03-17)
- `GET /api/v3/admin/workspace/:workspaceId/key` — Get workspace API key (masked). Admin only.

#### Admin Spotify Web Lookup — `/api/v3/admin/spotify/web-lookup` (added 2026-03-17, route registered 2026-03-18)
- `GET /api/v3/admin/spotify/web-lookup` — Spotify web lookup for hash resolver debugging/recovery. Admin only. Related to the Spotify hash resolver refactor (Redis-as-primary-cache, per-bundle timeouts). **Note:** Route was missing from Express router until 2026-03-18 (PR #8427 registered it in `index.w.js`).

#### Admin Ads — `/api/v3/_admin/ads/`
- `POST /api/v3/_admin/ads/createAd` — Create ad (admin only)
- `PUT /api/v3/admin/ads/:adId` — Update ad (admin only, added 2026-03-06)
- `POST /api/v3/admin/ads/sync` — Sync ad (admin only, added 2026-03-16)
- `GET /api/v3/admin/ads/analytics` — Get ad analytics with placement/platform breakdown (admin only, added 2026-03-16). **Updated 2026-03-20:** Now accepts `ad_ids` (internal numeric IDs) OR `creative_ids` (not both). `ad_ids` path skips musoAdsCreativeId lookup. Max 100 IDs per request. `days` param validated as positive integer (min 1).
- `GET /api/v3/admin/ads` — List all ads with metadata (admin only, added 2026-03-20). Returns `{ ads, total }`. Supports `limit` (default/max 500) and `offset` params. Fields: id, slug, musoAdsCreativeId, adHeadline, advertiserName, advertiserVertical, placementType, isActive, createdAt.
- `DELETE /api/v3/admin/ads/:adId` — Delete ad (admin only, added 2026-03-16)

#### Admin Spotify Accounts — `/api/v3/admin/spotify-accounts/` (added 2026-03-20)
- `PUT /api/v3/admin/spotify-accounts/:id` — Update Spotify account (admin only). Allowed fields: `refreshToken`, `clientKey`, `clientSecret`, `status`. Status must be one of PAUSED/ACTIVE/DEACTIVATED (numeric). Clears accounts cache on success. Returns `{ spotifyAccount: { id, email, status, updatedAt } }`.

#### Admin Ads Targeting Debug — `/api/v3/admin/ads/targeting-debug` (added 2026-03-12)
- `GET /api/v3/admin/ads/targeting-debug` — Debug user ads targeting (admin only). Shows why specific ads are/aren't shown to a user.

#### Admin Marketplace Products — `/api/v3/admin/marketplace-products/` (added 2026-03-06)
- `POST /api/v3/admin/marketplace-products` — Create marketplace product (admin only)
- `PUT /api/v3/admin/marketplace-products/:id` — Update marketplace product (admin only)
- `DELETE /api/v3/admin/marketplace-products/:id` — Delete marketplace product (admin only, added 2026-03-16)

#### Admin Orders — `/api/v3/admin/orders/` (added 2026-03-06)
- `PUT /api/v3/admin/orders/:orderId/tracking` — Update order tracking (admin only)

#### Admin Media — `/api/v3/admin/media/` (added 2026-03-06)
- `POST /api/v3/admin/media/upload` — Upload media image (admin only, multipart file upload)

#### Schema change (2026-02-27)
- **Ad model**: `linkInfo` (nested object) deprecated/removed → replaced by `advertiserWebsiteUrl` (string). Migration: `20260227120000-drop-linkInfo-add-advertiserWebsiteUrl`. Mobile model `AmpAd` updated to match (removed `AmpAdLinkInfo` class, added `advertiserWebsiteUrl` field).

#### ⚠️ Breaking schema changes (2026-03-11)
- **`badgeLabel` → `badge` (JSONB)**: String field `badgeLabel` replaced by `badge` JSONB object with shape `{ text?: string, color?: string, icon?: string, textColor?: string, svg?: string }`. The `svg` field is resolved server-side from `icon` slug (e.g. "flame", "sparkle", "ribbon", "star", "tag", "zap" + `_fill` variants). Migration: `20260310130000-rename-badgeLabel-to-badge-jsonb`. **Breaking for any consumer expecting `badgeLabel` as a string.**
- **New fields on ads**: `sortOrder` (integer, default 0) — controls ad ordering (ASC). Migration: `20260309150000-add-sortOrder-to-ads`.
- **Ad events**: New `placement` (STRING(32)) and `platform` (STRING(16)) columns on `ad_events`. New composite index `ad_events_placement_dedup_idx`. Migration: `20260310120000-add-placement-platform-to-ad-events`.
- **`trackAdEvent` request body**: Now accepts optional `placement` field. Platform is inferred from `X-App-Version` header or User-Agent. Anonymous users (no userId) get `{ tracked: false }` response instead of tracking.
- **Ad listing order**: Changed from `createdAt DESC` to `sortOrder ASC, createdAt DESC` — ads now sort by explicit priority.
- **`GET /amp/ads` auth**: ACL changed from `deny(['guest'])` to open — endpoint is now publicly accessible without authentication.
- **Feed ad position**: Moved from 4th position (index 3) to 2nd position (index 1) in feed.
- **Feed ad dedup**: Common ads that already appear in personal results are deduplicated by slug.
- **Feed ad frequency capping**: Daily/weekly impression caps and dedup window are temporarily disabled (commented out) pending more ad inventory.
- **`forceShowToUserIds`**: New targeting criteria field — array of user IDs that always see the ad regardless of targeting match.
- **Targeting justification**: Now served from DB `targetingJustification` string when non-null (wrapped as `{ title, content }`), falling back to auto-generated text. Text grouping improved to deduplicate by prefix.
- **Feed `actorId`**: Feed ad activities now use `ad.profileId` as actorId when available (was always `ad-{id}`).
- **Feed `actorTitle`**: Changed from `ad.advertiserVertical` to `ad.industryCategory` (2026-03-13). Affects both global feed and following feed ad items.
- **Mixed-placement ads**: Ads with `mixed` placement now shown as regular ads when targeting criteria don't match (2026-03-13). Previously they may have been hidden entirely.

#### Ads API changes (2026-03-20)
- **`targetingJustification` response shape change**: Targeting justification is now resolved centrally in `mapAdToApiResponse()` instead of being attached inline in each service. For `PERSONALIZED_FOR_YOU` ads, the response still returns `{ title, content }` objects. For non-personalized ads, `targetingJustification` is now `undefined` (previously could leak raw strings). **Behavioral change: consumers should NOT expect `targetingJustification` on non-personalized ads.**
- **`ad_ids` support on analytics**: `GET /admin/ads/analytics` now accepts `ad_ids` (internal IDs) as an alternative to `creative_ids`. Cannot use both. Max 100 IDs.
- **New `listAds` endpoint**: `GET /admin/ads` — paginated ad listing with metadata (max 500 per page).
- **New `updateSpotifyAccount` endpoint**: `PUT /admin/spotify-accounts/:id` — manage Spotify account credentials and status.
- **Ad placement filtering**: Common (non-personalized) ads now filtered by explicit `ALLOWED_COMMON_PLACEMENTS` array (`FEATURED_BOOST`, `MARKETPLACE_ITEM`, `SPONSORED_TILE`) instead of excluding `PERSONALIZED_FOR_YOU`. This is a narrowing change — ads with other/null placement types will no longer appear in common slots.
- **`list()` and `count()` accept arrays**: `placementType` param now accepts `string | string[]`, using Postgres `@>` (overlap) for arrays.
- **DB migration**: New partial indexes on `user_identity_resolution` table — `idx_uir_user_confirmed` (WHERE is_confirmed = TRUE) and `idx_uir_primary_not_rejected` (WHERE is_primary = TRUE AND is_rejected = FALSE). Old `idx_uir_user_primary` dropped.

#### Ads sync validation & targeting merge (2026-03-16)
- **New migration**: `20260313120000-add-muso-ads-sync-fields` — adds sync-related fields to the ads table (likely `syncedAt`, validation status, or similar fields for syncing ad state with external systems).
- **`targetingCriteria` merge behavior**: `PUT /admin/ads/:adId` now **merges** `targetingCriteria` on update instead of replacing. This means partial targeting updates no longer wipe existing criteria — callers sending a subset of targeting fields will see them merged with the existing object. **Behavioral change: any admin tooling that relied on full replacement to clear targeting fields must now explicitly null them out.**
- **`isActive` default**: New ads default to `isActive: false` on creation (was previously unset/true). New ads must be explicitly activated.
- **Marketplace product validation**: `MARKETPLACE_ITEM` ads now validate that the linked marketplace product has valid variants before activation. Activation will fail if variants are missing/invalid.
- **Ad analytics breakdown**: New `getAdAnalytics` endpoint returns analytics broken down by `placement` and `platform` dimensions.

#### Ads profile denormalization & personalized targeting (2026-03-07)
- **Ad creation**: When `profileId` is provided, `profileName` and `profileAvatarUrl` are denormalized into the ad record. `advertiserName` falls back to profile name. Advertiser logo becomes optional (defaults to profile avatar). Primary media still required.
- **Feed ad targeting**: `getAdForFeed()` now receives `userId` instead of `ownerProfileId` — personalized ad targeting by user.
- **New response field**: Feed ad responses may include `targetingJustification` (object with explanation of why the ad was shown).
- **Mobile model update**: `AmpAd` now includes optional `marketplaceProduct` field (`AmpMarketplaceProduct` with `variants: List<AmpProductVariant>`). Each variant has `stripePriceId` and `imageUrl`. Mobile now has `isMarketplaceAd` computed property.

#### Orders API changes (2026-03-07)
- **`GET /orders`**: Now passes `userId` to the service layer — orders are filtered by user, not just workspace. This is a behavioral change (previously returned all workspace orders).
- **DTO alignment**: Address handling unified — stored in Stripe format, converted in DTO for Android `OrderDetails` model compliance.
- **New DB index**: `orders(userId, createdAt DESC)` — migration `20260306200000-orders-userid-createdat-index`.
- **Checkout**: Validates `user.defaultTeamId` exists before creating checkout session (returns 400 if missing).

#### Marketplace Products (added 2026-03-06)
- **New model**: `marketplace-product` (`src/models/marketplace-product.js`). Includes `adId` index.
- **Migration**: `20260305120000-create-marketplace-products` — creates marketplace products table.
- **Ad model update**: `src/models/ads.js` modified (likely marketplace product association).
- **Checkout flow**: `src/apis/amp/checkout.js` — new checkout endpoint for marketplace purchases. Stripe webhook handler updated (`stripeWebhook.js`) to handle marketplace checkout sessions, linking to workspace Stripe customer.

#### Mobile rename (2026-03-05)
- **"Offers" → "Offerings"**: Mobile route `ProfileOffersRoute` renamed to `ProfileOfferingsRoute`, AMP tab label changed to "Offerings". Backend API paths unchanged — this is a UI-only rename in the Flutter app.

---

### `/api/i/` — Integration API

- `POST /api/i/auth/find-or-create-user` — ⚠️ **Behavioral change (2026-03-11)**: Now calls `autoCreateUserProfile()` after creating a new user — auto-creates catalog profile + claiming (same as standard signup flow). This means users created via integration API now get a profile immediately, not just a user record.
- `POST /api/i/auth/create-oauth-integration-session`
- `POST /api/i/auth/set-consent`

### `/api/wh/` — Webhooks

- `POST /api/wh/klaviyo/event` — Klaviyo event webhook

---

## 2. Industry Data Processing (`Muso-AI/industry-data-processing`)

FastAPI service. Base path: `/api/v1/`

Auth: Internal service-to-service (no public auth).

### Profile (`/api/v1/profile/`)

- `GET /{profile_id}` — Profile details
- `GET /ipi/{ipi}` — Profile by IPI number
- `GET /{profile_id}/roles` — Profile roles (with track IDs)
- `GET /{profile_id}/parent-roles` — Parent roles (deprecated)
- `GET /{profile_id}/collaborators` — Collaborators
- `GET /{profile_id}/credits` — Profile credits (supports `use_aurora` and `use_precalculated_table` flags, **new: `keyword` param triggers Atlas Search filtering** — added 2026-03-12)
- `GET /{profile_id}/members` — Profile members
- `GET /{profile_id}/memberships` — Profile memberships
- `GET /{profile_id}/collaborators/{collaborator_id}` — Mutual collaboration tracks
- `GET /{profile_id}/albums` — Profile albums
- `GET /{profile_id}/credits/history` — Credits history
- `GET /{profile_id}/sources` — Raw profile sources
- `GET /{profile_id}/stats` — Platform-wide stats
- `GET /{profile_id}/roster-stats` — Roster stats (by roster type)
- `GET /{profile_id}/label-profiles` — Label profiles
- `GET /{profile_id}/publisher-profiles` — Publisher profiles
- `GET /{profile_id}/profile-labels` — Profile labels
- `GET /{profile_id}/profile-publishers` — Profile publishers

#### Atlas Search: Keyword Track Search (added 2026-03-12)

New internal helper `search_profile_track_ids(profile_ids, keyword)` uses MongoDB Atlas Search to find track IDs matching a keyword across profile credits. Used by `GET /{profile_id}/credits?keyword=...` to pre-filter results. Falls back to PostgreSQL `ILIKE` if Atlas Search fails. Response fields `get_profile_credits` and `get_profile_tracks_v2` now include optional `matching_track_ids: list[str] | None`.

#### Atlas Search: Album & Collaborator Keyword Search (added 2026-03-14)

New internal helpers for Atlas Search-powered filtering on profile sub-pages:
- `search_profile_album_ids(keyword)` — searches `catalog_release` collection by title/artist fields, returns matching release IDs (limit 500). Used by `GET /{profile_id}/albums?keyword=...`.
- `search_collaborator_profile_ids(keyword)` — searches `catalog_profile` collection by profile name fields, returns matching profile IDs (limit 500). Used by `GET /{profile_id}/collaborators?keyword=...`.

Both fall back gracefully (return `None`) if Atlas Search fails, allowing the endpoint to use the existing ILIKE fallback.

**New function params:**
- `get_profile_albums()` now accepts `matching_release_ids: list[str] | None`
- `get_profile_collaborator_v2()` now accepts `matching_collaborator_ids: list[str] | None`
- `get_profile_helpers.get_members_v2()` now accepts `matching_profile_ids: list[str] | None`

**New search body param:** `profileTypes: Optional[list[str]]` added to search body validator.

#### Autocomplete Endpoint (added 2026-03-14)

- `GET /api/v1/search/autocomplete` — **NEW**: Lightweight autocomplete across profiles, tracks, and albums.
  - Query params: `q` (required, 1-150 chars), `limit` (1-10, default 5), `types` (optional filter: `profile`, `track`, `album`), `limitProfiles` (1-20, optional), `limitTracks` (1-20, optional), `limitAlbums` (1-20, optional), `totalLimit` (1-50, optional cap on total results)
  - Response: `AutocompleteResult { items: list[AutocompleteItem] }` where `AutocompleteItem { id, name, entityType, avatarUrl? }`
  - All profile types (artist, professional, organization) now return `entityType: "profile"` consistently. Organizations no longer return `entityType: "organization"` — **breaking for any consumer that filtered on `entityType=organization`**.
  - `credit_count_weight` removed from scoring — autocomplete no longer penalizes low-credit profiles. Zero-credit profiles are no longer suppressed.
  - Overfetch from Atlas Search increased to prevent weighted scoring from hiding exact matches.
  - Zero-multiplier fix: credit count scoring now produces a non-zero multiplier even with 0 credits, preventing org/company results from being killed entirely.
  - Searches each entity type independently; partial failures return remaining results.
  - *Updated 2026-03-17: entityType normalization (all profiles→"profile"), credit-weight removal from autocomplete, zero-multiplier fix, overfetch increase.*

#### Search Analytics Logging (added 2026-03-14)

Structured search analytics logging added with latency tracking for search operations. Enables monitoring of search performance and usage patterns.

### Profiles (`/api/v1/profiles/`)

- `POST /` — Get profiles by IDs (body: `{ids: {source: [ids]}}`)
- `POST /{source}` — Get profiles by source IDs
- `GET /credits` — Credits for multiple profile IDs
- `GET /search` — Search profiles by names + track IDs

### ⭐ ProfileCredit Schema (industry-data)

**Source:** `api/v1/schema/profile_credit.py`

```python
class ProfileCredit(BaseModel):
    id: str                        # ← TRACK ID (this is it!)
    credits: list[str]             # Role names
    catalogCredits: list[CatalogCredit]  # {parent, child, added_at}
    title: str | None              # Track title
    releaseDate: str | None
    spotifyIds: list[str]
    artists: list[EmbeddedArtist]
    avatarUrl: str | None
    avatarUrl_640_640: str | None
    album: EmbeddedAlbum | dict | None
    rank: int | None
    popularity: int | None
    isrcs: list[str] | None
    spotifyUrl: str | None
    spotifyId: str | None
    previewUrl: str | None
    createdAt: str | None
    label: str | None
    publisher: str | None
    p_line: str | None
    c_line: str | None
    spotifyLabel: str | None
    streams: int | None            # PG-stats-path only (formerly "Aurora-only"; self-hosted PG17)
    genres: list[str] | None       # PG-stats-path only (formerly "Aurora-only"; self-hosted PG17)
    auditNumISRCsAffected: int | None
    auditStatus: str | None
```

**Key: `id` is the track ID. Not `trackId`, not `track_id`.**

### Track (`/api/v1/track/`)

- `GET /{track_id}` — Track details
- `GET /{track_id}/credits` — Track credits
- `GET /{track_id}/albums` — Track albums
- `POST /list` — Get tracks by list
- `POST /{source}` — Get tracks by source IDs
- `GET /isrc/{isrc}` — Track by ISRC
- `GET /{track_id}/raw-credits` — Raw credits
- `GET /{track_id}/sources` — Raw sources
- `GET /{track_id}/stats` — Track stats
- `GET /{track_id}/profile-stats` — Track profile statistics

### Album (`/api/v1/album/`)

- `GET /{album_id}` — Album details
- `GET /{album_id}/tracks` — Album tracks
- `GET /{album_id}/credits` — Album credits
- `GET /upc/{upc}` — Album by UPC
- `GET /{album_id}/raw_releases` — Raw releases
- `GET /{album_id}/stats` — Album stats
- `GET /{album_id}/profile-stats` — Album profile stats

### Search (`/api/v1/search/`)

- `POST /` — Search (profiles, tracks, albums)
- `GET /autocomplete` — Autocomplete search (profiles, tracks, albums) — **added 2026-03-14, updated 2026-03-17** (per-type limits, entityType normalization, credit-weight removal)

### Stats (`/api/v1/stats/`)

- `GET /{group}` — Stats by group
- `GET /{group}/dates` — Stats date ranges
- `GET /track/{track_id}/links` — Track source links

### Charts (`/api/v1/charts/`)

- `GET /{chart_type}` — Chart entities

### Dictionaries

- `GET /api/v1/dict-credit/catalog-credits` — Catalog credit dictionary
- `GET /api/v1/dict-credit/organization-roles` — Organization roles
- `GET /api/v1/dict-role` — Role dictionary

### Platform (`/api/v1/platform/`)

- `POST /recompute/{entity_type}` — Recompute entities

### Real-Time Updates

- `POST /raw/{action}` — Raw entity actions (sync, upsert, delete, link)
- `POST /analytics/{action}` — Analytics actions
- `POST /catalog` — Catalog update
- `POST /capture` — Capture action
- `POST /capture/catalog/{entity_type}/{entity_id}` — Capture catalog entity
- `POST /capture/recompute-links/{profile_id}` — Recompute profile links

---

## 3. Customer API MCP (`Muso-AI/customer-api-mcp`)

FastAPI + MCP (Model Context Protocol) server. Wraps core-backend customer APIs for AI/MCP clients.

### REST Endpoints (`/api/c/v4/` proxy)

- `GET /profiles/search` — Search profiles
- `GET /profiles/{id_value}` — Profile details
- `GET /profiles/{id_value}/credits` — Profile credits
- `GET /profiles/{id_value}/collaborators` — Collaborators
- `GET /profiles/{id_value}/charts` — Profile charts
- `GET /albums/{id_key}/{id_value}` — Album details
- `GET /albums/{id_key}/{id_value}/credits` — Album credits
- `GET /tracks/{id_key}/{id_value}` — Track details
- `GET /tracks/{id_key}/{id_value}/albums` — Track albums
- `GET /roles` — All roles
- `POST /search` — Global search

### OAuth Endpoints

- `GET /.well-known/oauth-protected-resource`
- `GET /.well-known/oauth-authorization-server`
- `POST /register` — Client registration
- `GET /authorize` — Authorization
- `POST /authorize` — Authorization (form)
- `POST /token` — Token exchange
- `POST /revoke` — Token revocation

### MCP Endpoint

- `GET|POST /mcp` — MCP protocol endpoint

---

## 4. Feed Service (`Muso-AI/feed-service`)

FastAPI service for social feed features.

### Activities

- `POST /activities/` — Create activity
- `GET /activities/{activity_id}` — Get activity
- `GET /activities/actor/{actor_id}` — Get actor activities
- `DELETE /activities/{activity_id}` — Delete activity (added 2026-03-18). Returns `ActivityDeleteResponseSchema: { activity_id: str, reactions_deleted: int, feed_entries_deleted: int }`. Cascades: deletes associated reactions and feed entries.

### Feed

- `GET /feed/` — Get feed

### Follows

- `POST /follows/` — Follow
- `POST /follows/bulk` — Bulk follow
- `DELETE /follows/` — Unfollow
- `GET /follows/actor/{actor_id}/following` — Get following
- `GET /follows/actor/{actor_id}/followers` — Get followers

### Reactions

- `POST /reactions/` — Create reaction
- `DELETE /reactions/` — Delete reaction
- `GET /reactions/activity/{activity_id}` — Activity reactions
- `GET /reactions/actor/{actor_id}` — Actor reactions

---

## 5. Digital Plaque (`Muso-AI/digital-plaque`)

Express/TypeScript backend for physical digital plaques.

Routes in `apps/backend/src/routes/`:
- `/roster` — Roster management
- `/pairing` — Device pairing
- `/settings` — Plaque settings
- `/admin` — Admin operations
- `/telemetry` — Device telemetry
- `/updates` — OTA updates
- `/device` — Device management
- `/health` — Health check

---

## 6. Analytics Worker (`Muso-AI/analytics-worker`)

Background worker service — no HTTP API (**consumes Redpanda/Kafka topics; "SQS" in old
code and env-var names is a shim.**) _(corrected 2026-08-26: was "processes SQS messages" —
there is no live AWS SQS.)_

---

## 7. Analytics Scheduler (`Muso-AI/analytics-scheduler`)

Scheduling service — no public HTTP API.

---

## 8. Render Service (`Muso-AI/render-service`)

Internal service for rendering (posters, exports, etc.) — no public API.

---

## 9. AI Chat Service (`Muso-AI/ai-chat-service`)

AI chat integration service.

---

## 10. Surfaces missing from this catalog

_Added 2026-08-26._ These exist in production but were never catalogued above. Their absence
here is the main reason this document must not be treated as authoritative — a route missing
from this file is not evidence the route does not exist.

- **ticker-api nowcast** — `GET /v1/nowcast/<profile_id>`. **The profile UUID is REQUIRED**;
  bare `/v1/nowcast` and `/v1/nowcast/` return **404**, which is a route error, not a nowcast
  outage. Do not escalate a bare-path 404 as an incident.
- **Platform API** — `api.platform.muso.ai` is **live** (not "coming"), fronted by Kong.
  platform.muso.ai itself is live behind an @muso.ai better-auth gate.
- **`/w/v3/*`** — public profile routes. Not documented above at all.
- **`POST /v4/profile/:id/views`** — server-side profile views. **This is the SOLD metric.**
  It is NOT the raw Amplitude `profile_view` event; do not substitute one for the other when
  quoting a customer or an advertiser.
- **Insights / `followersTotal`** — the follower count. ⚠️ Profile-detail `followsCount` is
  **OUTGOING follows** (who the profile follows) and is **never** a follower count. These have
  been confused before.
- **Credits submissions** — the credit-submission surface behind "Add Missing Credits".
- **Feed activities** — the activity/feed surface.

---

## Common Patterns

### Pagination

All list endpoints support:
- `limit` — Page size (default varies: 20 for v4, 50 for customer)
- `offset` — Skip count

Response includes:
- `totalCount` — Total items
- `hasMoreToLoad` (v4) or calculate from `offset + items.length < totalCount`

### Sorting

- `sortKey` — Field to sort by
- `sortDirection` — `ASC` or `DESC`

### Authentication

| API | Auth Method |
|---|---|
| `/api/v4/` | JWT Bearer token |
| `/api/v5/` | TBD (common v5 search, added 2026-03-14) |
| `/api/c/v4` | API key (`x-api-key` header) |
| `/api/c/v5` | API key (`x-api-key` header) |
| `/api/c/v4a` | Auth0 OAuth token |
| `/api/m/v2` | JWT Bearer token |
| `/api/w/v2` | JWT Bearer token |
| `/api/v3/` | JWT Bearer + admin role |
| Industry Data | Internal service-to-service |

---

## Swagger/OpenAPI Specs

Available in `Muso-AI/customer-api-docs`:
- `swagger-v4.json` — Main customer API
- `swagger-workspace.json` — Workspace API
- `swagger-sso.json` — SSO API
