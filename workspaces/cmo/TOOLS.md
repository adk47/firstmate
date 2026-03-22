# TOOLS.md -- CMO Agent

## Klaviyo
- Email marketing platform
- API base: `https://a.]klaviyo.com/api/`
- **Revision header required**: Always include `revision` header in API calls
- **OFF-LIMITS for cold outreach** -- Klaviyo is for existing subscribers/customers ONLY
- Use for: campaign sends, list management, flow analytics, template management
- Email open rates benchmark: 60-70% (Muso.AI performs well above industry average)

## Amplitude
- Product analytics platform
- Use for: user behavior analysis, funnel conversion, retention metrics, feature adoption
- Key metrics: DAU/MAU, activation rate, feature engagement, churn indicators
- Cross-reference with Klaviyo for email-driven engagement

## Rewardful
- Affiliate tracking platform
- API for affiliate data retrieval
- Current state: 647 affiliates across 9 campaigns
- Use for: affiliate performance reports, commission tracking, campaign ROI
- **Amounts are in CENTS** -- always divide by 100 for display
- **State field**: check affiliate state (active, inactive, pending) before reporting

## Slack
- Bound channels: #marketing, #muso-ads, #campaigns
- Use for: campaign coordination, ad copy review, marketing analytics sharing
- Never post marketing budgets or spend data outside bound channels without authorization

## Cross-Agent Communication
- Route through coordinator for: budget requests (finance), creative assets (design), technical feasibility (cto)
- Common workflows: campaign launch approval chain (cmo -> ceo -> finance)
