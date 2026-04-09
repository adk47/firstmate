---
title: Em Dash Prohibited in All Output
description: Decision to ban em dashes (—) from all agent generated copy
type: decision
status: active
source: conversation with Fede 2026-04-09
last-verified: 2026-04-09
related: [[workflows/outreach-engine]]
---

# Decision: Em Dash Prohibited

**Date**: 2026-04-09
**Decided by**: Fede
**Status**: Active, zero tolerance

## The Rule

The em dash character `—` (Unicode U+2014) is **prohibited** in any output the
CMO agent produces. This includes:

- All emails (initial outreach, follow ups, win back, internal)
- All push notifications and external messages
- All Slack notifications
- All sheet entries
- All copy in skill files (so the agent does not learn the pattern)

## What Is Allowed

- En dash `–` (Unicode U+2013) is allowed
- Hyphen `-` (Unicode U+002D) is allowed
- Comma, period, parentheses, semicolon, colon are all preferred replacements

## Why

Fede uses em dashes in his own writing. The agent does not, because:
1. The agent cannot reliably distinguish em dash from en dash from hyphen visually
2. Em dash overuse is a tell that copy was AI generated (see [[lessons/outreach-failures]])
3. Removing em dashes from agent output makes copy feel more human

## What To Do Instead

Replace em dash with:
- Comma for short pauses: `we have 500K users, all verified`
- Period for hard stops: `We have 500K users. All verified.`
- Parentheses for asides: `we have 500K users (all verified)`
- Colon for elaboration: `the offer is simple: 3 free months`
- Restructure the sentence entirely

## How It Is Enforced

- All `muso-outreach-*` skills include the rule in their constraints section
- `muso-outreach-qa` runs a daily em dash sweep across all output channels (sheets, logs, skill files)
- Critical alert if any em dash is found
- The rule is documented in `muso-outreach-engine/references/config.md`

## What Fede Said

> I DONT'T want Em Dash (—) ever. This is prohibited.
>
> I don't want to use M-Dashes ever, ever, not short ones and not long ones.
>
> I can use that, but not you, you don't.
>
> Because you cannot tell the difference between a very long dash and a short dash. If you could, then it would be a different shit, bro.

## History

- 2026-04-09: rule established by Fede during CMO rebuild conversation
