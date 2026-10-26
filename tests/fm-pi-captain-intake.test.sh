#!/usr/bin/env bash
# Behavior tests for the tracked Pi captain-intake extension
# (.pi/extensions/fm-captain-intake.ts): every captain prompt typed while a
# turn is running becomes a durable record and a follow-up, the current turn is
# never steered, consumption and abort move the record, and nothing typed is
# lost across a settle or a session replacement.
#
# The extension is loaded in a plain Node host with a stub `pi` whose
# sendUserMessage records what Pi would have queued, so the queue decision, the
# record layout, and every transition are exercised with no live Pi session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-captain-intake)
EXT="$ROOT/.pi/extensions/fm-captain-intake.ts"
export NODE_NO_WARNINGS=1

new_home() {  # <name> [enabled]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  [ "${2:-on}" = off ] || : > "$home/config/captain-intake"
  printf '%s' "$home"
}

# drive <home> <scenario> [args...]: load the extension against <home>, run one
# scenario, and print one JSON object describing what Pi was asked to queue
# and what the input handler answered. Scenarios are named below.
drive() {
  local home=$1
  shift
  FM_HOME="$home" FM_INTAKE_RESEND_GRACE_MS="${FM_INTAKE_RESEND_GRACE_MS:-20}" EXT_PATH="$EXT" \
    node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const [scenario, ...args] = process.argv.slice(2);
const handlers = {};
const commands = {};
const queued = [];
const notices = [];
const statuses = [];
let failQueue = false;
const pi = {
  on(name, fn) { handlers[name] = fn; },
  registerCommand(name, spec) { commands[name] = spec; },
  async sendUserMessage(text, options) {
    if (failQueue) throw new Error("Cannot submit a prompt while compaction is in progress.");
    queued.push({ text, deliverAs: options && options.deliverAs });
  },
};
const ctx = {
  ui: {
    notify(message, type) { notices.push({ message, type: type || "info" }); },
    setStatus(key, text) { statuses.push({ key, text: text === undefined ? null : text }); },
  },
  sessionManager: { getSessionId: () => "sess-" + scenario },
};
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
mod.default(pi);
const input = (text, extra) => handlers.input({ type: "input", text, source: "interactive", streamingBehavior: "steer", ...extra }, ctx);
const results = [];
const settle = async (aborted) => {
  await handlers.agent_settled({ type: "agent_settled", aborted }, ctx);
  await new Promise((resolve) => setTimeout(resolve, 80));
};
await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
switch (scenario) {
  case "steer": results.push(await input(args[0])); break;
  case "three":
    for (const text of args) results.push(await input(text));
    break;
  case "passthrough":
    results.push(await input("/model"));
    results.push(await input("!ls"));
    results.push(await input("stop"));
    results.push(await input("Cancel that!"));
    results.push(await input("ship it", { streamingBehavior: undefined }));
    results.push(await input("ship it", { streamingBehavior: "followUp" }));
    results.push(await input("ship it", { source: "extension" }));
    results.push(await input("   "));
    break;
  case "consume-streaming":
    results.push(await input(args[0]));
    await handlers.message_start({ type: "message_start", message: { role: "user", content: [{ type: "text", text: queued[0].text }] } }, ctx);
    break;
  case "consume-idle":
    results.push(await input(args[0]));
    await handlers.before_agent_start({ type: "before_agent_start", messageType: "user", prompt: queued[0].text }, ctx);
    break;
  case "consume-other-text":
    results.push(await input(args[0]));
    await handlers.message_start({ type: "message_start", message: { role: "user", content: "something else" } }, ctx);
    await handlers.message_start({ type: "message_start", message: { role: "assistant", content: queued[0].text } }, ctx);
    break;
  case "abort":
    results.push(await input(args[0]));
    await settle(true);
    break;
  case "settle-unconsumed":
    results.push(await input(args[0]));
    await settle(false);
    break;
  case "settle-consumed":
    results.push(await input(args[0]));
    await handlers.message_start({ type: "message_start", message: { role: "user", content: queued[0].text } }, ctx);
    await settle(false);
    break;
  case "queue-refused":
    failQueue = true;
    results.push(await input(args[0]));
    break;
  case "session-start-only":
    break;
  case "command":
    await commands.intake.handler("", ctx);
    break;
  default: throw new Error("unknown scenario " + scenario);
}
console.log(JSON.stringify({ results, queued, notices, statuses, commands: Object.keys(commands) }));
EOF
}

field() {  # <json> <jq-expr>
  printf '%s' "$1" | jq -r "$2"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
}

test_flag_absent_keeps_native_steer() {
  local home out
  home=$(new_home off off)
  out=$(drive "$home" steer "please also fix the footer") || fail "drive failed: $out"
  [ "$(field "$out" '.results[0].action')" = continue ] || fail "with no flag the input must continue: $out"
  [ "$(field "$out" '.queued | length')" = 0 ] || fail "with no flag nothing is queued: $out"
  [ ! -d "$home/state/intake" ] || [ -z "$(ls "$home/state/intake" 2>/dev/null)" ] || fail "with no flag nothing is recorded"
  pass "with config/captain-intake absent every prompt keeps Pi's native steer and nothing is written"
}

test_mid_turn_prompt_becomes_record_and_follow_up() {
  local home out text rec
  home=$(new_home capture)
  text=$'please also fix the footer\nand the nav'
  out=$(drive "$home" steer "$text") || fail "drive failed: $out"
  [ "$(field "$out" '.results[0].action')" = handled ] || fail "a mid-turn prompt must be consumed by the extension: $out"
  [ "$(field "$out" '.queued | length')" = 1 ] || fail "exactly one follow-up must be queued: $out"
  [ "$(field "$out" '.queued[0].deliverAs')" = followUp ] || fail "the prompt must be re-delivered as a follow-up, never a steer: $out"
  case "$(field "$out" '.queued[0].text')" in
    "Firstmate intake #1 ("*"acknowledge it in one line, then handle it):"$'\n\n'"$text") : ;;
    *) fail "the follow-up must lead with one header line then the verbatim text: $(field "$out" '.queued[0].text')" ;;
  esac
  rec="$home/state/intake/1.prompt"
  assert_present "$rec" "the durable record was not written"
  head -n 1 "$rec" | grep -q '^schema=fm-captain-intake.v1$' || fail "record schema line missing"
  grep -q '^seq=1$' "$rec" || fail "record seq missing"
  grep -q '^session=sess-steer$' "$rec" || fail "record session missing"
  [ "$(sed -n '/^--$/,$p' "$rec" | tail -n +2)" = "$text" ] || fail "record body must be the verbatim captain text"
  [ "$(field "$out" '.notices | length')" = 1 ] || fail "exactly one acknowledgement notice is shown: $out"
  field "$out" '.notices[0].message' | grep -q '^intake #1 queued' || fail "the notice names the intake number: $out"
  [ "$(field "$out" '.statuses[-1].text')" = "intake: 1 queued" ] || fail "the status line shows one queued: $out"
  pass "a prompt typed mid-turn is recorded verbatim, re-delivered as one headed follow-up, and acknowledged in one line"
}

test_three_prompts_keep_their_order() {
  local home out
  home=$(new_home three)
  out=$(drive "$home" three "first" "second" "third") || fail "drive failed: $out"
  [ "$(field "$out" '[.results[].action] | join(" ")')" = "handled handled handled" ] || fail "all three must be captured: $out"
  [ "$(field "$out" '[.queued[].text | split("\n")[0] | split(" ")[2]] | join(" ")')" = "#1 #2 #3" ] \
    || fail "follow-ups must carry ascending intake numbers in typed order: $out"
  [ "$(field "$out" '[.queued[].text | split("\n\n")[1]] | join("|")')" = "first|second|third" ] \
    || fail "follow-ups must carry the verbatim texts in typed order: $out"
  [ -f "$home/state/intake/3.prompt" ] || fail "the third record was not written"
  pass "several prompts typed in one turn are captured in order with ascending sequence numbers"
}

test_commands_interrupts_and_idle_prompts_pass_through() {
  local home out
  home=$(new_home passthrough)
  out=$(drive "$home" passthrough) || fail "drive failed: $out"
  [ "$(field "$out" '[.results[].action] | unique | join(" ")')" = continue ] \
    || fail "a slash command, a bash line, an urgent interrupt, an idle prompt, an explicit follow-up, an extension prompt, and a blank line must all pass through: $out"
  [ "$(field "$out" '.queued | length')" = 0 ] || fail "nothing passed through may be queued: $out"
  [ -z "$(ls "$home/state/intake" 2>/dev/null | grep -Ev '^(handled|released)$')" ] || fail "nothing passed through may be recorded"
  pass "commands, bash lines, short interrupts, idle prompts, explicit follow-ups, and non-interactive input keep their native lane"
}

test_consumption_moves_the_record_to_handled() {
  local home out
  home=$(new_home consume-streaming)
  out=$(drive "$home" consume-streaming "fix the footer") || fail "drive failed: $out"
  [ -f "$home/state/intake/handled/1.prompt" ] || fail "a follow-up consumed by a streaming run must move its record to handled/"
  [ ! -f "$home/state/intake/1.prompt" ] || fail "a consumed record must not stay pending"
  [ "$(field "$out" '.statuses[-1].text')" = null ] || fail "the status line clears once nothing is queued: $out"

  home=$(new_home consume-idle)
  out=$(drive "$home" consume-idle "fix the footer") || fail "drive failed: $out"
  [ -f "$home/state/intake/handled/1.prompt" ] || fail "a follow-up consumed by an idle run must move its record to handled/"

  home=$(new_home consume-other)
  out=$(drive "$home" consume-other-text "fix the footer") || fail "drive failed: $out"
  [ -f "$home/state/intake/1.prompt" ] || fail "a user message with different text, or an assistant message, must not consume the record"
  pass "consumption is matched on the exact wrapped text at message_start or before_agent_start and moves the record to handled/"
}

test_abort_releases_rather_than_resends() {
  local home out
  home=$(new_home abort)
  out=$(drive "$home" abort "fix the footer") || fail "drive failed: $out"
  [ "$(field "$out" '.queued | length')" = 1 ] || fail "an aborted turn must not re-send the prompt Pi returned to the editor: $out"
  [ -f "$home/state/intake/released/1.prompt" ] || fail "an aborted turn must move the record to released/"
  field "$out" '.notices[-1].message' | grep -q 'returned to your editor' || fail "the release is announced: $out"
  [ "$(field "$out" '.notices[-1].type')" = warning ] || fail "the release notice is a warning: $out"
  pass "an abort releases the record (Pi already returned the text to the editor) instead of delivering it twice"
}

test_unconsumed_settle_resends_after_grace() {
  local home out
  home=$(new_home settle-unconsumed)
  out=$(drive "$home" settle-unconsumed "fix the footer") || fail "drive failed: $out"
  [ "$(field "$out" '.queued | length')" = 2 ] || fail "a record still pending after a non-aborted settle must be re-sent: $out"
  [ "$(field "$out" '.queued[1].text')" = "$(field "$out" '.queued[0].text')" ] || fail "the re-send carries the same wrapped text: $out"
  [ -f "$home/state/intake/1.prompt" ] || fail "a re-sent record stays pending until consumed"
  field "$out" '.notices[-1].message' | grep -q 're-queued' || fail "the re-send is announced: $out"

  home=$(new_home settle-consumed)
  out=$(drive "$home" settle-consumed "fix the footer") || fail "drive failed: $out"
  [ "$(field "$out" '.queued | length')" = 1 ] || fail "a consumed record must not be re-sent at settle: $out"
  pass "a record Pi accepted but never consumed is re-sent after the settle grace, while a consumed one is not"
}

test_session_start_resends_what_a_previous_session_left() {
  local home out
  home=$(new_home session-start)
  mkdir -p "$home/state/intake/handled"
  printf 'schema=fm-captain-intake.v1\nseq=4\nat=2026-10-26T14:02:11.000Z\nsession=old\n--\nfinish the review\n' > "$home/state/intake/4.prompt"
  printf 'schema=fm-captain-intake.v1\nseq=3\nat=2026-10-26T14:01:00.000Z\nsession=old\n--\nearlier\n' > "$home/state/intake/handled/3.prompt"
  out=$(drive "$home" session-start-only) || fail "drive failed: $out"
  [ "$(field "$out" '.queued | length')" = 1 ] || fail "exactly the pending record is re-sent at session start: $out"
  case "$(field "$out" '.queued[0].text')" in
    "Firstmate intake #4 (typed 14:02:11Z"*"finish the review") : ;;
    *) fail "the re-sent follow-up must rebuild the header from the record: $(field "$out" '.queued[0].text')" ;;
  esac
  out=$(drive "$home" steer "next") || fail "drive failed: $out"
  [ -f "$home/state/intake/5.prompt" ] || fail "sequence numbers must continue past handled and pending records"
  pass "a record left pending by a replaced or crashed session is re-sent at session start and the sequence continues"
}

test_queue_refusal_falls_back_to_the_native_steer() {
  local home out
  home=$(new_home refused)
  out=$(drive "$home" queue-refused "fix the footer") || fail "drive failed: $out"
  [ "$(field "$out" '.results[0].action')" = continue ] || fail "a refused queue must hand the prompt back to Pi's steer: $out"
  [ ! -f "$home/state/intake/1.prompt" ] || fail "a refused queue must not leave a pending record that would be re-sent later"
  field "$out" '.notices[0].message' | grep -q 'could not be queued' || fail "the refusal is announced: $out"
  pass "when Pi refuses the follow-up the prompt keeps its native steer and no stale record is left behind"
}

test_intake_command_lists_state() {
  local home out
  home=$(new_home command)
  out=$(drive "$home" command) || fail "drive failed: $out"
  field "$out" '.commands | join(" ")' | grep -q 'intake' || fail "the /intake command is registered"
  field "$out" '.notices[0].message' | grep -q '^captain intake: on' || fail "the listing reports the flag: $out"
  pass "/intake reports whether intake is on and what is pending"
}

require_jq
test_flag_absent_keeps_native_steer
test_mid_turn_prompt_becomes_record_and_follow_up
test_three_prompts_keep_their_order
test_commands_interrupts_and_idle_prompts_pass_through
test_consumption_moves_the_record_to_handled
test_abort_releases_rather_than_resends
test_unconsumed_settle_resends_after_grace
test_session_start_resends_what_a_previous_session_left
test_queue_refusal_falls_back_to_the_native_steer
test_intake_command_lists_state
echo "all fm-pi-captain-intake tests passed"
