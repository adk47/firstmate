import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import { deriveConvId } from "./dedupe-check.js";

// profiles_consolidate — gated WRITE (APPROVAL-tier): fold the CUSTOMER'S OWN
// unclaimed same-name duplicate profiles into the profile they own, by shelling
// `muso profiles consolidate --actor-identity <email>`. The muso-cli capability
// gate re-fetches the survivor + duplicates and refuses (exit 5,
// route_to_human) unless the survivor is owned by the actor identity and the
// merge is permitted — so the worst a hijacked call can do is consolidate the
// customer's OWN duplicates, which is the legitimate action. The WRITE
// counterpart of the read-only dedupe_check.
//
// Anti-spoof anchor (mirrors profiles_claim_self / dedupe-check.ts): the actor
// identity is the conversation's REAL Intercom author email, derived in-plugin
// from the trusted gateway session KEY (deriveConvId) — NEVER a model tool-arg
// and NEVER the message body. The wrapper trusts that ctx-derived email and muso
// re-verifies ownership server-side. The intercom-conv-id doubles as the
// approval-ref the wrapper passes to muso (the audit trail for the approval).

const UUID_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
// Mirrors muso-cli's enforced per-call cap (consolidateDupsPerCallCap = 25); muso
// re-verifies EVERY --from is unclaimed + same-name + owned, so the bound is the
// gate's, not ours. Intentionally larger than dedupe_check's MAX_DUPLICATES (5),
// which is only an evidence-display bound on the read-only verdict, not a write cap.
const MAX_DUPLICATES = 25;

const Parameters = Type.Object({
  survivorId: Type.String({
    pattern: UUID_PATTERN,
    description:
      "UUID of the profile the customer wants to KEEP (the survivor — their OWN profile). muso re-verifies the survivor is owned by the verified contact, so a foreign survivor is refused server-side.",
  }),
  dupIds: Type.Array(
    Type.String({ pattern: UUID_PATTERN }),
    {
      minItems: 1,
      maxItems: MAX_DUPLICATES,
      uniqueItems: true,
      description:
        "UUIDs of the unclaimed same-name duplicate profiles to fold into the survivor. 1–25, distinct, and NOT the survivor's own id. muso re-verifies each is consolidatable.",
    },
  ),
  apply: Type.Optional(
    Type.Boolean({
      default: false,
      description:
        "false = dry-run preview (default), true = apply. Preview first, tell the customer what will be merged, then apply.",
    }),
  ),
});

type Params = Static<typeof Parameters>;

type ExecFileLike = (
  file: string,
  args: readonly string[],
  options: { timeout?: number; maxBuffer?: number },
  callback: (err: unknown, stdout: string, stderr: string) => void,
) => unknown;

function execFileToPromise(fn: ExecFileLike) {
  return (file: string, args: readonly string[], options: { timeout?: number; maxBuffer?: number }) =>
    new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
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

export interface ProfilesConsolidateDeps {
  scriptPath: string;
  rateLimiter: RateLimiter;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // Phase-1 dark-ship gate (default OFF): registered but a no-op disabled
  // sentinel until explicitly enabled per the rollout (mirrors
  // profiles_claim_self / credit_verification_check).
  enabled: boolean;
  execFileImpl?: ExecFileLike;
}

export const DEFAULT_PROFILES_CONSOLIDATE_SCRIPT =
  process.env.PROFILES_CONSOLIDATE_SCRIPT ??
  "/opt/hydra/workspaces/support/skills/customer-profile-consolidate/scripts/consolidate.sh";

export function createProfilesConsolidateTool(deps: ProfilesConsolidateDeps): AgentTool<typeof Parameters, unknown> {
  const { scriptPath, rateLimiter, sessionKey, intercomReader, intercomToken, enabled, execFileImpl } = deps;
  const exec = execFileToPromise(execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "profiles_consolidate",
    label: "Consolidate the customer's own duplicate profiles into theirs",
    description:
      "Merge the CUSTOMER'S OWN unclaimed same-name duplicate profiles into the profile they own (the survivor). " +
      "Ownership is anchored to the verified Intercom contact and re-verified server-side — consolidating into a profile they do not own is refused. " +
      "Always call apply=false first to preview, tell the customer what will be merged, then apply=true. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Dark-ship gate (cheapest first): when off, do nothing so the agent falls
      // back to a normal ticket. No network, no exec.
      if (!enabled) {
        return textResult(JSON.stringify({ ok: false, disabled: true, note: "self-service profile consolidation is not enabled" }));
      }
      if (!rateLimiter.check(sessionKey, "profiles_consolidate", 60, 10).allowed) {
        return textResult(JSON.stringify({ ok: false, error: "rate_limited" }));
      }

      // Belt-and-suspenders before the irreversible verb: the survivor must not
      // appear among the duplicates (muso would refuse a self-merge, but reject
      // the nonsensical request up front rather than spend a gated call on it).
      // uniqueItems in the schema already rejects repeated dups.
      if (params.dupIds.some((d) => d === params.survivorId)) {
        return textResult(JSON.stringify({ ok: false, error: "survivor_in_dups", detail: "the survivor id must not be one of the duplicates" }));
      }

      // Anti-spoof anchor — derive the trusted actor email from the conversation,
      // never from a model arg. Fail closed on any unverifiable path.
      const convId = deriveConvId(sessionKey);
      if (!convId) {
        return textResult(JSON.stringify({ ok: false, error: "owner_undetermined", detail: "conversation id unavailable; cannot verify ownership" }));
      }
      if (!intercomToken) {
        return textResult(JSON.stringify({ ok: false, error: "owner_undetermined", detail: "intercom token unavailable; cannot verify ownership" }));
      }
      const actorEmail = await intercomReader.getAuthorEmail(convId, intercomToken);
      if (!actorEmail) {
        return textResult(JSON.stringify({ ok: false, error: "owner_undetermined", detail: "could not read the verified contact email; routed for human verification" }));
      }

      const argv = [
        scriptPath,
        "--into", params.survivorId,
        "--actor-identity", actorEmail,
        "--intercom-conv-id", convId,
      ];
      for (const dup of params.dupIds) argv.push("--from", dup);
      if (params.apply === true) argv.push("--apply");

      try {
        const { stdout, stderr } = await exec("bash", argv, { timeout: 60 * 1000, maxBuffer: 2 * 1024 * 1024 });
        if (stderr && stderr.trim()) console.warn(`[profiles_consolidate] wrapper stderr: ${stderr.trim()}`);
        const trimmed = stdout.trim();
        if (!trimmed) return textResult(JSON.stringify({ ok: false, error: "wrapper_empty_output" }));
        try {
          JSON.parse(trimmed);
        } catch {
          return textResult(JSON.stringify({ ok: false, error: "wrapper_invalid_output", detail: trimmed.slice(0, 200) }));
        }
        return textResult(trimmed);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const stderrSnippet = (e.stderr ?? "").trim().slice(0, 500);
        if (stderrSnippet) console.warn(`[profiles_consolidate] wrapper exec failed; stderr: ${stderrSnippet}`);
        return textResult(JSON.stringify({
          ok: false,
          error: "wrapper_exec_failed",
          detail: e.message || "unknown",
          stderr: stderrSnippet || undefined,
          code: e.code ?? null,
        }));
      }
    },
  };
}
