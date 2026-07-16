import { describe, it, expect, vi } from "vitest";
import {
  createBillingStatusTool,
  billingSupportActionFor,
  billingHandoffActionType,
  type BillingStatusDeps,
} from "../src/tools/billing-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { IntercomReader } from "../src/intercom-client.js";

const VERIFIED_EMAIL = "owner@example.com";
const SESSION_KEY = "agent:support:intercom:direct:CONV123";

function makeReader(email: string | null = VERIFIED_EMAIL): IntercomReader {
  return { getAuthorEmail: vi.fn(async () => email) };
}

type ExecImpl = NonNullable<BillingStatusDeps["execFileImpl"]>;
interface MockExec {
  impl: ExecImpl;
  calls: { file: string; args: readonly string[] }[];
}
function makeExec(opts: { stdout?: string; rejectWith?: Error }): MockExec {
  const calls: MockExec["calls"] = [];
  const impl: ExecImpl = (file, args, _options, callback) => {
    calls.push({ file, args });
    if (opts.rejectWith) {
      callback(opts.rejectWith, "", (opts.rejectWith as Error & { stderr?: string }).stderr ?? "");
    } else {
      callback(null, opts.stdout ?? "", "");
    }
    return undefined;
  };
  return { impl, calls };
}

function makeDeps(overrides: Partial<BillingStatusDeps> = {}): BillingStatusDeps {
  return {
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomReader: makeReader(),
    intercomToken: "tok",
    execFileImpl: makeExec({ stdout: "{}" }).impl,
    ...overrides,
  };
}

async function call(tool: ReturnType<typeof createBillingStatusTool>, params: Record<string, unknown> = {}) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as { type: "text"; text: string }).text);
}

// A full stripe-lane CLI payload the way muso >=0.10.0 emits it
// (subscription billing-summary --json; ms epochs + derived ISO twins).
const DAY = 24 * 60 * 60 * 1000;
function cliPayload(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    teamId: "1bbcc4b5-e44a-4664-adeb-7e255c813f8e",
    service: "stripe",
    subscription: {
      plan: "business_monthly",
      status: "ACTIVE",
      stripeStatus: "active",
      period: "monthly",
      cancelAtPeriodEnd: false,
      currentPeriodEnd: 1798761600000,
      currentPeriodEndIso: "2026-12-31T00:00:00Z",
      canceledAt: null,
    },
    lastCharge: {
      exists: true,
      date: 1780272000000,
      dateIso: "2026-06-01T00:00:00Z",
      amount: 3900,
      currency: "usd",
      paid: true,
      status: "succeeded",
    },
    refunds: { exists: false, count: 0, lastRefundDate: null, lastRefundAmount: null },
    paymentFailure: { pastDue: false, lastFailedChargeDate: null },
    ...overrides,
  });
}

describe("billing_status", () => {
  it("active subscription happy path → billing_state active, normalized fields, answer_from_status", async () => {
    const exec = makeExec({ stdout: cliPayload() });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "billing_question" });

    expect(out.ok).toBe(true);
    expect(out.billing_state).toBe("active");
    expect(out.subscription).toEqual({
      plan: "business_monthly",
      status: "ACTIVE",
      period: "monthly",
      cancel_at_period_end: false,
      current_period_end: "2026-12-31T00:00:00Z",
      canceled_at: null,
    });
    expect(out.last_charge).toEqual({
      exists: true,
      date: "2026-06-01T00:00:00Z",
      amount_minor: 3900,
      currency: "usd",
      status: "succeeded",
    });
    expect(out.refunds).toEqual({ exists: false, count: 0, last_date: null, last_amount_minor: null });
    expect(out.refund_already_issued).toBe(false);
    expect(out.charge_data_available).toBe(true);
    expect(out.workspace_id).toBe("1bbcc4b5-e44a-4664-adeb-7e255c813f8e");
    expect(out.support_action).toBe("answer_from_status");
    expect(out.handoff_packet).toBeUndefined();
    // Anti-spoof: the CLI is invoked with the VERIFIED email, never a model arg.
    expect(exec.calls).toHaveLength(1);
    expect(exec.calls[0].args).toEqual([
      "subscription", "billing-summary", "--email", VERIFIED_EMAIL, "--env", "prod", "--json",
    ]);
  });

  it("cancel_at_period_end → billing_state canceling_at_period_end with the period end surfaced", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        subscription: {
          plan: "business_monthly", status: "ACTIVE", stripeStatus: "active", period: "monthly",
          cancelAtPeriodEnd: true,
          currentPeriodEnd: 1798761600000, currentPeriodEndIso: "2026-12-31T00:00:00Z",
          canceledAt: 1782777600000, canceledAtIso: "2026-06-30T00:00:00Z",
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.billing_state).toBe("canceling_at_period_end");
    expect(out.subscription.current_period_end).toBe("2026-12-31T00:00:00Z");
  });

  it("canceled subscription → billing_state canceled with canceled_at", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        subscription: {
          plan: "business_monthly", status: "CANCELLED", stripeStatus: "canceled", period: "monthly",
          cancelAtPeriodEnd: false, currentPeriodEnd: null,
          canceledAt: 1782777600000, canceledAtIso: "2026-06-30T00:00:00Z",
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.billing_state).toBe("canceled");
    expect(out.subscription.canceled_at).toBe("2026-06-30T00:00:00Z");
  });

  it("no subscription ever (200 shape, subscription null) → ok:true billing_state no_subscription", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        service: "",
        subscription: null,
        lastCharge: { exists: false, date: null, amount: null, currency: "", paid: null, status: "" },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(true);
    expect(out.billing_state).toBe("no_subscription");
    expect(out.subscription).toBeNull();
    expect(out.last_charge.exists).toBe(false);
  });

  it("refund request with a recent charge → create_handoff_ticket carrying the charge in the packet", async () => {
    const recent = Date.now() - 5 * DAY;
    const recentIso = new Date(recent).toISOString();
    const exec = makeExec({
      stdout: cliPayload({
        lastCharge: {
          exists: true, date: recent, dateIso: recentIso,
          amount: 3900, currency: "usd", paid: true, status: "succeeded",
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "refund" });

    expect(out.recent_charge_within_14d).toBe(true);
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.handoff_packet).toMatchObject({
      action_type: "subscription-refund",
      workspace_id: "1bbcc4b5-e44a-4664-adeb-7e255c813f8e",
      billing_state: "active",
      customer_request: "refund",
      past_due: false,
      charge_data_available: true,
    });
    expect(out.handoff_packet.data_caveat).toBeUndefined();
    expect(out.handoff_packet.last_charge.amount_minor).toBe(3900);
    expect(out.notes.join(" ")).toMatch(/recent/i);
  });

  it("charge_issue on an active subscriber → create_handoff_ticket with a packet (a duplicate-charge complaint must not self-serve answer)", async () => {
    const recent = Date.now() - 3 * DAY;
    const recentIso = new Date(recent).toISOString();
    const exec = makeExec({
      stdout: cliPayload({
        lastCharge: {
          exists: true, date: recent, dateIso: recentIso,
          amount: 3900, currency: "usd", paid: true, status: "succeeded",
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "charge_issue" });

    expect(out.billing_state).toBe("active");
    expect(out.support_action).toBe("create_handoff_ticket");
    // A charge complaint files a Tier-2 billing-issue ticket, NOT the refund
    // workflow — that is the refund-retention doctrine's billing-issue path.
    expect(out.handoff_packet).toMatchObject({
      action_type: "billing-issue",
      billing_state: "active",
      customer_request: "charge_issue",
    });
    expect(out.handoff_packet.last_charge.amount_minor).toBe(3900);
  });

  it("non-active processor status (e.g. unpaid) → needs_review + create_handoff_ticket, never answered from status", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        subscription: {
          plan: "business_monthly", status: "ACTIVE", stripeStatus: "unpaid", period: "monthly",
          cancelAtPeriodEnd: false, currentPeriodEnd: 1798761600000,
          currentPeriodEndIso: "2026-12-31T00:00:00Z", canceledAt: null,
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "billing_question" });

    expect(out.billing_state).toBe("needs_review");
    expect(out.support_action).toBe("create_handoff_ticket");
    // A non-refund handoff (here a billing question on a non-active sub) is a
    // billing-issue, not a refund.
    expect(out.handoff_packet.action_type).toBe("billing-issue");
    expect(out.notes.join(" ")).toMatch(/non-active billing state/i);
  });

  it("refund request still files subscription-refund (the refund workflow) even for a non-active state", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        subscription: {
          plan: "business_monthly", status: "ACTIVE", stripeStatus: "paused", period: "monthly",
          cancelAtPeriodEnd: false, currentPeriodEnd: 1798761600000,
          currentPeriodEndIso: "2026-12-31T00:00:00Z", canceledAt: null,
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "refund" });
    expect(out.billing_state).toBe("needs_review");
    expect(out.handoff_packet.action_type).toBe("subscription-refund");
  });

  it("vip/non-stripe lane (empty stripeStatus + ACTIVE) stays active, not needs_review", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        service: "",
        subscription: {
          plan: "vip", status: "ACTIVE", stripeStatus: "", period: "",
          cancelAtPeriodEnd: null, currentPeriodEnd: null, canceledAt: null,
        },
        lastCharge: { exists: false, date: null, amount: null, currency: "", paid: null, status: "" },
        note: "non-stripe or vip subscription — charge/refund data not available here",
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.billing_state).toBe("active");
  });

  it("prior refund on the account → refund_already_issued true and flagged in the notes/packet", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        refunds: {
          exists: true, count: 1,
          lastRefundDate: 1780272000000, lastRefundDateIso: "2026-06-01T00:00:00Z",
          lastRefundAmount: 3900,
        },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "refund" });
    expect(out.refund_already_issued).toBe(true);
    expect(out.refunds).toEqual({
      exists: true, count: 1, last_date: "2026-06-01T00:00:00Z", last_amount_minor: 3900,
    });
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.notes.join(" ")).toMatch(/refund already/i);
  });

  it("cancel request on an active sub → run_retention_flow (this tool never cancels)", async () => {
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ stdout: cliPayload() }).impl }));
    const out = await call(tool, { customer_request: "cancel" });
    expect(out.support_action).toBe("run_retention_flow");
    expect(out.handoff_packet).toBeUndefined();
  });

  it("past_due → billing_state past_due and create_handoff_ticket regardless of request", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        subscription: {
          plan: "business_monthly", status: "ACTIVE", stripeStatus: "past_due", period: "monthly",
          cancelAtPeriodEnd: false, currentPeriodEnd: 1798761600000,
          currentPeriodEndIso: "2026-12-31T00:00:00Z", canceledAt: null,
        },
        paymentFailure: { pastDue: true, lastFailedChargeDate: 1782777600000 },
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "billing_question" });
    expect(out.billing_state).toBe("past_due");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.handoff_packet.past_due).toBe(true);
  });

  it("VIP / non-stripe lane (limited billing data) → hands off, never answers a billing question from unknown exists:false", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        service: "",
        subscription: {
          plan: "vip", status: "ACTIVE", stripeStatus: "", period: "",
          cancelAtPeriodEnd: null, currentPeriodEnd: null, canceledAt: null,
        },
        lastCharge: { exists: false, date: null, amount: null, currency: "", paid: null, status: "" },
        note: "non-stripe or vip subscription — charge/refund data not available here",
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    // A plain billing_question that would otherwise answer_from_status:
    const out = await call(tool, { customer_request: "billing_question" });
    expect(out.ok).toBe(true);
    expect(out.billing_state).toBe("active");
    // charge/refund data is UNKNOWN here, so exists:false must not be answered
    // from — the tool flags it and forces a handoff.
    expect(out.charge_data_available).toBe(false);
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.handoff_packet.action_type).toBe("billing-issue");
    // The safeguard must travel INSIDE the packet too, so Operations does not
    // read exists:false as authoritative.
    expect(out.handoff_packet.charge_data_available).toBe(false);
    expect(out.handoff_packet.data_caveat).toMatch(/unknown, not confirmed false/i);
    expect(out.notes.join(" ")).toMatch(/not available/i);
  });

  it("ambiguous workspace envelope → ok:false ambiguous_workspace, route_to_human, no packet", async () => {
    const err = new Error("exit 3") as Error & { stderr?: string };
    err.stderr = JSON.stringify({ error: { code: "not_found", message: `email "${VERIFIED_EMAIL}" matches 2 workspaces` } });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ rejectWith: err }).impl }));
    const out = await call(tool, { customer_request: "refund" });
    expect(out).toMatchObject({ ok: false, reason: "ambiguous_workspace", route_to_human: true });
    expect(out.handoff_packet).toBeUndefined();
  });

  it("workspace not found → ok:false not_found, route_to_human (roadmap no-match state)", async () => {
    const err = new Error("exit 3") as Error & { stderr?: string };
    err.stderr = JSON.stringify({ error: { code: "not_found", message: "no workspace found for email" } });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ rejectWith: err }).impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "not_found", route_to_human: true });
  });

  it("anti-spoof: unverifiable identity fails closed and the CLI is NEVER invoked", async () => {
    const exec = makeExec({ stdout: cliPayload() });
    const tool = createBillingStatusTool(
      makeDeps({ intercomReader: makeReader(null), execFileImpl: exec.impl }),
    );
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "owner_undetermined", route_to_human: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("anti-spoof: the tool exposes no email/team parameter at all", () => {
    const tool = createBillingStatusTool(makeDeps());
    const keys = Object.keys((tool.parameters as { properties: Record<string, unknown> }).properties);
    expect(keys).toEqual(["customer_request"]);
  });

  it("never writes structurally: exactly one exec, the read verb pair, no --requester/--yes", async () => {
    const exec = makeExec({ stdout: cliPayload() });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    await call(tool, { customer_request: "refund" });
    expect(exec.calls).toHaveLength(1);
    expect(exec.calls[0].args.slice(0, 2)).toEqual(["subscription", "billing-summary"]);
    expect(exec.calls[0].args).not.toContain("--requester");
    expect(exec.calls[0].args).not.toContain("--yes");
  });

  it("privacy: processor identifiers salted into the CLI output never reach the packet", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        stripe_customer: "cus_ABC123",
        lastCharge: {
          exists: true, date: 1780272000000, dateIso: "2026-06-01T00:00:00Z",
          amount: 3900, currency: "usd", paid: true, status: "succeeded",
          id: "ch_XYZ789", invoice: "in_INV001", customer: "cus_ABC123",
        },
        subscription: {
          plan: "business_monthly", status: "ACTIVE", stripeStatus: "active", period: "monthly",
          cancelAtPeriodEnd: false, currentPeriodEnd: 1798761600000,
          currentPeriodEndIso: "2026-12-31T00:00:00Z", canceledAt: null,
          externalSubId: "sub_EXT555",
        },
        // The free-form `note` is NOT forwarded verbatim — a processor name or
        // id planted here must not reach the packet either.
        note: "customer cus_LEAK999 on stripe, refunded charge ch_LEAK888",
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { customer_request: "refund" });
    const text = JSON.stringify(out);
    for (const leak of ["cus_ABC123", "ch_XYZ789", "in_INV001", "sub_EXT555", "stripe_customer", "cus_LEAK999", "ch_LEAK888", "stripe"]) {
      expect(text).not.toContain(leak);
    }
    expect(out.ok).toBe(true);
  });

  it("a CLI note is replaced by a fixed plugin-owned message, never forwarded verbatim", async () => {
    const exec = makeExec({
      stdout: cliPayload({
        service: "",
        subscription: {
          plan: "business_monthly", status: "ACTIVE", stripeStatus: "", period: "monthly",
          cancelAtPeriodEnd: false, currentPeriodEnd: null, canceledAt: null,
        },
        lastCharge: { exists: false, date: null, amount: null, currency: "", paid: null, status: "" },
        note: "non-stripe or vip subscription — charge/refund data not available here",
      }),
    });
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    const notesText = out.notes.join(" ");
    // conveys "charge data unavailable" via a fixed message that names no
    // processor and forwards no verbatim CLI text
    expect(notesText).toMatch(/not available for this account/i);
    expect(notesText).not.toContain("non-stripe or vip subscription");
    expect(notesText).not.toMatch(/stripe/i);
  });

  it("muso-cli 0.9.0 degradation: unknown-command stderr (no JSON envelope) → lookup_unavailable", async () => {
    const err = new Error("exit 1") as Error & { stderr?: string };
    err.stderr = 'Error: unknown command "billing-summary" for "muso subscription"';
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ rejectWith: err }).impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  it("missing muso binary (ENOENT) → lookup_unavailable", async () => {
    const err = new Error("spawn muso ENOENT") as Error & { stderr?: string; code?: string };
    err.code = "ENOENT";
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ rejectWith: err }).impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  it("non-JSON stdout → lookup_unavailable", async () => {
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ stdout: "flagrant garbage" }).impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  it("rate limits after 10 calls per session", async () => {
    const tool = createBillingStatusTool(makeDeps({ execFileImpl: makeExec({ stdout: cliPayload() }).impl }));
    for (let i = 0; i < 10; i += 1) {
      const out = await call(tool);
      expect(out.ok).toBe(true);
    }
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "rate_limited" });
  });
});

describe("billingSupportActionFor (pure)", () => {
  it("refund requests ALWAYS hand off — no billing state answers a refund", () => {
    for (const state of ["active", "canceling_at_period_end", "canceled", "past_due", "no_subscription"] as const) {
      expect(billingSupportActionFor(state, "refund")).toBe("create_handoff_ticket");
    }
  });

  it("charge complaints ALWAYS hand off — a duplicate/unexpected charge is never self-serve answered, even for an active subscriber", () => {
    for (const state of ["active", "canceling_at_period_end", "canceled", "past_due", "no_subscription"] as const) {
      expect(billingSupportActionFor(state, "charge_issue")).toBe("create_handoff_ticket");
    }
  });

  it("past_due hands off regardless of the request", () => {
    for (const req of ["refund", "cancel", "charge_issue", "billing_question"] as const) {
      expect(billingSupportActionFor("past_due", req)).toBe("create_handoff_ticket");
    }
  });

  it("needs_review (non-active/unverified billing state) hands off regardless of the request", () => {
    for (const req of ["refund", "cancel", "charge_issue", "billing_question"] as const) {
      expect(billingSupportActionFor("needs_review", req)).toBe("create_handoff_ticket");
    }
  });

  it("cancel intent routes to the retention flow only while there is something to cancel", () => {
    expect(billingSupportActionFor("active", "cancel")).toBe("run_retention_flow");
    expect(billingSupportActionFor("canceling_at_period_end", "cancel")).toBe("run_retention_flow");
    expect(billingSupportActionFor("canceled", "cancel")).toBe("answer_from_status");
    expect(billingSupportActionFor("no_subscription", "cancel")).toBe("answer_from_status");
  });

  it("billing questions answer from status", () => {
    expect(billingSupportActionFor("active", "billing_question")).toBe("answer_from_status");
    expect(billingSupportActionFor("canceled", "billing_question")).toBe("answer_from_status");
    expect(billingSupportActionFor("no_subscription", "billing_question")).toBe("answer_from_status");
  });
});

describe("billingHandoffActionType (pure)", () => {
  it("only an explicit refund request enters the refund workflow; everything else is a billing-issue", () => {
    expect(billingHandoffActionType("refund")).toBe("subscription-refund");
    expect(billingHandoffActionType("charge_issue")).toBe("billing-issue");
    expect(billingHandoffActionType("cancel")).toBe("billing-issue");
    expect(billingHandoffActionType("billing_question")).toBe("billing-issue");
  });
});
