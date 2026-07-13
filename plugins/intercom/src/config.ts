import type { IntercomAccountConfig } from "./types.js";
import { DEFAULT_FALLBACK_ACK } from "./types.js";

// Config captured at register() time — used as fallback when the Gateway
// passes undefined to channel lifecycle callbacks.
let capturedConfig: Record<string, unknown> | null = null;

let fallbackLogged = false;

export function setCapturedConfig(cfg: Record<string, unknown>): void {
  if (capturedConfig !== null) {
    console.warn("[intercom:config] overwriting previously captured config");
  }
  capturedConfig = cfg;
  fallbackLogged = false;
}

export function clearCapturedConfig(): void {
  capturedConfig = null;
  fallbackLogged = false;
}

function resolveConfig(cfg: Record<string, unknown> | undefined | null): Record<string, unknown> | null {
  if (cfg) return cfg;
  if (capturedConfig) {
    if (!fallbackLogged) {
      console.warn("[intercom:config] cfg was undefined — using config captured at register() time");
      fallbackLogged = true;
    }
    return capturedConfig;
  }
  return null;
}

export function listIntercomAccountIds(cfg: Record<string, unknown> | undefined | null): string[] {
  const resolved = resolveConfig(cfg);
  if (!resolved) return [];
  const channels = resolved.channels as Record<string, unknown> | undefined;
  const intercom = channels?.intercom as Record<string, unknown> | undefined;
  const accounts = intercom?.accounts as Record<string, unknown> | undefined;
  return accounts ? Object.keys(accounts) : [];
}

export function resolveIntercomAccount(
  cfg: Record<string, unknown> | undefined | null,
  accountId?: string | null,
): IntercomAccountConfig & { accountId: string } {
  const id = accountId ?? "default";
  const resolved = resolveConfig(cfg);

  // Fall back to captured config from register() time, or return disabled stub.
  if (!resolved) {
    return {
      accountId: id,
      enabled: false,
      workspaceId: "",
      token: "",
      webhookSecret: "",
      botAdminId: "",
      defaultInboxId: "",
      fallbackSlackSupervisionChannel: "",
      fallbackAcknowledgement: DEFAULT_FALLBACK_ACK,
      requireMappedHumanAdmin: true,
      adminMapping: {},
      riskAssessment: undefined,
      clickup: undefined,
      blockedChannelTags: [],
      personalization: undefined,
    };
  }

  const channels = resolved.channels as Record<string, unknown> | undefined;
  const intercom = channels?.intercom as Record<string, unknown> | undefined;
  const accounts = intercom?.accounts as Record<string, unknown> | undefined;
  const account = accounts?.[id] as Partial<IntercomAccountConfig> | undefined;

  if (!account) {
    throw new Error(`intercom: account "${id}" not found in config`);
  }
  if (!account.token) {
    throw new Error(`intercom: account "${id}" missing token`);
  }
  if (!account.workspaceId) {
    throw new Error(`intercom: account "${id}" missing workspaceId`);
  }
  if (!account.webhookSecret) {
    throw new Error(`intercom: account "${id}" missing webhookSecret`);
  }
  if (!account.botAdminId) {
    throw new Error(`intercom: account "${id}" missing botAdminId`);
  }

  return {
    accountId: id,
    enabled: account.enabled ?? false,
    workspaceId: account.workspaceId,
    token: account.token,
    webhookSecret: account.webhookSecret,
    botAdminId: account.botAdminId,
    defaultInboxId: account.defaultInboxId ?? "",
    fallbackSlackSupervisionChannel: account.fallbackSlackSupervisionChannel ?? "",
    fallbackAcknowledgement: account.fallbackAcknowledgement ?? DEFAULT_FALLBACK_ACK,
    requireMappedHumanAdmin: account.requireMappedHumanAdmin ?? true,
    adminMapping: account.adminMapping ?? {},
    riskAssessment: account.riskAssessment,
    clickup: account.clickup,
    // Passthroughs for the dispatch lane-wedge mitigations. dispatchTimeoutMs
    // shipped in #616 but was missing here, so the per-account override was
    // silently dead (the default still applied downstream).
    ...(typeof account.dispatchTimeoutMs === "number" ? { dispatchTimeoutMs: account.dispatchTimeoutMs } : {}),
    ...(typeof account.coalesceDispatch === "boolean" ? { coalesceDispatch: account.coalesceDispatch } : {}),
    blockedChannelTags: Array.isArray(account.blockedChannelTags)
      ? account.blockedChannelTags.filter((t): t is string => typeof t === "string" && t.length > 0)
      : [],
    personalization: account.personalization
      ? {
          enabled: account.personalization.enabled === true,
          ...(typeof account.personalization.timeoutMs === "number"
            ? { timeoutMs: account.personalization.timeoutMs }
            : {}),
        }
      : undefined,
    kbRetrieval: account.kbRetrieval
      ? {
          enabled: account.kbRetrieval.enabled === true,
          ...(typeof account.kbRetrieval.timeoutMs === "number" ? { timeoutMs: account.kbRetrieval.timeoutMs } : {}),
          ...(typeof account.kbRetrieval.maxResults === "number" ? { maxResults: account.kbRetrieval.maxResults } : {}),
          ...(typeof account.kbRetrieval.minScore === "number" ? { minScore: account.kbRetrieval.minScore } : {}),
          ...(typeof account.kbRetrieval.agentId === "string" ? { agentId: account.kbRetrieval.agentId } : {}),
        }
      : undefined,
  };
}

// Validate that account.clickup, when present, has all required fields populated
// with non-empty STRINGS. Returns null if config is fully valid; otherwise returns
// the name of the first missing/invalid field. Use at boot to fail loudly rather
// than getting silent 401s from ClickUp on every escalation. The typeof check is
// load-bearing: an unresolved SecretRef ({source, provider, id} — handed through
// raw when the secret contract misses the path) is truthy, and stringifies into
// `Authorization: [object Object]` → ClickUp OAUTH_019 on every ticket POST.
export function validateClickupConfig(account: IntercomAccountConfig): string | null {
  if (!account.clickup) return null; // ClickUp is optional
  const required: (keyof NonNullable<IntercomAccountConfig["clickup"]>)[] = [
    "apiKey",
    "listId",
    "userEmailFieldId",
    "profileIdFieldId",
  ];
  for (const key of required) {
    const value = account.clickup[key];
    if (typeof value !== "string" || value.trim() === "") return key;
  }
  return null;
}

export function inspectIntercomAccount(
  cfg: Record<string, unknown> | undefined | null,
  accountId?: string | null,
): { enabled: boolean; configured: boolean } {
  try {
    const account = resolveIntercomAccount(cfg, accountId);
    return {
      enabled: account.enabled,
      configured: Boolean(account.token && account.workspaceId),
    };
  } catch (err) {
    if (err instanceof Error && err.message.startsWith("intercom:")) {
      return { enabled: false, configured: false };
    }
    throw err;
  }
}
