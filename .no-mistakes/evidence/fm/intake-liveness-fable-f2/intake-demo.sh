#!/usr/bin/env bash
# End-to-end demo of .pi/extensions/fm-captain-intake.ts in a plain Node host
# with a stub `pi`: a captain prompt typed while a turn is running becomes a
# durable record and a follow-up (never a steer), then is consumed and moved.
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7M2RCQZKTS196CTVGCY9W11
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake-demo.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
: > "$HOME_DIR/config/captain-intake"

FM_HOME="$HOME_DIR" EXT_PATH="$ROOT/.pi/extensions/fm-captain-intake.ts" NODE_NO_WARNINGS=1 \
node --input-type=module <<'EOF'
import { readdirSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
const handlers = {};
const commands = {};
const queued = [];
const pi = {
  on(name, fn) { handlers[name] = fn; },
  registerCommand(name, spec) { commands[name] = spec; },
  async sendUserMessage(text, options) { queued.push({ text, deliverAs: options?.deliverAs }); },
};
const ctx = {
  ui: {
    notify(message, type) { console.log(`[${type || "info"}] ${message}`); },
    setStatus(key, text) { console.log(`[status] ${key}: ${text ?? "(cleared)"}`); },
  },
  sessionManager: { getSessionId: () => "demo-session" },
};
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
mod.default(pi);
await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);

const type = (text) => handlers.input({ type: "input", text, source: "interactive", streamingBehavior: "steer" }, ctx);

console.log("--- captain types while the turn is running:");
console.log(await type("please also fix the footer"));
console.log(await type("and update the nav copy"));
console.log();
console.log("--- what Pi was asked to queue (deliverAs):");
for (const [i, q] of queued.entries()) console.log(`#${i + 1} deliverAs=${q.deliverAs}\n${q.text}\n`);
console.log("--- durable records on disk:");
for (const name of readdirSync(`${home}/state/intake`).filter((n) => n.endsWith(".prompt")).sort()) {
  console.log(`state/intake/${name}:\n${readFileSync(`${home}/state/intake/${name}`, "utf8")}`);
}
console.log("--- Pi starts the queued run and consumes intake #1 (exact wrapped text):");
await handlers.message_start({ type: "message_start", message: { role: "user", content: [{ type: "text", text: queued[0].text }] } }, ctx);
console.log("state/intake:", readdirSync(`${home}/state/intake`).filter((n) => n.endsWith(".prompt")).sort().join(" ") || "(empty)");
console.log("state/intake/handled:", readdirSync(`${home}/state/intake/handled`).sort().join(" "));
console.log();
console.log("--- /intake listing:");
await commands.intake.handler("", ctx);
EOF
