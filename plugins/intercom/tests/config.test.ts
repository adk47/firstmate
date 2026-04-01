import { describe, it, expect, beforeEach } from "vitest";
import {
  listIntercomAccountIds,
  resolveIntercomAccount,
  inspectIntercomAccount,
  setCapturedConfig,
  clearCapturedConfig,
} from "../src/config.js";
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
