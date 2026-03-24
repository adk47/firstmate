import { createChatChannelPlugin } from "openclaw/plugin-sdk/core";
import { listIntercomAccountIds, resolveIntercomAccount } from "./config.js";

export const intercomPlugin = createChatChannelPlugin({
  base: {
    id: "intercom",
    meta: { label: "Intercom", order: 100 },
    capabilities: { chatTypes: ["direct"] },
    config: {
      listAccountIds: (cfg: any) => listIntercomAccountIds(cfg),
      resolveAccount: ({ cfg, accountId }: { cfg: any; accountId?: string | null }) =>
        resolveIntercomAccount(cfg, accountId),
      isConfigured: (account: any) => Boolean(account.token && account.workspaceId),
    },
    gateway: {
      // TODO: Wire runPassiveAccountLifecycle before deploy.
      // Without it, startAccount resolves immediately and the Gateway
      // restart-loops the account (see Google Chat issue #27933).
      // Must: register webhook HTTP route, park promise on ctx.abortSignal,
      // gate on account.enabled before accepting webhooks.
      startAccount: async (ctx: any) => {
        const account = resolveIntercomAccount(ctx.cfg, ctx.account?.accountId);
        if (!account.enabled) {
          ctx.log?.info?.(`[${account.accountId}] Intercom channel disabled, skipping`);
          return;
        }
        ctx.log?.info?.(`[${account.accountId}] starting Intercom webhook monitor`);
      },
    },
  },
  security: {
    dm: {
      channelKey: "intercom",
      resolvePolicy: () => "open",
      resolveAllowFrom: () => undefined,
    },
  },
  threading: { topLevelReplyToMode: "reply" },
  outbound: {
    attachedResults: {
      channel: "intercom",
      // TODO: Wire RealIntercomClient + canAgentReply pre-send validation before deploy.
      sendText: async ({ cfg, to, text, accountId }: any) => {
        throw new Error("intercom sendText is not yet wired — requires Gateway runtime on Node 8");
      },
    },
  },
});
