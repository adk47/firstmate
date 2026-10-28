import { describe, it, expect, vi } from "vitest";
import { createCarolineActionTools } from "../src/tools/caroline-actions.js";
import { createIntercomReader, type IntercomReader } from "../src/intercom-client.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { HttpClient } from "../src/http.js";

const SESSION_KEY = "agent:support:intercom:direct:215476577497353";
const KEEP = "c3c4d0d9-9f4f-4e69-a4a2-4751ca57d6b2";
const DUP = "cb464ea4-0317-484b-b672-775ba67c4aaa";

function makeHttp(get: HttpClient["get"]): HttpClient {
  return { get, post: vi.fn() as any, put: vi.fn() as any };
}

function reader(email: string | null): IntercomReader {
  return {
    getAuthorEmail: vi.fn(async () => "operations@muso.ai"),
    getCustomerEmail: vi.fn(async () => email),
    getLatestCustomerPart: vi.fn(async () => null),
    findBotMarkerInOtherConversations: vi.fn(async () => "unknown" as const),
  };
}

// execFile fake: records argv, answers per verb.
function fakeExec(answers: Record<string, unknown>) {
  const calls: string[][] = [];
  const fn = (file: string, args: readonly string[], _o: unknown, cb: (e: unknown, out: string, err: string) => void) => {
    calls.push([file, ...args]);
    const verb = args[1];
    cb(null, JSON.stringify(answers[verb] ?? { refusals: ["unexpected"] }), "");
  };
  return { fn, calls };
}

function tools(over: Partial<Parameters<typeof createCarolineActionTools>[0]> = {}) {
  const ex = fakeExec({
    status: { line_id: "status-team-review", reply_line: "Hi Ann, ...", refusals: [] },
    "doc-intake": { filed: 2, reply_line: null, refusals: ["owes_proof"] },
    "merge-intake": { refusals: [], merge_row: 7, next: "file_ticket", reply_line: null },
    "merge-record": { recorded: true, refusals: [] },
    handoff: { refusals: [], outcome: "handed_off", reply_line: null },
  });
  const list = createCarolineActionTools({
    scriptPath: "/opt/hydra/scripts/caroline-actions.py",
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomReader: reader("ann@example.com"),
    intercomToken: "tok",
    enabled: true,
    execFileImpl: ex.fn as any,
    ...over,
  });
  const by = Object.fromEntries(list.map((t) => [t.name, t]));
  return { by, ex };
}

const parse = (r: any) => JSON.parse(r.content[0].text);

describe("caroline actions: dark ship and identity", () => {
  it("every tool is a no-op sentinel while the flag is off (no exec, no Intercom)", async () => {
    const r = reader("ann@example.com");
    const { by, ex } = tools({ enabled: false, intercomReader: r });
    for (const name of ["credit_status_lookup", "document_intake", "merge_request_intake", "credit_trust_handoff"]) {
      const out = parse(await by[name].execute("t", { topic: "credit", subject: "credit", keepProfile: KEEP, otherProfiles: [DUP], summary: "x", reason: "dispute" }));
      expect(out.disabled).toBe(true);
      expect(out.reply_line).toBeNull();
    }
    expect(ex.calls).toHaveLength(0);
    expect(r.getCustomerEmail).not.toHaveBeenCalled();
  });

  it("uses the conversation's CUSTOMER email, never getAuthorEmail (the teammate on our own threads)", async () => {
    const r = reader("ann@example.com");
    const { by, ex } = tools({ intercomReader: r });
    await by.credit_status_lookup.execute("t", { topic: "credit" });
    expect(r.getAuthorEmail).not.toHaveBeenCalled();
    expect(ex.calls[0]).toEqual(["python3", "/opt/hydra/scripts/caroline-actions.py", "status", "--email", "ann@example.com",
      "--conv", "215476577497353", "--topic", "credit"]);
  });

  it("fails closed with no customer email, no token, a reader without getCustomerEmail, or no conversation", async () => {
    for (const over of [
      { intercomReader: reader(null) },
      { intercomToken: "" },
      { intercomReader: { ...reader("a@b.co"), getCustomerEmail: undefined } as IntercomReader },
      { sessionKey: "unknown" },
    ]) {
      const { by, ex } = tools(over as any);
      const out = parse(await by.credit_status_lookup.execute("t", { topic: "credit" }));
      expect(out.error).toBe("identity_unverified");
      expect(out.reply_line).toBeNull();
      expect(ex.calls).toHaveLength(0);
    }
  });

  it("rate limits each tool per session", async () => {
    const { by } = tools();
    for (let i = 0; i < 6; i++) await by.credit_status_lookup.execute("t", { topic: "credit" });
    expect(parse(await by.credit_status_lookup.execute("t", { topic: "credit" })).error).toBe("rate_limited");
  });
});

describe("caroline actions: dispatch", () => {
  it("document_intake files for the subject and passes the refusal through", async () => {
    const { by, ex } = tools();
    const out = parse(await by.document_intake.execute("t", { subject: "claim" }));
    expect(out.reply_line).toBeNull();
    expect(out.refusals).toEqual(["owes_proof"]);
    expect(ex.calls[0].slice(2)).toEqual(["doc-intake", "--email", "ann@example.com", "--conv", "215476577497353", "--subject", "claim"]);
  });

  it("merge_request_intake checks, files the profile-merge ticket, records it, and never executes", async () => {
    const execute = vi.fn(async () => ({ content: [{ type: "text" as const, text: JSON.stringify({ submitted: true, ticket_id: "86x" }) }], details: {} }));
    const { by, ex } = tools({ createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", {
      keepProfile: `https://credits.muso.ai/profile/${KEEP}`, otherProfiles: [`https://muso.ai/profile/${DUP}`], summary: "merge my two" }));
    expect(out).toMatchObject({ ok: true, filed: true, ticket_id: "86x", executed: false, reply_line: null });
    const ticket = (execute.mock.calls[0] as any[])[1];
    expect(ticket.actionType).toBe("profile-merge");
    expect(ticket.details.duplicate_profile_urls).toEqual([`https://credits.muso.ai/profile/${DUP}`]);
    expect(ex.calls.map((c) => c[2])).toEqual(["merge-intake", "merge-record"]);
    expect(ex.calls[1]).toContain("--ticket-id");
    expect(ex.calls.flat().join(" ")).not.toMatch(/consolidate|profiles merge|--apply/);
  });

  it("merge_request_intake refuses non-ids and a refused check files nothing", async () => {
    const execute = vi.fn();
    let { by, ex } = tools({ createTicket: () => ({ execute }) as any });
    expect(parse(await by.merge_request_intake.execute("t", { keepProfile: "Ann Example", otherProfiles: [DUP], summary: "" })).refusals)
      .toEqual(["not_profile_ids"]);
    expect(ex.calls).toHaveLength(0);
    const refusing = fakeExec({ "merge-intake": { refusals: ["already_filed_within_7d"], ticket_id: "86x" } });
    ({ by } = tools({ execFileImpl: refusing.fn as any, createTicket: () => ({ execute }) as any }));
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out.refusals).toEqual(["already_filed_within_7d"]);
    expect(execute).not.toHaveBeenCalled();
  });

  it("ticket filed but the record step fails twice: surfaced as merge_record_failed, never a clean filing", async () => {
    const execute = vi.fn(async () => ({ content: [{ type: "text" as const, text: JSON.stringify({ submitted: true, ticket_id: "86x" }) }], details: {} }));
    const ex = fakeExec({ "merge-intake": { refusals: [], merge_row: 7 }, "merge-record": { recorded: false, refusals: ["unknown_or_closed_row"] } });
    const { by } = tools({ execFileImpl: ex.fn as any, createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out).toMatchObject({ ok: false, filed: true, ticket_id: "86x", refusals: ["merge_record_failed"], reply_line: null });
    expect(ex.calls.filter((c) => c[2] === "merge-record")).toHaveLength(2);   // retried once
    expect(execute).toHaveBeenCalledTimes(1);
  });

  it("a lost record answer is retried and the filing then reads clean", async () => {
    const execute = vi.fn(async () => ({ content: [{ type: "text" as const, text: JSON.stringify({ submitted: true, ticket_id: "86x" }) }], details: {} }));
    let n = 0;
    const fn = (_f: string, args: readonly string[], _o: unknown, cb: (e: unknown, o: string, er: string) => void) => {
      if (args[1] === "merge-intake") return cb(null, JSON.stringify({ refusals: [], merge_row: 7 }), "");
      n += 1;
      return n === 1 ? cb(new Error("timeout"), "", "") : cb(null, JSON.stringify({ recorded: true }), "");
    };
    const { by } = tools({ execFileImpl: fn as any, createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out).toMatchObject({ ok: true, filed: true, ticket_id: "86x", refusals: [] });
  });

  it("after a filed ticket whose record failed, the second call never files again", async () => {
    const execute = vi.fn();
    const ex = fakeExec({ "merge-intake": { refusals: ["merge_in_flight"] } });
    const { by } = tools({ execFileImpl: ex.fn as any, createTicket: () => ({ execute }) as any });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out.refusals).toEqual(["merge_in_flight"]);
    expect(execute).not.toHaveBeenCalled();
  });

  it("a THROWING ticket call answers an explicit unknown outcome + handoff, keeps the row, records nothing", async () => {
    const execute = vi.fn(async () => { throw new Error("ClickUp timeout"); });
    const { by, ex } = tools({ createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out).toMatchObject({ ok: false, filed: "unknown", ticket_id: null, executed: false, merge_row: 7,
      refusals: ["merge_filing_outcome_unknown"], next: "credit_trust_handoff", reply_line: null });
    // No merge-record call: the row stays to_file, which blocks a second filing (never a duplicate ticket).
    expect(ex.calls.map((c) => c[2])).toEqual(["merge-intake"]);
  });

  it("a failed ticket is recorded as failed", async () => {
    const execute = vi.fn(async () => ({ content: [{ type: "text" as const, text: JSON.stringify({ submitted: false, reason: "queue_busy" }) }], details: {} }));
    const { by, ex } = tools({ createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out.refusals).toEqual(["merge_ticket_not_filed"]);
    expect(ex.calls[1]).toContain("--failed");
  });

  it("merge_intake_not_updated (an EXISTING ticket) keeps the hold with that ticket id and never records --failed", async () => {
    const execute = vi.fn(async () => ({ content: [{ type: "text" as const, text: JSON.stringify({ submitted: false,
      reason: "merge_intake_not_updated", action_type: "profile-merge", ticket_id: "cu-123", hint: "x" }) }], details: {} }));
    const { by, ex } = tools({ createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out).toMatchObject({ ok: false, filed: false, ticket_id: "cu-123", executed: false,
      refusals: ["merge_intake_not_updated"], reply_line: null });
    expect(ex.calls[1]).toEqual(expect.arrayContaining(["merge-record", "--ticket-id", "cu-123"]));
    expect(ex.calls.flat()).not.toContain("--failed");
  });

  it("keep_conflict_unflagged (existing ticket_ids) also keeps the hold, on the first existing id", async () => {
    const execute = vi.fn(async () => ({ content: [{ type: "text" as const, text: JSON.stringify({ submitted: false,
      reason: "keep_conflict_unflagged", action_type: "profile-merge", ticket_ids: ["cu-7", "cu-8"], hint: "x" }) }], details: {} }));
    const { by, ex } = tools({ createTicket: () => ({ execute }) });
    const out = parse(await by.merge_request_intake.execute("t", { keepProfile: KEEP, otherProfiles: [DUP], summary: "" }));
    expect(out).toMatchObject({ filed: false, ticket_id: "cu-7", existing_ticket_ids: ["cu-7", "cu-8"], refusals: ["keep_conflict_unflagged"] });
    expect(ex.calls[1]).toEqual(expect.arrayContaining(["--ticket-id", "cu-7"]));
    expect(ex.calls.flat()).not.toContain("--failed");
  });

  it("credit_trust_handoff passes a known reason only", async () => {
    const { by, ex } = tools();
    await by.credit_trust_handoff.execute("t", { reason: "approve_everything", summary: "x" });
    expect(ex.calls[0]).toContain("other");
    expect(ex.calls[0]).not.toContain("approve_everything");
  });

  it("an exec failure or garbage output is never a line", async () => {
    const bad = (_f: string, _a: readonly string[], _o: unknown, cb: any) => cb(new Error("boom"), "", "trace");
    const { by } = tools({ execFileImpl: bad as any });
    expect(parse(await by.credit_status_lookup.execute("t", { topic: "credit" }))).toMatchObject({ error: "actions_exec_failed", reply_line: null });
    const junk = (_f: string, _a: readonly string[], _o: unknown, cb: any) => cb(null, "not json", "");
    const t2 = tools({ execFileImpl: junk as any });
    expect(parse(await t2.by.credit_status_lookup.execute("t", { topic: "credit" }))).toMatchObject({ error: "actions_invalid_output", reply_line: null });
  });
});

describe("intercom-client getCustomerEmail", () => {
  it("answers the source author when it is the contact", async () => {
    const get = vi.fn(async () => ({ ok: true, data: { source: { author: { type: "user", email: "Ann@Example.com" } } } }));
    expect(await createIntercomReader(makeHttp(get as any)).getCustomerEmail!("c", "tok")).toBe("ann@example.com");
    expect(get).toHaveBeenCalledTimes(1);
  });

  it("on a thread our outbound note opened, answers the ONE contact, never the teammate", async () => {
    const get = vi.fn(async (url: string) => url.includes("/contacts/")
      ? { ok: true, data: { role: "user", email: "Ann@Example.com" } }
      : { ok: true, data: { source: { author: { type: "admin", email: "operations@muso.ai" } }, contacts: { contacts: [{ id: "k1" }] } } });
    expect(await createIntercomReader(makeHttp(get as any)).getCustomerEmail!("c", "tok")).toBe("ann@example.com");
    expect((get.mock.calls[1] as any[])[0]).toBe("https://api.intercom.io/contacts/k1");
  });

  it("is null for several contacts, no contact, a non-user role, or an error", async () => {
    const cases = [
      { conv: { source: { author: { type: "admin", email: "operations@muso.ai" } }, contacts: { contacts: [{ id: "a" }, { id: "b" }] } } },
      { conv: { source: { author: { type: "admin", email: "operations@muso.ai" } }, contacts: { contacts: [] } } },
      { conv: { source: { author: { type: "bot" } }, contacts: { contacts: [{ id: "a" }] } }, contact: { role: "admin", email: "x@muso.ai" } },
      { conv: { source: { author: { type: "user" } } } },
    ];
    for (const c of cases) {
      const get = vi.fn(async (url: string) => url.includes("/contacts/") ? { ok: true, data: c.contact ?? {} } : { ok: true, data: c.conv });
      expect(await createIntercomReader(makeHttp(get as any)).getCustomerEmail!("c", "tok")).toBeNull();
    }
    const fail = vi.fn(async () => ({ ok: false, error: "x", status: 500 }));
    expect(await createIntercomReader(makeHttp(fail as any)).getCustomerEmail!("c", "tok")).toBeNull();
  });
});
