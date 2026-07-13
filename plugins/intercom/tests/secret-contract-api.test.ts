import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the openclaw SDK helpers so we test THIS contract's wiring in isolation
// (the helpers themselves own the active/inactive-account + top-level-inheritance
// logic and are exercised by openclaw's own suite). The spy must be created via
// vi.hoisted because vi.mock factories are hoisted above module imports.
const { collectSpy, collectNestedSpy } = vi.hoisted(() => ({
  collectSpy: vi.fn(),
  collectNestedSpy: vi.fn(),
}));

vi.mock("openclaw/plugin-sdk/channel-secret-basic-runtime", () => ({
  // Minimal stand-in: a channel "surface" exists iff the config declares that channel.
  // Mirrors the real surface shape closely enough for the accountActive predicate
  // tests: accounts are exposed as {accountId, account, enabled} entries.
  getChannelSurface: (config: any, key: string) => {
    const channel = config?.channels?.[key];
    if (!channel) return null;
    const accounts = Object.entries(channel.accounts ?? {}).map(([accountId, account]: [string, any]) => ({
      accountId,
      account,
      enabled: account.enabled === true,
    }));
    return { channel, surface: { channelKey: key, hasExplicitAccounts: accounts.length > 0, accounts } };
  },
  collectSimpleChannelFieldAssignments: collectSpy,
  collectNestedChannelFieldAssignments: collectNestedSpy,
}));

import {
  secretTargetRegistryEntries,
  collectRuntimeConfigAssignments,
  channelSecrets,
} from "../src/secret-contract-api.js";

describe("intercom channel secret-contract", () => {
  beforeEach(() => {
    collectSpy.mockClear();
    collectNestedSpy.mockClear();
  });

  it("registers the per-account and top-level token as env-resolvable secret_input targets", () => {
    const patterns = secretTargetRegistryEntries.map((e) => e.pathPattern);
    expect(patterns).toContain("channels.intercom.accounts.*.token");
    expect(patterns).toContain("channels.intercom.token");
    // Every target must be a string-valued secret input so openclaw resolves the
    // ref to a plaintext string before the Intercom client reads account.token.
    for (const e of secretTargetRegistryEntries) {
      expect(e.secretShape).toBe("secret_input");
      expect(e.expectedResolvedValue).toBe("string");
      expect(e.includeInAudit).toBe(true);
    }
  });

  it("collects the token field for an intercom account (so a ref is resolved, never handed raw to the client)", () => {
    const config = {
      channels: {
        intercom: {
          accounts: {
            default: {
              enabled: true,
              token: { source: "env", provider: "hydra-env", id: "MUSOAI_INTERCOM_TOKEN" },
            },
          },
        },
      },
    };
    collectRuntimeConfigAssignments({ config, context: {} as any });
    expect(collectSpy).toHaveBeenCalledTimes(1);
    const params = collectSpy.mock.calls[0][0];
    expect(params.channelKey).toBe("intercom");
    expect(params.field).toBe("token");
  });

  it("registers the per-account clickup apiKey as an env-resolvable secret_input target", () => {
    // Regression (2026-07-06..12): the clickup block shipped as a SecretRef in
    // openclaw-edge.json without this registry entry, so openclaw handed the
    // plugin the raw ref object and every escalation ticket POST 401'd with
    // ClickUp OAUTH_019 (`Authorization: [object Object]`).
    const patterns = secretTargetRegistryEntries.map((e) => e.pathPattern);
    expect(patterns).toContain("channels.intercom.accounts.*.clickup.apiKey");
  });

  it("collects the nested clickup.apiKey field so a ref is resolved before the ClickUp client reads it", () => {
    const config = {
      channels: {
        intercom: {
          accounts: {
            default: {
              enabled: true,
              token: "tok",
              clickup: {
                apiKey: { source: "env", provider: "hydra-env", id: "CLICKUP_API_KEY" },
                listId: "901000600160",
              },
            },
            disabled: { enabled: false, token: "tok2" },
          },
        },
      },
    };
    collectRuntimeConfigAssignments({ config, context: {} as any });
    expect(collectNestedSpy).toHaveBeenCalledTimes(1);
    const params = collectNestedSpy.mock.calls[0][0];
    expect(params.channelKey).toBe("intercom");
    expect(params.nestedKey).toBe("clickup");
    expect(params.field).toBe("apiKey");
    // clickup is per-account only — the top-level channel object never carries it.
    expect(params.topLevelActive).toBe(false);
    // Only enabled accounts are active for resolution.
    const surface = params.surface;
    const enabledEntry = surface.accounts.find((e: any) => e.accountId === "default");
    const disabledEntry = surface.accounts.find((e: any) => e.accountId === "disabled");
    expect(params.accountActive(enabledEntry)).toBe(true);
    expect(params.accountActive(disabledEntry)).toBe(false);
  });

  it("is a no-op when no intercom channel is configured (no spurious assignments)", () => {
    collectRuntimeConfigAssignments({ config: { channels: {} }, context: {} as any });
    expect(collectSpy).not.toHaveBeenCalled();
    expect(collectNestedSpy).not.toHaveBeenCalled();
  });

  it("exposes the channelSecrets bundle openclaw's loader consumes", () => {
    expect(channelSecrets.secretTargetRegistryEntries).toBe(secretTargetRegistryEntries);
    expect(channelSecrets.collectRuntimeConfigAssignments).toBe(collectRuntimeConfigAssignments);
  });
});
