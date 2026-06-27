import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import { deriveConvId } from "./dedupe-check.js";

// subscription_status — READ-ONLY view of the customer's workspace subscription
// (plan, status, billing period, seat limit). Muso plans are WORKSPACE/TEAM
// level, so this resolves the verified contact email to their workspace(s) and
// reports the subscription the platform returns.
//
// Anti-spoof anchor (mirrors dedupe_check / credits_verify): the lookup email is
// the conversation's REAL Intercom author email, derived in-plugin from the
// trusted gateway session KEY (deriveConvId) — NEVER a model tool-arg and NEVER
// the message body. A customer cannot read someone else's subscription by typing
// a different email.
//
// Reads via `muso teams list --email <verified-email> --json`, which wraps
// GET /admin/team and returns the subscription inline ({plan,status,period,
// usersLimit}). The in-process MusoAdminClient is deliberately NOT used here:
//   (a) its GET allowlist does not include the /admin/team* endpoints, and
//   (b) resolving an ACCOUNT email through the profile-search index returns
//       name-fuzzy matches that do NOT anchor to the owning workspace (verified
//       against prod, 2026-06: searching a workspace email returned unrelated
//       profiles whose workspaces[] did not contain that email).
// `muso teams list --email` is an exact workspace-email anchor and returns the
// same subscription `muso teams get` would, in a single call, so this is the
// sanctioned execFile fallback for an endpoint the HTTP client cannot reach.

const Parameters = Type.Object({
  query: Type.Optional(
    Type.String({
      description:
        "What the customer is asking about their subscription (context only; the lookup is anchored to the verified Intercom contact email, never to anything the customer types).",
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

export interface SubscriptionStatusDeps {
  rateLimiter: RateLimiter;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // muso CLI binary + target env. The gateway PATH does not always include
  // /usr/local/bin, so default to the absolute path; prod is the live env.
  musoBin?: string;
  env?: string;
  execFileImpl?: ExecFileLike;
}

interface Subscription {
  plan?: unknown;
  status?: unknown;
  period?: unknown;
  usersLimit?: unknown;
}
interface TeamRow {
  id?: unknown;
  email?: unknown;
  subscription?: Subscription | null;
}

function fail(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ ok: false, reason, ...extra }));
}

export function createSubscriptionStatusTool(deps: SubscriptionStatusDeps): AgentTool<typeof Parameters, unknown> {
  const { rateLimiter, sessionKey, intercomReader, intercomToken } = deps;
  const musoBin = deps.musoBin ?? process.env.MUSO_CLI_BIN ?? "/usr/local/bin/muso";
  const env = deps.env ?? process.env.MUSO_CLI_ENV ?? "prod";
  const exec = execFileToPromise(deps.execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "subscription_status",
    label: "Subscription Status",
    description:
      "Read the customer's workspace subscription — plan, status, billing period, and seat limit. " +
      "Anchored to the verified Intercom contact email (anti-spoof): a customer can only ever see their OWN subscription. " +
      "On success returns { ok: true, has_subscription, plan, status, period, seats_limit, workspace_id }; " +
      "on failure returns { ok: false, reason: 'rate_limited' | 'owner_undetermined' | 'not_found' | 'lookup_unavailable' }. " +
      "Use this FIRST whenever a customer asks about their plan, billing, renewal, or whether their subscription is active, then guide them to Settings > Billing for changes. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, _params: Params): Promise<AgentToolResult<unknown>> {
      if (!rateLimiter.check(sessionKey, "subscription_status", 60, 10).allowed) {
        return fail("rate_limited");
      }

      // Anti-spoof anchor — derive the trusted contact email from the
      // conversation, never from a model arg. Fail closed on any unverifiable path.
      const convId = deriveConvId(sessionKey);
      if (!convId) {
        return fail("owner_undetermined", { route_to_human: true, detail: "conversation id unavailable; cannot verify identity" });
      }
      if (!intercomToken) {
        return fail("owner_undetermined", { route_to_human: true, detail: "intercom token unavailable; cannot verify identity" });
      }

      let verifiedEmail: string | null;
      try {
        verifiedEmail = await intercomReader.getAuthorEmail(convId, intercomToken);
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      if (!verifiedEmail) {
        return fail("owner_undetermined", { route_to_human: true, detail: "could not read the verified contact email; routed for human verification" });
      }

      // Resolve the verified email -> workspace(s) and read the subscription
      // inline via `muso teams list --email <email> --json` (GET /admin/team).
      // verifiedEmail is passed as a discrete argv element (execFile, no shell),
      // so it cannot be interpreted as a flag or injected.
      let stdout: string;
      try {
        const res = await exec(
          musoBin,
          ["teams", "list", "--email", verifiedEmail, "--env", env, "--json"],
          { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
        );
        stdout = res.stdout;
        if (res.stderr && res.stderr.trim()) console.warn(`[subscription_status] muso stderr: ${res.stderr.trim()}`);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const snippet = (e.stderr ?? "").trim().slice(0, 300);
        if (snippet) console.warn(`[subscription_status] muso exec failed: ${snippet}`);
        return fail("lookup_unavailable", { route_to_human: true, code: e.code ?? null });
      }

      let parsed: unknown;
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }

      const rows: TeamRow[] = (() => {
        const p = parsed as Record<string, unknown>;
        if (p && Array.isArray(p.items)) return p.items as TeamRow[];
        if (p && Array.isArray(p.data)) return p.data as TeamRow[];
        if (Array.isArray(parsed)) return parsed as TeamRow[];
        return [];
      })();

      // `--email` is a server-side SUBSTRING filter; re-filter to an EXACT
      // (case-insensitive) email match so a workspace whose email merely CONTAINS
      // the verified address as a substring is never mistaken for the customer's.
      const want = verifiedEmail.toLowerCase();
      const mine = rows.filter((r) => typeof r.email === "string" && (r.email as string).toLowerCase() === want);
      if (mine.length === 0) {
        // No workspace is billed to this verified email. Could be a team member
        // on someone else's workspace, or a customer with no workspace — either
        // way, guide to self-service / a human rather than guess.
        return fail("not_found", { route_to_human: true });
      }

      // Prefer a workspace that actually carries a subscription; among those,
      // prefer a non-CANCELLED one so an active plan wins over a stale cancelled one.
      const withSub = mine.filter((r) => r.subscription && typeof r.subscription === "object");
      const chosen =
        withSub.find((r) => String((r.subscription as Subscription).status ?? "").toUpperCase() !== "CANCELLED") ??
        withSub[0] ??
        mine[0];

      const sub = (chosen.subscription ?? null) as Subscription | null;
      const workspaceId = typeof chosen.id === "string" ? chosen.id : "";

      if (!sub) {
        return textResult(JSON.stringify({
          ok: true,
          has_subscription: false,
          plan: null,
          status: "none",
          period: null,
          seats_limit: null,
          workspace_id: workspaceId,
        }));
      }

      const seats = Number(sub.usersLimit);
      return textResult(JSON.stringify({
        ok: true,
        has_subscription: true,
        plan: sub.plan != null ? String(sub.plan) : null,
        status: sub.status != null ? String(sub.status) : null,
        period: sub.period != null ? String(sub.period) : null,
        seats_limit: Number.isFinite(seats) ? seats : null,
        workspace_id: workspaceId,
      }));
    },
  };
}
