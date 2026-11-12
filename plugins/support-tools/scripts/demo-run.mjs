// Demo-workspace run of the reader/actor gate (captain inbox 020).
// STUBS, named: the Intercom reader and the actor are stubs. The gate, the policy,
// the ledger sink and the claim store are the real ones.
import { readFileSync } from "node:fs";
import { createSupportIntentTool } from "../dist/support-intent.js";
import { fileLedger } from "../dist/support-intent-ledger.js";

const policy = JSON.parse(readFileSync(new URL("../../../policies/support-intent-policy.json", import.meta.url), "utf8"));
const LEDGER = process.env.PROOF_LEDGER ?? "/tmp/support-intent-demo/ledger.jsonl";
const TEAM = "0c519893-ec5a-4ffd-95d8-d5ab050d5aa3"; // demo@muso.ai, resolved by `muso teams list --email`
const PART = { id: "msg-demo-1", snippet: "yes please apply the offer save50 to my plan" };

const calls = [];
const tool = createSupportIntentTool({
  intercomReader: {
    getAuthorEmail: async () => "demo@muso.ai",
    getLatestCustomerPart: async () => PART,
    findBotMarkerInOtherConversations: async () => "not_found",
  },
  intercomToken: "stub",
  conversationId: "conv-demo-1",
  policy: () => policy,
  recordCheck: async () => ({ allowed: true, state: "active", teamId: TEAM }),
  actors: {
    retention_offer_apply: {
      name: "caroline.support-executor",
      run: async (input) => {
        calls.push(input);
        return { content: [{ type: "text", text: JSON.stringify({ ok: true, stub: true, team_id: input.teamId }) }], details: {} };
      },
    },
  },
  ledger: (row) => fileLedger(LEDGER).append(row),
  claims: { claim: async () => true },
});

const res = await tool.execute("demo-1", { intent: "retention_offer_apply", confirmation_ref: PART.id, params: { offer_code: "save50" } });
console.log("RESULT", res.content[0].text);
console.log("ACTOR_INPUT", JSON.stringify(calls[0]));
console.log("LEDGER", LEDGER);
