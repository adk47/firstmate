# Muso.AI LLM Cheatsheet

> **Load this file for every task.** It's the compact cross-system primer.

## TL;DR

Muso.AI is the world's first verified music credits platform. We help music professionals clean up their credits, track analytics across streaming platforms, and audit catalogs for missing royalties.

- **4M+ profiles** in our database
- **11 streaming platforms** tracked (Spotify, YouTube, TikTok, Shazam, etc.)
- **Founded 2017** at NRG Recording Studios, Los Angeles

## Repository Index

Use `gh repo clone Muso-AI/<repo>` or `gh api repos/Muso-AI/<repo>` for latest info.

| Repo | Purpose | Tech |
|------|---------|------|
| `core-backend` | REST API, workers | Node.js/Express, Flow types |
| `web-credits` | Web app | Nuxt 2, Vue 2, TypeScript |
| `mobile` | Mobile app | Flutter 3.35.7, Dart 3.9 |
| `platform-data-processing` | Data pipelines | Airflow 2.10, Spark 4.0 |
| `industry-data-processing` | Catalog processing | Python 3.12, FastAPI, SQS |
| `analytics-worker` | Stats capture | Python 3.11, SQS, KEDA |
| `devops` | Infrastructure | Terraform, Jenkins |

## Architecture Document Index

| Document | ~Lines | When to Load |
|----------|--------|--------------|
| `architecture/core_backend.md` | 85 | Backend API, workers |
| `architecture/web_credits.md` | 100 | Frontend development |
| `architecture/mobile.md` | 185 | Mobile app development |
| `architecture/platform_data_processing.md` | 150 | Airflow/Spark pipelines |
| `architecture/industry_data_processing.md` | 150 | Catalog processing, SQS workers |
| `architecture/analytics_worker.md` | 125 | Analytics capture |
| `architecture/devops.md` | 200 | Infrastructure, CI/CD |
| `architecture/database.md` | 100 | Schema, tables |
| `architecture/api_reference.md` | 100 | API routes, auth flows |
| `architecture/security.md` | 80 | Auth, guards |
| `architecture/integrations.md` | 120 | External services |

## Data Model - Key Terms

| Term | Definition |
|------|------------|
| **Profile** | A music professional or entity (artist, producer, writer, etc.) |
| **Track** | A song/recording with credits and streaming stats |
| **Credit** | A role (producer, writer, engineer) tied to a profile and track |
| **Workspace/Team** | Organization unit with seats, billing, and roster |
| **Roster** | Profiles managed within a workspace |
| **Catalog** | Unified industry dataset built from raw sources |
| **Raw** | Source-specific ingested data (before catalog merge) |
| **Milestone** | Streaming achievement (10K, 100K, 1M, etc.) |

## Source of Truth - Where Data Lives

**IMPORTANT: Athena is READ-ONLY.** When users ask to UPDATE data, guide them to the correct system:

| Entity | Source of Truth | How to Update |
|--------|-----------------|---------------|
| Profile metadata (name, bio, image, `profile_type`) | MongoDB `catalog_profile` | Admin UI or direct MongoDB |
| Profile claimed status | PostgreSQL `core_backend.profiles` | Admin UI or Aurora |
| User data (email, auth) | PostgreSQL `core_backend.users` | Admin UI or Aurora |
| Track/Album data | MongoDB `catalog_track`/`catalog_release` | Automated pipelines (rarely manual) |
| Streaming stats | PostgreSQL `platform_stats.track_daily` | Automated pipelines only |
| **Credits** | MongoDB `catalog_track.profiles[]` | User API, CSV import, or MongoDB → re-materialize (see Credit Update Guide below) |

**Key Resources (always cite these):**

| Resource | URL |
|----------|-----|
| Admin Panel (Prod) | https://admin-production.muso.ai/ |
| Admin Panel (Dev) | https://admin-nonproduction.muso.ai/ |
| How To: Athena | https://www.notion.so/2e90aeed21ad80a1ab79eb14fffbe739 |
| DB Tunneling | https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19 |
| MongoDB Access | https://www.notion.so/adb0059a507743bd8120be793a6648df |
| Oleg Knowledge Transfer | https://www.notion.so/2ed0aeed21ad80a28eedffdc9fcb1f96 |
| Useful Queries (GitHub) | https://github.com/Muso-AI/platform-data-processing/tree/main/docs/oleg-sql-ai |
| Retool (Internal Admin) | https://www.notion.so/af5412b08fc9409e81cdce6a017c8fdf |

**MongoDB Access:** Via SSH tunneling through bastion hosts. Credentials in Keybase (`musoai.infra`).

**If you don't know where data lives:** Search Notion for the entity name, or check `data-model/source-map.md`.

## Credit Updates (Common Question)

**What is a credit?** A role (producer, songwriter, engineer) linking a profile to a track.

**Where credits live:**
- Display: `mongo:catalog_track.profiles[]` (nested array)
- Raw source: `mongo:raw_recording_credit`
- User-submitted: `mongo:source_muso.profile_credit`

**How to update credits:**

| Method | When to Use |
|--------|-------------|
| **User self-submission** | API: `POST /api/m/v3/profile/{id}/add-track-credit` - goes through verification |
| **Bulk CSV import** | SQS task: `importProfileCreditsCsv` - for operations team |
| **Manual MongoDB fix** | Update `source_muso.profile_credit`, trigger materialization |
| **Automated** | Pipelines from Jaxsta/Spotify/Tidal/MLC/Genius (most credits) |

**Credit verification** scores submissions 0-100%; 50%+ = rejected. Checks: popularity mismatch, collaborator changes, duplicate mixing/mastering, scary roles (producer/songwriter).

**Full details:** See `data-model/source-map.md` → "Credit Update Guide"

## Primary Data Flows

### User Flow
```
Client (Web/Mobile) -> Core Backend API -> RDS/Redis/SQS -> Workers
```

### Industry Pipeline
```
Raw SQS -> MongoDB raw_* -> Catalog SQS -> MongoDB catalog_* -> Analytics SQS -> Postgres stats
```

### Data Platform
```
Airflow/Spark -> S3 data lake -> Postgres (stats/catalog/olap) + MongoDB + Elasticsearch
```

## API Surfaces

| Surface | Base URL | Auth | Used By |
|---------|----------|------|---------|
| Web API | `/api/w/v2`, `/api/w/v3` | JWT | web-credits |
| Mobile API | `/api/m/v2`, `/api/m/v3` | JWT | mobile |
| Customer API | `/api/c/v4`, `/api/c/v4a` | API Key | partners |
| Admin API | `/api/v4` | JWT | internal |
| Industry API | `/api/v1/*` (FastAPI) | internal | core-backend |

## Tech Stack Highlights

| Layer | Technologies |
|-------|-------------|
| **Backend** | Node.js 16+/Express 4.x, Flow types, Sequelize ORM, Auth0/JWT |
| **Data** | Airflow 2.10, Spark 4.0, MongoDB Atlas, Aurora/RDS Postgres, Redis, S3 |
| **Web** | Nuxt 2.18, Vue 2.7, TypeScript, Tailwind, Element UI, Vuex + Pinia |
| **Mobile** | Flutter 3.35.7, Dart 3.9, BLoC 9.1, auto_route 10.3 |
| **Infra** | AWS (ECS, EKS), Terraform 1.5+, Jenkins, Docker |

## Key Integrations

| Category | Services |
|----------|----------|
| **Payments** | Stripe, PayPal, Apple IAP, Google Play |
| **Music APIs** | Spotify, YouTube, TikTok, Shazam, SoundCloud, Tidal, Audiomack, Anghami, Qobuz |
| **Industry Data** | MLC, Jaxsta, Genius |
| **Auth** | Auth0, Facebook, Google, Apple Sign-In |
| **Marketing** | Amplitude, Segment, Klaviyo, Knock |
| **Support** | Intercom |

---

Last updated: 2026-01-16
