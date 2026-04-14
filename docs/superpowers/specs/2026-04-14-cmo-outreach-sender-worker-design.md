# CMO Outreach Sender Worker — Design

**Date:** 2026-04-14
**Author:** Nick (via CMO incident response)
**Status:** Draft — pending implementation plan

## Context

On 2026-04-14, 12 of 17 follow-up emails sent by the CMO agent were delivered to wrong recipients. The worst case: Ole Wichmann's follow-up went to `ow@lfrequencies.com` (a nonexistent domain) instead of `ow@larsenstrings.com`. Several others were sent to invented or mismatched domains (`@bfrnd.com`, `@songtradr.com`, `@musicbed.com` substituted for the real corporate addresses).

Root cause analysis (see `/root/.openclaw-main/agents/cmo/sessions/99105e17-*.jsonl`):

1. **Layer 1 — Hallucinated `--to` at draft creation.** The `muso-outreach-followup` skill instructs the agent to create drafts via `gog gmail drafts create --to "<email>" --reply-to-message-id "<id>"`. The skill does not require reading the original thread's `To:` header; it tells the agent to look up the recipient in the `contacts_intelligence` sheet. The sheet data was correct, but the LLM substituted plausible-looking alternative emails (compressed local-parts, invented domains) when emitting the Bash command. Gmail baked the wrong `To:` into each draft.
2. **Layer 2 — No logging.** The 17 sends on 2026-04-14 appear in zero log surfaces: no logbook sheet row, no api-log, no send ledger. `gog gmail drafts send <id>` was called as a bare command, bypassing the log-and-GHL-sync step of the skill.

Prose-only skill instructions proved insufficient. Any fix must be enforced in code.

## Goals

- Make it **impossible** for the CMO agent to deliver an outreach email with a hallucinated recipient.
- Make it **impossible** for an outreach send to happen without a ledger row.
- Preserve Fede/Aaron's existing approval gate (drafts visible in Gmail before send).
- Catch the same class of error in new outreach, not just follow-ups.
- Stand the bot down when a human teammate has already replied on a thread.

## Non-Goals

- Rewriting the drafting workflow itself (the agent still writes copy and creates drafts).
- Changing the Slack approval UX beyond what's required for the gate.
- Solving email validation for net-new contacts before they enter the sheet (separate concern — `muso-outreach-email-validator`).

## Design

### Architecture shift: drafts as outbox

Today, the agent is responsible for **drafting, approving, sending, and logging**. Sending is the dangerous step, and the agent's LLM-nature makes it the step most likely to hallucinate.

New split of responsibilities:

| Role | Who | What |
|---|---|---|
| Drafter | CMO agent (unchanged) | Creates Gmail drafts with labels + embedded metadata. Never sends. |
| Approver | Fede / Aaron | Reviews drafts in Gmail; approves batches via Slack reaction. |
| Sender | New worker script | Validates preconditions, calls `drafts send`, logs, syncs GHL. The **only** code path that can send an outreach email. |

The CMO agent's tool allow-list is updated to **remove `gog gmail drafts send`** and any equivalent send capability. The agent cannot call the send API directly. Only the sender worker can.

### Components

#### 1. Draft metadata convention

Every draft created by CMO for outreach MUST include a hidden HTML comment at the bottom of the body:

```html
<!-- muso-outreach:v1 kind=followup|new sheet_row_id=1234 opp_id=abc template=FU-01 sender=a@muso.ai original_thread_id=1812f... -->
```

- `kind` — `followup` or `new`. Determines which validation rule applies.
- `sheet_row_id` — row ID in `contacts_intelligence`. Authoritative for `new` sends.
- `opp_id` — GHL opportunity ID. Used for GHL stage sync after send.
- `template` — template key (e.g., `FU-01`, `Private Invite`). Logged.
- `sender` — the muso.ai account that will send (and must match the draft's account).
- `original_thread_id` — for `kind=followup`, the Gmail thread whose `To:` we must match. Omitted for `kind=new`.

The `muso-outreach-writer` and `muso-outreach-followup` skills are updated to always emit this comment as part of the draft body.

#### 2. Sender worker (`muso-outreach-sender-worker`)

A Python script at `/opt/hydra/scripts/muso-outreach-sender-worker.py`, run in two ways:

- **Interactive** (batch approval): triggered by a Slack reaction. Fede reacts ✅ on an "approval post" for a batch → a Slack event handler invokes the worker with that batch ID → worker processes every draft in the batch.
- **Scheduled** (Monday follow-up cron): runs at `*/5 9-11 * * 1` UTC and processes all drafts labeled `B2B - Ads/auto-fu-approved`.

For each draft:

1. **Parse metadata** from the hidden HTML comment. Reject the draft and post to `#sales-alerts` if the comment is missing or malformed.
2. **Validate sender account** — draft.account must equal `sender` in metadata.
3. **Run precondition gate** (see next section). On any failure: skip, do not send, post reason to `#sales-alerts`, advance to next draft.
4. **Send** via `gog gmail drafts send <draftId> --account <sender>`.
5. **Re-apply label** (Gmail strips the label on draft send).
6. **Append logbook row** in the same execution. Columns: timestamp, sender, draft_id, message_id, thread_id, recipient, sheet_row_id, opp_id, template, kind, status.
7. **Sync GHL**: advance the opportunity stage via `muso-outreach-ghl-sync`. If this fails, the send still counts but a warning is posted (send is irreversible; the sync is not).
8. **Post summary** to `#sales-alerts` after the batch: `X sent, Y blocked, blocked reasons: [...]`.

The worker is idempotent per draft: if a draft has already been sent (identified by Gmail's `SENT` label on the resulting message), it is skipped with no further action.

#### 3. Precondition gate

All checks must pass, else the send is blocked.

**A. Recipient match (kind-dependent)**

- `kind=new`: the draft's `To:` MUST exactly match `contacts_intelligence[sheet_row_id].valid_professional_email` (case-insensitive). If the sheet value is blank, empty, or has changed since drafting, block with reason.
- `kind=followup`: the draft's `To:` MUST exactly match the `To:` of the first message in `original_thread_id`. If the thread does not exist, has no outgoing message, or the `To:` mismatches, block with reason.

**B. No contact reply**

Search Gmail across all four muso accounts for any message in `original_thread_id` (or for `kind=new`, any message from the target email in the last 60 days) where the sender is **not** a `@muso.ai` address. If found, block with reason "contact already replied — move to Replied stage manually."

**C. No human-from-muso reply (the new rule)**

For `kind=followup`: walk `original_thread_id`; if there is any message after the last bot-sent message whose sender is a `@muso.ai` address OTHER than the bot sender (`a@muso.ai`, etc. — configurable), block with reason "human teammate already replied on this thread."

**D. Not weekend**

If UTC day-of-week is Saturday or Sunday, block with reason "weekend send blocked per outreach policy." Applies to both kinds.

**E. Follow-up cap**

For `kind=followup`: count existing follow-up rows in the logbook for this `sheet_row_id`. If already at 3, block with reason "follow-up cap reached."

**F. Sender domain sanity**

Draft's `From:` must be in the muso.ai outreach account allow-list (configurable). Blocks accidental sends from unexpected accounts.

#### 4. Agent tool restrictions

Update the CMO agent's gateway configuration (`/root/.openclaw-main/openclaw.json`, `agents[cmo].toolAllowlist` or equivalent):

- **Remove / deny**: `gog gmail drafts send` (any variant)
- **Remove / deny**: `gog gmail messages send` (prevents bare-send bypass)
- **Keep**: `gog gmail drafts create`, `gog gmail drafts list`, `gog gmail messages get`, `gog gmail threads get`

The agent can still draft, inspect, and thread; it can no longer deliver.

The skill prose (`muso-outreach-followup/SKILL.md`, `muso-outreach-sender/SKILL.md`, `muso-outreach-writer/SKILL.md`) is updated to reflect: drafts are the agent's output; sends are the worker's job. Step 6 "Send" is removed from the agent's responsibility and relocated to the worker's runbook.

#### 5. Override escape hatch

When the gate legitimately blocks a send that a human wants to push through (edge case: contact emailed from a different address asking the reply go to a colleague), a human can:

1. Manually edit the draft in Gmail (correct `To:`).
2. Add the label `B2B - Ads/override-approved`.
3. Write the override reason into the hidden metadata comment (`override_reason=<text>`).
4. Re-react ✅ on the Slack approval post.

The worker, on seeing `override-approved` + non-empty `override_reason`, SKIPS check A (recipient match) but runs all other checks, sends, logs the override reason, and posts a highlighted notice to `#sales-alerts`:

> ⚠️ **Override send** — `{draft_id}` to `{recipient}`. Reason: `{override_reason}`. Sent by override-approved flag.

No other check can be overridden this way (no overriding "contact replied" or "human replied" — those are absolute).

### Data flow

```
Agent (CMO session)
  ├─ muso-outreach-writer: generate copy
  ├─ gog gmail drafts create --to <x> --reply-to-message-id <y> (with metadata comment)
  └─ Post batch summary to #sales-alerts

Human (Fede / Aaron)
  ├─ Review drafts in Gmail
  ├─ ✅ reaction on #sales-alerts approval post
  └─ (Alternative) Manual edit + override-approved label for edge cases

Worker (muso-outreach-sender-worker.py)
  ├─ For each draft in batch:
  │    ├─ Parse metadata
  │    ├─ Run precondition gate (A-F)
  │    ├─ On pass: drafts send → reapply label → logbook append → GHL sync
  │    └─ On fail: post reason to #sales-alerts
  └─ Post batch summary
```

### Error handling

- **Metadata missing or malformed**: draft is skipped; `#sales-alerts` gets a notice with draft ID so a human can fix and re-approve.
- **gate failure**: post-per-draft reason, continue to next draft.
- **`gog gmail drafts send` failure**: retry once with 5s backoff; on second failure, post to `#sales-alerts` and stop the batch (something systemic is broken).
- **Logbook append failure after successful send**: post a red-alert to `#clio_devops` — the email went out but we have no record. Requires manual reconciliation; document this in RUNBOOK.
- **GHL sync failure after successful send and log**: warn in `#sales-alerts`, include opp_id for manual follow-up. Do not retry automatically (could double-move the opportunity).

### Testing

- **Unit tests** (`tests/test_sender_worker.py`): precondition gate logic — mock Gmail API responses for each check, assert block/pass for each of A-F. Include the hallucination case: draft.to=`ow@lfrequencies.com`, thread.to=`ow@larsenstrings.com` → must block.
- **Integration test** against a staging Gmail account (separate from muso.ai): create a real draft with known metadata, run the worker, assert it sent or blocked as expected.
- **Agent-cannot-send test**: simulate a CMO session attempting `gog gmail drafts send` under the new tool allow-list; assert tool-use is denied at the gateway level.
- **Override test**: draft with `override-approved` label and `override_reason` set, mismatched `To:` — assert send succeeds, warning posted.

### Rollout

1. **Phase 0 — freeze** (immediate, already partly in effect per CMO's Slack message): CMO is not sending any new follow-ups until the worker ships.
2. **Phase 1 — metadata + worker MVP**: land draft metadata comment in writer/followup skills. Ship the worker. Ship the precondition gate for checks A, B, D, E, F. (C — human-reply detection — can land in Phase 2 if timeline pressure.)
3. **Phase 2 — gate at gateway**: remove `gog gmail drafts send` from CMO's tool allow-list. Add check C.
4. **Phase 3 — cron enable**: turn on the scheduled Monday batch run. Add dashboards for block-reason trends.

### Observability

- Every worker run posts to `#sales-alerts` with counts + block reasons.
- Every block is logged to `/var/log/muso-outreach-sender-worker.log` with structured JSON (reason code, draft_id, sheet_row_id, recipient_sent_would_have_been, recipient_expected).
- A daily digest in `#clio_devops` at 08:00 UTC summarizes prior-day blocks and any red-alerts.

### Open questions (to resolve during implementation)

- Exact Slack event-handler hookup (new Slack app or extend existing devops bot?).
- Whether to store the ledger in Google Sheets (current logbook) or a real database (longer-term durability). MVP: sheets — migrate if/when volume justifies.
- Whether to bulk-reconcile the 17 bad sends from 2026-04-14 (manual one-off — out of scope for this design).

## Summary

Stop the agent from pressing the send button. Have humans approve drafts, and have deterministic code validate and send them. Record every send by construction. The CMO agent's role shrinks to what LLMs are good at (generating copy, drafting) and moves away from what they're bad at (accurately reproducing strings under hallucination pressure).
