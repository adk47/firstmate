# Intercom Bot Self-Protection — Design Spec

**Date**: 2026-05-04
**Author**: Nick + Claude
**Status**: Draft, awaiting review
**Triggered by**: Jan's escalation of conv `215474098923209` (jami@jamigrooms.com) — bot replied 30+ times to a frustrated Pro user threatening BBB/YouTube/refund without ever handing off; also fabricated three "ticket created" promises that were never real.

## Problem

The Intercom AI agent has four compounding failure modes that turned a routine analytics complaint into a near-cancellation event:

1. **Narrow escalation rules.** `escalation.ts` matches a tiny regex set (`chargeback`, `lawyer`, `hacked`, `harassment`). It does not match `refund`, `cancel`, `fraud`, `BBB`, `social media`, `tell everyone`, or any frustration paraphrase. Real distress does not trigger handoff.
2. **No turn-count cap.** Bot can loop indefinitely. Jami got 30+ replies before a human noticed.
3. **No fact memory.** Bot asked Jami for her account email at messages 5, 17, 27, 35 — even though she had answered at message 5 and the conversation was already tied to her logged-in Intercom contact.
4. **Theatrical promises.** Bot repeatedly said *"I've created a support ticket — you'll hear back within 1 business day"* and *"escalated to senior support."* Both fictions: `support-tools` plugin is built but **not enabled on the main profile**, so `create_ticket` isn't even available to the agent. The "1 business day" is a model fabrication.

## Scope

In-scope (this spec):

1. Hybrid risk detection (broadened rules + LLM-judge) replacing the narrow regex layer.
2. Magic-keyword "talk to a human" affordance.
3. Pinned-fact memory on session state, rendered into the agent's prompt every turn.
4. Real ticket creation on every meaningful handoff (replaces theatrical promises).
5. Honesty rules in `workspaces/support/SOUL.md` forbidding ticket/SLA fabrication.
6. Deploy prerequisites: enable `support-tools` on main profile; provision Muso API key + ClickUp `Profile ID` custom field ID.

Out of scope:

- Image / vision support (bot can't read user-shared screenshots — separate brainstorm).
- Product affordances inside the Intercom Messenger widget (separate effort).
- The "support@muso.ai is a black hole" problem (operational, not bot — separate brainstorm if revisited).
- Knowledge-base content rewrite (covered by 2026-04-12 CS-experience spec; this spec only touches the prompt's honesty rules, not voice/KB).

## Architecture

Five units inside `plugins/intercom/src/`. `handler.ts` is the orchestrator; everything else is a focused unit with its own tests.

```
                     ┌──────────────────────────────┐
  Intercom webhook → │       handler.ts             │ ← orchestrator
                     │  (existing — extended)       │
                     └──┬─────────┬────────┬────────┘
                        │         │        │
       on customer turn │         │        │ on handoff fire
                        ▼         ▼        ▼
            ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐
            │ extractors.ts│ │ escalation.ts│ │ escalation-action.ts │
            │  (NEW)       │ │  (extended:  │ │   (NEW — orchestrates│
            │  pinned-fact │ │   rules +    │ │   farewell, reassign,│
            │  updater     │ │   judge)     │ │   Slack, ticket)     │
            └──────┬───────┘ └──────┬───────┘ └──────────┬───────────┘
                   │                │                    │
                   ▼                ▼                    ▼
            IntercomSessionState (state-store.ts)  outbound.ts, slack.ts,
            ┌──────────────────────────┐           support-tools.create_ticket
            │ existing fields...       │           (existing — newly enabled
            │ + knownFacts: KnownFacts │            on main profile)
            │ + escalationFiredAt: ISO │
            │   string \| null         │
            │ + userTurnCount: int     │
            └──────────────────────────┘
```

`handoff.ts` (the existing pure state-machine) is unchanged. `escalation-action.ts` is new and side-effectful; it composes the existing `outbound.ts` + `slack.ts` + the `create_ticket` tool from `support-tools`.

### Data flow on a customer message

1. `handler.ts` validates payload + idempotency (existing).
2. `handler.ts` runs the existing live-check against Intercom API (existing).
3. **NEW**: `handler.ts` calls `extractors.update(message, state.knownFacts)` to pin newly-revealed facts.
4. `handler.ts` increments `state.userTurnCount`.
5. **NEW**: `handler.ts` calls `escalation.assessRisk(message, recentHistory, state)` which returns a `RiskAssessment`.
6. If `assessment.triggered && state.escalationFiredAt == null`:
   - Call `escalationAction.execute(state, conversationId, assessment, deps)`.
   - Return `{ action: "escalate", ... }`.
7. Otherwise, dispatch to agent as before — but with `state.knownFacts` injected into the agent's system prompt context (via `channel.ts`).

## Components

### 1. `escalation.ts` (extended) — three-layer risk assessment

Single export `assessRisk(message, history, state) → RiskAssessment`. Internal layers:

**Layer 0 — magic keyword (consent).** Cheapest, fires first. Matches case-insensitive against:
`talk to a (human|person|real|agent)`, `i want a human`, `human please`, `real person`, `speak to (someone|a person)`, `agent please`. Returns `{ triggered: true, source: "user_request", reason: "user_requested_human", suggestedActionType: "support-general", confidence: "high" }`. **Bypasses dedupe** (`escalationFiredAt`) — explicit consent always wins.

**Layer 1 — broadened rules.** Runs if Layer 0 didn't match. Categories:

- `refund_intent`: `refund`, `money back`, `pro[ -]rate`, `chargeback`
- `cancel_intent`: `\bcancel(?:l?ing|l?ed|lation)?\b` (matches "cancel", "cancelling", "cancellation"), `unsubscribe`, `close (my )?account`, `delete (my )?account`
- `fraud_complaint`: `\bfraud(?:ulent)?\b`, `\brip[ -]?off\b`, `\bscam\b`, `report (you|this) to`, `\bbbb\b`, `better business bureau`
- `public_shaming_intent`: `tell (everyone|my friends|everybody)`, `social media`, `youtube`, `twitter`, `\bx\.com\b`, `instagram`, `tiktok`, `scorched earth`, `going public`
- `legacy categories`: `lawyer`, `attorney`, `lawsuit`, `sue`, `subpoena`, `legal action`, `hacked`, `compromised`, `unauthorized access`, `harassment`, `phishing`
- `turn-count`: triggered if `state.userTurnCount > 6 && state.escalationFiredAt == null` regardless of message content.

Each match returns the same `RiskAssessment` shape with `source: "rule"`. `suggestedActionType` is mapped per category (refund_intent → `subscription-refund`, cancel_intent → `subscription-refund`, fraud_complaint → `dispute`, others → `support-general`).

**Layer 2 — LLM-judge.** Runs if Layers 0+1 didn't match AND `state.userTurnCount >= 4` (i.e., from the 4th customer turn onwards).

- Model: `anthropic/claude-haiku-4-5-20251001` via OpenRouter (already enabled on main).
- Input: last 6 conversation parts — **both customer and bot replies in chronological order** (so the judge can detect "bot asked X, customer answered, bot is asking X again") — sanitized for PII via existing `sanitize-email.ts`, plus the current `state.knownFacts`.
- Output (strict JSON, validated):
  ```json
  {
    "shouldHandoff": true,
    "reasons": ["frustration", "repeated_question", "stuck_in_loop"],
    "suggestedActionType": "support-general",
    "confidence": "high"
  }
  ```
- Threshold: trigger only if `shouldHandoff === true && confidence !== "low"`.
- **Fail-closed**: timeout, rate limit, malformed JSON → log warning, do not trigger handoff. Never punish the user for our infra failure.
- Budget: max 1 judge call per customer turn. Caching keyed on (conv id, last user message id) so a re-delivered webhook doesn't double-spend.

### 2. `extractors.ts` (NEW) — pinned-fact extractor

```ts
export type KnownFacts = {
  accountEmail?: string;          // regex: existing sanitize-email pattern
  musoProfileUrl?: string;        // regex: https?://muso\.ai/profile/[a-f0-9-]+
  musoProfileId?: string;         // derived from musoProfileUrl
  planTier?: "Pro" | "Business" | "Free" | "unknown";  // judge-set, once
  primaryComplaint?: string;      // judge-set, free text, once
  factsLastUpdated: string;       // ISO
};

export function update(message: string, current: KnownFacts): KnownFacts;
```

- Email + Muso profile URL extraction: pure regex, runs every customer turn.
- Plan tier + complaint extraction: piggybacks on the LLM-judge call (Layer 2). When the judge is invoked, the same call returns these fields if they aren't already set. This keeps cost flat — one LLM call per turn at most.
- Once a fact is set, it is **not overwritten** by later turns. The user might later say something contradictory ("I'm not Pro after all"); the support agent can override pinned facts manually via Intercom note or by closing the conversation.

**Injection mechanism — open architectural question.** `channel.ts` does not directly construct the agent's system prompt; it delegates to `dispatchInboundDirectDmWithRuntime` from the OpenClaw SDK, which assembles the prompt from the workspace's SOUL.md + framework defaults. There is no documented slot for per-conversation system-prompt augmentation. Three options:

1. **Inline-prepend into `rawBody`** *(recommended for v1)*. Before passing the customer's message to `dispatchInboundDirectDmWithRuntime`, prepend a structured block:
   ```
   [CONVERSATION_CONTEXT]
   Known about this user (do not re-ask):
   - account email: jami@jamigrooms.com
   - plan tier: Pro
   [CUSTOMER_MESSAGE]
   <actual user message>
   ```
   SOUL.md adds a section instructing the agent to treat `CONVERSATION_CONTEXT` as authoritative ground truth and never echo the block back. **Risk**: model may occasionally regurgitate the block to the user; mitigate with a few-shot example showing correct handling and a sanitization pass on outbound replies that strips any `[CONVERSATION_CONTEXT]` substring before sending.
2. **SDK enhancement.** Patch `dispatchInboundDirectDmWithRuntime` to accept an `extraSystemContext` parameter. Cleaner, but couples this work to upstream openclaw — a release dependency that has bitten us before (memory: openclaw cron bugs #65981/#66142). Defer unless option 1 proves leaky.
3. **Tool-based lookup.** Expose a `get_known_facts(conversationId)` tool the agent can call. Forces the agent to remember to call it; adds latency; loses the "facts visible without the agent doing anything" guarantee. Not recommended.

If a fact is unset, it is omitted from the rendered block (no `unknown` placeholder noise). Empty `KnownFacts` produces no prepended block at all — no noise on first contact.

### 3. `escalation-action.ts` (NEW) — handoff orchestrator

This **replaces** the existing inline escalation block in `channel.ts` (currently lines 329-405: ack → reassign → Slack). The existing block does not create tickets and uses a too-generic `fallbackAcknowledgement` farewell. The new orchestrator subsumes it.

Single export `execute(state, conversationId, assessment, deps)`. Order matters:

1. **Set dedupe gate first, synchronously, with awaited persist.** Set `state.escalationFiredAt = new Date().toISOString()` and `state.handoffMode = "human_takeover"` in memory, then `await saveSessions(accountSessions)` before any other I/O. The existing fire-and-forget `saveSessions(...).catch(...)` pattern in `channel.ts` is *not* sufficient here — a redelivered or concurrent webhook reading the in-memory state mid-flight would not see the gate. Atomic-on-disk persist before step 2 is required.
2. **Create ticket** via `deps.createTicket({...})`. Action type from `assessment.suggestedActionType`. Customer email + Muso profile ID from `state.knownFacts`. Conversation summary from last 6 parts. Capture ticket ID + SLA from the tool's return value. **Failure mode**: if `create_ticket` fails (rate limit, ClickUp 5xx, missing creds), capture the error and continue — the farewell text below adapts.
3. **Post farewell** via existing `IntercomClient.replyToConversation`. Two templates:
   - Ticket created: `"I'm pulling in a teammate to take this from here. They'll follow up at <email> within <SLA>. Reference: <ticket-id>."`
   - Ticket failed: `"I'm pulling in a teammate to take this from here. They'll follow up at <email> shortly."`
   - For magic-keyword path (`reason: user_requested_human`), prepend `"Got it — "` to either template.
4. **Reassign** the Intercom conversation to `account.defaultInboxId` (existing config field — currently `5465657` = Jan; semantically functions as "default human escalation target", though the field name is misleading). Use existing `client.assignConversation`; tolerate `IntercomAssignmentConflictError` (means a human already grabbed it). *Implementation note: the field name is a known wart but renaming to e.g. `humanEscalationTargetId` is out of scope for this spec — would require coordinated config migration across all three profiles.*
5. **Post Slack ping** via existing `slack.ts` `buildEscalationSlackMessage()`. Payload includes: conv URL, ticket URL/ID (or "ticket creation failed: <err>"), reason, last 3 sanitized turns, source layer.

Errors in steps 3-5 are logged but do not roll back step 1 — once we've fired, we've fired.

### 4. `handler.ts` + `channel.ts` (extended)

`handler.ts` adds the extractor call, turn counter, risk assessment, and handoff dispatch (described in Data Flow above). It also short-circuits dispatch when `state.escalationFiredAt != null` — once we've handed off, the bot does not reply again on this conversation, regardless of whether the human picked it up. (Existing `canAgentReply()` already enforces this via `handoffMode === "agent_active"`; the `escalationFiredAt` field is informational + used for the dedupe gate.)

`channel.ts` injects the rendered `KnownFacts` block into the agent's system prompt context every turn, just before the existing context block.

### 5. `state-store.ts` + `types.ts` (extended)

`IntercomSessionState` gains three optional fields:

```ts
interface IntercomSessionState {
  // ...existing fields...
  knownFacts?: KnownFacts;
  escalationFiredAt?: string | null;
  userTurnCount?: number;
}
```

All three are optional and have safe defaults during deserialization (`{}`, `null`, `0`). This means existing on-disk session state continues to load without migration.

### 6. `workspaces/support/SOUL.md` (extended) — honesty rules

New section, terse:

```
## Honesty rules (no fabrication)

- NEVER claim a ticket was created unless you actually called `create_ticket` in this turn AND received a successful response. If you would otherwise say "I've created a ticket" without a real tool call, say "I'll flag this for our team" instead.
- NEVER invent SLA timeframes ("you'll hear back within 1 business day", "5 business days", "senior support reviews within X"). When reporting back to the user about a ticket, use the literal SLA returned by `create_ticket` — do not paraphrase, shorten, or guess.
- NEVER invent ticket IDs, reference numbers, or case numbers.
- If `create_ticket` is not available as a tool in this turn, do not promise human follow-up at all. Say "I'd recommend emailing support@muso.ai with details" and stop.
```

This is short on purpose — the structural fix is wiring the tool up so the agent can actually file. The rules close the residual hallucination gap.

### 7. Deploy prerequisites — `openclaw-main.json` + secrets

- Add `"support-tools": { "enabled": true }` to `plugins.entries`.
- Add `create_ticket` to the support agent's tool allowlist (in the agent's config block).
- Provision in `secrets/`: `CLICKUP_API_KEY`, `CLICKUP_LIST_ID`, `CLICKUP_USER_EMAIL_FIELD_ID`, `CLICKUP_PROFILE_ID_FIELD_ID` (the `Profile ID` custom field — explicitly flagged as a deploy blocker in memory; needs creating in ClickUp before deploy).
- Reuse existing `defaultInboxId` config field for reassign target (currently `5465657` = Jan); no new config field needed.
- *Not in this spec*: a Muso API key for resolving Intercom contact → Muso profile would be needed for richer pinned facts, but is out of scope here (we only pin what the user types).

These prerequisites are listed as P0 in the implementation plan; the plugin code can ship without them and gracefully degrades (judge skipped if no key, ticket fails → "we'll follow up shortly" farewell).

## Data flow — Jami replay

To validate the design, replay Jami's transcript against it:

| Turn | Customer message | What fires |
|------|-----------------|------------|
| 1 | "Seams like this app does not update very often..." | extractor pins email later; no risk yet; agent replies normally |
| 2 | "[Image]" | extractor no-op; no risk; agent says "can't see image" |
| 3 | "It's been the same since Monday. I am a pro member..." | extractor pins planTier=Pro (judge will set on Layer 2 turn); no rule match; turn count 3, no judge yet; agent replies |
| 4 | "Yes I'm pro and ur not being very customer service like..." | turn count 4; judge runs (threshold met), scores `frustration: high`, `shouldHandoff: true` → **HANDOFF FIRES** |
| | | • Ticket created: action=`support-general`, summary "Pro user reports analytics frozen for ~1 week, escalating frustration"<br>• Farewell: "I'm pulling in a teammate. They'll follow up at jami@jamigrooms.com within 48 hours. Reference: <id>."<br>• Reassigned to default escalation target<br>• Slack ping with conv URL + ticket URL |

Even if the judge under-scores turn 4, the rule layer catches turn 5 ("close my account", "fraud", "rip off") immediately. Worst case, turn 7 hits the turn-count threshold. Old behavior of 30+ replies is structurally impossible.

## Error handling

- **`create_ticket` fails (network, ClickUp 5xx, missing creds)**: handoff continues with degraded farewell text. Slack ping carries the failure detail so the team can see why no ticket landed.
- **Reassign fails (`IntercomAssignmentConflictError`)**: log, continue — means a human already grabbed it.
- **Slack ping fails**: log, continue. Conversation is already handed off in Intercom; Slack is supervisory only.
- **Judge fails (timeout, rate limit, bad JSON)**: log, do not handoff. Falls through to normal agent reply.
- **Webhook redelivery after handoff fired**: `state.escalationFiredAt != null` short-circuits before any I/O. Safe.
- **Concurrent webhooks for same conversation**: dedupe gate at step 1 of `executeEscalation` (set timestamp before doing anything else, persist before next step). Worst-case race produces one duplicate Slack ping.

## Testing

- **Unit tests** (`plugins/intercom/tests/`):
  - `escalation.test.ts`: each rule category fires correctly; magic-keyword bypasses dedupe; turn-count threshold; judge fail-closed; judge confidence threshold.
  - `extractors.test.ts`: email regex correctness on edge cases (mixed case, leading/trailing whitespace, multiple emails — pick first); profile URL parsing; pinned facts not overwritten.
  - `escalation-action.test.ts`: order of operations (dedupe set first); ticket-failure farewell text; reassign-conflict tolerance; Slack failure non-fatal.
  - `handler.test.ts`: handoff short-circuits subsequent customer turns; user-turn count increments only on customer messages.
- **Integration test** (manual on edge profile first, then main):
  - Replay sanitized version of Jami's transcript against the deployed plugin in a test workspace; verify handoff fires by turn 4-5, real ticket created, Slack ping lands.
  - Magic-keyword test: send "talk to a human" on a fresh conversation → handoff fires immediately, ticket created.
  - Pinned-facts smoke: send "my email is foo@bar.com" → confirm second customer turn does not get asked for email.

## Rollout

1. Land code behind a feature flag in plugin config: `riskAssessment.enabled: false` by default. During the rollout window, `escalation.ts` exports both the legacy `checkEscalation()` and the new `assessRisk()`; `handler.ts` reads the flag and calls one or the other. Plugin behavior is unchanged when off.
2. Provision secrets + ClickUp custom field. Verify `create_ticket` works end-to-end in a manual test on edge profile.
3. Enable `support-tools` plugin on main profile. Add `create_ticket` to support agent allowlist. Deploy SOUL.md honesty rules.
4. Flip `riskAssessment.enabled: true` on edge profile. Watch for ~24h: bot reply rate per conv, handoff rate, ticket-creation success rate, judge call cost.
5. Flip on main profile. Monitor same metrics. Aaron + Jan eyeball-test 5-10 live conversations.
6. Remove the legacy `checkEscalation()` call after 1 week stable.

## Rollback

Single config toggle: `riskAssessment.enabled: false`. Reverts to existing escalation regex + no judge + no extractors + no auto-ticket. Pinned `knownFacts` already on disk are simply ignored on next load. SOUL.md honesty rules are model-agnostic and don't need rolling back; they only matter when `create_ticket` is available, and they degrade safely if it isn't.

## Success criteria

- **Hard floor**: no conversation receives more than 6 bot replies without a human assignee. (Currently: 30+ on Jami.)
- **Real artifacts**: 100% of automatic handoffs *attempt* `create_ticket`; ≥95% succeed (under normal ClickUp availability) and produce a real ID with `hydra-action-request` tag. Zero fabricated ticket claims (validated by sampling 20 conversations/week and grepping bot replies for `created a ticket` / `reference number` against actual ClickUp creates — every claim must match a real ticket).
- **Identity grounding**: zero conversations where the bot asks for the customer's email more than once. (Currently observed: 4 asks in Jami's thread.)
- **Magic keyword**: 100% of conversations containing `talk to a (human|person|real)` (or close variants) are reassigned within one bot turn.
- **Cost ceiling**: judge calls average ≤ 1 per conversation overall; total monthly OpenRouter cost for judge ≤ $50 at current Intercom volume.

## Open questions for review

- Should the magic-keyword list include phrasings like "this is useless" or "you're not helping" — borderline distress signals — or keep the magic-keyword purely consent-shaped and let those go through Layer 2 judge instead? *Current proposal: keep consent-shaped only; let judge handle the rest.*
- Should pinned-facts auto-clear when conversation lifecycle goes to `closed`, or persist across reopens? *Current proposal: persist; reopens are usually the same complaint.*
- Should the reassign target be a single admin (`defaultInboxId` = Jan today) or a per-action-type map (refunds → finance, dispute → ops, general → support)? *Current proposal: keep the existing single field for v1; revisit when team count > 1.*
- **Fact injection mechanism**: confirm option 1 (inline-prepend into `rawBody`) is acceptable, or do we want to invest in option 2 (SDK enhancement) up front to avoid the regurgitation risk?

## Implementation gotchas (notes for the plan, not approval-blocking)

- Pre-commit hook guards SOUL.md hardcoded model names (issue #117). Honesty rules section adds no model names; should pass cleanly. Sanity-check before commit.
- Adding `support-tools` plugin to `main` profile requires the deploy script to mirror it (memory: PR #176 already mirrored intercom plugin to main; same deploy.sh path applies). Verify via `ls /root/.openclaw-main/extensions/` after deploy.
- The legacy `escalation.ts` `EscalationResult` type is exported from `types.ts:147`; `assessRisk` introduces a new `RiskAssessment` type that should coexist (not replace) until the legacy `checkEscalation()` is removed in rollout step 6.
- Save-after-dedupe-gate must use `await saveSessions()`, not the existing fire-and-forget `.catch()` pattern in `channel.ts`. Easy to get wrong; call out in the implementation plan as a specific test case.
