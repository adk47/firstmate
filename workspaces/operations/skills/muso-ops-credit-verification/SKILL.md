---
name: muso-ops-credit-verification
description: |
  Autonomous credit verification workflow. Triggered by any message in
  #credit-verification (C0APB2CMM7C). No @mention required — the channel is
  configured with requireMention: false in openclaw.json. Parses the flagged
  credit request, investigates legitimacy, classifies verdict, and auto-approves,
  auto-rejects, or escalates to Aaron/Jan.

  Use when: any message arrives in #credit-verification channel.

  Triggers: any message in #credit-verification (C0APB2CMM7C)
depends-on:
  - muso-ops-credits
  - muso-ops-fraud
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
compatibility: |
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

**Every message in #credit-verification is evaluated by this workflow.
Thread replies in escalation threads are handled as escalation responses (see Step 5).
All other messages: parse, investigate, act. No conversational responses.**

**Thread-awareness:** If the message is a reply in a thread (has `thread_ts` and is
not the parent message), check if the thread was initiated by a credit verification
workflow. If so, treat the reply as an escalation response (see Step 5 — Escalate),
not a new trigger. Only parent messages trigger the full workflow.

## Visual Feedback (Emoji Reactions) — MANDATORY

You MUST use the message tool with `action: "react"` at these exact points.
This is not optional. Skipping reactions is a workflow violation.

**Step 0 passes → add :eyes:**
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes")
```

**After acting (approve/reject/escalate) → remove :eyes: and add final emoji:**
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="<final>")
```

Where `<final>` is:
- `white_check_mark` — auto-approved
- `x` — auto-rejected
- `mag` — escalated for human review

## Workflow

### Step 0: Message Format Gate

Using **case-insensitive** matching, the message MUST contain both:
- "credit request"
- "risk score"

If the message does not contain both markers, ignore it silently.

If the message passes the format gate, YOU MUST immediately call:
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes")
```

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

**If any required field cannot be parsed**, post an error in-thread AND escalate:

```
⚠️ PARSE ERROR — Could not extract required fields from this message.

Missing: [list of missing fields]

Skipping verification. <@U7RP6HKUZ> — message format may have changed. Manual review needed.
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

**If the GET call fails** (network error, non-200 response, timeout), post an error
in-thread and stop — do NOT proceed with investigation on unknown state:

```
⚠️ API ERROR — Could not verify current status of credit request [ID].

Error: [details]

Skipping verification — manual review required. <@U7RP6HKUZ>
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

If a source returns a 429 (rate limit) or blocks the request, skip it and note it
as a failed source. Do not retry aggressively — space requests if processing
multiple verifications in sequence.

**3c. Fraud signal check**:
- Bulk credit submissions (>20 in one day)?
- Disposable email?
- Genre mismatch across submitted credits?
- Credits to high-popularity tracks by unknown profile?
- Credit additions right after profile claiming?

**Investigation failure — CRITICAL:** If Athena is unreachable or returns an error,
OR if more than 2 web research sources fail, the investigation is INCOMPLETE.
An incomplete investigation MUST result in ESCALATION (UNVERIFIABLE — NEEDS REVIEW),
never auto-approve or auto-reject. Include in the report: "Investigation incomplete —
[list which sources failed]. Escalating for human review."

### Step 4: Classify

Map investigation results to a verdict using `muso-ops-fraud` criteria:

| Verdict | Criteria | Action |
|---------|----------|--------|
| **VERIFIED LEGIT** | Confirmed via web (AllMusic/Discogs credits, LinkedIn career, studio site) | Auto-approve |
| **UNVERIFIABLE — LOW CONCERN** | No web presence but consistent pattern (single technical role, professional email, low fraud signals) | Auto-approve |
| **SUSPICIOUS — CLEAR FRAUD** | 2+ strong fraud signals (identity mismatch, web contradicts, disposable email + bulk submissions) | Auto-reject silently |
| **SUSPICIOUS — BORDERLINE** | 1 fraud signal or soft signals (no web presence + high-pop track, but professional email) | Auto-reject + tag Jan |
| **UNVERIFIABLE — NEEDS REVIEW** | No web presence AND risk signals (pop >=90, creative roles, many credits, mononym) | Escalate to Jan (status already `user_verification_needed`) |

### Step 5: Act

#### Safety Rails — Check BEFORE Acting

- **Daily cap**: Count today's autonomous actions by querying the audit log:
  grep the current date (UTC) in `api-logs/admin/YYYY-MM-DD.jsonl` for entries where
  operator is "clio" AND endpoint matches `PUT` on `/credit-requests`.
  If the log file does not exist yet today, count is 0 (first action of the day).
  If count >= 50, escalate this request instead of auto-acting. Post:
  ```
  ⚠️ Daily autonomous action limit reached (50/day). Escalating for human review.
  ```

#### Auto-Approve (VERIFIED LEGIT or LOW CONCERN)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester clio call PUT "/w/admin/credit-requests/<id>" '{"status":"approved"}'
```

Log via `muso-ops-audit` before execution. Then YOU MUST call:
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="white_check_mark")
```

#### Auto-Reject — Clear Fraud (SUSPICIOUS — 2+ strong signals)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester clio call PUT "/w/admin/credit-requests/<id>" \
  '{"status":"rejected","reason":"Flagged as suspicious during pre-approval verification: [specific reason]"}'
```

Use a specific reason based on findings. Examples:
- "Flagged as suspicious: no web presence, disposable email, 15 bulk submissions in 24h"
- "Flagged as suspicious: identity mismatch — web sources contradict claimed credits"
- "Flagged as suspicious: bulk self-additions across unrelated genres"

Log via `muso-ops-audit` before execution. Then YOU MUST call:
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="x")
```

#### Auto-Reject + Notify Jan — Borderline (SUSPICIOUS — 1 or soft signals)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester clio call PUT "/w/admin/credit-requests/<id>" \
  '{"status":"rejected","reason":"Flagged as suspicious during pre-approval verification: [specific reason]"}'
```

Log via `muso-ops-audit` before execution. Then YOU MUST call:
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="x")
```
Post in-thread notifying Jan:
```
🔴 REJECTED — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences]

Risk score: [X]% | Verdict: Suspicious (borderline)
Credit request [ID] rejected. Reason: [reason]
<@U038BM16T7W> — FYI, rejected with soft signals. Override if needed by replying "approve".
```

#### Escalate (NEEDS REVIEW)

The credit is already in `user_verification_needed` status (set by core-backend).
No API call needed — just notify Jan. YOU MUST call:
```
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="C0APB2CMM7C", messageId="<msg_ts>", emoji="mag")
```
Then post in-thread tagging Jan:

```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]"

Evidence: [1-2 sentences summarizing investigation findings]

Risk score: [X]% | Verdict: Unverifiable — Needs Review
<@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.
```

**Thread interaction:** Jan (or Aaron) can interact naturally in the thread:

- **"approve"** or **"approved"** → approve the credit request
- **"reject [reason]"** or **"rejected [reason]"** → reject with the given reason
- **Any other message** (questions, comments, discussion) → respond conversationally,
  answer questions about the investigation, provide more detail if asked. Use your
  existing skills (admin API lookups, Athena queries, web research) to help Jan make
  her decision. Stay in the thread.

**Sender verification:** Only Jan Delmo (`U038BM16T7W`) or Aaron (`U7RP6HKUZ`) can
trigger approve/reject actions. Verify `sender_id` from message metadata. Other users
can chat in the thread but their messages never trigger status changes.

**Executing a decision:** When Jan or Aaron says "approve" or "reject":
1. First, GET the credit request to retrieve the current `credits` array — the API
   requires it in the PUT body even for status changes
2. Call the admin API with their Slack ID as `--requester`:
   - Approve: `{"status":"approved","credits":[<credits from GET>]}`
   - Reject: `{"status":"rejected","reason":"[reason from Jan]","credits":[<credits from GET>]}`
3. The credit can be in any status (`unverified`, `user_verification_needed`, or
   even `rejected` for borderline overrides) — execute the decision regardless.
   If the API returns an error, post it in-thread and let Jan know it needs to be
   done manually via admin panel.
4. Update the emoji on the parent message. YOU MUST call:
   ```
   message(action="react", channelId="C0APB2CMM7C", messageId="<parent_msg_ts>", emoji="mag", remove=true)
   message(action="react", channelId="C0APB2CMM7C", messageId="<parent_msg_ts>", emoji="white_check_mark")
   ```
   (Use `emoji="x"` instead of `white_check_mark` if the decision is "reject")
5. Post confirmation in-thread

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
