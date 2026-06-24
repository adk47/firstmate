import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import { deriveConvId } from "./dedupe-check.js";

// credits_verify — gated WRITE: approve (verify) the CUSTOMER'S OWN pending,
// catalog-corroborated credit request by shelling
// `muso credits verify --actor-identity <email>`. The muso-cli capability gate
// re-fetches the request and refuses (exit 5, route_to_human) unless the
// request's profile is owned by the actor identity; an already-processed
// request is an idempotent no-op — so the worst a hijacked call can do is
// verify the customer's OWN pending request, which is the legitimate action.
// The WRITE counterpart of the read-only credit_verification_check.
//
// Anti-spoof anchor (mirrors profiles_claim_self / credit-verification-check.ts):
// the actor identity is the conversation's REAL Intercom author email, derived
// in-plugin from the trusted gateway session KEY (deriveConvId) — NEVER a model
// tool-arg and NEVER the message body. The wrapper trusts that ctx-derived email
// and muso re-verifies ownership server-side.

const UUID_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
const REQUEST_ID_PATTERN = "^[A-Za-z0-9_-]{1,128}$";

const Parameters = Type.Object({
  profileId: Type.String({
    pattern: UUID_PATTERN,
    description:
      "UUID of the profile whose pending credit to verify. muso re-verifies the profile is owned by the verified contact, so a foreign profile is refused server-side.",
  }),
  requestId: Type.String({
    pattern: REQUEST_ID_PATTERN,
    description:
      "The pending credit-request id to verify (from a prior credit_verification_check). muso re-verifies ownership, so a wrong/foreign id is refused server-side.",
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

export interface CreditsVerifyDeps {
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

export const DEFAULT_CREDITS_VERIFY_SCRIPT =
  process.env.CREDITS_VERIFY_SCRIPT ??
  "/opt/hydra/workspaces/support/skills/customer-credit-verification/scripts/verify-credit.sh";

export function createCreditsVerifyTool(deps: CreditsVerifyDeps): AgentTool<typeof Parameters, unknown> {
  const { scriptPath, rateLimiter, sessionKey, intercomReader, intercomToken, enabled, execFileImpl } = deps;
  const exec = execFileToPromise(execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "credits_verify",
    label: "Verify (approve) the customer's own pending credit request",
    description:
      "Approve the CUSTOMER'S OWN pending, catalog-corroborated credit request so the credit is verified to their profile. " +
      "Ownership is anchored to the verified Intercom contact and re-verified server-side — a request on a profile they do not own is refused. " +
      "Idempotent (an already-verified request is a no-op). Always call apply=false first to preview, tell the customer, then apply=true. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Dark-ship gate (cheapest first): when off, do nothing so the agent falls
      // back to a normal ticket. No network, no exec.
      if (!enabled) {
        return textResult(JSON.stringify({ ok: false, disabled: true, note: "self-service credit verification is not enabled" }));
      }
      if (!rateLimiter.check(sessionKey, "credits_verify", 60, 10).allowed) {
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
        "--profile", params.profileId,
        "--request-id", params.requestId,
        "--actor-identity", actorEmail,
        "--intercom-conv-id", convId,
      ];
      if (params.apply === true) argv.push("--apply");

      try {
        const { stdout, stderr } = await exec("bash", argv, { timeout: 60 * 1000, maxBuffer: 2 * 1024 * 1024 });
        if (stderr && stderr.trim()) console.warn(`[credits_verify] wrapper stderr: ${stderr.trim()}`);
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
        if (stderrSnippet) console.warn(`[credits_verify] wrapper exec failed; stderr: ${stderrSnippet}`);
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
