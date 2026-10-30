#!/usr/bin/env node
// Replays real Caroline merge conversations through the outbound merge-reply guard
// (plugins/intercom/src/merge-reply-guard.ts) exactly as channel.ts runs it per turn, carrying
// the per-conversation state (mergeIntentAt, mergeParagraphSentAt), and checks the outcome:
//   - every merge conversation ends up with the approved §2.4 paragraph EXACTLY once;
//   - no reply carries a merge judgement ("shouldn't be merged", "I can merge", ...);
//   - no reply to a turn carrying only profile links keeps the §2.2 document thank-you;
//   - the controls (billing, a track merge, a real document) are left untouched.
// Run: node --experimental-strip-types scripts/caroline-merge-guard-eval.mjs [fixture.json]
// Exit 0 = all pass, 1 = a failure (each printed), 2 = harness/input error.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const guardPath = process.env.MERGE_GUARD_SRC || resolve(root, "plugins/intercom/src/merge-reply-guard.ts");
const fixturePath = process.argv[2] || resolve(root, "plugins/intercom/tests/fixtures/caroline-merge-transcripts-1030.json");

let guard, fx;
try {
  guard = await import(guardPath);
  fx = JSON.parse(readFileSync(fixturePath, "utf8"));
} catch (e) {
  console.error(`harness error: ${e.message}`);
  process.exit(2);
}
const { applyMergeReplyGuard, prepareMergeReply, findJudgements, MERGE_PARAGRAPH } = guard;
const KEY = MERGE_PARAGRAPH.slice(0, 60);
const DOC = "Everything you send here is recorded against your account";
const count = (s, sub) => s.split(sub).length - 1;

let failures = 0;
const fail = (msg) => { failures++; console.log(`FAIL ${msg}`); };

for (const conv of fx.conversations ?? []) {
  // The same send-boundary helper channel.ts uses; every replayed reply counts as delivered.
  const state = { mergeIntentAt: null, mergeParagraphSentAt: null };
  let paragraphs = 0;
  for (const [i, t] of conv.turns.entries()) {
    const prep = prepareMergeReply(state, t.customer, t.reply, `turn${i}`);
    const out = { ...prep.result, body: prep.body };
    prep.commit(true);
    paragraphs += count(out.body, KEY);
    if (/(?:^|\s)ai\/profile\//.test(out.body)) fail(`${conv.id} turn ${i}: a broken URL fragment was delivered`);
    // every occurrence of the approved opening must be the exact paragraph
    if (count(out.body, "Merges work like this") !== count(out.body, MERGE_PARAGRAPH))
      fail(`${conv.id} turn ${i}: a non-exact §2.4 variant was delivered`);
    if (findJudgements(out.body).length) fail(`${conv.id} turn ${i}: judgement left in reply: ${JSON.stringify(out.body)}`);
    if (out.mergeIntent && out.body.includes(DOC) && /muso\.ai\/profile\//.test(t.customer))
      fail(`${conv.id} turn ${i}: §2.2 document thank-you left on a profile-link turn`);
    if (process.env.MERGE_GUARD_VERBOSE) console.log(`--- ${conv.id} turn ${i} [${out.actions.join(",")}]\n${out.body}`);
  }
  // expectParagraphs: 0 marks a thread with no recognisable merge ask (e.g. a bare profile link);
  // every other conversation must carry §2.4 exactly once.
  const want = conv.expectParagraphs ?? 1;
  if (paragraphs !== want) fail(`${conv.id}: §2.4 sent ${paragraphs} times across the conversation (want exactly ${want})`);
  else console.log(`ok ${conv.id}: §2.4 ${want === 1 ? "exactly once" : "not sent (no merge ask)"}, no judgement (${conv.why})`);
}

for (const c of fx.controls ?? []) {
  const out = applyMergeReplyGuard({ customerText: c.customer, reply: c.reply, paragraphAlreadySent: false });
  if (out.body !== c.reply) fail(`control changed (${c.why}): ${JSON.stringify(out.body)}`);
  else console.log(`ok control untouched: ${c.why}`);
}

console.log(failures ? `${failures} failure(s)` : "OK: merge-reply guard passes every transcript");
process.exit(failures ? 1 : 0);
