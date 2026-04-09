---
title: Email Hive Engine (Design Doc)
description: Architecture for the multi account email hive that routes outreach and winback sends across 4 Muso accounts with draft first approval
type: workflow
status: designed, warming in progress, build deferred to ~2026-05-21
source: conversation with Fede 2026-04-09
last-verified: 2026-04-09
related: [[workflows/outreach-engine]], [[workflows/winback-engine]], [[channels/email-accounts]]
---

# Email Hive Engine (Design)

**Current status (2026-04-09)**: Snov.io warm up initiated for `ak@`, `aaron.k@`,
and `f@`. 6 week warming curve puts full hive capacity at ~2026-05-21. Until
then, ALL production sends go from `a@muso.ai` only. The hive rotation system
is PAUSED.

**When build starts**: Nick implements in n8n after warm up completes.

## Problem Statement

Fede's 4 Muso email accounts:

| Email | Voice | Status |
|-------|-------|--------|
| `a@muso.ai` | Aaron, CEO | Warmed, production ready |
| `ak@muso.ai` | Aaron, CEO (alt) | Cold, needs warming |
| `aaron.k@muso.ai` | Aaron, CEO (alt) | Cold, needs warming |
| `f@muso.ai` | Federico, CMO | Cold, needs warming |

Two outreach streams:
- **B2B Sales** (outreach engine, cold emails to companies)
- **Winback** (winback engine, churned user re engagement)

### Three Problems to Solve

1. **Warm Up**: 3 accounts need to be warmed from 0 to 40 emails/day production volume
2. **Rotation**: distribute both streams across all 4 accounts daily, shifting the mix so no account is always sending one type
3. **Draft First Approval**: nothing auto sends. Drafts go to Gmail, Fede approves via Slack, then the system sends

## Problem 1: Warm Up

**Tool**: Snov.io warm up feature (confirmed by Fede).

Timeline per account:

| Week | Warm Up Volume | Real Send Volume | Status |
|---|---|---|---|
| 1 | 5-10/day | 0 | Pure warm up |
| 2 | 15-25/day | 1-2/day (test sends) | Engagement building |
| 3 | 30-50/day | 5-10/day | Ramp begins |
| 4 | 50-80/day | 15-25/day | Mid ramp |
| 5 | 80-100/day | 30-40/day | Near full |
| 6+ | maintain 50/day | 40/day | Production capacity |

**6 weeks to full production capacity** (40/day per account).

Monitor weekly:
- Bounce rate: if > 5% on any day, STOP that account
- Spam reports: if ANY, STOP that account immediately
- Inbox placement: verify sends are reaching inbox, not spam folder

## Problem 2: Rotation Architecture

**Approach**: Daily shuffled round robin with capacity and warming constraints.

### The Planner (runs 5 AM CST daily)

Inputs:
- Eligible sales contacts today (from outreach engine)
- Eligible winback contacts today (from winback engine)
- Available capacity per account (factors warming curve)

Output:
- Distribution plan (account x stream x contact list)

### The Rotation Logic

**Daily seed**: today's date is the random seed. Reproducible but different every day.

**Step 1**: Decide today's stream split per account. Percentages shuffle daily.

Example Monday:
| Account | Sales % | Winback % |
|---|---|---|
| `a@` | 60% | 40% |
| `ak@` | 30% | 70% |
| `aaron.k@` | 50% | 50% |
| `f@` | 70% | 30% |

Example Tuesday (reshuffled):
| Account | Sales % | Winback % |
|---|---|---|
| `a@` | 30% | 70% |
| `ak@` | 80% | 20% |
| `aaron.k@` | 40% | 60% |
| `f@` | 50% | 50% |

**Step 2**: Apply capacity.

```
a@ capacity 40: (Monday) 24 sales + 16 winback
ak@ capacity 25 (warming): 8 sales + 17 winback
aaron.k@ capacity 25 (warming): 13 sales + 12 winback
f@ capacity 25 (warming): 18 sales + 7 winback

Total: 63 sales + 52 winback = 115 drafts planned
```

**Step 3**: If demand exceeds capacity, overflow pushes to tomorrow's queue.

**Step 4**: Within each account, sequence sends with random 2-4 minute spacing.
Interleave sales and winback within the account so the outbound stream looks organic.

### Constraints

- Never exceed account daily cap (40 max for warmed, less for warming per curve)
- Never send Saturday or Sunday
- Never send outside 8 AM to 6 PM CST
- Honor warming curves (ak@, aaron.k@, f@ get less volume until week 6+)
- Honor pre send checks (Stripe for winback, exclusion DB for sales)
- Apply correct voice (Aaron for a@/ak@/aaron.k@, Fede for f@)

### Why This Works

- No account is "the sales account" or "the winback account"
- Daily mix shifts so sending profiles look organic
- Spacing prevents bulk blast signatures
- Recipient domain variety stays high (sales hits company domains, winback hits individual inboxes)
- Warming curves enforced automatically

## Problem 3: Draft First Approval Workflow

### Flow

```
5:00 AM CST
  ↓
Planner runs, computes distribution plan
  ↓
Posts plan preview to Slack (#marketing)
  ↓
Fede reviews plan, says "plan ok" or edits
  ↓
Drafts created in all 4 Gmail inboxes (via gog gmail drafts create)
  Sales drafts get "B2B - Ads" label
  Winback drafts get "Win-Back" label
  ↓
Single Slack post with summary + deep links to each Gmail inbox
  ↓
Fede reviews drafts in Gmail (can edit, delete, or leave alone)
  ↓
Fede replies in Slack thread with approval command:
  "go" → send all drafts still in folders
  "go a@" → send only drafts from a@muso.ai
  "go sales" → send only sales drafts across all accounts
  "go winback" → send only winback drafts across all accounts
  "skip f@" → send everything except f@ drafts
  "hold" → cancel everything, leave in drafts folder
  ↓
Worker walks through each account's draft IDs
  If draft still exists in folder → send + reapply label
  If draft was deleted → skip (Fede removed it during review)
  ↓
Logs to sheet + GHL via existing sync skills
  ↓
Completion summary posted to #sales-alerts and #win-back-alerts
```

### Key Properties

- **Drafts in actual Gmail Drafts folders**, not a separate system. Fede opens Gmail and sees them like any other draft.
- **Editing is natural**: delete a draft = it does not send. Edit a draft = the edited version sends.
- **Approval is Slack first**: Fede does not need to click through 4 inboxes to approve. One "go" command in Slack is enough.
- **Granular override**: Fede can send a subset if some need more review.
- **Idempotent**: replying "go" twice does not double send (sent drafts are gone from the folder).
- **Safe**: worker only sends drafts IT created in this batch (tracked by draft IDs). Cannot accidentally send pre existing drafts.

### Prior Incident (Why This Exists)

The previous automated send system went rogue and sent broken emails without
human review. Drafts first means any broken email IS visible in the inbox before
it goes out, and Fede can delete it. The approval command is explicit and human
in the loop.

## Problem 4: n8n vs Custom vs Both

**Recommendation**: n8n orchestration + HYDRA skills for the heavy lifting.

### Split of Responsibilities

| Layer | Tool | What it does |
|---|---|---|
| Planner (5 AM cron) | n8n | Pulls capacity, computes distribution, posts plan |
| Eligibility query | HYDRA (CMO) | Calls existing outreach + winback sender skills |
| Draft generation | HYDRA (CMO) | Calls outreach-writer + winback-writer for copy |
| Draft creation | HYDRA + gog | Creates actual Gmail drafts with labels |
| Slack approval listener | n8n | Watches for "go"/"hold" replies |
| Send worker | n8n + gog | Sends drafts on approval |
| Logging + GHL sync | HYDRA (CMO) | Calls existing sync skills |

### Why This Split

- n8n handles scheduling and orchestration (visual, easy to debug, handles cron)
- HYDRA handles intelligence (Opus for copy, existing skills for crosschecks)
- Existing skills do not get rewritten, they get called by the orchestrator

### Nick's Implementation

Nick should build:
1. n8n workflow for the planner (cron + distribution logic)
2. Slack approval webhook listener
3. Send worker that walks through draft IDs
4. Small admin command (CLI or Slack slash command) for manual triggering

Estimated: 1 to 2 days of focused work.

## Outstanding Items (Before Launch)

From `ACTION-ITEMS.md` Phase 3:

- [ ] Subscribe to Snov.io (or verify existing plan includes warm up)
- [ ] Add 3 cold accounts to Snov.io warm up
- [ ] 6 week warming period before real production volume
- [ ] Verify DKIM, SPF, DMARC
- [ ] Meeting with Nick to scope and schedule the n8n build
- [ ] Build and test the n8n workflow
- [ ] First end to end test with dummy drafts
- [ ] Go live after 6 week warming period plus build time

## What Lives in a Skill File vs Here

This page is the **design doc**. The actual implementation (when built) will
live in:
- `skills/muso-email-engine/SKILL.md` (orchestrator, references this design)
- `skills/muso-email-engine/references/rotation-logic.md` (distribution algorithm)
- `skills/muso-email-engine/references/approval-commands.md` (Slack command reference)
- n8n workflow (in Nick's n8n instance, not in the zip)

Until Nick builds it, neither the skill file nor the n8n workflow exists.
This design doc is the spec.

## History

- 2026-04-09: design captured during CMO rebuild conversation. Switched warm up tool from Mailreach to Snov.io per Fede. Drafts confirmed to live in Gmail Drafts folders. Nick to implement in n8n.
