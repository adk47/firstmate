# CS Experience Overhaul — Design Spec

**Date:** 2026-04-21
**Author:** Nick (with Aaron)
**Branch:** `fix/cs-agent-email-guardrail`
**Context:** Aaron flagged deteriorating customer service on 2026-04-21. A 30-day audit of Intercom (1,974 conversations, 2026-03-22 → 2026-04-21) found that 55% of inbound conversations never receive an admin reply, Caroline (our CS AI) hallucinates "ticket created" in 98% of cases, no CSAT data is being collected, and the Slack escalation path covers <2% of situations that should trigger it. This spec is the response.

## Goals
1. Stop Caroline from lying about ClickUp tickets.
2. Remove Intercom's "⚠️ ✉️ Message failed" tombstones from customer view, root cause + recovery.
3. Auto-escalate to a human on explicit request, cancel/refund intent, frustration, and stuck loops.
4. Collect CSAT, triage the unanswered backlog, and give Aaron a hard churn number.

## Non-goals
- Replacing Intercom or Caroline.
- Building the Credit-Verification self-serve flow (19% of support volume) — scoped separately as a future spec.
- Enforcing SLAs via paging/auto-assignment (we start with visibility; enforcement is follow-up).
- Re-architecting the openclaw plugin system.

## Success metrics
Tracked in a weekly `#cs-escalations` digest starting Phase 1 week 2:

| Metric | Baseline (30d audit) | Target |
|---|---|---|
| % Caroline replies claiming a ticket that include a real ClickUp ID | 2% | 100% |
| "⚠️ ✉️ Message failed" tombstones visible to customers / week | ~8–10 | 0 |
| % escalation-worthy conversations actually escalated to Slack | <2% | >90% |
| % conversations with customer reply in human-reply path within 24h | ~45% | >70% |
| % conversations closed with a CSAT rating | 0% | >30% (after Phase 2) |
| Net cancellations among unanswered-thread cohort (monthly) | unknown | measured + decreasing |

## Phases

Each phase is independently shippable. Phase 1 is the "stop the bleed" week; Phase 2 builds the trust layer; Phase 3 is structural.

### Phase 1 — Stop the bleed (week 1)

#### 1A. Ticket-honesty enforcement

Caroline can only say "ticket created" after `create_ticket` returns a real ClickUp task ID. We enforce this via the openclaw SDK's **plugin hook system**, not via a session-state field.

**Architecture — hook-based evidence passing**

The openclaw SDK exposes `api.registerHook(name, handler)` with the relevant hooks:
- `after_tool_call` — fires when any tool completes; event = `{toolName, params, result, error, durationMs}`; context = `{sessionKey, agentId, toolCallId}`
- `message_sending` — fires before outbound delivery; event = `{to, content, metadata}`; context = `{sessionKey, channelId}`; handler can return `{content: rewrittenBody}` to modify or `{cancel: true}` to suppress

`sessionKey` is the stable identifier both hooks share within a single agent turn. That's how the Intercom plugin can correlate "did `create_ticket` just succeed?" with "Caroline is about to send this reply."

**Implementation**

New module `plugins/intercom/src/ticket-evidence-store.ts`:
```ts
// Module-local, short-TTL cache keyed by sessionKey
// Written by the after_tool_call hook; read + cleared by the message_sending hook.
type TicketEvidence = { ticketId: string; createdAt: number };
const TTL_MS = 120_000;
const store = new Map<string, TicketEvidence>();

export function recordTicketCreated(sessionKey: string, ticketId: string): void;
export function consumeTicketEvidence(sessionKey: string): TicketEvidence | null;
export function clearForSession(sessionKey: string): void; // called on inbound webhook
```

New module `plugins/intercom/src/ticket-claim-sanitizer.ts`:
```ts
export function sanitizeTicketClaim(
  body: string,
  evidence: TicketEvidence | null,
): { body: string; action: "pass" | "inject_id" | "rewrite"; reason?: string };
```

Logic:
1. If body contains no claim phrase → `pass`.
2. If claim phrase present AND evidence is null → `rewrite` to the safe fallback template and log `[intercom:ticket-hallucination]` to `#cs-escalations`.
3. If claim phrase present AND evidence is non-null → `inject_id` (append `\n\nReference: \`${ticketId}\`` to the reply if the ID isn't already there) and pass.

`TICKET_CLAIM_PATTERNS` (case-insensitive, EN+ES):
- `ticket (created|submitted|opened|raised)`
- `i('ve| have) (created|submitted|opened|raised) (a|your) (support )?ticket`
- `creating a (support )?ticket`
- `i('ll| will) (create|submit|open|raise) a (support )?ticket`
- `escalat(ed|ion) (created|submitted)`
- `flagg(ed|ing) (this|it) (with|for) (our|the) team`
- `forwarded (this|it|them) to (our|the) team`
- `ticket (creado|enviado|abierto)`
- `he (creado|enviado|abierto) un ticket`

Safe fallback template:
> "I've noted your request. Please email support@muso.ai with your conversation link so our team can follow up directly."

**Wiring (in `plugins/intercom/src/index.ts`)**

```ts
api.registerHook("after_tool_call", async (event, ctx) => {
  if (event.toolName !== "create_ticket") return;
  if (event.error || !event.result) return;
  const parsed = tryParseTicketResult(event.result); // handles the textResult JSON shape
  if (!parsed?.ticketId || !ctx.sessionKey) return;
  recordTicketCreated(ctx.sessionKey, parsed.ticketId);
});

api.registerHook("message_sending", async (event, ctx) => {
  if (ctx.channelId !== "intercom") return;
  if (!account.ticketClaimSanitizerEnabled) return; // feature flag
  const evidence = ctx.sessionKey ? consumeTicketEvidence(ctx.sessionKey) : null;
  const { body, action, reason } = sanitizeTicketClaim(event.content, evidence);
  if (action === "rewrite") {
    logger.warn(`[intercom:ticket-hallucination] sessionKey=${ctx.sessionKey} reason=${reason}`);
    postToCsEscalationsSlack({ kind: "ticket_hallucination", original: event.content, ctx });
    return { content: body };
  }
  if (action === "inject_id") return { content: body };
  // "pass" → no return = unchanged
});
```

**Inbound-clearing (in `plugins/intercom/src/handler.ts`)**
On each inbound `conversation.user.replied` webhook, call `clearForSession(sessionKey)` before dispatching to the agent. This scopes evidence strictly to the in-flight agent turn and prevents stale ticket IDs from leaking into the next customer turn. TTL is a secondary safeguard.

**Full-body rewrite tradeoff.** The sanitizer replaces the *entire* reply when it triggers, even if the reply had useful content beyond the hallucinated claim. Accepted for v1 (safer, simpler). Follow-up: sentence-level redaction if the false-positive Slack feed shows good content being lost at scale.

**Supporting instruction-layer changes** (not enforcement, just alignment):
- Rewrite `workspaces/support/SOUL.md` and `workspaces/support/skills/action-request/SKILL.md` customer-communication templates so every ticket-claim phrase includes a `${ticket_id}` placeholder filled from the tool return value. If Caroline followed SOUL.md perfectly, the sanitizer would never fire. The sanitizer is the belt; SOUL.md is the suspenders.

**Feature flag.** `account.ticketClaimSanitizerEnabled: boolean` (default `true`). Set to `false` in `openclaw.json` to disable the sanitizer without redeploy. Hook remains registered but becomes a no-op when the flag is false.

**Tests**
- Unit (sanitizer): each claim phrase with null evidence → rewrite; with valid evidence → inject_id only if body lacks ID; no claim phrases → pass.
- Unit (evidence store): record + consume round-trip; TTL expiry; clearForSession wipes entry.
- Integration: simulated `after_tool_call` → `message_sending` sequence with the real sessionKey shape; ensures evidence flows correctly.
- Integration: replay harness with a recorded hallucination conversation from the 30-day audit; sanitizer must rewrite.

#### 1B. "Message failed" detection + auto-recovery

Facts verified against live data (conversation `215473603897368` on 2026-04-01):
- Intercom renders delivery failures as a regular conversation part with `part_type="comment"`, `author.type="bot"`, `author.id` = bot admin ID, and literal `body = "⚠️ ✉️ Message failed"`.
- No distinct webhook topic. We subscribe to `conversation.admin.single.created` (already subscribed) and the existing webhook ingress path.

**Design**
Extend `plugins/intercom/src/handler.ts` with a `delivery-failure` branch. When a webhook event arrives and the new part satisfies:

```
part.part_type == "comment"
AND part.author.id == account.botAdminId
AND normalize(part.body) starts with "⚠️ ✉️ Message failed"
```

then:
1. Emit `[intercom:delivery-failed] conv=<id>` log.
2. Post a structured Slack alert to `#cs-escalations` with category `delivery_failed` and a link to the conversation.
3. **Retry guards** (protects against the race where the customer has sent a follow-up that already produced a fresh reply):
   - `state.lastOutboundText` must still equal the message we believe failed.
   - `state.lastOutboundAt` must be within 60 seconds of the failure event's `created_at`.
   - `state.deliveryRetryCount` must be 0 for this outbound (capped at 1 retry per turn).
   - If any guard fails → log `[intercom:delivery-failed-stale]`, post a context-only Slack notice (no retry), and stop. The failure is recorded for ops visibility but not acted on.
4. If all guards pass, retry the original bot reply once via `SanitizingIntercomClient.replyToConversation` with the cached body re-run through the sanitizer chain. Increment `state.deliveryRetryCount` atomically.
5. If retry succeeds, done.
6. If retry also fails (detected by another `Message failed` tombstone arriving within 30s, tracked in session state), post a short customer-facing message: *"We're having a temporary issue delivering our reply. A human will follow up with you shortly."* Then force-escalate the thread (reassign + Slack alert with category `delivery_failed_retried`).

**Webhook-or-poll fallback.** If Intercom does not deliver `conversation.admin.single.created` for the failed-delivery tombstone (to be verified during implementation), the fallback is **not** per-outbound polling (expensive). Instead:
- **Primary fallback:** scan for tombstones on every *next-inbound* webhook for the same conversation (free, opportunistic).
- **Secondary fallback:** a lightweight cron (`scripts/cs-delivery-sweep.py`, runs every 15 min) queries open conversations updated in the last 30 min and inspects the tail parts for tombstones. Catches conversations where the customer never replied again.

**State additions** (`plugins/intercom/src/types.ts`)
- `IntercomSessionState.lastOutboundText: string | null` — body most recently sent by Caroline.
- `IntercomSessionState.lastOutboundAt: string | null` — ISO timestamp of the most recent outbound.
- `IntercomSessionState.deliveryRetryCount: number` — capped at 1 per outbound; reset when `lastOutboundText` is overwritten.
- `IntercomSessionState.turnCount: number` — increments on each successful Caroline outbound; used by the auto-handoff floor (2D).
- `IntercomSessionState.lastResolutionTurnCount: number | null` — turn number at which a `create_ticket` success was recorded.
- `IntercomSessionState.language: "en" | "es" | null` — set by 2B.
- `IntercomSessionState.backfilledAt: string | null` — idempotency flag for 1F.

Note: `lastTicketCreatedId` is **not** added to IntercomSessionState. Ticket evidence flows via the in-memory hook store (1A) with a short TTL, not through disk-persisted session state.

**Migration.** Existing on-disk sessions won't have the new fields. Read with nullish-coalescing defaults (`state.turnCount ?? 0`, etc.). No one-shot migration needed — fields populate lazily on first webhook.

**Tests**
- Unit: handler receives webhook with failed-delivery part → identifies it, triggers retry.
- Unit: retry succeeds → no escalation.
- Unit: retry also fails (second tombstone within 30s window) → customer-facing recovery message + force-escalate.
- Integration: replay a recorded failed-delivery webhook payload end-to-end.

#### 1C. Escalation rule expansion

Extend `plugins/intercom/src/escalation.ts` with four new categories. Keep the existing `EscalationRule` shape — no plumbing changes.

```ts
const ESCALATION_RULES: EscalationRule[] = [
  // existing: billing, legal, security, abuse
  {
    category: "human_request",
    patterns: [
      /\b(speak|talk) to (a )?(human|real person|agent|representative)\b/i,
      /\bmanager\b/i,
      /\bsupervisor\b/i,
      /\bhablar con (una )?(persona|agente)\b/i,
      /\bpersona real\b/i,
      /\bagente real\b/i,
    ],
  },
  {
    category: "cancel_churn",
    patterns: [
      /\b(cancel|unsubscribe|stop billing|stop charging)\b/i,
      /\bmy subscription\b.*\bcancel\b/i,
      /\b(cancelar|darme de baja|dar de baja|me doy de baja)\b/i,
    ],
  },
  {
    category: "refund_dispute",
    patterns: [
      /\brefund\b/i,
      /\bdispute (the|my|this) charge\b/i,
      /\bmoney back\b/i,
      /\b(reembolso|devoluci[oó]n del dinero|chargeback)\b/i,
    ],
  },
  {
    category: "frustration",
    patterns: [
      /\b(frustrat(ed|ing)|useless|ridiculous|unacceptable|worst|terrible|awful)\b/i,
      /\b(scam|fraud|estafa|fraude)\b/i,
      // profanity is covered by existing content filters; we don't duplicate them
    ],
  },
];
```

Precedence rule (added to `checkEscalation`): iterate categories in order (billing → legal → security → abuse → human_request → cancel_churn → refund_dispute → frustration). First match wins. Explicit human-request and cancel_churn take precedence over frustration because the response templates differ. Revenue-critical categories (cancel_churn, refund_dispute, billing) reassign to the team immediately; frustration gets one grace turn from Caroline before handoff (implemented in 1E).

**Tests**
- Unit: 5 positive + 5 negative fixtures per category, drawn from real conversations in the 30-day audit (e.g., "me doy de baja" should match `cancel_churn`; "I want to cancel the order" should match; "cancel this reservation" in an unrelated context — we accept this false positive since it's a tiny population and safer to escalate than silent-bot).

#### 1D. Stuck-loop detection (simplified)

New module `plugins/intercom/src/stuck-loop-detector.ts`. Called once per inbound webhook.

```ts
export function isStuckLoop(state: IntercomSessionState, conversation: IntercomConversation): boolean {
  const stats = conversation.statistics ?? {};
  if ((stats.count_reopens ?? 0) >= 2) return true;

  // 3+ consecutive customer messages without any admin reply — but only
  // after the bot/human has already replied at least once in this thread.
  // This avoids false-positives on the "hi / hello / are you there?" burst
  // pattern at the start of a brand-new conversation.
  const hasAnyAdminReply =
    (stats.time_to_admin_reply ?? null) !== null || (state.turnCount ?? 0) > 0;
  if (!hasAnyAdminReply) return false;

  const parts = conversation.conversation_parts?.conversation_parts ?? [];
  const consecutiveUserMsgs = countTrailingUserMessages(parts);
  if (consecutiveUserMsgs >= 3) return true;

  return false;
}

// "User message" = part whose author.type === "user" AND part_type is one of
// ["comment", "quick_reply"]. Excludes `open`, `close`, `assignment`, and
// other system parts.
function countTrailingUserMessages(parts: IntercomConversationPart[]): number;
```

No TF-IDF, no intent clustering, no semantic similarity. If this underfires we revisit; simple first.

On detection: emit a Slack notification with category `stuck_loop` but do NOT auto-handoff (ops reads it and decides). This avoids churning long threads that are genuinely progressing.

#### 1E. Consolidated Slack channel
Single webhook for `#cs-escalations`, set on `account.fallbackSlackSupervisionChannel` (already supported). Every category (existing + new) posts there. `slack.ts`'s block builder gets a category badge and a color mapping:

- `billing` / `refund_dispute` → red
- `legal` → purple
- `security` / `abuse` → orange
- `human_request` / `cancel_churn` → yellow
- `frustration` / `stuck_loop` / `delivery_failed` → gray

No Slack routing logic; one channel, one audience.

#### 1F. Backfill sweep for existing unanswered threads
One-shot script `scripts/cs-backlog-sweep.py`. On Phase 1 deploy day:
1. Query Intercom for all currently-open conversations created in the last 30 days with `statistics.time_to_admin_reply = null`. (610 at time of spec.)
2. For each, run the new `checkEscalation` + `isStuckLoop` logic on the conversation body.
3. Emit a single Slack digest to `#cs-escalations` with the triaged list grouped by category, age, and priority. Ops team clears it manually over the next week.

Not cron'd. One-time. Idempotent (uses a session-state flag `backfilledAt` so subsequent runs skip already-triaged conversations).

### Phase 2 — Trust & transparency (weeks 2–3)

#### 2A. CSAT collection

**Owner + timing:** Nick enables Intercom's built-in conversation-rating prompt on close in the Intercom admin UI on the Monday of week 2. This is a settings toggle, not code.

Add `scripts/cs-csat-digest.py` + `cron-jobs.json` entry: daily 09:00 local post to `#cs-escalations` with the last 24h CSAT distribution, remark count, and any 1-star ratings linked for ops review.

**Weekly metrics digest** (covers success-metrics reporting for all phases): `scripts/cs-metrics-digest.py` runs every Monday 09:15 local. Joins Intercom conversation data (last 7 days) with ClickUp tasks and emits a Slack roll-up of the six success metrics from the top of this spec. Baseline numbers shipped with the script so trend is visible from week 1.

#### 2B. Language pinning
Extend `IntercomSessionState` with `language: "en" | "es" | null`. On first inbound message, run a lightweight detect (existing `language_detection_details` part that Intercom already emits is authoritative — prefer that over our own detection). On subsequent turns, prepend a single-line system instruction to Caroline: `Respond only in ${language}.`

No mid-thread code-switching. If the customer switches languages mid-thread, the pinned language stays — Caroline acknowledges politely in the pinned language. Escape hatch: if the user explicitly says "respond in English/Spanish", we update `state.language`.

#### 2C. Unassigned-queue digest
`scripts/cs-backlog-digest.py` + cron entry. Daily 09:30 local. Posts a Slack summary of currently-open conversations with no admin reply, grouped by age bucket (0–24h, 1–3d, 3–7d, >7d) and by inferred category (run `checkEscalation` on each). Visibility only — no auto-paging.

#### 2D. Auto-human-handoff safety net

**Turn definition.** `state.turnCount` increments on each *successful* Caroline-authored outbound reply (confirmed message ID returned from `replyToConversation`). It does not increment on dropped/failed deliveries. This is the authoritative counter.

**Handoff rule.** When Caroline is about to generate her Nth reply (default N=4), check whether a resolution has occurred this conversation: `state.lastResolutionTurnCount !== null`. If no resolution: force-escalate with category `stalled_bot_thread` before the reply is generated, reassign, and post to Slack.

**Resolution marker.** A successful `create_ticket` tool call with a real ClickUp ID. Written by the `after_tool_call` hook (1A) — when the hook records ticket evidence, it also sets `state.lastResolutionTurnCount = state.turnCount`. No NLP-based "thanks/solved" detection (too brittle across languages and phrasing).

**Precedence.** Explicit escalation triggers from 1C (`human_request`, `cancel_churn`, `refund_dispute`, `frustration`) fire FIRST if matched on the inbound message. The auto-handoff floor is the safety net, not the primary path. Order:
1. Inbound webhook arrives → `checkEscalation(body)` (1C).
2. If category matches → escalate, done.
3. Else → `isStuckLoop()` check (1D); if stuck → Slack alert (ops decides, no forced handoff).
4. Else → turn counter check (2D); if turnCount ≥ N without resolution → force-escalate with `stalled_bot_thread`.
5. Else → dispatch to Caroline as normal.

**Tuning.** N=4 is the starting value. Measured via the weekly metrics digest (N2): if `stalled_bot_thread` fires too often on genuinely-progressing threads, raise N. If it fires too rarely and customers are stuck in 5+ turn loops, lower N.

### Phase 3 — Structural (month 2)

#### 3A. Churn-cohort analysis (one-shot)
Standalone script `scripts/churn-cohort.py`. Not part of the infra plan — lives in this doc only as the terminal output. Cross-references:
- 30-day unanswered-thread customer list (from Intercom)
- 30-day cancel/refund-intent customer list (from Intercom, same new escalation classifier)
- Subscription table (via existing muso-api access)

Outputs: (a) count of actual cancellations in each cohort, (b) revenue lost, (c) a scatter correlating "days to first admin reply" vs. "cancellation within 14 days." One-page PDF to Aaron.

Will be spec'd separately in its own small doc.

#### 3B. Credit-Verification self-serve flow (separate spec)
Placeholder. 19% of support volume (369 threads/month) is credit verification. Needs its own design doc + customer research. Not in scope for this overhaul.

## Architecture diagram

```
Customer inbound message
    │
    ▼
[webhook: conversation.user.replied / conversation.admin.single.created]
    │
    ▼
handler.ts (webhook handler)
    │
    ├─ (A) clearForSession(sessionKey) in ticket-evidence-store      [1A]
    │
    ├─ (B) if part is from bot AND body starts with "⚠️ ✉️ Message failed"
    │        → delivery-failure branch (retry-guarded)                [1B]
    │
    ├─ (C) checkEscalation(body) — first matching category wins     [1C]
    │        → if match: ack + reassign + Slack, stop
    │
    ├─ (D) isStuckLoop(state, conversation)                          [1D]
    │        → if stuck: Slack alert, no forced handoff
    │
    ├─ (E) turnCount >= N AND lastResolutionTurnCount == null        [2D]
    │        → force-escalate with category stalled_bot_thread, stop
    │
    └─ (F) dispatch to Caroline agent
            │
            ▼
       [openclaw SDK: agent turn]
            │
            ├─ agent calls create_ticket tool (if applicable)
            │        │
            │        ▼
            │   after_tool_call hook fires                            [1A]
            │        │
            │        └─→ ticket-evidence-store.recordTicketCreated(sessionKey, ticketId)
            │            state.lastResolutionTurnCount = state.turnCount
            │
            ├─ agent produces reply text
            │
            ▼
       [openclaw SDK: outbound send]
            │
            ├─ message_sending hook fires                             [1A]
            │        │
            │        └─→ consume evidence, run ticket-claim-sanitizer
            │            action = pass / inject_id / rewrite
            │            (returns {content: ...} to modify body)
            │
            ▼
       attachedResults.sendText({to, text, ...})
            │
            ▼
       SanitizingIntercomClient (existing email guardrail)
            │
            ▼
       RealIntercomClient.replyToConversation
            │
            ▼
       Intercom delivery
            │
            ▼  (on failure)
       "⚠️ ✉️ Message failed" part arrives via next webhook
            │
            └─→ re-enters handler.ts at branch (B) above
```

## Components summary

| File | New/Changed | Phase | Responsibility |
|---|---|---|---|
| `plugins/intercom/src/ticket-evidence-store.ts` | new | 1A | In-memory `sessionKey → ticketId` store with short TTL |
| `plugins/intercom/src/ticket-claim-sanitizer.ts` | new | 1A | Pure function: body + evidence → pass / inject_id / rewrite |
| `plugins/intercom/src/index.ts` | changed | 1A | Register `after_tool_call` + `message_sending` SDK hooks |
| `plugins/intercom/src/handler.ts` | changed | 1B, 1D, 2B, 2D | Delivery-failure branch, stuck-loop check, language detect, turn counter, handoff floor, inbound evidence clear |
| `plugins/intercom/src/escalation.ts` | changed | 1C | +4 rule categories with EN+ES regex, precedence rule |
| `plugins/intercom/src/stuck-loop-detector.ts` | new | 1D | Reopens OR consecutive-user-msgs, gated on prior-admin-reply |
| `plugins/intercom/src/slack.ts` | changed | 1E | Category badge + color for new categories |
| `plugins/intercom/src/types.ts` | changed | 1B, 2B, 2D | `+lastOutboundText, +lastOutboundAt, +deliveryRetryCount, +turnCount, +lastResolutionTurnCount, +language, +backfilledAt` |
| `workspaces/support/SOUL.md` | changed | 1A | Soft: require `${ticket_id}` in all ticket templates |
| `workspaces/support/skills/action-request/SKILL.md` | changed | 1A | Soft: reinforce tool-return-ID contract |
| `scripts/cs-backlog-sweep.py` | new | 1F | One-shot: triage existing 610 unanswered threads |
| `scripts/cs-delivery-sweep.py` | new | 1B | 15-min cron: catch failed-delivery tombstones on quiet threads |
| `scripts/cs-metrics-digest.py` | new | 2 | Weekly metrics roll-up to #cs-escalations |
| `scripts/cs-csat-digest.py` | new | 2A | Daily CSAT summary |
| `scripts/cs-backlog-digest.py` | new | 2C | Daily unanswered-queue summary |
| `scripts/churn-cohort.py` | separate spec | 3A | Not in this plan |
| `cron-jobs.json` | changed | 1B, 2 | Register delivery sweep + daily digests + weekly metrics jobs |

**Pre-commit lint:** no new rule needed. The existing rule blocking direct `RealIntercomClient` construction already keeps all outbound through `createIntercomClient()` (the email-guardrail chain). The ticket-claim sanitizer rides on the SDK `message_sending` hook (1A) and is independent of the client-construction path, so it has no bypass surface to lint against.

**Python conventions:** all new Python scripts use `uv` for dependencies and `ruff` for lint/format, per CLAUDE.md.

**Session-state migration:** existing on-disk sessions won't have the new fields. Read with nullish-coalescing defaults (`state.turnCount ?? 0`, etc.). No one-shot migration needed — fields populate lazily on first webhook.

## Error handling

| Failure | Response |
|---|---|
| Ticket-claim sanitizer rewrites a legitimate reply | Slack alert with original body + conversation URL; feature flag `ticketClaimSanitizerEnabled=false` hot-disables per account |
| Delivery retry guards fail (stale / race) | Log `[intercom:delivery-failed-stale]` + Slack notice (context only); no retry; ops decides |
| Delivery retry also fails | Customer-facing recovery message + force-escalate with category `delivery_failed_retried` |
| ClickUp API down when `create_ticket` called | Existing fallback in action-request skill: "please email support@muso.ai" (no change). `after_tool_call` hook receives `event.error`; no evidence recorded; sanitizer correctly blocks any ticket claim |
| `after_tool_call` hook fires but `sessionKey` is undefined | Log warning; do not record evidence; downstream sanitizer treats as "no evidence" and will rewrite any ticket claim (safe-by-default) |
| Language detection ambiguous | Default to English; no impact |
| Webhook replay (duplicate failed-delivery part) | Retry guards (text equality + 60s window + `deliveryRetryCount` cap) block duplicate retries |
| `ticket-evidence-store` Map grows unbounded | TTL cleanup on read + periodic sweep (on each clear) keeps size bounded to active sessions |

## Testing strategy

- Unit tests per module (TicketClaimSanitizer, stuck-loop-detector, expanded escalation, delivery-failure branch).
- Integration test covering the full outbound path: agent reply → sanitizer chain → client → mock Intercom.
- Replay harness: record webhook payloads from a handful of real 30-day conversations (with PII redacted) and feed them through the new handler in integration tests.
- Existing pre-commit lint that blocks direct `RealIntercomClient` construction extended to also block bypass of `TicketClaimSanitizer`.

No E2E test against production Intercom; the webhook replay harness is sufficient.

## Rollback plan

All Phase 1+2 features are behind `account.*` config flags in `openclaw.json`:

| Flag | Default | Disables |
|---|---|---|
| `ticketClaimSanitizerEnabled` | `true` | `message_sending` hook becomes no-op (1A) |
| `deliveryFailureRecoveryEnabled` | `true` | Retry + customer-recovery message (1B) |
| `stuckLoopDetectionEnabled` | `true` | `isStuckLoop` always returns false (1D) |
| `expandedEscalationEnabled` | `true` | 4 new escalation categories revert to no-op (1C) |
| `autoHandoffTurnLimit` | `4` | Set to `0` to disable the 2D safety net entirely; higher N raises the threshold |
| `languagePinningEnabled` | `true` | No language system-instruction (2B) |

Flag flips edit `openclaw.json`; no redeploy required. Per project memory, out-of-band config writes aren't audited by `openclaw config-audit.jsonl` — flip flags via the proper `openclaw config` tool path so the change is logged.

`cs-backlog-sweep.py` is one-shot (Phase 1 deploy day) and idempotent via `state.backfilledAt` — no rollback needed.

## Sequencing

| Week | Work |
|---|---|
| 1 | Phase 1 (1A → 1B → 1C → 1D → 1E), ship together as one PR. Run 1F backfill on deploy day. |
| 2 | Phase 2A (CSAT toggle + digest), 2B (language pinning) |
| 3 | Phase 2C (backlog digest), 2D (auto-handoff floor) |
| Month 2+ | Phase 3A (churn-cohort) as its own spec. Phase 3B (credit-verification self-serve) as its own spec. |

## YAGNI trims
- No TF-IDF / intent clustering in stuck-loop detection.
- No per-category Slack routing; single channel.
- No "auto-create ticket when Caroline mentions creating one" magic; instead, strict prompt + sanitizer.
- No SLA enforcement in Phase 2; just visibility.
- No resolution-marker NLP; only ClickUp tool call counts as resolution for auto-handoff floor.
- Churn-cohort lives as a separate script/spec, not bundled here.

## Risks & open questions

- **Risk:** Ticket-claim sanitizer may over-fire on phrases we haven't enumerated, or under-fire on phrases we haven't anticipated. Mitigation: feature flag + Slack observability on every rewrite → we learn the false-positive/false-negative shape in week 1 and patch.
- **Risk:** Full-body rewrite on sanitizer trigger loses helpful content in multi-topic replies. Accepted for v1; tracked as a follow-up for sentence-level redaction if Slack feed shows volume of lost-content cases.
- **Risk:** Delivery-failure retry may double-send in a race (customer follow-up arrives between original send and failure webhook). Mitigation: retry guards (text equality + 60s window + retry cap) block this; worst case is one logged `delivery-failed-stale` event with no customer impact.
- **Risk:** Intercom's failed-delivery tombstone may NOT fire via `conversation.admin.single.created` webhook. Mitigation: 15-min `cs-delivery-sweep.py` cron catches tombstones on any conversation we missed, and the opportunistic "scan-on-next-inbound" path covers active threads.
- **Risk:** `sessionKey` shape may differ between the SDK's ephemeral sessions and our persisted Intercom session state (different key schemes). Validation task for the implementation plan: confirm sessionKey stability across a single conversation turn via a small integration test before wiring the evidence store.
- **Open question:** What's the true population of escalation-worthy conversations? The 30-day audit's "18% asks for human + 16% cancel + 17% frustration" counts have overlap and noise. We'll know post-ship via the weekly metrics digest.
- **Open question:** Is N=4 the right turn-count threshold for auto-handoff? Tunable via `account.autoHandoffTurnLimit`; starting value is 4 based on the median thread length in the 30-day audit (11 parts = ~5 exchanges).
