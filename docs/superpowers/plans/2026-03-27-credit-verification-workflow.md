# Credit Verification Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the ops agent to autonomously investigate and act on flagged credit requests posted to `#credit-verification` by core-backend.

**Architecture:** New skill (`muso-ops-credit-verification`) defines the autonomous workflow. SOUL.md binds the channel with a hard trigger rule. The admin skill's write approval gate gets a narrow exception for credit approve/reject from this channel.

**Tech Stack:** Markdown skill files (SKILL.md, SOUL.md, TOOLS.md) — no code changes, pure agent configuration.

**Spec:** `docs/superpowers/specs/2026-03-27-credit-verification-workflow-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `workspaces/operations/skills/muso-ops-credit-verification/SKILL.md` | Create | Full autonomous credit verification workflow |
| `workspaces/operations/SOUL.md` | Modify | Channel binding + trigger rule + Jan as escalation approver |
| `workspaces/operations/TOOLS.md` | Modify | Add channel to bound list |
| `workspaces/operations/skills/muso-ops-admin/SKILL.md` | Modify | Approval gate exception for credit verification |

---

### Task 1: Create the credit verification skill

**Files:**
- Create: `workspaces/operations/skills/muso-ops-credit-verification/SKILL.md`

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p workspaces/operations/skills/muso-ops-credit-verification
```

- [ ] **Step 2: Write the SKILL.md file**

Create `workspaces/operations/skills/muso-ops-credit-verification/SKILL.md` with this content:

```markdown
---
name: muso-ops-credit-verification
description: |
  Autonomous credit verification workflow. Triggered when the ops agent is
  @mentioned in #credit-verification (C0APB2CMM7C). Parses the flagged credit
  request, investigates legitimacy, classifies verdict, and auto-approves,
  auto-rejects, or escalates to Aaron/Jan.

  Use when: @mentioned in #credit-verification channel with a credit verification
  request from core-backend.

  Triggers: messages in #credit-verification (C0APB2CMM7C) that @mention this agent
depends-on:
  - muso-ops-credits
  - muso-ops-fraud
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
compatibility: |
  Requires: muso-ops-admin (API gateway), muso-ops-fraud (web research),
  muso-ops-credits (Athena cross-reference), muso-ops-audit (logging).
  Cross-repo dependency: core-backend PR #8465 must set rich text fallback
  in postCreditVerification() for the agent to parse the message content.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Credit Verification (Autonomous)

Pre-approval review of flagged credit requests. Core-backend posts a Block Kit
message to #credit-verification when a credit request's risk score >= 85%.
This skill defines how to handle those messages autonomously.

## HARD RULE

**Every @mention in #credit-verification triggers this workflow. No exceptions.
No conversational responses. No clarifying questions. Parse, investigate, act.**

## Workflow

### Step 1: Parse the Incoming Message

Extract these fields from the message text:

| Field | Required | Example |
|-------|----------|---------|
| Credit request ID | Yes | `cr_abc123` |
| Profile ID | Yes | `prof_xyz789` |
| Profile name | Yes | `John Smith` |
| Workspace ID | Yes | `ws_456` |
| Owner email | Yes | `owner@example.com` |
| Track title | Yes | `"Midnight Rain"` |
| Artists | Yes | `Taylor Swift` |
| Spotify link | No | `https://open.spotify.com/track/...` |
| Claimed roles | Yes | `Producer, Songwriter` |
| Overall risk score | Yes | `87%` |
| Per-dimension scores | Yes | `artist_risk: 92%, track_risk: 75%, role_risk: 88%` |
| Pending verification count | No | `3 other pending` |

**If any required field cannot be parsed**, post an error in-thread:

```
⚠️ PARSE ERROR — Could not extract required fields from this message.

Missing: [list of missing fields]

Skipping verification. Please check the message format.
```

Do NOT attempt to investigate or act on incomplete data.

### Step 2: Idempotency Check

Before investigating, query the credit request status:

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/credit-requests/<credit_request_id>"
```

If the status is NOT `user_verification_needed` (e.g., already `approved` or `rejected`),
post a short note in-thread and stop:

```
ℹ️ Already processed — status: [current_status]. Skipping.
```

### Step 3: Investigate

Use existing skill workflows:

**3a. Athena cross-reference** (from `muso-ops-credits`):
```sql
SELECT t._id, t.title, t.popularity, t.default_release_label
FROM "platform-industry-bi-prod".matvw_catalog_track t
WHERE t._id = '<track_id>'
  AND t.is_deleted = false
```

Does this person appear in industry data for this track?
Is the role plausible given the track's genre/era/label?

**3b. Web research** (from `muso-ops-fraud`):
- AllMusic: `allmusic.com/search/all/[name]`
- Discogs: `discogs.com/search/?q=[name]&type=artist`
- DuckDuckGo: `"[name]"+[role]+engineer|producer|mixing`
- LinkedIn: music industry career history
- Professional website (check email domain)

**3c. Fraud signal check**:
- Bulk credit submissions (>20 in one day)?
- Disposable email?
- Genre mismatch across submitted credits?
- Credits to high-popularity tracks by unknown profile?
- Credit additions right after profile claiming?

### Step 4: Classify

Map investigation results to a verdict using `muso-ops-fraud` criteria:

| Verdict | Criteria | Action |
|---------|----------|--------|
| **VERIFIED LEGIT** | Confirmed via web (AllMusic/Discogs credits, LinkedIn career, studio site) | Auto-approve |
| **UNVERIFIABLE — LOW CONCERN** | No web presence but consistent pattern (single technical role, professional email, low fraud signals) | Auto-approve |
| **SUSPICIOUS** | Active red flags (identity mismatch, web contradicts claims, bulk self-additions, disposable email) | Auto-reject |
| **UNVERIFIABLE — NEEDS REVIEW** | No web presence AND risk signals (pop >=90, creative roles, many credits, mononym) | Escalate |

### Step 5: Act

#### Safety Rails — Check BEFORE Acting

- **Daily cap**: If you have already made 50 autonomous approve/reject actions today,
  escalate this request instead of auto-acting. Post:
  ```
  ⚠️ Daily autonomous action limit reached (50/day). Escalating for human review.
  ```

#### Auto-Approve (VERIFIED LEGIT or LOW CONCERN)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester clio call PUT "/w/admin/credit-requests/<id>" '{"status":"approved"}'
```

Log via `muso-ops-audit` before execution.

#### Auto-Reject (SUSPICIOUS)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester clio call PUT "/w/admin/credit-requests/<id>" \
  '{"status":"rejected","reason":"Flagged as suspicious during pre-approval verification: [specific reason]"}'
```

Use a specific reason based on findings. Examples:
- "Flagged as suspicious: no web presence, disposable email, 15 bulk submissions in 24h"
- "Flagged as suspicious: identity mismatch — web sources contradict claimed credits"
- "Flagged as suspicious: bulk self-additions across unrelated genres"

Log via `muso-ops-audit` before execution.

#### Escalate (NEEDS REVIEW)

Do NOT call the admin API. Post in-thread tagging both approvers:

```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences summarizing investigation findings]

Risk score: [X]% | Verdict: Unverifiable — Needs Review
<@U7RP6HKUZ> <@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.
```

**Accepted response formats**: "approve", "approved", "reject [reason]", "rejected [reason]".
Other messages are acknowledged but not treated as decisions.

**First valid response wins.** Act on it immediately using the responder's Slack ID as `--requester`.
If a conflicting response arrives after, acknowledge it:
```
Already acted on — [action] was taken based on [name]'s response.
```

**Timeout**: If no valid response within 30 minutes, post a reminder:
```
⏰ Reminder: credit request [ID] still needs review. Reply "approve" or "reject [reason]".
```
No auto-action on timeout. The credit stays in `user_verification_needed` until a human decides.

#### API Failure

If the admin API call to approve/reject fails, post error in-thread:
```
⚠️ API ERROR — Failed to [approve/reject] credit request [ID].

Error: [error details]

Manual action required.
```

Do NOT retry automatically.

### Step 6: Report

Post investigation summary in-thread on the original message.

**Auto-approve format:**
```
✅ APPROVED — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences]

Risk score: [X]% | Verdict: [Verdict]
Credit request [ID] approved.
```

**Auto-reject format:**
```
🔴 REJECTED — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences]

Risk score: [X]% | Verdict: [Verdict]
Credit request [ID] rejected. Reason: [reason]
```

## Relationship to Daily Credit Fraud Scan

This workflow and the daily heartbeat scan serve different purposes:

- **This workflow**: Pre-approval review of flagged credits (risk >= 85%)
- **Daily scan**: Post-approval review of approved credits on high-popularity tracks (Spotify pop >= 50)

They review different populations. Both should continue running.
```

- [ ] **Step 3: Commit**

```bash
git add workspaces/operations/skills/muso-ops-credit-verification/SKILL.md
git commit -m "feat(ops): add autonomous credit verification skill"
```

---

### Task 2: Add channel binding and trigger rule to SOUL.md

**Files:**
- Modify: `workspaces/operations/SOUL.md:30-35` (channel binding section)
- Modify: `workspaces/operations/SOUL.md:217-228` (operations channel rule + write approval)

- [ ] **Step 1: Add channel to Channel Binding section**

In `workspaces/operations/SOUL.md`, find the Channel Binding section (around line 30):

```markdown
## Channel Binding

- **#operations** -- operational discussions and process management
- **#customer-support** -- customer support triage and resolution
```

Add below `#customer-support`:

```markdown
- **#credit-verification** (C0APB2CMM7C) -- autonomous credit verification (see below)
```

- [ ] **Step 2: Add credit verification channel rule**

Insert between the Operations Channel Rule (line 219) and Write Operations section (line 221). The new section goes right after the `#operations` refund rule:

```markdown
## Credit Verification Channel Rule (#credit-verification / C0APB2CMM7C)
Every @mention in #credit-verification triggers the muso-ops-credit-verification skill.
No exceptions. No conversational responses. No clarifying questions.
Parse the message, investigate, classify, act, report. Every time.
This channel receives automated messages from core-backend when a credit request
is flagged with risk score >= 85%. The agent is @mentioned in each message.
```

- [ ] **Step 3: Add credit verification exception to Write Operations section**

Find this exact block in SOUL.md (lines 221-228):

```markdown
## Write Operations — Approval Required
ALL admin API writes from anyone except Aaron (U7RP6HKUZ) must be QUEUED for Aaron review:
1. Acknowledge the request
2. Prepare the action details
3. Post to Aaron (DM or thread) for approval
4. Only execute after Aaron explicitly approves
This applies to: credit changes, merges, claims, user modifications, workspace changes.
Read operations remain open to all authorized ops team members.
```

Append immediately after "Read operations remain open to all authorized ops team members." (do NOT replace the existing content — add below it):

```markdown

### Exception: Credit Verification Channel (C0APB2CMM7C)
Credit request approve/reject operations triggered by the muso-ops-credit-verification
skill in #credit-verification are autonomous — no human approval needed for clear verdicts
(VERIFIED LEGIT, SUSPICIOUS, UNVERIFIABLE — LOW CONCERN). UNVERIFIABLE — NEEDS REVIEW
verdicts are escalated to Aaron (<@U7RP6HKUZ>) or Jan Delmo (<@U038BM16T7W>) in-thread.
Either can approve. See muso-ops-credit-verification skill for full workflow.
```

- [ ] **Step 4: Verify the changes read correctly**

Read back the modified sections of SOUL.md to confirm they're consistent and don't contradict other rules.

- [ ] **Step 5: Commit**

```bash
git add workspaces/operations/SOUL.md
git commit -m "feat(ops): bind #credit-verification channel with autonomous trigger rule"
```

---

### Task 3: Add channel to TOOLS.md bound list

**Files:**
- Modify: `workspaces/operations/TOOLS.md:26-29` (Slack section)

- [ ] **Step 1: Update Slack bound channels**

In `workspaces/operations/TOOLS.md`, find the Slack section (lines 26-29):

```markdown
## Slack
- Bound channels: #operations, #customer-support
```

Replace with:

```markdown
## Slack
- Bound channels: #operations, #customer-support, #credit-verification
```

- [ ] **Step 2: Commit**

```bash
git add workspaces/operations/TOOLS.md
git commit -m "feat(ops): add #credit-verification to bound channels in TOOLS.md"
```

---

### Task 4: Add approval gate exception to admin skill

**Files:**
- Modify: `workspaces/operations/skills/muso-ops-admin/SKILL.md:87-100` (write approval gate)

- [ ] **Step 1: Add exception after the write approval gate**

In `workspaces/operations/skills/muso-ops-admin/SKILL.md`, find the write approval gate section (lines 87-100):

```markdown
## ⚠️ WRITE APPROVAL GATE (MANDATORY until hardened)

**ALL write operations (POST, PUT, PATCH, DELETE) require Aaron's explicit approval.**

Before executing ANY write:
1. Show Aaron exactly what will be called: method, path, body
2. Explain what it will change and why
3. Wait for explicit "go", "do it", "approved" confirmation
4. Log to audit trail before execution
5. Execute and confirm result

Read operations (GET) are always allowed without approval.

This gate will be relaxed per-operation as we validate each endpoint in production.
```

After "This gate will be relaxed per-operation as we validate each endpoint in production.", add:

```markdown

### Hardened Exception: Credit Verification (C0APB2CMM7C)

The following operation is approved for autonomous execution when triggered by the
`muso-ops-credit-verification` skill from the #credit-verification channel (C0APB2CMM7C):

- `PUT /w/admin/credit-requests/<id>` with `{"status":"approved"}` or `{"status":"rejected","reason":"..."}`

Conditions:
- Source channel MUST be C0APB2CMM7C
- Verdict MUST be VERIFIED LEGIT, SUSPICIOUS, or UNVERIFIABLE — LOW CONCERN
- UNVERIFIABLE — NEEDS REVIEW requires Aaron or Jan Delmo approval in-thread
- `--requester clio` for autonomous actions; responder's Slack ID for escalated actions
- Daily cap: 50 autonomous actions/day (escalate remainder)
- All actions logged via muso-ops-audit before execution
```

- [ ] **Step 2: Verify the changes**

Read back the modified section to confirm the exception is clearly scoped and doesn't weaken the general gate.

- [ ] **Step 3: Commit**

```bash
git add workspaces/operations/skills/muso-ops-admin/SKILL.md
git commit -m "feat(ops): add hardened approval gate exception for credit verification"
```

---

### Task 5: Final verification and integration commit

- [ ] **Step 1: Verify all files are consistent**

Read the following files and check for contradictions:
- `workspaces/operations/skills/muso-ops-credit-verification/SKILL.md` — workflow references correct API paths and skill names
- `workspaces/operations/SOUL.md` — channel binding, trigger rule, and approval exception are consistent
- `workspaces/operations/TOOLS.md` — channel is listed
- `workspaces/operations/skills/muso-ops-admin/SKILL.md` — exception is correctly scoped

- [ ] **Step 2: Run a quick grep to verify no conflicting rules**

```bash
grep -n "credit-verification\|C0APB2CMM7C" workspaces/operations/SOUL.md workspaces/operations/TOOLS.md workspaces/operations/skills/muso-ops-admin/SKILL.md workspaces/operations/skills/muso-ops-credit-verification/SKILL.md
```

Expected: All references should be consistent — same channel ID, same channel name.

- [ ] **Step 3: Verify no duplicate channel binding**

```bash
grep -c "credit-verification" workspaces/operations/SOUL.md
```

Expected: 3 (channel binding list, channel rule header, write operations exception).
