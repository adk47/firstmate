import { defineChannelPluginEntry } from "openclaw/plugin-sdk/core";
import { gmailPlugin } from "./src/channel.js";
import { setGmailRuntime } from "./src/runtime.js";

// PATCH: fix account lifecycle — add isConfigured and override isEnabled
// to return true for accounts with an email (raw config lacks explicit
// enabled:true, and the Zod default isn't applied by the gateway).
const origStartAccount = gmailPlugin.gateway?.startAccount;

const patchedPlugin = {
  ...gmailPlugin,
  config: {
    ...gmailPlugin.config,
    isConfigured: (account: any) => Boolean(account?.email?.trim()),
    isEnabled: (account: any) => account?.enabled !== false && Boolean(account?.email?.trim()),
  },
  gateway: {
    ...gmailPlugin.gateway,
    startAccount: async (ctx: any) => {
      console.log('[openclaw-gmail] startAccount:', ctx?.account?.email ?? ctx?.accountId);
      if (!origStartAccount) {
        throw new Error('[openclaw-gmail] FATAL: gateway.startAccount missing on original plugin');
      }
      try {
        await origStartAccount(ctx);
      } catch (err) {
        console.error('[openclaw-gmail] startAccount error:', String(err));
        throw err;
      }
    },
  },
};

export default defineChannelPluginEntry({
  id: "openclaw-gmail",
  name: "Gmail",
  description: "Gmail channel plugin for OpenClaw - direct API or gog CLI",
  plugin: patchedPlugin,
  registerFull(api) {
    setGmailRuntime(api.runtime);
  },
});
