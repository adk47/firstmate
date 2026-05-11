# Caroline analytics handoff — design

**Date:** 2026-05-11
**Author:** Nick (with Claude)
**Status:** v2 — revised after Clio review (see Revision History at end)
**Successor to:** [2026-05-08-caroline-analytics-knowledge-base-design.md](2026-05-08-caroline-analytics-knowledge-base-design.md) (PR #269, KB rewrite)

## Problem

After PR #269 rewrote Caroline's analytics knowledge base ("no apology, upgrade-in-progress, never quote timing"), Jan reported that analytics-related support volume has not dropped. Inspection of the live intercom inbox (last 30 days, n=1641 conversations; ~55 explicit "analytics" + 63 "streams" + 10 "stream count") shows:

- **Caroline already uses the new KB tone correctly.** The script ("your analytics are still being tracked normally in the background…") appears on the vast majority of analytics replies — both Caroline-authored and Jan-authored.
- **Caroline handles 57% of last-7-day volume (n=150).** Jan handles 37%, mostly conversations where the customer pushed back and Caroline escalated by routing them to email.
- **The escalation to email is a no-op loop.** Caroline tells the customer "email `support@muso.ai`" → that address routes back to the same intercom inbox → Jan replies with the same boilerplate Caroline already sent. No new action, just more work for Jan.
- **Customer pushback is about specificity.** "Are you looking at MY account?" — Caroline never proves she has, because she doesn't call her existing `profile_lookup`/`credits_search` tools on analytics conversations.
- **Root cause discovered during v2 review: the support-tools plugin is not loaded by the edge gateway.** `openclaw-edge.json` has `plugins.allow: ["slack", "intercom"]` and `plugins.load.paths: ["/root/.openclaw-edge/extensions/intercom"]`. The `support-tools` directory exists on disk but is never loaded. Verified live: `grep create_ticket` across 7 days of edge gateway logs returns 0. Caroline has **zero** custom tools today — the four entries in `SOUL.md` describe a contract that does not exist at runtime. This is the underlying reason Caroline falls back to "email support@muso.ai" — she has no `create_ticket` to call.

## Goal

Stop the no-op email loop. Make Caroline:
1. Prove she has read the customer's specific profile before giving the upgrade-in-progress reply.
2. File a real ClickUp ticket on customer pushback instead of routing to email.
3. Never recommend the customer email any Muso address.

Expected outcome: analytics volume to Jan drops because the conversations that previously escalated to email now either resolve in-chat (customer satisfied by per-profile acknowledgment) or land in a single queue (ClickUp `analytics-followup`) that engineering reviews on a schedule.

## Non-goals

- No Ops-agent-handles-Intercom path. Caroline stays fully isolated.
- No `sessions_send` for Caroline. No cross-agent communication.
- No new Muso API endpoints. No per-profile rollout-status data, no freshness timestamps from upstream.
- No in-app banner (product/frontend work, outside hydra).
- No implementation of `subscription_status`. The existing stub stays.
- No model change. Same model chain stays in `openclaw-edge.json`.

## Prerequisites (P0 — must land before anything else)

The runtime gap discovered in v2 review is the gating item. Two changes to `openclaw-edge.json`:

1. Add `"support-tools"` to `plugins.allow`.
2. Add `"/root/.openclaw-edge/extensions/support-tools"` to `plugins.load.paths`.

And one deploy-time guarantee: `deploy.sh` must copy `plugins/support-tools/` into `/root/.openclaw-edge/extensions/support-tools/` (verify it already does for the edge profile — the directory exists on disk, suggesting it does, but the load path is the missing piece).

**Verification gate:** before any of the new components below are considered done, a staging probe must show `profile_lookup`, `credits_search`, `subscription_status`, `create_ticket` registered for the support agent on edge — preferably by sending Caroline a test message asking what tools she has, or by introspecting the gateway's tool registry log line at startup.

The main-profile `openclaw-main.json` already has `support-tools` in `plugins.allow` but **not** in `plugins.load.paths` either — so main is in the same broken state. Whether to fix main as part of this PR depends on whether main currently serves any Caroline traffic. Currently main and edge both have a `support`-agent intercom binding for `accountId: "default"`, which is ambiguous; the live edge service handles intercom traffic (verified). Main's binding appears to be dead-code or fallback-only. Leave main's config alone in this PR unless intercom routing is being changed.

## Architecture

Everything lives inside the existing `support-tools` plugin and `workspaces/support/` plus a small extension to `plugins/intercom/src/` (sanitizer). No new services, no agent-to-agent wiring, no openclaw.json restructure beyond the prerequisites above and plugin tool registration.

```
intercom (existing)
  ↓
edge gateway (openclaw-gateway-edge.service, existing)
  ↓
support agent = Caroline (existing)
  ↓ tools (plugin-registered, isolated)
  ├─ profile_lookup       (existing, unchanged)
  ├─ credits_search       (existing, unchanged)
  ├─ subscription_status  (existing stub, unchanged)
  ├─ create_ticket        (existing — gains "analytics-followup" actionType)
  └─ profile_status       (NEW — bundles lookup + credits)
```

Caroline's deny list and isolation properties are unchanged. The new tool calls only Muso API endpoints already used by `profile_lookup` and `credits_search`.

## Component 1 — `profile_status` tool

**Purpose:** bundled read-only view of a customer's profile so Caroline can acknowledge specifics in one round-trip.

**Input:** one of (mutually exclusive, validated by the tool):
- `profile_url` (string) — full profile URL on `credits.muso.ai`, parsed for the UUID
- `profile_id` (string) — bare UUID
- `name` (string) — display name, resolved via the autocomplete-then-search fallback that `profile_lookup` already uses
- `email` (string) — customer's account email, used only as a search input

The tool accepts whichever signal Caroline has. If `email` is the input it is used to find the profile **and never returned in the output** (the existing PII filter strips emails; document this explicitly here). If more than one input is provided, `profile_id` > `profile_url` > `email` > `name` in precedence.

**Wraps:**
- `GET /api/c/v5/search/autocomplete` (fallback to `POST /api/c/v5/search`) for profile identification.
- `GET /api/c/v4/profile/{profileId}/credits` for the latest credits.

**Output shape:**

```json
{
  "found": true,
  "profile": {
    "id": "90b6866c-7026-…",
    "name": "Aasis Beats",
    "verified": true,
    "primary_role": "Producer",
    "credits_count": 142
  },
  "latest_credits": [
    { "track": "…", "release": "…", "role": "…", "date": "2026-05-08" },
    { "track": "…", "release": "…", "role": "…", "date": "2026-05-02" },
    { "track": "…", "release": "…", "role": "…", "date": "2026-04-30" }
  ],
  "latest_credit_date": "2026-05-08"
}
```

Top 3 credits **sorted by `release_date` descending** (explicit, not relying on the credits endpoint default order). If `release_date` is missing on a credit, fall back to credit-created timestamp; if both missing, drop it from the top-3. No stream counts (no reliable per-platform freshness data; quoting numbers risks contradicting the customer's own platform views).

**Failure shape (no exceptions, ever):**

| Scenario | Returns |
|---|---|
| Profile not found | `{ "found": false, "reason": "no_match" }` |
| Multiple matches | `{ "found": false, "reason": "multiple_matches", "matches": ["…", "…", "…"] }` |
| Muso API 5xx / timeout | `{ "found": false, "reason": "lookup_unavailable" }` |
| Tool-side rate-limit hit | `{ "found": false, "reason": "rate_limited" }` |
| Empty/bad input | `{ "found": false, "reason": "missing_input" }` |

**Structured-only — no text returns from this tool, ever.** No "please try again" string for rate-limit, no human-readable error messages, no exceptions. Caroline translates structured failures into customer-facing language per the SOUL Tool-Failure subsection.

**Limits:**
- Rate limit: 10/min per session (same as `profile_lookup`).
- PII filter: email, phone, address, payment details stripped — same filter as `profile_lookup`.

**Code location:** `plugins/support-tools/src/tools/profile-status.ts`, registered in `plugins/support-tools/src/index.ts`.

## Component 2 — `analytics-followup` ticket type (+ `create_ticket` return-shape refactor)

**Prerequisite refactor** (required by the new SOUL contract): `create_ticket` currently returns customer-facing English (`"Support request #123 created…"`, `"Unable to create a ticket right now. Please email support@muso.ai directly."`, `"You've already submitted requests this session…"`). These strings violate the new "no `ticket` word to customer, no email handoff" rules. Refactor all return paths to **structured JSON only**:

```json
// success
{ "submitted": true,  "ticket_id": "abc123", "sla": "48 hours", "action_type": "analytics-followup", "tier": 1 }
// transient failure
{ "submitted": false, "reason": "queue_busy" }
// rate-limit (was: "You've already submitted requests this session…")
{ "submitted": false, "reason": "rate_limited" }
// validation error
{ "submitted": false, "reason": "invalid_input", "field": "customerEmail" }
```

This refactor applies to ALL action types, not just `analytics-followup`. Existing skills that consume `create_ticket` output (`action-request`, `refund-retention`) must be updated to read the structured shape. Caroline composes the customer-facing reply from the structured fields per SOUL.

**SLA value comes from the tool, not from Caroline.** The tool returns the literal SLA string (e.g., `"48 hours"`); Caroline uses what the tool returned verbatim and does not translate it to "2 business days" on her own. If the product wants "2 business days" wording surfaced to customers, change `TIER_SLAS` in `create-ticket.ts` to `"2 business days"` and the change propagates consistently. **For this design we update `TIER_SLAS[1]` from `"48 hours"` to `"2 business days"`** so Caroline can faithfully relay it.

A new `actionType` in the existing `create_ticket` taxonomy. Drops cleanly into the existing ClickUp action-request machinery.

| Field | Value |
|---|---|
| `actionType` | `analytics-followup` |
| Tier | 1 (48 hours / 2 business days) |
| ClickUp list | `901000600160` (existing) |
| Tags | `hydra-action-request`, `tier-1`, `analytics-followup` |
| Priority | tier-1 default |

**Ticket body** uses the standard `---ACTION-REQUEST---` JSON block with required `details` keys:

```json
{
  "action_type": "analytics-followup",
  "approval_tier": 1,
  "customer_email": "…",
  "customer_profile_id": "…",
  "details": {
    "profile_url": "https://credits.muso.ai/profile/…",
    "latest_credit_date_on_file": "2026-05-08",
    "credits_count_on_file": 142,
    "what_customer_sees": "stuck at 5.3B streams since April 17–23",
    "pushback_signal": "asked for timing twice / asked for refund / persistent disagreement"
  },
  "conversation_summary": "…"
}
```

`pushback_signal` is free-text, for the human reviewer's benefit only — not enforced or validated.

**What Caroline says to the customer when she files it:**

> "I've flagged your profile to engineering so they can review yours specifically. You'll hear back within 2 business days."

She does NOT use the words "ticket", "ClickUp", "task", or "support@muso.ai".

**Existing rate-limit unchanged:** `create_ticket` is capped at 2 per session per 60-minute window. `analytics-followup` counts against the same cap.

**Code change scope:**
- Add `"analytics-followup": 1` to `TIER_MAP` in `plugins/support-tools/src/tools/create-ticket.ts`.
- Mention `analytics-followup` in the tool's `description`.
- Include `analytics-followup` in the ClickUp tags array.
- **Replace all `textResult("…english…")` returns with `textResult(JSON.stringify({…}))` structured shapes per the refactor above.**
- Update `TIER_SLAS[1]` from `"48 hours"` to `"2 business days"`.

~30 lines including the refactor (vs 10 if we hadn't found the text-return issue).

## Component 3 — SOUL.md + KB + secondary references

Surgical edits across multiple files in `workspaces/support/`. The "EXACTLY 4" / "4 tools" string appears in three places (`SOUL.md:73`, `TOOLS.md:3, 5`, `skills/refund-retention/SKILL.md:22`); all must be updated to "5" or the contract drifts again.

**(a) Tool-count references — update everywhere, not just SOUL.md**

- `SOUL.md` line 73: "EXACTLY 4 — nothing else" → "EXACTLY 5 — nothing else". Add the 5th entry for `profile_status` (text below).
- `TOOLS.md` lines 3 + 5: same substitution, plus add a `profile_status` section matching the existing per-tool format (wraps, returns, auth, rate-limit, parameters).
- `skills/refund-retention/SKILL.md` line 22: "the existing 4 tools (profile_lookup, credits_search, subscription_status, create_ticket)" → "the existing 5 tools (…, profile_status)".

The 5th-entry description (consistent across SOUL.md and TOOLS.md):
> "Bundled read-only view of a customer's profile — name, role, verified, credits count, and the latest 3 credits (sorted by release_date descending). Use this FIRST whenever a customer mentions analytics, streams, data freshness, or whether their account 'is working'."

Leave the existing 4 entries unchanged in content.

**(b) `SOUL.md` → "Contact Disclosure (CRITICAL)" section + code allowlist**

Docs-only change to SOUL.md is not enforcement. Two paired changes are required:

- **Code:** `plugins/intercom/src/sanitize-email.ts` — remove `"jan@muso.ai"` from the `ALLOWED_OUTBOUND_EMAILS` `Set`. Update `plugins/intercom/tests/sanitize-email.test.ts` to assert `jan@muso.ai` is now scrubbed to `support@muso.ai` and produces an `[intercom:email-leak]` audit row.
- **SOUL.md:** remove `jan@muso.ai` from the allowed-emails list. Keep `support@muso.ai` in the list but tighten the rule:
  > "You MUST NOT proactively share `support@muso.ai`. For every human-action need, use `create_ticket`. The ONLY situation in which mentioning `support@muso.ai` is permitted is when `create_ticket` itself returned a failure response (`submitted: false, reason != "rate_limited"`) in the current turn — and even then, prefer asking the customer to retry sending their message."

The deterministic outbound email filter (the wrapper class in `plugins/intercom/src/outbound.ts`) is unchanged in mechanism; only the allowlist content changes.

**(c) `reference/common-issues.md` → "Analytics not showing / streams not updating" section**

Replace the resolution path with:

1. First reply: call `profile_status` with whatever profile signal the customer has provided (URL, UUID, name, or email already in conversation context — never echo the email back). Acknowledge what you see — e.g., *"I'm looking at your profile right now — latest credit is `<track>` from `<date>`, showing `<N>` credits on file."* Then deliver the existing upgrade-in-progress message. Optionally offer to flag the profile.
2. If the customer accepts ("thanks", "ok", "got it"): close out. **No ticket.**
3. If the customer pushes back about **timing or data** (asks for timing again, expresses frustration about staleness, asks "are you actually checking", or "when will MINE update?"): call `create_ticket` with `actionType: "analytics-followup"`. Populate `details` with what `profile_status` returned (profile URL, latest credit date, credits count) and the customer's described symptom. Reply using the values from the tool's structured response — `"I've flagged your profile to engineering so they can review yours specifically. You'll hear back within <tool.sla>."`
4. **If the customer mentions a refund at any point — even tangentially ("I want my money back", "I'll cancel", "this isn't worth what I paid") — the `refund-retention` skill takes precedence over `analytics-followup`.** Run the existing 3-gate retention flow first; if retention ends with the customer still wanting out, the existing `subscription-refund` action-request path applies, not `analytics-followup`. Both can be filed in extreme cases, but refund precedence is enforced.
5. **Never tell the customer to email any address.** No `support@muso.ai`, no `jan@muso.ai`, no implication that the conversation needs to move channels.

**(d) `reference/common-issues.md` → footer "Never promise" list**

Add: *"Never recommend the customer email any Muso address. The ticket IS the escalation."*

Existing items in the list ("no specific timing", "no compensation", "no Apple Music data", "no feature parity") are unchanged.

## Pushback detection — model judgment, not a counter

We do not add a deterministic "count customer messages and trigger on N=2" mechanism. The signals in (c) step 3 above are prompt-level cues. Caroline's model is capable of recognizing "customer asked the same thing twice / mentioned refund / expressed frustration" reliably; a hard counter would break on edge cases ("thanks → actually one more thing" is not pushback). If post-deploy observation shows the model under-triggering, we tighten the prompt language. If it over-triggers, same. No code-level state.

## Error handling — three layers, no leakage to customer

The hard constraint: the customer never sees the words "tool", "lookup", "error", "unavailable", "system", "API", "ticket", or any variant of "I had trouble". Three independent layers enforce this.

**Layer 1 — tools never throw.**

`profile_status` returns the structured failure shape from Component 1. `create_ticket` already mostly returns rather than throws; the `analytics-followup` path adds no new failure modes but is re-verified during implementation. If ClickUp 5xx's, `create_ticket` returns `{ "submitted": false, "reason": "queue_busy" }`.

**Layer 2 — SOUL.md "Tool Failure" subsection** (new, inside existing "Response Patterns"):

- `profile_status: { found: false, reason: "no_match" }`: ask one focused follow-up — *"Can you share your Muso profile link or the email on your account?"* — and continue.
- `profile_status: { found: false, reason: "multiple_matches" }`: ask for the profile URL specifically.
- `profile_status: { found: false, reason: "lookup_unavailable" | "missing_input" }`: do NOT mention the lookup. Continue with the KB analytics answer; offer to flag the profile if the customer shares their link.
- `create_ticket: { submitted: false }`: do NOT mention the ticket. Say *"Let me get the team on this — could you email `support@muso.ai` with your profile link so we have it on record?"* This is the ONLY context in which `support@muso.ai` is appropriate.
- Forbidden words to the customer: "tool", "lookup", "error", "unavailable", "system", "API", "ticket".

**Layer 3 — deterministic outbound sanitizer in code (NOT just SKILL.md prose).**

The existing `workspaces/support/skills/output-sanitizer/SKILL.md` is prompt-level instructions — there is no code that runs its regex against outbound messages. The only mechanical outbound enforcement today is `plugins/intercom/src/outbound.ts` + `sanitize-email.ts`, which scrubs disallowed emails.

To make Layer 3 a real defense, extend the deterministic sanitizer:

- New file: `plugins/intercom/src/sanitize-tool-leak.ts` exporting `sanitizeOutboundBody(body: string): { body: string; redacted: string[] }`. Applies case-insensitive regex replacement to the outbound HTML body before `replyToConversation` (and any other body-carrying method) delegates to the inner client.
- Pattern list:
  - `\btool failed\b`, `\berror fetching\b`, `\bunable to look up\b`
  - `\bthe system says\b`, `\bmy system\b`, `\bthere was an issue with\b`
  - `\bcreate_ticket\b`, `\bprofile_status\b`, `\bprofile_lookup\b`, `\bcredits_search\b`, `\bsubscription_status\b`
  - `\bClickUp\b`, `\bopenclaw\b`, `\bHYDRA\b` (case-insensitive)
- Matches replaced with `[REDACTED]`; redacted list returned for audit logging as `[intercom:tool-leak] conv=<id> count=<n> redacted=[…]` (mirrors the existing `[intercom:email-leak]` pattern).
- Wire into `SanitizingIntercomClient` alongside the existing email sanitizer — both run on every outbound body. New tests in `plugins/intercom/tests/sanitize-tool-leak.test.ts`.

The `output-sanitizer/SKILL.md` document remains as prompt-level guidance for Caroline (so she avoids producing these strings in the first place), but is no longer relied on as enforcement. We DO also extend its blocklist for consistency, but the load-bearing layer is the new sanitizer module.

## Testing

Plugin is tested with vitest, matching the existing pattern.

**New test file: `plugins/support-tools/tests/profile-status.test.ts`**
- happy path: returns bundled shape with `found: true` and correct fields
- missing input → `{ found: false, reason: "missing_input" }`
- no profile match → `{ found: false, reason: "no_match" }`
- multiple matches → returns top-3 names array
- upstream 5xx → `{ found: false, reason: "lookup_unavailable" }`, no throw
- upstream timeout → same shape, no throw
- rate-limit triggered → returns standard rate-limit message, no throw
- PII filter: email/phone/payment never appear in output even if upstream returns them

**Updates to `plugins/support-tools/tests/create-ticket.test.ts`:**
- `getTierForAction("analytics-followup")` returns 1
- ticket description includes `"action_type": "analytics-followup"` and `"approval_tier": 1`
- ClickUp call payload includes the `analytics-followup` tag

**Updates to `plugins/support-tools/tests/index.test.ts`:**
- verify `profile_status` registered with correct name, params shape, and description
- verify tool count is 5 (was 4)

**New file: `plugins/intercom/tests/sanitize-tool-leak.test.ts`** — unit tests for the deterministic tool-leak sanitizer:
- *"My system couldn't find your profile"* → `[REDACTED]` + audit log row
- *"There was an error fetching your data"* → redacted
- *"Let me create a ticket"* → redacted (`create_ticket` matches in token form too, but plain English "create a ticket" — match `\bticket\b`? No: that's too aggressive given the word's broader meaning. We rely on the SOUL rule plus the explicit `create_ticket` token. Spell out tradeoff in the test rationale.)
- *"I've flagged your profile to engineering"* → passes through unchanged
- *"openclaw"* anywhere → redacted
- audit log message format matches `[intercom:tool-leak] conv=<id> count=<n> redacted=[…]`

**Updates to `plugins/intercom/tests/sanitize-email.test.ts`:**
- assert `jan@muso.ai` is now scrubbed (was previously allowed)
- assert audit log row fires for the new scrub case

**Tool-registration smoke test (gating — must pass before any other smoke test runs):**
0. Restart `openclaw-gateway-edge.service` after deploy.
1. Grep the edge journal at startup for a tool-registration line that lists all 5 support tools (`profile_lookup`, `credits_search`, `subscription_status`, `create_ticket`, `profile_status`). If the gateway does not emit such a line, send Caroline a test message asking "what tools do you have?" via the `support` Slack channel and confirm she names all 5. **If this gate fails, the support-tools plugin is not loading; stop and fix `openclaw-edge.json` before continuing.**

**End-to-end smoke test (post-deploy):**
1. Open intercom widget on a staging account (or DM Caroline in the `support` Slack channel).
2. Send "my analytics aren't updating" with a known profile email/URL.
3. Confirm Caroline calls `profile_status` (verify in gateway log), mentions the latest credit date, gives the KB answer, optionally offers to flag.
4. Push back about timing: "when will MINE update?"
5. Confirm Caroline calls `create_ticket` with `actionType=analytics-followup` and replies with the "flagged your profile to engineering / 2 business days" line (or whatever `tool.sla` returned).
6. Verify the resulting ClickUp task lands in list `901000600160` with tags `hydra-action-request`, `tier-1`, `analytics-followup`, and a valid JSON block.
7. Verify no leakage strings in the rendered customer-facing reply (curl the intercom conversation parts and grep for forbidden phrases).
8. Repeat the flow but mention a refund mid-conversation. Confirm `refund-retention` takes precedence — Caroline runs the 3-gate flow rather than filing `analytics-followup`.

No production load-testing required — analytics volume is ~55/month, well under existing rate-limit envelopes.

## Rollout

**Single PR, no feature flag.** Scope is small and isolated. A feature flag would add complexity for a change reversible in one commit.

- Branch: `feat/caroline-cs-agent-brainstorm` → spec PR. Implementation in a follow-up branch.
- Suggested commit order inside the implementation PR (makes rollback cleaner):
  1. **P0 prerequisite: enable support-tools on edge.** `openclaw-edge.json` adds `support-tools` to `plugins.allow` and `/root/.openclaw-edge/extensions/support-tools` to `plugins.load.paths`. Verify `deploy.sh` copies the plugin into the edge profile dir. Restart edge gateway and confirm tool-registration smoke test passes (Caroline names 5 tools).
  2. `plugins/support-tools/src/tools/create-ticket.ts` refactor to structured returns + new `analytics-followup` actionType + `TIER_SLAS[1] = "2 business days"`. Update consumers (`action-request`, `refund-retention` skills) to parse structured shape.
  3. `plugins/support-tools/src/tools/profile-status.ts` new tool + registration in `index.ts` + tests.
  4. `plugins/intercom/src/sanitize-email.ts` allowlist update (remove `jan@muso.ai`) + tests.
  5. `plugins/intercom/src/sanitize-tool-leak.ts` new sanitizer + wire into `SanitizingIntercomClient` + tests.
  6. SOUL.md + TOOLS.md + reference/common-issues.md + refund-retention/SKILL.md edits (tool count, contact disclosure, analytics resolution path, refund precedence).
- Deploy via existing `deploy.sh` path. Re-verify `deploy.sh` writes to the profile-specific edge path and not the legacy `/root/.openclaw/extensions/` path (known historical drift).
- Reload `openclaw-gateway-edge.service` after deploy.
- **Do not merge until the tool-registration smoke test passes on staging.**

## Observability

Three signals to watch in the first week. All exist already; no dashboard work.

| Signal | Source | Healthy reading |
|---|---|---|
| `profile_status` call rate | gateway logs, edge service journal | called on most analytics-themed conversations |
| `analytics-followup` ticket count | ClickUp list `901000600160`, filter by tag | 5–20/week (subset of ~55/mo analytics convos that escalate); zero would mean the trigger isn't firing |
| Email-leak audit entries | existing `[intercom:email-leak]` audit log | trending toward zero; any non-zero counts mean the SOUL rule is being bypassed |

If after two weeks the numbers look off, revisit. No commitment to building dashboards in this design.

## Rollback

Independent revert paths, by component:

- **Plugin (new tool):** remove `profile_status` from the plugin's exported tool list (one-line revert in `index.ts`), redeploy edge. Caroline returns to 4 tools.
- **SOUL.md / KB edits:** `git revert` the SOUL+KB commit. Plugin stays in place (harmless on its own).
- **`create_ticket` regression:** revert the `analytics-followup` taxonomy entry. Drops back to the existing 10 actionTypes. Any tickets already in ClickUp persist; no data loss.

Splitting the implementation into separate commits (per Rollout above) makes per-component revert clean.

## References

- Predecessor spec: [2026-05-08-caroline-analytics-knowledge-base-design.md](2026-05-08-caroline-analytics-knowledge-base-design.md)
- Existing intercom-handoff design: [2026-04-02-intercom-handoff-persistence-design.md](2026-04-02-intercom-handoff-persistence-design.md)
- Live edge gateway config: `openclaw-edge.json` (agent `support`, intercom binding `default`)
- Plugin source: `plugins/support-tools/`
- Sanitizer source: `plugins/intercom/src/outbound.ts`, `sanitize-email.ts`
- Caroline workspace: `workspaces/support/`
- ClickUp list: `901000600160` (existing action-request queue)

## Revision History

**v2 (2026-05-11) — after Clio review.** Five hard blockers and five design fixes incorporated, all verified against live state on hydra before acceptance:

1. **Support-tools plugin not loaded on edge** (root cause). v1 assumed Caroline already had 4 working tools; live `openclaw-edge.json` proves she has zero. Added Prerequisites section; tool-registration smoke test is now a gating step.
2. **Sanitizer was email-only.** v1 proposed "extend the SKILL.md regex"; that's prompt-only, not enforcement. v2 adds `plugins/intercom/src/sanitize-tool-leak.ts` as a real outbound sanitizer module wired into `SanitizingIntercomClient`.
3. **`jan@muso.ai` is in code, not just docs.** v1 only updated SOUL.md. v2 removes it from `ALLOWED_OUTBOUND_EMAILS` in `sanitize-email.ts` with corresponding test updates.
4. **`create_ticket` returns customer-facing text containing "ticket" and routes to email on failure.** v1 missed this. v2 refactors all `create_ticket` returns to structured JSON; Caroline composes customer wording from structured fields. Existing consumer skills (`action-request`, `refund-retention`) updated accordingly.
5. **Profile_status rate-limit contradiction.** v1 testing section said "standard rate-limit message"; tool contract is now structured-only — rate-limit returns `{ found: false, reason: "rate_limited" }`.

Design fixes:
- SLA language: `TIER_SLAS[1]` changed from `"48 hours"` to `"2 business days"` so Caroline relays the tool's literal value rather than inventing one.
- Sort order for `latest_credits` made explicit: `release_date` descending, with documented fallback.
- Profile_status input contract made explicit: URL / UUID / name / email, with precedence and a never-echo-email rule.
- Tool-count references audited: `SOUL.md:73`, `TOOLS.md:3,5`, `skills/refund-retention/SKILL.md:22` all need updating.
- Refund-retention precedence: customer mentioning refund routes through the existing 3-gate retention skill before `analytics-followup` can fire.
