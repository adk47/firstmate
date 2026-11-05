import { mkdir, mkdtemp, readFile, rm, rmdir, stat, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { appendSafetyLedger } from "../src/safety-ledger.js";
import { LEDGER_LOCK_STALE_MS, LEDGER_LOCK_SUFFIX, LEDGER_LOCK_WAIT_MS } from "../src/injection-watch.js";

/**
 * The TS writer's half of the shared ledger lock (QA on #1665). The retention prune deletes a sealed generation only
 * while it holds `<ledger>.ledger.lock`; an append outside that lock could land in a generation being deleted and be
 * lost. So the append happens under the lock -- and when the lock cannot be had the row is STILL written, with an
 * ALERT, because a dropped customer hit is worse than one unserialised append.
 */
describe("safety ledger: the shared prune lock", () => {
  let dir: string;
  let ledger: string;
  let lock: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "ledger-lock-"));
    await mkdir(join(dir, "leaf"), { recursive: false, mode: 0o700 });   // the parent must pre-exist
    ledger = join(dir, "leaf", "ledger.jsonl");
    lock = `${ledger}${LEDGER_LOCK_SUFFIX}`;
  });

  afterEach(async () => {
    await rmdir(join(dir, "leaf", "ledger.jsonl.ledger.lock")).catch(() => {});
    await rm(dir, { recursive: true, force: true });
  });

  it("appends under the lock and releases it", async () => {
    expect(await appendSafetyLedger({ n: 1 }, ledger)).toBeNull();
    await expect(stat(`${ledger}${LEDGER_LOCK_SUFFIX}`)).rejects.toThrow(); // released, not leaked
    expect(await readFile(ledger, "utf8")).toBe('{"n":1}\n');
  });

  it("waits for a lock another process holds, then writes", async () => {
    await mkdir(`${ledger}${LEDGER_LOCK_SUFFIX}`, { mode: 0o700 });
    const started = Date.now();
    setTimeout(() => void rmdir(`${ledger}${LEDGER_LOCK_SUFFIX}`).catch(() => {}), 80);
    expect(await appendSafetyLedger({ n: 2 }, ledger)).toBeNull();
    expect(Date.now() - started).toBeGreaterThanOrEqual(60);            // it really waited
    expect(await readFile(ledger, "utf8")).toContain('"n":2');
  });

  it("steals a stale lock from a crashed holder instead of waiting for it", async () => {
    await mkdir(`${ledger}${LEDGER_LOCK_SUFFIX}`, { mode: 0o700 });
    const old = new Date(Date.now() - (LEDGER_LOCK_STALE_MS + 5_000));
    await utimes(`${ledger}${LEDGER_LOCK_SUFFIX}`, old, old);
    expect(await appendSafetyLedger({ n: 3 }, ledger)).toBeNull();
    await expect(stat(`${ledger}${LEDGER_LOCK_SUFFIX}`)).rejects.toThrow();
    expect(await readFile(ledger, "utf8")).toContain('"n":3');
  });

  it("writes the row anyway, and reports it, when the lock cannot be taken", { timeout: 20_000 }, async () => {
    await mkdir(`${ledger}${LEDGER_LOCK_SUFFIX}`, { mode: 0o700 });      // fresh + never released
    const errors: string[] = [];
    const realError = console.error;
    console.error = (msg?: unknown) => { errors.push(String(msg)); };
    try {
      expect(await appendSafetyLedger({ n: 4 }, ledger)).toBeNull();
    } finally {
      console.error = realError;
    }
    expect(await readFile(ledger, "utf8")).toContain('"n":4');
    expect(errors.join("\n")).toContain("ALERT");
    expect(LEDGER_LOCK_WAIT_MS).toBe(5_000);
  });
});
