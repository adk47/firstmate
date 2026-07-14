import { describe, it, expect, vi } from "vitest";
import { createProfilesConsolidateTool } from "../src/tools/profiles-consolidate.js";
import { createIntercomReader } from "../src/intercom-client.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { IntercomReader } from "../src/intercom-client.js";
import type { HttpClient, HttpResult } from "../src/http.js";

// A valid support session key so deriveConvId(sessionKey) → "conv-1".
const SESSION_KEY = "agent:support:intercom:direct:conv-1";
const SURVIVOR = "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8";
const DUP = "bb9f3eb3-77ba-46f3-b6cd-db0898e5cbb8";

interface ExecCall {
  file: string;
  args: string[];
}

function makeTool(opts: {
  reader?: IntercomReader;
  stdout?: string;
  enabled?: boolean;
}) {
  const calls: ExecCall[] = [];
  const mock = (
    file: string,
    args: string[],
    _o: unknown,
    cb: (err: unknown, stdout: string, stderr: string) => void,
  ) => {
    calls.push({ file, args });
    setImmediate(() => cb(null, opts.stdout ?? JSON.stringify({ ok: true, mode: "dry-run", status: "dry_run" }), ""));
    return undefined as any;
  };
  const reader: IntercomReader = opts.reader ?? {
    getAuthorEmail: vi.fn(async () => "owner@example.com"),
    getLatestCustomerPart: vi.fn(async () => ({ id: "part-latest", snippet: "yes, both profiles are me" })),
  };
  const tool = createProfilesConsolidateTool({
    scriptPath: "/test/consolidate.sh",
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomReader: reader,
    intercomToken: "tok",
    enabled: opts.enabled ?? true,
    execFileImpl: mock as any,
  });
  return { tool, calls, reader };
}

function parse(r: { content: Array<{ type: string; text?: string }> }): any {
  return JSON.parse(r.content[0].text!);
}

describe("profiles_consolidate attestation", () => {
  it("does NOT pass --attested-msg when the customer has not confirmed", async () => {
    const { tool, calls, reader } = makeTool({});
    const r = await tool.execute("tc-1", { survivorId: SURVIVOR, dupIds: [DUP] });
    expect(calls[0].args).not.toContain("--attested-msg");
    expect(reader.getLatestCustomerPart).not.toHaveBeenCalled();
    expect(parse(r).attested).toBeUndefined();
  });

  it("resolves the customer's latest message, passes its id, and echoes {part_id, snippet}", async () => {
    const { tool, calls, reader } = makeTool({});
    const r = await tool.execute("tc-2", { survivorId: SURVIVOR, dupIds: [DUP], customerConfirmedSameArtist: true });
    expect(reader.getLatestCustomerPart).toHaveBeenCalledWith("conv-1", "tok");
    const i = calls[0].args.indexOf("--attested-msg");
    expect(i).toBeGreaterThan(-1);
    expect(calls[0].args[i + 1]).toBe("part-latest");
    expect(parse(r).attested).toEqual({ part_id: "part-latest", snippet: "yes, both profiles are me" });
  });

  it("pins an explicit attestedMsgId across preview→apply instead of re-resolving (QA #677)", async () => {
    const { tool, calls, reader } = makeTool({ stdout: JSON.stringify({ ok: true, mode: "apply", status: "applied" }) });
    const r = await tool.execute("tc-3", {
      survivorId: SURVIVOR,
      dupIds: [DUP],
      customerConfirmedSameArtist: true,
      attestedMsgId: "part-pinned",
      apply: true,
    });
    // The pin wins: no re-resolution, so a message arriving between preview
    // and apply can never silently become the attestation.
    expect(reader.getLatestCustomerPart).not.toHaveBeenCalled();
    const i = calls[0].args.indexOf("--attested-msg");
    expect(calls[0].args[i + 1]).toBe("part-pinned");
    expect(calls[0].args).toContain("--apply");
    expect(parse(r).attested).toEqual({ part_id: "part-pinned" });
  });

  it("ignores attestedMsgId when the customer has not confirmed", async () => {
    const { tool, calls } = makeTool({});
    await tool.execute("tc-4", { survivorId: SURVIVOR, dupIds: [DUP], attestedMsgId: "part-pinned" });
    expect(calls[0].args).not.toContain("--attested-msg");
  });

  it("omits --attested-msg (falls through to the normal gate) when no customer message resolves", async () => {
    const reader: IntercomReader = {
      getAuthorEmail: vi.fn(async () => "owner@example.com"),
      getLatestCustomerPart: vi.fn(async () => null),
    };
    const { tool, calls } = makeTool({ reader });
    const r = await tool.execute("tc-5", { survivorId: SURVIVOR, dupIds: [DUP], customerConfirmedSameArtist: true });
    expect(calls[0].args).not.toContain("--attested-msg");
    expect(parse(r).attested).toBeUndefined();
  });

  it("never resolves an attestation when disabled (dark-ship)", async () => {
    const { tool, calls, reader } = makeTool({ enabled: false });
    const r = await tool.execute("tc-6", { survivorId: SURVIVOR, dupIds: [DUP], customerConfirmedSameArtist: true });
    expect(parse(r)).toMatchObject({ ok: false, disabled: true });
    expect(calls).toHaveLength(0);
    expect(reader.getLatestCustomerPart).not.toHaveBeenCalled();
  });
});

// getLatestCustomerPart picks the most recent CONTACT-authored comment and
// returns a verifiable snippet of its body.
describe("intercom-client getLatestCustomerPart", () => {
  function httpReturning(data: unknown, ok = true): HttpClient {
    return {
      get: vi.fn(async () => (ok ? { ok: true, data } : { ok: false, error: "API error", status: 500 }) as HttpResult),
      post: vi.fn(),
      put: vi.fn(),
    } as unknown as HttpClient;
  }

  it("returns the latest user/lead comment with a tag-stripped snippet, ignoring admin/bot parts", async () => {
    const reader = createIntercomReader(httpReturning({
      created_at: 100,
      source: { id: "src", created_at: 100, body: "hi, I have duplicate profiles", author: { type: "user" } },
      conversation_parts: {
        conversation_parts: [
          { id: "p-admin", created_at: 300, part_type: "comment", body: "are these both you?", author: { type: "admin" } },
          { id: "p-cust-late", created_at: 250, part_type: "comment", body: "<p>yes both are  me!</p>", author: { type: "user" } },
          { id: "p-cust-early", created_at: 150, part_type: "comment", body: "here are the links", author: { type: "lead" } },
        ],
      },
    }));
    expect(await reader.getLatestCustomerPart("c", "tok")).toEqual({ id: "p-cust-late", snippet: "yes both are me!" });
  });

  it("falls back to the source message when it is the only customer part", async () => {
    const reader = createIntercomReader(httpReturning({
      created_at: 100,
      source: { id: "src", created_at: 100, body: "merge my profiles please", author: { type: "user" } },
      conversation_parts: { conversation_parts: [{ id: "p-a", created_at: 300, part_type: "comment", body: "ok", author: { type: "admin" } }] },
    }));
    expect((await reader.getLatestCustomerPart("c", "tok"))?.id).toBe("src");
  });

  it("ignores non-comment parts (notes/ratings)", async () => {
    const reader = createIntercomReader(httpReturning({
      created_at: 100,
      source: { id: "src", created_at: 100, body: "x", author: { type: "admin" } },
      conversation_parts: {
        conversation_parts: [
          { id: "p-note", created_at: 400, part_type: "note", body: "internal", author: { type: "user" } },
          { id: "p-comment", created_at: 200, part_type: "comment", body: "yes", author: { type: "user" } },
        ],
      },
    }));
    expect((await reader.getLatestCustomerPart("c", "tok"))?.id).toBe("p-comment");
  });

  it("returns null when no customer part exists or the API fails", async () => {
    const onlyAdmin = createIntercomReader(httpReturning({
      source: { id: "src", created_at: 100, author: { type: "admin" } },
      conversation_parts: { conversation_parts: [] },
    }));
    expect(await onlyAdmin.getLatestCustomerPart("c", "tok")).toBeNull();
    const failing = createIntercomReader(httpReturning({}, false));
    expect(await failing.getLatestCustomerPart("c", "tok")).toBeNull();
    expect(await onlyAdmin.getLatestCustomerPart("", "tok")).toBeNull();
  });
});
