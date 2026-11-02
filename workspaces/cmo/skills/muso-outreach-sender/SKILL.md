---
name: muso-outreach-sender
description: |
  Sends B2B Ads outreach batches. Pulls target contacts, runs the 4 source
  exclusion crosscheck, calls muso-outreach-writer for copy, presents batch for
  approval, creates Gmail drafts, sends on go, labels, logs to sheet, syncs GHL,
  and posts the Slack notification.

  Called by muso-outreach-engine. Primary send pipeline for initial (non follow up)
  outreach.

  Use when: "send outreach", "send cold emails", "pull leads and draft", "execute batch"

  Triggers: "send outreach", "send batch", "draft batch", "execute outreach",
  "cold send", "send emails to contacts"
depends-on:
  - muso-outreach-engine
  - muso-outreach-writer
  - muso-outreach-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Outreach Sender

Sends initial B2B Ads outreach batches end to end.

## Access Control

Write access: Nick (U0AL36NADEY), Aaron (U7RP6HKUZ) and, for B2B outreach, McLaren (U02S7C96CGN) only.

## Shared Config

All IDs, accounts, sheets, channels, and rules are in
`../muso-outreach-engine/references/config.md`.

## Workflow

### Step 0: Pre-Flight Crosscheck

Build the exclusion set from the 4 primary sources. NEVER skip this.

1. **Sheet logbook** (`muso-b2b-outreach-reports`): every row = touched.
2. **NocoDB Contacts Intelligence** (`m9vsbijhrr9ddeu`): every row with a
   non empty `Status` = touched.
3. **GHL pipeline** (paginate ALL pages with `page=N`, not POST search):
   extract every company + contact name across ALL stages (including Closed Lost).
4. **Gmail B2B - Ads label** across all 4 accounts: extract recipients + last names.

```bash
for acct in a@muso.ai f@muso.ai ak@muso.ai aaron.k@muso.ai; do
  gog gmail messages search 'label:"B2B - Ads"' --account $acct --max 1000
done
```

Any candidate matching ANY of these is SKIPPED.

### Step 1: Pick Targets

From NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`), via the `muso-nocodb`
skill (REST API, no MCP — see `config.md`), filter:
- `Status` empty (untouched)
- `Rank` / `Job Category` matching the ask
- Company exists in NocoDB Company Intelligence (`mvr6nmzcv7albxt`) with complete
  `Why Muso Ads Matters`

```bash
bash scripts/nocodb-api.sh records.ls m9vsbijhrr9ddeu \
  --where "(Status,blank)" \
  --fields "Id,Domain,Company Name,First Name,Last Name,Title,Job Category,Rank,Valid Professional Email"
```

Apply the exclusion set. Drop matches.

### Step 2: Parent Company Logic

See `../muso-outreach-engine/references/parent-companies.md`. Target parents only.
Collapse subsidiaries to their parent. Flag unknown parents for rollup.

### Step 3: Single Contact Per Company

If the company already has an active contact (any stage ≠ Closed Lost, and the
contact did not bounce), SKIP adding a 2nd person.

Exceptions allowed:
- Original email bounced or delivery failed
- Original contact received all 4 follow ups (FU-01 to FU-04) with zero replies

### Step 4: Research & Personalize

For each finalist:
- Pull the NocoDB Company Intelligence (`mvr6nmzcv7albxt`) row by `Domain`
- Pull `Why Muso Ads Matters` (if missing, ASK Nick or Aaron)
- Deep research: website, LinkedIn, recent news (use `web_search` + `web_fetch`)
- Select ICP name drops from `references/icp-name-drops.md`

### Step 5: Draft Email (call muso-outreach-writer)

Pass to `muso-outreach-writer`:
- Contact row, company row
- Template type (Initial)
- Sender account (default `a@muso.ai`, Aaron voice)
- Deep research hook

Receive back: `subject`, `body_html`, `template_id`, `checklist_passed`.

### Step 6: Present for Approval

Post the batch to `#sales-alerts` (`C0ARQ021M40`) using `muso-slack-formatter`.

```
*Outreach Batch, YYYY-MM-DD* ({N} emails, from {muso_email})

1. *{Contact Name}*, {Title}, {Company}
   Email: {email}
   Template: {template name}
   Hook: {the company specific opening line}

   {full draft}

2. ...
```

Wait for explicit approval (`send`, `go`, `approved`) from Nick, Aaron or McLaren (U02S7C96CGN). Never auto send.

### Step 7: Create Gmail Drafts

```bash
gog gmail drafts create \
  --to "<email>" \
  --subject "<subject>" \
  --body-html "<html_body>" \
  --account <muso_email> \
  --label "B2B - Ads"
```

Nick or McLaren reviews drafts in Gmail before final go.

### Step 8: Hand off to Sender Worker

Do NOT call `gog gmail drafts send`. Sending is the worker's job.

Once Nick / Aaron / McLaren approves the batch, the sender worker (running via
Slack event handler) reads every draft under label `B2B - Ads` with
`muso-meta/kind-new` applied, runs the precondition gate, and sends
only the valid drafts. The worker owns Gmail send + logbook append +
GHL `Emailed` stage set + Slack notification as one atomic step.

Blocked drafts appear in `#sales-alerts` with a machine-readable
reason code. Fix and re-approve; do NOT bypass.


See `docs/runbooks/RUNBOOK-outreach-sender-worker.md` for ops details.

## Constraints

- Never send without explicit approval
- Never send on Saturday or Sunday
- Never skip the 4 source crosscheck
- Never hardcode copy (pull from email_templates)
- Always apply `B2B - Ads` label after send
- Always log to the logbook sheet AND api-logs
- Always sync to GHL after send
- Always post the Slack notification
- Never post to `#clio_x_fede` (legacy, deprecated for sales)
