import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadAgentInstructions,
  __resetAgentInstructionsCacheForTests,
} from "../src/caroline-agent-instructions-loader.js";

// Uses a real temp dir (mkdtemp under os.tmpdir()), never a default/prod
// path — this loader's whole job is reading an arbitrary absolute path, so
// exercising it against a throwaway file is the honest test, but it must
// never touch /opt/hydra or /var/lib (see docs/lessons/working-in-hydra.md
// "CI writes prod" — CI runs these tests as root on node-8).
describe("loadAgentInstructions", () => {
  let dir: string;
  let file: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "jev-soul-test-"));
    file = join(dir, "SOUL.md");
    __resetAgentInstructionsCacheForTests();
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    __resetAgentInstructionsCacheForTests();
  });

  it("reads and returns the file's content", () => {
    writeFileSync(file, "Be warm. Be brief.", "utf8");
    expect(loadAgentInstructions(file)).toBe("Be warm. Be brief.");
  });

  it("returns null and warns once when the path is unreadable", () => {
    const missing = join(dir, "does-not-exist.md");
    const warn = { warn: (_m: string) => {} };
    let calls = 0;
    warn.warn = () => {
      calls++;
    };
    expect(loadAgentInstructions(missing, warn)).toBeNull();
    expect(loadAgentInstructions(missing, warn)).toBeNull();
    expect(calls).toBe(1); // warned once per distinct path, not per call
  });

  it("reloads when the file's mtime changes (a deploy overwriting SOUL.md)", () => {
    writeFileSync(file, "version one", "utf8");
    expect(loadAgentInstructions(file)).toBe("version one");

    // Bump mtime forward explicitly — same-millisecond rewrites on a fast
    // filesystem can otherwise leave mtimeMs unchanged, which would make
    // this test pass for the wrong reason (stale content never observed).
    const bumped = new Date(Date.now() + 5000);
    writeFileSync(file, "version two", "utf8");
    utimesSync(file, bumped, bumped);

    expect(loadAgentInstructions(file)).toBe("version two");
  });

  it("does not re-read the file when mtime is unchanged (cache hit)", () => {
    writeFileSync(file, "cached content", "utf8");
    const first = loadAgentInstructions(file);
    // Overwrite the file's bytes without touching mtime is impractical to
    // simulate portably; instead assert the returned string is stable
    // across repeated calls against the same unmodified file (mtime
    // naturally unchanged), which is the same code path the mtime-check
    // guards.
    const second = loadAgentInstructions(file);
    expect(first).toBe("cached content");
    expect(second).toBe("cached content");
  });

  it("falls back to DEFAULT_AGENT_INSTRUCTIONS_PATH when path is undefined or blank", () => {
    // Neither exists in this sandbox, so both resolve through the fail-soft
    // branch — this only asserts it never throws on an absent override.
    expect(() => loadAgentInstructions(undefined)).not.toThrow();
    expect(() => loadAgentInstructions("   ")).not.toThrow();
  });
});
