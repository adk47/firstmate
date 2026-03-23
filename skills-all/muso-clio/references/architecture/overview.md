# Muso.ai Platform Architecture

This document provides the high-level system overview and document map. For compact context loading, see `cheatsheet.md`.

## High-Level System Diagram

Shows users, edge services, compute platforms, data stores, and external integrations.

```text
Users & Clients
  - Web users (web-credits)
  - Mobile apps (iOS/Android)
  - Partners (Customer API)

Edge Layer (AWS)
  Route 53
    |--> CloudFront + WAF (website/credits/assets)
    `--> API Gateway (Customer API)

Compute Layer
  Public ALB
    |--> ECS on EC2: core-backend API, ai-chat-api, website, credits app, core workers, posters, render-service
    `--> (routes to EKS services as needed)
  EKS Cluster: feed-service, analytics-worker (capture), industry-processing

Core Backend API dependencies
  core-backend
    |--> RDS Postgres (core/analytics/stats/catalog/olap)
    |--> Redis
    |--> MongoDB Atlas (industry)
    |--> SQS
    |--> S3
    `--> External: Auth0, Stripe, Catalog API

Data Processing Platform (EKS)
  Airflow -> Spark
  Airflow/Spark -> S3 (data lake)
  Airflow -> RDS / MongoDB / Elasticsearch

Analytics capture
  SQS -> analytics-worker -> S3
  analytics-worker -> Streaming APIs (Spotify/YouTube/Qobuz/Audiomack/Shazam/TikTok)

Industry processing
  industry-processing -> MongoDB Atlas
  industry-processing -> S3
```

## Document Map

### This Knowledge Base

| Document | Purpose |
|----------|---------|
| `INDEX.md` | Deployed knowledge index (load order and contract) |
| `../business/business_overview.md` | Company, products, pricing |

### Architecture Documents (by System)

| Document | Purpose |
|----------|---------|
| `../core-backend/overview.md` | Express.js API + workers |
| `../web-credits/overview.md` | Nuxt/Vue frontend |
| `../mobile/overview.md` | Flutter mobile app |
| `../data-platform/overview.md` | Airflow/Spark data pipelines |
| `../industry-data/overview.md` | SQS workers + FastAPI catalog |
| `../analytics-worker/overview.md` | Streaming/social capture |
| `../devops/overview.md` | Terraform, CI/CD, environments |

### Infrastructure Documents

| Document | Purpose |
|----------|---------|
| `database.md` | Database schema, key tables |
| `api_reference.md` | API surfaces, auth flows |
| `security.md` | Authentication, authorization |
| `integrations.md` | External services |

## External Architecture Resources

### Draw.io Diagrams
We have additional architecture diagrams stored in a shared diagrams tool.

- Treat diagram links/exports as **internal-only**; do not paste public editor/render links into Slack.
- If you need access, ask Eng/DevOps for the current location and permissions.

### Notion Documentation

| Document | Link |
|----------|------|
| Application Infrastructure Layers | [Link](https://www.notion.so/Application-Infrastructure-Layers-bd21411d005546619248368d55ee2dfb) |
| AWS Network | [Link](https://www.notion.so/AWS-Network-6054df5031c74a72824d76465095b6ae) |
| Environments Convention | [Link](https://www.notion.so/Environments-Convention-3432c5cf727440a1986831fd1a491301) |
| CI/CD Concepts | [Link](https://www.notion.so/CI-CD-Concepts-9e02d10e90af45e1a7fc28e86819e8bc) |
| Muso Engineering Guidelines | [Link](https://www.notion.so/Muso-Engineering-Guidelines-e717242b5f71401cbfb6cc5695f14b94) |
| Engineering Onboarding | [Link](https://www.notion.so/How-To-Engineering-Onboarding-0391f529fada47c5977954c22779dc70) |
| GitHub Repositories Database | [Link](https://www.notion.so/922c1d31dbd94f14aa749dc7a30cf3ab?v=d7120f7b7de14a28937066b17a1ad510) |

### Figma
- [Org Chart](https://www.figma.com/file/0Hrn5d7aVX3Q7hsk7HuXAg/Org-Chart)
- [User Journey Map](https://www.figma.com/file/EOEy98arX1QFxH0zvtPmQx/User-Journey-Map)
- [Onboarding Overview](https://www.figma.com/board/oO6gnKvep5hEiFXZv57NC3/Onboarding-Overview)

---

Last updated: 2026-01-16
