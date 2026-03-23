# Core-Backend Architecture

### Tech Stack

| Layer | Technology |
|-------|------------|
| Framework | Express.js 4.17+ |
| Language | JavaScript with Flow types |
| Database | PostgreSQL + Sequelize ORM |
| Caching | Redis |
| Queue | AWS SQS |
| Auth | Auth0 + JWT |

### Application Structure

```text
Routes (/api/v4, /api/w/v2, /api/m/v2)
  -> Middleware (TokenValidation, ACL, Guards)
  -> Controllers (apis/*)
  -> Services (components/*)
  -> Sequelize Models (models/*) -> PostgreSQL

Services also integrate with:
  - Redis
  - SQS
  - External APIs: Auth0, Stripe, Spotify, Catalog API
```

### API Modules

| Module | Path | Description |
|--------|------|-------------|
| User | `apis/user/` | Registration, login, profile, invites, referrals |
| Profile | `apis/profile/` | Artist profiles, credits, stats, collaborators |
| Workspace/Team | `apis/team/` | Team management, members, subscriptions, roster |
| Analytics | `apis/analytics/` | Profile/track/album stats, catalogues |
| Payment | `apis/payment/` | Subscription webhooks (Stripe, PayPal, Apple, Google) |
| Spotify | `apis/spotify/` | Spotify search, OAuth integration |
| Song/Track | `apis/song/` | Track credits, albums, stats |
| Collection/Album | `apis/collection/` | Album credits, stats |
| Search | `apis/search/` | Global search across profiles, tracks |
| Feed | `apis/feed/` | Social feed, activities, following |
| Lists | `apis/lists/` | Custom profile lists (private/shared) |
| Poster | `apis/poster/` | Poster generation and preview |
| Orders | `apis/orders/` | Physical product orders (posters) |
| Chart | `apis/chart/` | Profile chart tiles |
| Milestones | `apis/milestones/` | Achievement milestones |

### API Versioning

| Route Prefix | Purpose | Auth |
|--------------|---------|------|
| `/api/v4/` | Common v4 API (main) | JWT Token |
| `/api/c/v4` | Customer v4 API | Customer Token |
| `/api/c/v4a` | Customer v4 Auth0 API | Auth0 Token |
| `/api/w/v2` | Web v2 API | JWT Token |
| `/api/m/v2` | Mobile v2 API | JWT Token |
| `/api/v3/` | Admin/internal API | JWT Token |
| `/api/i/` | Integration API (webhooks) | Various |

---
