import { describe, expect, it } from "vitest";
import { createSupportActionRouterTool, SUPPORT_ACTION_ROUTES } from "../src/tools/support-action-router.js";

async function call(params: Record<string, unknown>) {
  const tool = createSupportActionRouterTool();
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as { type: "text"; text: string }).text);
}

describe("support_action_router", () => {
  it("lists every supported intent from the registry", () => {
    expect(Object.keys(SUPPORT_ACTION_ROUTES).sort()).toEqual([
      "account_profile_change",
      "analytics_data_complaint",
      "billing_cancel_refund",
      "catalog_metadata_repair",
      "credit_verification",
      "founding_member",
      "login_email_verification",
      "order_fulfillment",
      "profile_claim",
      "profile_duplicates",
      "remove_wrong_credits",
    ]);
  });

  it("routes credit verification to the read check first, then preview/apply", async () => {
    const start = await call({ intent: "credit_verification" });
    expect(start.ok).toBe(true);
    expect(start.availability).toBe("live");
    expect(start.next).toMatchObject({
      outcome: "run_skill",
      skill: "customer-credit-verification",
      tool: "credit_verification_check",
    });
    expect(start.live_tools.write).toEqual(["credits_verify"]);

    const preview = await call({ intent: "credit_verification", state: "preview_ok" });
    expect(preview.next).toMatchObject({
      outcome: "ask_confirmation",
      tool: "credits_verify",
    });

    const confirmed = await call({ intent: "credit_verification", state: "customer_confirmed" });
    expect(confirmed.next).toMatchObject({
      outcome: "apply_tool",
      tool: "credits_verify",
    });
  });

  it("does not expose autonomous refund writes before scoped billing tools ship", async () => {
    const out = await call({ intent: "billing_cancel_refund", state: "read_ok" });
    expect(out.ok).toBe(true);
    expect(out.availability).toBe("partial");
    expect(out.live_tools.read).toEqual(["subscription_status"]);
    expect(out.live_tools.write).toEqual([]);
    expect(out.planned_tools).toEqual(["subscription_cancel", "refund_policy_check", "refund_create"]);
    expect(out.next).toMatchObject({
      outcome: "handoff",
      tool: "create_ticket",
      action_type: "subscription-refund",
    });
  });

  it("routes analytics complaints through the live analytics status resolver", async () => {
    const start = await call({ intent: "analytics_data_complaint" });
    expect(start.ok).toBe(true);
    expect(start.availability).toBe("live");
    expect(start.live_tools.read).toEqual(["profile_status", "subscription_status", "profile_analytics_status"]);
    expect(start.planned_tools).toEqual(["track_analytics_status", "analytics_refresh_request", "analytics_recheck"]);
    expect(start.next).toMatchObject({
      outcome: "call_tool",
      tool: "profile_status",
    });

    const readOk = await call({ intent: "analytics_data_complaint", state: "read_ok" });
    expect(readOk.next).toMatchObject({
      outcome: "call_tool",
      tool: "profile_analytics_status",
    });
    expect(readOk.handoff_when).toContain("profile_analytics_status reports missing, stale, or inconsistent analytics");
  });

  it("turns refused self-service duplicate merges into profile-merge handoff packets", async () => {
    const out = await call({ intent: "profile_duplicates", state: "tool_refused" });
    expect(out.next).toMatchObject({
      outcome: "handoff",
      tool: "create_ticket",
      action_type: "profile-merge",
    });
    expect(out.human_gated_writes).toContain("cross-owner merge");
  });

  it("keeps raw execution and broad admin surfaces denied in every route", async () => {
    for (const intent of Object.keys(SUPPORT_ACTION_ROUTES)) {
      const out = await call({ intent });
      expect(out.denied_tools).toEqual(expect.arrayContaining(["exec", "muso api", "muso query", "raw_http", "db_write"]));
      expect(JSON.stringify(out.live_tools)).not.toMatch(/exec|muso api|muso query|raw_http|db_write/);
    }
  });
});
