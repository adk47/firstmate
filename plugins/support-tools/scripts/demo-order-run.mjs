// Demo-workspace order-address run (captain inbox 024). STUBS, named: Intercom reader,
// order store and actor. REAL: gate, policy fixture, ledger sink, claim store, revert.
import { readFileSync } from "node:fs";
import { createSupportIntentTool } from "../dist/support-intent.js";
import { fileLedger } from "../dist/support-intent-ledger.js";
import { captureAddress, restoreAddress } from "../dist/order-address-revert.js";

const base = JSON.parse(readFileSync(new URL("../../../policies/support-intent-policy.json", import.meta.url), "utf8"));
const policy = { ...base, intents: { ...base.intents, order_address_update: { ...base.intents.order_address_update, enabled: true, order_scoped: true, params_shape: { address: "address" } } } };
const LEDGER = process.env.PROOF_LEDGER ?? "/tmp/support-intent-demo/order-ledger.jsonl";
const TEAM = "0c519893-ec5a-4ffd-95d8-d5ab050d5aa3";
const ORDER = "ord-demo-1";
const PRIOR = { name: "Demo Customer", phone: "+15550000001", line1: "1 Old Road", line2: "Unit 4", city: "Springfield", state: "IL", postcode: "62701", country: "US" };
const NEW = { ...PRIOR, line1: "123 Demo Street", line2: "", city: "Shelbyville" };
let current = { ...PRIOR };
const store = { read: async () => ({ ...current }), write: async (_r, v) => { current = { ...v }; } };
const PART = { id: "msg-demo-2", snippet: "please update my shipping address to 123 Demo Street, Shelbyville, 62701" };

const captured = await captureAddress(store, ORDER);
const tool = createSupportIntentTool({
  intercomReader: { getAuthorEmail: async () => "demo@muso.ai", getLatestCustomerPart: async () => PART, findBotMarkerInOtherConversations: async () => "not_found" },
  intercomToken: "stub", conversationId: "conv-demo-2", policy: () => policy,
  recordCheck: async () => ({ allowed: true, state: "active", teamId: TEAM, orderRef: ORDER, ownerEmail: "demo@muso.ai" }),
  actors: { order_address_update: { name: "caroline.support-executor", run: async (i) => { await store.write(i.orderRef, NEW); return { content: [{ type: "text", text: JSON.stringify({ ok: true, stub: true, order: i.orderRef }) }], details: {} }; } } },
  ledger: (row) => fileLedger(LEDGER).append(row),
  claims: { claim: async () => true },
});
const res = await tool.execute("demo-2", { intent: "order_address_update", confirmation_ref: PART.id, params: { address: "123 Demo Street, Shelbyville, 62701" } });
console.log("RESULT", res.content[0].text);
console.log("AFTER_WRITE", JSON.stringify(current));
const rev = await restoreAddress(store, captured);
console.log("REVERT", JSON.stringify(rev));
console.log("AFTER_REVERT", JSON.stringify(current));
