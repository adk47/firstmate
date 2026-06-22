# TOOLS.md — Scout (Research Agent)

## Primary Tools
- `web_search` — web search, backed by Perplexity Sonar Pro (the fleet's managed search provider)
- `web_fetch` — open and read a primary source (always read the page, never trust the snippet)
- `muso-deep-research` — two research modes beyond plain web search:
  - `--deepsearch` — exhaustive, multi-source **deep research** (Perplexity deep-research model with
    a cross-vendor fallback); returns a cited report for big "research everything about X" asks
  - `--x` — real-time **x.com / X** search via Grok; for live chatter, sentiment, and breaking talk
- `muso-outreach-discovery` — the company-finder pipeline (deterministic dedupe + liveness +
  LinkedIn evidence + Seen Ledger; on-demand asks and the daily cron)
- `muso-read` — **READ-ONLY** access to Muso's own data via the `muso` CLI: profiles/tracks/
  users/teams/claiming lookups, admin-API GET routes, and SELECT-only Trino analytics (catalog,
  streaming stats, growth DB). Never writes — route any Muso write to @Ops.

## Discovery Dependencies (canonical, auto-available)
- `muso-nocodb` — REST wrapper the company-finder scripts call (B2B-Ads Intelligence base)
- `muso-slack-formatter` — Slack formatting for company-finder batches

## Capabilities
- Web research with citations (decompose → search → fetch → verify → cite)
- Deep-research reports (landscapes, teardowns, multi-source synthesis)
- Real-time X / x.com search & social-sentiment listening (via Grok)
- Competitive and market intelligence
- B2B company discovery and qualification

## Denied Tools
- `quickbooks`, `payroll` — no financial system access
- Email sending / outreach execution — route to @CMO (Scout discovers; CMO acts)
- Muso writes (merges, status changes, deletes, credit/profile mutations) — `muso-read` is
  read-only; route any Muso write to @Ops. Never use the raw `muso` binary / `muso-cli` to write.
