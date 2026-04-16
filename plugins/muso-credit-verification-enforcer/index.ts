import { definePluginEntry, type OpenClawPluginApi } from "openclaw/plugin-sdk/core";
import { redirectWebSearch } from "./src/hooks/redirect-web-search.js";
import { cleanupSessionState } from "./src/hooks/lifecycle.js";
import { markCvSessionHook } from "./src/hooks/mark-cv-session.js";

/**
 * muso-credit-verification-enforcer
 *
 * Scope was narrowed on 2026-04-15 after live testing showed that openclaw's
 * `before_tool_call` / `after_tool_call` hooks do NOT fire reliably on
 * autonomous `exec` calls in YOLO mode (`tools.exec.security=full, ask=off`).
 * The approve gate moved to the bash layer (muso-admin-api.sh); the plugin
 * now only handles what the hook bus DOES reliably deliver:
 *
 *   - `inbound_claim`: mark a session as CV when it arrives on the CV channel
 *   - `before_tool_call` on `web_search`: redirect to the `browser` tool
 *     (works — web_search IS routed through the hook, unlike exec)
 *   - `session_end`: unmark the session
 *
 * The three hooks that previously lived here (gate-credit-approve,
 * track-tool-call, their Tier 1 / dedup / runlog supporting code) were removed
 * because they silently no-op'd in practice — confabulation risk, no value.
 */
export default definePluginEntry({
  id: "muso-credit-verification-enforcer",
  name: "Muso Credit Verification Enforcer",
  description:
    "Blocks web_search in credit-verification context; approve gate enforced at bash layer (muso-admin-api.sh).",
  register(api: OpenClawPluginApi) {
    // Mark sessions as CV when they arrive on the CV channel. Fail-OPEN —
    // if this throws we miss the mark (and the gate later no-ops) but we
    // don't break inbound delivery.
    api.on(
      "inbound_claim",
      (event, ctx) => {
        try {
          return markCvSessionHook(event, ctx);
        } catch (err) {
          console.error(
            `[credit-verification-enforcer] mark-cv-session error: ${String(err)}`,
          );
          return undefined;
        }
      },
      { priority: 100 },
    );

    // Fail-OPEN: search redirect is a UX nudge, not a security gate.
    api.on(
      "before_tool_call",
      (event, ctx) => {
        try {
          return redirectWebSearch(event, ctx);
        } catch (err) {
          console.error(
            `[credit-verification-enforcer] redirect-web-search error: ${String(err)}`,
          );
          return undefined;
        }
      },
      { priority: 100 },
    );

    // gate-credit-approve + track-tool-call hooks removed on 2026-04-15 — the
    // real gate lives in muso-admin-api.sh (bash layer), since openclaw does
    // not reliably fire before_tool_call on autonomous exec in YOLO mode.

    // session_start registration dropped: no channelId on SessionContext;
    // inbound_claim covers the real CV entry point.

    // Fail-OPEN cleanup: unmark the CV session so the set doesn't grow.
    api.on(
      "session_end",
      (event, ctx) => {
        try {
          cleanupSessionState(event, ctx);
        } catch (err) {
          console.error(
            `[credit-verification-enforcer] cleanup-session-state error: ${String(err)}`,
          );
        }
      },
      { priority: 100 },
    );
  },
});
