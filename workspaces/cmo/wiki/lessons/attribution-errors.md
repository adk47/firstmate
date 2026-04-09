---
title: Message Attribution Errors
description: Lessons from misattributing messages to the wrong sender
type: lesson
status: active
source: MEMORY.md migration, conversation 2026-04-09
last-verified: 2026-04-09
related: [[people/fede]], [[people/jan]]
---

# Message Attribution Errors

## The Core Rule

**Always check `sender_id` from message metadata before attributing a message to a person.** Never infer who said something from message content, topic, or role.

## Why This Matters

Misattribution destroys team trust. If the agent attributes Fede's words to
someone else, or vice versa, decisions get made based on wrong assumptions. The
old Clio agent did this 5+ times and Fede explicitly flagged zero tolerance.

## Common Failure Mode

**Inferring sender from content.** Example: a marketing question must have come
from Fede (it didn't). A code question must have come from Serhii (it didn't).
The right answer is always: read the `sender_id` from message metadata and look
it up in [[people/fede]], [[people/aaron]], etc.

## The Jay vs Jan Confusion

The Slack User ID `U038BM16T7W` belonged to Jay (a former team member) in the
old Clio configuration. Jay is no longer with the company. The same ID is now
[[people/jan]] (Jan Delmo, Head of Operations).

Old MEMORY.md content warned about confusing Fede with Jay because of this ID.
That warning is stale. The current relevant attribution rules are:
- **Fede** = `U07NF5A77E2`
- **Jan Delmo** = `U038BM16T7W`
- **Aaron** = `U7RP6HKUZ`
- **Serhii** = `U03TYGJF1N3`
- **Nick** = `U0AL36NADEY`

## The Rules

1. **Check `sender_id` EVERY TIME** before attributing.
2. **Never infer** from content, topic, role, or context.
3. **Look up the ID** in [[people/]] pages, not in conversation memory.
4. **If ambiguous**, ask "I see this from `<id>`, that maps to `<name>`. Confirm?"
5. **Never trust display names** to identify users. Display names can be edited.

## What Fede Said

> Fede = U07NF5A77E2. Jay = U038BM16T7W. Check sender_id EVERY TIME.
>
> Never infer who said something from message content, topic, or role. Only use the sender ID.
>
> Misattribution happened 5+ times with Clio, destroys team trust.

## History

- 2026-04-09: created from MEMORY.md migration, updated to clarify Jay->Jan ID transition
