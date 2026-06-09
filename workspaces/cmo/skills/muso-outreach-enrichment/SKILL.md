---
name: muso-outreach-enrichment
description: |
  Enriches companies and contacts in the Muso Ads leads database using Snov.io,
  Enrow, and Datagma. Picks up companies flagged `Needs Enrichment` from the
  discovery step, finds decision maker contacts, validates professional emails,
  and writes enriched data back to NocoDB Contacts Intelligence and Company Intelligence.

  NOTE: NOT YET ACTIVE. This skill is a placeholder. The enrichment workflow will
  run primarily in n8n with HYDRA orchestration. Wire up after Snov.io, Enrow,
  and Datagma accounts are configured.

  Use when: "enrich companies", "find contacts for companies", "enrichment batch"

  Triggers: "enrich", "enrichment", "find contacts", "contact enrichment"
depends-on:
  - muso-outreach-engine
metadata:
  version: "0.1"
  last-updated: "2026-04-09"
  status: "NOT ACTIVE, placeholder skill"
---

# Muso Outreach Enrichment (NOT ACTIVE)

Enriches companies and contacts for the B2B Ads outreach engine using external
intelligence providers. This skill is a placeholder. Wire up once the accounts
and n8n workflows are ready.

## Status

**NOT ACTIVE.** This skill documents the intended workflow but cannot be used
yet. Do not attempt to run enrichment operations until Fede confirms the setup
is complete.

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Intended Data Sources

### Snov.io
- **Purpose**: contact intelligence, email finding, domain search
- **Auth**: TBD (API key, OAuth, or n8n credential)
- **Rate limits**: TBD
- **Status**: account not yet configured

### Enrow
- **Purpose**: company and contact enrichment
- **Auth**: TBD
- **Status**: account not yet configured

### Datagma
- **Purpose**: company intelligence, industry classification, firmographics
- **Auth**: TBD
- **Status**: account not yet configured

## Intended Workflow

### Step 1: Pick Up Unenriched Rows

From NocoDB Company Intelligence (`mvr6nmzcv7albxt`), pull rows where the status
indicates enrichment is needed (`Status = Needs Enrichment`, or empty `Industry` /
`Value Proposition` / `ICPCategory Label`). Use the `muso-nocodb` skill (REST API, no MCP):

```bash
bash scripts/nocodb-api.sh records.ls mvr6nmzcv7albxt \
  --where "(Status,eq,Needs Enrichment)" \
  --fields "Id,Domain,Company Name,Industry,Value Proposition,ICPCategory Label"
```

### Step 2: Company Enrichment

For each company, enrich in this order:

1. **Datagma**: industry, company size, revenue, description, LinkedIn Company URL
2. **Enrow**: value proposition, target customer, competitive context
3. **Internal classification**: map company to ICP Category Label based on
   industry + target customer (use `references/target-verticals.md` as guide)

Write back to NocoDB Company Intelligence (`mvr6nmzcv7albxt`) by row `Id`, via
`bash scripts/nocodb-api.sh records.update mvr6nmzcv7albxt '[{"Id":<id>, …}]'`
(note the NocoDB column is `Linkedin Company`, not "LinkedIn Company URL"):
- Industry
- Linkedin Company
- Company Description
- Value Proposition
- Value Statement
- Target Customer
- ICPCategory Label
- Why Muso Ads Matters

If `Why Muso Ads Matters` cannot be auto generated, flag for Fede review.
This field must be manually validated before any outreach.

### Step 3: Contact Discovery

For each enriched company, find decision maker contacts via Snov.io:
- Priority titles: CEO, Founder, CMO, Head of Marketing, VP Marketing, Growth Lead
- Filter: seniority C-level or VP preferred
- Validate professional email (Snov.io email verifier)

For each found contact, write to NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`)
via `bash scripts/nocodb-api.sh records.create m9vsbijhrr9ddeu '{…}'` (`Id` and
`Row ID` auto-generate; leave `Status` empty for untouched):
- Source (e.g., `Snov.io`)
- Domain (matches parent in Company Intelligence)
- Company Name
- First Name, Last Name
- Title
- Job Category
- Rank (based on title seniority)
- Valid Professional Email
- Snov.io LinkedIn (the contact's LinkedIn URL — NocoDB has no "LinkedIn Profile URL" column)

### Step 4: Parent Rollup Enforcement

Before writing contacts, confirm the company is a parent (not a subsidiary).
If it is a subsidiary listed under a parent in
`../muso-outreach-engine/references/parent-companies.md`, skip the contact and
enrich the parent instead.

### Step 5: Log

Append enrichment actions to `api-logs/enrichment/YYYY-MM-DD.jsonl`:

```json
{"timestamp":"ISO8601","source":"snov|enrow|datagma","target":"company|contact","domain":"...","result":"success|fail","notes":"..."}
```

### Step 6: Notify Fede

After batch completion, post to `#company-finder`:

```
*Enrichment Batch, YYYY-MM-DD* ({N} companies enriched, {M} contacts added)

New enriched companies:
  • Company Name (domain.com) → {K} contacts added
  • ...

Needs Fede review (Why Muso Ads Matters missing):
  • Company Name (domain.com)
```

## Wire Up Checklist

Before enabling this skill:

- [ ] Snov.io account created and API key obtained
- [ ] Enrow account created and API key obtained
- [ ] Datagma account created and API key obtained
- [ ] n8n workflow for enrichment created and tested
- [ ] Credentials added to `$SNOVIO_API_KEY`, `$ENROW_API_KEY`, `$DATAGMA_API_KEY` in HYDRA env
- [ ] Test enrichment on 1 company against a throwaway NocoDB record (or `--dry-run`)
- [ ] Confirm ICP Category Label mapping logic works
- [ ] Fede verifies first 5 enriched companies manually
- [ ] Then enable batch enrichment

## Why This Skill Exists Now

Even though the wiring is not complete, the skill file exists so:
1. The orchestrator can route enrichment requests and reply "not yet wired, ask Fede"
2. When wiring is ready, the workflow is already documented
3. The QA skill knows this is expected but inactive, not missing

## Constraints (When Active)

- Never enrich without matching parent company rollup logic
- Never mark `Why Muso Ads Matters` as auto generated without Fede review
- Always validate professional emails (never write unverified emails to NocoDB)
- Always log every external API call
- Always respect rate limits on Snov.io / Enrow / Datagma
