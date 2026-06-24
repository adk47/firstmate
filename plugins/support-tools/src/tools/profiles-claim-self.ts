import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import { deriveConvId } from "./dedupe-check.js";

// profiles_claim_self — gated WRITE: verify (approve) the CUSTOMER'S OWN pending
// profile claim by shelling `muso profiles claim-self --actor-identity <email>`.
// The muso-cli capability gate re-fetches the claim and refuses unless the
// claim's workspace email equals the actor identity (route_to_human otherwise),
// and an already-processed claim is an idempotent no-op — so the worst a hijacked
// call can do is verify the customer's OWN pending claim, which is the legitimate
// action. The WRITE counterpart of the read-only dedupe/verification checks.
//
// Anti-spoof anchor (mirrors credit-verification-check.ts): the actor identity is
// the conversation's REAL Intercom author email, derived in-plugin from the
// trusted gateway session KEY (deriveConvId) — NEVER a model tool-arg and NEVER
// the message body. The wrapper trusts that ctx-derived email and muso re-verifies
// ownership server-side.

const CLAIM_ID_PATTERN = "^[A-Za-z0-9_-]{1,128}$";

const Parameters = Type.Object({
  claimId: Type.String({
    pattern: CLAIM_ID_PATTERN,
    description:
      "The pending claim id to verify (from a prior profile/claim lookup). muso re-verifies the claim's workspace email equals the verified contact, so a wrong/foreign id is refused server-side.",
  }),
  apply: Type.Optional(
    Type.Boolean({
      default: false,
      description:
        "false = dry-run preview (default), true = apply. Preview first, tell the customer what will be verified, then apply.",
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

export interface ProfilesClaimSelfDeps {
  scriptPath: string;
  rateLimiter: RateLimiter;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // Phase-1 dark-ship gate (default OFF): registered but a no-op disabled
  // sentinel until explicitly enabled per the rollout (mirrors
  // credit_verification_check / PR #416).
  enabled: boolean;
  execFileImpl?: ExecFileLike;
}

export const DEFAULT_PROFILES_CLAIM_SELF_SCRIPT =
  process.env.PROFILES_CLAIM_SELF_SCRIPT ??
  "/opt/hydra/workspaces/support/skills/customer-profile-claim/scripts/claim-self.sh";

export function createProfilesClaimSelfTool(deps: ProfilesClaimSelfDeps): AgentTool<typeof Parameters, unknown> {
  const { scriptPath, rateLimiter, sessionKey, intercomReader, intercomToken, enabled, execFileImpl } = deps;
  const exec = execFileToPromise(execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "profiles_claim_self",
    label: "Verify the customer's own pending profile claim",
    description:
      "Approve the CUSTOMER'S OWN pending profile claim so they become the verified owner. " +
      "Ownership is anchored to the verified Intercom contact and re-verified server-side — a claim for a different account is refused. " +
      "Idempotent (an already-verified claim is a no-op). Always call apply=false first to preview, tell the customer, then apply=true. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Dark-ship gate (cheapest first): when off, do nothing so the agent falls
      // back to a normal ticket. No network, no exec.
      if (!enabled) {
        return textResult(JSON.stringify({ ok: false, disabled: true, note: "self-service profile claim is not enabled" }));
      }
      if (!rateLimiter.check(sessionKey, "profiles_claim_self", 60, 10).allowed) {
        return textResult(JSON.stringify({ ok: false, error: "rate_limited" }));
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
        "--claim-id", params.claimId,
        "--actor-identity", actorEmail,
        "--intercom-conv-id", convId,
      ];
      if (params.apply === true) argv.push("--apply");

      try {
        const { stdout, stderr } = await exec("bash", argv, { timeout: 60 * 1000, maxBuffer: 2 * 1024 * 1024 });
        if (stderr && stderr.trim()) console.warn(`[profiles_claim_self] wrapper stderr: ${stderr.trim()}`);
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
        if (stderrSnippet) console.warn(`[profiles_claim_self] wrapper exec failed; stderr: ${stderrSnippet}`);
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
