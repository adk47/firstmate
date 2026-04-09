---
title: Email Marketing Benchmarks
description: Open rates, reply rates, conversion targets for Muso campaigns
type: benchmark
status: active
source: MEMORY.md migration, conversation 2026-04-09
last-verified: 2026-04-09
related: [[platforms/klaviyo]], [[workflows/outreach-engine]]
---

# Email Marketing Benchmarks

Use these as the reference for "is this campaign performing well or not".

## Klaviyo (Existing Subscribers)

| Metric | Muso Benchmark | Industry Average | Notes |
|--------|---------------|------------------|-------|
| Email open rate | 60 to 70% | ~30% | Muso runs well above industry |
| Click rate | TBD | ~3% | Capture next time we pull data |
| Unsubscribe rate | TBD | ~0.5% | Capture next time |

**Klaviyo is OFF LIMITS for cold outreach.** Existing subscribers and customers only.

## B2B Ads Cold Outreach

| Metric | Target | Industry Cold Outreach Avg | Notes |
|--------|--------|---------------------------|-------|
| Reply rate | > 15% | 1 to 3% | Private Invite template historically beats this |
| Meeting rate (per send) | > 5% | < 1% | Strong signal of fit |
| Meeting rate (per reply) | > 30% | varies | Indicates quality of replies |

## Win Back (Churned Pro Subscribers)

Past test data:
- Test batch (11 emails, Feb 26 2026): 0 replies, 0 conversions. Sample too small.
- Larger batches: pending.

**Note**: a previously claimed "52.9% win back conversion" is unverified and was
removed from MEMORY.md per Fede directive 2026-04-09. Real numbers will be
captured once campaigns run at scale.

## Encore Campaign (Annual)

- Runs November to February each year
- December is the acquisition spike
- January to February is the churn wave (~35% of cancels)
- **Compare year over year, not month over month** (seasonal pattern)

## How To Use These

1. When writing reports (`muso-outreach-reporter`), compare actuals to these benchmarks.
2. When building forecasts, anchor expectations on these numbers.
3. When a campaign falls below benchmark, investigate before declaring failure (could be small sample size).
4. When a campaign blows past benchmark, capture what worked in [[lessons/]] for future use.

## Verification Cadence

These benchmarks should be re verified quarterly. Last verified 2026-04-09.

## History

- 2026-04-09: created. Win back 52.9% number removed as unverified. Other numbers from MEMORY.md migration.
