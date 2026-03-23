# KT: 2026-01-28_industry-processing-1 (Curated)

- As-of: 2026-01-28
- Participants: Serhii Ostapchuk, Oleg Mamchich
- Systems mentioned: Aurora, MongoDB, RDS, Retool, Spotify, Tidal

## Purpose

Curate stable, reusable knowledge from this KT session into the deployed knowledge base.
Raw transcripts and full meeting artifacts remain repo-only under `kt-recordings/`.

## Key takeaways (stable)

- API Performance and Outliers (00:03:40): The dashboard metrics show response codes , P99, average, and maximum response times for the API . Oleg Mamchich explained that high maximum request times often result from "outliers" like complex queries on large profiles, which are difficult to eliminate en…
- Backend API Protection and Internal Service Access (00:10:04): Oleg Mamchich noted that the core pro API, the backend, has minimal default bot control protection due to the high risk associated with blocking requests on the backend, which are used by mobile apps and other services . The industry data processing API is an…
- Capture Queue and Prioritization Issues (01:14:49): Oleg Mamchich highlighted the dire state of the high-priority capture queue due to external service problems, noting they attempted to mitigate this by limiting the number of workers . They explained the current high-priority queue is not for SLAs, but handle…
- Database Structure and Catalog Data Storage (00:38:40): The database includes raw collections and catalog collections . In the catalog, Track entities store all associated data, including formerly separate credit properties like popularity and release date, to improve performance for queries such as sorting . Oleg…
- Data Prioritization and Field Sourcing (00:21:18): Jay Ruffing asked about the source of truth for specific fields across different systems . Oleg Mamchich clarified that priority is defined at the entity level, not the field level, and is applied consistently to all fields. Data synchronization proceeds from…
- Suggested next step: [ ] Oleg Mamchich will try to finish and push the branch that addresses the issue of one capture Q request making a lot of API calls using the same credentials, and will add Serhii Ostapchuk as a reviewer.
- Challenges with New Data Table Migration (00:47:10): Serhii Ostapchuk asked why the transition to the new Aurora table is incomplete. Oleg Mamchich cited several challenges, including an accidental push to production and the issue of real-time data: the new table is updated daily, so new credits may not appear…
- Addressing Big Artist Capture and Re-queuing Issues (01:28:55): Oleg Mamchich speculated that when a "big artist" appears in the queue, the high volume of API calls for their albums might cause the specific credential to be rate-limited, and they have a branch to randomize credentials used for such large requests to mitig…
- Impact of Spotify Issues on Data Quality (01:10:19): Jay Ruffing asked about the current stability of the sync process, to which Oleg Mamchich responded that while the sync itself generally works, external issues, specifically changes with Spotify, are causing problems, impacting the automatic fixing of data qu…
- Scraping Protection and Amazon WAF (00:06:19): Jay Ruffing inquired about site scraping, to which Oleg Mamchich responded that scraping is a constant issue . Protection is handled using the default Amazon WAF with specific rule sets, including a rate limit based on a GA4 fingerprint . This method, which u…
- Challenges with Spotify Credentials and Application Creation (01:22:36): Jay Ruffing suggested using a specific command, but Oleg Mamchich explained that accounts using the standard format were blocked, necessitating the creation of 490 unique profiles to avoid association with music. The team cannot simply create more Spotify acc…
- Data Overwriting and Extension in Sync (01:05:41): When syncing, many fields are overwritten, such as first name, last name, and contacts, while other identifier fields like IPIs, ISRCs, or UPCs are extended rather than overwritten. Oleg Mamchich explained that extending these identifiers is necessary to ensu…

## Recommended skill enhancements

### API Performance and Outliers
- Add/update: `skills/muso-clio/references/industry-data/overview.md`
- Why: missing vs current best match `skills/muso-clio/references/(none)` (score 0.00)

### Backend API Protection and Internal Service Access
- Add/update: `skills/muso-clio/references/devops/overview.md`
- Why: missing vs current best match `skills/muso-clio/references/(none)` (score 0.00)

### Capture Queue and Prioritization Issues
- Add/update: `skills/muso-clio/references/devops/overview.md`
- Why: missing vs current best match `skills/muso-clio/references/data-platform/formulas.md` (score 0.25)

### Database Structure and Catalog Data Storage
- Add/update: `skills/muso-clio/references/architecture/database.md`
- Why: partial vs current best match `skills/muso-clio/references/architecture/services-overview.md` (score 0.28)

### Data Prioritization and Field Sourcing
- Add/update: `skills/muso-clio/references/industry-data/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/industry-data/patterns.md` (score 0.29)

### Suggested next step
- Add/update: `skills/muso-clio/references/industry-data/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/devops/README.md` (score 0.30)

### Challenges with New Data Table Migration
- Add/update: `skills/muso-clio/references/architecture/database.md`
- Why: partial vs current best match `skills/muso-clio/references/architecture/services-overview.md` (score 0.32)

### Addressing Big Artist Capture and Re-queuing Issues
- Add/update: `skills/muso-clio/references/industry-data/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/analytics-worker/gotchas.md` (score 0.32)

### Impact of Spotify Issues on Data Quality
- Add/update: `skills/muso-clio/references/industry-data/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/operations/retool.md` (score 0.33)

### Scraping Protection and Amazon WAF
- Add/update: `skills/muso-clio/references/devops/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/architecture/services-overview.md` (score 0.33)

### Challenges with Spotify Credentials and Application Creation
- Add/update: `skills/muso-clio/references/devops/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/data-model/data-dictionary.md` (score 0.36)

### Data Overwriting and Extension in Sync
- Add/update: `skills/muso-clio/references/industry-data/overview.md`
- Why: partial vs current best match `skills/muso-clio/references/athena/SKILL.md` (score 0.38)

## Provenance (repo-only)

- Meeting artifacts: `kt-recordings/2026-01-28_industry-processing-1/`
- Transcript: ?tab=t.t25aedwmaed1
- Recording: https://drive.google.com/file/d/1W3NP8Ufl8fL3XOaGUFiQc_ZrlRv81fVn/view?usp=drive_web
