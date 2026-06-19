import { describe, it, expect } from "vitest";
import { createOrderAddressUpdateTool } from "../src/tools/order-address-update.js";
import { RateLimiter } from "../src/rate-limiter.js";
import { readFileSync } from "node:fs";

function makeMockExecFile(opts: { stdout?: string; stderr?: string; error?: Error } = {}) {
  const calls: { args: string[]; body?: Record<string, unknown> }[] = [];
  const mock = (
    _file: string,
    args: string[],
    _options: unknown,
    callback: (err: unknown, stdout: string, stderr: string) => void,
  ) => {
    const call: { args: string[]; body?: Record<string, unknown> } = { args };
    const i = args.indexOf("--body-file");
    if (i >= 0 && args[i + 1]) {
      // Read synchronously — the dispatcher deletes the tmpdir after exec resolves.
      try { call.body = JSON.parse(readFileSync(args[i + 1], "utf8")); } catch { /* ignore */ }
    }
    calls.push(call);
    setImmediate(() => callback(opts.error ?? null, opts.stdout ?? "", opts.stderr ?? ""));
    return undefined as unknown;
  };
  return { mock, calls };
}

const VALID_RECIPIENT = {
  name: "Maria Perez",
  phone: "+1 809 555 0100",
  line1: "Av Enriquillo 36",
  line2: "Apt 1101",
  city: "Santo Domingo",
  postcode: "11108",
  country: "DO",
};

function makeTool(opts: Parameters<typeof makeMockExecFile>[0] = {}) {
  const rateLimiter = new RateLimiter();
  const { mock, calls } = makeMockExecFile(opts);
  const tool = createOrderAddressUpdateTool({
    scriptPath: "/test/update-order-address.sh",
    rateLimiter,
    sessionId: "s",
    execFileImpl: mock as never,
  });
  return { tool, calls, rateLimiter };
}

const parse = (r: { content: Array<{ type: string; text?: string }> }) => JSON.parse(r.content[0].text!);
const argFlag = (args: string[], flag: string) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };

describe("createOrderAddressUpdateTool", () => {
  it("fast-refuses apply=true without intercomConvId and does NOT exec", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT, apply: true }));
    expect(out.error).toBe("intercom_conv_id_required");
    expect(calls).toHaveLength(0);
  });

  it("refuses an invalid address (over-length line) before exec", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    const bad = { ...VALID_RECIPIENT, line1: "A".repeat(41) };
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: bad }));
    expect(out.error).toBe("address_invalid");
    expect(out.validation.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("refuses an address missing a required field (no phone) before exec", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    const { phone, ...noPhone } = VALID_RECIPIENT;
    void phone;
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: noPhone as typeof VALID_RECIPIENT }));
    expect(out.error).toBe("address_invalid");
    expect(out.validation.missing).toContain("Phone number");
    expect(calls).toHaveLength(0);
  });

  it("dry-run: execs the wrapper with a Stripe-shape body and no --apply", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true,"mode":"dry-run","applied":false}' });
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "owner@x.com", recipient: VALID_RECIPIENT }));

    expect(out).toEqual({ ok: true, mode: "dry-run", applied: false });
    expect(calls).toHaveLength(1);
    const { args, body } = calls[0];
    expect(argFlag(args, "--order-ref")).toBe("ZGOP1");
    expect(argFlag(args, "--customer-email")).toBe("owner@x.com");
    expect(args).not.toContain("--apply");
    expect(args).not.toContain("--intercom-conv-id");
    // Body is the backend PUT shape: top-level name/phoneNumber + Stripe-shape address.
    expect(body).toEqual({
      name: "Maria Perez",
      phoneNumber: "+1 809 555 0100",
      address: { line1: "Av Enriquillo 36", line2: "Apt 1101", city: "Santo Domingo", postal_code: "11108", country: "DO" },
    });
  });

  it("apply: passes --apply and --intercom-conv-id through", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true,"mode":"apply","applied":true}' });
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "owner@x.com", recipient: VALID_RECIPIENT, apply: true, intercomConvId: "conv123" }));
    expect(out.applied).toBe(true);
    expect(calls[0].args).toContain("--apply");
    expect(argFlag(calls[0].args, "--intercom-conv-id")).toBe("conv123");
  });

  it("maps wrapper empty / non-JSON output to structured errors", async () => {
    expect(parse(await makeTool({ stdout: "" }).tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT })).error).toBe("wrapper_empty_output");
    expect(parse(await makeTool({ stdout: "not json" }).tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT })).error).toBe("wrapper_invalid_output");
  });

  it("rate-limits at 5/min per session", async () => {
    const { tool } = makeTool({ stdout: '{"ok":true}' });
    for (let i = 0; i < 5; i++) await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT });
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT }));
    expect(out.error).toBe("rate_limited");
  });
});
