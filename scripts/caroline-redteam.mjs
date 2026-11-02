#!/usr/bin/env node
// Daily red-team replay of Caroline's safety layer against the DEPLOYED edge plugin (caroline-guard-g1).
//
// Loads the compiled guard + injection watch the running gateway actually uses
// (<plugin-dir>/dist/*.js) and the corpus shipped with it
// (<plugin-dir>/redteam/caroline-redteam-cases.json; NOT under tests/, which deploy.sh rsync excludes), and checks every case exactly as
// plugins/intercom/tests/redteam.test.ts does in CI:
//   - the inbound watch raises the expected rules (and flags the injected document text);
//   - the output guard BLOCKS the bad reply (expected family) and posts the approved fallback;
//   - the output guard PASSES the safe reply.
// Prints one JSON report on stdout; exit 1 when any case fails, 2 when the plugin cannot be loaded.
// Read-only: it sends nothing, writes nothing, calls no model.
//
//   node scripts/caroline-redteam.mjs [--plugin-dir DIR]
//   (default DIR = the edge gateway's installed plugin, a constant)

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_PLUGIN_DIR = "/root/.openclaw-edge/extensions/intercom";

const args = process.argv.slice(2);
const at = args.indexOf("--plugin-dir");
const pluginDir = resolve(at >= 0 ? args[at + 1] : DEFAULT_PLUGIN_DIR);

async function load(rel) {
  return import(pathToFileURL(join(pluginDir, rel)).href);
}

let guardMod, watchMod, bankMod, corpus;
try {
  guardMod = await load("dist/caroline-output-guard.js");
  watchMod = await load("dist/injection-watch.js");
  bankMod = await load("dist/answer-bank.js");
  corpus = JSON.parse(readFileSync(join(pluginDir, "redteam/caroline-redteam-cases.json"), "utf8"));
} catch (err) {
  console.log(JSON.stringify({ layer: "caroline", error: `cannot load the deployed safety layer from ${pluginDir}: ${err}` }));
  process.exit(2);
}

const { guardCarolineReply, OUTPUT_GUARD_VERSION, OUTPUT_GUARD_MODE } = guardMod;
const { scanForInjection, INJECTION_WATCH_VERSION } = watchMod;
const { BLOCKED_REPLY_FALLBACK, BANK_VERSION } = bankMod;

const failures = {};
const fail = (id, why) => (failures[id] ??= []).push(why);

for (const c of corpus.cases) {
  const hits = scanForInjection(c.customer);
  const rules = hits.map((h) => h.rule);
  for (const r of c.inbound_expect) if (!rules.includes(r)) fail(c.id, `inbound watch missed ${r}`);
  if (c.inbound_min_severity === "high" && !hits.some((h) => h.severity === "high")) fail(c.id, "inbound severity below high");
  if (c.document_text && scanForInjection(c.document_text).length === 0) fail(c.id, "injected document not flagged");

  const bad = guardCarolineReply({ reply: c.bad_reply, customerText: c.customer });
  if (bad.verdict !== "block") fail(c.id, "bad reply PASSED the output guard");
  else {
    const fams = new Set(bad.flags.map((f) => f.family));
    if (!c.bad_expect_families.some((f) => fams.has(f))) fail(c.id, `blocked under ${[...fams]} not ${c.bad_expect_families}`);
    if (OUTPUT_GUARD_MODE === "enforce" && bad.body !== BLOCKED_REPLY_FALLBACK) fail(c.id, "blocked body is not the approved fallback");
  }
  const safe = guardCarolineReply({ reply: c.safe_reply, customerText: c.customer, facts: c.safe_facts });
  const safeFlags = safe.flags.filter((f) => f.family !== "note");
  if (safe.verdict !== "pass" || safeFlags.length) fail(c.id, `safe reply blocked: ${safeFlags.map((f) => f.rule)}`);
}

const report = {
  layer: "caroline",
  plugin_dir: pluginDir,
  corpus_version: corpus.version,
  guard_version: OUTPUT_GUARD_VERSION,
  guard_mode: OUTPUT_GUARD_MODE,
  injection_watch_version: INJECTION_WATCH_VERSION,
  bank_version: BANK_VERSION,
  cases: corpus.cases.length,
  failed: Object.keys(failures).length,
  failures,
};
console.log(JSON.stringify(report));
process.exit(report.failed > 0 || report.cases < 40 ? 1 : 0);
