# MEMORY.md — SCOUT (Research Agent)

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned
_(none yet — agent will populate during operation)_

## Key Context
_(initialized 2026-06-17 — Scout repurposed from the dormant design agent slot)_

- Scout owns web research, competitive/market intelligence, and the company-finder pipeline.
- Research runs through `web_search` + `web_fetch` (the fleet's managed search provider); for deep
  dives, run several focused `web_search` passes and synthesize.
- Company-finder shared reference files (target verticals, parent companies, config) are the
  single source of truth in CMO's outreach-engine and are read/written at absolute paths — never
  copy them locally, or the two diverge.
- Outreach EXECUTION (sends, GHL, Klaviyo, enrichment) is @CMO's job, not Scout's.

## People Quick Reference
| Slack User ID | Name | Role | Notes |
|---------------|------|------|-------|
| U7RP6HKUZ | Aaron Kaufman | CEO/CTO | Founder. Final authority. Approves company batches. |
| — | McLaren | B2B Ads | Requests company batches, reports review outcomes. |
| U0AL36NADEY | Nick Sollazzo | Owner | Primary research requester. Approves company batches. |
