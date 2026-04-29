import { definePluginEntry, type OpenClawPluginApi } from "openclaw/plugin-sdk/core";
import { redirectWebSearch } from "./src/hooks/redirect-web-search.js";
import { blockWebFetchTier1 } from "./src/hooks/block-web-fetch-tier1.js";
import { blockUnsanctionedBatchMessage } from "./src/hooks/block-unsanctioned-batch-message.js";
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
 *   - `before_tool_call` on `web_fetch`: block when the URL host is Tier 1
 *     (Spotify / Apple Music / MusicBrainz / Discogs / AllMusic / Tidal).
 *     Those pages are JS-rendered; web_fetch returns non-rendered HTML.
 *     Non-Tier-1 web_fetch still passes — e.g., an artist's own site.
 *   - `session_end`: unmark the session
 *
 * CV context detection was broadened on 2026-04-22 (issue #152) after live
 * testing showed @-mention flows into #credit-verification slipped past the
 * Tier 1 block because they don't re-trigger inbound_claim and don't set
 * runId. `isCreditVerificationSession` now also treats any tool call from
 * the `operations` / `operations-dev` agent as CV context — the workspace
 * itself is CV-scoped, so workspace-level gating is safer than the narrow
 * sessionKey/runId gate.
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

    // Block web_fetch on Tier 1 hosts — those pages are JS-rendered, so
    // web_fetch returns a different (and often wrong) data surface than
    // the browser tool. Fail-OPEN on error — the bash-layer approve gate
    // (muso-admin-api.sh) catches it too, so this hook is the UX sharpener
    // (fast feedback at call-time) rather than the sole defense.
    api.on(
      "before_tool_call",
      (event, ctx) => {
        try {
          return blockWebFetchTier1(event, ctx);
        } catch (err) {
          console.error(
            `[credit-verification-enforcer] block-web-fetch-tier1 error: ${String(err)}`,
          );
          return undefined;
        }
      },
      { priority: 100 },
    );

    // Block hand-composed [HEARTBEAT-BATCH] / "Credit batch complete"
    // posts to #credit-verification — the agent must use
    // post-batch-summary.sh (which posts via the openclaw CLI directly,
    // bypassing this hook). Closes the 2026-04-28 15:13 / 15:26 UTC
    // failure where gpt-5.5 posted "Queue fetch succeeded — no writes"
    // hand-composed messages after only running B0+B1.
    //
    // Unlike the exec-tool hooks (silently no-op in YOLO mode per the
    // narrowing comment above), the message tool IS reliably hooked —
    // it runs in agent foreground, not autonomous exec. Fail-OPEN
    // throughout: the lockfile.sh emit_renderer_missing_event_if_needed
    // detector catches bypasses post-hoc as a belt-and-braces.
    api.on(
      "before_tool_call",
      (event, ctx) => {
        try {
          return blockUnsanctionedBatchMessage(event, ctx);
        } catch (err) {
          console.error(
            `[credit-verification-enforcer] block-unsanctioned-batch-message error: ${String(err)}`,
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
