---
title: Slack Channel Map
description: Every Slack channel the CMO agent operates in
type: channel
status: active
source: SOUL.md, HEARTBEAT.md, conversation 2026-04-09
last-verified: 2026-04-09
related: [[channels/email-accounts]], [[workflows/outreach-engine]]
---

# Slack Channel Map

Single source of truth for every Slack channel CMO posts to or reads from.

## Active Channels

| Purpose | Channel | ID |
|---------|---------|----|
| General marketing discussion | `#marketing` | (lookup) |
| Muso Ads campaigns | `#muso-ads` | (lookup) |
| Campaign planning | `#campaigns` | (lookup) |
| Sales outreach notifications | `#sales-alerts` | `C0ARQ021M40` |
| Daily new company finder batch | `#company-finder` | `C0ARS7XMY93` |
| Churn winback notifications | `#win-back-alerts` | `C0ARTH6U0S2` |
| Heartbeat posts | `#hydra-heartbeat` | (lookup) |
| Audit logs | `hydra-audit` | (lookup) |
| Growth team daily reports | `#growth-team` | `C031DKAGQSH` |

## Deprecated Channels (DO NOT POST HERE)

| Channel | Why Deprecated | Replaced By |
|---------|----------------|-------------|
| `#clio_x_fede` (`C0AHN078CSH`) | Was the Clio era catch all for Fede notifications. Migrated to specific channels per topic. | `#sales-alerts` for outreach, `#win-back-alerts` for churn |

## Posting Rules

- Always respond in the same channel/DM the message came from.
- Stay in threads. Never break out to top level when a thread exists.
- Don't dominate group chats. Use emoji reactions for acks.
- Heartbeat posts go to MAIN CHANNEL (top level), never in a thread.
- Never post marketing budgets or spend data outside bound channels.

## Channel Routing by Engine

| Engine | Notification Channel |
|--------|----------------------|
| Outreach engine (sends, replies, meetings) | `#sales-alerts` |
| Discovery (daily company batches) | `#company-finder` |
| Win back engine (churn campaigns) | `#win-back-alerts` |
| EOD briefing for Nick | Nick's DM (`D0AKT90NQJX`) |
| AMP daily report | `#growth-team` |

## History

- 2026-04-09: created. `#sales-alerts`, `#company-finder`, `#win-back-alerts` are new channels per Fede directive. `#clio_x_fede` deprecated for sales/winback notifications.
