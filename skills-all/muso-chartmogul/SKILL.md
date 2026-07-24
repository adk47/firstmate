---
name: muso-chartmogul
description: "Deprecated ChartMogul redirect. Use only when the request explicitly includes the word ChartMogul; do not use when ChartMogul is not named."
---

# ChartMogul (Deprecated)

Muso no longer uses ChartMogul for current subscription analytics.

## Routing

- Use this skill only when the requester explicitly names ChartMogul.
- Route current MRR, ARR, churn, LTV, revenue, customer, and subscription analysis to Finance, using `muso-stripe-subscription-analytics`.
- Do not call the ChartMogul API.
- Do not inspect, test, repair, rotate, or escalate `MUSOAI_CHARTMOGUL_TOKEN`.
- Treat historical ChartMogul exports and saved queries as legacy artifacts, not current sources of truth.
- If Stripe cannot reproduce a historical ChartMogul metric exactly, explain the definition or coverage gap.

For current work, route to Finance. In the Finance workspace, load `muso-stripe-subscription-analytics` and follow its Stripe reporting contract.
