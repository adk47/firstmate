# MEMORY.md — QA Agent

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned
_(none yet — agent will populate during operation)_

## Key Context
_(initialized 2026-03-22)_

## Migrated from Clio (2026-03-23)

### Credit Request Approval Audit Trail
- Flow: User submits credit claim → core-backend API creates claim record → Admin reviews in Retool → approve/reject.
- Data source for verification: Athena `platform-core-backend-export-prod.public_claiming` + `public_teams`.
- As of Feb 28: 231 rejections in 7 days, 72% approval rate.
- **Key finding**: 160/231 rejections have NO reason logged — significant ops process gap to verify.
- Mobile app: `FollowersProviderBloc` requires `workspaceId` + `rosterSeatId` — following is gated on claimed profile.
- Test verification: confirm that approval/rejection flows work end-to-end, and that rejection reasons are being captured.

### Analytics Worker Overhaul Testing Context
- 84 commits in 3 months (Feb 2026 overhaul). Major changes to test:
  - Self-healing proxy architecture — proxies auto-rotate on failure
  - Circuit breakers — prevent cascade failures when a platform is down
  - Death spiral fix — prevents pods from endlessly retrying failed messages
  - Multi-provider proxy support (Webshare + Thordata) — fallback between providers
  - Per-platform country targeting — different proxy regions for different scrape targets
  - KEDA autoscaling up to 100 pods per queue
  - SQS batch receive — processes multiple messages per poll
- SQS volumes: ~3.5M msgs/day across all queues
- Queue backlogs to watch: YouTube, Shazam can build up to millions
- Key regression risk: proxy rotation logic, circuit breaker thresholds, KEDA scaling rules
- Lesson from production: Spotify rate limiting generates ~15K 429 errors/day — this is expected, not a bug
