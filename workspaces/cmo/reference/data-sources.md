# Data Sources

Canonical source mapping for analytics/data work.

- **Stripe via Finance**: Current MRR, ARR, subscriber counts, churn, LTV, and recurring-revenue analysis. Finance follows `muso-stripe-subscription-analytics` and discloses definitions and scope gaps.
- **ProfitWell**: Secondary cash/payment cross-reference (actual payments are not the same as recurring run rate)
- **ChartMogul**: Retired; historical artifacts only, never a source for current metrics
- **Klaviyo**: Email campaigns, flows, attributed revenue (existing subscribers ONLY)
- **Amplitude**: Product analytics, funnels, MAU/DAU
- **Trino**: Backend stats, ad events, profile enrichment (NOT lead sourcing). Queries written
  as Athena SQL are transparently routed to Trino on OVH. **There is no live AWS Athena and
  no AWS identity to authenticate against, so an `InvalidClientTokenId` (or any AWS
  credential/identity error) means you reached for the retired client — not that a credential
  expired.** Claiming lives in `postgresql_core.public.claiming`;
  catalog in `hive."platform-industry-bi-prod"`. **Do not escalate AWS credential errors** —
  switch to the Trino path.
  _(corrected 2026-08-26: was "**Athena**: Backend stats, ad events, profile enrichment (NOT
  lead sourcing)". AWS was decommissioned 2026-05-31; the Athena name survives only as a SQL
  dialect, which is why agents kept reading a dead credential error as an outage.)_
- **GA4**: Website traffic (not connected yet)
- **Meta Ads**: Paid social (not connected yet)
- **Meta Suite**: Organic social (not connected yet)
