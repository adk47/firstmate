import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import pluginEntry from "../src/index.js";

describe("support-tools plugin entry — tool registration", () => {
  it("registers exactly 16 tools", () => {
    const registered: string[] = [];
    const api = {
      pluginConfig: {
        musoApiBase: "https://api.muso.ai",
        adminEmail: "admin@muso.ai", adminPassword: "pw", clickupApiKey: "k", clickupListId: "list",
        clickupProfileIdFieldId: "pf", clickupUserEmailFieldId: "ef",
      },
      registerTool: (_factory: any, opts: { name: string }) => { registered.push(opts.name); },
    };
    (pluginEntry as any).register(api);
    expect(registered.sort()).toEqual([
      "create_ticket",
      "credit_verification_check",
      "credits_search",
      "credits_verify",
      "dedupe_check",
      "founding_buyback_link",
      "founding_status",
      "order_address_update",
      "order_lookup",
      "profile_lookup",
      "profile_status",
      "profiles_claim_self",
      "profiles_consolidate",
      "remove_credits",
      "subscription_status",
      "support_action_router",
    ]);
  });
});

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
    delete process.env.MUSO_ADMIN_EMAIL;
    delete process.env.MUSO_ADMIN_PASSWORD;
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
        adminEmail: "admin@muso.ai",
        adminPassword: "pw",
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

  it("ignores non-string secret-ref objects in pluginConfig and falls back to env vars", async () => {
    // openclaw 4.27 passes raw entry.config — including unresolved
    // secret-ref objects like {source: "env", id: "X"} — as
    // api.pluginConfig. Treating those as strings crashed the
    // required-keys .startsWith() check on register and took main
    // gateway into a 60+ restart crash-loop on 2026-05-05.
    process.env.MUSO_ADMIN_EMAIL = "admin@muso.ai";
    process.env.MUSO_ADMIN_PASSWORD = "pw";
    process.env.CLICKUP_API_KEY = "ck";
    process.env.CLICKUP_LIST_ID = "list-env";
    process.env.CLICKUP_PROFILE_ID_FIELD_ID = "fld-env-prof";
    process.env.CLICKUP_USER_EMAIL_FIELD_ID = "fld-env-email";
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const mod = await import("../src/index.js");
    const plugin = mod.default;

    const api = {
      pluginConfig: {
        clickupApiKey: { source: "env", provider: "hydra-env", id: "CLICKUP_API_KEY" },
        clickupListId: { source: "env", provider: "hydra-env", id: "CLICKUP_LIST_ID" },
        clickupProfileIdFieldId: { source: "env", provider: "hydra-env", id: "CLICKUP_PROFILE_ID_FIELD_ID" },
        clickupUserEmailFieldId: { source: "env", provider: "hydra-env", id: "CLICKUP_USER_EMAIL_FIELD_ID" },
      },
      registerTool: vi.fn(),
    };

    expect(() => plugin.register(api)).not.toThrow();
    expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining("Missing config keys"));
    expect(api.registerTool).toHaveBeenCalled();
    warnSpy.mockRestore();
  });

  it("falls back to env vars for all ClickUp fields when pluginConfig is empty", async () => {
    process.env.MUSO_ADMIN_EMAIL = "admin@muso.ai";
    process.env.MUSO_ADMIN_PASSWORD = "pw";
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

// The dark-ship flag must be wired through register() — the operator writes the
// natural JSON boolean `true` in openclaw-edge.json, which the string-only
// pluginConfig filter would otherwise silently drop (flag stays OFF, rollout
// burns with no warning).
describe("support-tools creditVerificationEnabled flag wiring", () => {
  const savedFlagEnv = process.env.CREDIT_VERIFICATION_ENABLED;
  beforeEach(() => {
    delete process.env.CREDIT_VERIFICATION_ENABLED;
  });
  afterEach(() => {
    if (savedFlagEnv === undefined) delete process.env.CREDIT_VERIFICATION_ENABLED;
    else process.env.CREDIT_VERIFICATION_ENABLED = savedFlagEnv;
  });

  function registerAndGetCvTool(pluginConfig: Record<string, unknown>) {
    let factory: ((ctx: any) => any) | undefined;
    const api = {
      pluginConfig: {
        adminEmail: "admin@muso.ai", adminPassword: "pw", clickupApiKey: "k", clickupListId: "list",
        clickupProfileIdFieldId: "pf", clickupUserEmailFieldId: "ef",
        ...pluginConfig,
      },
      registerTool: (f: any, opts: { name: string }) => {
        if (opts.name === "credit_verification_check") factory = f;
      },
    };
    (pluginEntry as any).register(api);
    expect(factory).toBeDefined();
    return factory!({ sessionKey: "unknown" });
  }

  const execute = async (tool: any) => JSON.parse((await tool.execute("id", {})).content[0].text);

  it("stays disabled by default (no flag anywhere)", async () => {
    const out = await execute(registerAndGetCvTool({}));
    expect(out.disabled).toBe(true);
  });

  it("enables on the natural JSON boolean true in entry config", async () => {
    const out = await execute(registerAndGetCvTool({ creditVerificationEnabled: true }));
    // Enabled tool proceeds past the flag gate and fails closed on the
    // underivable conv-id — proof the flag took effect.
    expect(out.disabled).toBeUndefined();
    expect(out.owner_undetermined).toBe(true);
  });

  it('enables on the string "true" and the number 1; stays disabled on other values', async () => {
    expect((await execute(registerAndGetCvTool({ creditVerificationEnabled: "true" }))).disabled).toBeUndefined();
    expect((await execute(registerAndGetCvTool({ creditVerificationEnabled: 1 }))).disabled).toBeUndefined();
    expect((await execute(registerAndGetCvTool({ creditVerificationEnabled: "yes" }))).disabled).toBe(true);
    expect((await execute(registerAndGetCvTool({ creditVerificationEnabled: false }))).disabled).toBe(true);
  });

  it("a non-primitive config value (e.g. an unresolved secret-ref object) does NOT shadow the env fallback", async () => {
    process.env.CREDIT_VERIFICATION_ENABLED = "true";
    const out = await execute(
      registerAndGetCvTool({ creditVerificationEnabled: { source: "env", provider: "hydra-env", id: "CREDIT_VERIFICATION_ENABLED" } }),
    );
    expect(out.disabled).toBeUndefined();
    expect(out.owner_undetermined).toBe(true);
  });
});

describe("support-tools manifest contracts.tools drift check", () => {
  it("contracts.tools in openclaw.plugin.json matches the tools registered in src/index.ts", () => {
    const __dirname_local = dirname(fileURLToPath(import.meta.url));
    const manifestPath = resolve(__dirname_local, "../openclaw.plugin.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf-8"));
    const declared = (manifest.contracts?.tools ?? []) as string[];

    const registered: string[] = [];
    const api = {
      pluginConfig: {
        musoApiBase: "https://api.muso.ai",
        adminEmail: "admin@muso.ai", adminPassword: "pw", clickupApiKey: "k", clickupListId: "list",
        clickupProfileIdFieldId: "pf", clickupUserEmailFieldId: "ef",
      },
      registerTool: (_factory: any, opts: { name: string }) => { registered.push(opts.name); },
    };
    (pluginEntry as any).register(api);

    expect(declared.sort()).toEqual(registered.sort());
  });
});
