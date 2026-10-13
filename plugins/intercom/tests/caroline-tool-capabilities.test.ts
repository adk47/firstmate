import { describe, it, expect, afterEach } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  loadCarolineToolCapabilities,
  loadCarolineIntents,
  __resetCarolineInventoryCacheForTests,
} from "../src/caroline-inventory-loader.js";

// caroline-tool-capabilities.json is hand-authored (sourced from
// workspaces/support/TOOLS.md), not machine-generated from
// caroline-inventory.json — so nothing enforces the two files stay in sync
// except this drift test. Per the spec: "Add a vitest drift test: capability
// names == inventory tool names exactly; kb_topics non-empty."

const THIS_DIR = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(THIS_DIR, "..", "src");
const REPO_ROOT = join(THIS_DIR, "..", "..", "..");

function readInventoryToolNames(): string[] {
  const raw = readFileSync(join(SRC_DIR, "caroline-inventory.json"), "utf8");
  const data = JSON.parse(raw) as { tools: { name: string }[] };
  return data.tools.map((t) => t.name);
}

function readInventoryHumanRequired(): string[] {
  const raw = readFileSync(join(SRC_DIR, "caroline-inventory.json"), "utf8");
  const data = JSON.parse(raw) as { human_required: string[] };
  return data.human_required;
}

function readKbReferenceTitles(): string[] {
  const dir = join(REPO_ROOT, "workspaces", "support", "reference");
  const files = readdirSync(dir).filter((f) => f.endsWith(".md")).sort();
  return files.map((f) => {
    const first = readFileSync(join(dir, f), "utf8").split("\n")[0];
    return first.replace(/^#\s*/, "").trim();
  });
}

describe("caroline-tool-capabilities.json drift", () => {
  afterEach(() => {
    __resetCarolineInventoryCacheForTests();
  });

  it("capability tool names == caroline-inventory.json tool names, exactly (same set)", () => {
    const capabilities = loadCarolineToolCapabilities();
    expect(capabilities).not.toBeNull();
    const capNames = capabilities!.tools.map((t) => t.name).sort();
    const inventoryNames = readInventoryToolNames().sort();
    expect(capNames).toEqual(inventoryNames);
  });

  it("no capability tool name is missing from the inventory (falsifiable: a stray name fails)", () => {
    const capabilities = loadCarolineToolCapabilities();
    const inventoryNames = new Set(readInventoryToolNames());
    for (const tool of capabilities!.tools) {
      expect(inventoryNames.has(tool.name)).toBe(true);
    }
  });

  it("no inventory tool is missing a capability entry (falsifiable: a dropped tool fails)", () => {
    const capabilities = loadCarolineToolCapabilities();
    const capNames = new Set(capabilities!.tools.map((t) => t.name));
    for (const name of readInventoryToolNames()) {
      expect(capNames.has(name)).toBe(true);
    }
  });

  it("policy.human_gated matches caroline-inventory.json's human_required list exactly", () => {
    const capabilities = loadCarolineToolCapabilities();
    expect(capabilities!.policy.human_gated).toEqual(readInventoryHumanRequired());
  });

  it("policy.kb_topics is non-empty", () => {
    const capabilities = loadCarolineToolCapabilities();
    expect(capabilities!.policy.kb_topics.length).toBeGreaterThan(0);
  });

  it("policy.kb_topics matches the live H1 titles under workspaces/support/reference/*.md (drift check)", () => {
    const capabilities = loadCarolineToolCapabilities();
    const liveTitles = readKbReferenceTitles();
    expect([...capabilities!.policy.kb_topics].sort()).toEqual([...liveTitles].sort());
  });

  it("every tool entry has non-empty answers or a non-empty cannot_answer/needs explanation", () => {
    const capabilities = loadCarolineToolCapabilities();
    for (const tool of capabilities!.tools) {
      const hasAnswers = tool.answers.length > 0;
      const hasExplanation = tool.cannot_answer.length > 0 || (tool.needs && tool.needs.length > 0);
      expect(hasAnswers || hasExplanation).toBe(true);
    }
  });

  it("loadCarolineIntents still resolves (sanity: caroline-inventory.json is readable, not just tool names)", () => {
    expect(loadCarolineIntents().length).toBeGreaterThan(0);
  });
});
