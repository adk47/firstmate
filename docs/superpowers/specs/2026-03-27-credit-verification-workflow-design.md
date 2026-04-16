# Credit Verification Workflow — Ops Agent Integration

**Date:** 2026-03-27
**Status:** Draft
**Related:** [core-backend PR #8465](https://github.com/Muso-AI/core-backend/pull/8465)

## Context

Core-backend PR #8465 introduces a Slack-based credit verification workflow. When a credit request's risk score meets or exceeds the threshold (default 85%), the system posts a rich Block Kit message to a dedicated Slack channel (`#credit-verification`), tagging the ops agent for review.

This spec defines what hydra needs to do so the ops agent can autonomously handle these flagged credit requests.

## Design

### New Skill: `muso-ops-credit-verification`

**Location:** `workspaces/operations/skills/muso-ops-credit-verification/SKILL.md`

A dedicated skill defining the autonomous workflow triggered when the agent is @mentioned in the `#credit-verification` channel.

**Dependencies:** `muso-ops-credits`, `muso-ops-fraud`, `muso-ops-admin`, `muso-ops-audit`, `muso-slack-formatter`

#### Workflow

1. **Parse** — Extract from the incoming message: credit request ID, profile ID, profile name, workspace ID, owner email, track title, artists, Spotify link, claimed roles, overall risk score, per-dimension scores (artist_risk, track_risk, role_risk), pending verification count. If any required field cannot be parsed, post an error in-thread listing the missing fields and skip processing — do not silently fail.

   **Idempotency check:** Before investigating, query the credit request status via admin API (`GET /admin/credit-requests/:requestId`). If the status is no longer `user_verification_needed` (e.g., already approved/rejected from a retry or duplicate post), post a short note in-thread ("Already processed — status: [status]") and skip.

2. **Investigate** — Reuse existing skill logic:
   - Athena cross-reference via `muso-ops-credits` (does this person appear in industry data for this track?)
   - Web research via `muso-ops-fraud` (AllMusic, Discogs, LinkedIn, professional sites)
   - Fraud signal check (bulk submissions, disposable email, genre mismatch, etc.)

3. **Classify** — Map to verdict categories:
   - **VERIFIED LEGIT** → auto-approve
   - **UNVERIFIABLE — LOW CONCERN** → auto-approve
   - **SUSPICIOUS** → auto-reject
   - **UNVERIFIABLE — NEEDS REVIEW** → escalate in-thread

4. **Act** — Call admin API to approve/reject, or post escalation. All actions logged via `muso-ops-audit`. For autonomous actions, use `--requester clio` (the ops agent's service identity). For escalated actions where Aaron or Jan responds, use their Slack user ID as `--requester`.

5. **Report** — Post investigation summary in-thread on the original Block Kit message.

#### Verdict-to-Action Mapping

| Verdict | Action | Approval Gate |
|---------|--------|---------------|
| Verified Legit | Auto-approve | Autonomous |
| Unverifiable — Low Concern | Auto-approve | Autonomous |
| Suspicious | Auto-reject | Autonomous |
| Unverifiable — Needs Review | Escalate in-thread | Requires Aaron or Jan |

### Channel Binding

**Channel:** `#credit-verification` (C0APB2CMM7C)

Added as a bound channel in SOUL.md with a hard rule:

- Every @mention in this channel triggers the `muso-ops-credit-verification` skill
- No exceptions. No conversational responses. No clarifying questions.
- Parse the message, investigate, act. Every time.

The trigger mechanism is the @mention from core-backend's `postCreditVerification()` — OpenClaw's existing Slack dispatch handles @mention routing. The channel rule ensures the agent always uses the credit verification skill (not general-purpose handling) when the mention comes from this channel.

### Approval Gate Exception

**Current state:** All write operations require Aaron's explicit approval.

**Change:** Add a narrow exception for credit request approve/reject. The admin API wrapper script prepends the `/w/` prefix automatically — the logical route is `PUT /admin/credit-requests/:requestId`:

- Only when triggered from the `#credit-verification` channel (C0APB2CMM7C)
- Only for clear verdicts: VERIFIED LEGIT, SUSPICIOUS, UNVERIFIABLE — LOW CONCERN
- UNVERIFIABLE — NEEDS REVIEW still requires human approval
- All actions still logged via audit skill

#### Safety Rails

- **Daily cap:** Max 50 autonomous approve/reject actions per day. Beyond that, escalate remaining requests to Aaron/Jan.
- **Parse failure:** If the incoming message cannot be parsed, post error in-thread and skip — never auto-act on incomplete data.
- **API failure:** If the admin API call to approve/reject fails, post error in-thread and do not retry automatically.

### Escalation

When verdict is UNVERIFIABLE — NEEDS REVIEW, the agent posts in-thread tagging both:

- Aaron (`<@U7RP6HKUZ>`)
- Jan Delmo (`<@U038BM16T7W>`)

Either can respond. First valid response wins — the agent acts on it and confirms. Any subsequent conflicting response is acknowledged but not acted on.

**Accepted response formats:** "approve", "approved", "reject [reason]", "rejected [reason]". Other messages in the thread are acknowledged but not treated as a decision.

**Timeout:** If no valid response within 30 minutes, the agent posts a reminder. No auto-action on timeout — the credit stays in `user_verification_needed` status until a human decides.

### In-Thread Reporting Format

**Auto-approve:**
```
✅ APPROVED — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences]

Risk score: [X]% | Verdict: [Verdict]
Credit request [ID] approved.
```

**Auto-reject:**
```
🔴 REJECTED — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences]

Risk score: [X]% | Verdict: [Verdict]
Credit request [ID] rejected. Reason: [standard rejection reason]
```

**Escalation:**
```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences]

Risk score: [X]% | Verdict: Unverifiable — Needs Review
@Aaron @Jan — please review. Reply "approve" or "reject [reason]" in this thread.
```

### Relationship to Daily Credit Fraud Scan

The daily heartbeat scan (HEARTBEAT.md) stays unchanged. It serves a different purpose:

- **This workflow:** Pre-approval review of flagged credits (risk >= 85%)
- **Daily scan:** Post-approval review of approved credits on high-popularity tracks (Spotify pop >= 50)

Defense in depth — the daily scan catches credits below the 85% threshold that still look suspicious after approval.

## Files Changed

| File | Change Type | Description |
|------|-------------|-------------|
| `workspaces/operations/skills/muso-ops-credit-verification/SKILL.md` | New | Autonomous credit verification workflow |
| `workspaces/operations/SOUL.md` | Modify | Add `#credit-verification` (C0APB2CMM7C) as bound channel with hard trigger rule. Add Jan as authorized approver for credit verification escalations. |
| `workspaces/operations/TOOLS.md` | Modify | Add channel to bound list |
| `workspaces/operations/skills/muso-ops-admin/SKILL.md` | Modify | Add approval gate exception: `PUT /admin/credit-requests/:requestId` is autonomous when source channel is C0APB2CMM7C and verdict is not NEEDS REVIEW |

**Note:** Jan Delmo's Slack user ID `U038BM16T7W` maps to `jan@muso.ai` in the admin API user mapping. This is the same person (Jan Roland Delmo, ops team owner).

## Cross-Repo Dependency

Core-backend PR #8465 must set a rich `text` fallback in `postCreditVerification()` alongside the Block Kit `blocks` array. OpenClaw receives the `text` field as the agent's input — if it's thin (e.g., "New credit verification request"), the agent gets insufficient context to investigate.

The `text` fallback must include: profile name, profile ID, credit request ID, track title, artists, claimed roles, overall risk score, per-dimension scores.

**Owner:** Nick (in progress).
