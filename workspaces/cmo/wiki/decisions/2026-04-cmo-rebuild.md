---
title: CMO Agent Full Rebuild
description: Why and how the CMO agent was rebuilt in April 2026
type: decision
status: active
source: conversation with Fede 2026-04-09
last-verified: 2026-04-09
related: [[decisions/2026-04-clay-deprecated]], [[decisions/2026-04-em-dash-prohibited]], [[workflows/outreach-engine]]
---

# Decision: CMO Agent Full Rebuild

**Date**: 2026-04-09
**Decided by**: Fede
**Status**: In progress

## Background

The CMO agent inherited content from multiple prior systems:
1. **Original Clio agent** (Mac mini, single agent on CloudBot, installed by Jay)
2. **Clio post compaction** (broken after an update that compacted things and corrupted skills)
3. **HYDRA agent hive** (Aaron's split into 11 specialized agents, including CMO carved out from Clio)
4. **HYDRA on API** (current, more stable, paid API)

Each transition introduced drift. Some skills were duplicated, some were broken,
some referenced dead resources. The Clay enrichment automation that was bridging
prospects to Sheets stopped working, Fede rebuilt a manual flow but never wired
it back into the agent's skill base.

By April 2026, the CMO agent's configuration was a mess of:
- Stale references (old Clay sheets, dead pipeline IDs, deprecated channels)
- Broken workflows (follow ups not firing, win back not sending)
- Inconsistent voice (sometimes Aaron, sometimes generic, no clear rules)
- No structured memory (one flat MEMORY.md with bullet points)

## The Decision

Rebuild from the foundation up, file by file, with Fede providing current state
for every reference. Treat the old config as a starting point but verify every
fact before keeping it.

## Scope

### Phase 1 (in progress, April 2026)

Foundation files:
- [x] `SOUL.md` (already updated)
- [x] `USER.md` (rewritten with current team)
- [x] `TOOLS.md` (rebuilt with all 18 tools, access levels)
- [x] `STARTUP.md` (new, wire up checklist)
- [x] Outreach engine (split into 11 subskills)
- [x] Wiki structure (this directory)

### Phase 2 (next)

- [ ] Win back engine rebuild
- [ ] MEMORY.md cleanup
- [ ] HEARTBEAT.md cron destination updates
- [ ] AGENTS.md verification

### Phase 3 (later)

- [ ] Analytics engine
- [ ] Email engine (multi account hive)
- [ ] Internal notification engine
- [ ] External notification engine
- [ ] Community management engine
- [ ] Social media engine

## Key Architectural Changes

1. **Outreach engine split into subskills.** Was monolithic, now 11 focused subskills under `muso-outreach-*` namespace.
2. **Shared config file.** All sheet IDs, GHL IDs, channels, accounts in one place (`muso-outreach-engine/references/config.md`). Subskills reference, never hardcode.
3. **Voice by sender.** Aaron for `a@/ak@/aaron.k@`, Fede for `f@`. Enforced in writer skill.
4. **New channels.** Sales notifications moved from `#clio_x_fede` to `#sales-alerts`.
5. **New sheet structure.** Master leads sheet `1OWzfm...`, replacing the old Clay bridged sheet.
6. **Em dash prohibited.** See [[decisions/2026-04-em-dash-prohibited]].
7. **Clay deprecated.** See [[decisions/2026-04-clay-deprecated]].
8. **Wiki added.** This directory. Provenance rich structured knowledge alongside MEMORY.md.

## Delivery

Fede ships the cmo folder as a zip to Nick, who installs it on the HYDRA server.
Everything inside the cmo folder is portable and self contained. No absolute
paths. No external file dependencies.

The startup checklist (`STARTUP.md`) walks the agent through wire up after the
zip is installed. Once green, that file is deleted.

## What Fede Said

> I downloaded the folder of my agent CMO and I gave you access because I really want to update everything in these fucking files. There are so many things that are wrong in these files because there was an old agent's version that got overwritten, so I want to make some cleaning.

> The task is for you to help me update all these files and make sure everything is correct now. A big fucking thing, man, is that when you ask me, "Should we do this and that in this file?" it's not good enough because all these files are interconnected.

## History

- 2026-04-09: rebuild started, Phase 1 in progress
