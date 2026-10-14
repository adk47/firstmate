import type { IntercomAccountConfig } from "./types.js";
import { DEFAULT_FALLBACK_ACK, DEFAULT_JEV_BANDS, DEFAULT_JEV_ACTIONS, DEFAULT_JEV_SHADOW } from "./types.js";

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
  // Fail loud at boot, same posture as the token/workspaceId/webhookSecret
  // checks above — a jev.enabled account that silently ran with an
  // unresolved SecretRef (or no key at all) would 401 on every turn instead
  // of failing the deploy.
  if (account.jev?.enabled) {
    if (typeof account.jev.apiKey !== "string" || account.jev.apiKey.trim() === "") {
      throw new Error(`intercom: account "${id}" jev enabled but missing apiKey`);
    }
  }
  if (account.jev?.bands) {
    for (const [key, value] of Object.entries(account.jev.bands)) {
      if (typeof value !== "number" || Number.isNaN(value) || value < 0 || value > 1) {
        throw new Error(`intercom: account "${id}" jev.bands.${key} must be a number in [0,1] (got: ${value})`);
      }
    }
  }
  if (account.jev?.actions) {
    for (const [key, value] of Object.entries(account.jev.actions)) {
      if (typeof value !== "boolean") {
        throw new Error(`intercom: account "${id}" jev.actions.${key} must be a boolean (got: ${value})`);
      }
    }
  }
  if (account.jev?.shadow && account.jev.shadow.storeState !== undefined) {
    if (typeof account.jev.shadow.storeState !== "boolean") {
      throw new Error(
        `intercom: account "${id}" jev.shadow.storeState must be a boolean (got: ${account.jev.shadow.storeState})`,
      );
    }
  }
  if (account.jev?.questionsVersion !== undefined) {
    if (account.jev.questionsVersion !== "v1" && account.jev.questionsVersion !== "v2") {
      throw new Error(
        `intercom: account "${id}" jev.questionsVersion must be "v1" or "v2" (got: ${account.jev.questionsVersion})`,
      );
    }
  }
  if (account.jev?.shadowVersions !== undefined) {
    if (
      !Array.isArray(account.jev.shadowVersions) ||
      account.jev.shadowVersions.some((v) => typeof v !== "string")
    ) {
      throw new Error(`intercom: account "${id}" jev.shadowVersions must be an array of strings`);
    }
    // Restrict to the versions jev-router.ts actually implements (mirrors
    // questionsVersion's "v1"|"v2" check above). QA NO-GO on #1022: an
    // unrecognised entry (e.g. a typo like "v02") used to pass this check,
    // then channel.ts silently ran the v1 runner for it while handler.ts
    // still labelled the shadow row with the typo'd version string — a
    // corrupted cohort masquerading as an experiment that was never run.
    account.jev.shadowVersions.forEach((v, i) => {
      if (v !== "v1" && v !== "v2") {
        throw new Error(`intercom: account "${id}" jev.shadowVersions[${i}] "${v}" is not a supported version (v1, v2)`);
      }
    });
  }
  if (account.jev?.shadowTimeoutMs !== undefined) {
    if (!Number.isInteger(account.jev.shadowTimeoutMs) || account.jev.shadowTimeoutMs <= 0) {
      throw new Error(
        `intercom: account "${id}" jev.shadowTimeoutMs must be a positive integer (got: ${account.jev.shadowTimeoutMs})`,
      );
    }
  }
  if (account.jev?.agentInstructionsPath !== undefined) {
    if (typeof account.jev.agentInstructionsPath !== "string" || account.jev.agentInstructionsPath.trim() === "") {
      throw new Error(`intercom: account "${id}" jev.agentInstructionsPath must be a non-empty string`);
    }
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
    jev: account.jev
      ? {
          enabled: account.jev.enabled === true,
          apiKey: account.jev.apiKey,
          ...(typeof account.jev.model === "string" ? { model: account.jev.model } : {}),
          ...(typeof account.jev.timeoutMs === "number" ? { timeoutMs: account.jev.timeoutMs } : {}),
          ...(typeof account.jev.shadowTimeoutMs === "number" ? { shadowTimeoutMs: account.jev.shadowTimeoutMs } : {}),
          bands: { ...DEFAULT_JEV_BANDS, ...(account.jev.bands ?? {}) },
          actions: { ...DEFAULT_JEV_ACTIONS, ...(account.jev.actions ?? {}) },
          shadow: { ...DEFAULT_JEV_SHADOW, ...(account.jev.shadow ?? {}) },
          // Shadow-only surface: questionsVersion gates LIVE routing
          // behaviour (decline/silence/escalate + the [ROUTING] block);
          // shadowVersions fires extra parallel Jev calls that only ever
          // write to the shadow log. Defaults keep prod identical to today.
          questionsVersion: account.jev.questionsVersion ?? "v1",
          shadowVersions: account.jev.shadowVersions ?? [],
          ...(typeof account.jev.agentInstructionsPath === "string"
            ? { agentInstructionsPath: account.jev.agentInstructionsPath }
            : {}),
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
