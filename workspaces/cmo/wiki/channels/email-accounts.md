---
title: Muso Email Accounts
description: The 4 Muso email accounts the agent operates and their voices
type: channel
status: active
source: USER.md, muso-outreach-writer skill, conversation 2026-04-09
last-verified: 2026-04-09
related: [[people/aaron]], [[people/fede]], [[workflows/outreach-engine]]
---

# Muso Email Accounts

The CMO agent operates 4 Muso email accounts. Each has a specific voice when
sending outreach.

## Account Map

| Email | Owner | Voice | Primary Use |
|-------|-------|-------|-------------|
| `a@muso.ai` | Aaron Kaufman | Aaron, CEO | Primary cold outreach |
| `ak@muso.ai` | Aaron Kaufman | Aaron, CEO | Alternative for rotation, warming |
| `aaron.k@muso.ai` | Aaron Kaufman | Aaron, CEO | Alternative for rotation, warming |
| `f@muso.ai` | Federico Cappuccilli | Fede, CMO | Logistics, follow ups, meeting booking |

## Default for Cold Outreach

`a@muso.ai` is the default sender for new cold outreach. The other accounts
exist for:
1. Hive rotation (deliverability, warming)
2. Voice differentiation (Fede handles logistics moves)
3. Multi touch sequences (Aaron + Fede motion, see [[people/aaron]])

## Voice Rules

- **Never send Aaron voice from `f@muso.ai`** (wrong sender)
- **Never send Fede voice from `a@`, `ak@`, or `aaron.k@`** (wrong sender)
- See `muso-outreach-writer` skill for full voice guide

## Hive Rotation Status (as of 2026-04-09)

**Warm up initiated on Snov.io for all 3 cold accounts (ak@, aaron.k@, f@) on
2026-04-09.** Expected full capacity: ~2026-05-21 (6 week warming curve).

**Until warming completes**:
- ALL production sends go from `a@muso.ai` only
- `ak@`, `aaron.k@`, `f@` must NOT send real campaigns (Snov.io is driving their warm up traffic)
- The hive rotation system is PAUSED
- Outreach engine and winback engine should default to `a@muso.ai` as the sender
- Gmail scanning (for crosschecks and reply detection) STILL scans all 4 accounts (historical threads may exist on any of them)

**After warming completes (~2026-05-21)**:
- Activate the hive rotation system per `wiki/workflows/email-engine.md`
- Each account can handle up to 40 real sends/day
- Total hive capacity: 160/day
- Nick builds the n8n orchestration layer

## Gmail Labels

- `B2B - Ads`: applied to all B2B Ads outreach across all 4 accounts
- `Win-Back`: applied to churn win back outreach (only on `a@muso.ai`)

## Tooling

- CLI: `gog gmail` for read/write
- Auth: each account authenticated separately via `gog auth login <email>`
- Sending format: always `--body-html` with `<p>` tags. Never plain text.

## Constraints

- After `gog gmail drafts send`, the label must be reapplied manually. Drafts
  do NOT auto inherit the `--label` flag.
- All sends must be logged to the outreach reports sheet with the `Muso Email`
  column set to the sending account.

## History

- 2026-04-09: created. Hive of 4 accounts documented. Multi email engine flagged as future work.
