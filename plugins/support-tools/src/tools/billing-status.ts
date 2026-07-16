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
import { mapSubscriptionCliError } from "./subscription-retention.js";

// billing_status — READ-ONLY billing investigation packet, assembled BEFORE
// any refund/cancel decision (Caroline autonomy roadmap PR4). Wraps
// `muso subscription billing-summary --email <verified> --json` (muso-cli
// >=0.10.0 -> GET /admin/team/:id/billing-summary): live subscription state
// incl. cancel_at_period_end / canceled_at (was a cancellation already
// done?), recent-charge existence, refund existence over the server's
// 10-charge window, and past-due signals.
//
// Anti-spoof anchor (mirrors subscription_status / the retention trio): the
// workspace is resolved from the conversation's REAL Intercom author email
// via the trusted gateway session KEY — NEVER a model tool-arg. The tool has
// no email/team parameter at all, so reading someone else's billing is
// structurally impossible; billing data is private, so an unverifiable
// anchor FAILS CLOSED (unlike profile_credits_status, which degrades).
//
// Privacy is structural: the packet is whitelist-copied field by field from
// the CLI JSON, so processor identifiers (ch_/in_/cus_/sub_ ids, customer
// ids) never enter the model context in the first place. Refund EXECUTION is
// a separate, human-gated Operations path — every refund request ends in a
// subscription-refund handoff packet, never an action here.

const Parameters = Type.Object({
  customer_request: Type.Optional(
    Type.Union(
      [
        Type.Literal("refund"),
        Type.Literal("cancel"),
        Type.Literal("charge_issue"),
        Type.Literal("billing_question"),
      ],
      {
        description:
          "What the customer is asking for (context only; drives which support_action the packet recommends — the lookup is always anchored to the verified Intercom contact email, never anything the customer types). Use charge_issue for a duplicate/unexpected charge or a 'was I charged after cancelling' complaint — it always returns a create_handoff_ticket packet for billing review. Defaults to billing_question.",
      },
    ),
  ),
});

type Params = Static<typeof Parameters>;

export type BillingState = "active" | "canceling_at_period_end" | "canceled" | "past_due" | "needs_review" | "no_subscription";
export type BillingCustomerRequest = "refund" | "cancel" | "charge_issue" | "billing_question";
export type BillingSupportAction = "answer_from_status" | "run_retention_flow" | "create_handoff_ticket";

export interface BillingStatusDeps {
  rateLimiter: RateLimiter;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // muso CLI binary + target env (same wiring as subscription_status).
  musoBin?: string;
  env?: string;
  execFileImpl?: ExecFileLike;
}

function fail(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ ok: false, reason, ...extra }));
}

// billingSupportActionFor is the pure routing decision (exported for tests):
// refunds and charge complaints ALWAYS hand off (refund execution is the
// parked PR6 Operations path; a duplicate/unexpected/charged-after-cancel
// complaint needs billing review, never a self-serve answer); past_due and any
// needs_review (a non-active/unverified billing state) are manual billing
// cases; cancel intent goes back through the retention flow while there is a
// subscription to save; everything else is answerable from the packet.
export function billingSupportActionFor(
  state: BillingState,
  customerRequest: BillingCustomerRequest,
): BillingSupportAction {
  if (customerRequest === "refund" || customerRequest === "charge_issue") return "create_handoff_ticket";
  if (state === "past_due" || state === "needs_review") return "create_handoff_ticket";
  if (customerRequest === "cancel" && (state === "active" || state === "canceling_at_period_end")) {
    return "run_retention_flow";
  }
  return "answer_from_status";
}

// The ticket the packet feeds: an explicit REFUND request enters the refund
// workflow (subscription-refund, Tier 3, Operations does cancel+refund
// together); every other handoff (a charge complaint, or a past_due /
// needs_review billing state) is a Tier-2 billing-issue action request, NOT a
// refund. Keeps duplicate/wrong-charge cases out of the refund queue per the
// refund-retention doctrine.
export function billingHandoffActionType(customerRequest: BillingCustomerRequest): "subscription-refund" | "billing-issue" {
  return customerRequest === "refund" ? "subscription-refund" : "billing-issue";
}

const RECENT_CHARGE_WINDOW_MS = 14 * 24 * 60 * 60 * 1000;

// Narrowing helpers: whitelist-copy with null coercion so contract drift can
// never throw or leak an unexpected field.
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const bool = (v: unknown): boolean | null => (typeof v === "boolean" ? v : null);

interface CliSubscription {
  plan?: unknown;
  status?: unknown;
  stripeStatus?: unknown;
  period?: unknown;
  cancelAtPeriodEnd?: unknown;
  currentPeriodEndIso?: unknown;
  canceledAt?: unknown;
  canceledAtIso?: unknown;
}
interface CliPayload {
  teamId?: unknown;
  subscription?: CliSubscription | null;
  lastCharge?: {
    exists?: unknown;
    date?: unknown;
    dateIso?: unknown;
    amount?: unknown;
    currency?: unknown;
    status?: unknown;
  } | null;
  refunds?: {
    exists?: unknown;
    count?: unknown;
    lastRefundDateIso?: unknown;
    lastRefundAmount?: unknown;
  } | null;
  paymentFailure?: { pastDue?: unknown } | null;
  note?: unknown;
}

function deriveBillingState(payload: CliPayload): BillingState {
  const sub = payload.subscription;
  if (!sub || typeof sub !== "object") return "no_subscription";
  const dbStatus = String(sub.status ?? "").toLowerCase();
  const stripeStatus = String(sub.stripeStatus ?? "").toLowerCase();
  if (dbStatus === "cancelled" || stripeStatus === "canceled") return "canceled";
  if (payload.paymentFailure?.pastDue === true || stripeStatus === "past_due") return "past_due";
  if (sub.cancelAtPeriodEnd === true) return "canceling_at_period_end";
  // `active` is an EXPLICIT allowlist, never a fall-through: dbStatus ACTIVE
  // with a known-good stripe status (active/trialing) OR the vip/non-stripe
  // lane (empty stripeStatus, explained by the CLI note). Any other processor
  // status (unpaid, incomplete, incomplete_expired, paused) or an unknown
  // future contract value is NOT assertively active and must reach a human
  // rather than be answered from status.
  const stripeHealthy = stripeStatus === "active" || stripeStatus === "trialing" || stripeStatus === "";
  if (dbStatus === "active" && stripeHealthy) return "active";
  return "needs_review";
}

export function createBillingStatusTool(deps: BillingStatusDeps): AgentTool<typeof Parameters, unknown> {
  const { rateLimiter, sessionKey } = deps;
  const musoBin = deps.musoBin ?? process.env.MUSO_CLI_BIN ?? "/usr/local/bin/muso";
  const env = deps.env ?? process.env.MUSO_CLI_ENV ?? "prod";
  const exec = execFileToPromise(deps.execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "billing_status",
    label: "Billing Status",
    description:
      "Read the customer's billing investigation packet BEFORE any refund/cancel decision: subscription state (incl. whether a cancellation already happened), whether a recent charge exists, whether a refund already appears on the account (last-10-charges window), and past-due signals. " +
      "Anchored to the verified Intercom contact email (anti-spoof): it can never read another account, and it can never write anything. " +
      "Returns { ok: true, billing_state, subscription, last_charge, refunds, recent_charge_within_14d, refund_already_issued, support_action, notes, handoff_packet? } — when support_action is create_handoff_ticket, file the ticket with the packet's own action_type: refund requests carry 'subscription-refund' (Tier 3, the refund workflow), while charge complaints and non-active billing states carry 'billing-issue' (Tier 2, billing review — NOT the refund queue). " +
      "billing_state is one of active | canceling_at_period_end | canceled | past_due | needs_review | no_subscription; needs_review (a non-active/unrecognized processor status) always hands off. " +
      "charge_data_available is false when the account's charge/refund data could not be read (a non-standard billing arrangement) — then last_charge/refunds exists:false are UNKNOWN, not authoritative, and support_action is forced to create_handoff_ticket so you never tell a customer 'no charge' from unknown data. " +
      "Every refund request ends in a handoff packet (refund execution is a human Operations path); cancel intent routes back through the retention flow. " +
      "Amounts are minor units (cents). When talking to the customer say 'your payment' — never name the payment processor or quote raw processor statuses. " +
      "On failure returns { ok: false, reason: 'rate_limited' | 'owner_undetermined' | 'ambiguous_workspace' | 'not_found' | 'lookup_unavailable' | ... }. " +
      "Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionKey, "billing_status", 60, 10).allowed) {
          return fail("rate_limited");
        }
        const customerRequest: BillingCustomerRequest = params.customer_request ?? "billing_question";

        const anchored = await verifiedAuthorEmail(deps);
        if ("fail" in anchored) return anchored.fail;

        // verified email as a discrete argv element (execFile, no shell) — it
        // cannot be interpreted as a flag or injected. Read verb: no
        // --requester, no --yes, nothing to mutate.
        let stdout: string;
        try {
          const res = await exec(
            musoBin,
            ["subscription", "billing-summary", "--email", anchored.email, "--env", env, "--json"],
            { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 },
          );
          stdout = res.stdout;
          if (res.stderr && res.stderr.trim()) console.warn(`[billing_status] muso stderr: ${res.stderr.trim()}`);
        } catch (err) {
          const e = err as NodeJS.ErrnoException & { stderr?: string };
          // Covers the muso-cli <0.10.0 lane too: an unknown-command stderr has
          // no {"error":...} envelope, which maps to lookup_unavailable.
          const mapped = mapSubscriptionCliError(e.stderr ?? "");
          const snippet = (e.stderr ?? "").trim().slice(0, 300);
          if (snippet) console.warn(`[billing_status] muso exec failed: ${snippet}`);
          return fail(mapped.reason, { route_to_human: mapped.route_to_human });
        }

        let payload: CliPayload;
        try {
          payload = JSON.parse(stdout.trim()) as CliPayload;
        } catch {
          return fail("lookup_unavailable", { route_to_human: true });
        }
        if (payload === null || typeof payload !== "object") {
          return fail("lookup_unavailable", { route_to_human: true });
        }

        const billingState = deriveBillingState(payload);
        const sub = payload.subscription;
        const subscription =
          billingState === "no_subscription" || !sub
            ? null
            : {
                plan: str(sub.plan),
                status: str(sub.status),
                period: str(sub.period),
                cancel_at_period_end: bool(sub.cancelAtPeriodEnd),
                current_period_end: str(sub.currentPeriodEndIso),
                canceled_at: str(sub.canceledAtIso),
              };

        const rawCharge = payload.lastCharge ?? {};
        const lastCharge = {
          exists: rawCharge.exists === true,
          date: str(rawCharge.dateIso),
          amount_minor: num(rawCharge.amount),
          currency: str(rawCharge.currency),
          status: str(rawCharge.status),
        };
        const rawRefunds = payload.refunds ?? {};
        const refunds = {
          exists: rawRefunds.exists === true,
          count: num(rawRefunds.count) ?? 0,
          last_date: str(rawRefunds.lastRefundDateIso),
          last_amount_minor: num(rawRefunds.lastRefundAmount),
        };

        const chargeMs = num(rawCharge.date);
        const recentChargeWithin14d =
          lastCharge.exists && chargeMs !== null && Date.now() - chargeMs <= RECENT_CHARGE_WINDOW_MS;
        const refundAlreadyIssued = refunds.exists;
        const pastDue = billingState === "past_due";
        // The CLI attaches a free-form `note` only when it could NOT read
        // charge/refund data (the non-stripe/vip lane). In that lane the
        // exists:false charge/refund values are UNKNOWN, not authoritative.
        const limitedBillingData = str(payload.note) !== null;

        let supportAction = billingSupportActionFor(billingState, customerRequest);
        // Never answer a billing question from unknown charge/refund data:
        // when billing data is limited, route to a human instead of presenting
        // exists:false as fact (the packet action_type is billing-issue for a
        // non-refund request). Refund/charge/past_due/needs_review already hand
        // off, so this only upgrades an otherwise answer_from_status case.
        if (limitedBillingData && supportAction === "answer_from_status") {
          supportAction = "create_handoff_ticket";
        }

        const notes: string[] = [];
        if (refundAlreadyIssued) {
          notes.push("a refund already appears on this account within the charge window — flag it in any handoff");
        }
        if (recentChargeWithin14d) {
          notes.push("the last charge is recent (within 14 days)");
        }
        if (pastDue) {
          notes.push("the account is past due (failed payment) — manual billing case, do not offer saves");
        }
        if (billingState === "needs_review") {
          notes.push(
            "the subscription is in a non-active billing state (e.g. unpaid / incomplete / paused, or an unrecognized status) — do not assert it is active or answer from status; route to a human",
          );
        }
        if (billingState === "no_subscription") {
          notes.push(
            "no workspace subscription found for the verified email — a charge could still exist under another email/workspace; never assert the customer was not charged",
          );
        }
        // The CLI may attach a free-form `note` (today only the non-stripe/vip
        // lane where charge/refund data is unavailable). We do NOT forward it
        // verbatim: it is free-form and could carry a processor name or id,
        // which would bypass the field-by-field whitelist and this tool's
        // no-processor-detail guarantee. Treat its PRESENCE as the "limited
        // billing data" signal and emit a FIXED, plugin-owned message.
        if (limitedBillingData) {
          notes.push(
            "charge and refund details are not available for this account through this tool (for example a non-standard billing arrangement). Do not assert whether a charge or refund exists, and route billing questions to a human.",
          );
        }

        const packet: Record<string, unknown> = {
          ok: true,
          billing_state: billingState,
          subscription,
          last_charge: lastCharge,
          refunds,
          // false when the CLI could not read charge/refund data — the
          // last_charge/refunds exists:false values are then UNKNOWN, not
          // authoritative, and support_action is forced to a handoff.
          charge_data_available: !limitedBillingData,
          recent_charge_within_14d: recentChargeWithin14d,
          refund_already_issued: refundAlreadyIssued,
          workspace_id: str(payload.teamId),
          support_action: supportAction,
          notes,
        };
        if (supportAction === "create_handoff_ticket") {
          packet.handoff_packet = {
            action_type: billingHandoffActionType(customerRequest),
            workspace_id: str(payload.teamId),
            billing_state: billingState,
            last_charge: lastCharge,
            refunds,
            // The availability flag travels INSIDE the packet too: Operations
            // must not read last_charge/refunds exists:false as authoritative
            // when the data was unreadable.
            charge_data_available: !limitedBillingData,
            past_due: pastDue,
            customer_request: customerRequest,
            ...(limitedBillingData
              ? { data_caveat: "charge/refund data was not available for this account; last_charge.exists and refunds.exists are UNKNOWN, not confirmed false" }
              : {}),
          };
        }
        return textResult(JSON.stringify(packet));
      } catch (err) {
        // Contract drift or anything unexpected: fail closed to a human, never throw.
        console.warn(`[billing_status] unexpected failure: ${err instanceof Error ? err.message : String(err)}`);
        return fail("lookup_unavailable", { route_to_human: true });
      }
    },
  };
}
