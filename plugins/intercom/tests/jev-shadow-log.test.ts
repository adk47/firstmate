import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

// Real filesystem, throwaway per-test dir — SHADOW_DIR is read from
// process.env.JEV_SHADOW_DIR at MODULE LOAD time (jev-shadow-log.ts's
// top-level `const SHADOW_DIR = ...`), so every test resets the module
// registry and re-imports after setting the env var, rather than mocking
// node:fs/promises the way handler.test.ts does — this exercises the real
// mkdir/appendFile/stat/chmod calls end to end.
describe("appendJevShadowRow", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "jev-shadow-log-test-"));
    process.env.JEV_SHADOW_DIR = dir;
    vi.resetModules();
  });

  afterEach(async () => {
    delete process.env.JEV_SHADOW_DIR;
    await rm(dir, { recursive: true, force: true });
  });

  async function importFresh() {
    return import("../src/jev-shadow-log.js");
  }

  async function readRow(): Promise<Record<string, unknown>> {
    const raw = await readFile(join(dir, "caroline.jsonl"), "utf8");
    const lines = raw.trim().split("\n");
    expect(lines).toHaveLength(1);
    return JSON.parse(lines[0]);
  }

  it("includes the raw state object next to state_sha256 by default", async () => {
    const { appendJevShadowRow } = await importFresh();
    const state = { message: "where's my credit", turnCount: 1 };
    await appendJevShadowRow({
      conversationId: "conv1",
      state,
      questions: { q: 1 },
      model: "jev-latest",
      answers: { a: 1 },
      usage: null,
      latencyMs: 5,
      actual: "route",
      rc: 0,
      http: 200,
    });
    const row = await readRow();
    expect(row.state).toEqual(state);
    expect(row.state_sha256).toMatch(/^[0-9a-f]{64}$/);
  });

  it("omits the raw state (keeps only the hash) when storeState is false", async () => {
    const { appendJevShadowRow } = await importFresh();
    const state = { message: "customer PII goes here" };
    await appendJevShadowRow({
      conversationId: "conv2",
      state,
      questions: { q: 1 },
      model: "jev-latest",
      answers: { a: 1 },
      usage: null,
      latencyMs: 5,
      actual: "route",
      rc: 0,
      http: 200,
      storeState: false,
    });
    const row = await readRow();
    expect(row.state).toBeNull();
    // The hash is still present — that half of the replay contract never
    // depends on the storeState knob.
    expect(row.state_sha256).toMatch(/^[0-9a-f]{64}$/);
    const raw = await readFile(join(dir, "caroline.jsonl"), "utf8");
    expect(raw).not.toContain("customer PII goes here");
  });

  it("creates a new shadow file at mode 0600", async () => {
    const { appendJevShadowRow } = await importFresh();
    await appendJevShadowRow({
      conversationId: "conv3",
      state: { a: 1 },
      questions: {},
      model: "jev-latest",
      answers: null,
      usage: null,
      latencyMs: 1,
      actual: "none",
      rc: 2,
      http: null,
    });
    const info = await stat(join(dir, "caroline.jsonl"));
    expect(info.mode & 0o777).toBe(0o600);
  });

  it("tightens an existing looser-permission shadow file to 0600 on the next append", async () => {
    const { appendJevShadowRow } = await importFresh();
    const { writeFile, chmod } = await import("node:fs/promises");
    const filePath = join(dir, "caroline.jsonl");
    await writeFile(filePath, "", { mode: 0o644 });
    await chmod(filePath, 0o644);
    const before = await stat(filePath);
    expect(before.mode & 0o777).toBe(0o644);

    await appendJevShadowRow({
      conversationId: "conv4",
      state: { a: 1 },
      questions: {},
      model: "jev-latest",
      answers: null,
      usage: null,
      latencyMs: 1,
      actual: "none",
      rc: 2,
      http: null,
    });

    const after = await stat(filePath);
    expect(after.mode & 0o777).toBe(0o600);
  });
});

// Real child_process throughout the suite above (execFile actually shells
// out to util-linux's flock, same as jev.sh/format-digest.sh) -- these tests
// stub node:child_process's execFile to prove the CALL shape (lock path,
// row on stdin) and the fallback when the flock binary itself is missing,
// neither of which the real-flock tests above can distinguish from a
// coincidentally-correct append.
describe("appendJevShadowRow -- flock call shape and ENOENT fallback", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "jev-shadow-log-lock-test-"));
    process.env.JEV_SHADOW_DIR = dir;
    vi.resetModules();
  });

  afterEach(async () => {
    delete process.env.JEV_SHADOW_DIR;
    await rm(dir, { recursive: true, force: true });
    vi.doUnmock("node:child_process");
  });

  it("invokes flock with a -w 5 wait on the file's own <file>.lock, piping the row on stdin", async () => {
    const filePath = join(dir, "caroline.jsonl");
    const lockPath = `${filePath}.lock`;
    const calls: { file: string; args: string[] }[] = [];

    vi.doMock("node:child_process", async (importOriginal) => {
      const actual = await importOriginal<typeof import("node:child_process")>();
      return {
        ...actual,
        execFile: (file: string, args: string[], _options: unknown, cb: (err: Error | null) => void) => {
          calls.push({ file, args });
          const stdin = new PassThrough();
          let written = "";
          stdin.on("data", (chunk) => {
            written += chunk.toString();
          });
          stdin.on("end", async () => {
            // Emulate what the real flock+sh -c 'cat >> "$1"' would do, so
            // the row shape assertion below is meaningful, not just the argv.
            await writeFile(filePath, written, { flag: "a" });
            cb(null);
          });
          return { stdin };
        },
      };
    });

    const { appendJevShadowRow } = await import("../src/jev-shadow-log.js");
    await appendJevShadowRow({
      conversationId: "conv-lock",
      state: { a: 1 },
      questions: {},
      model: "jev-latest",
      answers: null,
      usage: null,
      latencyMs: 1,
      actual: "none",
      rc: 0,
      http: 200,
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].file).toBe("flock");
    expect(calls[0].args[0]).toBe("-w");
    expect(calls[0].args[1]).toBe("5");
    expect(calls[0].args[2]).toBe(lockPath);
    expect(calls[0].args).toContain(filePath);

    const raw = await readFile(filePath, "utf8");
    const row = JSON.parse(raw.trim());
    expect(row.item_id).toBe("conv-lock");
  });

  it("falls back to a direct unlocked append when the flock binary is missing (ENOENT), and warns once", async () => {
    vi.doMock("node:child_process", async (importOriginal) => {
      const actual = await importOriginal<typeof import("node:child_process")>();
      return {
        ...actual,
        execFile: (_file: string, _args: string[], _options: unknown, cb: (err: NodeJS.ErrnoException) => void) => {
          const stdin = new PassThrough();
          stdin.on("data", () => {});
          stdin.on("end", () => {
            const err = new Error("spawn flock ENOENT") as NodeJS.ErrnoException;
            err.code = "ENOENT";
            cb(err);
          });
          return { stdin };
        },
      };
    });

    const { appendJevShadowRow } = await import("../src/jev-shadow-log.js");
    const warn = vi.fn();

    await appendJevShadowRow(
      {
        conversationId: "conv-enoent-1",
        state: { a: 1 },
        questions: {},
        model: "jev-latest",
        answers: null,
        usage: null,
        latencyMs: 1,
        actual: "none",
        rc: 0,
        http: 200,
      },
      { warn },
    );
    await appendJevShadowRow(
      {
        conversationId: "conv-enoent-2",
        state: { a: 1 },
        questions: {},
        model: "jev-latest",
        answers: null,
        usage: null,
        latencyMs: 1,
        actual: "none",
        rc: 0,
        http: 200,
      },
      { warn },
    );

    const filePath = join(dir, "caroline.jsonl");
    const raw = await readFile(filePath, "utf8");
    const lines = raw.trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0]).item_id).toBe("conv-enoent-1");
    expect(JSON.parse(lines[1]).item_id).toBe("conv-enoent-2");

    // Warned about the missing binary exactly once, not once per call.
    const missingBinaryWarnings = warn.mock.calls.filter(([msg]) => String(msg).includes("flock binary not found"));
    expect(missingBinaryWarnings).toHaveLength(1);
  });
});
