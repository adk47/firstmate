import { describe, it, expect } from "vitest";
import { createSubscriptionStatusTool } from "../src/tools/subscription-status.js";

describe("createSubscriptionStatusTool", () => {
  it("returns stub message suggesting ticket creation", async () => {
    const tool = createSubscriptionStatusTool();
    const result = await tool.execute("call_1", {});
    const text = (result.content[0] as { type: "text"; text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed.message).toContain("not yet available");
    expect(parsed.suggestTicket).toBe(true);
  });

  it("accepts optional query parameter without error", async () => {
    const tool = createSubscriptionStatusTool();
    const result = await tool.execute("call_1", { query: "when does my plan renew?" });
    expect(result.content).toHaveLength(1);
  });
});
