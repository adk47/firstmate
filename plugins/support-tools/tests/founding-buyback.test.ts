import { describe, it, expect, vi } from "vitest";
import {
  createFoundingStatusTool,
  createFoundingBuybackTool,
  mapFoundingCliError,
  type FoundingDeps,
} from "../src/tools/founding-buyback.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { IntercomReader } from "../src/intercom-client.js";

const VERIFIED_EMAIL = "owner@example.com";
const SESSION_KEY = "agent:support:intercom:direct:CONV123";

function makeReader(email: string | null = VERIFIED_EMAIL): IntercomReader {
  return { getAuthorEmail: vi.fn(async () => email) };
}

type ExecImpl = NonNullable<FoundingDeps["execFileImpl"]>;
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

function makeDeps(overrides: Partial<FoundingDeps> = {}): FoundingDeps {
  return {
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomReader: makeReader(),
    intercomToken: "tok",
    buybackEnabled: true,
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

const CHECKOUT_STDOUT = JSON.stringify({
  teamId: "ws-1",
  url: "https://checkout.stripe.com/c/pay/cs_x",
  sessionId: "cs_x",
  arrearsMonths: 3,
  arrearsCents: 2997,
  sinceYear: 2026,
  seats: 1,
  note: "…",
});

describe("founding_status", () => {
  it("maps the lapsed-founder envelope on the happy path", async () => {
    const exec = makeExec({
      stdout: JSON.stringify({
        teamId: "ws-1",
        name: "WS",
        email: VERIFIED_EMAIL,
        founder: { active: false, sinceYear: 2026, lapsedAt: "2026-05-01T00:00:00.000Z" },
        subscription: { plan: "pro_annual", status: "CANCELLED", period: "yearly" },
      }),
    });
    const tool = createFoundingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { query: "am I still a founding member?" });
    expect(out).toEqual({
      ok: true,
      founder_active: false,
      ever_founder: true,
      since_year: 2026,
      lapsed_at: "2026-05-01T00:00:00.000Z",
      workspace_id: "ws-1",
      plan: "pro_annual",
      sub_status: "CANCELLED",
    });
    // Anti-spoof: the CLI gets the VERIFIED email, never a model arg.
    expect(exec.calls[0].args).toEqual(["founding", "status", "--email", VERIFIED_EMAIL, "--env", "prod", "--json"]);
  });

  it("answers ever_founder:false for a never-founder workspace (founder null)", async () => {
    const exec = makeExec({
      stdout: JSON.stringify({ teamId: "ws-1", founder: null, subscription: { plan: "lite", status: "ACTIVE" } }),
    });
    const tool = createFoundingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(true);
    expect(out.ever_founder).toBe(false);
    expect(out.founder_active).toBe(false);
  });

  it("fails closed when identity cannot be verified, without reaching the CLI", async () => {
    const exec = makeExec({ stdout: "{}" });
    const tool = createFoundingStatusTool(makeDeps({ intercomReader: makeReader(null), execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "owner_undetermined", route_to_human: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("maps a CLI not-found to not_found", async () => {
    const exec = makeExec({ rejectWith: cliError(`no workspace with email ${VERIFIED_EMAIL}`) });
    const tool = createFoundingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "not_found", route_to_human: true });
  });

  it("fails closed on non-object CLI stdout (literal null)", async () => {
    const exec = makeExec({ stdout: "null" });
    const tool = createFoundingStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });
});

describe("founding_buyback_link", () => {
  it("mints the link and relays the arrears calculation on the happy path", async () => {
    const exec = makeExec({ stdout: CHECKOUT_STDOUT });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toEqual({
      ok: true,
      url: "https://checkout.stripe.com/c/pay/cs_x",
      workspace_id: "ws-1",
      arrears_months: 3,
      arrears_cents: 2997,
      since_year: 2026,
      seats: 1,
      expires_note: "the link lives ~24h; paying it reinstates founding status automatically",
    });
    // Anti-spoof + attribution: verified email as both selector and requester.
    expect(exec.calls[0].args).toEqual([
      "founding", "buyback-checkout",
      "--email", VERIFIED_EMAIL,
      "--requester", VERIFIED_EMAIL,
      "--env", "prod", "--json",
    ]);
  });

  it("refuses without the explicit confirm flag", async () => {
    const exec = makeExec({ stdout: CHECKOUT_STDOUT });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, {});
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("not_confirmed");
    expect(exec.calls).toHaveLength(0);
  });

  it("maps the already-active-founder 400 to already_founder (no human needed)", async () => {
    const exec = makeExec({ rejectWith: cliError("Team is already an active founder (HTTP 400)") });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "already_founder", route_to_human: false });
  });

  it("maps an ambiguous workspace email to a human route", async () => {
    const exec = makeExec({ rejectWith: cliError(`email ${VERIFIED_EMAIL} matches 2 workspaces: a, b`) });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "ambiguous_workspace", route_to_human: true });
  });

  it("refuses a response without a checkout url rather than relaying garbage", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", url: "javascript:alert(1)" }) });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  it("refuses an https url that is not the Stripe Checkout origin", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", url: "https://evil.example/pay", arrearsMonths: 3, arrearsCents: 2997 }) });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  it("refuses a link whose arrears figures are missing (never invite estimation)", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", url: "https://checkout.stripe.com/c/pay/cs_x" }) });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  // Regression: Number(null) === 0 (finite), so a coerce-then-isFinite guard
  // would wave a null arrears through as a $0.00 back-pay next to a live link.
  it("refuses null/non-number arrears figures (never quote $0.00 next to a live link)", async () => {
    for (const bad of [
      { arrearsMonths: null, arrearsCents: null },
      { arrearsMonths: 3, arrearsCents: null },
      { arrearsMonths: "3", arrearsCents: "2997" },
    ]) {
      const exec = makeExec({ stdout: JSON.stringify({ teamId: "ws-1", url: "https://checkout.stripe.com/c/pay/cs_x", ...bad }) });
      const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
      const out = await call(tool, { confirm: true });
      expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
    }
  });

  it("fails closed on non-object CLI stdout (literal null)", async () => {
    const exec = makeExec({ stdout: "null" });
    const tool = createFoundingBuybackTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "lookup_unavailable", route_to_human: true });
  });

  it("returns the disabled sentinel (not a mint) when the dark-ship flag is off", async () => {
    const exec = makeExec({ stdout: CHECKOUT_STDOUT });
    const tool = createFoundingBuybackTool(makeDeps({ buybackEnabled: false, execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, disabled: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("fails closed when identity cannot be verified, without reaching the CLI", async () => {
    const exec = makeExec({ stdout: CHECKOUT_STDOUT });
    const tool = createFoundingBuybackTool(makeDeps({ sessionKey: "agent:support:main", execFileImpl: exec.impl }));
    const out = await call(tool, { confirm: true });
    expect(out).toMatchObject({ ok: false, reason: "owner_undetermined" });
    expect(exec.calls).toHaveLength(0);
  });

  it("rate-limits after 3 mints per session", async () => {
    const exec = makeExec({ stdout: CHECKOUT_STDOUT });
    const deps = makeDeps({ execFileImpl: exec.impl });
    const tool = createFoundingBuybackTool(deps);
    for (let i = 0; i < 3; i++) {
      const out = await call(tool, { confirm: true });
      expect(out.ok).toBe(true);
    }
    const out = await call(tool, { confirm: true });
    expect(out).toEqual({ ok: false, reason: "rate_limited" });
  });
});

describe("mapFoundingCliError", () => {
  it.each([
    ["Team is already an active founder", "already_founder", false],
    ["No owner user found for workspace", "no_owner", true],
    ["Team not found", "not_found", true],
    ["email a@b matches 3 workspaces: x, y, z", "ambiguous_workspace", true],
    ["something exploded", "lookup_unavailable", true],
  ])("%s -> %s", (message, reason, route) => {
    const stderr = JSON.stringify({ error: { code: "error", message } });
    expect(mapFoundingCliError(stderr)).toEqual({ reason, route_to_human: route });
  });

  it("handles empty / non-envelope stderr", () => {
    expect(mapFoundingCliError("")).toEqual({ reason: "lookup_unavailable", route_to_human: true });
    expect(mapFoundingCliError("plain text panic")).toEqual({ reason: "lookup_unavailable", route_to_human: true });
  });
});
