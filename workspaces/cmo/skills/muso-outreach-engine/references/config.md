# Outreach Engine Shared Config

Single source of truth for all IDs, URLs, and constants used by any
`muso-outreach-*` subskill. If you change something here, it propagates to
every subskill that references this file.

**Do not hardcode these values in individual subskills.** Always reference this file.

---

## Contact & Company Intelligence — NocoDB (CANONICAL)

Contact + company intelligence lives in **NocoDB** now — it is the source of
truth and supersedes the legacy `contacts_intelligence`/`company_intelligence`
Google Sheet tabs. Access via the **`muso-nocodb` skill**
(`bash scripts/nocodb-api.sh <subcommand>`, REST API v2, `xc-token` /
`NOCODB_API_TOKEN`). **There is NO NocoDB MCP server.**

- **Base**: `p11hvpwapu4hv0x` (B2B-ADS-intelligence) · workspace `w8fofvl1`
- Read: `records.ls <tableId> --where "(Domain,eq,…)" --fields "A,B"` ·
  Count: `records.count <tableId> --where "…"` ·
  Write: `records.update <tableId> '[{"Id":N,"Field":"…"}]'` / `records.create <tableId> '{…}'`
- The subcommand is `records.ls` (NOT `records.list`). `--where` syntax is `(Field,op,value)`.

| Table | tableId | Key columns | Purpose |
|-------|---------|-------------|---------|
| Contacts Intelligence | `m9vsbijhrr9ddeu` | Id, Row ID, Status, Source, Domain, Company Name, First Name, Last Name, Title, Job Category, Rank, Valid Professional Email, Snov.io LinkedIn, Enrow/Raw/RocketReach/Snov.io Email, STEP, Sender | Verified music-industry contacts. No bare `Email` col — match by `Domain` or `Valid Professional Email`. |
| Company Intelligence | `mvr6nmzcv7albxt` | Id, Domain, Company Name, Industry, Linkedin Company, Company Description, Value Proposition, Value Statement, Target Customer, ICPCategory Label, Why Muso Ads Matters, STEP, Status | Company records keyed by Domain. |

## Google Sheets

### Master Leads Sheet (templates + knowledge base only)
Contact/company intelligence has **migrated to NocoDB** (above). This Sheet now
serves only templates and the product knowledge base.
- **ID**: `1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I`
- **URL**: https://docs.google.com/spreadsheets/d/1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I/edit
- **Account**: `a@muso.ai`

| Tab | gid | Columns | Purpose |
|-----|-----|---------|---------|
| `email_templates` | 1594786637 | ID, Template Type, Template Name, Subject Line, Email Body, When to Use, Times Sent, Replies, Meetings Booked, Reply Rate (%), Booking Rate (%), Last Used Date, Notes/Learnings | Source of truth for ALL templates (initial + follow up) |
| `what_is_muso_ads` | 719587516 | free form | Product knowledge base |
| `how_muso_ads_works` | 2060687836 | free form | Campaign mechanics, placements, targeting |

### Outreach Log Sheet (Logbook)
- **ID**: `1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0`
- **Tab**: `muso-b2b-outreach-reports` (gid `1061766444`)
- **URL**: https://docs.google.com/spreadsheets/d/1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0/edit?gid=1061766444
- **Account**: `a@muso.ai`

Columns: `# | Date | Muso Email | Domain | Contact | Company | Title | Email | Action | Status | Email Subject | Template | Hook / Notes`

Allowed `Action` values: `Drafted`, `Sent`, `Follow-Up Drafted`, `Follow-Up Sent`, `Reply Received`, `Meeting Booked`, `Bounced`, `Closed Lost`, `Closed Won`.

Allowed `Status` values: `Pending Approval`, `Approved`, `Sent`, `Replied`, `No Reply`, `Meeting Booked`, `Bounced`, `Won`, `Lost`.

---

## GHL (GoHighLevel)

### B2B Ads Sales Location
- **Location ID**: `S5w31kRRgsBjjiVATWlP`
- **Pipeline**: `B2B-Ads-Clio` (`GeSt85TueSvJ0SNFZXfQ`)
- Used by: all outreach subskills
- Write access: full

### Churn Win Back Location (SEPARATE, DO NOT CONFUSE)
- **Location ID**: `fmK5Vl9sJv49WTYA0QyP`
- Used by: win back engine only

### API Configuration
- **Base URL**: `https://services.leadconnectorhq.com`
- **API Key**: `$GHL_API_KEY` (Private Integration Token in `~/.zshrc`)
- **Version header**: `Version: 2021-07-28`
- **Pagination**: Use GET with `page=N` for opportunity searches. POST search is broken (caps at 100, cursor does not work).

### Opportunity Metadata (Required on every create)
- **Name format**: `{Company Name} | {Contact Name}`
- **Custom field `sheet_row_id`**: the `Row ID` from NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`) (enables reverse lookup from GHL)
- **Tags**: `B2B-Ads`, `Outreach`

### Pipeline Stages
See `pipeline-stages.md` in this same directory. 11 stages total. Stage IDs must be fetched live from GHL on first use.

---

## Gmail

### Muso Email Accounts
| Email | Voice | Primary Use | Status |
|-------|-------|-------------|--------|
| `a@muso.ai` | Aaron Kaufman, CEO | Primary outreach (cold + follow up) | ACTIVE |
| `ak@muso.ai` | Aaron Kaufman, CEO | Alternative for rotation | WARMING (Snov.io, started 2026-04-09, full ~2026-05-21) |
| `aaron.k@muso.ai` | Aaron Kaufman, CEO | Alternative for rotation | WARMING (same) |
| `f@muso.ai` | Federico Cappuccilli, CMO | Logistics, meeting booking, Fede voice | WARMING (same) |

**Current rule**: ALL production sends from `a@muso.ai` only until ~2026-05-21.
Do NOT send real campaigns from warming accounts. Gmail scanning still runs
across all 4 accounts for crosscheck and reply detection (historical threads
may exist on any of them).

### Gmail Labels
- `B2B - Ads`, used by outreach engine across all 4 accounts
- `Win-Back`, used by win back engine (separate)

### CLI
- Tool: `gog` CLI
- Send format: always `--body-html` with `<p>` tags. Never plain text.
- Label flag: `--label "B2B - Ads"` on drafts create. Must be reapplied after `gog gmail drafts send` (labels do not auto inherit on draft send).

### Outreach Draft Metadata (REQUIRED on every outreach draft)

Every draft created by CMO for outreach MUST carry both (1) a set of
`muso-meta/*` Gmail labels and (2) a JSON HTML comment at the bottom
of the body. Drafts lacking the labels are **refused** by the sender
worker (see `scripts/muso-outreach-sender-worker.py`).

**Labels (primary):**
- `muso-meta/kind-followup` or `muso-meta/kind-new`
- `muso-meta/row-<sheet_row_id>`
- `muso-meta/opp-<ghl_opp_id>`
- `muso-meta/template-<template_key>`
- `muso-meta/sender-<a_at_muso.ai>` (replace `@` with `_at_`)
- `muso-meta/thread-<thread_id>` (follow-ups only)

**JSON comment (fallback):**

    <!-- muso-outreach:v1 {"kind":"followup","sheet_row_id":1234,"opp_id":"abc","template":"FU-01","sender":"a@muso.ai","original_thread_id":"1812f..."} -->

The worker prefers labels (they survive body edits). If the two
disagree, the worker blocks the draft with code `METADATA_LABEL_DISAGREE`.

---

## Slack Channels

| Purpose | Channel | ID |
|---------|---------|----|
| General marketing | `#marketing` | (lookup) |
| Muso Ads discussion | `#muso-ads` | (lookup) |
| Campaigns | `#campaigns` | (lookup) |
| Sales outreach notifications (sends, replies, meetings) | `#sales-alerts` | `C0ARQ021M40` |
| Daily new company finder batch | `#company-finder` | `C0ARS7XMY93` |
| Churn win back alerts (separate engine) | `#win-back-alerts` | `C0ARTH6U0S2` |
| Heartbeat posts | `#hydra-heartbeat` | (lookup) |

**Never** post sales outreach notifications to `#clio_x_fede`. That was the
legacy Clio channel and is deprecated for outreach.

---

## Output Rules

### Prohibited Characters
- **Em dash (—) is PROHIBITED.** Zero tolerance. Use commas, periods, parentheses, or restructure.
- En dash (–) is allowed.
- Hyphen (-) is allowed.

### Email Format
- HTML only. Wrap paragraphs in `<p>...</p>`.
- Hyperlink "Muso.AI" once, first mention only:
  `<a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>`
- Signature block matches sender voice (Aaron or Fede).
- Body under 120 words (under 60 for tight sends).
- 3 paragraphs max.

### Slack Format
- Follow `muso-slack-formatter` rules (mandatory output filter).
- No markdown tables, no headings. Bold: `*text*`. Italic: `_text_`. Links: `<url|text>`.
- Bullet markers: `•` not `-`.

---

## Voice by Sender

| Sender | Voice | Signature |
|--------|-------|-----------|
| `a@muso.ai` | Aaron Kaufman, CEO | `Aaron Kaufman\nCEO, Muso.AI` |
| `ak@muso.ai` | Aaron Kaufman, CEO | `Aaron Kaufman\nCEO, Muso.AI` |
| `aaron.k@muso.ai` | Aaron Kaufman, CEO | `Aaron Kaufman\nCEO, Muso.AI` |
| `f@muso.ai` | Federico Cappuccilli, CMO | `Federico Cappuccilli\nCMO, Muso.AI` |

Default for cold outreach: `a@muso.ai`.

---

## Follow Up Cadence

- Touch 1 (FU-01): 7 days after initial send
- Touch 2 (FU-02): 14 days after initial send
- Touch 3 (FU-03): 140 days after initial send
- Stop after 3 follow ups with zero replies.
- **Never send on Saturday or Sunday.** If a follow up falls on a weekend, push to Monday.

---

## Discovery Cadence

- **Daily**: 5 new parent companies discovered at 1 PM CEST
- Posted to `#company-finder`
- Deduped against sheet, GHL, and `parent-companies.md`

---

## API Log Destinations
- Gmail actions: `api-logs/gmail/YYYY-MM-DD.jsonl`
- GHL actions: `api-logs/ghl/YYYY-MM-DD.jsonl`
- Sheet actions: `api-logs/sheets/YYYY-MM-DD.jsonl`

Log format: `{timestamp, action, target, requester, payload_summary, result}`

---

## History

- 2026-04-09: initial shared config extracted from the monolithic outreach engine skill
