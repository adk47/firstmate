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

const CONV_KEY = "agent:support:intercom:direct:215476355817432";
const NOW = 1793116800;
const contact = (o: Record<string, unknown> = {}) => ({ email: "a@b.com", role: "user", externalId: "pro-1",
  contactCreatedAt: NOW - 30 * 86400, conversationCreatedAt: NOW - 3600, ...o });
const readerFor = (who: unknown) => ({ getAuthorEmail: async () => null, getLatestCustomerPart: async () => null,
  findBotMarkerInOtherConversations: async () => "unknown", getContactIdentity: async () => who }) as never;

// The existing cases exercise the wrapper path, so they run with the IV gate explicitly OFF and the requester
// anchored as the verified contact a@b.com (the order's owner check stays the wrapper's).
function makeTool(opts: Parameters<typeof makeMockExecFile>[0] = {}, sessionKey: string = CONV_KEY,
                  extra: Record<string, unknown> = {}) {
  const rateLimiter = new RateLimiter();
  const { mock, calls } = makeMockExecFile(opts);
  const tool = createOrderAddressUpdateTool({
    scriptPath: "/test/update-order-address.sh",
    rateLimiter,
    sessionId: "s",
    sessionKey,
    execFileImpl: mock as never,
    orderDetailsRequireIv: false,
    intercomToken: "tok",
    intercomReader: readerFor(contact()),
    nowSeconds: () => NOW,
    ...extra,
  } as never);
  return { tool, calls, rateLimiter };
}

const parse = (r: { content: Array<{ type: string; text?: string }> }) => JSON.parse(r.content[0].text!);
const argFlag = (args: string[], flag: string) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };

describe("createOrderAddressUpdateTool", () => {
  it.each([
    ["main session", "agent:support:main"],
    ["ephemeral UUID", "3f2b8c1e-7a4d-4e0b-9c55-1d2e3f4a5b6c"],
    ["unknown", "unknown"],
  ])("fails closed with conv_id_unavailable (%s) and does NOT exec, dry-run or apply", async (_n, key) => {
    for (const apply of [false, true]) {
      const { tool, calls } = makeTool({ stdout: '{"ok":true}' }, key);
      const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT, apply }));
      expect(out.error).toBe("conv_id_unavailable");
      expect(calls).toHaveLength(0);
    }
  });

  it("derives --intercom-conv-id from the session key on dry-run too", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT });
    expect(argFlag(calls[0].args, "--intercom-conv-id")).toBe("215476355817432");
  });

  it("derives from the legacy {wsId}:conversation:{convId} key shape", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' }, "agent:support:intercom:ws1:conversation:999111");
    await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT, apply: true });
    expect(argFlag(calls[0].args, "--intercom-conv-id")).toBe("999111");
  });

  it("schema no longer accepts intercomConvId, and a model-supplied one never reaches argv", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    expect((tool.parameters as { properties: Record<string, unknown> }).properties).not.toHaveProperty("intercomConvId");
    await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT, apply: true, intercomConvId: "ATTACKER999" } as never);
    expect(calls[0].args).not.toContain("ATTACKER999");
    expect(calls[0].args.filter((a) => a === "--intercom-conv-id")).toHaveLength(1);
    expect(argFlag(calls[0].args, "--intercom-conv-id")).toBe("215476355817432");
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
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT }));

    expect(out).toEqual({ ok: true, mode: "dry-run", applied: false });
    expect(calls).toHaveLength(1);
    const { args, body } = calls[0];
    expect(argFlag(args, "--order-ref")).toBe("ZGOP1");
    expect(argFlag(args, "--customer-email")).toBe("a@b.com");
    expect(args).not.toContain("--apply");
    // Body is the backend PUT shape: top-level name/phoneNumber + Stripe-shape address.
    expect(body).toEqual({
      name: "Maria Perez",
      phoneNumber: "+1 809 555 0100",
      address: { line1: "Av Enriquillo 36", line2: "Apt 1101", city: "Santo Domingo", postal_code: "11108", country: "DO" },
    });
  });

  it("forwards a normalized taxId/taxIdType in the body when tax_id is supplied", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true,"mode":"dry-run","applied":false}' });
    const mx = { ...VALID_RECIPIENT, country: "MX", tax_id: " gode-561231.gr8 " };
    await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: mx });
    const { body } = calls[0];
    // taxId is normalized (upper, stripped) and type inferred; address/name preserved.
    expect(body!.taxId).toBe("GODE561231GR8");
    expect(body!.taxIdType).toBe("rfc");
    expect(body!.name).toBe("Maria Perez");
    expect((body!.address as Record<string, unknown>).country).toBe("MX");
  });

  it("omits taxId from the body entirely when tax_id is not supplied", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT });
    expect(calls[0].body).not.toHaveProperty("taxId");
    expect(calls[0].body).not.toHaveProperty("taxIdType");
  });

  it("validates the tax id against the DESTINATION country, not Mexico's shapes", async () => {
    // Before the rules were country-scoped this was rejected as tax_id_invalid: an
    // 11-digit CPF is neither a 12–13-char RFC nor an 18-char CURP, so a held
    // Brazilian order could not be released by Caroline at all — even though
    // core-backend accepts it and would release the hold on save.
    const { tool, calls } = makeTool({ stdout: '{"ok":true,"mode":"dry-run","applied":false}' });
    const br = { ...VALID_RECIPIENT, country: "BR", tax_id: "111.444.777-35" };
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: br }));
    expect(out.ok).toBe(true);
    expect(calls[0].body!.taxId).toBe("11144477735");
    expect(calls[0].body!.taxIdType).toBe("cpf");
  });

  it("refuses an id valid for another country, before exec", async () => {
    // A Mexican RFC on a Brazilian order. The backend 400s on this; catching it here
    // gives Caroline the local id name instead of a generic failure one layer later.
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    const mixed = { ...VALID_RECIPIENT, country: "BR", tax_id: "GODE561231GR8" };
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: mixed }));
    expect(out.error).toBe("tax_id_invalid");
    expect(out.detail).toMatch(/CPF or CNPJ/);
    expect(calls).toHaveLength(0);
  });

  it("refuses a tax id for a destination with no customs requirement", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    const us = { ...VALID_RECIPIENT, country: "US", tax_id: "123456789" };
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: us }));
    expect(out.error).toBe("tax_id_invalid");
    expect(calls).toHaveLength(0);
  });

  it("refuses a malformed tax_id before exec", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true}' });
    const bad = { ...VALID_RECIPIENT, country: "MX", tax_id: "123" };
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: bad }));
    expect(out.error).toBe("tax_id_invalid");
    expect(calls).toHaveLength(0);
  });

  it("apply: passes --apply and --intercom-conv-id through", async () => {
    const { tool, calls } = makeTool({ stdout: '{"ok":true,"mode":"apply","applied":true}' });
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: "a@b.com", recipient: VALID_RECIPIENT, apply: true }));
    expect(out.applied).toBe(true);
    expect(calls[0].args).toContain("--apply");
    expect(argFlag(calls[0].args, "--intercom-conv-id")).toBe("215476355817432");
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

// s1 guardrails-1101 gap 6 (red-team EX-1, 3/3): the wrapper's dry run returns the order's CURRENT address, so an
// unverified or non-owning contact must be refused BEFORE the wrapper runs: a refusal code, no address field.
describe("order_address_update owner gate (s1 gap 6)", () => {
  const PII = ["Av Enriquillo", "Santo Domingo", "11108", "+1 809 555 0100", "current_address"];
  const call = async (extra: Record<string, unknown>, email = "a@b.com", apply = false) => {
    const { tool, calls } = makeTool({ stdout: JSON.stringify({ ok: true, mode: "dry-run", current_address: { line1: "Av Enriquillo 36" } }) },
      CONV_KEY, extra);
    const out = parse(await tool.execute("c", { order_ref: "ZGOP1", customer_email: email, recipient: VALID_RECIPIENT, apply }));
    return { out, calls };
  };
  const refused = (out: any, calls: unknown[], error: string, check: string) => {
    expect(out).toMatchObject({ ok: false, error, owner_check: check });
    expect(calls).toHaveLength(0);
    for (const p of PII) expect(JSON.stringify(out), p).not.toContain(p);
  };

  it("default (IV gate on, flag absent or true): every caller is refused, preview and apply, with no exec", async () => {
    for (const flag of [undefined, true]) {
      for (const apply of [false, true]) {
        const { out, calls } = await call({ orderDetailsRequireIv: flag }, "a@b.com", apply);
        refused(out, calls, "owner_undetermined", "identity_verification_off");
      }
    }
  });

  it("red-team case 1: an identified contact names a FOREIGN customer's email (gate off) -> owner_mismatch, no exec", async () => {
    const { out, calls } = await call({}, "victim@example.com");
    refused(out, calls, "owner_mismatch", "customer_email_is_not_the_verified_contact");
  });

  it("red-team case 2: a lead / no external_id / fresh contact asks for the preview (gate off) -> refused, no exec", async () => {
    for (const [who, check] of [[contact({ role: "lead" }), "contact_not_user"],
                                [contact({ externalId: null }), "contact_no_external_id"],
                                [contact({ contactCreatedAt: NOW - 600 }), "contact_too_new"]] as const) {
      const { out, calls } = await call({ intercomReader: readerFor(who) });
      refused(out, calls, "owner_undetermined", check);
    }
  });

  it("red-team case 3: no readable contact or no token (gate off) -> refused, no exec", async () => {
    for (const extra of [{ intercomReader: readerFor(null) }, { intercomToken: "" }]) {
      const { out, calls } = await call(extra);
      expect(out.ok).toBe(false);
      expect(calls).toHaveLength(0);
    }
  });

  it("the verified owner (gate explicitly off) reaches the wrapper, which re-checks the order's owner", async () => {
    const { out, calls } = await call({});
    expect(out.ok).toBe(true);
    expect(calls).toHaveLength(1);
  });
});
