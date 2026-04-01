import { defineChannelPluginEntry } from "openclaw/plugin-sdk/core";
import { intercomPlugin } from "./channel.js";
import { setCapturedConfig } from "./config.js";

export default defineChannelPluginEntry({
  id: "intercom",
  name: "Intercom",
  description: "Intercom customer support channel for HYDRA",
  plugin: intercomPlugin,
  registerFull(api) {
    // Capture api.config at registration time. The Gateway provides full config
    // here but passes undefined to channel lifecycle callbacks (startAccount,
    // resolveAccount, etc.). This bridges the gap by caching the config for
    // fallback use in config.ts resolveConfig().
    if (api.config) {
      setCapturedConfig(api.config);
    } else {
      console.error(
        "[intercom] registerFull called but api.config is undefined — " +
        "config fallback for lifecycle callbacks will not be available",
      );
    }
  },
});
