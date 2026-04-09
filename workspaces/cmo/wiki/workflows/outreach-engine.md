---
title: Outreach Engine (B2B Ads)
description: High level overview of the B2B Ads outreach engine and its subskills
type: workflow
status: active
source: muso-outreach-engine SKILL.md and subskills
last-verified: 2026-04-09
related: [[company/muso-ads]], [[lessons/outreach-failures]], [[people/aaron]], [[people/fede]]
---

# Outreach Engine (B2B Ads)

## What It Is

The end to end B2B sales outreach engine for [[company/muso-ads]]. Identifies
prospects, crosschecks against multiple sources, drafts personalized emails,
sends on approval, and keeps every source of truth (sheet, GHL, Gmail) in sync.

## Architecture

The engine is split into specialized subskills under the `muso-outreach-*`
namespace. Each subskill has a single responsibility.

| Subskill | Job |
|----------|-----|
| `muso-outreach-engine` | Orchestrator, routing, shared config |
| `muso-outreach-writer` | Copy craft, voice by sender, framework |
| `muso-outreach-sender` | Pull, crosscheck, draft, send, log |
| `muso-outreach-followup` | Cadence (7d/14d/140d), template rotation |
| `muso-outreach-discovery` | 5 new parent companies per day |
| `muso-outreach-enrichment` | Snov.io + Enrow + Datagma (NOT YET ACTIVE) |
| `muso-outreach-reply-scanner` | Detect replies across 4 Gmail accounts |
| `muso-outreach-calendar` | Detect new meeting bookings |
| `muso-outreach-ghl-sync` | Single point of GHL writes |
| `muso-outreach-reporter` | Daily, weekly, batch reports |
| `muso-outreach-qa` | Daily audit of every other subskill |

## Sources of Truth

Four sources must stay in sync:

1. **Master Leads Sheet** (`1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I`): contacts, companies, templates, knowledge
2. **Outreach Log Sheet** (`1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0`): activity logbook across all 4 Muso emails
3. **GHL Pipeline** (B2B-Ads-Clio, `GeSt85TueSvJ0SNFZXfQ`): stage tracking
4. **Gmail** (across `a@`, `f@`, `ak@`, `aaron.k@`): inbound replies

When they disagree, investigate and reconcile. Never report from one source alone.

## Pipeline Stages

11 stages from cold to closed:

Cold → Emailed → Follow-up → Replied → Meeting Booked → No-Show → Awaiting for Application → Proposal Draft → Proposal Sent → Closed Won / Closed Lost

Stage IDs are fetched live from GHL and cached in
`skills/muso-outreach-engine/references/pipeline-stages.md`.

## Voice by Sender

| Sender | Voice |
|--------|-------|
| `a@muso.ai` | Aaron Kaufman, CEO (default cold) |
| `ak@muso.ai` | Aaron Kaufman, CEO (alt) |
| `aaron.k@muso.ai` | Aaron Kaufman, CEO (alt) |
| `f@muso.ai` | Federico Cappuccilli, CMO (logistics, follow ups) |

## Slack Notification Channels

- Send batches and replies → `#sales-alerts` (`C0ARQ021M40`)
- Daily company batches → `#company-finder` (`C0ARS7XMY93`)

Never `#clio_x_fede` (deprecated for sales).

## Hard Rules

- No em dash in any email or output (see [[decisions/2026-04-em-dash-prohibited]])
- Never send on Saturday or Sunday
- Never send without Fede or Aaron approval
- Never email a 2nd person at the same company unless rule exceptions met
- Always apply `B2B - Ads` Gmail label after send
- Always log every action to the logbook sheet
- Always sync GHL stages immediately after any state change
- Always crosscheck 4 sources before any send

## Where the Skill Files Live

- `skills/muso-outreach-engine/SKILL.md`, the orchestrator
- `skills/muso-outreach-engine/references/config.md`, shared config
- `skills/muso-outreach-engine/references/target-verticals.md`, ICP categories
- `skills/muso-outreach-engine/references/parent-companies.md`, parent rollups
- `skills/muso-outreach-engine/references/icp-name-drops.md`, name drop table
- `skills/muso-outreach-engine/references/pipeline-stages.md`, GHL stage IDs
- `skills/muso-outreach-writer/SKILL.md`, copy craft
- `skills/muso-outreach-writer/references/email-analysis.md`, lessons from past replies
- `skills/muso-outreach-{sender,followup,discovery,enrichment,reply-scanner,calendar,ghl-sync,reporter,qa}/SKILL.md`

## Lessons

See [[lessons/outreach-failures]] for the hard lessons from past batches.

## History

- 2026-04-09: rebuilt from monolithic skill into 11 subskills with shared config
