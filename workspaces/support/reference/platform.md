# Muso Platform (platform.muso.ai) -- the developer platform

This file is about **platform.muso.ai**, the self-service developer platform.
It is NOT about the Muso app's own features -- those are in `platform-features.md`,
where "platform" just means "the Muso product". Two different things that sound
the same; check which one the customer means before you answer.

**Live pricing, rate limits and endpoints are in `platform-api.md`**, which is
refreshed automatically from the public page. This file is the doctrine: what
Platform is, who it is for, and what to answer versus route. Deliberately no
figures here -- numbers written by hand go stale, and that is exactly how the old
API guidance ended up quoting a price that no longer existed.

## What it is

The self-service developer platform for Muso's verified music data. It is the
modern replacement for the old, manually-arranged developer programme: a customer
can sign up, add a card, get a key and start calling the API without talking to
anyone.

Four ways in, all billed on one meter:

- **REST API** at `api.platform.muso.ai`
- **MCP server**, hosted, for AI tools and assistants
- **`muso` CLI**
- **"Login with Muso"** single sign-on, so a partner's own users can sign in and
  see their own data

What it serves: verified credits, catalog metadata (profiles, albums, tracks,
roles) and chart and audience analytics, across the **full Muso catalog**.

## Who it is for

Developers and companies building something on Muso data: apps, internal tools,
partner integrations, catalogue analysis. Also the route for anyone who needs data
beyond their own roster.

It is not a replacement for a Muso subscription, and a normal Pro or Business
customer who just wants to see their own stats does not need it.

## The distinction that matters most

There are **two different API keys**, and customers confuse them constantly.
Work out which one they need before quoting anything.

| | Workspace API key | Platform API key |
|---|---|---|
| Who | Muso Pro/Business subscribers | anyone, self-service |
| Scope | their own roster only, read-only | the full Muso catalog |
| Where | the Muso app, under Settings | the platform.muso.ai console |
| Cost | included in their plan | pay as you go, card required |
| Limits | a fixed daily cap | tiered, scales with spend |

Rule of thumb: **"my own artists" is the workspace key; "everyone's data" is
Platform.** If they ask for catalog-wide access, they want Platform.

## How a customer gets started

1. Go to **platform.muso.ai** and sign in.
2. Add a card. There are starter credits, so they can try it before spending.
3. Create a key in the console, then call the API with it.

Docs are at **platform.muso.ai/docs**, pricing at **platform.muso.ai/pricing**.
There is no trial to request, no waiting list and no sales call for the standard
self-service tiers -- this is the main thing to tell people who expect the old
"request access and wait" process.

## What you can answer, and what you route

**Answer directly:**
- What Platform is, who it is for, and what data it covers.
- Which of the two keys they need.
- Where to sign up and where the docs are.
- The **published** pricing and limits -- retrieve `platform-api.md` and quote
  from it. Those figures come straight from the public pricing page, so they are
  what the customer would see themselves.

**Route to the team (`support-general`):**
- Anything custom: negotiated volume, committed contracts, enterprise terms.
- Data licensing questions, including storing or caching Muso data.
- Any request for a discount, a quote, or contract terms.

Never negotiate, never invent a figure, and never promise a timeline. If a
customer wants terms beyond the published self-service plans, that is a
conversation for the team, not something to settle in chat.

## Caveats worth knowing

- **The data licence allows in-app use, not redistribution.** Customers may build
  on the data for their own users. They may not resell it, redistribute it, bulk
  export it, or use it to build a competing credits database. Large-scale
  extraction is an enterprise arrangement, not something to buy around. If
  someone describes a plan that sounds like copying the catalog, do not guess at
  where the line is -- route it.
- **The CLI is built but not publicly installable yet.** Mention it as coming;
  do not send someone looking for a download.
- **Streaming analytics is planned, not purchasable.** Do not sell it.
- **Every key is live. There is no test mode**, so calls a customer makes while
  experimenting are real and metered. Worth flagging to anyone about to script
  something.

## Example replies (tone references, not scripts)

> Customer: "How do I get API access to all your credits data, not just mine?"
> Caroline: "That's our developer platform at platform.muso.ai. You can sign up
> yourself, add a card and generate a key -- no waiting list. It covers the full
> catalog: credits, profiles and analytics. Want me to walk you through the
> pricing?"

> Customer: "I'm on Pro. Do I already have API access?"
> Caroline: "You do, for your own roster -- that key lives in Settings in the Muso
> app and it's included in your plan. If you need data beyond your own artists,
> that's our developer platform at platform.muso.ai, which is separate and
> self-service. Which one are you after?"

> Customer: "Can we get a custom contract for bulk access?"
> Caroline: "That's an enterprise conversation rather than the self-service plans.
> Let me get the team to walk you through the options."
