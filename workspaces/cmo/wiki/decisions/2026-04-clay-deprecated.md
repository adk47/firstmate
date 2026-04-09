---
title: Clay Deprecated for B2B Enrichment
description: Decision to phase out Clay and replace with Datagma + Snov.io
type: decision
status: active
source: conversation with Fede 2026-04-09
last-verified: 2026-04-09
related: [[decisions/2026-04-cmo-rebuild]], [[platforms/clay]]
---

# Decision: Clay Deprecated

**Date**: 2026-04-09
**Decided by**: Fede
**Status**: Active, in progress

## The Rule

Clay is being phased out as the enrichment provider for the B2B Ads outreach
engine. Replacements:

- **Datagma** for company intelligence and firmographics
- **Snov.io** for contact discovery and email verification
- **Enrow** for additional enrichment (TBD scope)

## Why

The Clay to Sheet automation broke during a previous transition and Fede had
to rebuild the enrichment flow manually. Rather than re wire Clay (which is
complex and proprietary), the team is moving to a stack that is:
1. More flexible (multiple providers)
2. Cheaper at scale
3. Easier to integrate via n8n workflows
4. Less locked in

## Current State

- Clay account still exists but is being wound down
- The new enrichment stack (Datagma, Snov.io, Enrow) is NOT yet wired
- The `muso-outreach-enrichment` skill is a placeholder waiting for accounts and n8n workflows

## Implications

- Old MEMORY.md references to Clay sheets (`1isLz...`, `1baWC...`, `1MuGW...`) are stale
- The new master leads sheet (`1OWzfm...`) is the current source of truth
- Any skill or workflow that mentions Clay should be checked and updated to point to the new sheet or new providers
- The discovery skill should NOT call Clay even if old code paths exist

## Migration Tasks

- [x] Remove Clay sheet references from MEMORY.md (Phase 2)
- [x] Document new master sheet in outreach engine skill
- [x] Create placeholder `muso-outreach-enrichment` skill
- [ ] Set up Datagma account
- [ ] Set up Snov.io account
- [ ] Set up Enrow account
- [ ] Build n8n enrichment workflow
- [ ] Wire enrichment skill into discovery flow
- [ ] Test enrichment on a small batch
- [ ] Cancel Clay subscription

## What Fede Said

> we will get rid of clay so maybe not relevant
>
> I need to connect it to datagma and snov.io too to help with company intelligence and contact intelligence enrichment in the outreach engine

## History

- 2026-04-09: decision recorded during CMO rebuild
