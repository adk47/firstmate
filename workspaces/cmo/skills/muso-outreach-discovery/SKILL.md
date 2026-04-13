---
name: muso-outreach-discovery
description: |
  Daily parent company discovery for Muso Ads B2B outreach. Finds 5 new parent
  companies per day matching target verticals, dedupes against the sheet, GHL,
  and known parent list, applies parent to subsidiary rollup logic, and posts
  the batch to #company-finder for Fede's review.

  Runs as a cron at 1 PM CEST daily.

  Use when: "find new companies", "company finder", "daily discovery", "new targets"

  Triggers: "find companies", "discover companies", "new targets", "company batch",
  "company finder"
depends-on:
  - muso-outreach-engine
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
  status: "planned cron, not yet wired"
---

# Muso Outreach Discovery

Finds 5 new parent companies per day matching Muso Ads target verticals, with
strict dedupe and parent rollup logic.

## Access Control

Fede (U07NF5A77E2) and Aaron (U7RP6HKUZ) can approve new companies.
Read only for everyone else.

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Cadence

**Daily at 1 PM CEST.** Cron name: `company-finder-daily` (planned, not yet wired).

## Target Verticals

See `../muso-outreach-engine/references/target-verticals.md` for the full list.

**Active verticals** (prioritize):
- Pro Audio / Gear
- Music Software / Plugins
- Music Platforms
- Music Education
- Live / Touring / Ticketing
- Industry Services (PROs, Labels)
- Lifestyle / Adjacent

**Exploration verticals** (surface for review):
- Entertainment / Music Lawyers
- Royalty Collection / Admin
- Sync Licensing
- Distribution
- Music Insurance
- Merch / D2C

## Workflow

### Step 1: Discover Candidates

Run discovery queries for each active + exploration vertical. Discovery sources
(in priority order):

1. **Web search + web fetch** for "top {vertical} companies 2026"
2. **Datagma** (when wired) for vertical specific company lists
3. **Snov.io** (when wired) for domain search by industry
4. **Enrow** (when wired) for enriched company intelligence
5. **Manual curation** from industry publications (Mixmag, MusicTech, Billboard)

Target: surface ~20 candidates per run, narrow to top 5 after dedupe.

### Step 2: Dedupe (4 Sources)

Drop any candidate matching ANY of these:

1. **`contacts_intelligence`** sheet, by Domain OR Company Name (fuzzy match on first word)
2. **`company_intelligence`** sheet, by Domain OR Company Name
3. **GHL opportunities** in B2B-Ads-Clio pipeline (all stages)
4. **`parent-companies.md`** known parent list + all their subsidiaries

```bash
# Read sheets
gog sheets get 1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I \
  --range "contacts_intelligence!E:E" --account a@muso.ai  # Company Name column

gog sheets get 1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I \
  --range "company_intelligence!A:B" --account a@muso.ai  # Domain + Company Name

# Read GHL
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=S5w31kRRgsBjjiVATWlP" \
  -d "pipeline_id=GeSt85TueSvJ0SNFZXfQ" \
  -d "limit=100" -d "page=1"
# Paginate all pages
```

### Step 3: Parent Company Rollup Logic

For each candidate:

1. If the candidate is a **known subsidiary** (listed under any parent in
   `parent-companies.md`), drop it. The parent is the target.

2. If the candidate is a **new parent** that owns subsidiaries already in our
   sheet, flag it for rollup:
   - Add the parent to `parent-companies.md`
   - Add subsidiaries under the parent
   - Note in output which subsidiaries were rolled up
   - Do NOT remove the subsidiary rows from the sheet automatically. Flag for Fede.

3. If the candidate is a **standalone parent** (no subsidiaries in our list),
   include as is.

4. If the candidate is a **small brand** without parent complications, include
   as is.

### Step 4: Score & Select Top 5

Score each candidate on:
- Vertical match (active > exploration)
- Market size indicator (company size, funding, revenue if available)
- ICP fit (do their buyers match Muso users)
- Cleanliness (not a duplicate, not too niche, real company)

Return the top 5. Exploration vertical picks must include a note explaining why
they are worth surfacing now.

### Step 5: Post to #company-finder

Channel: `#company-finder` (`C0ARS7XMY93`)

Format (using `muso-slack-formatter` rules):

```
*New Company Batch, YYYY-MM-DD* (5 parent companies)

Pro Audio / Gear:
  1. *{Company Name}* (`domain.com`)
     Why: {1 line ICP fit}
     Vibe: {1 line about their market position}

Music Software:
  2. ...

Subsidiaries rolled up to parents:
  • subsidiary1.com → parent1.com (new parent added)
  • subsidiary2.com → parent2.com (already in list)

New parents discovered:
  • newparent.com (covers sub1.com, sub2.com, sub3.com)
```

Wait for Fede to react with ✅ or 👍 to approve.

### Step 6: On Approval

- Add approved companies to `company_intelligence` sheet (minimum: Domain,
  Company Name, Industry, Value Proposition placeholder).
- Mark status `Needs Enrichment` in the row (will be picked up by
  `muso-outreach-enrichment` when that skill is wired).
- Update `parent-companies.md` with any new parents/subsidiaries.
- Log to `api-logs/sheets/YYYY-MM-DD.jsonl`.

## Silent Rule

If no new companies match criteria on a given day (unlikely but possible), the
cron runs silently. Never post "nothing new found" messages.

## Constraints

- Only 5 parent companies per day
- Always target parents, never subsidiaries
- Always dedupe against all 4 sources
- Always post to `#company-finder` (not `#sales-alerts`)
- Never add companies to `contacts_intelligence` (that is for contacts only)
- Never enrich contacts inside this skill (that is `muso-outreach-enrichment`)
- Exploration vertical picks must be labeled as such

## Dependencies on Other Subskills

- `muso-outreach-enrichment`: picks up `Needs Enrichment` rows and fills in
  contact data via Snov.io / Enrow / Datagma (NOT YET WIRED)
- `muso-outreach-ghl-sync`: will create a Cold stage placeholder once contacts
  are enriched and ready for outreach

<!-- synced from node-8: 2026-04-13 -->
