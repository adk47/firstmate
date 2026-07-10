import { describe, it, expect, vi } from "vitest";
import {
  createRetentionOfferCheckTool,
  createRetentionOfferApplyTool,
  createCancelSubscriptionTool,
  mapSubscriptionCliError,
  type SubscriptionRetentionDeps,
} from "../src/tools/subscription-retention.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { IntercomReader } from "../src/intercom-client.js";

const VERIFIED_EMAIL = "owner@example.com";
const SESSION_KEY = "agent:support:intercom:direct:CONV123";

function makeReader(email: string | null = VERIFIED_EMAIL): IntercomReader {
  return { getAuthorEmail: vi.fn(async () => email) };
}

type ExecImpl = NonNullable<SubscriptionRetentionDeps["execFileImpl"]>;
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

function makeDeps(overrides: Partial<SubscriptionRetentionDeps> = {}): SubscriptionRetentionDeps {
  return {
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomReader: makeReader(),
    intercomToken: "tok",
    retentionOfferEnabled: true,
    cancelSubscriptionEnabled: true,
    execFileImpl: makeExec({ stdout: "{}" }).impl,
    ...overrides,
  };
}

async function call(tool: { execute: (id: string, p: any) => Promise<any> }, params: Record<string, unknown> = {}) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as { type: "text"; text: string }).text);
}

// One {"error":{...}} envelope line on stderr, the muso --json failure contract.
function cliError(message: string): Error {
  return Object.assign(new Error("exit 1"), {
    stderr: JSON.stringify({ error: { code: "error", message, hint: "" } }) + "\n",
  });
}

const OFFER = {
  id: "cvliKh5z",
  title: "A one-time offer before you go",
  description: "50% off for 3 months",
  percent_off: 50,
  duration: "repeating",
  duration_in_months: 3,
};

const OFFER_SUMMARY = {
  id: "cvliKh5z",
  description: "50% off for 3 months",
  percent_off: 50,
  duration_months: 3,
};

describe("retention_offer_check", () => {
  it("answers the eligible offer on the happy path, anchored to the verified email", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", offer: OFFER }) });
    const tool = createRetentionOfferCheckTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { query: "I want to cancel, too expensive" });
    expect(out).toEqual({ ok: true, eligible: true, offer: OFFER_SUMMARY, workspace_id: "ws-1" });
    // Anti-spoof: the CLI gets the VERIFIED email, never a model arg.
    expect(exec.calls[0].args).toEqual(["subscription", "retention-offer", "--email", VERIFIED_EMAIL, "--env", "prod", "--json"]);
  });

  it("answers eligible:false when the offer is null", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", offer: null }) });
    const tool = createRetentionOfferCheckTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: true, eligible: false, offer: null });
  });

  it("fails closed when identity cannot be verified, without reaching the CLI", async () => {
    const exec = makeExec({ stdout: "{}" });
    const tool = createRetentionOfferCheckTool(makeDeps({ intercomReader: makeReader(null), execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "owner_undetermined", route_to_human: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("fails closed on non-JSON CLI stdout", async () => {
    const exec = makeExec({ stdout: "not json" });
    const tool = createRetentionOfferCheckTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });
});

describe("retention_offer_apply", () => {
  const APPLY_STDOUT = JSON.stringify({
    teamId: "ws-1",
    success: true,
    offer: OFFER,
    discount: { coupon: { id: "cvliKh5z", percent_off: 50 } },
  });

  it("is dark-shipped OFF by default", async () => {
    const exec = makeExec({ stdout: APPLY_STDOUT });
    const tool = createRetentionOfferApplyTool(makeDeps({ retentionOfferEnabled: undefined, execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, disabled: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("refuses without the confirm literal", async () => {
    const exec = makeExec({ stdout: APPLY_STDOUT });
    const tool = createRetentionOfferApplyTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, {});
    expect(out).toMatchObject({ ok: false, reason: "not_confirmed" });
    expect(exec.calls).toHaveLength(0);
  });

  it("applies on the happy path with the verified email as both target and requester", async () => {
    const exec = makeExec({ stdout: APPLY_STDOUT });
    const tool = createRetentionOfferApplyTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toEqual({ ok: true, applied: true, offer: OFFER_SUMMARY, workspace_id: "ws-1" });
    expect(exec.calls[0].args).toEqual([
      "subscription", "apply-retention-offer",
      "--email", VERIFIED_EMAIL,
      "--requester", VERIFIED_EMAIL,
      "--env", "prod", "--json",
    ]);
  });

  it("maps the server's no-offer guard to no_offer (fall back to the free plan)", async () => {
    const exec = makeExec({ rejectWith: cliError("No retention offer available (subscription inactive, not on Stripe, or already discounted)") });
    const tool = createRetentionOfferApplyTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "no_offer", route_to_human: false });
  });

  it("refuses a success without the offer envelope (nothing safe to quote)", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", success: true, offer: null }) });
    const tool = createRetentionOfferApplyTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "apply_unverified", route_to_human: true });
  });

  it("fails closed when identity cannot be verified, without reaching the CLI", async () => {
    const exec = makeExec({ stdout: APPLY_STDOUT });
    const tool = createRetentionOfferApplyTool(makeDeps({ intercomReader: makeReader(null), execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "owner_undetermined", route_to_human: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("rate limits at 3 per hour per session", async () => {
    const exec = makeExec({ stdout: APPLY_STDOUT });
    const deps = makeDeps({ execFileImpl: exec.impl });
    const tool = createRetentionOfferApplyTool(deps);
    await call(tool, { confirm: true });
    await call(tool, { confirm: true });
    await call(tool, { confirm: true });
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "rate_limited" });
    expect(exec.calls).toHaveLength(3);
  });
});

describe("cancel_subscription", () => {
  const CANCEL_STDOUT = JSON.stringify({
    teamId: "ws-1",
    success: true,
    mode: "period_end",
    currentPeriodEnd: 1767225600,
    currentPeriodEndIso: "2026-01-01T00:00:00Z",
  });

  it("is dark-shipped OFF by default", async () => {
    const exec = makeExec({ stdout: CANCEL_STDOUT });
    const tool = createCancelSubscriptionTool(makeDeps({ cancelSubscriptionEnabled: undefined, execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, disabled: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("refuses without the confirm literal", async () => {
    const exec = makeExec({ stdout: CANCEL_STDOUT });
    const tool = createCancelSubscriptionTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, {});
    expect(out).toMatchObject({ ok: false, reason: "not_confirmed" });
    expect(exec.calls).toHaveLength(0);
  });

  it("cancels at period end on the happy path and reports access_until", async () => {
    const exec = makeExec({ stdout: CANCEL_STDOUT });
    const tool = createCancelSubscriptionTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toEqual({
      ok: true,
      cancelled: true,
      mode: "period_end",
      access_until: "2026-01-01T00:00:00Z",
      workspace_id: "ws-1",
    });
    expect(exec.calls[0].args).toEqual([
      "subscription", "cancel",
      "--email", VERIFIED_EMAIL,
      "--requester", VERIFIED_EMAIL,
      "--reason", "Customer request via support (Caroline)",
      "--yes",
      "--env", "prod", "--json",
    ]);
  });

  it("maps the server's guards to stable reasons", async () => {
    const cases: Array<[string, string, boolean]> = [
      ["Only stripe subscriptions can be cancelled", "not_stripe", true],
      ["VIP subscriptions need manual handling", "vip_manual", true],
      ["Subscription is not active", "no_active_subscription", false],
      ["Subscription not found", "not_found", true],
    ];
    for (const [message, reason, route] of cases) {
      const exec = makeExec({ rejectWith: cliError(message) });
      const tool = createCancelSubscriptionTool(makeDeps({ execFileImpl: exec.impl }));
      const out = await call(tool, { confirm: true });
      expect(out).toMatchObject({ ok: false, reason, route_to_human: route });
    }
  });

  it("fails closed on a response without success:true", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", success: false }) });
    const tool = createCancelSubscriptionTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "cancel_unverified", route_to_human: true });
  });

  it("fails closed when identity cannot be verified, without reaching the CLI", async () => {
    const exec = makeExec({ stdout: CANCEL_STDOUT });
    const tool = createCancelSubscriptionTool(makeDeps({ intercomReader: makeReader(null), execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "owner_undetermined", route_to_human: true });
    expect(exec.calls).toHaveLength(0);
  });
});

describe("mapSubscriptionCliError", () => {
  it("routes the ambiguous-workspace refusal to a human", () => {
    expect(mapSubscriptionCliError(JSON.stringify({ error: { message: "email a@b.test matches 2 workspaces: x, y" } })))
      .toEqual({ reason: "ambiguous_workspace", route_to_human: true });
  });

  it("defaults unknown errors to lookup_unavailable + human", () => {
    expect(mapSubscriptionCliError("garbage")).toEqual({ reason: "lookup_unavailable", route_to_human: true });
  });
});
