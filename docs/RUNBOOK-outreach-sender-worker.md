# Runbook: Outreach Sender Worker

**Script:** `/opt/hydra/scripts/muso-outreach-sender-worker.py`
**Source of truth:** `docs/superpowers/specs/2026-04-14-cmo-outreach-sender-worker-design.md`
**On call:** Nick / Aaron

## What it does

Reads outreach drafts from Gmail, validates recipient + reply state,
sends only the valid ones, and appends a logbook row atomically.
CMO agent creates drafts; this worker sends them.

## Triggers

- **Approval batch:** Slack reaction ✅ on the CMO's approval post in
  `#sales-alerts` → Slack event handler invokes the worker with the
  label for that batch.
- **Monday cron:** `0 9 * * 1` UTC — processes drafts under
  `B2B - Ads/auto-fu-approved`.
- **Manual:** SSH to node-8 and run:

      /opt/hydra/scripts/muso-outreach-sender-worker.py \
        --label "B2B - Ads/auto-fu-approved" --account a@muso.ai

## Reading the output

After every run the worker posts a batch summary to `#sales-alerts`:

> ✅ Batch done - sent: 12, blocked: 3, halted: no

For each blocked draft, a separate `#sales-alerts` message names the
draft ID and reason code.

## Block reason codes (email did NOT go out)

| Code | What happened | Fix |
|------|---------------|-----|
| `METADATA_MISSING` | Labels not set; draft was edited in Gmail or created outside the agent | Delete the draft and re-create from the agent |
| `METADATA_LABEL_DISAGREE` | Labels and JSON comment say different things | Re-create from the agent |
| `RECIPIENT_MISMATCH` | Draft `To:` differs from original thread / sheet value | Agent hallucinated; re-create |
| `RECIPIENT_SOURCE_MISSING` | Sheet email blank, or thread has no outgoing muso message | Fix the sheet row, or check the thread |
| `CONTACT_REPLIED` | The contact has already replied | Move GHL opp to Replied manually |
| `HUMAN_TEAMMATE_REPLIED` | Someone on the team replied on the thread after the bot | Bot stands down; if you still want to nudge, do it manually |
| `WEEKEND_BLOCKED` | Saturday or Sunday UTC | Re-trigger on Monday |
| `FOLLOWUP_CAP_REACHED` | Already sent 3 follow-ups to this contact | Move GHL opp to Closed Lost or No Reply |
| `SENDER_NOT_ALLOWED` | Draft is from an account outside the allow-list | Check the account; update config if warming is complete |
| `UNEXPECTED_CC_BCC` | Draft has CC/BCC not in metadata's allowlist | Remove the CC/BCC, or add to metadata and re-approve |
| `SEND_FAILED_RETRIED` | `gog gmail drafts send` failed twice on this draft | Single flake; ignore unless two in a row (then batch halts — see `#clio_devops`) |

## Post-send degradation codes (email DID go out — needs reconciliation)

| Code | What happened | Fix |
|------|---------------|-----|
| `LOGBOOK_APPEND_FAILED` | Email sent but Sheets append raised | **Red alert in `#clio_devops`** — manual reconciliation required (see below) |

> **Note on GHL sync:** every successful send currently posts an info note
> in `#sales-alerts` ("GHL sync deferred - advance opp manually"). This
> is by design until the stage-ID lookup lands; until then, a human must
> advance every sent opportunity in GHL manually. See the TODO in
> `scripts/lib/muso_outreach/worker.py`.

## Red-alert response (LOGBOOK_APPEND_FAILED)

The email was delivered but we have no record. To reconcile:

1. Find the message in Gmail via the `draft_id` or `sent-msg-id` in the alert.
2. Append the missing logbook row manually, using the format from
   `workspaces/cmo/skills/muso-outreach-engine/references/config.md` → "Outreach Log Sheet".
3. Advance the GHL opp manually if needed.
4. File an issue on the Sheets API reliability if this happens twice.

## Halted batch (2 consecutive send failures)

Gmail is likely in an outage. Check
<https://www.google.com/appsstatus/dashboard/> and retry the batch
after the incident clears:

    /opt/hydra/scripts/muso-outreach-sender-worker.py --label ... --account a@muso.ai

The worker is idempotent per-draft; already-sent drafts are skipped.

## Override an A-check block

Only Gate A (recipient match) is overridable. For every other block
code, the worker's decision is final.

Both of these steps are required; neither alone is enough. The JSON
comment is agent-editable so the label is the human-gated half.

1. Edit the draft in Gmail: fix `To:` manually.
2. Apply label `B2B - Ads/override-approved`.
3. In the hidden JSON comment, add `"override_reason": "<text>"`.
4. Re-approve in Slack (react ✅).

The worker will log `override:<reason>` in the notes column.
