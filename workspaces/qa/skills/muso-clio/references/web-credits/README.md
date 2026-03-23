# Web Credits Frontend

The Nuxt.js/Vue.js web application for Muso.AI credits and analytics.

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `web-credits` |
| **Framework** | Nuxt.js 2.18 |
| **Vue** | Vue 2.7 |
| **Language** | TypeScript |
| **CSS** | Tailwind CSS + SASS |
| **UI Library** | Element UI |
| **Charts** | ECharts |
| **State** | Vuex + Pinia |

## When to Load

Load this reference when:
- Building or modifying pages/components
- Working with Vuex/Pinia stores
- Implementing analytics charts or visualizations
- Working with the API service layer
- Styling with Tailwind or Element UI

## Application Structure

```
web-credits/
├── pages/              # Nuxt pages (auto-routed)
│   ├── home/           # Dashboard
│   ├── profile/        # Profile pages
│   ├── analytics/      # Analytics views
│   ├── search/         # Search results
│   └── settings/       # User/workspace settings
├── components/         # Vue components
│   └── shared/         # Shared components
│       ├── analytics/  # Charts, stats
│       ├── credits/    # Credit management
│       ├── feed/       # Activity feed
│       └── profile/    # Profile components
├── store/              # Vuex stores
├── stores/             # Pinia stores (new)
├── entities/           # Service layer
│   └── */service.ts    # API services
├── plugins/            # Nuxt plugins
├── middleware/         # Route middleware
└── assets/             # Static assets
```

## Main Pages

| Route | Purpose |
|-------|---------|
| `/home` | Dashboard with charts, rising profiles |
| `/profile/:id` | Profile with credits, collaborators |
| `/album/:id` | Album detail page |
| `/analytics/:id` | Analytics dashboard |
| `/analytics/:id/trends` | Trend analysis |
| `/analytics/:id/milestones` | Career milestones |
| `/search/*` | Search results |
| `/settings/workspace-roster` | Roster management |
| `/settings/workspace-billing` | Billing |
| `/settings/workspace-users` | Team members |
| `/pricing` | Subscription plans |
| `/promotion/plaque` | Career plaques |

## Key Features

1. **Credits Management** - View/add/edit credits, submissions workflow
2. **Analytics** - Summary metrics, trend charts, milestone tracking
3. **Profile Management** - Claiming, editing, social links
4. **Workspace/Team** - Multi-workspace, roster, invitations
5. **Search** - Global search with filtering
6. **Subscription & Billing** - Plan management, offers
7. **Social Feed** - Activity feed, following

## Related References

- `api.md` - Service layer and API integration
- `configuration.md` - Environment setup
- `patterns.md` - Vue/Nuxt patterns
- `gotchas.md` - Common pitfalls
