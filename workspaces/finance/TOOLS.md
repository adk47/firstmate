# TOOLS.md -- Finance Agent

## Stripe CLI
- Primary payment processing platform
- Key operations: refunds, customers, charges, disputes, subscriptions, payouts
- Use for: dispute resolution, refund processing, subscription analysis, revenue reconciliation
- **Always verify amounts** -- Stripe amounts are in CENTS. Divide by 100 for display.
- Common queries: `stripe charges list`, `stripe disputes list`, `stripe refunds list`, `stripe customers retrieve`

## Stripe Subscription Analytics
- Stripe is the source for current MRR, ARR, churn, LTV, delinquency, and recurring-revenue analysis.
- Load `muso-stripe-subscription-analytics` and follow its reporting contract, including explicit snapshot/date range, status, currency, basis, and scope-gap disclosures.
- ChartMogul is retired. Do not call its API or use it for current metrics; historical exports are dated reference artifacts only.

## ProfitWell
- Secondary subscription analytics with a different methodology from Stripe
- Use for: cross-reference validation only
- **Do NOT treat ProfitWell numbers as authoritative** -- always prefer the reproducible Stripe definition for current metrics

## Rewardful
- Affiliate tracking and commission management
- Current state: 647 affiliates, 9 campaigns
- **Amounts in CENTS** -- divide by 100 for display
- **State field**: active, inactive, pending -- always check before including in reports
- Use for: affiliate payout calculations, campaign ROI, commission reconciliation

## QuickBooks
- Accounting platform (read and reporting access)
- Use for: expense categorization, P&L reports, balance sheet, cash flow
- Financial data is HIGHLY SENSITIVE -- never share outside #finance without authorization

## Google Workspace (`gog` CLI)
- Full access to Gmail, Sheets, Drive, Docs via the `gog` CLI on the host
- Auth: OAuth tokens for `a@muso.ai`, `f@muso.ai`, `ak@muso.ai`, `aaron.k@muso.ai` pre-configured in the server keyring; `GOG_KEYRING_PASSWORD` is injected via the gateway service env — no extra setup needed inside agent turns.
- Use for: contract/invoice emails (`muso-contract-invoicer`), financial report exports, reading shared finance Sheets
- Sheet / Drive *create* (e.g., new report sheet, share invoice PDF): default `--account a@muso.ai`, then `gog drive share <fileId> --email <requester> --role writer`. Never use `hydra-automation` SA for Drive — quota 0.
- Full command reference: `skills/gog/SKILL.md`

## Slack
- Bound channel: #finance (PRIVATE)
- Never share financial data in public channels
- Only Liza and Aaron have full access to financial details
