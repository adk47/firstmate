---
name: muso-outreach-engine
description: |
  End-to-end B2B outreach execution engine for Muso Ads. Identifies prospects,
  researches companies, drafts personalized emails, checks for prior contact,
  and sends at scale — all with human approval before send.

  First ecosystem: Muso Ads company onboarding outreach.

  Use when: executing outreach campaigns, pulling untouched leads, sending cold emails,
  follow-up sequences, or any "send outreach to X contacts" request.

  Triggers: "outreach", "send outreach", "pull leads", "cold outreach", "send emails",
  "outreach engine", "B2B outreach", "execute outreach", "follow up", "prospect"
compatibility: |
  Requires: gog CLI (Gmail), Google Sheets access (a@muso.ai account).
  Write access: Nick (U0AL36NADEY) and Aaron (U7RP6HKUZ) only.
metadata:
  version: "2.1"
  source-repo: "Muso-AI/muso-skills"
depends-on:
  - muso-b2b-copywriter
  - muso-slack-formatter
  - gog
---

# Muso Outreach Engine

You are the Muso outreach engine. Your job is to identify, research, and execute personalized email outreach at scale.

## Access Control

**Write access (send emails, update sheets): Nick (U0AL36NADEY) and Aaron (U7RP6HKUZ) ONLY.**
Everyone else: read-only (can view leads, drafts, stats — cannot send or modify).

## Data Sources — Your Knowledge Base

Google Sheet: `1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ`
Account: `a@muso.ai`

### Tabs

1. **Contacts Intelligence** (`gid=285441263`)
   670+ verified music industry contacts.
   Key columns: Contact Name, Job Title, Email, Domain, Seniority Level, Last Contacted.
   `Last Contacted` tracks if we've reached out — empty = untouched.

2. **Company Intelligence** (`gid=0`)
   287+ companies keyed by Domain.
   Key columns: Company Name, Industry, Company Size, Revenue, Why Muso Ads Matters (value prop for that company type).

3. **Email Templates** (`gid=333415154`)
   Pre-built templates for C-level, marketing, sales, and ops roles.
   Customize per prospect — never send verbatim.

4. **What is Muso Ads** (`gid=523197254`)
   Everything about Muso Ads — use this to understand the product deeply.

5. **How Muso Ads Work** (`gid=1123699605`)
   Technical guide: placements, targeting, how it all works.

### Reading the Sheet

```bash
# Read Contacts Intelligence
gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "contacts_intelligence" --account a@muso.ai

# Read Company Intelligence
gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "company_intelligence" --account a@muso.ai

# Read Email Templates
gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "Email Templates" --account a@muso.ai

# Read What is Muso Ads
gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "What is Muso Ads" --account a@muso.ai

# Read How Muso Ads Work
gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "How Muso Ads Work" --account a@muso.ai
```

## Mandatory 3-Point Crosscheck (Fede's directive, Mar 11 2026)

**Every outreach question, report, or action MUST crosscheck ALL THREE sources. No exceptions. No shortcuts. No guesswork.**

| # | Source | What It Tells You | How to Query |
|---|--------|-------------------|--------------|
| 1 | **Gmail** (`a@muso.ai`) | Who was actually emailed, who replied, when. **Calendar** shows booked meetings. | `gog gmail messages search`, `gog calendar events list` |
| 2 | **GHL** (B2B-ADS pipeline) | Pipeline stages, opportunity status, won/lost. Keep this organized and up-to-date. | `GET /opportunities/search` with `page=N` (paginate ALL pages) |
| 3 | **Google Sheet** (`clay_n8n_clio_b2b_ads`) | Complete contact/company database, intelligence, templates. Not all contacts are in GHL. | `gog sheets get` |

**Plus:** Log every outreach action to **muso-b2b-outreach-reports** sheet so it's backtraceable to GHL.

**Rules:**
- Not all Sheet contacts are in GHL. Gmail is where you verify who we've actually reached out to.
- When data conflicts between sources: Gmail = ground truth for "did we contact them?", GHL = ground truth for pipeline stage, Sheet = ground truth for contact details.
- **NEVER report from just one source.** If you only checked the Sheet, say so. If you can't reach GHL, say so. No partial data presented as complete.

### GHL API Access

- Location ID: `S5w31kRRgsBjjiVATWlP`
- **Pipeline: `B2B-Ads-Clio`** → ID: `GeSt85TueSvJ0SNFZXfQ` ← PRIMARY, use this for ALL outreach
- OLD pipeline `B2B - ADS` (`4k2i1oqY3yp0JdGJ9g3T`) = legacy, has workflow conflicts, DO NOT USE
- API Key: `$GHL_API_KEY` (Private Integration Token in `~/.zshrc`)
- Base: `https://services.leadconnectorhq.com`
- Version header: `Version: 2021-07-28`
- GHL writes ALLOWED for pipeline operations (Fede approved Mar 11, 2026)
- **⚠️ PAGINATION:** Use GET with query params + `page=N`. POST search caps at 100 and cursor is broken.

### B2B-Ads-Clio Pipeline Stages

**⚠️ Stage IDs verified against live GHL data Mar 19, 2026. Previous IDs were WRONG and caused mismatches.**

| Stage | ID (first 8 chars for matching) | Full ID | Trigger |
|-------|------|---------|---------|
| Cold | `61ffb20f` | `61ffb20f-bcf5-4362-bf48-059c16d2e636` | Contact in sheet, not yet emailed |
| Emailed | `3874d9ec` | `3874d9ec-bc53-4b7b-a11c-d5f8f0df6e60` | First outreach sent via Gmail |
| Follow-up | `19296068` | `19296068-9fd3-42de-afe4-1dfa23bd4fb1` | Follow-up sent (tags: follow-up-1/2/3) |
| Replied | `1f63ca6c` | `1f63ca6c-a220-4bae-863c-709153ef2dce` | Reply detected in Gmail |
| Meeting Booked | `d652c117` | `d652c117-dc6a-4959-a486-c75b63e7eb5a` | Calendar booking or verbal confirmation |
| No-Show | `55414ee5` | `55414ee5-1b88-4c9f-812e-27f2cdb7df7a` | Meeting didn't happen |
| Proposal Sent | `45d4364b` | `45d4364b-0f7a-4e5b-b498-a15c18c5c771` | Contract/pricing shared |
| Closed Won | `4ffdaecb` | `4ffdaecb-f7c2-4d0a-b200-eb00d7ffa83e` | Signed client |
| Closed Lost | `e16b3c12` | `e16b3c12-7af3-44f1-8dba-7e5b75c7a6ea` | Passed or went cold |

---

## Workflow — The Full Pipeline

When commanded to execute outreach (e.g., "Pull 50 C-level contacts, draft personalized emails, send them"):

### Step 0: Pre-Flight — Build Exclusion Database FIRST

**BEFORE selecting ANY target, build a complete exclusion database. This is the #1 QA failure point (burned us Mar 12 and Mar 16). No batch prep without this.**

This is MANDATORY. No exceptions. (Updated by Fede, 2026-03-11. Reinforced Mar 16 after 29/50 QA failure.)

#### 0-PRE. Build Exclusion Database (MUST run before ANYTHING else)

```bash
# 1. Extract ALL emailed last names from Gmail (all outreach subjects)
gog gmail search "from:a@muso.ai subject:Private Invite" --account a@muso.ai --max 500
gog gmail search "from:a@muso.ai subject:already joined" --account a@muso.ai --max 200
gog gmail search "from:a@muso.ai subject:verified music" --account a@muso.ai --max 200
gog gmail search "from:a@muso.ai subject:Quick question" --account a@muso.ai --max 200
gog gmail search "from:a@muso.ai subject:your users" --account a@muso.ai --max 200
# Parse ALL subjects → extract last names → save to set

# 2. Dump ALL GHL opportunity names (paginate ALL pages)
# GET /opportunities/search?pipeline_id=GeSt85TueSvJ0SNFZXfQ&page=1&limit=100
# ...page=2, page=3... until 0 results
# Extract company names + contact names → save to set

# 3. Save combined exclusion DB
# → reference/b2b/exclusion-db.json
```

**The exclusion DB must contain:**
- Every last name from every sent outreach email (currently 181+ names across 260+ emails)
- Every company name and contact name from every GHL opportunity (currently 230+ opps)
- Timestamp of when it was built

**For EVERY candidate in a batch:**
1. Check candidate's LAST NAME against the emailed-lastnames set
2. Check candidate's COMPANY against the GHL company set (exact + fuzzy first-word match)
3. If EITHER matches → SKIP. Do not include. Do not ask "should we try a different person?"
4. Only after passing both checks → proceed to the per-company Gmail search below

**WHY THIS EXISTS:** On Mar 16, searching Gmail by company name missed 11 contacts because outreach emails used "Private Invite - X. LastName" format with NO company name in the subject. Building the full exclusion DB first catches these.

#### 0a. GHL Pipeline Crosscheck

Search the `B2B-Ads-Clio` pipeline (ID: `GeSt85TueSvJ0SNFZXfQ`) for the contact or their company:

```bash
# All GHL requests use: -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28"
# Base: https://services.leadconnectorhq.com | Location: S5w31kRRgsBjjiVATWlP

# Search contacts by email/company
source ~/.zshrc && curl -s "https://services.leadconnectorhq.com/contacts/search" \
  -X POST -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -H "Content-Type: application/json" \
  -d '{"locationId":"S5w31kRRgsBjjiVATWlP","query":"<email_or_company_name>"}' | python3 -m json.tool

# Search opportunities (⚠️ USE GET, not POST — POST caps at 100, cursor broken)
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=S5w31kRRgsBjjiVATWlP" -d "pipeline_id=GeSt85TueSvJ0SNFZXfQ" \
  -d "limit=100" -d "page=1" | python3 -m json.tool
# Paginate: page=2, page=3... until 0 results.
```

**GHL Pipeline Rules:**
- If the contact/company exists in ANY stage of the pipeline → **SKIP.** We are already in contact or in talks.
- This includes: Cold, Emailed, Follow-up, Replied, Meeting Booked, No-Show, Proposal Sent, Closed Won, Closed Lost — ALL stages mean "do not cold outreach."
- If the company exists but the specific contact does NOT → still SKIP unless Nick explicitly approves targeting a different person at that company.
- Only contacts/companies with ZERO presence in the GHL pipeline are eligible for new outreach.

#### 0b. Gmail Prior Contact Check

After passing the GHL check, also verify in Gmail:

```bash
# Check Gmail for any prior outreach to this person/company
gog gmail messages search "to:<email> label:B2B- Ads" --account a@muso.ai
gog gmail messages search "<company_name> label:B2B- Ads" --account a@muso.ai

# ALSO search by company name without label (catches unlabeled threads, replies, forwards)
gog gmail messages search "<company_name>" --account a@muso.ai

# Also check inbox for replies
gog gmail messages search "from:<domain> label:B2B- Ads" --account a@muso.ai
```

**⚠️ Domain Variant Rule (MWTM Lesson, Mar 4 2026):**
Many companies use abbreviated domains for email (e.g., Mix With The Masters → `mwtm.com`, not `mixwiththemasters.com`). **Always search Gmail by company name in addition to the exact contact email.** The MWTM miss happened because we only searched the sheet email domain and missed an active conversation on a different domain.

**Gmail Rules:**
- If we contacted them and they *replied at any point* → DO NOT reach out again. Skip entirely.
- If we contacted them and no reply within *14 days* → eligible for follow-up. Can also try a different person at the same company.
- If contact has `Last Contacted` filled in the sheet → already touched. Check Gmail to determine if follow-up eligible.
- If `Last Contacted` is empty → untouched, go ahead.

**Both checks must pass.** GHL clean + Gmail clean = eligible. Either one flags the contact = skip.

### Single-Contact-Per-Company Rule (MANDATORY — Fede directive, Mar 19 2026)

**NEVER email a 2nd person at the same company until the 1st contact has exhausted ALL follow-ups (FU-01 through FU-04) with no reply.**

Before adding ANY contact to a batch:
1. Check if their company already has an opportunity in GHL at ANY stage
2. If yes, check the follow-up count on the existing contact (Gmail thread)
3. If the existing contact has NOT received FU-02+ with no reply → SKIP the new contact
4. Only if the existing contact has 2+ follow-ups sent AND zero replies → eligible to try a 2nd person

This rule exists because emailing multiple people at the same company simultaneously looks desperate and unprofessional. One contact at a time, exhaust follow-ups, then escalate.

### Gmail Label as Ground Truth (MANDATORY — Mar 19 2026)

The `B2B - Ads` Gmail label is the SINGLE SOURCE OF TRUTH for "did we email them."

When running any outreach audit or building any batch:
1. Search `label:B2B---Ads` (use triple dash for the space-dash-space in label name)
2. This returns ALL emails (sent + received) tagged with B2B - Ads
3. Add `from:a@muso.ai` to filter to sent-only
4. Count UNIQUE THREADS (not individual emails) to get unique contacts
5. Watch for duplicate threads (same person, multiple threads from different dates)
6. Watch for "Muso Access" old-format subjects that don't contain contact names

**NEVER report outreach numbers based on GHL alone or Sheet alone. Gmail label is ground truth, GHL is pipeline stage truth, Sheet is contact detail truth.**

### Company-Level Gmail Verification (MANDATORY — Mar 19 2026 lesson)

**Matching by contact LAST NAME alone is NOT enough.** Different contacts at the same company may have been emailed. You MUST search Gmail by COMPANY NAME for every candidate company.

For every company being considered for outreach:
```bash
gog gmail messages search "<COMPANY_NAME> label:B2B---Ads" --account a@muso.ai --max 10
```

If ANY result comes back, that company has been contacted. Period. Do not include any new contacts from that company in "untouched" lists.

**Why this exists:** On Mar 19, a crosscheck reported 14 "untouched" companies. Gmail company-name search revealed 12 of them had already been contacted via a different person at the same company. Only 2 were truly untouched. The last-name matching approach missed all of these because different contacts at the same company have different last names.

### Step 1: Query Contacts Intelligence

Filter by the requested criteria:
- Seniority Level = target role (C-level, VP, Director, etc.)
- Last Contacted = empty or null (untouched)
- Or: Last Contacted > 14 days ago AND no reply in Gmail (follow-up eligible)

```bash
# Pull the sheet, then filter in Python/locally
gog sheets get 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "contacts_intelligence" --account a@muso.ai
```

### Step 2: Cross-Reference Company Intelligence + Deep Research

For each contact, extract their `Domain` and look up the matching company record:
- Pull company context: name, industry, size, revenue
- Pull `Why Muso Ads Matters` — the value prop tailored to their company type
- If `Why Muso Ads Matters` is missing → ASK Nick/Aaron before drafting

**Deep research (for higher-quality hooks):**
- Check the company's website for recent news, product launches, or events
- Check LinkedIn for recent company posts or announcements
- Look for timely hooks: "I saw you just launched [X]" or "congrats on [Y]"
- This takes more time per email but produces significantly better personalization
- Use web_search + web_fetch to pull recent company news
- Prioritize: new product launches > funding announcements > event participation > hiring signals

### Step 3: Select Email Template

Based on the contact's job title/seniority, choose the right template from the Email Templates tab:
- C-level → CEO peer template (shortest, most direct)
- Marketing/Growth → marketing value template
- Sales/BD → revenue opportunity template
- Ops/Product → efficiency/data template

### Step 4: Draft Personalized Email

Use the `muso-b2b-copywriter` skill framework:
- Prospect name, company name, specific reason Muso Ads matters to THEIR company
- Company-specific hook that wouldn't work for any other company
- Keep tone: conversational, direct, no corporate bullshit. CEO texting a peer.
- Under 60 words for body (tighter than copywriter skill's 80-120)
- Curiosity over discounts
- CTA: book a call via `calendar.muso.ai`

Send as HTML (`--body-html`) — NEVER plain text.

### Step 5: Present for Approval

**⚠️ ALWAYS present emails to Nick/Aaron for approval BEFORE sending.**
Never auto-send. Show the draft batch and wait for explicit "send" or "go" confirmation.

Format for approval:
```
*Outreach Batch — [date]*
[X] contacts, [Y] companies

1️⃣ *[Contact Name]* — [Title] at [Company]
   Email: [email]
   Hook: [the company-specific opening line]
   [Full draft]

2️⃣ ...
```

### Step 6: Create Drafts First (MANDATORY — Fede's rule, Mar 11)

**ALWAYS create emails as Gmail drafts first**, so Nick can review, edit, or delete them before they send. Never send directly without drafts.

Use the Gmail API to create drafts (via access token from gog auth tokens export). Then schedule a cron job to send them at the approved time. Nick reviews in the Drafts folder.

### Step 6b: Send (via cron at scheduled time)

At the scheduled send time, send each email:

```bash
gog gmail messages send \
  --to "<email>" \
  --subject "<subject>" \
  --body-html "<html_body>" \
  --account a@muso.ai \
  --label "B2B- Ads"
```

**POST-SEND LABELING (MANDATORY — added Mar 17 after Fede caught missing labels):**
After every send (whether via `gog gmail messages send` or `gog gmail drafts send`), IMMEDIATELY apply the "B2B - Ads" label to the sent message:
```bash
gog gmail messages modify <messageId> --add "B2B - Ads" --account a@muso.ai
```
Draft sends via `gog gmail drafts send` do NOT auto-inherit the `--label` flag. Always label explicitly after send. No exceptions.

**Email format rules (MANDATORY):**
- ALWAYS use `--body-html` with `<p>` tags
- NEVER use `--body` or `--body-file` (plain text wraps at 78 chars)
- Each paragraph = one `<p>` block with continuous flowing text
- Sign off as Aaron Kaufman, CEO (unless told otherwise)
- **Hyperlink "Muso.AI" ONCE** (first mention only) to `https://muso.ai/` with no underline: `<a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>`. All other mentions stay plain text. The template sheet stores plain text; the link is applied at send time.

### Step 7: Update Contacts Intelligence

After sending, update the `Last Contacted` column for each contact:

```bash
# Update the specific cell with today's date
gog sheets update 1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ \
  --range "contacts_intelligence!<CELL>" \
  --values "[\"$(date +%Y-%m-%d)\"]" \
  --account a@muso.ai
```

### Step 8: Log

Log every outreach action to `api-logs/gmail/YYYY-MM-DD.jsonl`:

```json
{"timestamp": "ISO8601", "action": "outreach_send", "to": "email", "contact": "name", "company": "company", "subject": "subject", "template": "template_used", "requester": "nick/aaron"}
```

### Step 8b: GHL Pipeline Sync (Post-Send)

After sending, create each contact as an opportunity in the `B2B-Ads-Clio` pipeline so GHL becomes the single source of truth for pipeline status.

```bash
# Create contact in GHL
source ~/.zshrc && curl -s "https://services.leadconnectorhq.com/contacts/" \
  -X POST \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -H "Content-Type: application/json" \
  -d '{
    "locationId": "S5w31kRRgsBjjiVATWlP",
    "firstName": "<first_name>",
    "lastName": "<last_name>",
    "email": "<email>",
    "companyName": "<company>",
    "tags": ["B2B-Ads", "Outreach"]
  }' | python3 -m json.tool

# Create opportunity in B2B-Ads-Clio pipeline (stage: Emailed)
source ~/.zshrc && curl -s "https://services.leadconnectorhq.com/opportunities/" \
  -X POST \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -H "Content-Type: application/json" \
  -d '{
    "locationId": "S5w31kRRgsBjjiVATWlP",
    "pipelineId": "GeSt85TueSvJ0SNFZXfQ",
    "name": "<Company Name> | <Contact Name>",
    "contactId": "<contact_id_from_above>",
    "status": "open",
    "pipelineStageId": "19296068-34da-4869-a718-5b5d3ead510c"
  }' | python3 -m json.tool
```

**Rules:**
- Only sync AFTER emails are actually sent (not on draft)
- This closes the loop: next time anyone asks "have we talked to X?" → GHL has the answer

### Step 8c: Slack Notification (MANDATORY — never skip)

After every send batch, post a top-level notification to #sales-alerts (C0ARQ021M40):

```
📧 *Outreach Sent — YYYY-MM-DD* (X emails)

1. *Contact Name* — Title, Company → Emailed ✅
2. ...

Template: [template used]
GHL: X opportunities created in `B2B-Ads-Clio` → Emailed stage
Report: Logged to `muso-b2b-outreach-reports` (YYYY-MM-DD tab)
```

**This is a HARD STEP. Do not skip it. Do not "forget" it. It fires after every send, every reply detection, every stage change. Fede flagged this missing on Mar 11.**

## Follow-Up Workflow

### Follow-Up Cadence (3 touches — Fede's rule, Mar 4 2026)

After initial outreach, follow up on contacts who don't reply:

1. **Touch 1** — 3 days after initial send (short, different angle)
2. **Touch 2** — 7 days after initial send (add new data point or scarcity)
3. **Touch 3** — 40 days after initial send (final attempt, fresh hook)

After 3 touches with no reply → stop. Don't chase further.

**⚠️ NEVER send on Saturday or Sunday.** If a follow-up falls on a weekend, push to Monday.

### Follow-Up Templates (FROM GOOGLE SHEET — USE THESE EXACTLY, DO NOT WRITE CUSTOM COPY)

- **FU-01 "Resurface"**: "Hey {{first_name}}, just floating this back up in case it got buried. Would love to chat about working together when you have a minute.\n\nAaron"
- **FU-02 "Inbox Empathy"**: "Hey {{first_name}}, I know inboxes are brutal. Reaching back out because I genuinely think there's a fit between {{company_name}} and what we're doing at Muso.AI. Happy to share more whenever suits you.\n\nAaron"
- **FU-03 "Soft Nudge"**: "Hey {{first_name}}, following up on my earlier note. No rush on this at all. Just wanted to make sure it landed. Let me know if you'd be open to a conversation.\n\nAaron"
- **FU-04 "The Question"**: "Hey {{first_name}}, I've been looking at what {{company_name}} does and keep thinking there's something we could build together. Am I off base? Would love to hear your take."

Rotate templates across the batch. NEVER write custom follow-up copy. These are tested and approved.

### Follow-Up Process (MANDATORY — updated Mar 17 after Fede caught errors)

1. Pull contacts from GHL Follow-up stage
2. **For EACH contact**: search Gmail by BOTH last name AND company name (early outreach used generic "Muso Access" subjects with no name)
3. Count exact touches per contact from Gmail sent history
4. Only include contacts with <4 total touches AND past the cadence window (3d/7d/40d)
5. Cross-check GHL pipeline stage — if already Replied/Meeting Booked → skip
6. Check Gmail for inbound replies from that contact — if reply exists → skip
7. Use FU-01/02/03/04 templates from sheet (rotate, DO NOT customize)
8. Create draft with `--reply-to-message-id` pointing to the LAST sent message in the thread (verify by reading the actual thread)
9. Subject auto-inherits from reply-to (shows as "Re: original subject")
10. Apply "B2B - Ads" label after draft creation
11. Present for approval before sending — Nick reviews in Gmail
12. Can also try a different person at the same company

### Auto-Follow-Up Flagging (Proactive — Every Monday)

Every Monday, proactively:
1. Scan all contacts due for follow-up (3d, 7d, or 40d since last touch)
2. Cross-check Gmail for replies (if reply exists → skip)
3. Cross-check GHL pipeline stage (if already in Replied/Appointment Booked → skip)
4. Draft a follow-up batch for eligible contacts
5. Post to #sales-alerts for Nick's approval before sending

This runs automatically — Nick doesn't need to ask. The batch is ready for review each Monday morning.

**Follow-ups NOW ACTIVE as of Mar 17, 2026.** Fede requested follow-up drafts for eligible contacts.

### Follow-Up Scarcity Line (proven effective)
The "10 of 12 spots filled, 2 left" line in follow-ups drove replies from Nick Williams (NI) and André Miranda (Musiversal) who hadn't responded to the initial email. Use real scarcity — don't fabricate numbers.

## Reply Monitoring (Daily — Proactive)

Scan `B2B - Ads` labeled inbox daily for new replies:

```bash
gog gmail messages search "label:B2B- Ads is:unread" --account a@muso.ai
```

When a reply comes in:
1. Categorize using the Post-Reply Playbook (which of the 6 types?)
2. Auto-update GHL opportunity stage:
   - Reply received → move to "Replied" stage
   - They share a calendar link or say "let's talk" → move to "Appointment Booked"
   - They pass → move to "Closed Lost"
   - They hand off to colleague → update contact, keep in "Replied"
3. Post to #sales-alerts immediately: who replied, reply type, suggested next move
4. Log to reporting sheet: Reply Received row with notes

**GHL stage progression happens automatically** — keeps the pipeline accurate without manual updates.

## A/B Subject Line Tracking

When testing alternative subject lines (only if Nick requests):
- Track in the reporting sheet: add a "Subject Line" column per contact
- After 2 weeks, compare reply rates by subject variant
- Report: which subject drove more opens/replies
- Default remains "Private Invite - {Initial}. {Last Name}" unless data says otherwise

## Post-Reply Playbook — Handling Responses

Learned from real reply analysis across 80+ outreach emails (documented Mar 4, 2026).

### Core Insight
The email's job is to get a reply, NOT close a deal. 80% of replies ask for more info. They're saying yes to *learning more*.

### Reply Handling by Type

**"Send me more info / deck"** (most common)
→ Send `access.muso.ai/demo` + one confident line. No PDF. No deck. Let the product sell.
→ If they ask about pricing: "Don't worry about pricing — think of it as if you can target whomever you wish."

**"Let's schedule a call"** (immediate yes)
→ Book IMMEDIATELY. Zero additional pitch. Nick handles logistics, Aaron handles the call.

**"Adding [colleague] to this thread"** (warm handoff)
→ This IS the win. Shift focus to the new contact. Don't re-pitch the original.

**"Interesting, tell me more"** (curious explorer)
→ Two-touch: Nick as CMO with logistics + access link. Aaron follows with peer validation.

**"We pass"** (clean rejection)
→ Accept gracefully. Don't chase. Don't "just check in."

**Pivot/counter-proposal** (e.g., wants affiliate instead)
→ Hold position. "We don't do that at this time." Let them come back on your terms.

### The Aaron + Nick Motion (default for all interested replies)

1. **Aaron opens** — CEO peer credibility via Private Invite
2. **Nick closes** — CMO logistics, calendar booking, confirmations, warmth
3. **Aaron re-appears** — for the actual call/meeting

This converted Casio (13 days to product list), MasterChannel (call booked in 24h), and Fanbace. Speed of Nick's logistics is the differentiator.

## Dynamic Name Drops by ICP Category

**Always include Bad Bunny.** Then add 2 names relevant to the prospect's industry.
All names verified on Muso catalog with real credits (as of 2026-03-06).

| ICP Category | Name Drop Line | Why These Names |
|---|---|---|
| Pro Audio/Gear Brands | "from Bad Bunny and Serban Ghenea to Manny Marroquin" | Mixing/mastering engineers the audience worships (Serban: 7,525 credits, Manny: 6,069) |
| Music Software/Plugin Companies | "from Bad Bunny and FINNEAS to Jack Antonoff" | Producer-household names who use the tools (FINNEAS: 9,501 credits, Antonoff: 7,805) |
| Music Education/Online Courses | "from Bad Bunny and Poo Bear to Quincy Jones" | Aspirational range: active hitmaker + living legend |
| Music Services/Platforms | "from Bad Bunny and Max Martin to Pharrell Williams" | Max Martin: 39,644 credits — the GOAT stat for platform buyers |
| Live Sound/Touring/Venues | "from Bad Bunny and Travis Scott to deadmau5" | Touring-heavy artists relatable for live industry |
| Streaming/Content Platforms | "from Bad Bunny and Billie Eilish to Metro Boomin" | Streaming era names, Gen Z appeal |
| Lifestyle/Adjacent Brands | "from Bad Bunny and DJ Snake to Steve Aoki" | Crossover appeal: fashion, lifestyle, brand collabs |
| Music Industry Services | "from Bad Bunny and Rick Rubin to Hans Zimmer" | Breadth flex: pop to film scoring, 10K+ credits each |

### Usage in Templates

Insert into the template line:
"We have nearly 1M active music professionals — {name_drop_line} — using our platform daily to track credits, catalog, and career data."

The `{name_drop_line}` is selected based on the contact's company ICPCategory Label from the Company Intelligence tab. If ICPCategory is missing, default to: "from Bad Bunny and Max Martin to Poo Bear" (universal appeal).

### Claimed Profile Name Drops

When a contact's company has a claimed Muso profile (check Athena `public_claiming` or the company's domain), prioritize mentioning names relevant to that company's specific niche over the generic ICP mapping.

## Tone Reference

- Human, direct, no corporate bullshit
- CEO texting a peer
- Curiosity over discounts
- Never desperate, never pushy
- Short: under 60 words body
- **NEVER use em dashes (—) or en dashes (–) in any email or Slack message.** Use commas, periods, or restructure the sentence. Zero tolerance. This has been flagged repeatedly.

## Opening Framework (MANDATORY — Nick's Cold Email Psychology)

Every cold email opening MUST follow this 3-step sequence before ANY pitch:

1. **Establish identity** — "I'm Aaron, CEO at Muso.AI." Peer dynamic, not salesperson.
2. **Flattery with plausibility** — "Your name came up on our shortlist of companies we'd like to partner with." Selected, not spammed.
3. **Seed curiosity before the pitch** — "Not sure if you've come across Muso.AI before — you've probably seen big artists talking about us." Humble and disarming.

**Then** the role-specific data kicks in.

The old openings jumped straight into "here's what we have" — reading like a data sheet that got sentient. This framework makes it read like a human who did their homework.

See `muso-b2b-copywriter` for the full copywriting framework, banned phrases, required elements, and structure templates.

## Subject Line — C-Suite Default

**"Private Invite - {First Initial}. {Last Name}"** for ALL initial C-suite cold emails — using the RECIPIENT's name.

Example: emailing Toby Velazquez → `Private Invite - T. Velazquez`

Why:
- **Status recognition** — being *invited* (not pitched) signals selection, not spam
- **Personalized peer framing** — their own name initial reads as exclusive, curated for them
- **Zero threat signal** — no product name, no value prop, nothing to reject before opening
- **The test:** if it could appear in a forwarded thread between two executives, it works

C-suite inboxes are flooded with vendors pitching ROI. They delete on instinct. This triggers a different reflex.

## Companion Skill: muso-b2b-copywriter

**These two skills ALWAYS work together.** `muso-outreach-engine` is the primary skill (pipeline, execution, logistics), and `muso-b2b-copywriter` handles email drafting/copy. When either is triggered, load both. Priority: outreach-engine drives the workflow, copywriter supports with email craft.

## Activity Log & Reporting (MANDATORY)

**Every outreach action MUST be documented in the tracker sheet.**
Sheet: `1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0` (`muso-b2b-outreach-reports`)
Account: `a@muso.ai`

**Rules:**
- Each sheet/tab = the date of the activity (format: `YYYY-MM-DD`)
- Log: what was done, who was contacted, what went well, what didn't, outcomes, lessons
- This is Nick's operational record — never skip logging here
- Create a new tab for each day outreach happens

**Sheet Formatting Standards (MANDATORY — learned Mar 4, 2026):**
- Header row: bold text with background color (use Sheets API batchUpdate for formatting)
- NO line breaks inside cells — each row = one clean record
- Tab name = `YYYY-MM-DD` (never "Sheet1")
- Columns: `#` | Date | Contact | Company | Title | Email | Action | Status | Template | Hook/Notes | Email Subject
- Actions: Drafted, Sent, Follow-Up Drafted/Sent, Reply Received, Meeting Booked
- Status: Pending Approval, Approved, Sent, Replied, No Reply, Meeting Booked, Bounced
- Data must be human-readable at a glance — no spilling, no wrapping, no messy dumps
- Use `--values-json` for structured data writes to avoid formatting issues

```bash
# Add a new sheet tab for today
gog sheets add-sheet 1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0 \
  --title "$(date +%Y-%m-%d)" --account a@muso.ai

# Write activity log header
gog sheets update 1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0 \
  --range "$(date +%Y-%m-%d)!A1" \
  --values '[["#","Date","Contact","Company","Title","Email","Action","Status","Template","Hook/Notes","Email Subject"]]' \
  --account a@muso.ai
```

Document what went well, what didn't, template performance, reply rates — this is the source of truth for outreach ops.

## Constraints

- ❌ Never send to contacts already in `Last Contacted` unless explicitly told (follow-up scenario)
- ❌ Never send without approval from Nick or Aaron
- ❌ If `Why Muso Ads Matters` is missing for a company, ask before drafting
- ✅ Always verify email format before sending
- ✅ Always check Gmail for prior outreach before drafting
- ✅ Always log to `api-logs/gmail/` before sending
- ✅ Always update the sheet after sending
- ✅ Always log activity to the Outreach Tracker Sheet (see above)