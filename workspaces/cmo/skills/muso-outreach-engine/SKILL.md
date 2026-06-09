---
name: muso-outreach-engine
description: |
  Orchestrator and system architecture for the Muso B2B Ads outreach engine.
  Routes outreach requests to the correct specialized subskill and holds shared
  config for every muso-outreach-* skill (sheet IDs, GHL IDs, channels, voice).

  Use when: ANY outreach related request, to route to the right subskill, or
  when you need to understand the full outreach system architecture.

  Triggers: "outreach", "b2b outreach", "muso ads outreach", "sales outreach",
  "cold email", "follow up", "pipeline", "company finder", "reply", "meeting",
  "outreach report", "outreach audit"
depends-on:
  - muso-outreach-writer
  - muso-outreach-sender
  - muso-outreach-followup
  - muso-outreach-discovery
  - muso-outreach-reply-scanner
  - muso-outreach-calendar
  - muso-outreach-ghl-sync
  - muso-outreach-reporter
  - muso-outreach-qa
  - muso-slack-formatter
metadata:
  version: "4.0"
  last-updated: "2026-04-09"
---

<!-- WORKSPACE-DIVERGENCE: newer-than-canonical orchestrator architecture (v4.0); depends on workspace-only muso-outreach-* subskills not present in skills-all/. Backport/converge tracked separately. -->

# Muso Outreach Engine (Orchestrator)

Entry point for all B2B Ads outreach work. This skill does not do the work
itself. It routes requests to the right subskill and holds the shared config
(`references/config.md`) that every subskill reads from.

## Access Control

Write access (send emails, update sheets, modify GHL): Fede (U07NF5A77E2) and
Aaron (U7RP6HKUZ) only. Everyone else is read only.

## Subskill Map

| Request | Route To | What It Does |
|---------|----------|--------------|
| "Send outreach to N contacts" | `muso-outreach-sender` | Pulls targets, calls writer, presents batch, sends on approval |
| "Draft an email to {contact}" | `muso-outreach-writer` | Copy craft, voice by sender, opening framework |
| "Send follow ups" | `muso-outreach-followup` | Cadence check, template rotation, thread reply |
| "Find new companies" | `muso-outreach-discovery` | Daily 5 parent company discovery, dedupe, post to #company-finder |
| "Enrich contacts" | `muso-outreach-enrichment` | Snov.io, Enrow, Datagma enrichment (NOT YET ACTIVE) |
| "Check for replies" | `muso-outreach-reply-scanner` | Scans 4 accounts for new B2B - Ads replies |
| "Check for meetings" | `muso-outreach-calendar` | Scans a@muso.ai calendar for new bookings |
| "Sync sheet to GHL" | `muso-outreach-ghl-sync` | Bidirectional state reconciliation |
| "Outreach report" / "How are we doing" | `muso-outreach-reporter` | Generates batch and period reports from logs |
| "Audit outreach" / "Check health" | `muso-outreach-qa` | Validates stage IDs, drift, consistency, em dash violations |

For any request that touches multiple subskills, this orchestrator coordinates them
in sequence and maintains the overall state.

## Shared Config

All subskills read from `references/config.md`. Never hardcode sheet IDs, GHL IDs,
channels, or email addresses in a subskill. Update `config.md` in one place and
every subskill picks up the change.

Config includes:
- Contact & Company Intelligence — NocoDB (CANONICAL): tables Contacts
  Intelligence (`m9vsbijhrr9ddeu`) + Company Intelligence (`mvr6nmzcv7albxt`)
- Master leads sheet, templates + KB tabs only (email_templates, what_is_muso_ads, how_muso_ads_works)
- Outreach log sheet (muso-b2b-outreach-reports)
- GHL location + pipeline + stage info
- 4 Muso email accounts and their voice mappings
- Slack channels (including the critical distinction between #sales-alerts and #clio_x_fede)
- Follow up cadence (7d / 14d / 140d)
- Prohibited characters (em dash), banned phrases
- API log destinations

## Architecture Overview

```
                    ┌─────────────────────────┐
                    │  muso-outreach-engine   │
                    │      (orchestrator)     │
                    └────────────┬────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
  ┌─────▼──────┐          ┌──────▼──────┐          ┌──────▼──────┐
  │ DISCOVERY  │          │   WRITER    │          │   SENDER    │
  │ 5/day at   │          │  Copy craft │          │  Gmail API  │
  │ 1 PM CEST  │          │   + voice   │          │   + label   │
  └────────────┘          └─────────────┘          └─────────────┘
        │                        │                        │
        ▼                        ▼                        ▼
  ┌─────────────────────────────────────────────────────────┐
  │              ENRICHMENT (not active yet)                │
  │         Snov.io + Enrow + Datagma via n8n              │
  └─────────────────────────────────────────────────────────┘
        │                        │                        │
        ▼                        ▼                        ▼
  ┌────────────┐          ┌──────────────┐         ┌─────────────┐
  │ FOLLOWUP   │          │REPLY-SCANNER │         │  CALENDAR   │
  │ 7/14/140d  │          │  every 15m   │         │ every 15m   │
  └────────────┘          └──────────────┘         └─────────────┘
        │                        │                        │
        └────────────────────────┴────────────────────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │   GHL-SYNC      │
                        │  Sheet <-> GHL  │
                        └────────┬────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
              ┌─────▼──────┐           ┌──────▼──────┐
              │  REPORTER  │           │     QA      │
              │  on demand │           │  daily audit│
              └────────────┘           └─────────────┘
```

## Data Flow

1. **Discovery** finds new parent companies → adds to NocoDB Contacts Intelligence and Company Intelligence
2. **Enrichment** (when active) fills missing contact data from Snov.io / Enrow / Datagma
3. **Writer** drafts personalized emails using templates from `email_templates`
4. **Sender** creates Gmail drafts, sends on approval, labels, logs to sheet, syncs to GHL
5. **Reply Scanner** detects inbound replies, triggers **GHL Sync** to move stages
6. **Calendar** detects new bookings, triggers **GHL Sync** to move to Meeting Booked
7. **Followup** runs on cadence, uses **Writer** + **Sender** for the send
8. **Reporter** reads logs and generates summaries
9. **QA** audits every other subskill daily

## References

- `references/config.md`, shared config for ALL subskills
- `references/target-verticals.md`, ICP categories (active + exploration)
- `references/parent-companies.md`, parent to subsidiary mappings
- `references/icp-name-drops.md`, Bad Bunny + genre name table
- `references/pipeline-stages.md`, GHL stage IDs cache
- `../muso-outreach-writer/references/email-analysis.md`, lessons from past replies

## Constraints (HARD RULES, apply to every subskill)

- Never use em dash (—) in any email, slack message, or sheet entry
- Never send without explicit Fede or Aaron approval
- Never send on Saturday or Sunday
- Never break voice (Aaron voice from f@ is wrong, Fede voice from a@/ak@/aaron.k@ is wrong)
- Never skip the 4 source crosscheck (sheet logbook + NocoDB Contacts Intelligence + GHL + Gmail label)
- Never report outreach numbers from one source only
- Never post sales notifications to `#clio_x_fede` (use `#sales-alerts`)
- Always apply `B2B - Ads` label after send
- Always log every action to the logbook sheet
- Always sync GHL stages immediately after any state change

## Not Yet Wired

These are documented but not yet active. Enable when ready:

- `muso-outreach-enrichment` (Snov.io / Enrow / Datagma via n8n)
- `muso-outreach-followup` automation (Monday cron, waiting on GHL + sheet sync to be fully green)
- `muso-outreach-discovery` daily cron (1 PM CEST)
- Multi email hive rotation (separate email engine, not built yet)
