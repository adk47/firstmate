import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { access, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { RateLimiter } from "../src/rate-limiter.js";
import {
  COMPANY_FINDER_CRON_SESSION,
  createCompanyFinderFinalizeTool,
  createCompanyFinderPrepTool,
  runProcessGroup,
} from "../src/tools/company-finder-batch.js";

type RunProcessImpl = (
  file: string,
  args: readonly string[],
  signal?: AbortSignal,
) => Promise<{ stdout: string; stderr: string; exitCode: number | string | null }>;

const parseResult = async (result: Promise<any>) =>
  JSON.parse((await result).content[0].text);

describe("company-finder atomic batch tools", () => {
  let diagnosticsDir: string;

  beforeEach(async () => {
    diagnosticsDir = await mkdtemp(path.join(tmpdir(), "company-finder-tool-test-"));
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await rm(diagnosticsDir, { recursive: true, force: true });
  });

  const deps = (runProcessImpl: RunProcessImpl, overrides: Record<string, unknown> = {}) => ({
    runnerPath: "/opt/hydra/scripts/company-finder/run-stage.sh",
    diagnosticsDir,
    sessionKey: COMPANY_FINDER_CRON_SESSION,
    sessionId: `session-${Math.random()}`,
    agentId: "scout",
    rateLimiter: new RateLimiter(),
    runProcessImpl,
    ...overrides,
  });

  it("rejects untrusted sessions before launching a host process", async () => {
    const runProcess = vi.fn();
    const tool = createCompanyFinderPrepTool(deps(runProcess as unknown as RunProcessImpl, {
      sessionKey: "agent:scout:slack:channel:random",
    }));

    const out = await parseResult(tool.execute("call-1", { candidates: [] }));

    expect(out).toMatchObject({ ok: false, status: "failed", error: "COMPANY_FINDER_NOT_AUTHORIZED" });
    expect(runProcess).not.toHaveBeenCalled();
  });

  it("rejects lookalike company-finder cron run sessions", async () => {
    const runProcess = vi.fn();
    const tool = createCompanyFinderPrepTool(deps(runProcess as unknown as RunProcessImpl, {
      sessionKey: `${COMPANY_FINDER_CRON_SESSION}:run:not-a-runtime-uuid`,
    }));

    const out = await parseResult(tool.execute("call-lookalike", { candidates: [] }));

    expect(out).toMatchObject({ ok: false, status: "failed", error: "COMPANY_FINDER_NOT_AUTHORIZED" });
    expect(runProcess).not.toHaveBeenCalled();
  });

  it("rejects the configured cron run session outside the Scout agent", async () => {
    const runProcess = vi.fn();
    const tool = createCompanyFinderPrepTool(deps(runProcess as unknown as RunProcessImpl, {
      sessionKey: `${COMPANY_FINDER_CRON_SESSION}:run:61cb8fa7-a51c-4305-9d33-b454d6d8f8cb`,
      agentId: "cmo",
    }));

    const out = await parseResult(tool.execute("call-wrong-agent", { candidates: [] }));

    expect(out).toMatchObject({ ok: false, status: "failed", error: "COMPANY_FINDER_NOT_AUTHORIZED" });
    expect(runProcess).not.toHaveBeenCalled();
  });

  it("rejects isolated runs from a different Scout cron", async () => {
    const runProcess = vi.fn();
    const tool = createCompanyFinderPrepTool(deps(runProcess as unknown as RunProcessImpl, {
      sessionKey: "agent:scout:cron:00000000-0000-4000-8000-000000000000:run:61cb8fa7-a51c-4305-9d33-b454d6d8f8cb",
    }));

    const out = await parseResult(tool.execute("call-wrong-cron", { candidates: [] }));

    expect(out).toMatchObject({ ok: false, status: "failed", error: "COMPANY_FINDER_NOT_AUTHORIZED" });
    expect(runProcess).not.toHaveBeenCalled();
  });

  it("bounds the prep union to the skill's 3-4x discovery budget", () => {
    const tool = createCompanyFinderPrepTool(deps(vi.fn() as unknown as RunProcessImpl));

    expect((tool.parameters as any).properties.candidates.maxItems).toBe(40);
  });

  it.each([
    ["Nick", "U0AL36NADEY"],
    ["Aaron", "U7RP6HKUZ"],
    ["McLaren", "U02S7C96CGN"],
  ])("allows approved requester %s through trusted inbound metadata", async (_name, requesterSenderId) => {
    const runProcess: RunProcessImpl = async () => ({
      stdout: '{"survivors":[],"rejects":{"duplicates":[],"dead":[],"name_flags":[]},"stats":{"checked":0}}',
      stderr: "",
      exitCode: 0,
    });
    const tool = createCompanyFinderPrepTool(deps(runProcess, {
      sessionKey: "agent:scout:slack:channel:company-finder",
      requesterSenderId,
    }));

    const out = await parseResult(tool.execute("call-2", { candidates: [] }));

    expect(out).toMatchObject({ ok: true, status: "no_candidates", terminal: true });
  });

  it("waits for prep and persists exact started-to-finished evidence", async () => {
    let capturedInput: unknown;
    let capturedSignal: AbortSignal | undefined;
    const runProcess: RunProcessImpl = async (_file, args, signal) => {
      capturedSignal = signal;
      capturedInput = JSON.parse(await readFile(args[1], "utf8"));
      return {
        stdout: JSON.stringify({
          survivors: [{ name: "A", domain: "a.example", verification: "alive" }],
          rejects: { duplicates: [], dead: [], name_flags: [] },
          stats: { checked: 1, survivors: 1 },
        }),
        stderr: "prep warning",
        exitCode: 0,
      };
    };
    const tool = createCompanyFinderPrepTool(deps(runProcess));
    const candidates = [{ name: "A", domain: "a.example", vertical: "Audio", why: "fit" }];
    const controller = new AbortController();

    const out = await parseResult(tool.execute("call-3", { candidates }, controller.signal));

    expect(out).toMatchObject({ ok: true, status: "prepared", terminal: false });
    expect(out.diagnosticId).toEqual(expect.any(String));
    expect(capturedInput).toEqual(candidates);
    expect(capturedSignal).toBe(controller.signal);

    const dayDirs = await readdir(diagnosticsDir);
    const artifacts = await readdir(path.join(diagnosticsDir, dayDirs[0]));
    expect(artifacts).toHaveLength(1);
    const artifact = JSON.parse(await readFile(path.join(diagnosticsDir, dayDirs[0], artifacts[0]), "utf8"));
    expect(artifact).toMatchObject({
      state: "finished",
      stage: "prep",
      toolCallId: "call-3",
      exitCode: 0,
      stdin: candidates,
      stderr: "prep warning",
    });
  });

  it("persists raw nonzero output before returning the wrapper marker", async () => {
    const runProcess: RunProcessImpl = async () => ({
      stdout: '{"error":"VERIFY_NETWORK_SUSPECT","exit":3,"detail":"egress"}',
      stderr: "raw stderr",
      exitCode: 3,
    });
    const tool = createCompanyFinderPrepTool(deps(runProcess));

    const out = await parseResult(tool.execute("call-4", {
      candidates: [{ name: "A", domain: "a.example", vertical: "Audio" }],
    }));

    expect(out).toMatchObject({ ok: false, error: "VERIFY_NETWORK_SUSPECT", exit: 3 });
    const dayDirs = await readdir(diagnosticsDir);
    const artifacts = await readdir(path.join(diagnosticsDir, dayDirs[0]));
    const artifact = JSON.parse(await readFile(path.join(diagnosticsDir, dayDirs[0], artifacts[0]), "utf8"));
    expect(artifact).toMatchObject({ state: "finished", exitCode: 3, stderr: "raw stderr" });
    expect(artifact.stdout).toContain("VERIFY_NETWORK_SUSPECT");
  });

  it("fails closed before execution when diagnostics cannot be created", async () => {
    const blockedPath = path.join(diagnosticsDir, "not-a-directory");
    await writeFile(blockedPath, "file");
    const runProcess = vi.fn();
    const tool = createCompanyFinderPrepTool(deps(runProcess as unknown as RunProcessImpl, {
      diagnosticsDir: blockedPath,
    }));

    const out = await parseResult(tool.execute("call-5", { candidates: [] }));

    expect(out).toMatchObject({ ok: false, error: "DIAGNOSTIC_UNAVAILABLE" });
    expect(runProcess).not.toHaveBeenCalled();
  });

  it("passes a strict final payload and trusted source to the host", async () => {
    let capturedInput: unknown;
    let capturedSource = "";
    const runProcess: RunProcessImpl = async (_file, args) => {
      capturedInput = JSON.parse(await readFile(args[1], "utf8"));
      capturedSource = args[2];
      return {
        stdout: '{"posted":{"ts":"123.456","channel":"C0ARS7XMY93"},"ledger":{"suggested":1,"rejects_recorded":0}}',
        stderr: "",
        exitCode: 0,
      };
    };
    const tool = createCompanyFinderFinalizeTool(deps(runProcess, {
      sessionKey: `${COMPANY_FINDER_CRON_SESSION}:run:9ce2ade0-39a8-4057-9378-44e31e587ae2`,
    }));
    const params = {
      batch: [{
        name: "A",
        domain: "a.example",
        vertical: "Audio",
        tier: "2",
        flags: ["bot-walled"],
        verification: "blocked" as const,
        verified_at: "2026-08-18",
        http_code: "403",
      }],
      rejects: [],
      date: "2026-08-18",
    };

    const out = await parseResult(tool.execute("call-6", params));

    expect(out).toMatchObject({ ok: true, status: "posted", terminal: true, posted: { ts: "123.456" } });
    expect(capturedInput).toEqual(params);
    expect(capturedSource).toBe("cron:company-finder-daily");
  });

  it("rate-limits repeated stage launches in one session", async () => {
    const runProcess: RunProcessImpl = async () => ({
      stdout: '{"survivors":[],"rejects":{"duplicates":[],"dead":[],"name_flags":[]},"stats":{"checked":0}}',
      stderr: "",
      exitCode: 0,
    });
    const tool = createCompanyFinderPrepTool(deps(runProcess));

    const first = await parseResult(tool.execute("call-7", { candidates: [] }));
    const second = await parseResult(tool.execute("call-8", { candidates: [] }));

    expect(first.status).toBe("no_candidates");
    expect(second).toMatchObject({ ok: false, error: "RATE_LIMITED" });
  });

  it("does not resolve abort until a TERM-ignoring process group is gone", async () => {
    const runner = path.join(diagnosticsDir, "ignore-term.sh");
    const marker = path.join(diagnosticsDir, "late-side-effect");
    const ready = path.join(diagnosticsDir, "ready");
    await writeFile(
      runner,
      `#!/usr/bin/env bash\ntrap '' TERM\n( trap '' TERM; touch '${ready}'; sleep 0.5; touch '${marker}' ) &\nwait\n`,
      { mode: 0o755 },
    );
    const controller = new AbortController();
    let resolved = false;

    const running = runProcessGroup(runner, [], controller.signal, 100)
      .then((result) => { resolved = true; return result; });
    while (true) {
      try { await access(ready); break; } catch { await new Promise((resolve) => setTimeout(resolve, 5)); }
    }
    controller.abort();
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(resolved).toBe(false);
    const result = await running;
    expect(result.exitCode).toBe("ABORTED");
    await expect(access(marker)).rejects.toThrow();
  });

  it("does not spawn a stage when the signal is already aborted", async () => {
    const runner = path.join(diagnosticsDir, "must-not-run.sh");
    const marker = path.join(diagnosticsDir, "unexpected-launch");
    await writeFile(runner, `#!/usr/bin/env bash\ntouch '${marker}'\n`, { mode: 0o755 });
    const controller = new AbortController();
    controller.abort();

    const result = await runProcessGroup(runner, [], controller.signal, 100);

    expect(result.exitCode).toBe("ABORTED");
    await expect(access(marker)).rejects.toThrow();
  });

  it("kills the process group when combined output exceeds the capture limit", async () => {
    const runner = path.join(diagnosticsDir, "oversized-output.sh");
    const marker = path.join(diagnosticsDir, "late-output-side-effect");
    await writeFile(
      runner,
      `#!/usr/bin/env bash\ntrap '' TERM\n( trap '' TERM; sleep 0.5; touch '${marker}' ) &\nyes x | head -c 5000000\nwait\n`,
      { mode: 0o755 },
    );

    const result = await runProcessGroup(runner, [], undefined, 100);

    expect(result.exitCode).toBe("COMPANY_FINDER_OUTPUT_TOO_LARGE");
    await expect(access(marker)).rejects.toThrow();
  });
});
