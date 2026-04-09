---
title: CMO Wiki
description: Navigable knowledge base for the CMO agent
last-verified: 2026-04-09
---

# CMO Wiki

This is the knowledge base for the CMO agent. It is meant to be read by the
agent (via OpenClaw `wiki_search`, `wiki_get`, `wiki_apply`, `wiki_lint` tools
when the memory-wiki plugin is enabled) and by humans (Obsidian friendly).

The wiki sits alongside `MEMORY.md` and the `memory/` daily notes. It does not
replace them. Active memory still owns recall and promotion. The wiki adds a
provenance rich knowledge layer.

## How to Use

**Reading**: search by keyword or browse by topic. Every page has frontmatter
with a `last-verified` date so you know how stale a fact might be.

**Writing**: when you learn something new that should outlive the conversation,
add it as a wiki page. Update `last-verified` whenever you confirm a fact is
still true. Link related pages with `[[page-name]]` style links (Obsidian
syntax) or markdown links.

**Deleting**: do not delete pages. Mark them `status: deprecated` in the
frontmatter and add a note explaining what replaced them.

## Index

### People
- [[people/fede]], owner, CMO of Muso.AI
- [[people/aaron]], CEO and outreach voice
- [[people/nick]], likely incoming CTO
- [[people/serhii]], current CTO
- [[people/jan]], Head of Operations

### Company
- [[company/muso-ai]], what Muso.AI is, the platform
- [[company/muso-ads]], the ads product (formerly called B2B)
- [[company/product-naming]], terminology rules and what to call things
- [[company/brand-voice]], how Muso speaks externally

### Platforms
- [[platforms/ghl]], GoHighLevel CRM, god mode access, gotchas
- [[platforms/klaviyo]], email marketing, off limits for cold
- [[platforms/chartmogul]], subscription metrics, source of truth for SaaS
- [[platforms/profitwell]], cash and payment metrics
- [[platforms/stripe]], payments and subscriptions
- [[platforms/amplitude]], product analytics
- [[platforms/rewardful]], affiliate program
- [[platforms/clickup]], task management
- [[platforms/n8n]], workflow automation
- [[platforms/docusign]], contracts
- [[platforms/google-sheets]], lead lists and tracking
- [[platforms/gmail]], email sending across 4 Muso accounts

### Channels
- [[channels/slack-channels]], full channel ID map
- [[channels/email-accounts]], the 4 Muso emails and their voices

### Workflows
- [[workflows/outreach-engine]], B2B Ads outreach overview
- [[workflows/winback-engine]], churn winback overview (separate engine)
- [[workflows/email-engine]], multi account email hive design (not yet built)
- [[workflows/eod-briefing]], daily 10 PM CET briefing for Fede

### Benchmarks
- [[benchmarks/email-metrics]], open rates, reply rates, conversion targets
- [[benchmarks/churn-rates]], churn benchmarks across Pro and Business

### Lessons
- [[lessons/outreach-failures]], hard lessons from outreach batches
- [[lessons/duplicate-sends]], why dedup matters
- [[lessons/attribution-errors]], misattribution incidents and rules

### Decisions
- [[decisions/2026-04-cmo-rebuild]], why and how the agent was rebuilt
- [[decisions/2026-04-em-dash-prohibited]], the em dash rule
- [[decisions/2026-04-clay-deprecated]], moving off Clay to Datagma + Snov.io
- [[decisions/2026-04-winback-rebuild]], win back engine rebuild
- [[decisions/2026-03-channel-migration]], moving sales alerts off #clio_x_fede

### Glossary
- [[glossary/pipeline-stages]], B2B Ads pipeline stage definitions
- [[glossary/icp-categories]], ICP category labels and what they mean
- [[glossary/terminology]], Muso specific terms

## Frontmatter Convention

Every wiki page starts with:

```yaml
---
title: Page Title
description: One line summary
type: person | company | platform | channel | workflow | benchmark | lesson | decision | glossary
status: active | deprecated
source: where this fact came from (slack thread, decision, doc, observation)
last-verified: YYYY-MM-DD
related: [[other-page]], [[another-page]]
---
```

## Provenance Rule

Every claim in the wiki should be traceable. If you write a fact, include:
- **Where it came from** (slack thread URL, decision doc, observation)
- **When it was verified**
- **Who verified it** (Fede, Aaron, or the agent itself)

If you cannot trace a claim, mark it `unverified` and flag for Fede review.

## Migration Path

If Muso later builds an infrastructure level wiki shared across all HYDRA agents,
the following directories are candidates to move out of CMO and into shared:
- `people/`
- `company/`
- `platforms/` (the ones not CMO specific)
- `channels/`
- `decisions/` (the cross cutting ones)
- `glossary/`

CMO specific content stays in CMO:
- `workflows/`
- `benchmarks/` (marketing specific ones)
- `lessons/` (marketing specific ones)
- `platforms/klaviyo`, `platforms/rewardful` (CMO only)
