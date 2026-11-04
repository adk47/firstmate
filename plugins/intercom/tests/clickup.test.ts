import { describe, it, expect, vi } from "vitest";
import { readFileSync } from "node:fs";
import { createClickupTicket } from "../src/clickup.js";

const CFG = {
  apiKey: "pk_test",
  listId: "901000600160",
  userEmailFieldId: "ef",
  profileIdFieldId: "pf",
} as any;

function makeFetch(response: Partial<Response> & { jsonData?: unknown } = {}) {
  return vi.fn(async () =>
    ({
      ok: response.ok ?? true,
      status: response.status ?? 200,
      json: async () => response.jsonData ?? { id: "T1" },
      text: async () => "",
    }) as unknown as Response);
}

const PARAMS = {
  actionType: "subscription-refund",
  customerEmail: "jen@example.com",
  customerProfileId: "prof_1",
  summary: "refund_intent",
  conversationSummary: "Rule fired: refund_intent. Last user message: I was charged twice",
  conversationId: "215473921553266",
  workspaceId: "dwjzhcge",
};

describe("createClickupTicket (escalation path, shared ticket format)", () => {
  it("creates the task with the shared title format and markdown body", async () => {
    const fetchImpl = makeFetch();
    const result = await createClickupTicket({ cfg: CFG, fetchImpl }, PARAMS);
    expect(result).toEqual({ ok: true, ticketId: "T1", sla: "5-10 business days" });

    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe("https://api.clickup.com/api/v2/list/901000600160/task");
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body.name).toBe("[refund] Escalation: refund_intent — jen@example.com");
    expect(body.markdown_description).toContain("**Customer:** jen@example.com");
    expect(body.markdown_description).toContain("**Action:** subscription-refund · Tier 3 · SLA 5-10 business days");
    expect(body.markdown_description).toContain(
      "**Conversation:** https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/215473921553266",
    );
    expect(body.description).toBeUndefined();

    // Machine block stays parseable by the ops sweep regex, and the session
    // key uses the SAME canonical shape as Caroline's tickets.
    const m = /---ACTION-REQUEST---\s*(\{[\s\S]*?\})\s*---END-ACTION-REQUEST---/.exec(body.markdown_description);
    expect(m).not.toBeNull();
    const parsed = JSON.parse(m![1]);
    expect(parsed.action_type).toBe("subscription-refund");
    expect(parsed.customer_email).toBe("jen@example.com");
    expect(parsed.cs_session_id).toBe("agent:support:intercom:dwjzhcge:conversation:215473921553266");
  });

  it("renders the ask in Request: and a parseable five-key machine block", async () => {
    // The turn_count_cap producer's whole point: a human reads the ask at the
    // top, and the receiving lane reads the SAME facts from the JSON block —
    // not a 400-char fragment and not an empty `details: {}`.
    const ask = "I have been charged twice this month and three of my credits are missing from the catalog.";
    const excerpt = "ok / thanks / ok";
    const details = {
      escalation_reason: "turn_count_cap",
      original_ask: ask,
      conversation_excerpt: excerpt,
      turn_count: 30,
      summary_source: "code_rule",
    };
    const fetchImpl = makeFetch();
    await createClickupTicket({ cfg: CFG, fetchImpl }, {
      ...PARAMS,
      actionType: "support-general",
      summary: ask,
      gistSubject: ask,
      conversationSummary: "Cap reached after 30 exchanges. Ask: " + ask,
      details,
    });
    const body = JSON.parse((fetchImpl.mock.calls[0][1] as RequestInit).body as string);
    const md: string = body.markdown_description;
    // Request: is the ask, never the reason code.
    expect(md).toContain("**Request:** " + ask);
    expect(md).not.toContain("**Request:** turn_count_cap");
    // The machine block is last and parses.
    const m = /---ACTION-REQUEST---\s*(\{[\s\S]*?\})\s*---END-ACTION-REQUEST---/.exec(md);
    expect(m).not.toBeNull();
    const parsed = JSON.parse(m![1]);
    expect(parsed.details).toEqual(details);
    expect(md.indexOf("**Request:**")).toBeLessThan(md.indexOf("---ACTION-REQUEST---"));
    expect(md.indexOf("conversation_excerpt")).toBeLessThan(md.indexOf("---ACTION-REQUEST---"));
    expect(md.length).toBeLessThanOrEqual(3000);
    // The title names the topic, not the reason code.
    expect(body.name).toContain("charged twice this month");
    expect(body.name).not.toContain("turn_count_cap");
  });

  it("applies shared tags plus the intercom-auto-handoff marker, priority and due date", async () => {
    const fetchImpl = makeFetch();
    await createClickupTicket({ cfg: CFG, fetchImpl }, PARAMS);
    const body = JSON.parse((fetchImpl.mock.calls[0][1] as RequestInit).body as string);
    expect(body.tags).toEqual([
      "hydra-action-request",
      "tier-3",
      "action:subscription-refund",
      "team:growth",
      "intercom-auto-handoff",
    ]);
    expect(body.priority).toBe(1);
    expect(body.due_date_time).toBe(false);
    expect(typeof body.due_date).toBe("number");
    expect(body.due_date).toBeGreaterThan(Date.now());
  });

  it("keeps custom fields and failure handling unchanged", async () => {
    const fetchImpl = makeFetch();
    await createClickupTicket({ cfg: CFG, fetchImpl }, PARAMS);
    const body = JSON.parse((fetchImpl.mock.calls[0][1] as RequestInit).body as string);
    expect(body.custom_fields).toEqual([
      { id: "ef", value: "jen@example.com" },
      { id: "pf", value: "prof_1" },
    ]);

    const failing = makeFetch({ ok: false, status: 503 });
    const result = await createClickupTicket({ cfg: CFG, fetchImpl: failing }, PARAMS);
    expect(result).toEqual({ ok: false, error: "ClickUp 503" });
  });
});

describe("no-email escalations (backfill 2026-07-13 finding)", () => {
  it("omits the email custom field when the customer email is the unknown placeholder", async () => {
    // ClickUp validates email-typed custom fields and 400s on "unknown@unknown"
    // (proven live: 3 of the 58 OAUTH_019 backfill tickets failed exactly this
    // way). An escalation with no accountEmail on file must still get a ticket.
    const fetchImpl = makeFetch();
    await createClickupTicket({ cfg: CFG, fetchImpl }, { ...PARAMS, customerEmail: "unknown@unknown" });
    const body = JSON.parse((fetchImpl.mock.calls[0][1] as RequestInit).body as string);
    expect(body.custom_fields).toEqual([{ id: "pf", value: "prof_1" }]);
    // The human-readable ticket body still says who to look for.
    expect(body.markdown_description).toContain("unknown@unknown");
  });

  it("omits the email custom field when the email is empty", async () => {
    const fetchImpl = makeFetch();
    await createClickupTicket({ cfg: CFG, fetchImpl }, { ...PARAMS, customerEmail: "", customerProfileId: undefined });
    const body = JSON.parse((fetchImpl.mock.calls[0][1] as RequestInit).body as string);
    expect(body.custom_fields).toEqual([]);
  });
});

describe("vendored twin parity", () => {
  it("is byte-identical to plugins/support-tools/src/tools/ticket-format.ts", () => {
    const ours = readFileSync(new URL("../src/ticket-format.ts", import.meta.url), "utf8");
    const twin = readFileSync(new URL("../../support-tools/src/tools/ticket-format.ts", import.meta.url), "utf8");
    expect(twin).toBe(ours);
  });
});
