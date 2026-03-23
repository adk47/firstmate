# /clio - Muso.AI Development Command

Your resident Muse of Music History. Execute development tasks with guided assistance.

## Usage

```
/clio <task description>
```

## Task Routing

When invoked, determine the appropriate system and load its references:

### Backend Tasks
**Keywords:** api, endpoint, route, worker, sqs, sequelize, model, auth, jwt, express
**Action:** Load `references/core-backend/` and work in `core-backend` repo

Examples:
- `/clio add a new profile endpoint`
- `/clio create a background worker for notifications`
- `/clio fix the subscription webhook handler`

### Web Frontend Tasks
**Keywords:** nuxt, vue, frontend, page, component, vuex, pinia, tailwind, element-ui
**Action:** Load `references/web-credits/` and work in `web-credits` repo

Examples:
- `/clio add analytics charts to the profile page`
- `/clio fix the roster management UI`
- `/clio implement a new settings page`

### Mobile Tasks
**Keywords:** flutter, dart, bloc, mobile, ios, android, widget, auto_route
**Action:** Load `references/mobile/` and work in `mobile` repo

Examples:
- `/clio fix the login flow on iOS`
- `/clio add a new insights screen`
- `/clio implement push notifications`

### Data Pipeline Tasks
**Keywords:** airflow, dag, spark, pipeline, etl, s3, data lake, calculation
**Action:** Load `references/data-platform/` and work in `platform-data-processing` repo

Examples:
- `/clio create a new import DAG for a streaming source`
- `/clio debug the OLAP calculation job`
- `/clio add a new materialization step`

### Catalog Processing Tasks
**Keywords:** catalog, raw, industry, fastapi, mongodb, sqs worker, process_raw, process_catalog
**Action:** Load `references/industry-data/` and work in `industry-data-processing` repo

Examples:
- `/clio add support for a new data source`
- `/clio fix the catalog merge logic`
- `/clio optimize the raw processing worker`

### Analytics Capture Tasks
**Keywords:** analytics worker, capture, streaming stats, spotify stats, youtube stats, tiktok, shazam
**Action:** Load `references/analytics-worker/` and work in `analytics-worker` repo

Examples:
- `/clio add TikTok stats capture`
- `/clio fix the Spotify rate limiting`
- `/clio improve the S3 data lake storage`

### Infrastructure Tasks
**Keywords:** terraform, ecs, eks, jenkins, ci/cd, deploy, infrastructure, devops
**Action:** Load `references/devops/` and work in `devops` repo

Examples:
- `/clio set up a new ECS service`
- `/clio configure autoscaling for analytics workers`
- `/clio fix the Jenkins pipeline`

### Business/Product Tasks
**Keywords:** business, product, pricing, subscription, feature, user story
**Action:** Load `references/business/`

Examples:
- `/clio explain how profile claiming works`
- `/clio describe the subscription tiers`
- `/clio what is the MLC gap detection feature`

## Execution Steps

1. **Parse the task** - Identify keywords and determine the target system
2. **Load references** - Load the appropriate `references/<system>/` files
3. **Verify setup** - Check if working in the correct repository
4. **Execute task** - Follow patterns from `patterns.md`, avoid issues in `gotchas.md`
5. **Test** - Run tests appropriate to the system
6. **Document** - Update relevant docs if adding new features

## Cross-System Tasks

For tasks spanning multiple systems:
1. Identify all affected systems
2. Load references for each
3. Plan changes in dependency order (typically: data -> backend -> frontend)
4. Execute changes sequentially
5. Test integration points

Example: `/clio add a new analytics metric end-to-end`
- Load: industry-data, core-backend, web-credits
- Order: Add to catalog -> Expose via API -> Display in UI
