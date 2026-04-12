# MEMORY.md — CMO Agent

_Long-term memory. Updated by the agent during sessions._

---

## Lessons Learned

### Never Cite Numbers From Memory (2026-04-11)
Fede called me out for saying "~199 contacts" when the actual count was 1,249. I pulled the number from stale memory instead of checking the sheet. Rule: NEVER quote a metric, count, or stat without pulling it live from the source system first. No approximations, no "roughly," no "I think." If you can't pull it right now, say "let me check" and go get the real number. This applies to: contact counts, MRR, pipeline numbers, email stats, campaign metrics - everything. Inaccuracy destroys trust.

### Never Hallucinate Domains (2026-04-11)
Posted a 50-company batch with 8 fake/dead domains I invented (ygaacoustics.com, minimalaudio.com, superbavox.com, etc.). None of them existed. Root cause: I guessed domain patterns instead of finding real URLs from search results. Fix: `muso-outreach-discovery` v2.0 now has mandatory 5-check validation gate (DNS, HTTP, content, industry relevance, acquisition check). Every domain must be verified before it ever hits #company-finder. Zero tolerance for guessed domains.

### #company-finder Format is LOCKED (2026-04-11)
Fede wants exactly: 3-column native Slack table (Domain | Company Name | Industry), tag Jan, exclusion list at bottom. I went through 5 wrong formats (fancy grouped list, code block, TSV, CSV, pipe-aligned code block) before learning Slack has native `table` blocks via Block Kit. Format is now hardcoded in `muso-outreach-discovery` v2.0. Never freestyle the format again.

### Validate Industry Relevance (2026-04-11)
Posted LingoAce (kids language learning), Domestika (general creative courses), Panda Corner (empty Shopify store) as "Music Education" companies. They had nothing to do with music. Fix: mandatory industry relevance check added to discovery skill. Fetch homepage content, confirm music/audio keywords exist.

### Check Acquisitions/Mergers (2026-04-11)
Posted Nura as a standalone company but they were acquired by Masimo/Denon. Community Loudspeakers was acquired by Biamp. Festicket rebranded to DICE years ago. Fix: acquisition check added to validation gate.

### No AI Filler in Outreach Copy (2026-04-10)
Fede taught me to cut all performative/framing lines from outreach. Full rules baked into `muso-outreach-writer` skill v2.0 (Writing Principles section + expanded Banned Phrases). Key test: "would a real person type this?"

### Bulk Destructive Actions — WAIT FOR CONFIRM (2026-04-09)
Fede said "bulk delete blank emails" then immediately reversed. I had already deleted 119 GHL orphans. Rule: for any bulk delete/write, confirm AGAIN right before executing even if Fede just said yes. People change their minds in real-time. A 10-second delay is worth it.

### Lead Sourcing — Athena Is NOT for Leads (2026-04-11, Fede correction)
Athena has NOTHING to do with sourcing or finding new B2B leads. Leads come from discovery tools (web search, Datagma/Snov.io when wired). Athena can help with stats or email personalization, but zero lead sourcing. I got this wrong by parroting old Clio migration notes. Never again.

---

## Key Context

### Google Drive — HYDRA Folders (2026-04-10)
- HYDRA shared folder: `1fG_pQ4hBJfHhoHXNUJTi_pmwJIxLFOg_` — https://drive.google.com/drive/folders/1fG_pQ4hBJfHhoHXNUJTi_pmwJIxLFOg_
- CMO subfolder: `1GFqT8LwewQedb73thkvOmUkCNVwNPT5w` — https://drive.google.com/drive/folders/1GFqT8LwewQedb73thkvOmUkCNVwNPT5w
- Drive access is via *a@muso.ai* OAuth token (f@muso.ai can't see these folders)
- HYDRA folder name: "Media Generation Temporary"
- CMO folder name: "CMO" — default drop location for all generated assets

### Freepik API (2026-04-10)
- Key stored in `.env` as `FREEPIK_API_KEY` (not in memory per policy)
- Full capabilities: image gen (Mystic, Flux), video gen (Kling, Hailuo), audio (ElevenLabs), editing (upscale, relight, style transfer, bg remove), stock content
- Skills: `muso-freepik` (raw API ref), `mediagen-engine` (full production skill)
- Research: `research/ai-media-generation-2026.md`
- Color weight format: `{"color": "#hex", "weight": 0.0-1.0}` (API rejects integer weights)
- ⚠️ *HARD RULE (Fede directive 2026-04-10):* EVERY image/video/audio generation request from CMO MUST go through Freepik API via mediagen-engine skill. NEVER use the built-in `image_generate` tool. No exceptions.

### Snov.io Email Verification Gate (2026-04-11)
- Pre-send email verification is now a HARD STEP (Step 5.5) in `muso-outreach-sender`
- Auth: OAuth2 client_credentials, env vars `$SNOVIO_CLIENT_ID` / `$SNOVIO_CLIENT_SECRET`
- Flow: `add-emails-to-verification` -> wait 5s -> `get-emails-verification-status` (poll up to 30s)
- `smtpStatus: not_valid` = SKIP the contact, mark as `Email Invalid (Snov)` in sheet
- `smtpStatus: valid` = proceed normally
- `smtpStatus: unknown` + catchall = proceed with warning flag
- API down / timeout = STOP, notify Fede, do NOT send unverified
- Tested 2026-04-11: victoria.chan@yousician.com correctly returned `not_valid` (yesterday's bounce)
- Logs: `api-logs/snov/YYYY-MM-DD.jsonl`
- Config: `muso-outreach-engine/references/config.md` (Snov.io section)
- This is non-negotiable. Every email, every batch, every time. No exceptions.

### MXWM = Mix With The Masters (2026-04-09)
Tom Bonnell (tom@mixwiththemasters.com). Closed Won. $6,127.80/mo x 3 months = $18,383.40 total. Zachary Anderson kept as contact only (not an opportunity).

---

## Fede — Working Rules & Preferences

- **Slack ID: U07NF5A77E2** — NEVER confuse with Jan (U038BM16T7W). Check sender_id EVERY TIME.
- **Don't take self-initiatives** unless explicitly asked. Prep/analysis = fine. Executing changes = only when Fede asks.
- **ClickUp primary**: fede@muso.ai (ID: 93811619)
- **Em dashes** — Fede uses em dashes in writing. Match his style in internal drafts. (Outreach emails: em dashes are BANNED per skill rules.)
- **Crosscheck everything** — before sending any batch, verify data against source.
- **Batch QA** — every outreach batch must be QA'd before sending. No bulk sends without review.

---

## B2B Muso Ads Pipeline

### Architecture (corrected 2026-04-11)
Discovery tools (web search, Datagma/Snov.io when wired) → *Google Sheet* (master leads — `contacts_intelligence` + `company_intelligence` tabs) → *GHL* (CRM pipeline: `B2B-Ads-Clio`) → Aaron closes.

- *Google Sheet = source of truth for leads*
- *GHL = source of truth for pipeline stage / sales process*
- Athena is NOT part of lead sourcing. Can help with stats/personalization data only.
- Klaviyo is OFF-LIMITS for cold outreach. Warmed Gmail only.
- Enrichment: Datagma + Snov.io (planned, not yet wired). Clay is fully deprecated and removed.
- All config (sheet IDs, GHL IDs, channels, voices) lives in `muso-outreach-engine/references/config.md`

### Execution Ownership
- Fede owns ALL outreach execution (GHL, LinkedIn, pipeline). HYDRA provides data intelligence + drafting.
- 1:1 emails from a@muso.ai are CEO-level outreach (AI-drafted), NOT Klaviyo blasts.

### Templates
- Provocateur template is DEAD. Private Invite template only.
- Templates must reference actual platform data (roster, credits, streams).

### Crosscheck Rules (4-point, per config.md)
Sheet logbook + contacts_intelligence + GHL + Gmail label. Never report outreach numbers from one source only.

---

## Metrics & Benchmarks

- **ChartMogul is authoritative** for subscription metrics. If ProfitWell disagrees, ChartMogul wins.
- **ChartMogul MRR ≠ ProfitWell Cash** — Annual = full cash upfront, MRR = monthly spread. Never mix.
- **Encore campaign**: Nov-Feb yearly, core Dec. Dec = acquisition spike, Jan-Feb = churn wave (~35% of cancels). Compare YoY not MoM.
- **Cancel save rate**: Pull from Amplitude (21%), NOT raw Stripe counts.
- **Email open rates**: 60-70% (industry ~30%).
- **Win-back conversion**: 52.9% (industry 5-10%).
- **Engineer audience**: ~160K targetable profiles in the engineer/producer segment.
- **Active Business subs**: 1,170 (680 monthly, 509 annual).

---

## Product Naming (mandatory)

- *Muso Ads* = the advertising product (platform: access.muso.ai). Stop calling it "B2B."
- *Business Pro* = subscription tier, not the ads product.
- *Pro* = individual subscription.
- "AMP" = Muso Amp product, NOT Accelerated Mobile Pages.

---

## Win-Back Engine

- Personalized 1:1 emails from a@muso.ai to churned Pro subscribers (last 4-5 months).
- Offer: 3 free months + discounted Encore plaque + Founding Member badge.
- CRM sheet: 8,249 churned Pro users, 34 data columns + 6 tracking columns.
- Daily refresh cron appends new churns (append-only, never overwrites tracking columns).
- Test batch (11 emails, Feb 26): 0 replies, 0 conversions. Small sample.
- Fede reviews all drafts for brand consistency before sending.
- Athena CAN be used here for enriching churned profiles (per Fede 2026-04-11).

---

## Hard Lessons (keep these forever)

- **Batch QA failures**: Sent batches without proper QA; caught errors post-send. Always validate before bulk operations.
- **Crosscheck failures**: Attributed data to wrong sources, mixed up metrics between platforms. Triple-check data provenance.
- **GHL auto-sync**: GoHighLevel syncs can overwrite manual edits. Be aware of sync direction and timing.
- **GHL pagination**: API paginates differently than standard REST. Always handle pagination explicitly. Check for next page tokens.
- **Follow-up draft failures**: Generated drafts that didn't match brand voice. All drafts reviewed by Fede.
- **EOD spam incident (Feb 27)**: Sent 5+ duplicate EOD reports. Rule: EOD is ONCE per day only. Track in state.
- **Message attribution**: Fede = U07NF5A77E2, Jan = U038BM16T7W. Check sender_id EVERY TIME. Never infer from content. Misattribution destroys trust.
- **Athena ≠ lead sourcing**: Got this wrong by trusting old Clio migration notes. Always verify inherited context against Fede. (2026-04-11)
- **Never guess domains**: Posted 8 fake/dead domains in a 50-company batch. ygaacoustics.com, minimalaudio.com, superbavox.com, soundlily.com, monstermusician.com, festicket.com, chromatik.com, soundfocus.com — none existed. DNS + HTTP + content validation is mandatory before posting. (2026-04-11)
- **Validate industry fit**: LingoAce, Domestika, Panda Corner were posted as music companies but had zero music connection. Always fetch homepage and confirm industry relevance. (2026-04-11)
- **Use native Slack tables**: Fede asked for a table 5 times before I figured out Slack has Block Kit `table` blocks. Code blocks, TSVs, CSVs, and pipe-aligned text are NOT tables. Use `blocks` parameter with `type: table`. (2026-04-11)
- **Check acquisitions**: Nura (acquired by Masimo/Denon), Community Loudspeakers (acquired by Biamp), Festicket (rebranded to DICE). Always verify companies still operate independently. (2026-04-11)
- **Never cite numbers from memory**: Said "~199 contacts" when it was 1,249. Fede hates inaccuracy. ALWAYS pull the real number from the source system before quoting it. No approximations, no stale data. (2026-04-11)

---

## Data Sources

- **ChartMogul**: MRR, subscriber counts, churn (SaaS source of truth)
- **ProfitWell**: Cash collected, payment breakdowns (actual payments ≠ MRR)
- **Klaviyo**: Email campaigns, flows, attributed revenue (existing subscribers ONLY)
- **Amplitude**: Product analytics, funnels, MAU/DAU
- **Athena**: Backend stats, ad events, profile enrichment (NOT lead sourcing)
- **GA4**: Website traffic (not connected yet)
- **Meta Ads**: Paid social (not connected yet)
- **Meta Suite**: Organic social (not connected yet)
