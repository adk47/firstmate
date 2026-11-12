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
  "credits_verify", "profiles_claim_self", "profiles_consolidate",
  "profile_credits_status", "dedupe_check", "remove_credits",
  "credit_status_lookup", "document_intake", "merge_request_intake", "credit_trust_handoff",
  "merge_intake", "proof_on_file",
];
// ai-support-quality-v1 (2026-11-12): TWO reads are hers again. Measured over 24h: 146 of 417
// conversations did not close because she could not read the customer's own request state, and 56
// more because the output guard needs a code-measured open_request fact that these reads write
// (data/ai-support-quality-v1/report.md). Both FAIL CLOSED unless the conversation has a signed-in
// contact (owner-anchor.ts) and return that contact's own rows only: a profile link typed in the
// thread can choose which profile is looked at, never whose rows come back.
// profile_credits_status is NOT one of them. It degrades instead of failing closed, resolves any
// profile by a typed id or name, and scans same-name duplicate candidates: that is the dedupe work
// the captain's ruling above keeps away from her, so it stays denied.
// The names are listed one by one on purpose: a NEW tool whose name reads as verification is still
// denied by the third test until someone adds it to this list in a reviewed change.
const OWN_ROW_READS = ["credit_verification_check", "profile_claim_status"];
// Kept on Caroline by the captain's 12:3xZ clarification (Nick's pre-existing tools).
const KEPT = [
  "create_ticket", "support_action_router", "profile_lookup", "credits_search", "profile_status",
  "profile_analytics_status", "order_lookup", "order_address_update", "subscription_status",
  "billing_status", "founding_status", "founding_buyback_link", "retention_offer_check",
  "retention_offer_apply", "cancel_subscription", "company_finder_prep", "company_finder_finalize",
];

describe("openclaw-edge.json: Caroline hands off verification and merging", () => {
  it("denies exec and the 12 verification / claim / merge / proof tools to the support agent", () => {
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
      if (OWN_ROW_READS.includes(n)) continue;
      expect(deny, n).toContain(n);
    }
  });

  it("the two own-row reads are allowed, and they are reads: none of them is a write tool", () => {
    for (const t of OWN_ROW_READS) {
      expect(deny, t).not.toContain(t);
      expect(SUPPORT_DENY, t).not.toContain(t);
    }
    expect(OWN_ROW_READS).toHaveLength(2);
    // The write twins, and the diagnosis that scans duplicates, stay denied by name.
    for (const t of ["credits_verify", "profiles_claim_self", "profiles_consolidate", "remove_credits", "profile_credits_status", "dedupe_check"]) {
      expect(deny, t).toContain(t);
    }
  });

  it("each own-row read FAILS CLOSED without a signed-in contact and never calls a write verb", () => {
    for (const f of ["credit-verification-check.ts", "profile-claim-status.ts"]) {
      const src = readFileSync(resolve(here, "../src/tools", f), "utf8");
      expect(src, f).toMatch(/resolveOwnerAnchor\(/);
      // Not just "reads the anchor": an anchor that did not resolve returns the fail-closed verdict
      // before any admin read. profile-credits-status.ts does not have this shape (it carries on
      // with `owner_undetermined`), which is exactly why it is not in OWN_ROW_READS.
      expect(src, f).toMatch(/if \(!anchor\.ok\) \{\s*return textResult\(JSON\.stringify\(failClosedVerdict\(/);
      const run = src.slice(src.indexOf("async execute("));
      const beforeGate = run.slice(0, run.indexOf("if (!anchor.ok)"));
      expect(beforeGate.length, f).toBeGreaterThan(0);
      expect(beforeGate, f).not.toMatch(/adminClient\.get|fetchProfile\(|fetchUvnCredits\(|fetchAwaitingReview\(|resolveOwnedProfileId\(/);
      expect(src, f).not.toMatch(/\.(?:put|post|patch|delete)\(/i);
      expect(src, f).not.toMatch(/method:\s*"(?:PUT|POST|PATCH|DELETE)"/);
    }
  });
});
