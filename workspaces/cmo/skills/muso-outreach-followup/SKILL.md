---
name: muso-outreach-followup
description: |
  Sends B2B Ads follow up emails on cadence. Pulls contacts from the Emailed and
  Follow-up GHL stages, crosschecks for replies, selects and varies the FU template,
  creates thread replies in Gmail, sends on approval, logs, and moves GHL stage.

  Cadence: 7 days, 14 days, 140 days. Stops at 3 follow ups with zero replies.
  Never sends on Saturday or Sunday.

  Use when: "send follow ups", "check who needs a follow up", "monday follow up batch"

  Triggers: "follow up", "followup", "monday batch", "nudge", "resurface"
depends-on:
  - muso-outreach-engine
  - muso-outreach-writer
  - muso-outreach-ghl-sync
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
  status: "not yet live, wire up once GHL + sheet sync green"
---

# Muso Outreach Follow Up

Handles the follow up cadence for B2B Ads outreach.

## Access Control

Write access: Nick (U0AL36NADEY) and Aaron (U7RP6HKUZ) only.

## Shared Config

See `../muso-outreach-engine/references/config.md`.

## Cadence (Nick's Rule)

- **Touch 1 (FU-01)**: 7 days after initial send
- **Touch 2 (FU-02)**: 14 days after initial send
- **Touch 3 (FU-03)**: 140 days after initial send
- Stop after 3 follow ups with zero replies.
- **Never send on Saturday or Sunday.** Push to Monday if it lands on a weekend.

## Workflow

### Step 1: Identify Candidates

Pull contacts from GHL stages `Emailed` and `Follow-up` via the pipeline API:

```bash
curl -s -G "https://services.leadconnectorhq.com/opportunities/search" \
  -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  -d "location_id=S5w31kRRgsBjjiVATWlP" \
  -d "pipeline_id=GeSt85TueSvJ0SNFZXfQ" \
  -d "limit=100" -d "page=1" | python3 -m json.tool
```

For each opportunity in those stages:
1. Read the `sheet_row_id` custom field → look up the contact in NocoDB Contacts
   Intelligence (`m9vsbijhrr9ddeu`), matching its `Row ID` column via the
   `muso-nocodb` skill: `bash scripts/nocodb-api.sh records.ls m9vsbijhrr9ddeu --where "(Row ID,eq,<sheet_row_id>)"`
2. Check days since last touch (from logbook sheet)
3. Count follow ups already sent (from logbook)
4. Filter: past cadence window (7d, 14d, or 140d) AND less than 3 follow ups sent

### Step 2: Reply Crosscheck

For each candidate, confirm there is NO inbound reply. Check Gmail across all 4
Muso accounts:

```bash
for acct in a@muso.ai f@muso.ai ak@muso.ai aaron.k@muso.ai; do
  gog gmail messages search 'label:"B2B - Ads" from:<contact_email>' --account $acct
done
```

If any reply exists:
- Skip the follow up
- Call `muso-outreach-ghl-sync` to move stage to `Replied`
- Log reply to the logbook sheet

### Step 3: Select Template

Pull follow up templates from `email_templates` sheet (`Template Type = Follow-Up`
or specific `FU-01` / `FU-02` / `FU-03` / `FU-04` naming).

- Rotate across the batch
- Vary 1 or 2 words per send (synonym swap) to dodge spam filter repetition
- Never reuse exact wording across consecutive follow ups to the same contact

### Step 4: Draft (Thread Reply)

Call `muso-outreach-writer` with:
- Template type = Follow-Up (specific FU number)
- Sender account (same as original, unless Nick says switch)
- Reference the original thread topic

Create the draft as a thread reply, using `--reply-to-message-id` pointing to
the LAST sent message in the original thread. Verify by reading the thread first.

```bash
gog gmail drafts create \
  --to "<email>" \
  --reply-to-message-id "<last_message_id>" \
  --body-html "<html_body>" \
  --account <muso_email> \
  --label "B2B - Ads"
```

Subject auto inherits as `Re: <original subject>`.

### Step 5: Present for Approval

Post the batch to `#sales-alerts`:

```
*Follow Up Batch, YYYY-MM-DD* ({N} follow ups)

1. *{Contact}*, {Company} → {FU-0X} (original sent {Xd} ago)
   Template: {template name}
   Preview: {first line}

2. ...
```

Wait for explicit approval.

### Step 6: Hand off to Sender Worker

Do NOT call `gog gmail drafts send`. Sending is the worker's job.

When the batch is approved (Nick reacts ✅ on the Slack approval post),
the sender worker runs, reads every draft under label
`B2B - Ads/auto-fu-approved`, applies the precondition gate, and sends
only the valid drafts. The worker owns Gmail send + logbook append +
GHL stage advance as one atomic step.

If a draft is blocked, the worker posts the reason to `#sales-alerts`.
Fix the draft (re-create from this skill if the data changed) and
re-approve. Do NOT attempt to bypass the gate by calling `drafts send`
directly — the gateway allow-list denies it.

See `docs/runbooks/RUNBOOK-outreach-sender-worker.md` for failure-mode details.

## Auto Flagging (Monday Cron, Planned)

**NOT YET LIVE.** Once GHL + sheet sync is fully working, enable this cron:

Every Monday:
1. Scan all contacts due for follow up (7d, 14d, or 140d since last touch)
2. Crosscheck Gmail for replies
3. Crosscheck GHL stage (skip if already Replied or beyond)
4. Draft follow up batch for eligible contacts
5. Post to `#sales-alerts` for Nick's approval

Before enabling, verify:
- [ ] Follow up templates exist in `email_templates` sheet
- [ ] GHL stage IDs are current (fetch fresh)
- [ ] Reply scanner is running
- [ ] Logbook sheet is up to date

## Constraints

- Never send on Saturday or Sunday
- Never send more than 3 follow ups per contact
- Never send if an inbound reply exists
- Never send without Nick/Aaron approval
- Never use em dash in any draft
- Always vary 1 to 2 words per send
- Always reply as a thread (not new subject)
- Always log to logbook
