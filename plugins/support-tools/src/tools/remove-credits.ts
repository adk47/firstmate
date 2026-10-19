import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";

// Hand-rolled promisifier so an injected mock (in tests) can use the plain
// `(file, args, options, callback)` shape without needing the
// `util.promisify.custom` symbol that ships with the real execFile.
type ExecFileLike = (
  file: string,
  args: readonly string[],
  options: { timeout?: number; maxBuffer?: number },
  callback: (err: unknown, stdout: string, stderr: string) => void,
) => unknown;

function execFileToPromise(
  fn: ExecFileLike,
): (file: string, args: readonly string[], options: { timeout?: number; maxBuffer?: number }) => Promise<{ stdout: string; stderr: string }> {
  return (file, args, options) =>
    new Promise((resolve, reject) => {
      fn(file, args, options, (err, stdout, stderr) => {
        if (err) {
          const e = err as Error & { stdout?: string; stderr?: string };
          e.stdout = stdout;
          e.stderr = stderr;
          reject(e);
        } else {
          resolve({ stdout, stderr });
        }
      });
    });
}

// Pattern strings are kept in sync with the bash wrapper's regex checks
// (see remove-credits.sh arg validation block). Two layers of defense:
// (a) JSON-schema rejection at the framework boundary if the dispatcher
// validates, (b) wrapper regex check as the canonical security boundary.
const UUID_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
const EMAIL_PATTERN = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$";

// remove_credits is destructive and the wrapper runs DELETEs serially
// (~1s each). Cap a single APPLY so each batch stays small, quick, and
// individually confirmable — bounding the blast radius and worst-case run
// time of one destructive call and keeping the dry-run → confirm → apply
// loop reviewable a batch at a time. Dry-run (read-only) is unaffected and
// still previews the full 50; the wrapper is idempotent and the 15-min
// dry-run audit gate makes batched apply safe.
const APPLY_MAX_TRACKS = 15;

const Parameters = Type.Object({
  profileId: Type.String({
    pattern: UUID_PATTERN,
    description: "Target profile UUID. Must match the URL the customer pasted in the conversation.",
  }),
  requesterEmail: Type.String({
    pattern: EMAIL_PATTERN,
    description: "Customer's verified Intercom email (from [CONVERSATION_CONTEXT]). The wrapper script re-verifies ownership against this email.",
  }),
  tracks: Type.Array(
    // Forbid embedded newlines/CRs — the wrapper writes one track per line,
    // an embedded \n would split a single track into two phantom rows.
    Type.String({ minLength: 1, pattern: "^[^\\n\\r]{1,300}$" }),
    {
      description: "List of 'Artist - Title' strings the customer wants removed from their profile. One element per track. Max 50 per call.",
      minItems: 1,
      maxItems: 50,
    },
  ),
  apply: Type.Optional(Type.Boolean({
    default: false,
    description: "false = dry-run preview (default). Always leave this false: apply=true is refused for agent tokens (core-backend#10310), so a removal is never applied from here. Show the preview, then hand off.",
  })),
  intercomConvId: Type.Optional(Type.String({
    minLength: 1,
    description: "Intercom conversation ID. Cross-checks the customer's email against Intercom's stored author.email — closes the message-text injection vector). Strongly recommended on dry-run too: the same cross-check runs whenever conv-id is present.",
  })),
});

type Params = Static<typeof Parameters>;

interface ToolDeps {
  scriptPath: string;
  rateLimiter: RateLimiter;
  sessionId: string;
  execFileImpl?: ExecFileLike;
}

// Single source of truth for the env var override + default deploy path.
// The script lives in the support workspace; hydra deploy.sh syncs the
// repo into /opt/hydra (DEPLOY_PATH default; see scripts/deploy.sh:21).
// Tests inject a path via scriptPath; override at runtime via
// REMOVE_CREDITS_SCRIPT env or pluginConfig.removeCreditsScriptPath.
export const DEFAULT_REMOVE_CREDITS_SCRIPT =
  process.env.REMOVE_CREDITS_SCRIPT ??
  "/opt/hydra/workspaces/support/skills/customer-credit-removal/scripts/remove-credits.sh";

export function createRemoveCreditsTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { scriptPath, rateLimiter, sessionId, execFileImpl } = deps;
  const exec = execFileToPromise(execFileImpl ?? (execFile as ExecFileLike));
  return {
    name: "remove_credits",
    label: "Remove Credits from Customer's Own Profile",
    description:
      "Remove one or more mis-attributed credits from a profile the customer owns. " +
      "Refuses if the requester's email doesn't match the profile's claimed owner. " +
      "Agent use is preview-only: call with apply=false to resolve the exact tracks and roles. apply=true is refused for agent tokens (core-backend#10310); owners remove credits in the app, or staff review a packet. " +
      "Caps: 50 tracks per call, 100 per customer per day (enforced inside the wrapper). " +
      "Tool-level rate limit: 10 calls per 60 minutes per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Hardening 1b: apply: true requires intercomConvId. The bash wrapper
      // re-enforces this independently, but checking here gives the agent a
      // fast feedback path before we go through tmpfile + exec overhead.
      // This closes the message-text-email-injection vector at the tool
      // boundary too.
      if (params.apply === true && (!params.intercomConvId || !params.intercomConvId.trim())) {
        return textResult(JSON.stringify({
          ok: false,
          error: "intercom_conv_id_required",
          detail: "apply: true requires intercomConvId so the wrapper can verify the customer's email against Intercom's contact record",
        }));
      }

      // Bound a single destructive apply to a small, individually-confirmable
      // batch. Dry-run is read-only and unaffected — preview all tracks, then
      // apply in batches.
      if (params.apply === true && Array.isArray(params.tracks) && params.tracks.length > APPLY_MAX_TRACKS) {
        return textResult(JSON.stringify({
          ok: false,
          error: "apply_batch_too_large",
          detail: `Apply is limited to ${APPLY_MAX_TRACKS} tracks per call so each destructive batch stays small and individually confirmable. Run the dry-run to preview them all, then apply in batches of ${APPLY_MAX_TRACKS} or fewer.`,
          max_apply_tracks: APPLY_MAX_TRACKS,
        }));
      }

      // Rate-limit budget covers the dry-run → apply pair plus headroom for
      // a couple of retries / multiple cleanup batches per session.
      if (!rateLimiter.check(sessionId, "remove_credits", 60, 10).allowed) {
        return textResult(JSON.stringify({ ok: false, error: "rate_limited" }));
      }

      // Write tracks to a tmpfile — keeps argv tight and avoids any shell
      // quoting concerns on multi-line / unicode track names.
      let tmpDir: string | null = null;
      try {
        tmpDir = await mkdtemp(path.join(tmpdir(), "ccr-tool-"));
        const tracksFile = path.join(tmpDir, "tracks.txt");
        await writeFile(tracksFile, params.tracks.join("\n") + "\n", "utf8");

        const argv = [
          scriptPath,
          "--profile-id", params.profileId,
          "--requester-email", params.requesterEmail,
          "--tracks-file", tracksFile,
        ];
        if (params.apply === true) argv.push("--apply");
        if (params.intercomConvId) argv.push("--intercom-conv-id", params.intercomConvId);

        // execFile (NOT exec) — no shell interpretation, argv is positional.
        // bash interprets the script; argv passes straight through.
        const { stdout, stderr } = await exec("bash", argv, {
          // 5-min cap: the wrapper paginates credits + runs DELETEs in serial,
          // worst case ~50 tracks at ~1s each + a few seconds for credits list.
          timeout: 5 * 60 * 1000,
          maxBuffer: 4 * 1024 * 1024, // 4MB — output is JSON, usually <10KB
        });

        // The wrapper writes "WARN: ..." lines to stderr for non-fatal
        // anomalies it wants ops to see (audit append failure, Intercom
        // token missing, etc.). Surface them to the gateway log so they
        // land in Loki / journalctl — otherwise this signal would be lost.
        if (stderr && stderr.trim()) {
          console.warn(`[remove_credits] wrapper stderr: ${stderr.trim()}`);
        }

        // Wrapper always emits a single JSON object on stdout (success or
        // refusal). Pass it through verbatim — the agent reads it directly.
        const trimmed = stdout.trim();
        if (!trimmed) {
          return textResult(JSON.stringify({ ok: false, error: "wrapper_empty_output" }));
        }
        // Validate it's parseable JSON — if not, the wrapper crashed.
        try {
          JSON.parse(trimmed);
        } catch {
          return textResult(JSON.stringify({
            ok: false,
            error: "wrapper_invalid_output",
            detail: trimmed.slice(0, 200),
          }));
        }
        return textResult(trimmed);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stdout?: string; stderr?: string };
        // If the wrapper exited non-zero (it shouldn't — it always emits JSON
        // and exits 0), surface enough context for triage. Include the first
        // 500 chars of stderr so the wrapper's WARN/error lines reach the
        // agent + Loki, not just /dev/null.
        const stderrSnippet = (e.stderr ?? "").trim().slice(0, 500);
        if (stderrSnippet) {
          console.warn(`[remove_credits] wrapper exec failed; stderr: ${stderrSnippet}`);
        }
        return textResult(JSON.stringify({
          ok: false,
          error: "wrapper_exec_failed",
          detail: e.message || "unknown",
          stderr: stderrSnippet || undefined,
          code: e.code ?? null,
        }));
      } finally {
        if (tmpDir) {
          await rm(tmpDir, { recursive: true, force: true }).catch(() => undefined);
        }
      }
    },
  };
}
