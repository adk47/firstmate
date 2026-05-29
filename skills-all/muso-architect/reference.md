# Muso Architect Reference

## Overview

The **muso-architect** skill provides comprehensive knowledge of Muso's system architecture, including service topology, team structure, data flow patterns, and integration points. Use this skill when designing new features, troubleshooting cross-service issues, or understanding how components interact across the platform.

## Key Concepts

**Platform Team**: Two-engineer team (Andre and Oleg Mamchich) responsible for data pipelines, infrastructure, and catalog microservices. Andre handles ~80% of data pipeline work.[^1]

**Catalog/Growth Merge**: The Catalog and Growth teams have been merged into a single unit, with catalog microservices now primarily owned by Oleg Mamchich.[^2]

**Capture Service**: Multi-repository system (worker, scheduler, interface) responsible for fetching external data from platforms like Spotify, Tidal, YouTube, and others through web scraping and API calls.[^3]

**Core Backend API**: Primary client interaction point that handles authentication, user management, and orchestrates requests to downstream services like Industry API.[^4]

**Industry API**: Service providing music industry data (tracks, profiles, releases) to Core Backend API in real-time.[^5]

**Raw vs Catalog Entities**: Raw entities represent platform-specific data (e.g., Spotify track), while catalog entities are merged, canonical representations across multiple sources.[^6]

**Profile Merging**: Process of consolidating duplicate profiles using `is_deleted` flag and `merged_to_id` field, supporting up to 3-5 recursive redirects.[^7]

## Architecture

### System Topology

```text
Clients/Apps
  |
  v
Core Backend API
  |--> User Database
  |
  v
Industry API
  |
  v
Capture Interface Service
  |
  v
Capture Scheduler Service
  |
  v
Analytics Worker
  |--> S3 Data Lake --> Trino (query, OVH — Athena retired 2026-04-25)
  `--> Aurora Catalog DB
```

### Team Ownership

| Component | Team | Primary Owner |
|-----------|------|---------------|
| Core Backend API | Platform | Platform Team |
| Industry API | Platform | Platform Team |
| Capture Services | Catalog | Oleg Mamchich |
| Data Pipelines | Platform | Andre (80%) |
| User Database | Growth | Growth Team |
| Catalog Microservices | Catalog | Oleg Mamchich |

### Data Flow Patterns

**Client Request Flow**:
1. Client → Core Backend API (authentication layer)[^8]
2. Core Backend API → User Database (for user-related data)
3. Core Backend API → Industry API (for music industry data)[^9]
4. Response combines user + industry data

**Capture Task Flow**:
1. Tasks enter Capture Interface Service queue[^10]
2. Routed to source-specific worker queues (Spotify, Tidal, YouTube, etc.)
3. Workers fetch data via web scraping or APIs
4. Retry up to 5 times on failure[^11]
5. Raw data → S3 Data Lake
6. Catalog data → Aurora Catalog Database[^12]

**Data Export Flow**:
- Weekly full dumps + deltas exported to S3[^13]
- S3 data queried via Athena for analytics[^14]
- Airflow pipelines prepare data for external partners (e.g., Zyte)[^15]

## Service Inventory

### Core Backend API
**Type**: REST API  
**Team**: Platform  
**Purpose**: Primary client interaction point and authentication layer

**Responsibilities**:
- User registration and login
- Roster management
- Authentication for all client requests[^16]
- Orchestrating requests to Industry API for music data[^17]
- Combining user-related data with music industry information

**Database**: User Database (maintained by Growth team)[^18]

**Integrations**:
- Industry API (real-time queries)
- S3 (weekly exports + deltas)[^19]

---

### Industry API
**Type**: REST API  
**Team**: Platform  
**Purpose**: Provides music industry data (tracks, profiles, releases)

**Responsibilities**:
- Serving catalog entities (tracks, profiles, releases)
- Handling recording and release credits[^20]
- Linking external platform IDs to Muso track IDs[^21]

**Data Sources**:
- Aurora Catalog Database
- Requests missing data from Capture Interface Service[^22]

---

### Capture Interface Service
**Type**: Task Queue Manager  
**Team**: Catalog  
**Owner**: Oleg Mamchich  
**Repository**: Part of multi-repo capture system

**Responsibilities**:
- Receiving capture task requests
- Routing tasks to source-specific worker queues[^23]
- Tracking last request time for external IDs[^24]
- Managing task priorities

**Configuration**:
- Retry limit: 5 attempts[^25]
- Stores last request timestamps in PostgreSQL

**External Sources**: Spotify, Tidal, YouTube, Stripe, Apple Pay, Google Pay, Amplitude[^26]

---

### Capture Scheduler Service
**Type**: Task Scheduler  
**Team**: Catalog  
**Repository**: Part of multi-repo capture system

**Responsibilities**:
- Distributing capture tasks to Analytics Workers
- Managing task scheduling and prioritization[^27]

---

### Analytics Worker
**Type**: Background Worker  
**Team**: Catalog  
**Repository**: Part of multi-repo capture system

**Responsibilities**:
- Executing web scraping for external platforms
- Making API calls to external services
- Data quality checks and augmentation[^28]
- Routing data to appropriate queues (raw vs catalog)[^29]

**Scraping Targets**:
- Spotify (via ~500 rotating credentials)[^30]
- Genius (HTML scraping)[^31]
- Shazam (HTML scraping)[^32]
- Other platforms via APIs

**Infrastructure**:
- WebShare proxy service (5,000 European proxies)[^33]
- Custom proxy rotation with caching of failed proxies[^34]
- Automatic user agent rotation[^35]

**Configuration**:
- Proxy refresh: Monthly (desire for weekly)[^36]
- Spotify credentials: ~500 accounts, randomly selected[^37]
- Credential testing: Periodic script validates working credentials[^38]

---

### Airflow Pipelines
**Type**: Data Pipeline Orchestration  
**Team**: Platform  
**Owner**: Andre (manages ~80% of pipeline work)[^39]

**Responsibilities**:
- Data transformation and aggregation
- Snapshot management (Andre responsible for additions)[^40]
- External partner data preparation (e.g., Zyte)[^41]
- Profile aggregation and catalog database insertion[^42]

**Key Pipelines**:
- Profile aggregation → Aurora Catalog Database
- External persist pipeline (triggered by Andre)[^43]
- Weekly S3 exports

---

### External Integrations

**Zyte**: External scraping partner receiving base URLs and capture specifications[^44]

**Notion**: Documentation platform for:
- Common commands and configurations[^45]
- SSH keys (separate dev/prod for tunneling)[^46]
- Event tracking (191+ Amplitude analytics events)[^47]

**ClickUp**: Primary project management tool for DevOps team[^48]

**Retool**: Used for profile deletion workflows[^49]

## Quick Reference

### Configuration Values

| Setting | Value | Context |
|---------|-------|---------|
| Capture retry limit | 5 attempts | Before throwing error[^50] |
| Profile merge redirect limit | 3-5 hops | Recursive merge support[^51] |
| Spotify credentials | ~500 accounts | Rotating pool[^52] |
| WebShare proxies | 5,000 | Primarily European[^53] |
| Proxy refresh cycle | Monthly | Desired: weekly[^54] |
| Amplitude events documented | 191+ | Potential undocumented events[^55] |

### Team Contacts

| Role | Person | Responsibilities |
|------|--------|------------------|
| Senior Data Engineer | Andre | 80% of data pipelines, Airflow, snapshots |
| Platform Engineer | Oleg Mamchich | Catalog microservices, capture services |
| Engineering Lead | Aaron | Morning meetings (7:00 AM)[^56] |
| Operations | Aaron | User request handling, hiring decisions[^57] |

### Common Procedures

**Profile Deletion**:
1. Verify profile size (e.g., single track)[^58]
2. Use Retool for small deletions
3. For complex cases: Python notebook scripts in separate branch[^59]

**Notion Cleanup**:
1. Create archive space for irrelevant content[^60]
2. Oleg identifies relevant engineering content[^61]

**Spotify Rate Limiting Mitigation**:
- Rotate through credential pool
- Periodic validation script
- Note: Spotify reduced limits after December data leak[^62]

### Data Structures

**Profile Merge Fields**:
- `is_deleted`: Boolean flag for API visibility[^63]
- `merged_to_id`: Target profile ID for redirects[^64]

**Capture Task Tracking**:
- Last request timestamp per external ID[^65]
- Source-specific worker queues
- Priority-based routing

## Known Gaps

- Service 'Core Workers' mentioned in bootstrap but not found in extracted items

## Source Attribution

[^1]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 2, 00:04:37-00:05:47
[^2]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 2, 00:04:37-00:05:47
[^3]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^4]: 2026-01-19_devops-discussion, chunk 3, 00:07:11-00:08:13
[^5]: 2026-01-19_devops-discussion, chunk 3, 00:07:11-00:08:13
[^6]: 2026-01-16_part-2, chunk 8, timestamp range not specified
[^7]: 2026-01-20_user-requests, chunk 12, 00:38:53-00:40:19
[^8]: 2026-01-19_devops-discussion, chunk 3, 00:07:11-00:08:13
[^9]: 2026-01-19_devops-discussion, chunk 3, 00:07:11-00:08:13
[^10]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^11]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^12]: 2026-01-22_capture-service, chunk 5, timestamp range not specified
[^13]: 2026-01-19_devops-discussion, chunk 1, timestamp range not specified
[^14]: 2026-01-19_devops-discussion, chunk 10, timestamp range not specified
[^15]: 2026-01-21_athena-part-3, chunk 1, timestamp range not specified
[^16]: 2026-01-19_devops-discussion, chunk 3, 00:07:11-00:08:13
[^17]: 2026-01-19_devops-discussion, chunk 3, 00:07:11-00:08:13
[^18]: 2026-01-19_devops-discussion, chunk 0, timestamp range not specified
[^19]: 2026-01-19_devops-discussion, chunk 1, timestamp range not specified
[^20]: 2026-01-16_part-2, chunk 7, timestamp range not specified
[^21]: 2026-01-16_part-2, chunk 14, timestamp range not specified
[^22]: 2026-01-19_devops-discussion, chunk 7, timestamp range not specified
[^23]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^24]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^25]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^26]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^27]: 2026-01-22_capture-service, chunk 1, timestamp range not specified
[^28]: 2026-01-22_capture-service, chunk 3, timestamp range not specified
[^29]: 2026-01-22_capture-service, chunk 5, timestamp range not specified
[^30]: 2026-01-22_capture-service, chunk 10, 00:51:57
[^31]: 2026-01-22_capture-service, chunk 11, 00:44:08-00:55:08
[^32]: 2026-01-22_capture-service, chunk 11, 00:44:08-00:55:08
[^33]: 2026-01-22_capture-service, chunk 7, 00:15:58-00:21:24
[^34]: 2026-01-22_capture-service, chunk 7, 00:15:58-00:21:24
[^35]: 2026-01-22_capture-service, chunk 11, 00:44:08-00:55:08
[^36]: 2026-01-22_capture-service, chunk 7, 00:15:58-00:21:24
[^37]: 2026-01-22_capture-service, chunk 10, 00:51:57
[^38]: 2026-01-22_capture-service, chunk 10, 00:51:57
[^39]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 2, 00:04:37-00:05:47
[^40]: 2026-01-20_athena-part-2, chunk 1, timestamp range not specified
[^41]: 2026-01-21_athena-part-3, chunk 1, timestamp range not specified
[^42]: 2026-01-21_athena-part-3, chunk 10, timestamp range not specified
[^43]: 2026-01-21_athena-part-3, chunk 14, timestamp range not specified
[^44]: 2026-01-22_capture-service, chunk 17, timestamp range not specified
[^45]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 4, 00:08:16-00:10:19
[^46]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 4, 00:08:16-00:10:19
[^47]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 4, 00:08:16-00:10:19
[^48]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 8, timestamp range not specified
[^49]: 2026-01-20_user-requests, chunk 3, 00:07:55-00:09:03
[^50]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
[^51]: 2026-01-20_user-requests, chunk 12, 00:38:53-00:40:19
[^52]: 2026-01-22_capture-service, chunk 10, 00:51:57
[^53]: 2026-01-22_capture-service, chunk 7, 00:15:58-00:21:24
[^54]: 2026-01-22_capture-service, chunk 7, 00:15:58-00:21:24
[^55]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 4, 00:08:16-00:10:19
[^56]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 10, 00:33:29-00:34:12
[^57]: 2026-01-19_devops-discussion, chunk 13, timestamp range not specified
[^58]: 2026-01-20_user-requests, chunk 3, 00:07:55-00:09:03
[^59]: 2026-01-20_user-requests, chunk 3, 00:07:55-00:09:03
[^60]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 10, 00:33:29-00:34:12
[^61]: 2026-01-14_meeting-jan-14-2026-at-19-21-eet, chunk 10, 00:33:29-00:34:12
[^62]: 2026-01-22_capture-service, chunk 10, 00:51:57
[^63]: 2026-01-20_user-requests, chunk 12, 00:38:53-00:40:19
[^64]: 2026-01-20_user-requests, chunk 12, 00:38:53-00:40:19
[^65]: 2026-01-16_part-2, chunk 5, 00:07:59-00:13:12
