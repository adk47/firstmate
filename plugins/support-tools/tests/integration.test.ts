import { describe, it, expect, beforeAll } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname_local = dirname(fileURLToPath(import.meta.url));

// Build is run at deploy time; the integration test requires the dist output
// because that's what the openclaw runtime actually loads. If you haven't run
// `npm run build` before tests, this test will instruct you to.
const distPath = resolve(__dirname_local, "../dist/index.js");
const manifestPath = resolve(__dirname_local, "../openclaw.plugin.json");

describe("integration: built plugin loads through a contracts-enforcing api stub", () => {
  let pluginModule: { default: { register: (api: unknown) => void } } | null = null;

  beforeAll(async () => {
    if (!existsSync(distPath)) {
      throw new Error(
        `Built dist not found at ${distPath}. Run \`npm run build\` in plugins/support-tools before running tests.`
      );
    }
    pluginModule = (await import(distPath)) as any;
  });

  it("exports a default with a register function", () => {
    expect(pluginModule).toBeTruthy();
    expect(typeof pluginModule!.default).toBe("object");
    expect(typeof pluginModule!.default.register).toBe("function");
  });

  it("registers all 22 declared tools without producing contracts diagnostics", () => {
    const manifest = JSON.parse(readFileSync(manifestPath, "utf-8"));
    const declared: string[] = manifest.contracts?.tools ?? [];

    const registered: string[] = [];
    const diagnostics: Array<{ level: string; message: string }> = [];

    const api = {
      pluginConfig: {
        musoApiBase: "https://api.muso.ai",
        adminEmail: "admin@muso.ai",
        adminPassword: "test-password",
        clickupApiKey: "test-key",
        clickupListId: "test-list",
        clickupProfileIdFieldId: "test-pf",
        clickupUserEmailFieldId: "test-ef",
      },
      registerTool: (_factory: unknown, opts: { name: string }) => {
        if (declared.length === 0) {
          diagnostics.push({ level: "error", message: "plugin must declare contracts.tools before registering agent tools" });
          return;
        }
        if (!declared.includes(opts.name)) {
          diagnostics.push({ level: "error", message: `plugin must declare contracts.tools for: ${opts.name}` });
          return;
        }
        registered.push(opts.name);
      },
      registerSkill: (_skill: unknown) => {},
      registerHook: (_hook: unknown) => {},
    };

    (pluginModule!.default as any).register(api);

    expect(diagnostics).toEqual([]);
    expect(registered.sort()).toEqual([
      "cancel_subscription",
      "create_ticket",
      "credit_verification_check",
      "credits_search",
      "credits_verify",
      "dedupe_check",
      "founding_buyback_link",
      "founding_status",
      "order_address_update",
      "order_lookup",
      "profile_analytics_status",
      "profile_claim_status",
      "profile_credits_status",
      "profile_lookup",
      "profile_status",
      "profiles_claim_self",
      "profiles_consolidate",
      "remove_credits",
      "retention_offer_apply",
      "retention_offer_check",
      "subscription_status",
      "support_action_router",
    ]);
  });

  it("manifest contracts.tools matches the registered set exactly (drift check)", () => {
    const manifest = JSON.parse(readFileSync(manifestPath, "utf-8"));
    const declared: string[] = manifest.contracts?.tools ?? [];

    const registered: string[] = [];
    const api = {
      pluginConfig: {
        musoApiBase: "https://api.muso.ai",
        adminEmail: "admin@muso.ai",
        adminPassword: "pw",
        clickupApiKey: "k",
        clickupListId: "list",
        clickupProfileIdFieldId: "pf",
        clickupUserEmailFieldId: "ef",
      },
      registerTool: (_factory: unknown, opts: { name: string }) => { registered.push(opts.name); },
      registerSkill: (_skill: unknown) => {},
      registerHook: (_hook: unknown) => {},
    };
    (pluginModule!.default as any).register(api);

    expect(declared.sort()).toEqual(registered.sort());
  });
});
