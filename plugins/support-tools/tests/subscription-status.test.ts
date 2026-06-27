import { describe, it, expect, vi } from "vitest";
import { createSubscriptionStatusTool, type SubscriptionStatusDeps } from "../src/tools/subscription-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { IntercomReader } from "../src/intercom-client.js";

const VERIFIED_EMAIL = "owner@example.com";
const SESSION_KEY = "agent:support:intercom:direct:CONV123";

function makeReader(email: string | null = VERIFIED_EMAIL): IntercomReader {
  return { getAuthorEmail: vi.fn(async () => email) };
}

// A mock execFile that resolves with the given stdout JSON (or rejects with the
// given error). Captures the argv so tests can assert the anti-spoof email is
// the one passed to the CLI.
type ExecImpl = NonNullable<SubscriptionStatusDeps["execFileImpl"]>;
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

function makeDeps(overrides: Partial<SubscriptionStatusDeps> = {}): SubscriptionStatusDeps {
  return {
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomReader: makeReader(),
    intercomToken: "tok",
    execFileImpl: makeExec({ stdout: JSON.stringify({ items: [] }) }).impl,
    ...overrides,
  };
}

async function call(tool: ReturnType<typeof createSubscriptionStatusTool>, params: Record<string, unknown> = {}) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as { type: "text"; text: string }).text);
}

describe("subscription_status", () => {
  it("returns ok:true with the plan/status/period/seats on the happy path", async () => {
    const exec = makeExec({
      stdout: JSON.stringify({
        items: [
          {
            id: "1bbcc4b5-e44a-4664-adeb-7e255c813f8e",
            email: VERIFIED_EMAIL,
            subscription: { plan: "muso_individual_pro_annual", status: "ACTIVE", period: "annual", usersLimit: 1 },
          },
        ],
        total: 1,
      }),
    });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool, { query: "what plan am I on?" });
    expect(out).toEqual({
      ok: true,
      has_subscription: true,
      plan: "muso_individual_pro_annual",
      status: "ACTIVE",
      period: "annual",
      seats_limit: 1,
      workspace_id: "1bbcc4b5-e44a-4664-adeb-7e255c813f8e",
    });
    // Anti-spoof: the CLI is invoked with the VERIFIED email, never a model arg.
    expect(exec.calls).toHaveLength(1);
    expect(exec.calls[0].args).toContain(VERIFIED_EMAIL);
    expect(exec.calls[0].args).toEqual(["teams", "list", "--email", VERIFIED_EMAIL, "--env", "prod", "--json"]);
  });

  it("never echoes member PII — only the subscription + workspace id are returned", async () => {
    const exec = makeExec({
      stdout: JSON.stringify({
        items: [
          {
            id: "ws-1",
            email: VERIFIED_EMAIL,
            name: "Some Workspace Name",
            users: [{ email: "other-member@example.com", fullName: "Other Member" }],
            subscription: { plan: "pro", status: "ACTIVE", period: "monthly", usersLimit: 5 },
          },
        ],
      }),
    });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    const json = JSON.stringify(out);
    expect(json).not.toMatch(/other-member@example\.com|Other Member|Some Workspace Name/);
    expect(out.ok).toBe(true);
    expect(out.workspace_id).toBe("ws-1");
  });

  it("returns has_subscription:false for a workspace on no paid plan (subscription null)", async () => {
    const exec = makeExec({
      stdout: JSON.stringify({ items: [{ id: "ws-free", email: VERIFIED_EMAIL, subscription: null }] }),
    });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out).toEqual({
      ok: true,
      has_subscription: false,
      plan: null,
      status: "none",
      period: null,
      seats_limit: null,
      workspace_id: "ws-free",
    });
  });

  it("re-filters the substring --email match to an EXACT (case-insensitive) email", async () => {
    // `--email` is a substring filter: a foreign workspace can come back whose
    // email merely CONTAINS the verified address. It must be excluded.
    const exec = makeExec({
      stdout: JSON.stringify({
        items: [
          { id: "foreign", email: "x" + VERIFIED_EMAIL, subscription: { plan: "team", status: "ACTIVE" } },
          { id: "mine", email: VERIFIED_EMAIL.toUpperCase(), subscription: { plan: "pro", status: "ACTIVE", period: "monthly", usersLimit: 2 } },
        ],
      }),
    });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(true);
    expect(out.workspace_id).toBe("mine");
    expect(out.plan).toBe("pro");
  });

  it("prefers an active subscription over a stale CANCELLED one", async () => {
    const exec = makeExec({
      stdout: JSON.stringify({
        items: [
          { id: "old", email: VERIFIED_EMAIL, subscription: { plan: "old_pro", status: "CANCELLED", period: "annual", usersLimit: 1 } },
          { id: "new", email: VERIFIED_EMAIL, subscription: { plan: "new_pro", status: "ACTIVE", period: "monthly", usersLimit: 1 } },
        ],
      }),
    });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.workspace_id).toBe("new");
    expect(out.status).toBe("ACTIVE");
  });

  it("returns not_found when no workspace is billed to the verified email", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ items: [] }) });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("not_found");
    expect(out.route_to_human).toBe(true);
  });

  it("fails closed (owner_undetermined) when the session key has no conversation id", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ items: [] }) });
    const tool = createSubscriptionStatusTool(makeDeps({ sessionKey: "agent:support:main", execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("owner_undetermined");
    // never reaches the CLI when identity cannot be established
    expect(exec.calls).toHaveLength(0);
  });

  it("fails closed (owner_undetermined) when the verified contact email is unreadable", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ items: [] }) });
    const tool = createSubscriptionStatusTool(makeDeps({ intercomReader: makeReader(null), execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("owner_undetermined");
    expect(exec.calls).toHaveLength(0);
  });

  it("fails closed (owner_undetermined) when the intercom token is missing", async () => {
    const tool = createSubscriptionStatusTool(makeDeps({ intercomToken: "" }));
    const out = await call(tool);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("owner_undetermined");
  });

  it("returns lookup_unavailable when the muso CLI exec fails", async () => {
    const exec = makeExec({ rejectWith: Object.assign(new Error("spawn ENOENT"), { code: "ENOENT", stderr: "" }) });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("lookup_unavailable");
  });

  it("returns lookup_unavailable when the CLI emits non-JSON", async () => {
    const exec = makeExec({ stdout: "not json at all" });
    const tool = createSubscriptionStatusTool(makeDeps({ execFileImpl: exec.impl }));
    const out = await call(tool);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("lookup_unavailable");
  });

  it("returns rate_limited after the per-session cap is exhausted", async () => {
    const exec = makeExec({ stdout: JSON.stringify({ items: [] }) });
    const deps = makeDeps({ execFileImpl: exec.impl });
    const tool = createSubscriptionStatusTool(deps);
    for (let i = 0; i < 10; i++) await call(tool);
    const out = await call(tool);
    expect(out).toEqual({ ok: false, reason: "rate_limited" });
  });
});
