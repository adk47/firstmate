import { describe, it, expect, vi } from "vitest";

describe("support-tools plugin entry", () => {
  it("exports a default plugin definition with correct id and name", async () => {
    const mod = await import("../src/index.js");
    const plugin = mod.default;

    expect(plugin).toBeDefined();
    expect(plugin.id).toBe("support-tools");
    expect(plugin.name).toBe("Support Agent Tools");
  });
});
