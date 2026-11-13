// End-to-end through the real channel webhook route (channel.ts): a signed Intercom webhook goes in,
// and we assert what actually leaves the process — Intercom API calls (reply = customer-facing ack,
// parts = reassignment), the Slack supervision alert, and whether the agent (Caroline) was dispatched.
// Only the OpenClaw gateway plumbing (route registration, lifecycle, agent dispatch, state dir) and
// the network (global fetch) are stubbed; handler.ts, restricted-accounts.ts and channel.ts run for real.
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createHmac } from "node:crypto";
import { Readable } from "node:stream";
import userCreated from "./fixtures/conversation-user-created.json";

const routes: Array<(req: any, res: any) => Promise<void>> = [];
const dispatched: any[] = [];

vi.mock("openclaw/plugin-sdk/webhook-ingress", () => ({
  registerPluginHttpRoute: (opts: any) => {
    routes.push(opts.handler);
    return () => {};
  },
}));
vi.mock("openclaw/plugin-sdk/channel-outbound", () => ({
  runPassiveAccountLifecycle: async ({ start }: any) => {
    await start();
  },
}));
vi.mock("openclaw/plugin-sdk/channel-inbound", () => ({
  dispatchInboundDirectDmWithRuntime: async (args: any) => {
    dispatched.push(args);
    await args.deliver({ text: "Happy to help with that." });
  },
}));
vi.mock("openclaw/plugin-sdk/state-paths", () => ({ resolveStateDir: () => null }));

const { intercomPlugin, accountSessions } = await import("../src/channel.js");
const { RESTRICTED_NOTE, PROOF_REVIEW_NOTE } = await import("../src/restricted-accounts.js");
const { DEFAULT_FALLBACK_ACK } = await import("../src/types.js");

const SECRET = "whsec_test";
const BOT = "bot_1";
const SLACK = "https://hooks.slack.test/supervision";
const RESTRICTED_ID = "63bf0173c00101f1a4a458ec"; // an account that stays banned
const PROOF_REVIEW_ID = "653d6188543386a913cae31e"; // a restored account under proof review
const CLEARED_ID = "6310229dc45a0ca92679342c"; // the 17:56Z contact; cleared by the re-review
const cfg = {
  channels: {
    intercom: {
      accounts: {
        default: {
          enabled: true,
          workspaceId: "ws_1",
          token: "tok",
          webhookSecret: SECRET,
          botAdminId: BOT,
          escalationTeamId: "777111",
          fallbackSlackSupervisionChannel: SLACK,
          coalesceDispatch: false,
        },
      },
    },
  },
};

type Call = { method: string; url: string; body: any };
let calls: Call[] = [];
let liveAssignee: { type: string; id: string } | null = null;
// A human assignee holds a conversation only while a human is WORKING it (assignment-policy.ts
// humanHold). false = that human acted a minute ago; true = nobody human ever touched it.
let liveStale = false;
let slackStatus = 200;
let liveGetStatus = 200;
const errors: string[] = [];

function message(authorId: string, body: string, eventId: string, convId: string) {
  return {
    ...userCreated,
    id: eventId,
    data: {
      ...userCreated.data,
      item: { ...userCreated.data.item, id: convId, source: { body, author: { type: "user", id: authorId } } },
    },
  };
}

async function deliver(payload: unknown): Promise<void> {
  const raw = JSON.stringify(payload);
  const sig = "sha256=" + createHmac("sha256", SECRET).update(raw).digest("hex");
  const req: any = Readable.from([Buffer.from(raw)]);
  req.method = "POST";
  req.headers = { "x-hub-signature": sig };
  const res: any = { writeHead: vi.fn(), end: vi.fn() };
  await routes[0](req, res);
  expect(res.writeHead).toHaveBeenCalledWith(200, expect.anything());
}

// /reply carries both customer-facing comments and admin-only internal notes; only comments reach the customer.
const replies = () =>
  calls.filter((c) => c.method === "POST" && c.url.endsWith("/reply") && c.body.message_type !== "note");
const notes = () =>
  calls.filter((c) => c.method === "POST" && c.url.endsWith("/reply") && c.body.message_type === "note");
const reassigns = () => calls.filter((c) => c.method === "POST" && c.url.endsWith("/parts"));
// An explicit escalation = take the bot off ("0"), then place the escalation TEAM (type team).
const expectEscalatedToTeam = () => {
  expect(reassigns().map((c) => [c.body.type, c.body.assignee_id])).toEqual([["admin", "0"], ["team", "777111"]]);
};
const slack = () => calls.filter((c) => c.url === SLACK);

beforeEach(async () => {
  calls = [];
  dispatched.length = 0;
  liveAssignee = null;
  liveStale = false;
  slackStatus = 200;
  liveGetStatus = 200;
  errors.length = 0;
  accountSessions.clear();
  vi.stubGlobal("fetch", async (url: string, init: any = {}) => {
    const method = init.method ?? "GET";
    calls.push({ method, url, body: init.body ? JSON.parse(init.body) : undefined });
    if (method === "GET") {
      if (liveGetStatus !== 200) return new Response("unavailable", { status: liveGetStatus });
      return new Response(
        JSON.stringify({
          type: "conversation", id: url.split("/").pop(), open: true, state: "open", assignee: liveAssignee,
          conversation_parts: {
            conversation_parts: liveAssignee && !liveStale
              ? [{ id: "p1", part_type: "comment", body: "On it.", created_at: Math.floor(Date.now() / 1000) - 60, author: { type: "admin", id: liveAssignee.id } }]
              : [],
          },
        }),
        { status: 200 },
      );
    }
    if (url === SLACK) return new Response(slackStatus === 200 ? "ok" : "rate_limited", { status: slackStatus });
    return new Response(JSON.stringify({ id: "part_1" }), { status: 200 });
  });
  if (routes.length === 0) {
    await (intercomPlugin as any).gateway.startAccount({
      cfg,
      accountId: "default",
      channelRuntime: {},
      abortSignal: new AbortController().signal,
      log: { info: () => {}, warn: () => {}, error: (m: string) => errors.push(m) },
    });
  }
});

afterEach(() => vi.unstubAllGlobals());

describe("channel webhook - restricted accounts (end to end)", () => {
  it("restricted contact, bot holds conversation: no agent, no ack, reassigned to the escalation TEAM, Slack alert carries hold note", async () => {
    await deliver(message(RESTRICTED_ID, "My subscription was cancelled unexpectedly, please restore it", "e1", "conv_r1"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expectEscalatedToTeam();
    expect(slack()).toHaveLength(1);
    expect(JSON.stringify(slack()[0].body)).toContain(RESTRICTED_NOTE);
    expect(notes()).toHaveLength(1);
    expect(notes()[0].body.body).toBe(RESTRICTED_NOTE);

    // every message re-alerts, deliberately
    await deliver(message(RESTRICTED_ID, "hello?", "e2", "conv_r1"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expect(slack()).toHaveLength(2);
    expect(notes()).toHaveLength(2);
  });

  it("restricted contact, human admin holds conversation: re-alert without reassigning, no ack, no agent", async () => {
    liveAssignee = { type: "admin", id: "human_admin_1" };
    await deliver(message(RESTRICTED_ID, "Any update on my refund?", "e3", "conv_r2"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expect(reassigns()).toHaveLength(0);
    expect(slack()).toHaveLength(1);
    expect(JSON.stringify(slack()[0].body)).toContain(RESTRICTED_NOTE);
    expect(notes()).toHaveLength(1);
    expect(notes()[0].body.body).toBe(RESTRICTED_NOTE);
  });

  it("restricted contact, human-held, Slack rejects the alert (429): hold note still lands in Intercom, rejection logged", async () => {
    liveAssignee = { type: "admin", id: "human_admin_1" };
    slackStatus = 429;
    await deliver(message(RESTRICTED_ID, "Please reverse the cancellation", "e8", "conv_r4"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expect(reassigns()).toHaveLength(0);
    expect(slack()).toHaveLength(1);
    expect(notes()).toHaveLength(1);
    expect(notes()[0].url).toContain("/conversations/conv_r4/reply");
    expect(notes()[0].body.body).toBe(RESTRICTED_NOTE);
    expect(errors.some((e) => e.includes("Slack escalation notification rejected: 429"))).toBe(true);
  });

  it("restricted contact, bot-held, Slack fails the alert (500): note and reassignment still land, rejection logged", async () => {
    slackStatus = 500;
    await deliver(message(RESTRICTED_ID, "Why is my account locked?", "e13", "conv_r6"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expect(slack()).toHaveLength(1);
    expectEscalatedToTeam();
    expect(notes()).toHaveLength(1);
    expect(notes()[0].url).toContain("/conversations/conv_r6/reply");
    expect(notes()[0].body.body).toBe(RESTRICTED_NOTE);
    expect(errors.some((e) => e.includes("Slack escalation notification rejected: 500"))).toBe(true);
  });

  it("keyword escalation (legacy), Slack rejects the alert (500): ack unchanged, escalated to the team, rejection logged", async () => {
    slackStatus = 500;
    await deliver(message("user_abc", "I'm filing a chargeback", "e14", "conv_n4"));
    expect(replies()).toHaveLength(1);
    expect(replies()[0].body.body).toBe(DEFAULT_FALLBACK_ACK);
    expectEscalatedToTeam();
    expect(slack()).toHaveLength(1);
    expect(errors.some((e) => e.includes("Slack escalation notification rejected: 500"))).toBe(true);
  });

  it.each([429, 500])(
    "restricted contact, human-held, live assignee lookup fails (%i): cached human owner kept, no reassign",
    async (status) => {
      liveAssignee = { type: "admin", id: "human_admin_1" };
      await deliver(message(RESTRICTED_ID, "Any news?", `e11_${status}`, `conv_r5_${status}`));
      expect(reassigns()).toHaveLength(0);

      calls = [];
      liveGetStatus = status;
      await deliver(message(RESTRICTED_ID, "Hello again", `e12_${status}`, `conv_r5_${status}`));
      expect(calls.some((c) => c.method === "GET")).toBe(true);
      expect(dispatched).toHaveLength(0);
      expect(replies()).toHaveLength(0);
      expect(reassigns()).toHaveLength(0);
      expect(slack()).toHaveLength(1);
      expect(notes()).toHaveLength(1);
      expect(notes()[0].body.body).toBe(RESTRICTED_NOTE);
    },
  );

  it("restricted contact, closed conversation: still filtered (unchanged live-check behaviour)", async () => {
    calls = [];
    vi.stubGlobal("fetch", async (url: string, init: any = {}) => {
      calls.push({ method: init.method ?? "GET", url, body: init.body ? JSON.parse(init.body) : undefined });
      return new Response(JSON.stringify({ type: "conversation", state: "closed", open: false, assignee: null }), { status: 200 });
    });
    await deliver(message(RESTRICTED_ID, "hi", "e4", "conv_r3"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expect(notes()).toHaveLength(0);
    expect(slack()).toHaveLength(0);
  });

  it("proof-review contact, bot holds conversation: no agent, no ack, reassigned, neutral note in Intercom and Slack", async () => {
    await deliver(message(PROOF_REVIEW_ID, "Some of my credits are still hidden", "e9", "conv_p1"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expectEscalatedToTeam();
    expect(slack()).toHaveLength(1);
    expect(JSON.stringify(slack()[0].body)).toContain(PROOF_REVIEW_NOTE);
    expect(JSON.stringify(slack()[0].body)).not.toContain(RESTRICTED_NOTE);
    expect(notes()).toHaveLength(1);
    expect(notes()[0].body.body).toBe(PROOF_REVIEW_NOTE);
  });

  it("cleared contact: reaches the agent, no alert, no note", async () => {
    await deliver(message(CLEARED_ID, "Thanks, I can log in now", "e10", "conv_c1"));
    expect(dispatched).toHaveLength(1);
    expect(slack()).toHaveLength(0);
    expect(notes()).toHaveLength(0);
    expect(reassigns().every((c) => c.body?.assignee_id !== "team_ops")).toBe(true);
    expect(JSON.stringify(calls)).not.toContain("proof review");
    expect(JSON.stringify(calls)).not.toContain("banned fraud account");
  });

  it("everyone else unchanged: normal message reaches the agent; keyword escalation still sends the ack", async () => {
    await deliver(message("user_abc", "Hi, I need help with my account", "e5", "conv_n1"));
    expect(dispatched).toHaveLength(1);
    expect(slack()).toHaveLength(0);

    calls = [];
    await deliver(message("user_abc", "I'm filing a chargeback", "e6", "conv_n2"));
    expect(dispatched).toHaveLength(1);
    expect(replies()).toHaveLength(1);
    expect(replies()[0].body.body).toBe(DEFAULT_FALLBACK_ACK);
    expect(notes()).toHaveLength(0);
    expectEscalatedToTeam();
    expect(slack()).toHaveLength(1);
  });

  it("restricted contact parked on a STALE human assignee: moved to the escalation team, never left on the person", async () => {
    liveAssignee = { type: "admin", id: "5465657" };
    liveStale = true;
    await deliver(message(RESTRICTED_ID, "Any update on my refund?", "e30", "conv_r30"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expectEscalatedToTeam();
    expect(notes()).toHaveLength(1);
  });

  it("non-restricted contact parked on a STALE human assignee: Caroline reclaims it and answers", async () => {
    liveAssignee = { type: "admin", id: "5465657" };
    liveStale = true;
    await deliver(message("user_abc", "Any update?", "e31", "conv_n31"));
    expect(dispatched).toHaveLength(1);
    // The only assignment is the bot taking it back.
    expect(reassigns().map((c) => [c.body.type, c.body.assignee_id])).toEqual([["admin", BOT]]);
    expect(slack()).toHaveLength(0);
  });

  it("non-restricted contact, human admin holds conversation: still filtered, nothing sent", async () => {
    liveAssignee = { type: "admin", id: "human_admin_1" };
    await deliver(message("user_abc", "Any update?", "e7", "conv_n3"));
    expect(dispatched).toHaveLength(0);
    expect(replies()).toHaveLength(0);
    expect(reassigns()).toHaveLength(0);
    expect(slack()).toHaveLength(0);
  });
});
