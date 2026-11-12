import { describe, expect, it } from "vitest";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileLedger } from "../src/support-intent-ledger.js";

describe("support-intent ledger", () => {
  it("appends one JSON row per decision, in order, and never rewrites", async () => {
    const dir = await mkdtemp(join(tmpdir(), "sig-ledger-"));
    const path = join(dir, "nested", "ledger.jsonl");
    const ledger = fileLedger(path);
    await ledger.append({ ts: "2026-11-09T20:30:00.000Z", kind: "support_intent", decision: "allow", actor: "caroline.support-executor" });
    await ledger.append({ ts: "2026-11-09T20:30:01.000Z", kind: "support_intent", decision: "executed", actor: "caroline.support-executor" });
    const lines = (await readFile(path, "utf8")).trim().split("\n").map((l) => JSON.parse(l));
    expect(lines.map((l) => l.decision)).toEqual(["allow", "executed"]);
    expect(lines[0].actor).toBe("caroline.support-executor");
  });
});
