import { describe, it, expect, beforeEach } from "vitest";
import { createRemoveCreditsTool } from "../src/tools/remove-credits.js";
import { RateLimiter } from "../src/rate-limiter.js";
import { readFileSync } from "node:fs";

// Test-level mock for execFile that records calls and returns a programmable
// stdout/stderr/error. Matches Node's execFile callback signature so the
// promisify() wrapper inside the tool resolves/rejects correctly.
interface ExecCall {
  file: string;
  args: string[];
  options: unknown;
  tracksFileContents?: string;
}

function makeMockExecFile(opts: {
  stdout?: string;
  stderr?: string;
  error?: Error & { code?: string | number };
}) {
  const calls: ExecCall[] = [];
  const mock = (
    file: string,
    args: string[],
    options: unknown,
    callback: (err: unknown, stdout: string, stderr: string) => void,
  ) => {
    const call: ExecCall = { file, args, options };
    // Capture tracks-file contents SYNCHRONOUSLY, before the callback can
    // resolve the tool's promise: the tool unlinks its tmpfile right after
    // exec settles, so an async read races the cleanup and intermittently
    // records undefined (observed on a slow CI runner 2026-07-14).
    const tracksFileIdx = args.indexOf("--tracks-file");
    if (tracksFileIdx >= 0 && args[tracksFileIdx + 1]) {
      try {
        call.tracksFileContents = readFileSync(args[tracksFileIdx + 1], "utf8");
      } catch {
        // leave undefined — the assertion will fail loudly with context
      }
    }
    calls.push(call);
    setImmediate(() => {
      if (opts.error) {
        callback(opts.error, opts.stdout ?? "", opts.stderr ?? "");
      } else {
        callback(null, opts.stdout ?? "", opts.stderr ?? "");
      }
    });
    return undefined as any;
  };
  return { mock, calls };
}

function makeTool(opts: Parameters<typeof makeMockExecFile>[0] = {}) {
  const rateLimiter = new RateLimiter();
  const { mock, calls } = makeMockExecFile(opts);
  const tool = createRemoveCreditsTool({
    scriptPath: "/test/remove-credits.sh",
    rateLimiter,
    sessionId: "session-test",
    execFileImpl: mock as any,
  });
  return { tool, calls, rateLimiter };
}

function parseResult(r: { content: Array<{ type: string; text?: string }> }): any {
  return JSON.parse(r.content[0].text!);
}

describe("createRemoveCreditsTool", () => {
  let okStdout: string;
  beforeEach(() => {
    okStdout = JSON.stringify({
      ok: true,
      mode: "dry-run",
      profile_id: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      owner_email: "owner@example.com",
      ownership_check: "passed",
      results: [{ input: "Don Pero - Big Don Dada", status: "would_remove", matched_track_id: "abc", matched_title: "Big Don Dada" }],
      summary: { requested: 1, removed: 0, already_removed: 0, not_found: 0, ambiguous: 0, errors: 0 },
    });
  });

  it("invokes bash with fixed argv shape (no --apply when omitted)", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    await tool.execute("tc-1", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["Don Pero - Big Don Dada"],
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].file).toBe("bash");
    expect(calls[0].args[0]).toBe("/test/remove-credits.sh");
    expect(calls[0].args).toContain("--profile-id");
    expect(calls[0].args).toContain("aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8");
    expect(calls[0].args).toContain("--requester-email");
    expect(calls[0].args).toContain("owner@example.com");
    expect(calls[0].args).toContain("--tracks-file");
    expect(calls[0].args).not.toContain("--apply");
  });

  it("appends --apply when apply: true (with intercomConvId)", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    await tool.execute("tc-2", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
      apply: true,
      intercomConvId: "conv-xyz",
    });
    expect(calls[0].args).toContain("--apply");
  });

  it("appends --intercom-conv-id when provided", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    await tool.execute("tc-3", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
      intercomConvId: "conv-42",
    });
    expect(calls[0].args).toContain("--intercom-conv-id");
    expect(calls[0].args).toContain("conv-42");
  });

  it("passes tracks through a tmpfile (one per line)", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    await tool.execute("tc-4", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["A - B", "C - D", "E - F"],
    });
    // Wait long enough for the deferred readFile to complete.
    await new Promise((r) => setTimeout(r, 20));
    expect(calls[0].tracksFileContents).toBe("A - B\nC - D\nE - F\n");
  });

  it("returns the wrapper's stdout JSON verbatim on success", async () => {
    const { tool } = makeTool({ stdout: okStdout });
    const r = await tool.execute("tc-5", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
    });
    expect(parseResult(r)).toEqual(JSON.parse(okStdout));
  });

  it("passes through wrapper refusal envelopes unchanged", async () => {
    const refusal = JSON.stringify({ ok: false, error: "owner_mismatch", detail: "requester email does not match the profile's claimed owner" });
    const { tool } = makeTool({ stdout: refusal });
    const r = await tool.execute("tc-6", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "wrong@example.com",
      tracks: ["x - y"],
    });
    expect(parseResult(r)).toEqual({ ok: false, error: "owner_mismatch", detail: "requester email does not match the profile's claimed owner" });
  });

  it("returns wrapper_empty_output when stdout is empty", async () => {
    const { tool } = makeTool({ stdout: "" });
    const r = await tool.execute("tc-7", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
    });
    expect(parseResult(r)).toEqual({ ok: false, error: "wrapper_empty_output" });
  });

  it("returns wrapper_invalid_output when stdout is not JSON", async () => {
    const { tool } = makeTool({ stdout: "not json at all" });
    const r = await tool.execute("tc-8", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
    });
    const parsed = parseResult(r);
    expect(parsed.ok).toBe(false);
    expect(parsed.error).toBe("wrapper_invalid_output");
    expect(parsed.detail).toBe("not json at all");
  });

  it("returns wrapper_exec_failed when execFile rejects", async () => {
    const err = Object.assign(new Error("script died"), { code: 1 });
    const { tool } = makeTool({ error: err });
    const r = await tool.execute("tc-9", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
    });
    const parsed = parseResult(r);
    expect(parsed.ok).toBe(false);
    expect(parsed.error).toBe("wrapper_exec_failed");
    expect(parsed.detail).toBe("script died");
  });

  it("refuses apply:true without intercomConvId without exec'ing the wrapper", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    const r = await tool.execute("tc-icvid", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
      apply: true,
    });
    const parsed = parseResult(r);
    expect(parsed.ok).toBe(false);
    expect(parsed.error).toBe("intercom_conv_id_required");
    // Crucial: the rejection must short-circuit BEFORE we spawn the wrapper.
    expect(calls).toHaveLength(0);
  });

  it("refuses apply:true with empty/whitespace intercomConvId", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    const r = await tool.execute("tc-icvid-ws", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
      apply: true,
      intercomConvId: "   ",
    });
    expect(parseResult(r).error).toBe("intercom_conv_id_required");
    expect(calls).toHaveLength(0);
  });

  it("allows apply:false (dry-run) without intercomConvId", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    const r = await tool.execute("tc-dryrun-no-cv", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
      apply: false,
    });
    expect(parseResult(r).ok).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0].args).not.toContain("--apply");
  });

  it("enforces 10-call-per-60min rate limit", async () => {
    const { tool, calls } = makeTool({ stdout: okStdout });
    for (let i = 0; i < 10; i++) {
      const r = await tool.execute(`tc-rl-${i}`, {
        profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
        requesterEmail: "owner@example.com",
        tracks: ["x - y"],
      });
      expect(parseResult(r).ok).toBe(true);
    }
    const eleventh = await tool.execute("tc-rl-11", {
      profileId: "aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8",
      requesterEmail: "owner@example.com",
      tracks: ["x - y"],
    });
    expect(parseResult(eleventh)).toEqual({ ok: false, error: "rate_limited" });
    // The rate-limited call must NOT have invoked the wrapper.
    expect(calls).toHaveLength(10);
  });

  it("does NOT mention the script path or wrapper internals in the tool description", () => {
    const { tool } = makeTool({ stdout: okStdout });
    // The description is what the agent sees and reasons about. It should
    // describe behavior + safety properties, not implementation details.
    expect(tool.description).not.toMatch(/script|bash|exec|\.sh/i);
    expect(tool.description).toMatch(/customer.*own.*profile/i);
    expect(tool.description).toMatch(/preview|dry/i);
  });
});
