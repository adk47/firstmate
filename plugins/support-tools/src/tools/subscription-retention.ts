import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import {
  execFileToPromise,
  verifiedAuthorEmail,
  type ExecFileLike,
} from "./founding-buyback.js";

// retention_offer_check / retention_offer_apply / cancel_subscription — the
// refund-retention trio (the muso-cli `subscription` verbs against the
// team-keyed admin routes shipped in core-backend
// feat/admin-retention-offer-cancel).
//
//   retention_offer_check  READ-ONLY: is this workspace eligible for the
//                          product's own cancel-flow save (50% off 3 months
//                          monthly / 50% off 1 year annual), and with what
//                          wording. Read it BEFORE offering the discount.
//   retention_offer_apply  Applies that offer to the live Stripe sub. The
//                          coupon is resolved SERVER-SIDE from the same
//                          eligibility check — neither the model nor this
//                          plugin can choose a coupon.
//   cancel_subscription    The app's own cancel semantics: active subs cancel
//                          at PERIOD END (access runs out the paid period;
//                          reversible until then); past_due cancels
//                          immediately server-side. NO money moves — a refund
//                          is a separate, gated Operations path.
//
// Anti-spoof anchor (mirrors subscription_status / founding_buyback_link):
// the workspace is resolved from the conversation's REAL Intercom author
// email, derived in-plugin from the trusted gateway session KEY — NEVER a
// model tool-arg and NEVER the message body. A customer cannot check, apply,
// or cancel against someone else's workspace by typing a different email.
// The CLI re-anchors server-side (exact workspace-email match, refuses
// ambiguity) and its policy gate audits both writes (requester = the
// verified customer email; cancel is dangerous-tier).

const CheckParameters = Type.Object({
  query: Type.Optional(
    Type.String({
      description:
        "What the customer said about cancelling/refunding (context only; the lookup is anchored to the verified Intercom contact email, never to anything the customer types).",
    }),
  ),
});
type CheckParams = Static<typeof CheckParameters>;

const ApplyParameters = Type.Object({
  confirm: Type.Literal(true, {
    description:
      "Must be true, and only after the customer has explicitly ACCEPTED the retention offer in this conversation (e.g. said yes to the 50% off). Applying changes their next invoice(s) — never apply speculatively.",
  }),
});
type ApplyParams = Static<typeof ApplyParameters>;

const CancelParameters = Type.Object({
  confirm: Type.Literal(true, {
    description:
      "Must be true, and only after the customer has explicitly asked to cancel their subscription in this conversation AND declined the retention offers. Cancelling ends their paid access at period end.",
  }),
});
type CancelParams = Static<typeof CancelParameters>;

export interface SubscriptionRetentionDeps {
  rateLimiter: RateLimiter;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // Dark-ship gates for the WRITE tools only (default OFF, same rollout
  // lever as founding_buyback_link); the check is read-only and ungated.
  retentionOfferEnabled?: boolean;
  cancelSubscriptionEnabled?: boolean;
  // muso CLI binary + target env (same wiring as subscription_status).
  musoBin?: string;
  env?: string;
  execFileImpl?: ExecFileLike;
}

function fail(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ ok: false, reason, ...extra }));
}

// muso --json failures put exactly one {"error":{code,message,hint}} envelope
// line on stderr. Map the subscription domain guards to stable reasons the
// model can branch on; anything unrecognized routes to a human.
export function mapSubscriptionCliError(stderr: string): { reason: string; route_to_human: boolean } {
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
  if (m.includes("no retention offer available")) return { reason: "no_offer", route_to_human: false };
  if (m.includes("past due")) return { reason: "past_due_billing", route_to_human: true };
  if (m.includes("vip")) return { reason: "vip_manual", route_to_human: true };
  if (m.includes("only stripe")) return { reason: "not_stripe", route_to_human: true };
  if (m.includes("not active")) return { reason: "no_active_subscription", route_to_human: false };
  // Specific pattern (not bare word checks): the not-found message embeds the
  // customer's email, which could itself contain "matches"/"workspaces".
  if (/matches \d+ workspaces/.test(m)) return { reason: "ambiguous_workspace", route_to_human: true };
  if (m.includes("no workspace") || m.includes("not found")) return { reason: "not_found", route_to_human: true };
  return { reason: "lookup_unavailable", route_to_human: true };
}

// offerSummary narrows the CLI's offer envelope to the fields Caroline may
// quote; null when the workspace is ineligible.
function offerSummary(offer: unknown): { id: string; description: string; percent_off: number; duration_months: number } | null {
  if (offer === null || typeof offer !== "object") return null;
  const o = offer as { id?: unknown; description?: unknown; percent_off?: unknown; duration_in_months?: unknown };
  if (typeof o.id !== "string" || typeof o.description !== "string") return null;
  return {
    id: o.id,
    description: o.description,
    percent_off: typeof o.percent_off === "number" ? o.percent_off : 0,
    duration_months: typeof o.duration_in_months === "number" ? o.duration_in_months : 0,
  };
}

function cliRunner(deps: SubscriptionRetentionDeps) {
  const musoBin = deps.musoBin ?? process.env.MUSO_CLI_BIN ?? "/usr/local/bin/muso";
  const env = deps.env ?? process.env.MUSO_CLI_ENV ?? "prod";
  const exec = execFileToPromise(deps.execFileImpl ?? (execFile as ExecFileLike));
  return { musoBin, env, exec };
}

export function createRetentionOfferCheckTool(deps: SubscriptionRetentionDeps): AgentTool<typeof CheckParameters, unknown> {
  const { rateLimiter, sessionKey } = deps;
  const { musoBin, env, exec } = cliRunner(deps);

  return {
    name: "retention_offer_check",
    label: "Retention Offer Check",
    description:
      "Read whether the customer's OWN workspace is eligible for the retention discount — the SAME 50% save the in-app cancel flow offers (50% off 3 months on monthly plans, 50% off 1 year on annual). " +
      "Anchored to the verified Intercom contact email (anti-spoof): it can never read another account. " +
      "On success returns { ok: true, eligible, offer: { description, percent_off, duration_months } | null } — offer null means ineligible (no active Stripe sub, or already discounted); offer the free Lite plan instead. " +
      "Use it BEFORE mentioning any discount so the wording matches what can actually be applied. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: CheckParameters,
    async execute(_toolCallId: string, _params: CheckParams): Promise<AgentToolResult<unknown>> {
      if (!rateLimiter.check(sessionKey, "retention_offer_check", 60, 10).allowed) {
        return fail("rate_limited");
      }
      const anchored = await verifiedAuthorEmail(deps);
      if ("fail" in anchored) return anchored.fail;

      let stdout: string;
      try {
        const res = await exec(
          musoBin,
          ["subscription", "retention-offer", "--email", anchored.email, "--env", env, "--json"],
          { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
        );
        stdout = res.stdout;
        if (res.stderr && res.stderr.trim()) console.warn(`[retention_offer_check] muso stderr: ${res.stderr.trim()}`);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const mapped = mapSubscriptionCliError(e.stderr ?? "");
        const snippet = (e.stderr ?? "").trim().slice(0, 300);
        if (snippet) console.warn(`[retention_offer_check] muso exec failed: ${snippet}`);
        return fail(mapped.reason, { route_to_human: mapped.route_to_human });
      }

      let parsed: { teamId?: unknown; offer?: unknown };
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      if (parsed === null || typeof parsed !== "object") {
        return fail("lookup_unavailable", { route_to_human: true });
      }

      const offer = offerSummary(parsed.offer ?? null);
      return textResult(JSON.stringify({
        ok: true,
        eligible: offer !== null,
        offer,
        workspace_id: typeof parsed.teamId === "string" ? parsed.teamId : "",
      }));
    },
  };
}

export function createRetentionOfferApplyTool(deps: SubscriptionRetentionDeps): AgentTool<typeof ApplyParameters, unknown> {
  const { rateLimiter, sessionKey } = deps;
  const { musoBin, env, exec } = cliRunner(deps);

  return {
    name: "retention_offer_apply",
    label: "Retention Offer Apply",
    description:
      "Apply the retention discount to the customer's OWN workspace subscription (anchored to the verified Intercom contact email — it can never target another account). " +
      "The coupon is resolved SERVER-SIDE from the same eligibility check retention_offer_check reads; there is nothing to choose or pass. " +
      "Call it ONLY after the customer explicitly accepts the offer. " +
      "On success returns { ok: true, applied: true, offer: { description, ... } } — confirm to the customer with EXACTLY the returned description, never a figure you computed. " +
      "On failure { ok: false, reason: 'no_offer' (ineligible or already discounted — fall back to the free Lite plan) | 'past_due_billing' | 'not_found' | 'rate_limited' | ... }. " +
      "Rate limit: 3 calls / 60 min per session.",
    parameters: ApplyParameters,
    async execute(_toolCallId: string, params: ApplyParams): Promise<AgentToolResult<unknown>> {
      if (deps.retentionOfferEnabled !== true) {
        return textResult(JSON.stringify({ ok: false, disabled: true, note: "retention offer apply is not enabled; offer the free Lite plan and flag the request for the team" }));
      }
      if (params.confirm !== true) {
        return fail("not_confirmed", { detail: "apply only after the customer explicitly accepts the offer" });
      }
      if (!rateLimiter.check(sessionKey, "retention_offer_apply", 60, 3).allowed) {
        return fail("rate_limited");
      }
      const anchored = await verifiedAuthorEmail(deps);
      if ("fail" in anchored) return anchored.fail;

      // The verified email rides as a discrete argv element (execFile, no
      // shell). --requester attributes the gated write to the customer whose
      // subscription is discounted.
      let stdout: string;
      try {
        const res = await exec(
          musoBin,
          ["subscription", "apply-retention-offer", "--email", anchored.email, "--requester", anchored.email, "--env", env, "--json"],
          { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
        );
        stdout = res.stdout;
        if (res.stderr && res.stderr.trim()) console.warn(`[retention_offer_apply] muso stderr: ${res.stderr.trim()}`);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const mapped = mapSubscriptionCliError(e.stderr ?? "");
        const snippet = (e.stderr ?? "").trim().slice(0, 300);
        if (snippet) console.warn(`[retention_offer_apply] muso exec failed: ${snippet}`);
        return fail(mapped.reason, { route_to_human: mapped.route_to_human });
      }

      let parsed: { teamId?: unknown; success?: unknown; offer?: unknown };
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      if (parsed === null || typeof parsed !== "object" || parsed.success !== true) {
        return fail("apply_failed", { route_to_human: true });
      }
      const offer = offerSummary(parsed.offer ?? null);
      // A success without the applied offer's wording invites the model to
      // improvise a discount figure next to a real subscription change — refuse.
      if (!offer) {
        return fail("apply_unverified", { route_to_human: true, detail: "no offer envelope in the response" });
      }

      return textResult(JSON.stringify({
        ok: true,
        applied: true,
        offer,
        workspace_id: typeof parsed.teamId === "string" ? parsed.teamId : "",
      }));
    },
  };
}

export function createCancelSubscriptionTool(deps: SubscriptionRetentionDeps): AgentTool<typeof CancelParameters, unknown> {
  const { rateLimiter, sessionKey } = deps;
  const { musoBin, env, exec } = cliRunner(deps);

  return {
    name: "cancel_subscription",
    label: "Cancel Subscription",
    description:
      "Cancel the customer's OWN workspace subscription at PERIOD END — the app's own cancel semantics: paid access continues to the end of the current billing period, no money moves, and the cancel is reversible until then (anchored to the verified Intercom contact email — it can never target another account). " +
      "Call it ONLY after the customer explicitly asked to cancel AND declined the retention offers. " +
      "This is NOT a refund: if the customer wants money back, that is the refund path, not this tool. " +
      "On success returns { ok: true, cancelled: true, mode: 'period_end' | 'immediate', access_until } — tell the customer the access_until date when present. " +
      "On failure { ok: false, reason: 'no_active_subscription' (nothing to cancel) | 'not_stripe' | 'vip_manual' | 'not_found' | 'rate_limited' | ... }. " +
      "Rate limit: 3 calls / 60 min per session.",
    parameters: CancelParameters,
    async execute(_toolCallId: string, params: CancelParams): Promise<AgentToolResult<unknown>> {
      if (deps.cancelSubscriptionEnabled !== true) {
        return textResult(JSON.stringify({ ok: false, disabled: true, note: "subscription cancel is not enabled; guide the customer to Settings > Billing or flag the request for the team" }));
      }
      if (params.confirm !== true) {
        return fail("not_confirmed", { detail: "cancel only after the customer explicitly asks to cancel and declines the retention offers" });
      }
      if (!rateLimiter.check(sessionKey, "cancel_subscription", 60, 3).allowed) {
        return fail("rate_limited");
      }
      const anchored = await verifiedAuthorEmail(deps);
      if ("fail" in anchored) return anchored.fail;

      let stdout: string;
      try {
        const res = await exec(
          musoBin,
          [
            "subscription", "cancel",
            "--email", anchored.email,
            "--requester", anchored.email,
            "--reason", "Customer request via support (Caroline)",
            "--yes",
            "--env", env,
            "--json",
          ],
          { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
        );
        stdout = res.stdout;
        if (res.stderr && res.stderr.trim()) console.warn(`[cancel_subscription] muso stderr: ${res.stderr.trim()}`);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const mapped = mapSubscriptionCliError(e.stderr ?? "");
        const snippet = (e.stderr ?? "").trim().slice(0, 300);
        if (snippet) console.warn(`[cancel_subscription] muso exec failed: ${snippet}`);
        return fail(mapped.reason, { route_to_human: mapped.route_to_human });
      }

      let parsed: { teamId?: unknown; success?: unknown; mode?: unknown; currentPeriodEndIso?: unknown };
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        return fail("lookup_unavailable", { route_to_human: true });
      }
      if (parsed === null || typeof parsed !== "object" || parsed.success !== true) {
        return fail("cancel_unverified", { route_to_human: true });
      }
      const mode = parsed.mode === "immediate" ? "immediate" : "period_end";

      return textResult(JSON.stringify({
        ok: true,
        cancelled: true,
        mode,
        access_until: typeof parsed.currentPeriodEndIso === "string" ? parsed.currentPeriodEndIso : null,
        workspace_id: typeof parsed.teamId === "string" ? parsed.teamId : "",
      }));
    },
  };
}
