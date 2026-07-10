import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import { deriveConvId } from "./dedupe-check.js";

// founding_status / founding_buyback_link — the founding-member program pair
// (ADR 2026-05-28-founding-badge; endpoints shipped core-backend b83bcf04b).
//
//   founding_status       READ-ONLY founder envelope (active / lapsed / never)
//                          + subscription summary for the customer's workspace.
//   founding_buyback_link  Mints the PAID buy-back Stripe Checkout link: one
//                          ~24h URL bundling a Pro-annual subscription + the
//                          one-off arrears back to the 2026-06-30 program
//                          anchor. Payment reinstates (or late-buys-in)
//                          automatically via the Stripe webhook — nothing else
//                          to do after sending the URL. The mint itself changes
//                          no account state; the customer decides to pay.
//
// Anti-spoof anchor (mirrors subscription_status): the workspace is resolved
// from the conversation's REAL Intercom author email, derived in-plugin from
// the trusted gateway session KEY (deriveConvId) — NEVER a model tool-arg and
// NEVER the message body. A customer cannot mint a link (or read founder
// state) for someone else's workspace by typing a different email.
//
// Goes through `muso founding status|buyback-checkout --email <verified>`,
// which re-anchors server-side: the CLI exact-matches the workspace email over
// the server's substring filter and refuses ambiguity, and the policy gate
// audits the write (requester = the verified customer email). Comp (free)
// reinstate is deliberately NOT exposed here — that is an ops-only,
// approval-tier action (`muso founding reinstate`).

const StatusParameters = Type.Object({
  query: Type.Optional(
    Type.String({
      description:
        "What the customer is asking about their founding-member status (context only; the lookup is anchored to the verified Intercom contact email, never to anything the customer types).",
    }),
  ),
});
type StatusParams = Static<typeof StatusParameters>;

const BuybackParameters = Type.Object({
  confirm: Type.Literal(true, {
    description:
      "Must be true, and only after the customer has explicitly asked to rejoin / buy back their founding-member status in this conversation. Minting is harmless (paying is the customer's choice) but each link is a real Stripe session.",
  }),
});
type BuybackParams = Static<typeof BuybackParameters>;

export type ExecFileLike = (
  file: string,
  args: readonly string[],
  options: { timeout?: number; maxBuffer?: number },
  callback: (err: unknown, stdout: string, stderr: string) => void,
) => unknown;

export function execFileToPromise(fn: ExecFileLike) {
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

export interface FoundingDeps {
  rateLimiter: RateLimiter;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // Dark-ship gate for the MINT tool only (default OFF, same rollout lever as
  // profiles_claim_self / credits_verify); founding_status is read-only and
  // ungated like subscription_status.
  buybackEnabled?: boolean;
  // muso CLI binary + target env (same wiring as subscription_status).
  musoBin?: string;
  env?: string;
  execFileImpl?: ExecFileLike;
}

function fail(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ ok: false, reason, ...extra }));
}

// muso --json failures put exactly one {"error":{code,message,hint}} envelope
// line on stderr. Map the founding domain guards to stable reasons the model
// can branch on; anything unrecognized routes to a human.
export function mapFoundingCliError(stderr: string): { reason: string; route_to_human: boolean } {
  let message = "";
  for (const line of stderr.trim().split("\n")) {
    try {
      const parsed = JSON.parse(line) as { error?: { message?: unknown } };
      if (parsed && parsed.error && typeof parsed.error.message === "string") {
        message = parsed.error.message;
        break;
      }
    } catch {
      // not an envelope line; keep scanning
    }
  }
  const m = message.toLowerCase();
  if (m.includes("already an active founder")) return { reason: "already_founder", route_to_human: false };
  if (m.includes("no owner")) return { reason: "no_owner", route_to_human: true };
  // Specific pattern (not bare word checks): the not-found message embeds the
  // customer's email, which could itself contain "matches"/"workspaces".
  if (/matches \d+ workspaces/.test(m)) return { reason: "ambiguous_workspace", route_to_human: true };
  if (m.includes("no workspace") || m.includes("not found")) return { reason: "not_found", route_to_human: true };
  return { reason: "lookup_unavailable", route_to_human: true };
}

// verifiedAuthorEmail derives the trusted contact email from the conversation
// (fail-closed on every unverifiable path), shared by both tools (and the
// subscription-retention tools, which anchor identically).
export async function verifiedAuthorEmail(
  deps: Pick<FoundingDeps, "sessionKey" | "intercomReader" | "intercomToken">,
): Promise<{ email: string } | { fail: AgentToolResult<unknown> }> {
  const convId = deriveConvId(deps.sessionKey);
  if (!convId) {
    return { fail: fail("owner_undetermined", { route_to_human: true, detail: "conversation id unavailable; cannot verify identity" }) };
  }
  if (!deps.intercomToken) {
    return { fail: fail("owner_undetermined", { route_to_human: true, detail: "intercom token unavailable; cannot verify identity" }) };
  }
  let email: string | null;
  try {
    email = await deps.intercomReader.getAuthorEmail(convId, deps.intercomToken);
  } catch {
    return { fail: fail("lookup_unavailable", { route_to_human: true }) };
  }
  if (!email) {
    return { fail: fail("owner_undetermined", { route_to_human: true, detail: "could not read the verified contact email; routed for human verification" }) };
  }
  return { email };
}

export function createFoundingStatusTool(deps: FoundingDeps): AgentTool<typeof StatusParameters, unknown> {
  const { rateLimiter, sessionKey } = deps;
  const musoBin = deps.musoBin ?? process.env.MUSO_CLI_BIN ?? "/usr/local/bin/muso";
  const env = deps.env ?? process.env.MUSO_CLI_ENV ?? "prod";
  const exec = execFileToPromise(deps.execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "founding_status",
    label: "Founding Member Status",
    description:
      "Read the customer's founding-member status: whether their workspace is an active founder, a LAPSED founder (eligible for the paid buy-back), or was never in the program — plus since-year and subscription summary. " +
      "Anchored to the verified Intercom contact email (anti-spoof): a customer can only ever see their OWN status. " +
      "On success returns { ok: true, founder_active, ever_founder, since_year, lapsed_at, workspace_id, plan, sub_status }; " +
      "on failure { ok: false, reason }. Use it BEFORE discussing buy-back or founding perks. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: StatusParameters,
    async execute(_toolCallId: string, _params: StatusParams): Promise<AgentToolResult<unknown>> {
      if (!rateLimiter.check(sessionKey, "founding_status", 60, 10).allowed) {
        return fail("rate_limited");
      }
      const anchored = await verifiedAuthorEmail(deps);
      if ("fail" in anchored) return anchored.fail;

      let stdout: string;
      try {
        const res = await exec(
          musoBin,
          ["founding", "status", "--email", anchored.email, "--env", env, "--json"],
          { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
        );
        stdout = res.stdout;
        if (res.stderr && res.stderr.trim()) console.warn(`[founding_status] muso stderr: ${res.stderr.trim()}`);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const mapped = mapFoundingCliError(e.stderr ?? "");
        const snippet = (e.stderr ?? "").trim().slice(0, 300);
        if (snippet) console.warn(`[founding_status] muso exec failed: ${snippet}`);
        return fail(mapped.reason, { route_to_human: mapped.route_to_human });
      }

      let parsed: {
        teamId?: unknown;
        founder?: { active?: unknown; sinceYear?: unknown; lapsedAt?: unknown } | null;
        subscription?: { plan?: unknown; status?: unknown } | null;
      };
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      if (parsed === null || typeof parsed !== "object") {
        return fail("lookup_unavailable", { route_to_human: true });
      }

      const founder = parsed.founder ?? null;
      return textResult(JSON.stringify({
        ok: true,
        founder_active: founder ? founder.active === true : false,
        ever_founder: founder != null,
        since_year: founder && founder.sinceYear != null ? Number(founder.sinceYear) : null,
        lapsed_at: founder && founder.lapsedAt != null ? String(founder.lapsedAt) : null,
        workspace_id: typeof parsed.teamId === "string" ? parsed.teamId : "",
        plan: parsed.subscription?.plan != null ? String(parsed.subscription.plan) : null,
        sub_status: parsed.subscription?.status != null ? String(parsed.subscription.status) : null,
      }));
    },
  };
}

export function createFoundingBuybackTool(deps: FoundingDeps): AgentTool<typeof BuybackParameters, unknown> {
  const { rateLimiter, sessionKey } = deps;
  const musoBin = deps.musoBin ?? process.env.MUSO_CLI_BIN ?? "/usr/local/bin/muso";
  const env = deps.env ?? process.env.MUSO_CLI_ENV ?? "prod";
  const exec = execFileToPromise(deps.execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "founding_buyback_link",
    label: "Founding Buy-Back Link",
    description:
      "Mint the founding-member PAID buy-back Stripe Checkout link for the customer's OWN workspace (anchored to the verified Intercom contact email — it can never target another account). " +
      "The single link bundles a Pro-annual subscription + the one-off arrears back to the 2026-06-30 program anchor; it lives ~24h and payment reinstates founding status automatically. " +
      "Call it ONLY after the customer explicitly asks to rejoin/buy back. " +
      "On success returns { ok: true, url, arrears_months, arrears_cents, since_year, seats, expires_note } — quote ONLY these returned figures, never estimate an amount. " +
      "On failure { ok: false, reason: 'already_founder' (they are not lapsed; nothing to buy) | 'not_found' | 'ambiguous_workspace' | 'rate_limited' | ... }. " +
      "Comp/free reinstates are NOT this tool — flag those to the team. Rate limit: 3 calls / 60 min per session.",
    parameters: BuybackParameters,
    async execute(_toolCallId: string, params: BuybackParams): Promise<AgentToolResult<unknown>> {
      if (deps.buybackEnabled !== true) {
        return textResult(JSON.stringify({ ok: false, disabled: true, note: "founding buy-back link minting is not enabled; flag the request for the team" }));
      }
      if (params.confirm !== true) {
        return fail("not_confirmed", { detail: "mint only after the customer explicitly asks to buy back" });
      }
      if (!rateLimiter.check(sessionKey, "founding_buyback_link", 60, 3).allowed) {
        return fail("rate_limited");
      }
      const anchored = await verifiedAuthorEmail(deps);
      if ("fail" in anchored) return anchored.fail;

      // The verified email rides as a discrete argv element (execFile, no
      // shell). --requester attributes the gated write to the customer the
      // link is minted for; the CLI's per-actor/day mint cap keys off it too.
      let stdout: string;
      try {
        const res = await exec(
          musoBin,
          ["founding", "buyback-checkout", "--email", anchored.email, "--requester", anchored.email, "--env", env, "--json"],
          { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
        );
        stdout = res.stdout;
        if (res.stderr && res.stderr.trim()) console.warn(`[founding_buyback_link] muso stderr: ${res.stderr.trim()}`);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const mapped = mapFoundingCliError(e.stderr ?? "");
        const snippet = (e.stderr ?? "").trim().slice(0, 300);
        if (snippet) console.warn(`[founding_buyback_link] muso exec failed: ${snippet}`);
        return fail(mapped.reason, { route_to_human: mapped.route_to_human });
      }

      let parsed: {
        teamId?: unknown;
        url?: unknown;
        arrearsMonths?: unknown;
        arrearsCents?: unknown;
        sinceYear?: unknown;
        seats?: unknown;
      };
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      if (parsed === null || typeof parsed !== "object") {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      // The URL is relayed verbatim to the customer as a payment link: pin it
      // to the Stripe Checkout origin so an upstream regression can never hand
      // Caroline an arbitrary https URL to send.
      if (typeof parsed.url !== "string" || !parsed.url.startsWith("https://checkout.stripe.com/")) {
        return fail("lookup_unavailable", { route_to_human: true, detail: "no stripe checkout url in the response" });
      }
      // The model is told to quote ONLY these figures; a link without real
      // arrears figures invites estimating around a bogus amount, so refuse.
      // Guard the RAW field type, not Number(): Number(null) and Number("")
      // are 0 (finite), so a coerce-then-isFinite check would pass a null/
      // missing arrears through as a $0.00 back-pay next to a live link.
      const arrearsMonths = parsed.arrearsMonths;
      const arrearsCents = parsed.arrearsCents;
      if (
        typeof arrearsMonths !== "number" || !Number.isFinite(arrearsMonths) ||
        typeof arrearsCents !== "number" || !Number.isFinite(arrearsCents)
      ) {
        return fail("lookup_unavailable", { route_to_human: true, detail: "no arrears figures in the response" });
      }

      const sinceYear = typeof parsed.sinceYear === "number" && Number.isFinite(parsed.sinceYear) ? parsed.sinceYear : null;
      const seats = typeof parsed.seats === "number" && Number.isFinite(parsed.seats) ? parsed.seats : null;
      return textResult(JSON.stringify({
        ok: true,
        url: parsed.url,
        workspace_id: typeof parsed.teamId === "string" ? parsed.teamId : "",
        arrears_months: arrearsMonths,
        arrears_cents: arrearsCents,
        since_year: sinceYear,
        seats,
        expires_note: "the link lives ~24h; paying it reinstates founding status automatically",
      }));
    },
  };
}
