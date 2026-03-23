# KT: Capture Service (2026-01-22)

**Source**: `kt-recordings/2026-01-22_capture-service/`
**Participants**: Oleg Mamchich, Jay Ruffing
**Duration**: ~1h 35m

## Session Summary

Deep dive into the capture service architecture, including live debugging of a Genius parser issue.

## Key Topics Covered

### Architecture
- Three-service architecture: Interface → Scheduler → Worker
- Interface handles priority routing (high = direct, other = database)
- Scheduler reads DB daily with priority-based SLAs
- **Planned deprecation**: Move scheduling to Airflow, eliminate scheduler service + DB

### Proxy Configuration (WebShare)
- 5,000 European proxies ($346/mo monthly refresh)
- Worker implements in-memory blacklist per source
- Countries chosen to avoid blocking (US/Asia blocked more)

### Scraping Approach
- Most sources: reverse-engineered internal JSON APIs
- HTML scraping only: Genius, Shazam
- User agent rotation from static list

### Live Debugging Session
1. Investigated Jaxsta errors → discovered service hibernated (deprecated)
2. Fixed Genius 403 error by adding cookie header
3. Deployed fix to prod via Jenkins pipeline

### Source Importance
- **Critical**: Spotify, Tidal (catalog + credits)
- **Analytics**: Streams most important; partner feeds + scraped
- **Deprecated**: Jaxsta (ceased operations), Genius (low priority)

### External Partners
- **Zyte**: Handles high-volume Spotify **analytics** scraping (~1M/day, streams/popularity only), all Instagram (video links, streams, video data)
- **MLC**: Weekly data import for cross-platform track linking via ISRC

### Deployment
- Version bump in `.version` file required
- Push to main → auto-deploy dev → manual approval for prod
- Helm configs in `ops/helm/analytics-worker/values*.yaml`
- KEDA autoscaling based on SQS queue depth

## Action Items from Meeting

- [x] Add deploy section to analytics-worker README
- [x] Document proxy configuration
- [ ] Add Jay to #cicd-notifications channel
- [ ] Consider Python engineer for capture service support

## Documentation Created

Knowledge from this session was integrated into:
- `analytics-worker/capture-service-architecture.md` (new)
- `analytics-worker/configuration.md` (proxy, deployment sections)
- `analytics-worker/patterns.md` (scraping patterns)
- `analytics-worker/overview.md` (source hierarchy, Jaxsta deprecation)
- `architecture/integrations.md` (Zyte details)
- `data-platform/overview.md` (MLC linking workflow)
