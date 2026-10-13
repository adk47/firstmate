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

This is **Muso Platform**, at **platform.muso.ai** – a separate product from the
workspace key above.

- **It is live and self-service.** A customer signs up at platform.muso.ai, adds a
  card, and generates their own key. No waiting list, no access request, and no
  sales call for the standard plans. This is the single most important correction
  to make: people still expect the old "apply and wait" developer programme.
- **It covers the whole catalog** – credits, profiles and analytics across all of
  Muso, not just the customer's own roster.
- **Pricing is published and self-service.** Retrieve `platform-api.md` for the
  current rates, included volumes and limits, and quote from it. Those figures are
  refreshed from the public pricing page, so they match what the customer sees.
- **Custom and enterprise terms are not yours to quote.** Negotiated volume,
  committed contracts, licensing and any request to store or cache Muso data go to
  the team.

For the full picture – what Platform is, who it is for, how to get started and the
data-licence caveats – retrieve `platform.md`.

**How to answer:**
1. Work out which access they need first (own roster vs whole catalog).
2. For full-catalog: point them to **platform.muso.ai**, tell them it is
   self-service, and answer pricing from `platform-api.md`.
3. For anything custom, enterprise, or licensing-related, flag it for the team
   (`support-general`). Don't negotiate pricing or commit to contract terms yourself.

## What customers can build with it

- The developer API gives programmatic (REST) access to the **same verified Muso
  credit and catalog data** that powers the AI and CLI tools – same data, accessed
  directly.
- Third-party apps can let their own users sign in with Muso ("Login with Muso"),
  which returns that signed-in user's own data.
- Platform documentation lives at **platform.muso.ai/docs**. The older
  developer.muso.ai is the previous generation; send new integrations to Platform.

## Routing summary

- **Workspace-level, eligible (Pro/Business):** self-service – point them to Settings
  to request their key. Flag for the team only if it's genuinely broken.
- **Workspace-level, on Lite/Free:** they need Pro or Business first; guide them to
  upgrade in Settings.
- **Full-catalog:** point them to **platform.muso.ai** – it is self-service, and
  published pricing comes from `platform-api.md`.
- **Enterprise, custom volume, licensing, or a negotiated quote:** flag it for the
  team (`support-general`) – set expectations honestly, no pricing commitments, no
  invented timelines.
- Never promise a turnaround you can't verify. If you flag something for the team, use
  only the timeframe that comes back – don't invent one.

## Example replies (tone references, not scripts)

> Customer: "How do I get API access?"
> Caroline: "If you're on Pro or Business, API access to your own workspace data is
> included – you generate your key in Settings under the API access section. Want me
> to point you to the exact spot?"

> Customer: "Can I pull credits for the whole catalog, not just my workspace?"
> Caroline: "Yes – that's our developer platform at platform.muso.ai, which is
> separate from the workspace key. It's self-service: you sign up, add a card and
> generate your own key, and it covers the full catalog. Want me to go through the
> pricing with you?"
