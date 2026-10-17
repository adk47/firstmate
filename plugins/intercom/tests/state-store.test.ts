import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, readFile, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initStateStore, loadSessions, saveSessions } from "../src/state-store.js";
import { createInitialSessionState } from "../src/handoff.js";
import type { IntercomSessionState } from "../src/types.js";

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

    const sessions = new Map<string, Map<string, IntercomSessionState>>();
    const inner = new Map<string, IntercomSessionState>();
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
    const sessions = new Map<string, Map<string, IntercomSessionState>>();
    sessions.set("default", new Map());

    await saveSessions(sessions);

    const tmpFile = join(tmpDir, "plugins", "intercom", "sessions.json.tmp");
    await expect(stat(tmpFile)).rejects.toThrow();
  });

  it("preserves multiple accounts and conversations", async () => {
    await initStateStore(tmpDir);

    const sessions = new Map<string, Map<string, IntercomSessionState>>();
    const account1 = new Map<string, IntercomSessionState>();
    account1.set("conv_1", createInitialSessionState("conv_1", "ws_1"));
    account1.set("conv_2", createInitialSessionState("conv_2", "ws_1"));
    const account2 = new Map<string, IntercomSessionState>();
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

  describe("state-store backward-compat defaults", () => {
    let dir: string;

    beforeEach(async () => {
      dir = await mkdtemp(join(tmpdir(), "intercom-state-"));
    });

    afterEach(async () => {
      await rm(dir, { recursive: true, force: true });
    });

    it("defaults userTurnCount to 0 and escalationFiredAt to null when missing from on-disk state", async () => {
      await initStateStore(dir);
      const filePath = join(dir, "plugins", "intercom", "sessions.json");
      const legacy = {
        version: 1,
        sessions: {
          acct1: {
            conv1: {
              conversationId: "conv1",
              workspaceId: "ws1",
              handoffMode: "agent_active",
              lifecycleState: "open",
              currentAssigneeId: null,
              currentAssigneeType: null,
              lastEventId: null,
              processedEventIds: [],
              outboundMessageIds: [],
              createdAt: "2026-01-01T00:00:00Z",
              updatedAt: "2026-01-01T00:00:00Z",
            },
          },
        },
      };
      await writeFile(filePath, JSON.stringify(legacy), "utf8");

      const loaded = await loadSessions();
      const state = loaded.get("acct1")!.get("conv1")!;

      expect(state.userTurnCount).toBe(0);
      expect(state.userExchangeCount).toBe(0);
      expect(state.escalationFiredAt).toBeNull();
      expect(state.knownFacts).toEqual({});
    });
  });
});
