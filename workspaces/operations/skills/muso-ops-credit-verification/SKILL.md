---
name: muso-ops-credit-verification
description: |
  Autonomous credit verification workflow. Two modes:
  1. Reactive: Triggered by any message in #credit-verification (C0APB2CMM7C).
     No @mention required. Parses flagged credit requests, investigates, and
     either auto-approves or moves to user_verification_needed. The bot does NOT
     auto-reject — rejection is a manual override from Jan/Aaron in escalation
     threads.
  2. Batch (heartbeat): Proactively fetches up to N unverified credits from
     the API every 6h (N is phased: 10 → 25 → 50 → 100) and processes them,
     posting a summary to #credit-verification with a Jan-tagged thread reply.

  Use when: any message arrives in #credit-verification channel, OR during
  heartbeat execution of the "Batch Credit Verification" task.

  Triggers: any message in #credit-verification (C0APB2CMM7C), heartbeat schedule
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

**Channel ID:** Use `OPS_CREDIT_VERIFICATION_CHANNEL_ID` if set; otherwise default
to `C0APB2CMM7C`. Substitute this channel ID in all `message(...)` calls below.

In examples below, use:
- `<credit_verification_channel_id>` = `OPS_CREDIT_VERIFICATION_CHANNEL_ID` (if set) else `C0APB2CMM7C`

**Step 0 passes → add :eyes:**
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes")
```

**After acting (approve/reject/escalate) → remove :eyes: and add final emoji:**
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="<final>")
```

Where `<final>` is:
- `white_check_mark` — auto-approved
- `warning` — auto-moved to `user_verification_needed`
- `mag` — escalated for human review
- `no_entry` — skipped (cap or idempotent) — rare; only in reactive mode

## Workflow

### Step 0: Message Format Gate

**Self-ignore:** If the message starts with `[HEARTBEAT-BATCH]`, ignore it silently.
This is output from the batch verification heartbeat task — not a new credit to verify.

**On-demand batch trigger:** If the message content is exactly
`run credit verification batch` (case-insensitive), treat it as an on-demand
batch trigger and run **Batch Mode (B1–B5)** using the current channel ID
(`OPS_CREDIT_VERIFICATION_CHANNEL_ID`). Do NOT treat it as a reactive credit
message. Post the batch summary back to the same channel with the standard
`[HEARTBEAT-BATCH]` prefix.

**Authorization.** This command is pre-authorized (no Aaron approval queue)
**only** when the Slack sender is one of:
- Aaron Kaufman (`U7RP6HKUZ`)
- Jan Delmo (`U038BM16T7W`)
- Nick Sollazzo (`U0AL36NADEY`)

Verify `sender_id` from message metadata before running. If the sender is
anyone else, fall through to the default SOUL.md "Write Operations —
Approval Required" flow: acknowledge, prep the action, DM Aaron for
approval, and only execute after he approves.

**Path A — Direct bot message:** Using **case-insensitive** matching, the message
contains both "credit request" and "risk score". Proceed to Step 1 using this message.

**Path B — Human relay via @Ops mention:** The message does NOT contain both markers,
but it is an explicit `@Ops` mention in this channel. No other phrases qualify —
only direct `@Ops` mentions trigger this path. Slack does not deliver bot messages
to other bots, so the original Credit Verification Bot message may not have reached
you. Look at the **preceding message** in the channel (the message immediately above)
to find the Credit Verification Bot's rich message containing the credit data. If the
preceding message contains both "credit request" and "risk score", use THAT message's
content for Step 1 parsing. Store the preceding message's timestamp as
`data_message_ts` — this is the message you will react on and parse from.

> **TODO**: This Path B workaround is fragile (depends on message ordering). The
> proper fix is to have core-backend post credit verifications via a webhook instead
> of a bot user, so Slack delivers the message to the Ops agent directly. See
> core-backend `postCreditVerification()`.

**Neither path matches:** Ignore silently.

If either path matches, YOU MUST immediately call (use `data_message_ts` for Path B):
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<data_message_ts>", emoji="eyes")
```

### Step 1: Parse the Incoming Message

Extract these fields from the message text. The Credit Verification Bot posts using
Slack block kit with bold labels. Match field values by looking for the label followed
by the value on the same or next line. Labels may vary — use the aliases below.

| Field | Required | Bot label(s) | Example value |
|-------|----------|-------------|---------------|
| Credit request ID | Yes | `Credit Request ID:`, `Credit Request:` | `test-req-011`, `cr_abc123` |
| Profile ID | Yes | `Profile ID:` | `test-profile-001`, `prof_xyz789` |
| Profile name | Yes | `Profile:` | `Test Artist Profile` |
| Workspace ID | Yes | `Workspace ID:`, `Workspace:` | `test-ws-001` |
| Owner email | Yes | `Owner Email:` | `nick@muso.ai` |
| Track title | Yes | `Track:` | `Blinding Lights` |
| Artists | Yes | `Artists:` | `The Weeknd` |
| Spotify link | No | `Spotify URL:`, `Spotify:` | `https://open.spotify.com/track/...` |
| Claimed roles | Yes | `Roles:` | `Producer, Songwriter` |
| Overall risk score | Yes | `Risk Score:` | `92%` |
| Per-dimension scores | Yes | `Risk Breakdown:` (bullet list below) | `• artist_risk: 0.85` |
| Pending verification count | No | `Pending Verifications:` | `3` |

**Per-dimension scores** appear as a bullet list under `Risk Breakdown:`, with each
line formatted as `• key: value` (e.g., `• artist_risk: 0.85`). Collect all bullet
items as the per-dimension risk scores.

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
  call GET "/admin/credit-requests/<credit_request_id>"
```

If the status is NOT `unverified` or `user_verification_needed` (e.g., already `approved` or `rejected`),
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

**Tool selection — BROWSER ONLY for credit verification:**

- Use `browser` for **every** web lookup — specific URLs (Spotify/Apple Music/MusicBrainz/Discogs/AllMusic/TIDAL, Jaxsta, ASCAP/BMI/SESAC, studio/artist sites) AND searches (load a search engine URL with `browser open https://duckduckgo.com/?q=<url-encoded query>` or Bing/Google).
- **Do NOT use `web_fetch`.** The admin-api credit-approve gate does not accept `web_fetch` evidence — any PUT approve backed by `web_fetch` loads will be blocked. `web_fetch` frequently returns Cloudflare challenge pages as 200 OK (false positives) and doesn't render JavaScript-dependent credit pages.
- **Do NOT use `web_search`.** The plugin redirects `web_search` in this channel; use `browser` with a search-engine URL instead.

Workflow: `browser open <tier1 URL>` → `browser snapshot` (read rendered text) → repeat for a second Tier 1 host → extract a **literal substring** from the rendered page that confirms the claim (artist name as rendered, role string, track title, etc.) — this is your `--evidence-excerpt` for the approve.

Sources are tiered by priority. Always check Tier 1. Check Tier 2 and 3 as indicated.

**Tier 1 — Always check (primary credit databases):**
- Spotify "Show Credits": use the Spotify link from the credit request to check the track's credits tab for the claimed name+role
- Apple Music: check album credits page — detailed role-level credits for tracks
- MusicBrainz: `musicbrainz.org/search?query=[name]&type=artist` — recording-level credits; look for the specific track+role match, not just artist existence
- Discogs: `discogs.com/search/?q=[name]&type=artist` — discography and credits
- AllMusic: `allmusic.com/search/all/[name]` — artist profile with credits
- TIDAL: `tidal.com` — track/artist credits page, often the most detailed streaming credits

**Tier 2 — Check when claimed role is writing/publishing (songwriter, composer, lyricist, publisher):**
- ASCAP: `ascap.com/repertory` — search by writer name
- BMI: `repertoire.bmi.com/` — search by writer name
- SESAC: `sesac.com` — affiliated writer search

**Tier 3 — Check if Tier 1 is inconclusive (no Tier 1 source confirms the claimed name+role):**
- Jaxsta: `jaxsta.com` — dedicated music credits database
- LinkedIn: music industry career history
- Professional website: check email domain
- DuckDuckGo: `"[name]"+[role]+engineer|producer|mixing`

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
OR if more than 2 **Tier 1** sources fail, the investigation is INCOMPLETE.
An incomplete investigation MUST result in ESCALATION (UNVERIFIABLE — NEEDS REVIEW),
never auto-approve or auto-reject. Include in the report: "Investigation incomplete —
[list which sources failed]. Escalating for human review."

**Grounding — HARD RULE (anti-confabulation):**

Every source URL cited in your verdict MUST correspond to a **successful `browser` tool call** executed in this investigation turn. Prior knowledge, training-data recall, or pattern-matching on the profile/studio/track name is NOT evidence. If you didn't load the page with `browser` and see the text in the snapshot, you don't know what it says.

**Mechanical enforcement.** Autonomous approves are gated by
`muso-admin-api.sh` at the bash layer. The gate reads the openclaw session
log and refuses `PUT /admin/credit-requests status=approved` unless it finds:

1. **≥2 distinct Tier 1 hostnames** (open.spotify.com, music.apple.com, musicbrainz.org, discogs.com, allmusic.com, tidal.com — `www.` tolerated) loaded via the **`browser`** tool (NOT `web_fetch` — those loads do not count).
2. The `--evidence-excerpt` string you pass must appear **verbatim** (case-insensitive) in the browser result text for each of those ≥2 pages.

**Invocation.** Every autonomous credit approve MUST include `--evidence-excerpt`:

```bash
bash .../muso-admin-api.sh call PUT "/admin/credit-requests" \
    --evidence-excerpt "<literal substring on the Tier 1 page>" \
    '{"requestIds":["<cr_id>"],"status":"approved"}'
```

Good excerpt examples (each is a literal substring you saw in a browser snapshot):
- `"Jose Roig"` — artist name as rendered on MusicBrainz + AllMusic
- `"Producer: Ulf Blomberg"` — role string as rendered on AllMusic credits
- `"Tears In Your Smile"` — track title as rendered on Spotify credits

Bad excerpts: generic strings like `"music"`, single words that appear everywhere (`"artist"`), or things you didn't actually see in the rendered page. The bash layer sees 100% of admin API
traffic, so there is no way to confabulate past it.

If the approve command returns `credit_approve_gate: insufficient evidence`,
load two fresh Tier 1 pages with `browser open <url>`, run `browser snapshot`
to confirm the excerpt is visible in the rendered text, then retry the
approve with the updated excerpt. If Tier 1 pages genuinely don't confirm the
credit, downgrade the verdict to **UNVERIFIABLE — NEEDS REVIEW** and escalate
to Jan rather than approving.

**Human overrides bypass the gate — narrowly.** Only passes when `--requester`
resolves to Jan (jan@muso.ai) or Aaron (aaron@muso.ai), i.e. they replied
"approve" in an escalation thread after reviewing the credit. Other requesters
(including Nick triggering a batch with `run credit verification batch`) do NOT
count as per-credit verification — the gate still requires `--evidence-excerpt`
+ browser loads.

**On batch approves, do NOT pass `--requester`.** Batch-mode PUTs are autonomous
— the batch trigger is NOT a per-credit endorsement. Passing `--requester` on
batch approves does nothing useful (Nick is not in the human-verified list) and
can confuse the audit trail. Reserve `--requester <slack_id>` for the
escalation-thread "approve" reply flow only.

**Verdict → Action (unchanged):**

| Verdict | Action |
|---|---|
| VERIFIED LEGIT | Auto-approve (gate enforces evidence). |
| UNVERIFIABLE — LOW CONCERN | Auto-approve (gate still requires ≥2 Tier 1 "checked but no results" loads). |
| UNVERIFIABLE — NEEDS REVIEW | Escalate to Jan. |
| SUSPICIOUS | Move to `user_verification_needed` (or escalate if `OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1`). |

### Step 4: Classify

Map investigation results to a verdict using `muso-ops-fraud` criteria:

| Verdict | Criteria | Action |
|---------|----------|--------|
| **VERIFIED LEGIT** | Confirmed via web (any of: Spotify credits, MusicBrainz, Discogs, AllMusic, Jaxsta, ASCAP/BMI/SESAC, LinkedIn career, studio site) | Auto-approve |
| **UNVERIFIABLE — LOW CONCERN** | No web presence but consistent pattern (single technical role, professional email, low fraud signals) | Auto-approve |
| **SUSPICIOUS — CLEAR FRAUD** | 2+ strong fraud signals (identity mismatch, web contradicts, disposable email + bulk submissions) | **Move to `user_verification_needed`** (silent per-credit; rolled into batch summary). See note on reject policy below. |
| **SUSPICIOUS — BORDERLINE** | 1 fraud signal or soft signals (no web presence + high-pop track, but professional email) | **Move to `user_verification_needed`** (silent per-credit; rolled into batch summary) |
| **UNVERIFIABLE — NEEDS REVIEW** | No web presence AND risk signals (pop >=90, creative roles, many credits, mononym) | Escalate to Jan (status already `unverified` or `user_verification_needed`) |

> **No-reject policy (2026-04-13):** The bot does NOT auto-reject. Both SUSPICIOUS verdicts move credits to `user_verification_needed` so the user can complete their own proof step. Rejection remains available only as a manual override via `reject [reason]` in an escalation thread (see Step 5 → Escalate → Executing a decision).

### Step 5: Act

#### Safety Rails — Check BEFORE Acting

- **Daily approval cap (500/day, UTC).** The cap applies to **autonomous approvals only** — verification-needed moves and escalations are uncapped. Human-initiated approvals (Jan/Aaron override from an escalation thread) carry their Slack ID as `--requester` and do NOT count against the cap.

  Count today's autonomous approvals via the helper:
  ```bash
  COUNT=$(OPS_AUDIT_LOG_DIR="${OPS_AUDIT_LOG_DIR:-api-logs/admin}" \
    bash "${SKILL_DIR}/scripts/count-approvals.sh")
  ```
  where `SKILL_DIR=~/.openclaw/skills/skills/muso-ops-credit-verification`.

  The counter matches entries where **all three** are true: `operator == "clio"`, `requester == "clio"`, `status == "approved"`. Cap resets at **00:00 UTC** (log filename is `YYYY-MM-DD.jsonl` in UTC).

  If `COUNT >= 500` and the current verdict is LEGITIMATE (would trigger an approve): **skip the approve**, mark the credit as `skip_cap` in the run log, and include in the batch summary. **Verification-needed moves and escalations still run** — the cap does not block them.

- **Dry-run mode.** If `OPS_DRY_RUN=1`, still call the admin API wrapper. If the response includes `dry_run: true`, treat it as a successful action but explicitly note in the thread/report: `DRY-RUN: no changes applied`.

#### Auto-Approve (VERIFIED LEGIT or LOW CONCERN)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/credit-requests" \
  --evidence-excerpt "<literal substring you saw on a Tier 1 page>" \
  '{"requestIds":["<id>"],"status":"approved"}'
```

**Important:** Use `PUT /admin/credit-requests` (bulk status endpoint), NOT
`PUT /admin/credit-requests/:id` (that endpoint updates the credits array only
and silently ignores the status field).

Log via `muso-ops-audit` before execution. Then YOU MUST call:
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="white_check_mark")
```

#### Move to `user_verification_needed` (SUSPICIOUS — any tier)

Both CLEAR FRAUD and BORDERLINE verdicts take this same action: flip the credit's status so the user is prompted to complete their own verification. The bot does NOT reject.

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/credit-requests" \
  '{"requestIds":["<id>"],"status":"user_verification_needed","reason":"Moved to user_verification_needed during pre-approval: [specific reason]"}'
```

Use a specific reason based on findings (examples):
- "Moved to user_verification_needed during pre-approval: no web presence, disposable email, 15 bulk submissions in 24h"
- "Moved to user_verification_needed during pre-approval: identity mismatch — web sources contradict claimed credits"
- "Moved to user_verification_needed during pre-approval: bulk self-additions across unrelated genres"

**Fallback if gate #2 failed** (`OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1` set): skip the API call, treat this verdict as an escalation instead — post the same detail in-thread and tag Jan. This prevents silently-parked credits until the user-facing notification flow ships.

Log via `muso-ops-audit` before execution. Do NOT tag Jan per-credit — the batch summary handles the single rolled-up ping.

Reactive mode only: update emoji on the source message. YOU MUST call:
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="warning")
```

(Using `warning` instead of `x` to reflect "moved, not rejected." In batch mode, no reactions since there is no source message.)

Per-credit Slack post is **removed** in both modes — the rolled-up batch summary (Batch Mode B3) carries the audit trail.

#### Escalate (NEEDS REVIEW)

The credit is already in `unverified` or `user_verification_needed` status (set by core-backend).
No API call needed — just notify Jan. YOU MUST call:
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="mag")
```
Then post in-thread tagging Jan:

```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]" ([Artists])

Evidence: [1-2 sentence summary of investigation findings]

Sources (Tier 1):
• Spotify credits: <url> — [what was found, or "no credits listed"]
• MusicBrainz: <url> — [what was found, or "no results"]
• Discogs: <url> — [what was found, or "no results"]
• AllMusic: <url> — [what was found, or "no results"]
[Tier 2/3 sources checked, if any]

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
1. Call the admin API with their Slack ID as `--requester`:
   - Approve: `PUT /admin/credit-requests` with `{"requestIds":["<id>"],"status":"approved"}`
   - Reject: `PUT /admin/credit-requests` with `{"requestIds":["<id>"],"status":"rejected","reason":"[reason from Jan]"}`
   **Important:** Use the bulk status endpoint (`PUT /admin/credit-requests`), NOT
   the per-request endpoint (`PUT /admin/credit-requests/:id`) which only updates credits.
2. The credit can be in any status (`unverified`, `user_verification_needed`, or
   even `rejected` for borderline overrides) — execute the decision regardless.
   If the API returns an error, post it in-thread and let Jan know it needs to be
   done manually via admin panel.
3. Update the emoji on the parent message. YOU MUST call:
   ```
   message(action="react", channelId="<credit_verification_channel_id>", messageId="<parent_msg_ts>", emoji="mag", remove=true)
   message(action="react", channelId="<credit_verification_channel_id>", messageId="<parent_msg_ts>", emoji="white_check_mark")
   ```
   (Use `emoji="x"` instead of `white_check_mark` if the decision is "reject")
4. Post confirmation in-thread

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
✅ APPROVED — [Profile Name] as [Role] on "[Track Title]" ([Artists])

Evidence: [1-2 sentence summary of why this is legit]

Sources (Tier 1):
• Spotify credits: <url> — [what was found, or "no credits listed"]
• MusicBrainz: <url> — [what was found, or "no results"]
• Discogs: <url> — [what was found, or "no results"]
• AllMusic: <url> — [what was found, or "no results"]
[Tier 2 — if writing/publishing role was checked:]
• ASCAP/BMI/SESAC: <url> — [what was found]
[Tier 3 — if checked:]
• [source]: <url> — [what was found]

Risk score: [X]% | Verdict: [Verdict]
Note: [1 sentence on why risk flag is a false positive, if applicable]
Credit request [ID] approved.
```

**Manual reject format (escalation thread only — used when Jan/Aaron issue a `reject` command):**
```
🔴 REJECTED — [Profile Name] as [Role] on "[Track Title]" ([Artists])

Evidence: [1-2 sentence summary of fraud signals]

Sources (Tier 1):
• Spotify credits: <url> — [what was found, or "no credits listed"]
• MusicBrainz: <url> — [what was found, or "no results"]
• Discogs: <url> — [what was found, or "no results"]
• AllMusic: <url> — [what was found, or "no results"]
[Tier 2/3 sources checked, if any]

Risk score: [X]% | Verdict: [Verdict]
Credit request [ID] rejected. Reason: [reason]
```

## Relationship to Other Verification Workflows

Three verification workflows exist, each serving a different purpose:

- **Reactive verification (this skill, Steps 0-6):** Pre-approval review of
  flagged credits (risk >= 85%) posted by core-backend to #credit-verification.
  Processes one credit per message, immediately.

- **Batch verification (this skill, Batch Mode):** Proactive queue processing
  via heartbeat. Fetches up to `$FETCH_SIZE` (phased 10 → 100) unverified credits
  every 6 hours and processes them, posting a summary with a Jan-tagged thread.
  Catches credits that reactive mode doesn't see (risk < 85%). Idempotency check
  prevents double-processing with reactive. Approvals are capped at 500/day UTC;
  verification-needed moves are uncapped.

- **Daily fraud scan (HEARTBEAT.md):** Post-approval review of already-approved
  credits on high-popularity tracks (Spotify pop >= 50). Different population —
  only looks at credits that have already been approved.

All three should continue running. They complement each other.

---

## Batch Mode (Heartbeat Task)

Proactive queue processing triggered by the heartbeat schedule (every 6 hours).
Instead of reacting to a channel message, the agent fetches unverified credits
from the API and processes them in a batch.

### When This Applies

This mode applies ONLY when executing the "Batch Credit Verification" heartbeat task.
It does NOT apply when responding to messages in #credit-verification — those use the
reactive workflow above (Steps 0-6).

### Batch Workflow

#### B0. Setup — lockfile, run_id, fetch_size

Before any network work, initialize the run context.

**0a. Verify required env.** Fail loudly if any of these are missing:
- `OPS_BATCH_LOCK_PATH` — absolute path to lockfile (e.g. `/root/.openclaw/locks/ops-credit-batch.lock`)
- `OPS_AUDIT_LOG_DIR` — audit log base (e.g. `/root/.openclaw/api-logs/admin`)
- `OPS_RUNLOG_DIR` — run-log base (e.g. `/root/.openclaw/api-logs/credit-batch-runs`)
- `OPS_WORKSPACE` — either `operations-dev` or `operations`
- `OPS_BATCH_ENABLED` — must be `true` (default). Set to `false` to suppress batches on the twin not currently running.

If `OPS_BATCH_ENABLED != "true"`, exit silently with no Slack post.

**0b. Acquire lockfile.**

The lockfile uses PID liveness as the primary signal and a **5h30m** mtime fallback for cases where a process was killed without releasing (SIGKILL, host crash). 5h30m sits inside the 6h heartbeat cadence — a legitimately long batch (very large queue, slow API) approaching that window CAN be self-stolen by the next heartbeat. In practice the batch never exceeds ~30min; if you see runs near 5h30m you have a deeper problem to investigate.

```bash
SKILL_DIR=~/.openclaw/skills/skills/muso-ops-credit-verification
# Pass our own $$ so the lockfile records the long-lived caller PID, not the
# helper script's ephemeral PID (which dies on return).
bash "$SKILL_DIR/scripts/lockfile.sh" acquire $$
case $? in
  0) ;;       # acquired
  10) exit 0 ;;  # another run holds it, exit silently
  *) echo "Lockfile error"; exit 1 ;;
esac
trap 'bash "$SKILL_DIR/scripts/lockfile.sh" release' EXIT
```

**0c. Init run log and read phase variables.**
```bash
RUN_ID=$(bash "$SKILL_DIR/scripts/runlog.sh" init)
FETCH_SIZE="${OPS_BATCH_FETCH_SIZE:-10}"   # ← phase knob; set OPS_BATCH_FETCH_SIZE env to ramp 10→25→50→100
APPROVAL_CAP_LIMIT=500

# CRITICAL: count-approvals.sh must succeed AND return a number. If it returns
# empty (script errored, captured as ""), `[[ "" -ge 500 ]]` evaluates false
# and the cap is silently disabled. Assert numeric explicitly.
APPROVAL_CAP_USED=$(bash "$SKILL_DIR/scripts/count-approvals.sh") || {
  echo "FATAL: count-approvals.sh failed (exit $?); aborting batch to avoid uncapped approvals" >&2
  exit 1
}
if ! [[ "$APPROVAL_CAP_USED" =~ ^[0-9]+$ ]]; then
  echo "FATAL: count-approvals.sh returned non-numeric output: '$APPROVAL_CAP_USED'; aborting batch" >&2
  exit 1
fi

bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" run_started \
  "$(jq -n --arg phase "${OPS_BATCH_PHASE:-0}" --argjson fs "$FETCH_SIZE" \
          --argjson cu "$APPROVAL_CAP_USED" --argjson cl "$APPROVAL_CAP_LIMIT" \
          '{phase:$phase, fetch_size:$fs, approval_cap_used_at_start:$cu, approval_cap_limit:$cl}')"
```

#### B1. Fetch the Queue

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?status=unverified&limit=$FETCH_SIZE"
```

Also fetch total queue size:
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests/counts?status=unverified"
```

Record queue depth to the run log:
```bash
bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" run_started_queue \
  "$(jq -n --argjson depth "$TOTAL_UNVERIFIED" '{queue_depth_at_start:$depth}')"
```

The list endpoint returns `createdAt DESC` by default (newest first = LIFO).

- **If the list is empty:** Post the queue-clear message (see B5) and stop.
- **If either API call fails:** Post an error status to `#credit-verification` and stop:
  ```
  [HEARTBEAT-BATCH] Credit Verification Batch — [timestamp]
  ⚠️ API error fetching unverified queue. Skipping this cycle.
  Error: [details]
  ```

#### B2. Process Each Credit

Initialize in-run counters:
```bash
MOVES_COUNT=0
APPROVED_IN_RUN=0
```

For each credit request in the batch:

1. **Log fetched.**
   ```bash
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" credit_fetched \
     "$(jq -n --arg id "$CR_ID" --arg uid "$USER_ID" --arg pid "$PROFILE_ID" \
            --arg st "$CURRENT_STATUS" \
            '{cr_id:$id, userid:$uid, profileid:$pid, current_status:$st}')"
   ```

2. **Idempotency check.** If current status is not `unverified` or `user_verification_needed`, log `skip_idempotent` and continue.
   ```bash
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" action_attempted \
     "$(jq -n --arg id "$CR_ID" --arg a skip_idempotent '{cr_id:$id, action:$a}')"
   ```

3. **Investigate + Classify** (Step 3 + Step 4). Log:
   ```bash
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" verdict \
     "$(jq -n --arg id "$CR_ID" --arg v "$VERDICT" --arg r "$REASON" \
            --argjson sig "$SIGNALS_JSON" \
            '{cr_id:$id, verdict:$v, reason:$r, signals:$sig}')"
   ```

4. **Approval cap check** (only for LEGITIMATE verdicts).
   ```bash
   if [[ "$VERDICT" == "LEGITIMATE" && "$APPROVAL_CAP_USED" -ge "$APPROVAL_CAP_LIMIT" ]]; then
     bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" action_attempted \
       "$(jq -n --arg id "$CR_ID" --arg a skip_cap '{cr_id:$id, action:$a}')"
     continue   # move on, DO NOT mark as verification_needed
   fi
   ```

5. **Runaway safety rail** (before executing a verification_needed move).
   ```bash
   if [[ "$VERDICT" == "CLEAR_FRAUD" || "$VERDICT" == "BORDERLINE" ]]; then
     MOVES_COUNT=$((MOVES_COUNT + 1))
     # Fires when ≥90% of fetched have been moved — catches a runaway mid-batch.
     # Round UP so small FETCH_SIZE doesn't trip on the first move:
     #   FETCH_SIZE=10 → 9, FETCH_SIZE=25 → 23, FETCH_SIZE=100 → 90, FETCH_SIZE=1 → 1
     THRESHOLD=$(( (FETCH_SIZE * 9 + 9) / 10 ))
     if [[ "$MOVES_COUNT" -ge "$THRESHOLD" ]]; then
       bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" runaway_rail_triggered \
         "$(jq -n --argjson n "$MOVES_COUNT" --argjson fs "$FETCH_SIZE" \
                '{moves_so_far:$n, fetch_size:$fs}')"
       # Post to Slack (Jan only) and exit the batch.
       # CRITICAL: this MUST actually send via the message() tool — a comment
       # placeholder would mean the rail trips silently and Jan never finds out.
       # Tool syntax matches the `react` calls used in Step 5 (parens + kwargs),
       # NOT shell. The bash block above logs the event; this step is the
       # tool-call instruction the agent executes.
       message(action="send",
               channelId="<credit_verification_channel_id>",
               text="🚨 Runaway batch — $MOVES_COUNT of $FETCH_SIZE fetched credits moved to verification_needed. Pausing. <@U038BM16T7W>")
       break
     fi
   fi
   ```

6. **Act (Step 5).** Execute the verdict (approve / verification_needed / escalate).
   - **Fallback override (gate #2):** If `OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1` is set AND verdict is CLEAR_FRAUD or BORDERLINE, treat the verdict as ESCALATE instead — post an individual top-level escalation message tagging Jan, do NOT call the admin API to flip status. This protects against silently-parking credits when the user-facing notification flow isn't wired yet.
   - Before: log `action_attempted` with the API request body and `reason_storage` (`api_reason_field` if gate #1 confirmed the API stores reason; otherwise `verificationdata.ops_reason`).
   - After: parse the bulk API response and log `action_result` with `per_id_outcome` (`success` / `error` / `unchanged`), `http_status`, and `duration_ms`.
   - If VERDICT was LEGITIMATE and action succeeded: `APPROVED_IN_RUN=$((APPROVED_IN_RUN + 1))` and `APPROVAL_CAP_USED=$((APPROVAL_CAP_USED + 1))`.
   - If `per_id_outcome` was `error`: `ERRORS=$((ERRORS + 1))`.
   - **Skip all emoji reactions** — no source message in batch mode.
   - For escalations: post an individual top-level message (existing behavior, unchanged).

7. **On any per-credit error:** log `error` event with `cr_id`, `stage`, `error_message`, and a truncated `traceback_snippet`, increment `ERRORS`, then continue with the next credit.

   **Error-storm escalation.** If at the end of the loop `ERRORS >= max(3, FETCHED / 2)` (i.e. half the batch errored, with a floor of 3 to avoid noise on tiny batches), post a Jan-tagged alert in addition to the normal summary:
   ```bash
   if [[ "$FETCHED" -gt 0 ]]; then
     ERR_THRESHOLD=$(( FETCHED / 2 ))
     [[ "$ERR_THRESHOLD" -lt 3 ]] && ERR_THRESHOLD=3
     if [[ "$ERRORS" -ge "$ERR_THRESHOLD" ]]; then
       # Tool syntax matches the `react` calls in Step 5 (not shell).
       message(action="send",
               channelId="<credit_verification_channel_id>",
               text="🚨 Error storm — $ERRORS of $FETCHED credits errored this batch. Likely API degradation. <@U038BM16T7W>")
     fi
   fi
   ```

#### B3. Compose Summary

**Parent message** (top-level, public, no tags, always posted to `OPS_CREDIT_VERIFICATION_CHANNEL_ID`, default `C0APB2CMM7C`):
```
[HEARTBEAT-BATCH] Credit batch complete — {YYYY-MM-DD HH:MM UTC}
Fetched: {FETCHED} | Approved: {APPROVED_IN_RUN} | → verification_needed: {MOVES_COUNT} | Escalated: {ESCALATED} | Skipped: {SKIPPED_IDEMPOTENT + SKIPPED_CAP}
Approval cap used: {APPROVAL_CAP_USED}/{APPROVAL_CAP_LIMIT} today | Queue remaining: {QUEUE_REMAINING} unverified
```

Store the parent message's Slack ts for thread replies and for the `run_finished` event in B6.

**Thread reply 1** (only if there were verification_needed moves, escalations, or skipped — i.e. non-empty detail; tags Jan):
```
<@U038BM16T7W> — batch summary

🔴 → verification_needed ({MOVES_COUNT}):
• {cr_id} {profile} as {role} on "{track}" — reason: {specific reason}
• ...

🔍 Escalated ({ESCALATED}):
• {cr_id} {profile} as {role} on "{track}" — reason: {specific reason}
• ...

⏭️ Skipped idempotent ({SKIPPED_IDEMPOTENT}):
• {cr_id} — already processed

⏭️ Skipped (cap) ({SKIPPED_CAP}):
• {cr_id} — daily approval cap reached
```

If all four detail sections (`verification_needed`, `Escalated`, `Skipped idempotent`, `Skipped (cap)`) are empty, skip this thread reply entirely.

**Thread reply 2** (only if approval cap was hit during this run):
```
⚠️ Daily approval cap reached ({APPROVAL_CAP_LIMIT}/day). {SKIPPED_CAP} LEGITIMATE verdicts skipped — will retry next batch.
Verification-needed moves continued uncapped.
```

Use `message(action=send, target="<credit_verification_channel_id>")` for the parent message (NO `threadId`). For thread replies, use the parent's ts as `threadId` / `replyTo`.

#### B4. Escalation Threads

For each escalated credit, post a **separate top-level message** in
`#credit-verification` BEFORE the summary. Use the same format as reactive
escalations (Step 5 — Escalate section above):

```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]" ([Artists])

Evidence: [1-2 sentence summary of investigation findings]

Sources (Tier 1):
• Spotify credits: <url> — [what was found, or "no credits listed"]
• MusicBrainz: <url> — [what was found, or "no results"]
• Discogs: <url> — [what was found, or "no results"]
• AllMusic: <url> — [what was found, or "no results"]
[Tier 2/3 sources checked, if any]

Risk score: [X]% | Verdict: Unverifiable — Needs Review
<@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.
```

Jan can reply in each escalation thread independently. Thread interaction works
the same as reactive flow (see Step 5 — Thread interaction).

The batch summary's "Escalated" line references these threads but does not
duplicate the full investigation details.

#### B5. Queue Clear

If the API returns zero unverified credits:

```
[HEARTBEAT-BATCH] Credit Verification Batch — [timestamp]
Queue clear — no unverified credits remaining.
```

#### B6. Finish — log summary, compress old logs

After the parent summary message is posted (whether B3's normal summary or B5's queue-clear message), run the finalization steps.

Log the `run_finished` event:
```bash
bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" run_finished \
  "$(jq -n --argjson f "$FETCHED" --argjson a "$APPROVED_IN_RUN" \
          --argjson v "$MOVES_COUNT" --argjson e "$ESCALATED" \
          --argjson si "$SKIPPED_IDEMPOTENT" --argjson sc "$SKIPPED_CAP" \
          --argjson errs "$ERRORS" --arg ts "$PARENT_MSG_TS" \
          '{fetched:$f, approved:$a, verification_needed:$v, escalated:$e,
            skipped_idempotent:$si, skipped_cap:$sc, errors:$errs,
            summary_post_message_ts:$ts}')"
```

Run compression (idempotent; cheap no-op most days):
```bash
bash "$SKILL_DIR/scripts/compress-old-logs.sh" || true
```

The lockfile is released automatically by the `trap` set in B0 when the run exits.

### Rate Limiting Note

When processing multiple credits sequentially, space web research requests to
avoid hitting rate limits on external sources (Spotify, MusicBrainz, etc.).
If a source returns 429, skip it and note as a failed source for that credit.

---

## Profile Verification Mode (Ad-Hoc)

Handles requests like "verify all credits for profile X" or "check all remaining
credits for [name]". This mode is triggered by a human (Jan or Aaron) asking in
any ops channel — NOT by the automated credit verification bot.

### When This Applies

A human explicitly asks to verify, check, or approve all pending/remaining credits
for a specific profile. This is NOT a bulk rubber-stamp — each credit group goes
through investigation.

### HARD RULES

1. **Never approve all credits in a single API call.** The wrapper enforces a
   maximum of 10 requestIds per call. Even if the wrapper allowed it, you MUST
   process in groups.
2. **Never skip investigation.** Every credit group must be investigated before
   approval. "The profile looks legit" is not sufficient — you must verify the
   credits themselves are plausible.
3. **Daily approval cap still applies.** If you hit 500 autonomous approvals
   (UTC day), stop approving and tell the requester how many remain for the
   next cycle. Verification-needed moves and escalations are uncapped.
4. **Only Jan (U038BM16T7W) or Aaron (U7RP6HKUZ) can trigger this workflow.**
   Verify `sender_id` from message metadata.

### Workflow

#### P1. Acknowledge and Fetch

Acknowledge the request, then fetch all unverified credits for the profile:

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?status=unverified&profileId=<profile_id>&limit=500"
```

Post acknowledgment:

```
Checking all unverified credits for [Profile Name] ([profile_id]).
Found [N] pending. Processing now — this will take a while for large queues.
```

If N > 500, add:
```
Note: Daily approval cap is 500 autonomous approvals. I'll approve up to 500
this cycle and report how many remain. (Verification-needed moves and
escalations are uncapped.)
```

#### P2. Profile-Level Investigation

Before processing individual credits, investigate the profile itself. This
determines the baseline trust level.

**Required checks:**
- Web presence: professional website, LinkedIn, studio presence
- Industry registration: IPI, MLC, TIDAL, Jaxsta profiles
- Existing catalog: how many credits already in the system, what roles, how long
- Submission pattern: single role type vs. mixed, same ecosystem vs. scattered

**Classify the profile:**

| Profile Level | Criteria | Effect on Credit Processing |
|---------------|----------|---------------------------|
| **ESTABLISHED** | Professional website + IPI/MLC + 50+ existing credits + consistent role | Groups of same role/ecosystem can use lighter investigation (P3a) |
| **EMERGING** | Some web presence OR IPI/MLC OR 10+ existing credits | Each credit gets standard investigation (P3b) |
| **UNKNOWN** | No web presence, no registrations, few/no existing credits | Escalate entire batch to Jan — do not auto-process |

Post the profile assessment before proceeding:

```
Profile Assessment — [Profile Name]

Web: [findings]
Industry: [IPI/MLC/TIDAL/Jaxsta status]
Catalog: [N] existing credits, primarily [roles]
Submission: [pattern description]

Profile level: [ESTABLISHED/EMERGING/UNKNOWN]
Proceeding with [approach based on level].
```

#### P3. Group and Process Credits

Group the credits by **role type** and **submission source** (submissionId).
Each group is processed separately.

**P3a. Established profile — grouped investigation:**

For each role/source group:
1. Verify the role is consistent with the profile's known work
2. Spot-check 3-5 credits from the group against Tier 1 sources (Spotify, MusicBrainz)
3. Check for deleted tracks in the group (GET each credit's track status)
4. Check for outliers: different genre, unusually high popularity (pop >= 90),
   or roles that differ from the profile's primary role

If spot-checks pass and no outliers: approve the group (in batches of 10 max).
If outliers found: pull them out and process individually per P3b.

**P3b. Emerging profile — individual investigation:**

Process each credit through the standard Steps 2-6 from the reactive workflow:
- Step 2: Idempotency check
- Step 3: Investigate (Athena + tiered web research + fraud signals)
- Step 4: Classify
- Step 5: Act (approve/reject/escalate)

This is slower but ensures full rigor for less-established profiles.

**P3c. Unknown profile — escalate:**

Do NOT auto-process. Post to the channel:

```
Warning: Profile [Name] has insufficient verification data for autonomous processing.

Web presence: [none/minimal]
Industry registration: [none found]
Existing catalog: [N] credits

[N] unverified credits cannot be auto-processed. Manual review required.
<@U038BM16T7W> — please review this profile before I process credits.
```

Wait for Jan/Aaron to respond with guidance in the thread.

#### P4. Execute Approvals

For each approved group, call the API in batches of 10 or fewer:

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester <requester_slack_id> \
  call PUT "/admin/credit-requests" \
  '{"requestIds":["<id1>","<id2>",...max 10],"status":"approved"}'
```

Log each batch via `muso-ops-audit` before execution.

For rejections, include a reason:

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester <requester_slack_id> \
  call PUT "/admin/credit-requests" \
  '{"requestIds":["<id>"],"status":"rejected","reason":"[specific reason]"}'
```

#### P5. Summary Report

After processing all credits (or hitting the daily cap), post a summary:

```
Profile Verification Complete — [Profile Name]

Profile level: [ESTABLISHED/EMERGING/UNKNOWN]
Total unverified: [N]
Processed: [N]

Approved: [N] ([breakdown by role group])
Rejected: [N] ([reasons])
Escalated: [N] ([reasons])
Skipped (cap): [N] — daily limit reached, [N] remain for next cycle
Skipped (deleted track): [N]

[If any remain:]
Remaining: [N] unverified credits. Will process in next cycle or on request.
```
