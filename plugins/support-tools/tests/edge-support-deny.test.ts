import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Captain 2026-10-28 12:1xZ / 12:3xZ: Caroline (edge agent `support`) keeps her look-up, billing,
// subscription, order, founding, retention and ticket tools, but NOTHING that verifies, claims,
// merges, dedupes, removes credits or files proof; that work is reached by a hand-off. Every hydra
// deploy rewrites the live /root/.openclaw-edge/openclaw.json from this repo file, so the deny list
// must live HERE or each deploy hands the tools back (it did at 16:0xZ and 16:55Z on 10-28).
// support-tools also loads on the main gateway; these tools are denied to `support` only.
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../../..");
const edge = JSON.parse(readFileSync(resolve(root, "openclaw-edge.json"), "utf8"));
const support = (edge.agents?.list ?? []).find((a: any) => a.id === "support");
const deny: string[] = support?.tools?.deny ?? [];

const SUPPORT_DENY = [
  "exec",
  "credits_verify", "credit_verification_check", "profiles_claim_self", "profiles_consolidate",
  "profile_claim_status", "profile_credits_status", "dedupe_check", "remove_credits",
  "credit_status_lookup", "document_intake", "merge_request_intake", "credit_trust_handoff",
  "merge_intake", "proof_on_file",
];
// Kept on Caroline by the captain's 12:3xZ clarification (Nick's pre-existing tools).
const KEPT = [
  "create_ticket", "support_action_router", "profile_lookup", "credits_search", "profile_status",
  "profile_analytics_status", "order_lookup", "order_address_update", "subscription_status",
  "billing_status", "founding_status", "founding_buyback_link", "retention_offer_check",
  "retention_offer_apply", "cancel_subscription", "company_finder_prep", "company_finder_finalize",
];

describe("openclaw-edge.json: Caroline hands off verification and merging", () => {
  it("denies exec and all 14 verification / claim / merge / proof tools to the support agent", () => {
    expect(support).toBeTruthy();
    for (const t of SUPPORT_DENY) expect(deny, t).toContain(t);
  });

  it("keeps her pre-existing look-up, billing, order, founding, retention and ticket tools", () => {
    for (const t of KEPT) expect(deny, t).not.toContain(t);
  });

  it("any registered support-tools tool whose name reads as verification or merging is denied to her", () => {
    const src = readFileSync(resolve(here, "../src/index.ts"), "utf8");
    const names = [...src.matchAll(/name:\s*"([a-z_]+)"/g)].map((m) => m[1]);
    expect(names.length).toBeGreaterThan(10);
    for (const n of names.filter((x) => /verif|claim_|_claim|consolidat|dedupe|merge|proof|remove_credit/.test(x))) {
      expect(deny, n).toContain(n);
    }
  });
});
