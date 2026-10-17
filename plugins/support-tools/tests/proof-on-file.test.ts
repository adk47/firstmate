import { describe, it, expect, beforeEach, vi } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { indexProofDoc, checkProofOnFile, resetProofOnFileCacheForTest } from "../src/tools/proof-on-file.js";
import {
  createCreditVerificationCheckTool,
  PROOF_ASK_MARKER,
  PRE_MARKER_ASK_PHRASE,
  PRE_MARKER_WINDOW_END_MS,
  priorAskMarkers,
} from "../src/tools/credit-verification-check.js";
import { createIntercomReader } from "../src/intercom-client.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";

// Step 2's ask gate (firstmate 761): on_file = never ask, none = ask ONCE, unknown = do NOT ask.
// Every part of credit-trust's merged export (core + cs-intercom + cs-gmail) must be present and
// fresh: the shared contract with scripts/credit_review/proof_parts.py (fixture-tested below).
// An unanswered ask is caught across conversations by the ask's marker sentence (asked_before).

const NOW = Date.parse("2026-10-17T18:00:00Z");
const iso = (msAgo: number) => new Date(NOW - msAgo).toISOString();
const H = 60 * 60 * 1000;

function doc(over: Record<string, unknown> = {}) {
  return {
    generated_at: iso(10 * 60 * 1000),
    sources: [
      { name: "core", generated_at: iso(10 * 60 * 1000), count: 1 },
      { name: "cs-intercom", generated_at: iso(H), stale: false, count: 2 },
      { name: "cs-gmail", generated_at: iso(H), stale: false, count: 0 },
    ],
    users: 2,
    entries: [
      { user_id: 111, request_id: null, kind: "pending_doc", source: "intercom", ref: "x" },
      { user_id: 222, request_id: "req-a", kind: "approved_doc", source: "core", ref: "y" },
    ],
    ...over,
  };
}

function fileWith(content: unknown): string {
  const dir = mkdtempSync(join(tmpdir(), "pof-"));
  const p = join(dir, "proof-on-file.json");
  writeFileSync(p, typeof content === "string" ? content : JSON.stringify(content));
  return p;
}

beforeEach(() => resetProofOnFileCacheForTest());

// ---- the shared contract (same fixture file as scripts/tests/test_proof_parts_contract.py) ----

interface ContractCase {
  name: string;
  sources: Array<Record<string, unknown>>;
  gmail_contacts_90d?: { generated_at_age_h: number; source: string; user_ids: unknown[] };
  entries?: unknown[];
  users?: unknown;
  expect: "ok" | "unknown";
}
const CONTRACT: { cases: ContractCase[] } = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../../../scripts/tests/fixtures/proof-parts-contract.json"), "utf8"),
);

function contractDoc(c: ContractCase): Record<string, unknown> {
  const sources = c.sources.map((src) => {
    const { age_h, ...rest } = src as { age_h?: number } & Record<string, unknown>;
    return typeof age_h === "number" && rest.generated_at === undefined ? { ...rest, generated_at: iso(age_h * H) } : rest;
  });
  const out: Record<string, unknown> = { generated_at: iso(0.1 * H), sources, entries: c.entries ?? [] };
  const users = c.users === undefined ? 0 : c.users;
  if (users !== null) out.users = users;
  if (c.gmail_contacts_90d) {
    const { generated_at_age_h, ...rest } = c.gmail_contacts_90d;
    out.gmail_contacts_90d = { ...rest, generated_at: iso(generated_at_age_h * H) };
  }
  return out;
}

describe("proof-on-file completeness contract (shared with proof_parts.py)", () => {
  it("has cases", () => expect(CONTRACT.cases.length).toBeGreaterThan(10));
  for (const c of CONTRACT.cases) {
    it(c.name, () => {
      expect(indexProofDoc(contractDoc(c), NOW).ok).toBe(c.expect === "ok");
    });
  }
});

describe("indexProofDoc: every part must be present and fresh", () => {
  it("accepts a fresh document with every part (core needs no stale flag when its own stamp is fresh)", () => {
    expect(indexProofDoc(doc(), NOW).ok).toBe(true);
  });
  it("is unknown when the whole export is older than 3h, or stamped in the future", () => {
    expect(indexProofDoc(doc({ generated_at: iso(4 * H) }), NOW)).toMatchObject({ ok: false });
    expect(indexProofDoc(doc({ generated_at: iso(-10 * 60 * 1000) }), NOW)).toMatchObject({ ok: false });
  });
  it("is unknown when a part is missing, marked stale, or carries no fresh stamp", () => {
    const d = doc();
    expect(indexProofDoc({ ...d, sources: [d.sources[0], d.sources[2]] }, NOW)).toMatchObject({ ok: false, reason: expect.stringContaining("cs-intercom") });
    expect(indexProofDoc({ ...d, sources: [d.sources[1], d.sources[2]] }, NOW)).toMatchObject({ ok: false, reason: expect.stringContaining("core") });
    expect(indexProofDoc({ ...d, sources: [d.sources[0], d.sources[1]] }, NOW)).toMatchObject({ ok: false, reason: expect.stringContaining("cs-gmail") });
    expect(indexProofDoc({ ...d, sources: [{ ...d.sources[0], stale: true }, d.sources[1], d.sources[2]] }, NOW)).toMatchObject({ ok: false });
    expect(indexProofDoc({ ...d, sources: [{ name: "core", generated_at: iso(5 * H) }, d.sources[1], d.sources[2]] }, NOW)).toMatchObject({ ok: false });
  });
  it("is unknown for a naive (timezone-less) stamp", () => {
    expect(indexProofDoc(doc({ generated_at: "2026-10-17T17:50:00" }), NOW)).toMatchObject({ ok: false });
  });
});

describe("checkProofOnFile", () => {
  it("on_file by request id, and by any entry for the submitting user", () => {
    const p = fileWith(doc());
    expect(checkProofOnFile(p, ["999"], ["req-a"], NOW).state).toBe("on_file");
    expect(checkProofOnFile(p, ["111"], ["req-z"], NOW).state).toBe("on_file");
    expect(checkProofOnFile(p, ["222"], ["req-z"], NOW).state).toBe("on_file");
  });
  it("none only when every part is fresh and nothing lists this customer", () => {
    expect(checkProofOnFile(fileWith(doc()), ["34135"], ["req-z"], NOW)).toMatchObject({ state: "none" });
  });
  it("unknown (never none) when users says another customer's entries were not written", () => {
    expect(checkProofOnFile(fileWith(doc({ users: 3 })), ["34135"], ["req-z"], NOW).state).toBe("unknown");
    const halfRow = doc({ entries: [{ user_id: null, request_id: null, kind: "pending_doc" }, ...doc().entries] });
    expect(checkProofOnFile(fileWith(halfRow), ["34135"], ["req-z"], NOW).state).toBe("unknown");
  });
  it("unknown (never none) when the file is missing, malformed, stale, or the submitter is unknown", () => {
    expect(checkProofOnFile("/nonexistent/proof.json", ["34135"], [], NOW).state).toBe("unknown");
    expect(checkProofOnFile(fileWith("{not json"), ["34135"], [], NOW).state).toBe("unknown");
    expect(checkProofOnFile(fileWith(doc({ generated_at: iso(4 * H) })), ["34135"], [], NOW).state).toBe("unknown");
    expect(checkProofOnFile(fileWith(doc()), [], ["req-z"], NOW).state).toBe("unknown");
  });
  it("re-checks freshness on every call even when the file is unchanged (only the parse is cached)", () => {
    const p = fileWith(doc());
    expect(checkProofOnFile(p, ["34135"], [], NOW).state).toBe("none");
    expect(checkProofOnFile(p, ["34135"], [], NOW + 4 * H).state).toBe("unknown");
  });
});

// ---- through the tool ---------------------------------------------------------

const OWNED = { ok: true, status: 200, data: { data: { id: "p1", isClaimed: true, workspaces: [{ email: "owner@example.com", isClaimed: true }] } } } as AdminClientResult<unknown>;
function admin(items: unknown[]): MusoAdminClient {
  return {
    get: vi.fn(async (path: string) =>
      path.includes("/credit-requests") ? ({ ok: true, status: 200, data: { data: { items } } } as AdminClientResult<unknown>) : OWNED) as MusoAdminClient["get"],
  };
}
type PriorAsk = "found" | "not_found" | "unknown";
function reader(prior: PriorAsk = "not_found") {
  return {
    getAuthorEmail: vi.fn(async () => "owner@example.com"),
    findBotMarkerInOtherConversations: vi.fn(async (_p: Record<string, unknown>) => prior),
  };
}
function tool(
  items: unknown[],
  proofOnFilePath: string,
  opts: { reader?: ReturnType<typeof reader>; botAdminId?: string; now?: number } = {},
) {
  return createCreditVerificationCheckTool({
    adminClient: admin(items),
    intercomReader: opts.reader ?? reader(),
    rateLimiter: new RateLimiter(),
    sessionKey: "agent:support:intercom:direct:c1",
    intercomToken: "tok",
    enabled: true,
    proofOnFilePath,
    now: () => opts.now ?? NOW,
    botAdminId: "botadmin",
    ...(opts.botAdminId !== undefined ? { botAdminId: opts.botAdminId } : {}),
  } as any);
}
const run = async (t: ReturnType<typeof createCreditVerificationCheckTool>) =>
  JSON.parse(((await t.execute("id", { profileId: "p1" } as any)).content[0] as any).text);
const item = (id: string, userId: number) => ({ id, userId, spotifyTrackTitle: "Champagne", spotifyTrackArtists: [{ name: "Remi Wolf" }], credits: ["Co-Writer"] });

describe("credit_verification_check: proof_on_file drives the Step 2 ask", () => {
  it("none: a returning customer with NO proof on file may be asked once (the 2026-10-17 'nothing needed' case)", async () => {
    const out = await run(tool([item("req-z", 34135)], fileWith(doc())));
    expect(out.proof_on_file.state).toBe("none");
    expect(out.notes.join(" ")).toMatch(/ask for proof ONCE/);
  });
  it("on_file: never ask", async () => {
    const out = await run(tool([item("req-z", 111)], fileWith(doc())));
    expect(out.proof_on_file.state).toBe("on_file");
    expect(out.notes.join(" ")).toMatch(/never ask for proof again/);
  });
  it("unknown: do not ask and do not say nothing is needed", async () => {
    const out = await run(tool([item("req-z", 34135)], "/nonexistent/proof.json"));
    expect(out.proof_on_file.state).toBe("unknown");
    expect(out.notes.join(" ")).toMatch(/do NOT ask for proof, and do NOT tell the customer nothing is needed/);
  });
  it("is not assessed (null) when there are no needs-proof credits", async () => {
    const out = await run(tool([], fileWith(doc())));
    expect(out.proof_on_file).toBeNull();
  });
});

describe("credit_verification_check: none = ask ONCE across conversations", () => {
  it("looks for the bot's marker in the contact's other conversations of the last 60 days, at most 10", async () => {
    const r = reader("not_found");
    const out = await run(tool([item("req-z", 34135)], fileWith(doc()), { reader: r }));
    expect(out.proof_on_file.state).toBe("none");
    expect(r.findBotMarkerInOtherConversations).toHaveBeenCalledWith({
      conversationId: "c1",
      token: "tok",
      botAdminId: "botadmin",
      markers: [PROOF_ASK_MARKER, PRE_MARKER_ASK_PHRASE, "Champagne"],
      sinceUnix: Math.floor((NOW - 60 * 24 * H) / 1000),
      limit: 10,
    });
  });
  it("after the pre-marker window ends, only the marker sentence is looked for", async () => {
    const later = PRE_MARKER_WINDOW_END_MS + H;
    const shifted = JSON.parse(JSON.stringify(doc()), (k, v) =>
      k === "generated_at" && typeof v === "string" ? new Date(Date.parse(v) + (later - NOW)).toISOString() : v,
    );
    const r = reader("not_found");
    const out = await run(tool([item("req-z", 34135)], fileWith(shifted), { reader: r, now: later }));
    expect(out.proof_on_file.state).toBe("none");
    expect((r.findBotMarkerInOtherConversations.mock.calls[0][0] as { markers: string[] }).markers).toEqual([PROOF_ASK_MARKER]);
  });
  it("asked_before: an earlier ask in another conversation blocks a second one", async () => {
    const out = await run(tool([item("req-z", 34135)], fileWith(doc()), { reader: reader("found") }));
    expect(out.proof_on_file.state).toBe("asked_before");
    expect(out.notes.join(" ")).toMatch(/do NOT ask again; file a needs-human credit-verify ticket/);
  });
  it("unknown when the earlier-ask lookup fails or is truncated", async () => {
    const out = await run(tool([item("req-z", 34135)], fileWith(doc()), { reader: reader("unknown") }));
    expect(out.proof_on_file.state).toBe("unknown");
    expect(out.notes.join(" ")).toMatch(/do NOT ask for proof/);
  });
  it("unknown when the bot admin id is not configured (the lookup cannot run)", async () => {
    const r = reader("not_found");
    const out = await run(tool([item("req-z", 34135)], fileWith(doc()), { reader: r, botAdminId: "" }));
    expect(out.proof_on_file.state).toBe("unknown");
    expect(r.findBotMarkerInOtherConversations).not.toHaveBeenCalled();
  });
  it("on_file wins without any lookup", async () => {
    const r = reader("found");
    const out = await run(tool([item("req-z", 111)], fileWith(doc()), { reader: r }));
    expect(out.proof_on_file.state).toBe("on_file");
    expect(r.findBotMarkerInOtherConversations).not.toHaveBeenCalled();
  });
});

// ---- the Intercom read behind asked_before ----------------------------------

describe("IntercomReader.findBotMarkerInOtherConversations", () => {
  const MARK = PROOF_ASK_MARKER;
  const conv = (parts: unknown[], extra: Record<string, unknown> = {}) => ({
    contacts: { contacts: [{ id: "contact-1" }] },
    source: { author: { type: "user", id: "contact-1" }, body: "hi" },
    conversation_parts: { conversation_parts: parts, total_count: parts.length },
    ...extra,
  });
  const botAsk = { part_type: "comment", author: { type: "admin", id: "botadmin" }, body: `Your pending credits: X.\n\nAny one of these works   (a screenshot is fine):\n- link` };
  function http(opts: { search?: unknown; searchOk?: boolean; convs?: Record<string, unknown> }) {
    const get = vi.fn(async (url: string) => {
      const id = decodeURIComponent(url.split("/conversations/")[1].split("?")[0]);
      const c = opts.convs?.[id];
      return c === undefined ? { ok: false as const, error: "API error", status: 404 } : { ok: true as const, data: c };
    });
    const post = vi.fn(async () =>
      opts.searchOk === false ? { ok: false as const, error: "API error", status: 500 } : { ok: true as const, data: opts.search });
    return { get, post, put: vi.fn() } as any;
  }
  const params = { conversationId: "c1", token: "tok", botAdminId: "botadmin", markers: [MARK], sinceUnix: 1_700_000_000, limit: 10 };
  const page = (ids: string[], total = ids.length) => ({ conversations: ids.map((id) => ({ id })), total_count: total });

  it("found: the bot posted the marker in another conversation; the search is scoped to this contact, other ids, the window and the cap", async () => {
    const h = http({ search: page(["c2", "c3"]), convs: { c1: conv([]), c2: conv([]), c3: conv([botAsk]) } });
    expect(await createIntercomReader(h).findBotMarkerInOtherConversations(params)).toBe("found");
    const [url, req] = h.post.mock.calls[0] as [string, { body: any }];
    expect(url).toMatch(/\/conversations\/search$/);
    expect(req.body).toEqual({
      query: {
        operator: "AND",
        value: [
          { field: "contact_ids", operator: "=", value: "contact-1" },
          { field: "id", operator: "!=", value: "c1" },
          { field: "updated_at", operator: ">", value: 1_700_000_000 },
        ],
      },
      pagination: { per_page: 10 },
    });
  });
  it("not_found: the marker from a human admin, from the customer, or in a note does not count", async () => {
    const human = { ...botAsk, author: { type: "admin", id: "jan" } };
    const customer = { ...botAsk, author: { type: "user", id: "contact-1" } };
    const note = { ...botAsk, part_type: "note" };
    const h = http({ search: page(["c2"]), convs: { c1: conv([]), c2: conv([human, customer, note, { ...botAsk, body: "Thanks!" }]) } });
    expect(await createIntercomReader(h).findBotMarkerInOtherConversations(params)).toBe("not_found");
  });
  it("not_found when the contact has no other recent conversations", async () => {
    const h = http({ search: page([]), convs: { c1: conv([]) } });
    expect(await createIntercomReader(h).findBotMarkerInOtherConversations(params)).toBe("not_found");
  });
  it.each([
    ["the search fails", { searchOk: false, convs: { c1: conv([]) } }],
    ["more conversations than the cap (truncated)", { search: page(["c2"], 11), convs: { c1: conv([]), c2: conv([]) } }],
    ["a conversation cannot be read", { search: page(["c2"]), convs: { c1: conv([]) } }],
    ["a conversation's part list is truncated", { search: page(["c2"]), convs: { c1: conv([]), c2: conv([], { conversation_parts: { conversation_parts: [], total_count: 600 } }) } }],
    // Intercom returns at most 500 parts and total_count counts only those: an older ask may be cut off.
    ["a conversation's part list hits Intercom's 500-part cap", { search: page(["c2"]), convs: { c1: conv([]), c2: conv(Array(500).fill({ ...botAsk, body: "Thanks!" })) } }],
    ["the current conversation has no single contact", { search: page([]), convs: { c1: conv([], { contacts: { contacts: [] } }) } }],
    ["the search returns no total_count", { search: { conversations: [] }, convs: { c1: conv([]) } }],
  ])("unknown when %s", async (_label, o) => {
    expect(await createIntercomReader(http(o as any)).findBotMarkerInOtherConversations(params)).toBe("unknown");
  });
});

// ---- asks sent before the marker existed (firstmate 039) ----------------------

describe("pre-marker asks count as asked_before until the window ends", () => {
  const conv = (parts: unknown[]) => ({
    contacts: { contacts: [{ id: "contact-1" }] },
    source: { author: { type: "user", id: "contact-1" }, body: "hi" },
    conversation_parts: { conversation_parts: parts, total_count: parts.length },
  });
  const bot = { type: "admin", id: "botadmin" };
  const comment = (author: unknown, body: string) => ({ part_type: "comment", author, body });
  const titleAsk = "I can see these pending credits: <b>CHAMPAGNE</b>   (Co-Writer). Could you send something that shows your work on it?";
  const phraseAsk = "Please send a link or a file. Screenshots are   accepted for all of these.";
  const markerAsk = `Pending: X.\n${PROOF_ASK_MARKER}\n- link`;
  const credits = [
    { cr_id: "req-z", role: "Co-Writer", track_title: "Champagne", artist: "Remi Wolf", isrc: null },
    { cr_id: "req-y", role: "Producer", track_title: "Yo", artist: "Remi Wolf", isrc: null },
  ];
  function http(opts: { parts?: unknown[]; searchOk?: boolean }) {
    const convs: Record<string, unknown> = { c1: conv([]), c2: conv(opts.parts ?? []) };
    const get = vi.fn(async (url: string) => {
      const id = decodeURIComponent(url.split("/conversations/")[1].split("?")[0]);
      return convs[id] === undefined ? { ok: false as const, error: "API error", status: 404 } : { ok: true as const, data: convs[id] };
    });
    const post = vi.fn(async () =>
      opts.searchOk === false
        ? { ok: false as const, error: "API error", status: 500 }
        : { ok: true as const, data: { conversations: [{ id: "c2" }], total_count: 1 } });
    return { get, post, put: vi.fn() } as any;
  }
  const lookup = (parts: unknown[], now: number, extra: { searchOk?: boolean } = {}) =>
    createIntercomReader(http({ parts, ...extra })).findBotMarkerInOtherConversations({
      conversationId: "c1",
      token: "tok",
      botAdminId: "botadmin",
      markers: priorAskMarkers(credits, now),
      sinceUnix: 1_700_000_000,
      limit: 10,
    });

  it("asked_before: an earlier bot ask naming a pending track title (case- and whitespace-insensitive)", async () => {
    expect(await lookup([comment(bot, titleAsk)], NOW)).toBe("found");
  });
  it("asked_before: an earlier bot ask with the old Step 2 phrase", async () => {
    expect(await lookup([comment(bot, phraseAsk)], NOW)).toBe("found");
  });
  it("a human admin's or the customer's comment naming the title does not count", async () => {
    const human = comment({ type: "admin", id: "jan" }, titleAsk);
    const customer = comment({ type: "user", id: "contact-1" }, `${titleAsk} ${phraseAsk}`);
    expect(await lookup([human, customer], NOW)).toBe("not_found");
  });
  it("a title shorter than 3 characters is never matched", async () => {
    expect(await lookup([comment(bot, "Yo, thanks for writing in!")], NOW)).toBe("not_found");
  });
  it("after the window end only the marker sentence counts", async () => {
    const end = PRE_MARKER_WINDOW_END_MS;
    expect(await lookup([comment(bot, titleAsk), comment(bot, phraseAsk)], end)).toBe("not_found");
    expect(await lookup([comment(bot, markerAsk)], end)).toBe("found");
    expect(await lookup([comment(bot, titleAsk)], end - 1)).toBe("found");
  });
  it("unknown when the lookup fails, whatever it would have matched", async () => {
    expect(await lookup([comment(bot, titleAsk)], NOW, { searchOk: false })).toBe("unknown");
  });
});
