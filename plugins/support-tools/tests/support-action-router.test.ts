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

  it("routes profile claims through the read-only claim-status resolver first", async () => {
    const start = await call({ intent: "profile_claim" });
    expect(start.ok).toBe(true);
    expect(start.live_tools.read).toContain("profile_claim_status");
    expect(start.next).toMatchObject({
      outcome: "run_skill",
      skill: "customer-profile-claim",
      tool: "profile_claim_status",
    });
    // The resolver discovers the claim id now — it is no longer missing info.
    expect(start.missing_info).toEqual(["Profile URL"]);

    const readOk = await call({ intent: "profile_claim", state: "read_ok" });
    expect(readOk.next).toMatchObject({ outcome: "call_tool", tool: "profiles_claim_self" });

    const accountChange = await call({ intent: "account_profile_change" });
    expect(accountChange.live_tools.read).toContain("profile_claim_status");
  });

  it("exposes the live retention/cancel trio but keeps refunds handoff-only", async () => {
    const out = await call({ intent: "billing_cancel_refund", state: "read_ok" });
    expect(out.ok).toBe(true);
    expect(out.availability).toBe("partial");
    expect(out.live_tools.read).toEqual(["subscription_status", "retention_offer_check", "billing_status"]);
    expect(out.live_tools.write).toEqual(["retention_offer_apply", "cancel_subscription"]);
    // The refund WRITE stays planned — money out is the human/Operations path.
    // (refund_policy_check was retired: billing_status now delivers that read.)
    expect(out.planned_tools).toEqual(["refund_create"]);
    expect(out.next).toMatchObject({
      outcome: "call_tool",
      tool: "retention_offer_check",
    });

    const confirmed = await call({ intent: "billing_cancel_refund", state: "customer_confirmed" });
    expect(confirmed.next).toMatchObject({ outcome: "apply_tool", tool: "cancel_subscription" });
    expect(confirmed.next.instruction).toContain("Never call cancel on the refund branch");

    const refused = await call({ intent: "billing_cancel_refund", state: "tool_refused" });
    expect(refused.next).toMatchObject({ outcome: "handoff", tool: "create_ticket" });
    // Failure states no longer force the Tier-3 refund queue: a charge complaint
    // whose billing_status fails must be able to file the Tier-2 billing-issue
    // ticket, so no single action_type is hardcoded — the agent picks by request.
    expect(refused.next.action_type).toBeUndefined();
    expect(refused.next.instruction).toContain("billing-issue");
    expect(refused.next.instruction).toContain("subscription-refund");
  });

  it("billing failure states do not misroute charge complaints into the Tier-3 refund queue", async () => {
    for (const state of ["tool_refused", "tool_disabled", "loop_detected"]) {
      const out = await call({ intent: "billing_cancel_refund", state });
      expect(out.next.outcome).toBe("handoff");
      expect(out.next.tool).toBe("create_ticket");
      // request-appropriate action_type, not a hardcoded subscription-refund
      expect(out.next.action_type).toBeUndefined();
      expect(out.next.instruction).toMatch(/billing-issue \(Tier 2\)/);
      expect(out.next.instruction).toMatch(/subscription-refund \(Tier 3\)/);
    }
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

  it("exposes profile_credits_status as a live read on the credit/profile routes", async () => {
    for (const intent of ["credit_verification", "profile_claim", "profile_duplicates", "remove_wrong_credits", "catalog_metadata_repair"]) {
      const out = await call({ intent });
      expect(out.live_tools.read).toContain("profile_credits_status");
    }

    // catalog read_ok now diagnoses a referenced credit before filing.
    const catalogReadOk = await call({ intent: "catalog_metadata_repair", state: "read_ok" });
    expect(catalogReadOk.next).toMatchObject({ outcome: "call_tool", tool: "profile_credits_status" });
  });

  it("keeps raw execution and broad admin surfaces denied in every route", async () => {
    for (const intent of Object.keys(SUPPORT_ACTION_ROUTES)) {
      const out = await call({ intent });
      expect(out.denied_tools).toEqual(expect.arrayContaining(["exec", "muso api", "muso query", "raw_http", "db_write"]));
      expect(JSON.stringify(out.live_tools)).not.toMatch(/exec|muso api|muso query|raw_http|db_write/);
    }
  });
});
