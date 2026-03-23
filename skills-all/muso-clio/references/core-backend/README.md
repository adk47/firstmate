# Core Backend

The main REST API and background workers for Muso.AI.

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `core-backend` |
| **Framework** | Express.js 4.17+ |
| **Language** | JavaScript with Flow types |
| **Database** | PostgreSQL + Sequelize ORM |
| **Cache** | Redis |
| **Queue** | AWS SQS |
| **Auth** | Auth0 + JWT |

## When to Load

Load this reference when:
- Building or modifying API endpoints
- Working with Sequelize models
- Creating or modifying background workers
- Implementing authentication/authorization
- Working with subscriptions or payments

## Application Structure

```
core-backend/
├── apis/              # API route handlers
│   ├── user/          # User registration, login, profile
│   ├── profile/       # Artist profiles, credits, stats
│   ├── team/          # Workspace management
│   ├── analytics/     # Profile/track/album stats
│   ├── payment/       # Subscription webhooks
│   ├── spotify/       # Spotify integration
│   ├── song/          # Track credits
│   ├── collection/    # Album credits
│   ├── search/        # Global search
│   ├── feed/          # Social feed
│   ├── lists/         # Custom profile lists
│   ├── poster/        # Poster generation
│   ├── orders/        # Physical products
│   ├── chart/         # Profile charts
│   └── milestones/    # Achievements
├── components/        # Business logic services
├── models/            # Sequelize models
├── middleware/        # Express middleware
├── workers/           # SQS-based background jobs
└── scripts/           # Scheduled processes
```

## API Modules

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

## Key Dependencies

- Express.js 4.x
- Sequelize 6.x
- Redis (ioredis)
- AWS SDK (SQS, S3, SES, SNS)
- Auth0 SDK
- Stripe SDK

## Related References

- `api.md` - API routes and versioning
- `configuration.md` - Environment setup
- `patterns.md` - Common coding patterns
- `gotchas.md` - Tribal knowledge and pitfalls
