---
title: Aaron Kaufman
description: CEO of Muso.AI, voice for cold outreach
type: person
status: active
source: USER.md, SOUL.md, outreach engine
last-verified: 2026-04-09
related: [[people/fede]], [[workflows/outreach-engine]], [[channels/email-accounts]]
---

# Aaron Kaufman

## Identity

- **Role**: CEO at Muso.AI
- **Slack User ID**: `U7RP6HKUZ`
- **Primary email**: `a@muso.ai`
- **Alt emails**: `ak@muso.ai`, `aaron.k@muso.ai`

## Authority

- CEO. Sole authorizer of security-file changes (Aaron-only fleet-wide). Agent policy files take either Nick's or Aaron's authorization.
- **Spending approval**: any task estimated at $30+ in compute or API costs needs Aaron's explicit OK.
- Approves outreach batches alongside Nick.
- Owns the relationship with high value B2B prospects (proposal sent and beyond).

## Voice as Sender

When the agent writes emails from `a@muso.ai`, `ak@muso.ai`, or `aaron.k@muso.ai`,
it writes in Aaron's voice:

- **Confident.** State facts. "We have 500K+ verified music professionals" not "we're exploring ways to help."
- **Peer level.** CEO writing to a peer. Warm but not eager. Direct but not pushy.
- **Intriguing.** Do not over explain. The email's job is curiosity, not closing.
- **Short.** 3 paragraphs max. 80 to 120 words body.

Signature:
```
Aaron Kaufman
CEO, Muso.AI
```

This is the **default voice for all cold outreach** in the B2B Ads engine. Only
follow ups and logistics use Fede's voice.

See `muso-outreach-writer` skill for the full voice guide.

## The Aaron + Fede Motion

For interested B2B Ads replies, the standard flow is:

1. **Aaron opens** with the Private Invite (CEO peer credibility)
2. **Fede follows up** with logistics (booking, warmth, next steps)
3. **Aaron reappears** for the actual call

This converted Casio, MasterChannel, and Fanbace in past batches. Fede's speed
on logistics is the differentiator. See [[lessons/outreach-failures]] for the
failure modes when this motion is broken.

## Cross Agent Authority

- Can direct any HYDRA agent (CMO, CTO, Finance, etc).
- If Aaron and Nick disagree on a marketing call, **Nick's decision stands** for marketing specifically.
- Final escalation point above Nick on cross department issues.

## Other Skills That Reference Aaron

- `muso-outreach-writer`: Aaron voice for cold emails
- `muso-outreach-sender`: Aaron is approver
- `muso-docusign`: Aaron only (write access)
- `muso-stripe`: Aaron and Fede (via specific skills)
- `muso-contract-invoicer`: Aaron only
- `muso-winback-engine`: Aaron only
- `muso-ads-manager`: Aaron, Serhii, Fede

## History

- 2026-04-09: page created during CMO rebuild
