# MEMORY.md — CMO Agent

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned
_(none yet — agent will populate during operation)_

## Key Context
_(initialized 2026-03-22)_

## Migrated from Clio (2026-03-23)

### Fede Pahlen — ALL Working Rules
- **Slack ID: U07NF5A77E2** — NEVER confuse with Jay (U038BM16T7W). Check sender_id EVERY TIME before attributing a message. This error happened 5+ times with Clio — zero tolerance.
- **Don't take self-initiatives** unless explicitly asked. Prep/analysis = fine. Executing changes = only when Fede asks.
- **ClickUp primary**: fede@muso.ai (ID: 93811619)
- **ChartMogul MRR ≠ ProfitWell Cash** — Annual = full cash upfront, MRR = monthly spread. Never mix these.
- **Encore campaign**: Nov-Feb yearly, core Dec. Dec = acquisition spike, Jan-Feb = churn wave (~35% of cancels). Compare YoY not MoM.
- **Cancel save rate**: Pull from Amplitude (21%), NOT raw Stripe counts.
- **Email open rates**: 60-70% (industry ~30%). Win-back conversion: 52.9% (industry 5-10%).
- **Klaviyo OFF-LIMITS for cold outreach** — deliverability risk. Clay + warmed Gmail only.
- **Em dashes** — Fede uses em dashes in writing. Match his style in drafts.
- **Crosscheck everything** — before sending any batch, verify data against source. 3-point crosscheck rule (see below).
- **Clay sheets** — prospect data lives in Google Sheets bridged to Clay. Existing sheets: 1K scored prospects, 20K publisher universe, 4.3K domains.
- **Batch QA** — every outreach batch must be QA'd before sending. No bulk sends without review.
- **Template rules** — Provocateur template is DEAD. Private Invite template only.
- **Engineer audience**: ~160K targetable profiles in the engineer/producer segment.
- **Fede owns ALL outreach execution** (Clay, GHL, LinkedIn, pipeline). Clio/HYDRA provides data intelligence only.
- **Jeff should use existing prospect sheets** — not build from scratch in Clay.
- **1:1 emails from a@muso.ai** are CEO-level outreach (built by AI), NOT the same as Klaviyo template blasts.

### Hard Lessons — B2B Outreach
- **Clay sheets**: Jeff created duplicate prospect databases — always check existing sheets first.
- **Batch QA failures**: Sent batches without proper QA; caught errors post-send. Always validate before bulk operations.
- **Crosscheck failures**: Attributed data to wrong sources, mixed up metrics between platforms. Triple-check data provenance.
- **GHL auto-sync**: GoHighLevel syncs can overwrite manual edits. Be aware of sync direction and timing.
- **Follow-up draft failures**: Generated drafts that didn't match brand voice. All drafts must be reviewed by Fede for brand consistency.
- **EOD spam incident (Feb 27)**: Sent 5+ duplicate EOD reports to Fede in #clio_analyst. Rule: EOD is ONCE per day only. Track in state. Never re-send.

### B2B-Ads-Clio Pipeline
- Architecture: AI Agent → Athena (data) → Google Sheet (bridge) → Clay (enrichment) → GHL (CRM) → Aaron (closes)
- Prospect scoring uses: roster composition, streaming stats, MLC audit gaps, personalized pitch angles.
- Klaviyo is OFF-LIMITS for cold. Clay = outbound engine. Sheets = bridge.
- 1,170 active Business subs (680 monthly, 509 annual).
- Sheet IDs: 1K scored (`1isLz...`), 20K publishers (`1baWC...`), 4.3K domains (`1MuGW...`).

### B2B Outreach 3-Point Crosscheck Rules
1. **Data source verification** — confirm which database/API the number came from.
2. **Cross-reference** — check the same metric from a second source (e.g., ChartMogul vs ProfitWell vs Stripe).
3. **Freshness check** — verify the data timestamp. Athena exports are ~daily; real-time Stripe is live.
Never present a number without knowing all three.

### Template Rules
- **Provocateur template is DEAD** — do not use. Was too aggressive for the audience.
- **Private Invite template ONLY** — warm, exclusive tone. CEO-level personal outreach.
- Templates must reference actual platform data (roster, credits, streams) — no generic pitches.

### AMP Ads Terminology
- "AMP" refers to the Muso Amp product launch, NOT Accelerated Mobile Pages.
- "Muso Access" = the advertising platform at access.muso.ai (now called "Muso Ads").
- "Muso Ads" is the current preferred name. Stop calling it "B2B."

### GHL Pagination Rules
- GoHighLevel API paginates differently than standard REST. Always handle pagination explicitly.
- Check for next page tokens in responses.

### Message Attribution Rules
- **Fede = U07NF5A77E2. Jay = U038BM16T7W.** Check sender_id EVERY TIME.
- Never infer who said something from message content, topic, or role. Only use the sender ID.
- Misattribution happened 5+ times with Clio — destroys team trust.

### Terminology — Product Naming
- **Stop calling it B2B.** The product is "Muso Ads" (platform: access.muso.ai).
- "Business Pro" = subscription tier, not the ads product.
- "Pro" = individual subscription.

### Win-Back Engine Context
- Win-back campaign: personalized 1:1 emails from a@muso.ai to churned Pro subscribers (last 4-5 months).
- Offer: 3 free months + discounted Encore plaque + Founding Member badge.
- CRM sheet: 8,249 churned Pro users, 34 data columns + 6 tracking columns.
- Daily refresh cron appends new churns (append-only, never overwrites tracking columns).
- Test batch (11 emails, Feb 26): 0 replies, 0 conversions. Small sample.
- Fede reviews all drafts for brand consistency before sending.

### Data Sources for Marketing
- **ChartMogul**: MRR, subscriber counts, churn (SaaS source of truth)
- **ProfitWell**: Cash collected, payment breakdowns (actual payments ≠ MRR)
- **Klaviyo**: Email campaigns, flows, attributed revenue
- **Amplitude**: Product analytics, funnels, MAU/DAU
- **GA4**: Website traffic
- **Meta Ads**: Paid social
- **Meta Suite**: Organic social
