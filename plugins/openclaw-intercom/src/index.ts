import { defineChannelPluginEntry } from "openclaw/plugin-sdk/core";
import { intercomPlugin } from "./channel.js";

export default defineChannelPluginEntry({
  id: "intercom",
  name: "Intercom",
  description: "Intercom customer support channel for HYDRA",
  plugin: intercomPlugin,
});
