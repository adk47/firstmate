# Intercom Handoff Persistence & Live Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist Intercom handoff state to disk and verify conversation assignee via live API check so the bot stops responding after human takeover, even across gateway restarts.

**Architecture:** New `state-store.ts` module handles file I/O with atomic writes. `handler.ts` gains a live Intercom API check on inbound customer messages (async). `channel.ts` wires up startup hydration and persistence calls. `outbound.ts` gets a 5s timeout on `getConversation()`.

**Tech Stack:** TypeScript, Node.js `fs/promises`, Vitest, Intercom REST API v2.11

---

## File Structure

| File | Responsibility |
|------|---------------|
| `plugins/intercom/src/state-store.ts` | **New** — init, load, save sessions to `{stateDir}/plugins/intercom/sessions.json` |
| `plugins/intercom/src/handler.ts` | **Modify** — make `handleWebhookEvent` async, add live API check in customer_message case |
| `plugins/intercom/src/channel.ts` | **Modify** — startup hydration, saveSessions calls after state mutations |
| `plugins/intercom/src/outbound.ts` | **Modify** — add 5s timeout to `getConversation()` |
| `plugins/intercom/tests/state-store.test.ts` | **New** — round-trip, atomic write, corrupt/missing file, version check |
| `plugins/intercom/tests/handler.test.ts` | **Modify** — update all calls for async, add live check tests |
| `plugins/intercom/tests/integration.test.ts` | **New** — restart scenario end-to-end |

---

### Task 1: State Store — Tests & Implementation

**Files:**
- Create: `plugins/intercom/src/state-store.ts`
- Create: `plugins/intercom/tests/state-store.test.ts`

- [ ] **Step 1: Write the failing tests for state-store**

Create `plugins/intercom/tests/state-store.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, readFile, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initStateStore, loadSessions, saveSessions } from "../src/state-store.js";
import { createInitialSessionState } from "../src/handoff.js";

describe("state-store", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), "intercom-state-"));
  });

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  it("round-trips sessions through save and load", async () => {
    await initStateStore(tmpDir);

    const sessions = new Map<string, Map<string, any>>();
    const inner = new Map<string, any>();
    const state = createInitialSessionState("conv_1", "ws_1");
    state.handoffMode = "human_takeover";
    state.currentAssigneeId = "admin_99";
    inner.set("conv_1", state);
    sessions.set("default", inner);

    await saveSessions(sessions);
    const loaded = await loadSessions();

    expect(loaded.get("default")?.get("conv_1")?.handoffMode).toBe("human_takeover");
    expect(loaded.get("default")?.get("conv_1")?.currentAssigneeId).toBe("admin_99");
    expect(loaded.get("default")?.get("conv_1")?.conversationId).toBe("conv_1");
  });

  it("returns empty map when file does not exist", async () => {
    await initStateStore(tmpDir);
    const loaded = await loadSessions();
    expect(loaded.size).toBe(0);
  });

  it("returns empty map and warns on corrupt file", async () => {
    await initStateStore(tmpDir);
    const filePath = join(tmpDir, "plugins", "intercom", "sessions.json");
    await writeFile(filePath, "NOT VALID JSON{{{", "utf8");

    const loaded = await loadSessions();
    expect(loaded.size).toBe(0);
  });

  it("returns empty map when version key is missing", async () => {
    await initStateStore(tmpDir);
    const filePath = join(tmpDir, "plugins", "intercom", "sessions.json");
    await writeFile(filePath, JSON.stringify({ sessions: {} }), "utf8");

    const loaded = await loadSessions();
    expect(loaded.size).toBe(0);
  });

  it("returns empty map when version is unrecognized", async () => {
    await initStateStore(tmpDir);
    const filePath = join(tmpDir, "plugins", "intercom", "sessions.json");
    await writeFile(filePath, JSON.stringify({ version: 999, sessions: {} }), "utf8");

    const loaded = await loadSessions();
    expect(loaded.size).toBe(0);
  });

  it("does not leave .tmp file after successful write", async () => {
    await initStateStore(tmpDir);
    const sessions = new Map<string, Map<string, any>>();
    sessions.set("default", new Map());

    await saveSessions(sessions);

    const tmpFile = join(tmpDir, "plugins", "intercom", "sessions.json.tmp");
    await expect(stat(tmpFile)).rejects.toThrow();
  });

  it("preserves multiple accounts and conversations", async () => {
    await initStateStore(tmpDir);

    const sessions = new Map<string, Map<string, any>>();
    const account1 = new Map<string, any>();
    account1.set("conv_1", createInitialSessionState("conv_1", "ws_1"));
    account1.set("conv_2", createInitialSessionState("conv_2", "ws_1"));
    const account2 = new Map<string, any>();
    account2.set("conv_3", createInitialSessionState("conv_3", "ws_2"));
    sessions.set("acct_1", account1);
    sessions.set("acct_2", account2);

    await saveSessions(sessions);
    const loaded = await loadSessions();

    expect(loaded.size).toBe(2);
    expect(loaded.get("acct_1")?.size).toBe(2);
    expect(loaded.get("acct_2")?.size).toBe(1);
    expect(loaded.get("acct_2")?.get("conv_3")?.workspaceId).toBe("ws_2");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd plugins/intercom && npx vitest run tests/state-store.test.ts`
Expected: FAIL — `state-store.js` does not exist

- [ ] **Step 3: Implement state-store.ts**

Create `plugins/intercom/src/state-store.ts`:

```typescript
import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { IntercomSessionState } from "./types.js";

const CURRENT_VERSION = 1;
let sessionsFilePath = "";

export async function initStateStore(stateDir: string): Promise<void> {
  const dir = join(stateDir, "plugins", "intercom");
  await mkdir(dir, { recursive: true });
  sessionsFilePath = join(dir, "sessions.json");
}

export async function loadSessions(): Promise<Map<string, Map<string, IntercomSessionState>>> {
  const empty = new Map<string, Map<string, IntercomSessionState>>();

  let raw: string;
  try {
    raw = await readFile(sessionsFilePath, "utf8");
  } catch {
    return empty;
  }

  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch {
    console.warn("[intercom:state-store] corrupt sessions file — starting fresh");
    return empty;
  }

  if (parsed?.version !== CURRENT_VERSION) {
    console.warn(
      `[intercom:state-store] unknown version ${parsed?.version} (expected ${CURRENT_VERSION}) — starting fresh`,
    );
    return empty;
  }

  const result = new Map<string, Map<string, IntercomSessionState>>();
  const sessions = parsed.sessions ?? {};
  for (const [accountId, convMap] of Object.entries(sessions)) {
    const inner = new Map<string, IntercomSessionState>();
    for (const [convId, state] of Object.entries(convMap as Record<string, IntercomSessionState>)) {
      inner.set(convId, state);
    }
    result.set(accountId, inner);
  }

  return result;
}

export async function saveSessions(
  sessions: Map<string, Map<string, IntercomSessionState>>,
): Promise<void> {
  const obj: Record<string, Record<string, IntercomSessionState>> = {};
  for (const [accountId, convMap] of sessions) {
    const inner: Record<string, IntercomSessionState> = {};
    for (const [convId, state] of convMap) {
      inner[convId] = state;
    }
    obj[accountId] = inner;
  }

  const data = JSON.stringify({ version: CURRENT_VERSION, sessions: obj }, null, 2);
  const tmpPath = sessionsFilePath + ".tmp";
  await writeFile(tmpPath, data, "utf8");
  await rename(tmpPath, sessionsFilePath);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/intercom && npx vitest run tests/state-store.test.ts`
Expected: All 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add plugins/intercom/src/state-store.ts plugins/intercom/tests/state-store.test.ts
git commit -m "feat(intercom): add file-based session state persistence

Atomic writes via .tmp + rename. Versioned format (version: 1) for
future migration. Handles missing, corrupt, and unknown-version files
gracefully."
```

---

### Task 2: Add 5s Timeout to getConversation

**Files:**
- Modify: `plugins/intercom/src/outbound.ts:142-159`
- Modify: `plugins/intercom/tests/outbound.test.ts`

- [ ] **Step 1: Write the failing test for timeout**

Add to `plugins/intercom/tests/outbound.test.ts` (or create if tests for RealIntercomClient don't exist — check first). Since `RealIntercomClient` calls the real Intercom API, timeout behavior is best tested via the integration test in Task 5. For now, verify the code change compiles.

- [ ] **Step 2: Add AbortSignal.timeout to getConversation in RealIntercomClient**

In `plugins/intercom/src/outbound.ts`, modify the `getConversation` method (line 142-159):

```typescript
  async getConversation(params: {
    conversationId: string;
  }): Promise<IntercomConversation> {
    const url = `${this.baseUrl}/conversations/${params.conversationId}`;
    const response = await fetch(url, {
      method: "GET",
      headers: this.headers(),
      signal: AbortSignal.timeout(5000),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      throw new Error(`Intercom getConversation failed: ${response.status} ${response.statusText} - ${errorBody}`);
    }

    return await this.parseJson(response, "getConversation");
  }
```

- [ ] **Step 3: Run existing tests to verify no regressions**

Run: `cd plugins/intercom && npx vitest run`
Expected: All existing tests PASS

- [ ] **Step 4: Commit**

```bash
git add plugins/intercom/src/outbound.ts
git commit -m "feat(intercom): add 5s timeout to getConversation API call

Prevents customer messages from queuing behind slow Intercom API
responses."
```

---

### Task 3: Make handleWebhookEvent Async + Add Live Check

**Files:**
- Modify: `plugins/intercom/src/handler.ts`
- Modify: `plugins/intercom/tests/handler.test.ts`

- [ ] **Step 1: Write failing tests for live check behavior**

Add to the bottom of the `describe` block in `plugins/intercom/tests/handler.test.ts`:

```typescript
import { MockIntercomClient } from "../src/outbound.js";

// ... existing tests above ...

describe("live check", () => {
  it("filters when live check finds human assignee", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: Date.now() / 1000,
        updated_at: Date.now() / 1000,
        open: true,
        state: "open" as const,
        assignee: { type: "admin" as const, id: "human_admin_1", name: "Jan" },
      };
    };

    const payload = { ...userCreated, id: "evt_500" };
    const { result, state: updated } = await handleWebhookEvent(
      payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
    );
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("live check");
    }
    expect(updated?.handoffMode).toBe("human_takeover");
    expect(updated?.currentAssigneeId).toBe("human_admin_1");
  });

  it("dispatches when live check finds bot assignee", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: Date.now() / 1000,
        updated_at: Date.now() / 1000,
        open: true,
        state: "open" as const,
        assignee: { type: "bot" as const, id: BOT_ADMIN_ID },
      };
    };

    const payload = { ...userCreated, id: "evt_501" };
    const { result } = await handleWebhookEvent(
      payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("restores agent_active when live check finds bot on human_takeover conversation", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.handoffMode = "human_takeover";
    state.currentAssigneeId = "human_admin_1";

    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: Date.now() / 1000,
        updated_at: Date.now() / 1000,
        open: true,
        state: "open" as const,
        assignee: { type: "bot" as const, id: BOT_ADMIN_ID },
      };
    };

    const payload = { ...userCreated, id: "evt_502" };
    const { result, state: updated } = await handleWebhookEvent(
      payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(updated?.handoffMode).toBe("agent_active");
  });

  it("falls through to cached state when API call fails", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = new MockIntercomClient();
    client.getConversation = async () => {
      throw new Error("Network error");
    };

    const payload = { ...userCreated, id: "evt_503" };
    const { result } = await handleWebhookEvent(
      payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("falls through to cached state when client is not provided", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const payload = { ...userCreated, id: "evt_504" };
    const { result } = await handleWebhookEvent(
      payload as IntercomWebhookPayload, state, BOT_ADMIN_ID,
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("filters when live check finds closed conversation", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: Date.now() / 1000,
        updated_at: Date.now() / 1000,
        open: false,
        state: "closed" as const,
        assignee: null,
      };
    };

    const payload = { ...userCreated, id: "evt_505" };
    const { result, state: updated } = await handleWebhookEvent(
      payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
    );
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("live check");
    }
    expect(updated?.lifecycleState).toBe("closed");
  });
});
```

- [ ] **Step 2: Update all existing tests to use async/await**

Every existing `handleWebhookEvent` call must be awaited. Change every test from:

```typescript
const { result } = handleWebhookEvent(payload, state, BOT_ADMIN_ID);
```

to:

```typescript
const { result } = await handleWebhookEvent(payload, state, BOT_ADMIN_ID);
```

And change every `it("...", () => {` to `it("...", async () => {`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd plugins/intercom && npx vitest run tests/handler.test.ts`
Expected: FAIL — `handleWebhookEvent` is still sync and doesn't accept `client` parameter

- [ ] **Step 4: Make handleWebhookEvent async with optional client parameter**

Replace the full content of `plugins/intercom/src/handler.ts`:

```typescript
import type { IntercomWebhookPayload, IntercomSessionState, IntercomClient } from "./types.js";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply } from "./filters.js";
import { checkEscalation } from "./escalation.js";
import {
  handleAssignment,
  handleAdminReply,
  handleLifecycleChange,
  handleImplicitReopen,
  canAgentReply,
} from "./handoff.js";

export type HandlerAction =
  | { action: "dispatch_to_agent"; conversationId: string; body: string; authorId: string }
  | { action: "escalate"; conversationId: string; category: string; matchedPattern: string; body: string }
  | { action: "state_updated"; conversationId: string; description: string }
  | { action: "filtered"; conversationId: string; reason: string }
  | { action: "ignored"; reason: string }
  | { action: "duplicate"; eventId: string }
  | { action: "invalid_signature" };

export async function handleWebhookEvent(
  payload: IntercomWebhookPayload,
  state: IntercomSessionState | null,
  botAdminId: string,
  client?: IntercomClient,
): Promise<{ result: HandlerAction; state: IntercomSessionState | null }> {
  if (typeof payload?.data?.item?.id !== "string" || !payload?.topic || typeof payload?.id !== "string") {
    return { result: { action: "ignored", reason: "malformed payload: missing required fields" }, state };
  }

  const eventId = payload.id;
  const classified = classifyEvent(payload);

  // Check idempotency if we have state
  if (state) {
    const eventIdSet = createEventIdSet(state.processedEventIds);
    if (isEventProcessed(eventId, eventIdSet)) {
      return { result: { action: "duplicate", eventId }, state };
    }
    trackEventId(eventId, state.processedEventIds);
  }

  switch (classified.kind) {
    case "customer_message": {
      // Handle implicit reopen if conversation was closed
      if (state && state.lifecycleState === "closed") {
        handleImplicitReopen(state, botAdminId);
      }

      // Live check: verify conversation assignee via Intercom API
      if (state && client && classified.conversationId) {
        try {
          const conversation = await client.getConversation({
            conversationId: classified.conversationId,
          });

          // Check lifecycle state from live data
          if (conversation.state === "closed" || conversation.state === "snoozed") {
            state.lifecycleState = conversation.state;
            state.updatedAt = new Date().toISOString();
            return {
              result: {
                action: "filtered",
                conversationId: classified.conversationId,
                reason: `live check: conversation ${conversation.state}`,
              },
              state,
            };
          }

          // Check assignee from live data
          const assigneeId = conversation.assignee?.id ?? null;
          if (assigneeId && assigneeId !== botAdminId) {
            state.handoffMode = "human_takeover";
            state.currentAssigneeId = assigneeId;
            state.updatedAt = new Date().toISOString();
            return {
              result: {
                action: "filtered",
                conversationId: classified.conversationId,
                reason: `live check: human assignee ${assigneeId}`,
              },
              state,
            };
          }

          // Bot or no assignee — restore agent_active (clears stale human_takeover)
          state.handoffMode = "agent_active";
          state.currentAssigneeId = assigneeId;
          state.updatedAt = new Date().toISOString();
        } catch (err) {
          console.warn(
            `[intercom:handler] live check failed for conv=${classified.conversationId}: ${err}`,
          );
          // Fall through to cached state
        }
      }

      // Check escalation before dispatching
      const escalation = checkEscalation(classified.body);

      if (escalation.triggered) {
        // Escalation auto-sets human_takeover
        if (state) {
          state.handoffMode = "human_takeover";
          state.updatedAt = new Date().toISOString();
        }
        return {
          result: {
            action: "escalate",
            conversationId: classified.conversationId,
            category: escalation.category!,
            matchedPattern: escalation.matchedPattern!,
            body: classified.body,
          },
          state,
        };
      }

      // Suppress dispatch if agent cannot reply (human_takeover, snoozed, closed)
      if (state && !canAgentReply(state)) {
        return {
          result: {
            action: "filtered",
            conversationId: classified.conversationId,
            reason: `suppressed: ${state.handoffMode}/${state.lifecycleState}`,
          },
          state,
        };
      }

      return {
        result: {
          action: "dispatch_to_agent",
          conversationId: classified.conversationId,
          body: classified.body,
          authorId: classified.authorId,
        },
        state,
      };
    }

    case "admin_reply": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for admin reply" }, state };
      }

      // Check self-reply
      if (isSelfReply(classified.messageId, state.outboundMessageIds)) {
        return {
          result: { action: "filtered", conversationId: classified.conversationId, reason: "self-reply" },
          state,
        };
      }

      // Non-bot admin reply → implicit takeover
      handleAdminReply(state, classified.adminId, botAdminId);

      if (classified.adminId !== botAdminId) {
        return {
          result: {
            action: "state_updated",
            conversationId: classified.conversationId,
            description: `human_takeover (admin ${classified.adminId} replied)`,
          },
          state,
        };
      }

      return {
        result: { action: "filtered", conversationId: classified.conversationId, reason: "bot self-reply" },
        state,
      };
    }

    case "assigned": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for assignment" }, state };
      }

      handleAssignment(state, classified.assigneeId, botAdminId);
      return {
        result: {
          action: "state_updated",
          conversationId: classified.conversationId,
          description: `assigned to ${classified.assigneeId}, mode: ${state.handoffMode}`,
        },
        state,
      };
    }

    case "lifecycle": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for lifecycle change" }, state };
      }

      handleLifecycleChange(state, classified.state);
      return {
        result: {
          action: "state_updated",
          conversationId: classified.conversationId,
          description: `lifecycle → ${classified.state}`,
        },
        state,
      };
    }

    case "noted":
      return { result: { action: "ignored", reason: "internal note" }, state };

    case "unknown":
      return { result: { action: "ignored", reason: `unknown topic: ${classified.topic}` }, state };
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd plugins/intercom && npx vitest run tests/handler.test.ts`
Expected: All tests PASS (existing + 6 new live check tests)

- [ ] **Step 6: Commit**

```bash
git add plugins/intercom/src/handler.ts plugins/intercom/tests/handler.test.ts
git commit -m "feat(intercom): add live Intercom API check before dispatching customer messages

handleWebhookEvent is now async and accepts an optional IntercomClient.
Verifies conversation assignee and state via API before dispatching.
Symmetric: human assignee triggers takeover, bot/no assignee restores
agent_active. Falls through to cached state on API failure."
```

---

### Task 4: Wire Up Persistence in channel.ts

**Files:**
- Modify: `plugins/intercom/src/channel.ts`

- [ ] **Step 1: Run existing tests as baseline**

Run: `cd plugins/intercom && npx vitest run`
Expected: All tests PASS (confirms Task 1-3 haven't broken anything)

- [ ] **Step 2: Add imports and update the module-level comment**

At the top of `plugins/intercom/src/channel.ts`, add the state-store import and update the comment:

Replace:
```typescript
import { RealIntercomClient, trackOutboundMessageId } from "./outbound.js";
```
with:
```typescript
import { RealIntercomClient, trackOutboundMessageId } from "./outbound.js";
import { initStateStore, loadSessions, saveSessions } from "./state-store.js";
```

Replace:
```typescript
// Module-level session store shared between startAccount (inbound) and sendText (outbound).
// Keyed by accountId → conversationId → session state.
// In-memory only — lost on restart. Acceptable for v1; durable state deferred until traffic patterns emerge.
// TODO: Add TTL-based eviction when Intercom traffic volume justifies it.
export const accountSessions = new Map<string, Map<string, IntercomSessionState>>();
```
with:
```typescript
// Module-level session store shared between startAccount (inbound) and sendText (outbound).
// Keyed by accountId → conversationId → session state.
// Persisted to disk via state-store.ts; loaded on startup, saved on every state mutation.
// At current volumes, full-file rewrite per mutation is fine. Next step if measurable: debounced/batched writes.
export let accountSessions = new Map<string, Map<string, IntercomSessionState>>();
```

Note: changed `const` to `let` so we can reassign from `loadSessions()`.

- [ ] **Step 3: Add startup hydration in the plugin registration**

In the `startAccount` callback, after the `enabled` and `channelRuntime` guards but before `runPassiveAccountLifecycle`, add hydration. Find the line:

```typescript
        ctx.log?.info?.(`[${tag}] starting webhook monitor`);
```

Add before it:

```typescript
        // Hydrate session state from disk (once, on first account start)
        if (accountSessions.size === 0) {
          try {
            const stateDir = ctx.api?.runtime?.state?.resolveStateDir?.() ?? "";
            if (stateDir) {
              await initStateStore(stateDir);
              accountSessions = await loadSessions();
              ctx.log?.info?.(`[${tag}] loaded ${countSessions(accountSessions)} sessions from disk`);
            }
          } catch (err) {
            ctx.log?.warn?.(`[${tag}] failed to load sessions from disk: ${err}`);
          }
        }
```

Add a helper function after the `accountSessions` declaration:

```typescript
function countSessions(sessions: Map<string, Map<string, IntercomSessionState>>): number {
  let count = 0;
  for (const inner of sessions.values()) count += inner.size;
  return count;
}
```

- [ ] **Step 4: Add saveSessions calls after state mutations**

In the webhook handler's async processing block (after `const { result } = await handleWebhookEvent(...)`), add a save call whenever state was mutated. Find:

```typescript
                  const { result } = handleWebhookEvent(payload, state, account.botAdminId);
```

Replace with:

```typescript
                  const client = new RealIntercomClient(account.token);
                  const { result } = await handleWebhookEvent(payload, state, account.botAdminId, client);

                  // Persist state after every webhook that may have mutated it
                  if (result.action !== "ignored" && result.action !== "duplicate") {
                    saveSessions(accountSessions).catch((err) =>
                      log?.error?.(`[${tag}] failed to save sessions: ${err}`),
                    );
                  }
```

Also add a save after new session creation in `getOrCreateSession`. Find:

```typescript
    state = createInitialSessionState(conversationId, workspaceId);
    sessions.set(conversationId, state);
```

Add after:

```typescript
    saveSessions(accountSessions).catch((err) =>
      console.warn(`[intercom] failed to save new session: ${err}`),
    );
```

- [ ] **Step 5: Run all tests**

Run: `cd plugins/intercom && npx vitest run`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add plugins/intercom/src/channel.ts
git commit -m "feat(intercom): wire up session persistence and live check in channel

Hydrates session state from disk on startup. Passes IntercomClient to
handleWebhookEvent for live assignee check. Persists state after every
webhook that mutates it."
```

---

### Task 5: Integration Test — Restart Scenario

**Files:**
- Create: `plugins/intercom/tests/integration.test.ts`

- [ ] **Step 1: Write the integration test**

Create `plugins/intercom/tests/integration.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initStateStore, loadSessions, saveSessions } from "../src/state-store.js";
import { createInitialSessionState } from "../src/handoff.js";
import { handleWebhookEvent } from "../src/handler.js";
import type { IntercomWebhookPayload } from "../src/types.js";
import userCreated from "./fixtures/conversation-user-created.json";

const BOT_ADMIN_ID = "bot_1";

describe("restart persistence integration", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), "intercom-integration-"));
  });

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  it("preserves human_takeover state across simulated restart", async () => {
    // Phase 1: Establish state and persist
    await initStateStore(tmpDir);

    const sessions = new Map<string, Map<string, any>>();
    const inner = new Map<string, any>();
    const state = createInitialSessionState("conv_123", "ws_1");
    state.handoffMode = "human_takeover";
    state.currentAssigneeId = "admin_99";
    state.processedEventIds = ["evt_001"];
    inner.set("conv_123", state);
    sessions.set("default", inner);

    await saveSessions(sessions);

    // Phase 2: Simulate restart — clear memory, reload from disk
    const restored = await loadSessions();
    const restoredState = restored.get("default")?.get("conv_123");

    expect(restoredState).toBeDefined();
    expect(restoredState!.handoffMode).toBe("human_takeover");
    expect(restoredState!.currentAssigneeId).toBe("admin_99");

    // Phase 3: Process a customer message — should be suppressed
    const payload = { ...userCreated, id: "evt_600" } as IntercomWebhookPayload;
    const { result } = await handleWebhookEvent(payload, restoredState!, BOT_ADMIN_ID);

    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("suppressed");
    }
  });

  it("dispatches normally for agent_active state after restart", async () => {
    await initStateStore(tmpDir);

    const sessions = new Map<string, Map<string, any>>();
    const inner = new Map<string, any>();
    const state = createInitialSessionState("conv_123", "ws_1");
    inner.set("conv_123", state);
    sessions.set("default", inner);

    await saveSessions(sessions);

    const restored = await loadSessions();
    const restoredState = restored.get("default")?.get("conv_123");

    const payload = { ...userCreated, id: "evt_601" } as IntercomWebhookPayload;
    const { result } = await handleWebhookEvent(payload, restoredState!, BOT_ADMIN_ID);

    expect(result.action).toBe("dispatch_to_agent");
  });

  it("handles version migration by starting fresh", async () => {
    await initStateStore(tmpDir);
    const filePath = join(tmpDir, "plugins", "intercom", "sessions.json");

    // Write a file with no version key (simulating old format)
    await writeFile(filePath, JSON.stringify({
      default: { conv_123: { handoffMode: "human_takeover" } },
    }), "utf8");

    const loaded = await loadSessions();
    expect(loaded.size).toBe(0);
  });

  it("handles version 0 by starting fresh", async () => {
    await initStateStore(tmpDir);
    const filePath = join(tmpDir, "plugins", "intercom", "sessions.json");

    await writeFile(filePath, JSON.stringify({
      version: 0,
      sessions: { default: { conv_123: { handoffMode: "human_takeover" } } },
    }), "utf8");

    const loaded = await loadSessions();
    expect(loaded.size).toBe(0);
  });
});
```

- [ ] **Step 2: Run the integration test**

Run: `cd plugins/intercom && npx vitest run tests/integration.test.ts`
Expected: All 4 tests PASS

- [ ] **Step 3: Run full test suite**

Run: `cd plugins/intercom && npx vitest run`
Expected: All tests PASS across all test files

- [ ] **Step 4: Commit**

```bash
git add plugins/intercom/tests/integration.test.ts
git commit -m "test(intercom): add integration tests for restart persistence

Covers human_takeover preservation across restart, normal dispatch after
restart, and version migration (missing/old version starts fresh)."
```

---

## Execution Order

Tasks must be executed in order: 1 → 2 → 3 → 4 → 5. Each builds on the previous.

## Post-Implementation Notes

- The `ctx.api?.runtime?.state?.resolveStateDir?.()` call in Task 4 Step 3 uses optional chaining because the API shape may vary by OpenClaw version. If `resolveStateDir` is unavailable, hydration is skipped silently and the plugin falls back to in-memory only (same as v1 behavior).
- The `RealIntercomClient` is created once per webhook in Task 4 and passed to `handleWebhookEvent`. This is cheap (no connections pooled) and matches the existing pattern where `RealIntercomClient` is instantiated per-operation.
