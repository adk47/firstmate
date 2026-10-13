import { describe, it, expect, beforeEach } from "vitest";
import {
  listIntercomAccountIds,
  resolveIntercomAccount,
  inspectIntercomAccount,
  setCapturedConfig,
  clearCapturedConfig,
  validateClickupConfig,
} from "../src/config.js";
import type { IntercomAccountConfig } from "../src/types.js";
import { DEFAULT_FALLBACK_ACK } from "../src/types.js";

const validConfig = {
  channels: {
    intercom: {
      accounts: {
        default: {
          enabled: true,
          workspaceId: "ws_prod",
          token: "tok_123",
          webhookSecret: "secret_456",
          botAdminId: "bot_1",
          defaultInboxId: "inbox_1",
          fallbackSlackSupervisionChannel: "C_SUPPORT",
          fallbackAcknowledgement: "Custom message",
          requireMappedHumanAdmin: true,
          adminMapping: { U_NICK: "admin_1" },
        },
        staging: {
          enabled: false,
          workspaceId: "ws_staging",
          token: "tok_staging",
          webhookSecret: "secret_staging",
          botAdminId: "bot_staging",
        },
      },
    },
  },
};

describe("listIntercomAccountIds", () => {
  it("returns account IDs from config", () => {
    const ids = listIntercomAccountIds(validConfig);
    expect(ids).toContain("default");
    expect(ids).toContain("staging");
    expect(ids).toHaveLength(2);
  });

  it("returns empty array when no intercom config", () => {
    expect(listIntercomAccountIds({})).toEqual([]);
    expect(listIntercomAccountIds({ channels: {} })).toEqual([]);
  });
});

describe("resolveIntercomAccount", () => {
  it("resolves default account", () => {
    const account = resolveIntercomAccount(validConfig);
    expect(account.accountId).toBe("default");
    expect(account.workspaceId).toBe("ws_prod");
    expect(account.token).toBe("tok_123");
    expect(account.enabled).toBe(true);
    expect(account.fallbackAcknowledgement).toBe("Custom message");
  });

  it("resolves named account", () => {
    const account = resolveIntercomAccount(validConfig, "staging");
    expect(account.accountId).toBe("staging");
    expect(account.workspaceId).toBe("ws_staging");
    expect(account.enabled).toBe(false);
  });

  it("round-trips riskAssessment and clickup blocks (the defanged edge backstop config)", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: {
        ...validConfig.channels.intercom.accounts.default,
        riskAssessment: { enabled: true, turnCountHardCap: 14, judgeMinTurnCount: 4 },
        clickup: { apiKey: "pk_test", listId: "901000600160", userEmailFieldId: "f_email", profileIdFieldId: "f_prof" },
      } } } },
    };
    const account = resolveIntercomAccount(cfg);
    expect(account.riskAssessment).toEqual({ enabled: true, turnCountHardCap: 14, judgeMinTurnCount: 4 });
    // openrouterApiKey deliberately absent → LLM judge stays off downstream (buildRiskOptions).
    expect(account.riskAssessment?.openrouterApiKey).toBeUndefined();
    expect(account.clickup).toEqual({ apiKey: "pk_test", listId: "901000600160", userEmailFieldId: "f_email", profileIdFieldId: "f_prof" });
  });

  it("throws on missing account", () => {
    expect(() => resolveIntercomAccount(validConfig, "nonexistent")).toThrow('account "nonexistent" not found');
  });

  it("throws on missing token", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { workspaceId: "ws_1" } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow("missing token");
  });

  it("throws on missing workspaceId", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { token: "tok_1" } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow("missing workspaceId");
  });

  it("throws on missing webhookSecret", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { token: "t", workspaceId: "w", botAdminId: "b" } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow("missing webhookSecret");
  });

  it("throws on missing botAdminId", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { token: "t", workspaceId: "w", webhookSecret: "s" } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow("missing botAdminId");
  });

  const minimalValid = {
    channels: { intercom: { accounts: { default: { token: "t", workspaceId: "w", webhookSecret: "s", botAdminId: "b" } } } },
  };

  it("uses default fallback acknowledgement when not specified", () => {
    const account = resolveIntercomAccount(minimalValid);
    expect(account.fallbackAcknowledgement).toBe(DEFAULT_FALLBACK_ACK);
  });

  it("defaults requireMappedHumanAdmin to true", () => {
    const account = resolveIntercomAccount(minimalValid);
    expect(account.requireMappedHumanAdmin).toBe(true);
  });
});

describe("inspectIntercomAccount", () => {
  it("reports enabled and configured for valid account", () => {
    const result = inspectIntercomAccount(validConfig);
    expect(result.enabled).toBe(true);
    expect(result.configured).toBe(true);
  });

  it("reports not configured for missing config", () => {
    const result = inspectIntercomAccount({});
    expect(result.enabled).toBe(false);
    expect(result.configured).toBe(false);
  });

  it("reports disabled when enabled is false", () => {
    const result = inspectIntercomAccount(validConfig, "staging");
    expect(result.enabled).toBe(false);
    expect(result.configured).toBe(true);
  });
});

describe("config fallback (capturedConfig)", () => {
  beforeEach(() => {
    clearCapturedConfig();
  });

  it("listIntercomAccountIds returns [] when cfg and capturedConfig are both null", () => {
    expect(listIntercomAccountIds(undefined)).toEqual([]);
  });

  it("listIntercomAccountIds uses capturedConfig when cfg is undefined", () => {
    setCapturedConfig(validConfig);
    const ids = listIntercomAccountIds(undefined);
    expect(ids).toContain("default");
    expect(ids).toContain("staging");
  });

  it("resolveIntercomAccount uses capturedConfig when cfg is undefined", () => {
    setCapturedConfig(validConfig);
    const account = resolveIntercomAccount(undefined);
    expect(account.accountId).toBe("default");
    expect(account.workspaceId).toBe("ws_prod");
    expect(account.token).toBe("tok_123");
    expect(account.enabled).toBe(true);
  });

  it("resolveIntercomAccount returns disabled stub when both cfg and capturedConfig are null", () => {
    const account = resolveIntercomAccount(undefined);
    expect(account.enabled).toBe(false);
    expect(account.token).toBe("");
    expect(account.workspaceId).toBe("");
  });

  it("explicit cfg takes precedence over capturedConfig", () => {
    const altConfig = {
      channels: {
        intercom: {
          accounts: {
            default: {
              enabled: false,
              workspaceId: "ws_alt",
              token: "tok_alt",
              webhookSecret: "secret_alt",
              botAdminId: "bot_alt",
            },
          },
        },
      },
    };
    setCapturedConfig(validConfig);
    const account = resolveIntercomAccount(altConfig);
    expect(account.workspaceId).toBe("ws_alt");
    expect(account.token).toBe("tok_alt");
  });

  it("inspectIntercomAccount uses capturedConfig when cfg is undefined", () => {
    setCapturedConfig(validConfig);
    const result = inspectIntercomAccount(undefined);
    expect(result.enabled).toBe(true);
    expect(result.configured).toBe(true);
  });

  it("clearCapturedConfig resets the fallback", () => {
    setCapturedConfig(validConfig);
    clearCapturedConfig();
    const account = resolveIntercomAccount(undefined);
    expect(account.enabled).toBe(false);
    expect(account.token).toBe("");
  });
});

describe("validateClickupConfig", () => {
  const baseAccount = {
    accountId: "default",
    enabled: true,
    workspaceId: "ws_prod",
    token: "tok_123",
    webhookSecret: "secret_456",
    botAdminId: "bot_1",
    defaultInboxId: "inbox_1",
    fallbackSlackSupervisionChannel: "",
    fallbackAcknowledgement: "ack",
    requireMappedHumanAdmin: true,
    adminMapping: {},
  } as IntercomAccountConfig;

  const validClickup = {
    apiKey: "pk_123_ABC",
    listId: "901000600160",
    userEmailFieldId: "field-email",
    profileIdFieldId: "field-profile",
  };

  it("returns null when clickup is absent (optional)", () => {
    expect(validateClickupConfig(baseAccount)).toBeNull();
  });

  it("returns null for a fully populated string config", () => {
    expect(validateClickupConfig({ ...baseAccount, clickup: validClickup })).toBeNull();
  });

  it("names the first missing/empty field", () => {
    expect(
      validateClickupConfig({ ...baseAccount, clickup: { ...validClickup, apiKey: "" } }),
    ).toBe("apiKey");
    expect(
      validateClickupConfig({ ...baseAccount, clickup: { ...validClickup, listId: "" } }),
    ).toBe("listId");
  });

  it("rejects an unresolved SecretRef object as apiKey (would 401 as '[object Object]')", () => {
    // Regression: openclaw only resolves SecretRefs at paths the channel's
    // secret contract registers. If the contract misses clickup.apiKey, the
    // plugin receives the raw ref object, which is truthy — so a bare
    // truthiness check lets it through and every escalation 401s with
    // ClickUp OAUTH_019 ("Oauth token not found") from `Authorization:
    // [object Object]`. Boot validation must reject any non-string value.
    const secretRef = { source: "env", provider: "hydra-env", id: "CLICKUP_API_KEY" };
    expect(
      validateClickupConfig({
        ...baseAccount,
        clickup: { ...validClickup, apiKey: secretRef as unknown as string },
      }),
    ).toBe("apiKey");
  });

  it("rejects whitespace-only values", () => {
    expect(
      validateClickupConfig({ ...baseAccount, clickup: { ...validClickup, apiKey: "   " } }),
    ).toBe("apiKey");
  });
});

describe("dispatch coalescing / timeout config passthrough", () => {
  const base = {
    enabled: true,
    workspaceId: "w",
    token: "t",
    webhookSecret: "s",
    botAdminId: "b",
  };

  it("passes dispatchTimeoutMs through (regression: #616 shipped the field but not this mapping, so per-account overrides were silently dead)", () => {
    const cfg = { channels: { intercom: { accounts: { default: { ...base, dispatchTimeoutMs: 120000 } } } } };
    expect(resolveIntercomAccount(cfg).dispatchTimeoutMs).toBe(120000);
  });

  it("passes coalesceDispatch=false through and leaves both undefined when absent", () => {
    const cfg = { channels: { intercom: { accounts: { default: { ...base, coalesceDispatch: false } } } } };
    expect(resolveIntercomAccount(cfg).coalesceDispatch).toBe(false);
    const bare = { channels: { intercom: { accounts: { default: { ...base } } } } };
    expect(resolveIntercomAccount(bare).coalesceDispatch).toBeUndefined();
    expect(resolveIntercomAccount(bare).dispatchTimeoutMs).toBeUndefined();
  });
});

describe("jev.questionsVersion / jev.shadowVersions config (shadow-only rollout surface)", () => {
  const base = {
    enabled: true,
    workspaceId: "w",
    token: "t",
    webhookSecret: "s",
    botAdminId: "b",
  };

  it("defaults questionsVersion to v1 and shadowVersions to [] when jev is configured but neither key is set", () => {
    const cfg = { channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k" } } } } } };
    const account = resolveIntercomAccount(cfg);
    expect(account.jev?.questionsVersion).toBe("v1");
    expect(account.jev?.shadowVersions).toEqual([]);
  });

  it("passes questionsVersion=v2 and shadowVersions through unchanged", () => {
    const cfg = {
      channels: {
        intercom: {
          accounts: {
            default: { ...base, jev: { enabled: true, apiKey: "k", questionsVersion: "v2", shadowVersions: ["v1"] } },
          },
        },
      },
    };
    const account = resolveIntercomAccount(cfg);
    expect(account.jev?.questionsVersion).toBe("v2");
    expect(account.jev?.shadowVersions).toEqual(["v1"]);
  });

  it("throws on an invalid questionsVersion", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", questionsVersion: "v3" } } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/questionsVersion must be "v1" or "v2"/);
  });

  it("throws when shadowVersions is not an array of strings", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", shadowVersions: "v2" } } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/shadowVersions must be an array of strings/);
  });

  it("throws when shadowVersions contains a non-string entry", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", shadowVersions: [1] } } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/shadowVersions must be an array of strings/);
  });

  // QA NO-GO on #1022 (finding 1, comment 4088080438): shadowVersions: ["v02"]
  // passed this validation, channel.ts then silently mapped it to the v1
  // runner while handler.ts still wrote questions_version: "v02" on the
  // shadow row — a corrupted cohort labelled as an experiment that was never
  // actually run. Restrict entries to the implemented set (v1, v2).
  it("throws when shadowVersions contains an unsupported version string (e.g. a typo)", () => {
    const cfg = {
      channels: {
        intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", shadowVersions: ["v02"] } } } },
      },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/shadowVersions\[0\] "v02" is not a supported version \(v1, v2\)/);
  });

  it("throws when shadowVersions contains a supported version alongside an unsupported one", () => {
    const cfg = {
      channels: {
        intercom: {
          accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", shadowVersions: ["v2", "v3"] } } },
        },
      },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/shadowVersions\[1\] "v3" is not a supported version \(v1, v2\)/);
  });

  it("accepts shadowVersions containing only implemented versions", () => {
    const cfg = {
      channels: {
        intercom: {
          accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", shadowVersions: ["v1", "v2"] } } },
        },
      },
    };
    expect(resolveIntercomAccount(cfg).jev?.shadowVersions).toEqual(["v1", "v2"]);
  });

  it("leaves agentInstructionsPath undefined when absent", () => {
    const cfg = { channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k" } } } } } };
    expect(resolveIntercomAccount(cfg).jev?.agentInstructionsPath).toBeUndefined();
  });

  it("passes agentInstructionsPath through unchanged", () => {
    const cfg = {
      channels: {
        intercom: {
          accounts: {
            default: { ...base, jev: { enabled: true, apiKey: "k", agentInstructionsPath: "/opt/hydra/workspaces/support/SOUL.md" } },
          },
        },
      },
    };
    expect(resolveIntercomAccount(cfg).jev?.agentInstructionsPath).toBe("/opt/hydra/workspaces/support/SOUL.md");
  });

  it("throws when agentInstructionsPath is an empty/blank string", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", agentInstructionsPath: "  " } } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/agentInstructionsPath must be a non-empty string/);
  });

  it("throws when agentInstructionsPath is not a string", () => {
    const cfg = {
      channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", agentInstructionsPath: 42 } } } } },
    };
    expect(() => resolveIntercomAccount(cfg)).toThrow(/agentInstructionsPath must be a non-empty string/);
  });
});

describe("jev.shadowTimeoutMs config (MUS-3192)", () => {
  const base = { enabled: true, workspaceId: "w", token: "t", webhookSecret: "s", botAdminId: "b" };
  const withJev = (jev: Record<string, unknown>) => ({
    channels: { intercom: { accounts: { default: { ...base, jev: { enabled: true, apiKey: "k", ...jev } } } } },
  });

  it("passes a positive integer through", () => {
    expect(resolveIntercomAccount(withJev({ shadowTimeoutMs: 5000 })).jev?.shadowTimeoutMs).toBe(5000);
  });

  it("leaves it undefined when unset", () => {
    expect(resolveIntercomAccount(withJev({})).jev?.shadowTimeoutMs).toBeUndefined();
  });

  it.each([0, -1, 1.5, "5000", Number.NaN, null])("rejects %p", (bad) => {
    expect(() => resolveIntercomAccount(withJev({ shadowTimeoutMs: bad }))).toThrow(/jev\.shadowTimeoutMs/);
  });
});
