# API Reference

## API Surface Map

```text
Clients
  - Web Credits (Nuxt)   -> CloudFront + WAF -> Core Backend API
  - Mobile App (Flutter) -> CloudFront + WAF -> Core Backend API
  - Partners             -> API Gateway (x-api-key) -> Core Backend API
  - Internal tools        -> Industry Data API (FastAPI)

API surfaces
  Core Backend API routes:
    /api/v4
    /api/w/v2, /api/w/v3
    /api/m/v2, /api/m/v3
    /api/i/*
    /api/c/v4, /api/c/v4a
  Industry Data API routes:
    /api/v1/*

Core Backend API dependencies
  Core Backend API -> Industry Data API
  Core Backend API -> PostgreSQL (core/analytics/stats)
  Core Backend API -> Redis
  Core Backend API -> SQS

Industry Data API dependencies
  Industry Data API -> MongoDB Atlas (industry)
  Industry Data API -> PostgreSQL (stats/catalog)
```

## Core Backend API Routes

| Route Prefix | Client | Purpose |
|--------------|--------|---------|
| `/api/v4` | Admin/Internal | Admin API |
| `/api/w/v2`, `/api/w/v3` | Web | Web-specific endpoints |
| `/api/m/v2`, `/api/m/v3` | Mobile | Mobile-specific endpoints |
| `/api/c/v2`, `/api/c/v4`, `/api/c/v4a` | Partners | Customer/Developer API |
| `/api/i/` | External | Integration webhooks |
| `/` | Public | Public routes |

### Main API Modules

| Module | Functionality |
|--------|---------------|
| **profile** | Artist/professional profiles, collaborators, albums, roles |
| **user** | User account management, authentication, settings |
| **team** | Workspace management, team members, permissions |
| **analytics** | Profile analytics, streaming stats, weekly summaries |
| **song** | Track/song data, credits, sources |
| **collection** | Album collections and management |
| **feed** | Social activity feed (follows, posts, reactions) |
| **milestones** | Achievement tracking (streaming milestones) |
| **payment** | Subscription management, billing |
| **orders** | Merchandise/poster orders |
| **search** | Full-text search across entities |
| **spotify** | Spotify OAuth, playlist management |
| **checklist** | Onboarding checklist tracking |
| **lists** | Custom list management |
| **invitation** | Team invitation system |

## Industry Data API (FastAPI)

| Endpoint | Purpose |
|----------|---------|
| `/api/v1/profile/{id}` | Profile details |
| `/api/v1/track/{id}` | Track details with credits |
| `/api/v1/album/{id}` | Album details |
| `/api/v1/search` | Search profiles, tracks, albums |
| `/api/v1/stats` | Analytics statistics |

## Authentication Flow

```text
Login
  Client -> Core Backend: POST /login (email, password)
  Core Backend -> Auth0: validate credentials
  Auth0 -> Core Backend: Auth0 token + user info
  Core Backend -> PostgreSQL: find/create user
  Core Backend -> Client: JWT token + user data

Authenticated request
  Client -> Core Backend: GET /api/v4/profile (Authorization: Bearer <JWT>)
  Core Backend: TokenValidation -> ACL (role check) -> DB query
  Core Backend -> Client: response
```

## Customer API Flow (Developer API)

```text
Partner request (Customer/Developer API)
  Partner -> API Gateway: GET /v4/... (x-api-key)
  API Gateway: validate API key
  API Gateway -> ALB: forward request + inject x-api-gw-auth header
  ALB -> Core Backend: route to core-backend
  Core Backend: validate x-api-gw-auth
  Core Backend -> Partner: response
```

## Key Traffic Flows

### Public Web Request
```
User -> Route53 -> CloudFront (WAF) -> Public ALB -> ECS (website/credits)
```

### API Request
```
Client -> Route53 -> Public ALB -> ECS (core-backend-api)
```

### Customer API Request
```
Partner -> Route53 -> API Gateway -> Public ALB (+ auth header) -> ECS (core-backend)
```

### Static Assets
```
Browser -> CloudFront (assets CDN) -> S3 (via OAI)
```

### Background Job
```
Core API -> SQS queue -> Core Worker -> RDS/S3/external services
```
