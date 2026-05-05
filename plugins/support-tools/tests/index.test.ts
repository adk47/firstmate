import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

describe("support-tools plugin entry", () => {
  it("exports a default plugin definition with correct id and name", async () => {
    const mod = await import("../src/index.js");
    const plugin = mod.default;

    expect(plugin).toBeDefined();
    expect(plugin.id).toBe("support-tools");
    expect(plugin.name).toBe("Support Agent Tools");
  });
});

// Config resolution: verify the plugin reads from api.pluginConfig (the
// OpenClaw entry-config surface) and that env-var fallbacks cover all
// ClickUp fields. Without these guarantees, partial configs result in
// silent create_ticket failures (see PR #238 review).
describe("support-tools config resolution", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    delete process.env.CLICKUP_API_KEY;
    delete process.env.CLICKUP_LIST_ID;
    delete process.env.CLICKUP_USER_EMAIL_FIELD_ID;
    delete process.env.CLICKUP_PROFILE_ID_FIELD_ID;
  });

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it("warns when api.pluginConfig is empty and no env vars are set", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const mod = await import("../src/index.js");
    const plugin = mod.default;

    const api = {
      pluginConfig: {},
      registerTool: vi.fn(),
    };
    plugin.register(api);

    expect(warnSpy).toHaveBeenCalled();
    const calls = warnSpy.mock.calls.map((c) => String(c[0]));
    expect(calls.some((m) => m.includes("Missing config keys"))).toBe(true);
    expect(calls.some((m) => m.includes("clickupListId"))).toBe(true);
    warnSpy.mockRestore();
  });

  it("reads ClickUp fields from api.pluginConfig (OpenClaw entry config surface)", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const mod = await import("../src/index.js");
    const plugin = mod.default;

    const api = {
      pluginConfig: {
        musoApiKey: "k",
        clickupApiKey: "ck",
        clickupListId: "list-123",
        clickupProfileIdFieldId: "fld-prof",
        clickupUserEmailFieldId: "fld-email",
      },
      registerTool: vi.fn(),
    };
    plugin.register(api);

    expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining("Missing config keys"));
    expect(api.registerTool).toHaveBeenCalled();
    warnSpy.mockRestore();
  });

  it("falls back to env vars for all ClickUp fields when pluginConfig is empty", async () => {
    process.env.MUSO_CUSTOMER_API_KEY = "k";
    process.env.CLICKUP_API_KEY = "ck";
    process.env.CLICKUP_LIST_ID = "list-env";
    process.env.CLICKUP_PROFILE_ID_FIELD_ID = "fld-env-prof";
    process.env.CLICKUP_USER_EMAIL_FIELD_ID = "fld-env-email";
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const mod = await import("../src/index.js");
    const plugin = mod.default;

    const api = { pluginConfig: {}, registerTool: vi.fn() };
    plugin.register(api);

    expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining("Missing config keys"));
    warnSpy.mockRestore();
  });
});
