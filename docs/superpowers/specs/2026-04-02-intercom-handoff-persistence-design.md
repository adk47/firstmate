# Intercom Handoff Persistence & Live Check

**Date:** 2026-04-02
**Status:** Draft
**Bug:** CS bot responds after human takeover because in-memory session state is lost on gateway restart

## Problem

The Intercom plugin tracks handoff state (whether a human has taken over a conversation) in an in-memory `Map`. When the gateway restarts, this state is lost. The bot treats every conversation as fresh (`agent_active`) and responds even when a human agent like Jan has already intervened.

## Root Cause

`channel.ts:13-17` — `accountSessions` is a module-level `Map` with no persistence. The code explicitly defers durable state: *"In-memory only — lost on restart. Acceptable for v1; durable state deferred until traffic patterns emerge."*

## Solution

Two complementary changes:

1. **File-based persistence** — Write session state to disk on every mutation, reload on startup
2. **Live Intercom API check** — Before dispatching a customer message, verify the conversation's assignee via the Intercom API

Together these cover: restarts (file), webhook ordering races (live check), file loss (live check), API downtime (file).

## Design

### 1. State Persistence Layer

**New file:** `plugins/intercom/src/state-store.ts`

**Responsibilities:**
- `initStateStore(stateDir: string)` — Resolve path to `{stateDir}/plugins/intercom/sessions.json`, create directories if needed
- `loadSessions(): Map<string, Map<string, IntercomSessionState>>` — Read and deserialize the file. If missing or corrupt, return empty map and log a warning
- `saveSessions(sessions: Map<string, Map<string, IntercomSessionState>>)` — Serialize and write atomically (write to `.tmp`, then `rename()`)

**Serialization format:** JSON object of `{ [accountId]: { [conversationId]: IntercomSessionState } }`. The `Map` structure round-trips through plain objects.

**Call sites for `saveSessions()`:** Every path in `handler.ts` that mutates state — after `handleAssignment()`, `handleAdminReply()`, `handleLifecycleChange()`, `handleImplicitReopen()`, and escalation-triggered `human_takeover`. Also after `createInitialSessionState()` in `getOrCreateSession()`.

**Write frequency note:** At current Intercom volumes, full-file rewrite per mutation is fine. If conversation count grows to where this is measurable, the next step is debounced/batched writes (e.g., coalesce mutations within a 500ms window).

**Serialization versioning:** The top-level JSON object includes a `version: 1` key. `loadSessions()` checks this on load — if missing or unrecognized, it treats the file as corrupt (fresh start + warning). This enables future format migration without guessing.

### 2. Live Intercom API Check

**Where:** `handler.ts`, inside the `"customer_message"` case — between the implicit reopen logic (line 48-50) and the escalation check (line 45). Specifically, before `canAgentReply()` is evaluated (line 71).

**Logic:**
```
1. Call client.getConversation(conversationId) with a 5s timeout
2. If response.assignee exists and assignee.id !== botAdminId:
   - Update state: handoffMode = "human_takeover", currentAssigneeId = assignee.id
   - Save state to file
   - Return { action: "filtered", reason: "live check: human assignee" }
3. If response.assignee.id === botAdminId (or no assignee / unassigned):
   - Update state: handoffMode = "agent_active", currentAssigneeId = assignee.id or null
   - Save state to file
   - Fall through to normal dispatch (this clears stale human_takeover state)
4. If response.state is "closed" or "snoozed":
   - Update state: lifecycleState accordingly
   - Save state to file
   - Return { action: "filtered", reason: "live check: conversation closed/snoozed" }
5. If API call fails (network error, timeout, non-2xx):
   - Log warning
   - Fall through to cached state (do not block the bot)
```

**Bot reassignment edge case:** Step 3 is critical — without it, a conversation handed off to a human and then reassigned back to the bot stays permanently suppressed. The live check must be symmetric: human assignee triggers takeover, bot/no assignee clears it.

**The Intercom client** (`outbound.ts` — `RealIntercomClient`) needs a new method: `getConversation(conversationId: string)`. This calls `GET /conversations/{id}` with the account's bearer token.

**Signature change:** `handleWebhookEvent()` is currently synchronous. The live API call makes it `async`. All call sites in `channel.ts` must `await` it. This is the only breaking API change.

**Async safety:** The webhook route in `channel.ts` must send `res.sendStatus(200)` to Intercom *before* awaiting `handleWebhookEvent()`. Intercom retries on non-2xx, and any error in the async path must not prevent the 200 response. The handler runs in a fire-and-forget `Promise` after the HTTP response is sent, wrapped in a top-level try/catch that logs errors.

**`getConversation()` timeout:** The API call uses a 5s timeout (via `AbortSignal.timeout(5000)` or equivalent). Intercom's API can be slow under load — customer messages must not queue behind it.

### 3. Startup Hydration

**Where:** `channel.ts`, in the plugin registration callback (before the webhook route is registered).

**Steps:**
1. Call `api.runtime.state.resolveStateDir()` to get the base state directory
2. Call `initStateStore(stateDir)` to set up the path and create directories
3. Call `loadSessions()` and assign the result to `accountSessions`
4. Register the webhook route (existing code)

This ensures the session map is populated before any webhooks are processed.

### 4. Files Changed

| File | Change |
|------|--------|
| `plugins/intercom/src/state-store.ts` | **New** — persistence layer (init, load, save) |
| `plugins/intercom/src/handler.ts` | Add live API check in `customer_message` case; accept `client` and `botAdminId` for API call |
| `plugins/intercom/src/channel.ts` | Wire up startup hydration; call `saveSessions()` after state mutations; pass client to handler |
| `plugins/intercom/src/outbound.ts` | Add `getConversation()` method to `RealIntercomClient` |
| `plugins/intercom/tests/state-store.test.ts` | **New** — round-trip, atomic write, corrupt file recovery |
| `plugins/intercom/tests/handler.test.ts` | Add tests for live check (human assignee, bot assignee, API failure fallback) |
| `plugins/intercom/tests/integration.test.ts` | **New** — restart scenario: populate state, clear memory, load from file, verify handoff preserved |

### 5. What Does NOT Change

- `IntercomSessionState` interface — no new fields needed
- Handoff state machine (`handoff.ts`) — transitions remain identical
- Escalation logic (`escalation.ts`) — unchanged
- Webhook signature validation — unchanged
- `openclaw.json` config — no new config keys

### 6. Testing Strategy

**Unit tests (`state-store.test.ts`):**
- Round-trip: save sessions, load sessions, verify equality
- Atomic write: verify `.tmp` file is cleaned up after successful write
- Corrupt file: write garbage to `sessions.json`, verify `loadSessions()` returns empty map and logs warning
- Missing file: verify `loadSessions()` returns empty map without error

**Unit tests (handler live check):**
- Human assignee: mock `getConversation()` returning human admin — verify message is filtered
- Bot assignee: mock returning bot admin — verify message is dispatched
- Bot reassignment: mock returning bot admin on a `human_takeover` conversation — verify `agent_active` is restored and message is dispatched
- API failure: mock throwing error — verify fallback to cached state (dispatch proceeds)
- API timeout: mock hanging beyond 5s — verify fallback to cached state

**Integration test (`integration.test.ts`):**
- Create sessions with various handoff states
- Save to file
- Clear the in-memory map (simulating restart)
- Load from file
- Process a customer message on a `human_takeover` conversation
- Verify it is correctly suppressed
- Version migration: write a file without `version` key or with `version: 0` — verify `loadSessions()` treats it as corrupt and starts fresh
