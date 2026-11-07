/**
 * Run the plugin's OWN output guard (`plugins/intercom/src/caroline-output-guard.ts`) on one reply.
 *
 * stdin  : JSON {reply, customerText?, customerNames?, customerEmails?, openRequest?}
 * stdout : JSON {ok, verdict, blocked, body, mode, guardVersion, bankVersion, flags[]}
 *          or, with `--bank`, {ok, bankVersion, entries: [{id, intents, requiresFact, text}]}
 *
 * Exit codes: 0 always when the guard RAN (its verdict is in the payload — a block is not an
 * error). 2 when the guard could not be loaded, so the caller fails CLOSED (nothing is sent) and
 * says why. Never exit 0 with an implicit "pass".
 *
 * Look at the reply, not the process: `verdict: "block"` is a normal, expected outcome.
 */
import { createInterface } from "node:readline";

async function readStdin() {
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let buf = "";
  for await (const line of rl) buf += `${line}\n`;
  return buf;
}

function fail(message) {
  process.stdout.write(`${JSON.stringify({ ok: false, error: message })}\n`);
  process.exit(2);
}

const bankMode = process.argv.includes("--bank");

const guardPath = new URL("../../plugins/intercom/src/caroline-output-guard.ts", import.meta.url).href;
const bankPath = new URL("../../plugins/intercom/src/answer-bank.ts", import.meta.url).href;

const guard = await import(guardPath).catch((e) => fail(`cannot load ${guardPath}: ${e.message}`));

if (bankMode) {
  const bank = await import(bankPath).catch((e) => fail(`cannot load ${bankPath}: ${e.message}`));
  const entries = (bank.ANSWER_BANK || []).map((e) => ({
    id: e.id,
    intents: e.intents || [],
    requiresFact: e.requiresFact || null,
    lead: e.lead || null,
    text: e.text,
  }));
  process.stdout.write(`${JSON.stringify({ ok: true, bankVersion: bank.BANK_VERSION, entries })}\n`);
  process.exit(0);
}

let input;
try {
  const raw = await readStdin();
  input = JSON.parse(raw || "{}");
} catch (e) {
  fail(`stdin is not JSON: ${e.message}`);
}

if (typeof input.reply !== "string") fail("input.reply is required (string)");

const facts = typeof input.openRequest === "boolean" ? { openRequest: input.openRequest } : undefined;

let result;
try {
  result = guard.guardCarolineReply({
    reply: input.reply,
    customerText: input.customerText || "",
    customerNames: input.customerNames || [],
    customerEmails: input.customerEmails || [],
    facts,
  });
} catch (e) {
  fail(`guardCarolineReply threw: ${e.message}`);
}

process.stdout.write(
  `${JSON.stringify({
    ok: true,
    verdict: result.verdict,
    blocked: result.verdict !== "pass",
    body: result.body,
    mode: result.mode,
    guardVersion: result.guardVersion,
    bankVersion: result.bankVersion,
    flags: (result.flags || []).map((f) => ({ family: f.family, rule: f.rule, excerpt: f.excerpt })),
  })}\n`,
);
process.exit(0);
