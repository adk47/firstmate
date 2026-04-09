# MEMORY.md, CMO Agent

Durable memory file. Loaded at the start of every session by OpenClaw's active
memory plugin. Keep this SHORT and pointer-heavy. Deep context lives in the
`wiki/` folder, which is loaded on demand via `wiki_search` / `wiki_get`.

_Updated 2026-04-09 during the CMO rebuild. Previous Clio-era content migrated
to wiki pages or skill config files. Do NOT restore the old bullet-dump format._

---

## How This Works

- **MEMORY.md (this file)**: stable pointers + a handful of hard rules. Small enough to load every session.
- **`memory/YYYY-MM-DD.md`**: daily notes, ephemeral context. Today + yesterday auto-loaded.
- **`wiki/`**: structured knowledge base, searchable on demand. Most facts live here.
- **`skills/*/references/config.md`**: engine-specific config. Loaded when the skill is invoked.

If you are looking for something and it is not in this file, search the wiki first. If it is not in the wiki, check the relevant skill's config.

---

## Critical Hard Rules (Agent Must Obey Always)

1. **Em dash (—) is PROHIBITED** in any output (emails, Slack, sheets, copy). See `wiki/decisions/2026-04-em-dash-prohibited.md`.
2. **Check `sender_id` from message metadata** before attributing any message. Never infer from content. See `wiki/lessons/attribution-errors.md`.
3. **Never execute external writes without Fede or Aaron's approval.** Prep and analysis are fine. Sends, publishes, campaign changes need explicit go.
4. **Never confuse B2B Ads outreach with churn win back.** Different sheets, different GHL locations, different API keys, different channels. See `wiki/workflows/outreach-engine.md` and `wiki/workflows/winback-engine.md`.
5. **Klaviyo is OFF-LIMITS for cold outreach.** Existing subscribers only. Deliverability risk.
6. **ChartMogul is source of truth for SaaS metrics.** If ProfitWell disagrees, ChartMogul wins.
7. **EOD briefing is once per day only.** Never re-send. See the incident record in `wiki/lessons/` (to be added if the rule ever gets tested again).

---

## People (full detail in `wiki/people/`)

- **Fede** (`U07NF5A77E2`, `f@muso.ai`): owner, CMO, final word on marketing. See `wiki/people/fede.md`.
- **Aaron** (`U7RP6HKUZ`, `a@muso.ai`): CEO, approves spend > $30, voice for cold outreach. See `wiki/people/aaron.md`.
- **Serhii** (`U03TYGJF1N3`): current CTO. See `wiki/people/serhii.md`.
- **Nick Sollazzo** (`U0AL36NADEY`): likely incoming CTO. See `wiki/people/nick.md`.
- **Jan Delmo** (`U038BM16T7W`): Head of Operations. Note: this ID historically belonged to "Jay" in old Clio configs. Jay is irrelevant now. See `wiki/people/jan.md`.

## Channels (full detail in `wiki/channels/`)

- `#sales-alerts` (`C0ARQ021M40`): B2B Ads outreach notifications
- `#company-finder` (`C0ARS7XMY93`): daily company finder batches
- `#win-back-alerts` (`C0ARTH6U0S2`): churn win back notifications
- `#clio_x_fede`: legacy, deprecated for sales and winback. Still used for EOD briefing for now.
- `#marketing`, `#muso-ads`, `#campaigns`: general marketing discussion
- `#hydra-heartbeat`: system heartbeat posts

## Email Accounts (full detail in `wiki/channels/email-accounts.md`)

- `a@muso.ai`: Aaron voice, warmed, primary cold outreach sender
- `ak@muso.ai`, `aaron.k@muso.ai`: Aaron voice, need warming
- `f@muso.ai`: Fede voice, needs warming, used for logistics and follow ups

## Voice by Sender

See `wiki/people/aaron.md` and `wiki/people/fede.md` for full voice guides.
- Aaron voice for `a@`, `ak@`, `aaron.k@`
- Fede voice for `f@`

---

## Key Benchmarks (full detail in `wiki/benchmarks/`)

- **Email open rate**: Muso runs 60 to 70% (industry ~30%). See `wiki/benchmarks/email-metrics.md`.
- **B2B cold reply rate target**: > 15% (Private Invite historically beats this).
- **B2B cold meeting rate target**: > 5% of sends.
- **Cancel save rate**: pull from Amplitude (~21%), NOT raw Stripe counts.
- **Encore campaign**: Nov to Feb yearly, December is the acquisition spike, Jan to Feb is the churn wave (~35% of annual cancels). Compare YoY, not MoM.

---

## Product Naming (full detail in `wiki/company/product-naming.md`)

- **Muso Ads**: the B2B advertising platform at `access.muso.ai`. NOT "B2B", NOT "Muso Access" (old name), NOT "AMP" (different product).
- **Muso Pro**: individual subscription.
- **Muso Business**: team subscription.
- **Muso Encore**: annual campaign product.

---

## Data Sources (full detail in `wiki/platforms/`)

- **ChartMogul**: source of truth for SaaS metrics (MRR, ARR, churn, LTV, customer count)
- **ProfitWell**: cash collected and payment metrics
- **Stripe**: live payments and subscription state
- **Amplitude**: product analytics (DAU/MAU, funnels, retention)
- **GA4**: website traffic (not yet connected)
- **Meta Ads**: paid social (not yet connected)
- **Athena**: SQL warehouse (Aaron may be migrating to Cloudflare, verify)

See `TOOLS.md` for the full tool list with access levels and env vars.

---

## Rebuild Context (April 2026)

The CMO agent was fully rebuilt in April 2026 after multiple config transitions
corrupted the original Clio era setup. See `wiki/decisions/2026-04-cmo-rebuild.md`
for the full story.

Key outputs of the rebuild:
- `muso-outreach-*` (11 subskills for B2B Ads outreach)
- `muso-winback-*` (8 subskills for churned Pro win back)
- Wiki knowledge base (`wiki/`)
- `STARTUP.md` (agent wire up checklist)
- `ACTION-ITEMS.md` (Fede's physical checklist)

Both engines follow the same architectural pattern: orchestrator + writer + sender + followup + reply-scanner + ghl-sync + reporter + qa, with a shared config file.

---

## What NOT To Store Here

Do NOT write to MEMORY.md:
- Ephemeral task state (use `memory/YYYY-MM-DD.md`)
- Deep knowledge (use the wiki)
- Engine-specific config (use the skill's `references/config.md`)
- Credentials or API keys (never store secrets in a file that ships in the zip)
- Conversation details (handled by active memory plugin)
- Duplicates of what is already in the wiki (link instead)

If this file ever grows past ~200 lines, it has too much. Migrate content to
the wiki and keep this file as a thin index.

---

## Session Lessons (agent writes here)

_(empty, agent will populate during operation)_

When the agent learns a new hard lesson during a session that is worth durable
storage, it can either:
1. Add a short entry here with a wiki link, OR
2. Create a dedicated wiki page under `wiki/lessons/` and link to it from here

Prefer the wiki approach for anything longer than 2 lines.

---

## History

- 2026-04-09: rewrote MEMORY.md as a thin pointer document. Old Clio-era bullet dump migrated to wiki pages. Removed unverified 52.9% win back conversion figure. Removed stale Clay sheet IDs. Removed Jay references (Jay is irrelevant; `U038BM16T7W` is Jan Delmo now).
- 2026-03-23: original migration from Clio (deprecated content, replaced 2026-04-09)
- 2026-03-22: file initialized
