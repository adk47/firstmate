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

  // Captain 2026-10-28: Caroline only hands off on credits, documents, claims, removals and
  // merges. QA on #1451: the router must never send her to a denied tool or a removed skill.
  const RETIRED_TOOLS = ["credit_verification_check", "credits_verify", "profiles_claim_self", "profiles_consolidate",
    "profile_claim_status", "profile_credits_status", "dedupe_check", "remove_credits"];
  const RETIRED_SKILLS = ["customer-credit-verification", "customer-profile-claim", "customer-profile-consolidate",
    "customer-profile-dedupe", "customer-track-dedupe", "customer-credit-removal"];
  const HANDOFF: Record<string, string> = {
    credit_verification: "credit-verify", profile_claim: "profile-claim",
    profile_duplicates: "profile-merge", remove_wrong_credits: "credit-correction",
  };
  const STATES = ["new_request", "read_ok", "preview_ok", "customer_confirmed", "applied_ok", "tool_refused", "tool_disabled", "loop_detected"];

  it("every state of the verification/merge routes is the verification-handoff ticket of its kind", async () => {
    for (const [intent, kind] of Object.entries(HANDOFF)) {
      for (const state of STATES) {
        const out = await call({ intent, state });
        expect(out.next, `${intent}/${state}`).toMatchObject({
          outcome: "run_skill", skill: "verification-handoff", tool: "create_ticket", action_type: kind,
        });
        expect(out.next.instruction).toMatch(/no look-up/);
        expect(out.next.instruction).toMatch(/Never say you checked, filed, verified or merged/);
      }
      const ask = await call({ intent, state: "missing_info" });
      expect(ask.next.outcome).toBe("ask_missing_info");
      expect(ask.next.instruction).toContain(kind);
      expect(ask.live_tools).toEqual({ read: [], write: [], handoff: ["create_ticket"] });
    }
  });

  it("no route names a retired verification/merge tool or skill, in any state or field", () => {
    const blob = JSON.stringify(SUPPORT_ACTION_ROUTES);
    for (const name of [...RETIRED_TOOLS, ...RETIRED_SKILLS]) expect(blob).not.toContain(name);
  });

  it("catalog repair no longer diagnoses a credit itself; a credit question is a hand-off", async () => {
    const out = await call({ intent: "catalog_metadata_repair", state: "read_ok" });
    expect(out.next).toMatchObject({ outcome: "handoff", tool: "create_ticket" });
    expect(out.next.instruction).toContain("verification-handoff");
  });

  it("keeps raw execution and broad admin surfaces denied in every route", async () => {
    for (const intent of Object.keys(SUPPORT_ACTION_ROUTES)) {
      const out = await call({ intent });
      expect(out.denied_tools).toEqual(expect.arrayContaining(["exec", "muso api", "muso query", "raw_http", "db_write"]));
      expect(JSON.stringify(out.live_tools)).not.toMatch(/exec|muso api|muso query|raw_http|db_write/);
    }
  });
});
