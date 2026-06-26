import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the openclaw SDK helpers so we test THIS contract's wiring in isolation
// (the helpers themselves own the active/inactive-account + top-level-inheritance
// logic and are exercised by openclaw's own suite). The spy must be created via
// vi.hoisted because vi.mock factories are hoisted above module imports.
const { collectSpy } = vi.hoisted(() => ({ collectSpy: vi.fn() }));

vi.mock("openclaw/plugin-sdk/channel-secret-basic-runtime", () => ({
  // Minimal stand-in: a channel "surface" exists iff the config declares that channel.
  getChannelSurface: (config: any, key: string) => {
    const channel = config?.channels?.[key];
    if (!channel) return null;
    return { channel, surface: { channelKey: key } };
  },
  collectSimpleChannelFieldAssignments: collectSpy,
}));

import {
  secretTargetRegistryEntries,
  collectRuntimeConfigAssignments,
  channelSecrets,
} from "../src/secret-contract-api.js";

describe("intercom channel secret-contract", () => {
  beforeEach(() => collectSpy.mockClear());

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

  it("is a no-op when no intercom channel is configured (no spurious assignments)", () => {
    collectRuntimeConfigAssignments({ config: { channels: {} }, context: {} as any });
    expect(collectSpy).not.toHaveBeenCalled();
  });

  it("exposes the channelSecrets bundle openclaw's loader consumes", () => {
    expect(channelSecrets.secretTargetRegistryEntries).toBe(secretTargetRegistryEntries);
    expect(channelSecrets.collectRuntimeConfigAssignments).toBe(collectRuntimeConfigAssignments);
  });
});
