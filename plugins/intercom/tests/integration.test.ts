import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initStateStore, loadSessions, saveSessions } from "../src/state-store.js";
import { createInitialSessionState } from "../src/handoff.js";
import { handleWebhookEvent } from "../src/handler.js";
import type { IntercomWebhookPayload, IntercomSessionState } from "../src/types.js";
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

    const sessions = new Map<string, Map<string, IntercomSessionState>>();
    const inner = new Map<string, IntercomSessionState>();
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

    const sessions = new Map<string, Map<string, IntercomSessionState>>();
    const inner = new Map<string, IntercomSessionState>();
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
