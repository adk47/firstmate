import { definePluginEntry, type OpenClawPluginApi } from "openclaw/plugin-sdk/core";
import { blockUnsanctionedBatchMessage } from "./src/hooks/block-unsanctioned-batch-message.js";
import { cleanupSessionState } from "./src/hooks/lifecycle.js";
import { markCvSessionHook } from "./src/hooks/mark-cv-session.js";

/**
 * muso-credit-verification-enforcer
 *
 * Scope was narrowed twice:
 *
 *   2026-04-15 — `before_tool_call` / `after_tool_call` hooks do NOT fire
 *   reliably on autonomous `exec` calls in YOLO mode. The approve gate
 *   moved to the bash layer (muso-admin-api.sh::enforce_credit_approve_gate).
 *
 *   2026-05-06 — credit-verification cut over from browser-only Tier-1
 *   evidence to API helpers (musicbrainz / spotify / discogs) plus AllMusic
 *   browser fallback. The three hooks that existed only to FORCE the
 *   browser path were removed:
 *     - redirect-web-search       (redirected web_search → browser)
 *     - block-web-fetch-tier1     (blocked web_fetch on Tier-1 hosts)
 *     - block-escalation-without-browse (counted ≥2 Tier-1 browser loads)
 *   Under api-mode none of these are correct: web_search citations may
 *   become primary evidence, web_fetch is harmless because the gate's
 *   api-evidence library doesn't count its results, and escalations may
 *   legitimately have zero browser activity when API helpers cleared the
 *   queue. The bash gate (CV_EVIDENCE_MODE=api default) is the source of
 *   truth; CV_EVIDENCE_MODE=browser remains as a rollback knob.
 *
 * What the plugin still does:
 *
 *   - `inbound_claim`: mark a session as CV when it arrives on the CV channel.
 *   - `before_tool_call` on `message`: block hand-composed [HEARTBEAT-BATCH] /
 *     "Credit batch complete" posts. Hygiene gate; not browser-related.
 *     Closes the 2026-04-28 failure where the agent posted false "no writes"
 *     status after running only B0+B1.
 *   - `session_end`: unmark the session so the in-memory set doesn't grow.
 *
 * The message-tool hook is reliably delivered (foreground, not autonomous
 * exec). Fail-OPEN throughout: the bash gate, runlog renderer-missing
 * detector, and admin-API-side validation all catch any bypass.
 */
export default definePluginEntry({
  id: "muso-credit-verification-enforcer",
  name: "Muso Credit Verification Enforcer",
  description:
    "Marks CV sessions and blocks hand-composed batch-complete messages; approve gate is enforced at the bash layer (muso-admin-api.sh).",
  register(api: OpenClawPluginApi) {
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
