/**
 * OpenClaw channel secret-contract for the Intercom channel.
 *
 * openclaw discovers this module by CONVENTION — it searches the extension's
 * `dist/` (and root) for a `secret-contract-api` basename and matches it to a
 * channel via the manifest `channel.id` ("intercom"). It is NOT listed in
 * package.json `openclaw.extensions` (that would mis-load it as a runtime
 * extension). `tsc` compiles this src file to `dist/secret-contract-api.js`,
 * which the deploy rsyncs into the extension dir alongside `dist/index.js`.
 *
 * Why this exists: the Intercom access token used to be an inline plaintext
 * string in openclaw-edge.json (committed to git). openclaw only resolves
 * SecretRefs at config paths a collector knows about; a channel's per-account
 * fields are only collected if the channel ships this contract. Without it, a
 * SecretRef at `channels.intercom.accounts.*.token` would be handed to the
 * plugin RAW (an unresolved object), silently breaking every Intercom API call.
 *
 * With this contract, openclaw's channel collector resolves the ref at startup
 * (fail-closed if the env var is missing) and injects the plaintext string back
 * into the resolved config BEFORE the plugin reads `account.token`. The plugin's
 * hot path (config.ts `resolveIntercomAccount` → `createIntercomClient(account.token)`)
 * is unchanged — it keeps receiving a string.
 *
 * This mirrors the bundled Mattermost channel's `botToken` contract 1:1
 * (registers the `accounts.*` wildcard plus the top-level field; one
 * `collectSimpleChannelFieldAssignments` call covers both). See
 * openclaw `dist/extensions/secret-contract-Dg0RJVak.js`.
 */
import {
  getChannelSurface,
  collectSimpleChannelFieldAssignments,
  type SecretTargetRegistryEntry,
  type ResolverContext,
  type SecretDefaults,
} from "openclaw/plugin-sdk/channel-secret-basic-runtime";

export const secretTargetRegistryEntries: SecretTargetRegistryEntry[] = [
  {
    id: "channels.intercom.accounts.*.token",
    targetType: "channels.intercom.accounts.*.token",
    configFile: "openclaw.json",
    pathPattern: "channels.intercom.accounts.*.token",
    secretShape: "secret_input",
    expectedResolvedValue: "string",
    includeInPlan: true,
    includeInConfigure: true,
    includeInAudit: true,
  },
  {
    id: "channels.intercom.token",
    targetType: "channels.intercom.token",
    configFile: "openclaw.json",
    pathPattern: "channels.intercom.token",
    secretShape: "secret_input",
    expectedResolvedValue: "string",
    includeInPlan: true,
    includeInConfigure: true,
    includeInAudit: true,
  },
];

export function collectRuntimeConfigAssignments(params: {
  config: { channels?: Record<string, unknown> } & Record<string, unknown>;
  defaults?: SecretDefaults;
  context: ResolverContext;
}): void {
  const resolved = getChannelSurface(params.config, "intercom");
  if (!resolved) return;
  const { channel: intercom, surface } = resolved;
  collectSimpleChannelFieldAssignments({
    channelKey: "intercom",
    field: "token",
    channel: intercom,
    surface,
    defaults: params.defaults,
    context: params.context,
    topInactiveReason: "no enabled account inherits this top-level Intercom token.",
    accountInactiveReason: "Intercom account is disabled.",
  });
}

export const channelSecrets = {
  secretTargetRegistryEntries,
  collectRuntimeConfigAssignments,
};
