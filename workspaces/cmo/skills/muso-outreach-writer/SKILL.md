---
name: muso-outreach-writer
description: |
  Draft personalized B2B cold outreach emails for Muso Ads in the voice of the
  sender (Aaron Kaufman CEO for a@/ak@/aaron.k@, Federico Cappuccilli CMO for f@).
  Pulls contact + company data from the enriched leads database, applies the Muso
  opening framework, and returns ready to send HTML emails.

  Companion skill to muso-outreach-engine. Handles copy craft only.

  Use when: writing or editing a cold email, drafting follow ups, personalizing a
  template, or any "write an email to this lead" request.

  Triggers: "cold email", "outreach email", "b2b email", "write email to lead",
  "draft outreach", "sales email", "book a meeting email", "ads outreach"
depends-on:
  - muso-outreach-engine
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Outreach Writer

Copy craft for B2B Ads outreach. Owns voice, opening framework, personalization.
Called by `muso-outreach-sender` and `muso-outreach-followup` to produce the
actual email body.

## Shared Config

All IDs, accounts, sheets, and rules come from
`../muso-outreach-engine/references/config.md`. Never hardcode.

## Pick filter (NocoDB only)
NocoDB `Contacts Intelligence` joined with `Company Intelligence` is the only source of truth for picking outreach contacts. Read `Status` to identify untouched contacts. Do NOT crosscheck against Gmail labels, GHL pipelines, or Google Sheets. NocoDB is READ-ONLY for this skill — Nick/team manages `Status` manually.

Minimum requirements for any picked row:
- `Status` is empty (untouched) AND not in the hardcoded known-clients list below.
- `Valid Professional Email` is present and verified.
- Linked `Company Intelligence` row has a non-empty `Why Muso Ads Matters`. If empty, drop the contact and pick another. Never generic-backfill.

## Known clients / partners (hardcoded exclusion)
These companies are already Muso Ads clients, partners, or social-proof references. Their contacts MUST be excluded from every pick, regardless of NocoDB `Status` (Status is for outreach state, not client state — current clients live in Status=empty because no one ever outreached to them; they came in another way).

Seed list (2026-05-27):
- IK Multimedia
- Mix With The Masters
- Slate Digital
- Jamstik
- Kali Audio

Match is case-insensitive and ignores common suffixes (Inc, LLC, Ltd, GmbH, S.r.l., Co., AS). When in doubt, drop and ask Nick.

Maintenance: this list is human-curated. When Nick or Aaron names a new client/partner/integration, add them here AND remove any in-flight drafts to those companies. Do not auto-detect from Stripe / GHL / anywhere — that's drift-prone. Hardcode is the source.

## Enrichment load (per picked contact)
For every picked contact, load the full linked Company Intelligence row: `Company Description`, `Value Proposition`, `Target Customer`, `Why Muso Ads Matters`, `ICPCategory Label`. These map directly into the email body (see Required Elements below).

## What this skill does NOT do
- Does not write to NocoDB (read-only).
- Does not send emails (drafts only). Sending requires explicit Nick approval.
- Does not touch GHL pipelines, Google Sheets logbooks, or any non-NocoDB source.
- Does not email known clients / partners. See the hardcoded exclusion list above.

## Voice by Sender

The voice depends on the Muso account the email is being sent from.

### Aaron Kaufman, CEO (a@, ak@, aaron.k@)

Default for cold outreach.

- **Confident.** State facts. "We have 500K+ verified music professionals" not "we're exploring ways to help."
- **Peer level.** CEO writing to a peer. Warm but not eager. Direct but not pushy.
- **Intriguing.** Do not over explain. The email's job is curiosity, not closing.
- **Short.** 3 paragraphs max. 80 to 120 words body. 60 for tight single batch sends.

Signature:
```
Aaron Kaufman
CEO, Muso.AI
```

### Federico Cappuccilli, CMO (f@)

Follow ups, logistics, meeting booking, warmth moves.

- **Operational warmth.** Fede handles the logistics part of the Aaron + Fede motion.
- **Slightly more conversational** than Aaron, still direct and tight.
- **Same length rules** and same ban on em dashes.

Signature:
```
Federico Cappuccilli
CMO, Muso.AI
```

## Hard Rules

- **Em dash (—) PROHIBITED.** Zero tolerance. Use commas, periods, parentheses, or restructure.
- Body under 120 words (under 60 for tight sends)
- 3 paragraphs max
- HTML only. Wrap each paragraph in `<p>...</p>`.
- Hyperlink "Muso.AI" ONCE, first mention only:
  `<a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>`
- Do NOT open with the pitch
- Do NOT assume the reader already cares about Muso
- Never send Aaron voice from f@ or Fede voice from a@/ak@/aaron.k@

## Opening Framework (Mandatory, 3 Step)

Every cold email opens with this sequence BEFORE any pitch:

1. **Establish identity.** "I'm Aaron, CEO at Muso.AI." Peer dynamic, not sales rep.
2. **Flattery with plausibility.** "Your name came up on our shortlist of companies we'd like to partner with." Selected, not spammed.
3. **Seed curiosity.** "Not sure if you've come across Muso.AI before, you've probably seen big artists talking about us." Humble and disarming.

Then the role specific data kicks in.

Example Aaron opening:

```
Hey {First Name}, I'm Aaron, CEO at Muso.AI. Your name came up on our
shortlist of companies we'd like to partner with.

Not sure if you've come across Muso.AI before, you've probably seen big
artists talking about us. We have 500K+ verified music professionals using
our platform daily to track credits, catalog, and career data.
```

Never open with the pitch, a data point, or any line assuming the reader
already cares about Muso.

## Required Elements

Every email MUST include:

1. **Company specific hook** (1 or 2 sentences). Shows you know their business.
   Pulled from `Why Muso Ads Matters` in NocoDB Company Intelligence. This line
   should NOT work for any other company.
2. **The pitch** (1 or 2 sentences). What Muso Ads is and why it is different:
   - 500K+ verified music professionals
   - Hyper targeting by role, credits, genre, career stage
   - Not available on any other platform
3. **The CTA**. One clear ask. Book a call at `calendar.muso.ai`.

## Subject Lines

### C Suite Default
`Private Invite - {First Initial}. {Last Name}`
Example: Toby Velazquez → `Private Invite - T. Velazquez`

Status recognition, personalized peer framing, zero threat signal. Test: if it
could appear in a forwarded thread between two execs, it works.

### Alternatives
- Number or insight ("41,000 mixing engineers")
- Provocative framing
- Max 6 words, lowercase, no company name

## Banned Phrases

- "Just reaching out", "I was wondering", "I'd love to"
- "Exploring partnerships", "potential synergies"
- "Hope this finds you well", "Hope you're doing great"
- "I think you'll find this interesting"
- "Please let me know", "at your earliest convenience"
- "Circling back" (in initial outreach)
- Hedging: "maybe", "perhaps", "might be worth"

## ICP Name Drops

Always include Bad Bunny, plus 2 genre relevant names based on the company's
`ICPCategory Label`. See `../muso-outreach-engine/references/icp-name-drops.md`.

Insert into this template line:

```
We have nearly 1M active music professionals, {name_drop_line}, using our
platform daily to track credits, catalog, and career data.
```

Default if no category match: `from Bad Bunny and Max Martin to Poo Bear`.

## Pulling Templates

Never hardcode copy. Pull from the `email_templates` sheet:

```bash
gog sheets get 1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I \
  --range "email_templates" --account a@muso.ai
```

Filter by `Template Type` and `When to Use`. Rotate across a batch. Vary 1 or
2 words per send (synonym swap) to dodge spam filter repetition.

After send, report back to `muso-outreach-sender` which template was used so it
can bump `Times Sent` and `Last Used Date`.

## Follow Up Copy

Cadence from shared config: 7 days, 14 days, 140 days. Stop at 3 with zero replies.

- Pull from `email_templates` sheet (Template Type = Follow-Up or FU-01/02/03/04)
- Rotate across a batch, vary 1 to 2 words
- Reference the original thread
- Shorter than original (2 paragraphs max)
- Add one new data point or angle
- Never desperate, never pushy

Proven scarcity line: `10 of 12 spots filled, 2 left`. Real scarcity only, never
fabricate.

## Personalization Checklist

Before handing an email back to sender, verify:

- [ ] First sentence references something specific about the company (not just the name)
- [ ] Hook pulled from `Why Muso Ads Matters` or deep research
- [ ] Name drops match `ICPCategory Label`
- [ ] Subject line uses Private Invite format (C suite) or a company neutral insight
- [ ] No banned phrases
- [ ] No em dash anywhere
- [ ] Under 120 words body
- [ ] CTA is calendar.muso.ai or access.muso.ai/demo
- [ ] Voice matches sender (Aaron vs Fede)
- [ ] HTML wrapped, Muso.AI hyperlinked once
- [ ] Signature matches sender

## Inputs / Outputs

**Inputs** (from `muso-outreach-sender` or `muso-outreach-followup`):
- Contact row (from NocoDB Contacts Intelligence)
- Company row (from NocoDB Company Intelligence, matched by Domain)
- Template type (`Initial`, `Follow-Up`, `FU-01`, `FU-02`, `FU-03`, `FU-04`)
- Sender account (a@, ak@, aaron.k@, f@)
- Deep research hook (optional, from web_search results)

**Outputs**:
- `subject`: subject line string
- `body_html`: HTML body wrapped in `<p>` tags
- `template_id`: which template row was used (for writeback)
- `checklist_passed`: boolean, all personalization checks green

## References

- `references/email-analysis.md`, lessons from 80+ real replies (historical)
- `../muso-outreach-engine/references/config.md`, shared config
- `../muso-outreach-engine/references/icp-name-drops.md`, name drop table
- `../muso-outreach-engine/references/target-verticals.md`, ICP categories

## Draft Creation (Required Metadata)

After generating the HTML body, ALWAYS append this HTML comment at the
very bottom of `body_html`:

    <!-- muso-outreach:v1 {"kind":"new","sheet_row_id":<N>,"opp_id":"<X>","template":"<T>","sender":"a@muso.ai","original_thread_id":null} -->

(For follow-ups, use `"kind":"followup"` and set `"original_thread_id"`
to the original thread's ID.)

When creating the Gmail draft via `gog gmail drafts create`, ALWAYS
also apply the full set of `muso-meta/*` labels described in
`../muso-outreach-engine/references/config.md` → "Outreach Draft Metadata".

Omitting either the comment or the labels will cause the sender worker
to block the draft at send time.
