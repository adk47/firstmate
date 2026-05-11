import { describe, it, expect } from "vitest";
import { createSubscriptionStatusTool } from "../src/tools/subscription-status.js";

describe("createSubscriptionStatusTool", () => {
  it("returns structured not-implemented JSON", async () => {
    const tool = createSubscriptionStatusTool();
    const result = await tool.execute("call_1", {});
    const text = (result.content[0] as { type: "text"; text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed.ok).toBe(false);
    expect(parsed.reason).toBe("not_implemented");
    expect(parsed.suggest_followup).toBe(true);
  });

  it("accepts optional query parameter without error", async () => {
    const tool = createSubscriptionStatusTool();
    const result = await tool.execute("call_1", { query: "when does my plan renew?" });
    expect(result.content).toHaveLength(1);
  });
});
