---
name: muso-b2b-copywriter
description: >
  Craft personalized B2B cold outreach emails for Muso Ads. Pulls contact + company
  intelligence from the enriched leads database, checks pipeline for existing history,
  and writes tailored emails designed to book meetings.
  
  Use when: writing cold emails for Muso Ads B2B outreach, drafting outreach sequences,
  personalizing emails from the B2B database, or any "write an email to this lead" request.
  
  Triggers: "cold email", "outreach email", "B2B email", "write email to lead",
  "draft outreach", "sales email", "book a meeting email", "ads outreach"
---

# Muso B2B Copywriter

## Data Sources

### Enriched Leads Database
Google Sheet: `1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ`
Account: `a@muso.ai`

Two sheets:
- **contacts_intelligence** (cols A-L): Row ID, Status, Source, Domain, Company Name, First Name, Last Name, Title, Job Category, Rank, Valid Professional Email, LinkedIn URL
- **company_intelligence** (cols A-J): Domain, Company Name, Industry, LinkedIn URL, Company Description, Value Proposition, Value Statement, Target Customer, ICP Category, Why Muso Ads Matters

**Join key:** `Domain` field links contacts to their company record.

### Pipeline Check — 3-Point Crosscheck (MANDATORY — Fede's directive, Mar 11 2026)

**Before writing ANY email, run the full 3-point crosscheck. No exceptions. No guesswork.**

| # | Source | Check | Command |
|---|--------|-------|---------|
| 1 | **Gmail** (`a@muso.ai`) | Prior outreach, replies, conversations. Also check **Calendar** for booked meetings. | `gog gmail messages search "[company]" --account a@muso.ai` + `gog gmail messages search "label:B2B- Ads [company]" --account a@muso.ai` |
| 2 | **GHL** (B2B-Ads-Clio pipeline) | Pipeline stage, opportunity status. Is this company already tracked? | `GET /opportunities/search?location_id=S5w31kRRgsBjjiVATWlP&pipeline_id=GeSt85TueSvJ0SNFZXfQ&limit=100&page=N` (paginate ALL pages) |
| 3 | **Google Sheet** (`clay_n8n_clio_b2b_ads`) | Contact details, Status column, Last Contacted date. | `gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ --range "contacts_intelligence" --account a@muso.ai` |

**Additional checks:**
- Stripe: `stripe customers search --query "name~'[company]' OR email~'[domain]'"` — existing paying customer?
- ClickUp: search for company name — active deal/task?

**Domain variant rule:** Many companies use abbreviated domains (e.g., Mix With The Masters → mwtm.com). Always search Gmail by company name AND all known domain variants.

**GHL API access:**
- Location: `S5w31kRRgsBjjiVATWlP` | Pipeline: `B2B-Ads-Clio` → `GeSt85TueSvJ0SNFZXfQ` | Key: `$GHL_API_KEY`
- ⚠️ Use GET with `page=N` for pagination (POST cursor is broken, caps at 100)

If prior outreach exists, adapt tone (reference previous touch, don't re-introduce).
If actively in conversation → **EXCLUDE from batch entirely.**
If in ANY GHL pipeline stage → **SKIP** unless Fede explicitly approves.

## Copy Framework

Read `references/email-analysis.md` for detailed patterns from real outreach history.

### Voice & Tone

Write as **Aaron Kaufman, CEO** — not a sales rep, not a marketing team, not AI.

- **Confident.** State facts. "We have 500K+ verified music professionals" not "we're exploring ways to help."
- **Peer-level.** CEO writing to a peer. Warm but not eager. Direct but not pushy.
- **Intriguing.** Don't over-explain. Leave something for the call. The email's job is to spark curiosity, not close a deal.
- **Short.** 3 paragraphs max. Every sentence earns its place or gets cut. Target 80-120 words body (excluding signature).

### Opening Framework (MANDATORY)

3-step sequence before ANY pitch:
1. **Establish identity** — "I'm Aaron, CEO at Muso.AI." Peer dynamic.
2. **Flattery with plausibility** — "Your name came up on our shortlist." Selected, not spammed.
3. **Seed curiosity** — "Not sure if you've come across Muso.AI before..." Humble, disarming.

```
Hey [First Name], I'm Aaron, CEO at Muso.AI. Your name came up on our shortlist
of companies we'd like to partner with.

Not sure if you've come across Muso.AI before — you've probably seen big artists
talking about us. We have 500K+ verified music professionals using our platform
daily to track credits, catalog, and career data.
```

**NEVER open with:** the pitch, a data point, or any line assuming the reader already cares about Muso.

### Banned Phrases & Characters
- "Just reaching out" / "I was wondering" / "I'd love to"
- "Exploring partnerships" / "potential synergies"
- "Hope this finds you well" / "Hope you're doing great"
- "I think you'll find this interesting"
- "Please let me know" / "at your earliest convenience"
- "Circling back" (in initial outreach)
- Any hedging language: "maybe", "perhaps", "might be worth"

### BANNED CHARACTER — Em Dash "—" (ABSOLUTE RULE)
**NEVER use em dashes (—) in any email. Period.** Use commas, periods, or restructure the sentence instead. Aaron has flagged this repeatedly. Zero tolerance. This applies to all outreach emails, follow-ups, and any text that will be sent via email.

### Required Elements

Every email MUST include:

1. **Company-specific hook** (first 1-2 sentences) — something that shows you know their business. Pull from Company Intelligence fields: what they do, who they sell to, why Muso matters for them specifically. This line should NOT work for any other company.

2. **The pitch** (1-2 sentences) — what Muso Ads is and why it's different. Keep it tight:
   - 500K+ verified music professionals
   - Hyper-targeting by role, credits, genre, career stage
   - Not available on any other platform

3. **The CTA** — one clear ask. Book a call: `calendar.muso.ai`

### Optional Elements (Use When Relevant)
- Scarcity/exclusivity framing ("invite-only", "limited launch partners")
- Social proof ("brands like [X] are already in")
- Specific audience size for their vertical (e.g., "41K mixing engineers" for pro audio)
- Preview link: `access.muso.ai/demo`

### Structure Templates

**Template A — The Hook** (best for strong ICP match)
```
[Company-specific insight — why THEIR audience is on Muso]

[What Muso Ads is — one sentence. Differentiation — one sentence.]

[CTA]
```

**Template B — The Question** (best for sparking curiosity)
```
[Provocative question about their marketing challenge]

[How Muso solves it — brief. Credibility stat.]

[CTA]
```

**Template C — The Data Drop** (best for data-driven contacts)
```
[Specific number relevant to their business — from Muso's data]

[Context for why that number matters for them. What they can do with it.]

[CTA]
```

### Subject Lines

**C-suite default: "Private Invite - {First Initial}. {Last Name}"** (recipient's name). Status recognition + zero threat signal. Reads like a personal note, not a campaign.

**Alternatives** (non-C-suite or when requested): number/insight ("41,000 mixing engineers"), provocative framing. Max 6 words, lowercase, no company name.

### Personalization Checklist

Before sending, verify the email passes these checks:
- [ ] First sentence references something specific about the company (not just their name)
- [ ] The "why Muso" angle is tailored to their ICP/target customer
- [ ] Subject line couldn't work for a different company (or is the Private invite format)
- [ ] No banned phrases
- [ ] Under 120 words body
- [ ] CTA is calendar.muso.ai
- [ ] Sent from a@muso.ai (or as specified)

## Companion Skill: muso-outreach-engine

**These two skills ALWAYS work together.** `muso-outreach-engine` is the primary skill (pipeline, execution, logistics), and this skill (`muso-b2b-copywriter`) handles email drafting/copy. When either is triggered, load both. Priority: outreach-engine drives the workflow, copywriter supports with email craft.

## Activity Log — Outreach Tracker Sheet

**Every outreach action MUST be documented in the tracker sheet:**
Sheet: `1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0`
Account: `a@muso.ai`

Each sheet/tab = the date of the activity. Log what was done, outcomes, what went well/didn't. See `muso-outreach-engine` SKILL.md for full logging format.

Fede requested this 2026-03-04 in #clio_x_fede.

## Workflow

1. **Pull contact** — random or specified from contacts_intelligence
2. **Pull company** — match via domain from company_intelligence
3. **Deep research** — check company website + LinkedIn for recent news, product launches, events. Use timely hooks when available ("I saw you just launched [X]"). Web search + fetch for recent company activity.
4. **Pipeline check** — GHL B2B-Ads-Clio pipeline + Stripe + ClickUp + Gmail history (all must be clean)
5. **Draft email** — using framework above, tailored to company intelligence + deep research
6. **Show draft** — present to requester with contact/company summary
7. **Send on approval** — via `gog gmail send --body-html` from `a@muso.ai` (or specified account)
8. **GHL sync** — create contact + opportunity in GHL pipeline (stage: Contacted) after send

## Email Sending Rules

- ALWAYS use `--body-html` with `<p>` tags. Never plain text.
- Send from `a@muso.ai` unless told otherwise.
- Include Aaron's signature block unless told otherwise.
- Test sends go to requester's email first.
- Log to `api-logs/gmail/YYYY-MM-DD.jsonl` before sending to actual leads.

## Follow-Up Emails

For follow-ups, check the original thread first. Reference something specific:
- "Sent you a note last week about [specific thing]"
- Add a new data point or angle they haven't seen
- Shorter than the original (2 paragraphs max)
- New subject line OR reply to original thread (ask requester)

## Post-Reply Playbook

See `muso-outreach-engine` Post-Reply Playbook for full reply handling by type.

**Key Insight:** The email's job is to get a reply, NOT close a deal. 80% of replies ask for more info. Optimize copy for curiosity, not conversion.
