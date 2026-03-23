# Web-Credits Frontend Architecture

### Tech Stack

| Category | Technology |
|----------|------------|
| Framework | Nuxt.js 2 |
| Vue | Vue 2 |
| Language | TypeScript |
| CSS | Tailwind CSS + SASS |
| UI Library | Element UI |
| Charts | ECharts |
| State | Vuex + Pinia |

### Application Structure

```text
Pages layer
  /home
  /profile/:id
  /analytics/:id
  /settings/*
  /search/*

Component layer
  shared/* (analytics, credits, feed, profile)
  navigation (AppHeader, Breadcrumbs)
  modals (Subscription, Offer)

State management
  Vuex (auth, roster, subscription, claim)
  Pinia (feed, audit-export)

API layer
  axios.plugin.ts
  entities/*/service.ts

Data flow
  Pages/Components -> State -> Services -> core-backend (/api/v4, /w/v2, /w/v3)
```

### Main Pages

| Route | Purpose |
|-------|---------|
| `/home` | Dashboard with charts, rising profiles/companies |
| `/profile/:id` | Profile page with credits, collaborators, roles |
| `/album/:id` | Album detail page |
| `/analytics/:id` | Analytics dashboard for a profile |
| `/analytics/:id/trends` | Trend analysis |
| `/analytics/:id/milestones` | Career milestones |
| `/search/*` | Search results (profiles, albums, tracks) |
| `/settings/workspace-roster` | Roster management |
| `/settings/workspace-billing` | Billing management |
| `/settings/workspace-users` | Team members |
| `/pricing` | Subscription plans |
| `/promotion/plaque` | Career plaques |

### Key Features

1. **Credits Management** - View/add/edit credits, submissions workflow
2. **Analytics** - Summary metrics, trend charts, milestone tracking
3. **Profile Management** - Claiming, editing, social links
4. **Workspace/Team** - Multi-workspace, roster, invitations
5. **Search** - Global search with filtering
6. **Subscription & Billing** - Plan management, offers
7. **Social Feed** - Activity feed, following

### Service Layer

| Service | Purpose |
|---------|---------|
| `authService` | Login, signup, profile management |
| `analyticsService` | Analytics data |
| `creditsService` | Credits CRUD |
| `chartsService` | Music charts |
| `subscriptionService` | Billing/plans |
| `workspaceService` | Workspace management |
| `claimService` | Profile claiming |
| `feedService` | Activity feed |
| `pwsService` | Platform-wide stats |

---
