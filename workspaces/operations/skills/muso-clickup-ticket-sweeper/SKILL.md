---
name: muso-clickup-ticket-sweeper
description: |
  Fast, auditable sweeps of ClickUp support tickets. Use when Nick/ops asks to
  cycle through a bucket of overdue ClickUp tickets, inspect Intercom/admin
  context, solve what is safe, leave ClickUp comments explaining closed vs kept
  open, backfill fields, draft or send customer resolution notes through
  Caroline when explicitly enabled, and report how many remain. Designed for
  subagent assisted read-only investigation with one local write/audit pass.

  Triggers: "check overdue tickets", "cycle through ClickUp tickets",
  "sweep tickets", "check 10 more", "check 20 more", "leave comments on
  ClickUp", "backfill ClickUp fields", "notify the users", "customer
  resolution message", "how many are left to check".
depends-on:
  - muso-clickup
  - muso-intercom
  - muso-ops-admin
  - muso-ops-tracks
  - muso-slack-formatter
---

# Muso ClickUp Ticket Sweeper

Use this for internal support-ticket cleanup where the requester wants a batch
review, not a one-off ticket answer.

The goal is to quickly convert a messy ClickUp bucket into:

- tickets safely resolved;
- tickets kept open with a precise blocker;
- structured fields backfilled for the next pass;
- a concise Slack count of checked / resolved / kept open / left.

## Hard rules

- Customer-facing notification is not automatic. Draft it for resolved tickets;
  send only when the requester explicitly asks for notification and an approved
  Caroline/Intercom send path is available.
- Customer-facing Intercom writes are Aaron-only unless using the approved
  Caroline send path. Use Intercom to read and recover IDs; do not close
  Intercom conversations from this skill.
- All external writes must be logged before execution. Use the helper script for ClickUp comments, fields, and status changes.
- If notifying a customer, log the planned customer message before sending and
  record the send result in the ClickUp comment.
- Do not let subagents write. Subagents only produce investigation packets.
- Close only deterministic cases: readback-fixed, exact safe credit correction, duplicate/stale ticket, source-check answered, or async repair queued with a clear next state.
- Keep open when the request is broad, ambiguous, source-backed metadata from DSPs, missing exact track/profile IDs, ownership mismatch, or needs customer proof.
- Never invent ticket IDs, owners, escalations, or process. A write happened only if the tool returned a concrete success.

## Batch workflow

1. Build the bucket.
   - Pull ClickUp tasks and comments.
   - Filter by the requested concern/tag/status/date. For credit/manual buckets,
     keep the working JSONL in `tmp/`.
   - Count total and unique task IDs before starting.

2. Split read-only investigation.
   - If subagents are available and the batch has more than about 8 tickets,
     spawn 2-5 subagents. Each gets a disjoint ticket slice.
   - Give each subagent the ticket bodies/comments for its slice and ask for a
     JSON investigation packet. They may use read-only Intercom/admin lookups if
     those tools are available to them, but they must never write. If read-only
     tools are unavailable, they should return `parent_readback_needed`.
   - Keep one small slice local so the critical path keeps moving.

3. For each ticket, recover missing IDs.
   - Search Intercom by customer email, then fetch the relevant conversation with
     `display_as=plaintext`.
   - Read ClickUp comments before acting; action-request updates may supersede
     the task description.
   - Use admin reads and OpenClaw read tools to resolve profile, track, album,
     raw credits, analytics sources, and current profile credit state.

4. Decide the action.
   - Use `references/decision-rubric.md` when the answer is not obvious.
   - For any admin write, log first, include `--requester <slack_id>`, execute,
     then read back.
   - Prefer partial safe fixes over all-or-nothing. Leave the ticket open if any
     requested part remains unsupported.

5. Prepare customer notification for resolved tickets.
   - Draft a short personalized reply from the actual evidence: what was fixed,
     what now reads back correctly, and any honest limitation.
   - Send only if the requester asked for customer notification and the ticket
     is fully resolved. Never send "resolved" when the ticket is only partially
     fixed, queued for async repair, or left open.
   - If partially fixed, draft a non-final update: say what was corrected and
     what still needs review or exact information.
   - Subagents may propose the message text, but the parent agent owns the final
     copy, audit, send, and readback of the send result.

6. Write ClickUp documentation in one pass.
   - Prepare a JSON file for `scripts/clickup_batch_update.py`.
   - Each ticket must get a comment explaining why it was closed or kept open.
   - If a customer was notified, include the Caroline/Intercom send evidence.
     If not notified, say why: draft-only, left open, no safe send path, or no
     requester instruction to notify.
   - Backfill `User Email`, `Profile ID`, `Muso URL`, `Intercom Link`, and the
     `Comments` custom field when known.
   - Resolve only tickets whose current state is actually complete.

7. Report in Slack.
   - State how many were checked, how many were resolved, how many were kept
     open, how many customers were notified or drafted-only, and how many are
     left in the bucket.
   - Mention only high-signal blockers or unusual tool failures.
   - Use Slack mrkdwn: no tables, no markdown headings, links as `<url|label>`.

## Subagent packet format

Ask subagents to return one JSON object per ticket:

```json
{
  "ticket_id": "869...",
  "recommended_status": "resolved|open",
  "safe_action": "none|admin_write_needed|already_fixed|needs_human_review|parent_readback_needed",
  "evidence": [
    "Intercom 215... says ...",
    "Admin readback: profile ... has ..."
  ],
  "fields": {
    "email": "customer@example.com",
    "profile": "uuid-or-null",
    "muso": "https://credits.muso.ai/...",
    "intercom": "https://app.intercom.com/..."
  },
  "customer_message": {
    "mode": "none|draft|send",
    "text": "Hi ...",
    "reason": "fully resolved|left open|no safe send path|needs requester instruction"
  },
  "clickup_comment": "Ops scan YYYY-MM-DD: ..."
}
```

The parent agent owns final decisions, writes, and Slack reporting.

## ClickUp update helper

Create an input file like:

```json
{
  "requester": "U0AL36NADEY",
  "action": "ticket_sweep_credit_manual_bucket",
  "tickets": [
    {
      "id": "869dp9nta",
      "status": "resolved",
      "comment": "Ops scan 2026-07-14: ...",
      "customer_message": {
        "mode": "draft",
        "text": "Hi ...",
        "reason": "fully resolved; draft for Caroline send"
      },
      "fields": {
        "comments": "Ops scan 2026-07-14: ...",
        "email": "customer@example.com",
        "profile": "df1bd16e-1591-40ad-a11c-99c0f10c7073",
        "muso": "https://credits.muso.ai/profile/...",
        "intercom": "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/..."
      }
    }
  ]
}
```

Run:

```bash
python3 /opt/hydra/workspaces/operations/skills/muso-clickup-ticket-sweeper/scripts/clickup_batch_update.py \
  --input /path/to/update.json
```

The helper writes pre- and post-results to `api-logs/clickup/YYYY-MM-DD.jsonl`
and exits non-zero if any ClickUp write fails.

## Useful paths and APIs

- ClickUp env: `CLICKUP_API_KEY` or `MUSOAI_CLICKUP_API_KEY`.
- ClickUp task comment: `POST /api/v2/task/{task_id}/comment`.
- ClickUp task status: `PUT /api/v2/task/{task_id}` with `{"status":"resolved"}`.
- ClickUp field update: `POST /api/v2/task/{task_id}/field/{field_id}`.
- Admin wrapper: `skills/muso-ops-admin/scripts/muso-admin-api.sh --requester <id> call ...`.
- Intercom conversation: `GET /conversations/{id}?display_as=plaintext`.
