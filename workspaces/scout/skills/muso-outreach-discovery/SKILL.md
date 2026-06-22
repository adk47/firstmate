---
name: muso-outreach-discovery
description: |
  Daily parent company discovery for Muso Ads B2B outreach. Finds new parent
  companies matching target verticals through a deterministic pipeline:
  discover (subagents) → union → ONE dedupe call → website liveness verify →
  LinkedIn evidence → record in the Seen Ledger → post to #company-finder.

  Runs as a cron at 1 PM CEST daily, and on demand when McLaren/Fede asks
  "find me N companies in category X" — the full criteria below apply to the
  bare ask; nobody has to paste a rules prompt.

  Use when: "find new companies", "find me N companies", "company finder",
  "daily discovery", "new targets"

  Triggers: "find companies", "find me companies", "discover companies",
  "new targets", "company batch", "company finder"
depends-on:
  - muso-slack-formatter
  - muso-nocodb
metadata:
  version: "2.0"
  last-updated: "2026-06-11"
  status: "deterministic pipeline: dedupe + verify + Seen Ledger (PR pending id pin)"
---

# Muso Outreach Discovery

Finds new parent companies matching Muso Ads target verticals. Discovery is
LLM-driven; **dedupe, liveness and recording are deterministic scripts** — the
2026-06-10 batch (26/60 duplicates, 6 dead, 4 no-LinkedIn) is what happens
when any of them is left to prompt rules.

## Access Control

Fede (U07NF5A77E2) and Aaron (U7RP6HKUZ) can approve new companies.
McLaren can request batches and report review outcomes.
Read only for everyone else.

## Shared Config

See `/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/config.md`.

> **Cross-workspace note (Scout-owned skill).** Company-finder lives with Scout, but its
> reference files — `config.md`, `target-verticals.md`, and `parent-companies.md` — remain the
> canonical source of truth inside CMO's outreach-engine and are shared with the rest of CMO's
> funnel (sender, enrichment, qa). Always read AND write them at their absolute
> `/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/` paths. Never make a local
> copy in Scout's workspace — a second copy silently diverges from the funnel.

## Cadence & Batch Cap

**Daily at 1 PM CEST** (cron `company-finder-daily`), 5 companies per day.
On-demand asks: **hard max 10 companies per run.** If someone asks for more
(e.g. "find me 60"), say that quality collapses past ~10 (the 2026-04-11
50-company batch shipped fake domains) and deliver in daily batches instead.

## Target Verticals

See `/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/target-verticals.md` for
the full list. A bare "find me N companies in category X" uses X as the vertical.

## Hard Requirements (canonical criteria — apply to EVERY batch)

Every company in a batch must pass ALL of these. Requesters do not need to
restate them; this skill IS the ruleset.

1. **Niche fit**: product/service directly relevant to working music
   professionals (creators, technical pros, business-side pros, artists).
   No generic B2B SaaS. No general-consumer brands unless they actively
   market to musicians.
2. **Real website** (URL required) — mechanically verified, see Step 3.
3. **Active LinkedIn company page** (URL required) — evidence-fetched, see
   Step 4.
4. **Genuinely new** — mechanically deduped, see Step 2. Never claimed by
   recall; there is no "if unsure, flag it" escape hatch.
5. **Visible marketing spend in the last 12 months** (active social, recent
   launches, paid ads, sponsorships, content marketing, podcast sponsorships,
   NAMM/AES booths).
6. **English-speaking primary market** OR clearly markets to US/UK/EU
   musicians.
7. **Company size 2–500 employees** — no solo operators; giants
   (Universal, Spotify, Apple, Adobe-level) handle their own deals.
8. **Not a Muso competitor** (credits/profile/analytics platforms for music
   pros: Jaxsta, Roon, Sonemic, Soundways, AllMusic, etc.).
9. **Not dead, acquired into a bigger holding, or dormant** in the last
   12 months.
10. **Always parents, never subsidiaries** (rollup logic in Step 5).

If fewer than N companies pass every check, return fewer — quality over
quantity. At the bottom of every batch, list rejected considerations with a
one-word reason: `DEAD`, `TOO_BIG`, `NOT_NICHE`, `NO_LINKEDIN`, `IN_NOCO`,
`IN_LEDGER`, `IN_BATCH`, `ACQUIRED`, `COMPETITOR`, `BLOCKED`.

## Pipeline (normative — steps in this order, no skipping)

```
discover (per-vertical subagents, JSON only)
  → UNION all candidates from all verticals
  → ONE dedupe-candidates.sh call on the union
  → verify-candidates.sh (website liveness)
  → LinkedIn web_fetch evidence per survivor
  → parent rollup + score + select top N
  → ledger.sh suggest          (records Status=suggested — BEFORE posting)
  → post to #company-finder
```

### Step 1: Discover (subagent fan-out)

Spawn one discovery subagent per vertical **using exactly this prompt**
(fill `{VERTICAL}` and `{N}`):

```
You are a discovery-only subagent for the vertical: {VERTICAL}.
Use web_search/web_fetch to surface up to {N} candidate parent companies
relevant to working music professionals (no generic B2B SaaS, no giants,
2–500 employees, US/UK/EU market).
Return ONLY a JSON array: [{"name":"…","domain":"…","vertical":"{VERTICAL}","why":"1 line"}].
Do NOT check NocoDB. Do NOT claim anything is new, deduped, alive, or has a
LinkedIn page — dedupe and verification happen downstream deterministically.
Do NOT post to Slack. Return the JSON array and nothing else.
```

Subagents have **zero dedupe responsibility** — that is downstream and
deterministic, so there is nothing for them to skip.

Target ~3-4× the requested batch size in raw candidates across verticals.

### Step 2: Dedupe — ONE call on the UNION

Union ALL subagent outputs into a single JSON array first. **Per-category
dedupe calls are forbidden** — subagents are blind to each other, and split
calls can't see cross-vertical duplicates (the script's `reason:"batch"`
handles within-union dupes only when it sees the whole union at once).

```bash
echo "$UNION_JSON" | bash /opt/hydra/scripts/company-finder/dedupe-candidates.sh
# -> { "new":[…], "duplicates":[…], "name_flags":[…], "stats":{…} }
```

The script snapshots **three required sources** — Company Intelligence
(`mvr6nmzcv7albxt`), Contacts Intelligence (`m9vsbijhrr9ddeu`) and the
**Company Seen Ledger** (every company ever suggested, including rejected
ones) — normalizes both sides, and self-dedupes the union.

- Carry forward **ONLY** `.new[]`.
- `.name_flags[]` are kept but noted in the post (possible rebrand for human
  eyes). Never drop on a name flag alone.
- **Fail-closed:** non-zero exit / `DEDUP_SOURCE_UNAVAILABLE: <table>` →
  do NOT ship a normally-deduped batch. Reply `NO_REPLY` or mark the batch
  PARTIAL/UNSAFE naming the failed source.
- Do NOT hand-roll per-candidate `records.ls --where` lookups. Ever.

### Step 3: Verify website liveness (deterministic)

```bash
echo "$NEW_JSON" | bash /opt/hydra/scripts/company-finder/verify-candidates.sh
# -> { "alive":[…], "blocked":[…], "dead":[…], "stats":{…} }
```

- **Drop** `.dead[]` — list them in the rejects with reason `DEAD`.
- **Keep** `.blocked[]` (bot-walled sites are usually real companies behind
  Cloudflare) but flag them visibly in the post: `⚠ site bot-walled, eyeball it`.
- **Fail-closed:** exit 2 / `VERIFY_NETWORK_SUSPECT` means OUR egress is
  suspect, not that every company died — PARTIAL/UNSAFE, never a silent
  all-dead batch.

### Step 4: LinkedIn evidence (fetched, not recalled)

For each survivor, `web_fetch` its LinkedIn company page. Record a dated
evidence line per company:

```
LinkedIn: https://www.linkedin.com/company/<slug> — page live, last post <date>, fetched <today>
```

No fetchable LinkedIn company page → move to rejects with `NO_LINKEDIN`.
A LinkedIn URL produced from memory without a fetch is not evidence.

### Step 5: Parent rollup, score, select

Rollup (unchanged from v1):

1. Candidate is a **known subsidiary** (listed in the shared
   `/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/parent-companies.md`) →
   drop it; the parent is the target.
2. Candidate is a **new parent** owning subsidiaries already in NocoDB →
   flag for rollup: add parent + subsidiaries to the shared
   `/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/parent-companies.md`, note
   it in the output, do NOT remove subsidiary rows from NocoDB (flag for Fede).
3. Standalone parent or simple small brand → include as is.

Also drop matches in the GHL B2B-Ads-Clio pipeline (all stages):

```bash
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=S5w31kRRgsBjjiVATWlP" -d "pipeline_id=GeSt85TueSvJ0SNFZXfQ" \
  -d "limit=100" -d "page=1"
# Paginate all pages
```

Score on: vertical match (active > exploration), market size indicator, ICP
fit, cleanliness. Select the top N (≤ batch cap). Exploration-vertical picks
must include a note on why they're worth surfacing now.

### Step 6: Record in the Seen Ledger — BEFORE posting

**6a. Terminal rejects first.** Every company that survived dedupe but was
mechanically rejected — `DEAD` (from verify), `NO_LINKEDIN` (Step 4),
`IN_GHL`, `SUBSIDIARY` — gets a rejected ledger row so it is never
re-discovered and re-checked on future runs:

```bash
echo "$TERMINAL_REJECTS_JSON" | BATCH_SOURCE="cron:company-finder-daily" \
  bash /opt/hydra/scripts/company-finder/ledger.sh record-rejects
# input: [{"name":…,"domain":…,"reason":"DEAD"|"NO_LINKEDIN"|"IN_GHL"|"SUBSIDIARY",…}]
```

**Do NOT record score-cuts** (companies that passed every check but didn't
make today's top N) — they are legitimately re-surfaceable in a future
batch. `record-rejects` is idempotent: already-known domains are skipped and
reported, never a fatal collision.

**6b. Then the batch itself:**

```bash
echo "$FINAL_BATCH_JSON" | BATCH_SOURCE="cron:company-finder-daily" \
  bash /opt/hydra/scripts/company-finder/ledger.sh suggest
```

(`BATCH_SOURCE="manual"` — the default — for on-demand asks.)

Each company is recorded with `Status=suggested`, which is what prevents it
from EVER being re-suggested, even if the review never happens. Include each
company's LinkedIn evidence line in its `evidence` field.

**Fail-closed:** any non-zero exit → do NOT post a normal batch.
`LEDGER_COLLISION` means dedupe was skipped or raced — re-run the pipeline
from Step 2. Other failures → PARTIAL/UNSAFE naming the marker
(`LEDGER_SOURCE_UNAVAILABLE` / `LEDGER_WRITE_FAILED`).

The Slack post happens ONLY after the ledger write succeeds.

### Step 7: Post to #company-finder

Channel: `#company-finder` (`C0ARS7XMY93`). Format (per
`muso-slack-formatter`), one row per company:

```
*New Company Batch, YYYY-MM-DD* (N parent companies)

{Vertical}:
  1. *{Company Name}* (`domain.com`)
     Website: {url} | LinkedIn: {url}
     HQ: {country} | Size: {employees}
     Why: {1 line ICP fit tied to a music-pro audience need}
     Spend signal: {1 specific marketing-spend signal}
     First touch: {Founder/CEO/Head of Marketing — name + title if findable}
     {⚠ site bot-walled, eyeball it — only for blocked[] entries}
     {⚠ possible match: {name} — only for name_flags[] entries}

Rejected considerations: {Name} DEAD · {Name} NO_LINKEDIN · {Name} IN_LEDGER · …

Subsidiaries rolled up to parents:
  • subsidiary1.com → parent1.com (new parent added)
```

Wait for Fede/McLaren to react with ✅ / 👍 (approve) or report rejects.

### Step 8: Review flips (when the human review comes back)

Per **approved** company:

```bash
bash /opt/hydra/scripts/company-finder/ledger.sh approve <domain> --industry "<Industry>"
```

This creates the Company Intelligence row (Status `Needs Enrichment`, picked
up by `muso-outreach-enrichment`) AND flips the ledger row. **Never call
`records.create mvr6nmzcv7albxt` directly** — `ledger.sh` is the only
sanctioned write path (it normalizes the domain and enforces uniqueness;
NocoDB Cloud cannot).

Per **rejected** company:

```bash
bash /opt/hydra/scripts/company-finder/ledger.sh reject <domain> "<reason>"
```

Companies left undecided stay `suggested` — still deduped against, which is
the correct failure mode when review feedback never arrives.

Also update the shared
`/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/parent-companies.md` with any
new parents/subsidiaries and log
to `api-logs/discovery/YYYY-MM-DD.jsonl`.

## Silent Rule

If no new companies pass on a given day, the cron runs silently (`NO_REPLY`).
Never post "nothing new found" messages.

## Constraints

- 5 parent companies per day (cron); hard max 10 per on-demand run
- Always parents, never subsidiaries
- ONE dedupe call on the union; never per-category, never hand-rolled
- Website liveness via `verify-candidates.sh`; LinkedIn via fetched evidence
- `ledger.sh record-rejects` (terminal rejects) + `ledger.sh suggest` before
  posting; `approve`/`reject` for review flips; score-cuts never ledgered
- All NocoDB company writes go through `ledger.sh` — no direct `records.create`
- Never add companies to Contacts Intelligence (`m9vsbijhrr9ddeu`)
- Never enrich contacts inside this skill (that is `muso-outreach-enrichment`)
- Exploration vertical picks must be labeled as such
- Fail-closed markers (`DEDUP_SOURCE_UNAVAILABLE`, `VERIFY_NETWORK_SUSPECT`,
  `LEDGER_*`) → PARTIAL/UNSAFE or NO_REPLY, never a silently degraded batch

## Dependencies on Other Subskills

- `muso-nocodb`: the REST wrapper the company-finder scripts call
- `muso-outreach-enrichment`: picks up `Needs Enrichment` rows (NOT YET WIRED)
- `muso-outreach-ghl-sync`: creates Cold stage placeholders post-enrichment
