---
name: muso-outreach-discovery
description: |
  Daily parent company discovery for Muso Ads B2B outreach. Finds new parent
  companies matching target verticals through an enforced pipeline: discover
  (bounded) → prep-batch.sh (dedupe + liveness) → LinkedIn evidence + tier +
  select → finalize-batch.sh (records the Seen Ledger AND posts). The two wrapper
  scripts are mandatory: a batch reaches #company-finder ONLY as finalize-batch.sh
  output — never hand-assembled or hand-posted.

  Runs as a cron at 1 PM CEST daily, and on demand when McLaren/Nick asks
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
  version: "3.0"
  last-updated: "2026-06-22"
  status: "enforced pipeline: prep-batch.sh (dedupe+liveness) + finalize-batch.sh (ledger+post gate)"
---

# Muso Outreach Discovery

Finds new parent companies matching Muso Ads target verticals. Discovery + tier
judgment are LLM-driven; **dedupe, liveness, the ledger write and the Slack post
are deterministic scripts you MUST exec** — `prep-batch.sh` then
`finalize-batch.sh`. Skipping them is exactly the 2026-06 leak: batches
hand-assembled from `web_search`, posted with zero dedupe, duplicates compounding
because nothing was ledgered. The wrappers make the correct path the *easy* path
(dedupe + ledger + post in one exec call), so there's no reason to hand-roll a
batch — see **THE INVARIANT** below.

## Access Control

Nick (U0AL36NADEY) and Aaron (U7RP6HKUZ) can approve new companies.
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

## Tier Rubric

Requesters (McLaren/Nick) often ask for a specific tier. Tier is driven primarily
by **visible marketing spend** (revenue is usually unknown), with company size as
a secondary cue. Classify every selected company (Step 4) and show its tier in the post.

| Tier | Profile | Signals |
|---|---|---|
| **Tier 1** | Best targets — well-funded, sustained, *visible* marketing spend | frequent paid ads, headline NAMM/AES presence, major sponsorships, big content / influencer programs |
| **Tier 2** | Solid — a real, consistent marketing budget | regular ads / content, event presence, active social with reach |
| **Tier 3** | Mid-size (~$1M–$5M), **modest** spend | boutique plugins, regional distros, indie sync libraries |
| **Tier 4** | Sub-$1M, **no real marketing budget** | skip cold outreach; do not surface unless explicitly asked for exploration |

- **Default**: surface Tier 1–3, label each; never surface Tier 4 unless asked.
- **Honor an explicit filter**: "Tier 1/2 only" ⇒ drop Tier 3 and Tier 4 — do not
  pad the count with a lower tier (returning fewer is correct, per Hard Requirements).
- The Tier 3/4 bands are McLaren's; the Tier 1/2 split is directional — if
  McLaren/Nick sharpen the bands (e.g. revenue thresholds), update this table.

## Pipeline (normative — steps in this order, no skipping)

```
discover (bounded)  →  prep-batch.sh  →  [you: LinkedIn evidence + rollup +
  tier + select top N]  →  finalize-batch.sh   (records the ledger AND posts)
```

> **THE INVARIANT — read it twice.** A company batch reaches #company-finder
> **only** as the output of `finalize-batch.sh`. You never hand-post a batch to
> the channel, never hand-run dedupe, and never write or *recall* dedupe/ledger
> output yourself. If you did not exec `prep-batch.sh` **and** `finalize-batch.sh`
> in THIS session, you have not produced a valid batch — say so plainly and post
> nothing. (Batches assembled from `web_search` and hand-posted, skipping these,
> are exactly the 2026-06 leak: duplicates shipped, nothing ledgered, dups
> compounding every run.)

> **This skill is in your context, so it is available — run it, don't go hunting for it.** If you
> can read this, `prep-batch.sh` and `finalize-batch.sh` are available to you. Never `read` a
> `SKILL.md` from a filesystem path to "verify" the skill exists, never treat a failed file read as
> proof a tool is missing, and never escalate a "tool availability blocker" or say the skill "isn't
> in your toolset." The only correct response to a company-finder request is to run the pipeline.

### Step 1: Discover (bounded — never hang)

Surface ~3-4× the requested batch size in raw candidates across the target
verticals using `web_search` / `web_fetch`. This is the only creative step; keep
it **bounded**.

- Work within a tight budget (a few searches per vertical, a couple of minutes).
- **Do NOT park the turn in `sessions_yield` waiting for spawned subagents to
  signal completion.** That wake is unreliable and is what hung a batch for 45
  minutes. Inline discovery is fine and fast. If you *do* fan out to subagents,
  give them a hard deadline and proceed with whatever has returned by then
  (PARTIAL) — a slightly thinner batch beats a hung one.
- Return raw candidates ONLY — no dedupe, no liveness, no "this is new" claims;
  all of that is downstream and deterministic.

Union everything into one JSON array:
`[{"name":"…","domain":"…","vertical":"…","why":"1 line"}, …]`.

### Step 2: `prep-batch.sh` — dedupe + liveness in ONE call

```bash
echo "$UNION_JSON" | bash /opt/hydra/scripts/company-finder/prep-batch.sh
# -> { "survivors":[…], "rejects":{duplicates,dead,name_flags}, "stats":{…} }
```

Runs the deterministic dedupe (Company Intelligence + Contacts + Seen Ledger,
normalized set-match) then the website-liveness check, and returns the alive-new
**survivors** plus categorized rejects. Carry forward **ONLY** `.survivors`.

- A survivor with `verification == "blocked"` is bot-walled — KEEP it, but add a
  `flags` entry `"site bot-walled, eyeball it"` in Step 4 so the post shows ⚠.
- `.rejects.name_flags[]` = NEW companies with a partial name overlap — keep, note
  the possible match in the post for human eyes; never drop on a name flag alone.
- `.rejects.duplicates` / `.rejects.dead` are out. Feed each `dead` into the
  terminal rejects (Step 4, reason `DEAD`); list dups on the post's Rejected line.
- **Fail-closed:** non-zero exit (2 = a dedupe source was unavailable, 3 =
  liveness/egress suspect) → do NOT ship. Reply `NO_REPLY` or mark the batch
  PARTIAL/UNSAFE, naming the gate. Never hand-roll a per-candidate lookup around it.

### Step 3: LinkedIn evidence (fetched, not recalled)

For each survivor, `web_fetch` its LinkedIn company page and attach a dated
evidence line:
`LinkedIn: …/company/<slug> — live, last post <date>, fetched <today>`.
No fetchable LinkedIn page → it becomes a terminal reject `NO_LINKEDIN`. A
LinkedIn URL recalled without a fetch is not evidence.

### Step 4: Rollup, tier, score, select

- **Rollup** (unchanged): a known subsidiary (in the shared
  `/opt/hydra/workspaces/cmo/skills/muso-outreach-engine/references/parent-companies.md`)
  → drop, target the parent; a new parent owning NocoDB subsidiaries → flag for
  rollup, add to that shared file (do not delete subsidiary rows; flag for Nick);
  standalone → keep. **GHL match = best-effort filter, NOT a required gate:** if
  the GHL pipeline is reachable, drop GHL-pipeline matches → terminal reject
  `IN_GHL` (the GHL search is in the Appendix); if the GHL read fails (e.g. 403 /
  network), SKIP the `IN_GHL` filter, still ship the batch, and add a batch flag
  `⚠ GHL pipeline filter unavailable — N candidates not checked` so Nick knows.
  Never fail the batch on a GHL failure — its durable home is CMO at enrollment,
  which owns the GHL pipeline.
- **Tier** (see the **Tier Rubric** above): classify each survivor against the
  rubric using its spend-signal evidence and label it. **If the requester named a
  tier filter ("Tier 1/2 only"), DROP everything outside it** — never surface a
  Tier 3/4 when Tier 1/2 was asked. Tier is your judgment, but it must be
  evidence-backed and shown per company in the post.
- **Score + select** the top N (≤ the batch cap). Score-cuts are NOT ledgered
  (they stay re-surfaceable); only DEAD / NO_LINKEDIN / IN_GHL / SUBSIDIARY are
  terminal rejects.

### Step 5: `finalize-batch.sh` — ledger + POST in ONE call (the gate)

Assemble the final object and pipe it in. **This is the only way a batch reaches
the channel.**

```bash
echo "$FINAL_JSON" | BATCH_SOURCE="manual" \
  bash /opt/hydra/scripts/company-finder/finalize-batch.sh
# $FINAL_JSON = {
#   "batch":   [ {name,domain,vertical,tier,website,linkedin,hq,size,why,
#                 spend_signal,first_touch,evidence,
#                 flags?:["site bot-walled, eyeball it"]}, … ],
#   "rejects": [ {name,domain,reason:"DEAD"|"NO_LINKEDIN"|"IN_GHL"|"SUBSIDIARY"} ],
#   "date":    "YYYY-MM-DD"
# }
# -> { "posted":{ts,channel}, "ledger":{suggested,rejects_recorded} }
```

It records the terminal rejects, writes the batch to the Seen Ledger
(`Status=suggested` — what stops a company from EVER being re-suggested), and
**only on a clean ledger write formats and posts the batch to #company-finder
itself.** You do not post; the script does, after the ledger. Use
`BATCH_SOURCE="cron:company-finder-daily"` for the cron, `manual` (default) on
demand.

- **Fail-closed:** non-zero exit → the batch is NOT in the channel, by design.
  - exit 3 `LEDGER_COLLISION` = a company slipped past dedupe (prep-batch skipped
    or raced) → re-run from Step 2 on the union; never retry blindly.
  - exit 2 / 4 = a ledger source/write or the post itself failed → report it; do
    NOT hand-post as a fallback (that reintroduces the exact bug this gate closes).
- Review flips (`approve`/`reject`) stay on `ledger.sh` directly — see Step 6.

Then wait for Nick/McLaren to react ✅ / 👍 (approve) or report rejects.

### Step 6: Review flips (when the human review comes back)

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

## Appendix — GHL pipeline check (Step 4, `IN_GHL`) — best-effort

Drop any candidate already in the GHL B2B-Ads-Clio pipeline (all stages). This is
a **best-effort** filter: `$GHL_API_KEY` is a CMO-owned credential that may be
absent or scoped-out for Scout, so a `403`/auth failure here is expected and
**must not fail the batch** — skip `IN_GHL` and flag the batch per Step 4.

```bash
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=S5w31kRRgsBjjiVATWlP" -d "pipeline_id=GeSt85TueSvJ0SNFZXfQ" \
  -d "limit=100" -d "page=1"
# Paginate all pages. A match → terminal reject IN_GHL (feed it into finalize's rejects).
# On 403 / non-200 / empty $GHL_API_KEY: SKIP IN_GHL, ship the batch, flag it — never fail-closed on GHL.
```

## Silent Rule

If no new companies pass on a given day, the cron runs silently (`NO_REPLY`).
Never post "nothing new found" messages.

## Constraints

- 5 parent companies per day (cron); hard max 10 per on-demand run
- Always parents, never subsidiaries
- **Dedupe + liveness only via `prep-batch.sh`** on the whole union (ONE call,
  never per-category, never hand-rolled)
- **Ledger + post only via `finalize-batch.sh`** — a batch reaches the channel
  ONLY as its output; never hand-post, never recall/fabricate dedupe/ledger output
- Discovery is bounded — never park in `sessions_yield` waiting on subagents
- Tier every selected company; honor an explicit "Tier N only" filter (drop the rest)
- `ledger.sh approve`/`reject` for review flips; score-cuts never ledgered
- All NocoDB company writes go through `ledger.sh` (called by the wrappers) — no
  direct `records.create`
- Never add companies to Contacts Intelligence (`m9vsbijhrr9ddeu`)
- Never enrich contacts inside this skill (that is `muso-outreach-enrichment`)
- Exploration vertical picks must be labeled as such
- Fail-closed markers (`DEDUP_SOURCE_UNAVAILABLE`, `VERIFY_NETWORK_SUSPECT`,
  `LEDGER_*`) → PARTIAL/UNSAFE or NO_REPLY, never a silently degraded batch

## Dependencies on Other Subskills

- `muso-nocodb`: the REST wrapper the company-finder scripts call
- `muso-outreach-enrichment`: picks up `Needs Enrichment` rows (NOT YET WIRED)
- `muso-outreach-ghl-sync`: creates Cold stage placeholders post-enrichment
