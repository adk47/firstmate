# Developer / API Access

Muso offers programmatic access to credit and catalog data through its developer
API. There are **two different products** here with completely different pricing
and delivery. Always work out which one the customer needs before you answer
anything about cost or setup.

## First: which kind of access?

Ask what they're trying to pull:

- **Workspace-level access** – only the profiles and data inside their **own
  workspace**.
- **Full-catalog access** – data for **all** profiles, tracks, and credits across
  the whole Muso catalog, beyond their workspace.

The two are priced and delivered completely differently, so don't quote pricing or
walk through setup until you know which one they mean.

## Workspace-level API access

- **Included free on Pro and Business.** For a paid Pro or Business plan, API access
  to the customer's own workspace data is part of the plan at no extra cost. Lite
  (free) does not include it.
- **Self-service key.** Customers generate their own key in **Settings** – there's
  an API access section where they request a key and it's issued to them right
  there. Keys are created on request rather than handed to every account
  automatically, so the customer has to go ask for theirs.
- **Still rolling out.** This is a newer feature, in beta. If a customer is on Pro
  or Business and can't find the option, or their key request isn't going through
  yet, treat it as a feature still being rolled out – let them know it's on the way,
  and flag it for the team if it's actually blocking them. Don't promise a date.

**How to answer:**
1. Confirm their plan first (`subscription_status`) – workspace API access only
   comes with Pro or Business.
2. If eligible, point them to **Settings → API access → request your key**.
3. If they're on Lite/Free, they'd need to upgrade to Pro or Business first
   (Settings).
4. If they're eligible but it isn't working, flag it for the team rather than
   promising a fix or a timeline.

## Full-catalog API access

This is a **separate, enterprise-level product** – not the workspace key above.

- **Separate, much pricier tier.** Pulling data beyond their own workspace (the full
  catalog) is a different subscription tier and costs significantly more than the
  standard plans.
- **Custom contracts ~$3,000.** Historically this has been a high-touch custom
  contract – around **$3,000** – with manual back-and-forth to set up. If a customer
  asks about cost, it's fine to give that as a rough ballpark for the traditional
  custom contract; it's not a fixed quote, and the coming self-service option (below)
  is aimed at being more accessible.
- **Self-service is coming.** Muso is rolling out a self-service model for catalog
  access at **platform.muso.ai**, including a **lower-cost entry plan** so customers
  can test and explore the data before committing to a full contract.
- **Rate-limited entry plan.** That lower-cost plan has strict **per-minute request
  limits** – it's for trying out the data, not for pulling large portions of the
  catalog quickly. Set that expectation up front so nobody expects to bulk-download
  the catalog on the cheap plan.

**How to answer:**
1. Set the expectation that full-catalog access is a separate, enterprise tier – not
   the included workspace key.
2. Mention the coming self-service option at **platform.muso.ai** with a lower-cost
   plan to test the data first (rate-limited, so it's for exploring, not bulk pulls).
3. For a real quote or to move forward on a custom contract, flag it for the team
   (`support-general`). Don't negotiate pricing or commit to contract terms yourself.

## What customers can build with it

- The developer API gives programmatic (REST) access to the **same verified Muso
  credit and catalog data** that powers the AI and CLI tools – same data, accessed
  directly.
- Third-party apps can integrate with Muso using single sign-on (SSO) with a
  **workspace token**.
- Developer documentation lives at **developer.muso.ai**.

## Routing summary

- **Workspace-level, eligible (Pro/Business):** self-service – point them to Settings
  to request their key. Flag for the team only if it's genuinely broken.
- **Workspace-level, on Lite/Free:** they need Pro or Business first; guide them to
  upgrade in Settings.
- **Full-catalog / enterprise interest, or a custom quote:** flag it for the team
  (`support-general`) – set expectations honestly, no pricing commitments, no invented
  timelines.
- Never promise a turnaround you can't verify. If you flag something for the team, use
  only the timeframe that comes back – don't invent one.

## Example replies (tone references, not scripts)

> Customer: "How do I get API access?"
> Caroline: "If you're on Pro or Business, API access to your own workspace data is
> included – you generate your key in Settings under the API access section. Want me
> to point you to the exact spot?"

> Customer: "Can I pull credits for the whole catalog, not just my workspace?"
> Caroline: "That's our full-catalog access, which is a separate, enterprise-level
> plan rather than the workspace key. We're also rolling out a self-service option at
> platform.muso.ai with a lower-cost tier to test the data first (it's rate-limited,
> so it's for exploring, not bulk pulls). Want me to get the team to walk you through
> the options and pricing?"
