#!/usr/bin/env bash
# SA-02 Router: the five-verb CLI and the five-tool Pi extension.
#
# Proves the Router premise (design.md section 0.1) by driving the interfaces:
#   * sa-cli exposes exactly five verbs and refuses every shell/read/edit verb
#   * argv values are never interpreted by a shell
#   * sa-cli never writes the event log itself; the store is the sole writer
#   * all five verbs round-trip into the store's projections
#   * concurrent ticket creation keeps distinct ids and both tickets
#   * the store's own unit suite passes
#   * the extension registers exactly five tools, no commands, no event hooks,
#     and its sa_ticket reaches the CLI without a shell
#
# The live Pi session probe is development-only evaluation: set SA_LIVE_PI=1 to
# run it. It is not part of the deterministic CI proof.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/sa/bin/sa-cli"
STORE="$ROOT/sa/bin/sa-store"
EXT="$ROOT/sa/extensions/sa-router.ts"
VERBS=(ticket assign reply rule escalate)
FORBIDDEN=(bash sh exec read cat edit write)

TMP_ROOT=$(fm_test_tmproot fm-sa-router)
SA_HOME="$TMP_ROOT/home"
export SA_HOME

note() { printf 'note: %s\n' "$1"; }

# Read one field of one ticket row from the store's tickets projection.
ticket_field() {  # <ticket-id> <field>
  "$STORE" state --table tickets |
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]])' "$1" "$2"
}

# --------------------------------------------------------------------------- 1
test_cli_verb_surface() {
  local out rc listed v
  out=$("$CLI" --help 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "sa-cli --help exited $rc"
  listed=$(printf '%s\n' "$out" | sed -n '/^verbs:/,/^$/p' | grep -E '^  [a-z]+$' | sed 's/^  //' | sort | tr '\n' ' ')
  [ "$listed" = "assign escalate reply rule ticket " ] \
    || fail "sa-cli help verb block is not exactly the five verbs: '$listed'"
  for v in "${VERBS[@]}"; do
    printf '%s\n' "$out" | grep -Eq "^[[:space:]]+$v([[:space:]]|$)" \
      || fail "sa-cli help does not list verb: $v"
  done
  pass "sa-cli --help lists exactly the five verbs"
}

# --------------------------------------------------------------------------- 2
test_unknown_verbs_refused() {
  local v out rc
  for v in "${FORBIDDEN[@]}" definitely-not-a-verb; do
    out=$("$CLI" "$v" 2>&1)
    rc=$?
    [ "$rc" -eq 2 ] || fail "sa-cli $v exited $rc, expected 2 (output: $out)"
    printf '%s' "$out" | grep -q "unknown command: $v" \
      || fail "sa-cli $v did not report 'unknown command: $v' (output: $out)"
    printf '%s' "$out" | grep -q "ticket" \
      || fail "sa-cli $v did not print the verb list"
  done
  [ ! -e "$SA_HOME/events.jsonl" ] \
    || fail "a refused verb wrote the event log"
  pass "sa-cli refuses every shell/read/edit verb with exit 2 and writes nothing"
}

# --------------------------------------------------------------------------- 3
test_argv_is_never_shell_interpreted() {
  local title body requester tid
  # shellcheck disable=SC2016 # the metacharacters must stay literal
  title='$(touch '"$TMP_ROOT"'/pwned-title)'
  # shellcheck disable=SC2016
  body='`touch '"$TMP_ROOT"'/pwned-body`'
  # shellcheck disable=SC2016
  requester='; touch '"$TMP_ROOT"'/pwned-requester;'
  tid=$("$CLI" ticket --title "$title" --body "$body" --requester "$requester" 2>&1) \
    || fail "sa-cli ticket with shell metacharacters failed: $tid"
  [ ! -e "$TMP_ROOT/pwned-title" ] || fail "sa-cli ticket title reached a shell"
  [ ! -e "$TMP_ROOT/pwned-body" ] || fail "sa-cli ticket body reached a shell"
  [ ! -e "$TMP_ROOT/pwned-requester" ] || fail "sa-cli ticket requester reached a shell"
  [ "$(ticket_field "$tid" title)" = "$title" ] \
    || fail "ticket title was not stored literally: $(ticket_field "$tid" title)"
  [ "$(ticket_field "$tid" body)" = "$body" ] \
    || fail "ticket body was not stored literally: $(ticket_field "$tid" body)"
  [ "$(ticket_field "$tid" requester)" = "$requester" ] \
    || fail "ticket requester was not stored literally: $(ticket_field "$tid" requester)"
  pass "sa-cli stores argv values literally; no shell is reached"
}

# --------------------------------------------------------------------------- 4
test_cli_never_writes_the_log() {
  local isolated="$TMP_ROOT/isolated" home="$TMP_ROOT/isolated-home" out rc
  mkdir -p "$isolated/bin" "$home"
  cp "$CLI" "$isolated/bin/sa-cli"
  out=$(SA_HOME="$home" "$isolated/bin/sa-cli" ticket --title t --body b --requester r 2>&1)
  rc=$?
  [ "$rc" -eq 3 ] || fail "sa-cli without a store exited $rc, expected 3 (output: $out)"
  printf '%s' "$out" | grep -q "sa-store" \
    || fail "sa-cli without a store did not name the missing store: $out"
  [ ! -e "$home/events.jsonl" ] \
    || fail "sa-cli wrote the event log itself instead of going through the store"
  pass "sa-cli writes nothing when the store is absent; the store is the sole writer"
}

# --------------------------------------------------------------------------- 5
test_five_verbs_round_trip() {
  local tid out
  tid=$("$CLI" ticket --title "Router smoke" --body "prove the router can open a ticket" \
    --requester "sa-router.test.sh" --acceptance '{"command":"true"}' 2>&1) \
    || fail "sa-cli ticket failed: $tid"
  printf '%s' "$tid" | grep -Eq '^T-[0-9]{4}$' || fail "sa-cli ticket returned '$tid'"
  [ "$(ticket_field "$tid" title)" = "Router smoke" ] \
    || fail "tickets projection does not hold the created ticket"

  "$CLI" assign --ticket "$tid" --owner "sa-worker-1" --reason "only worker with the scope" \
    >/dev/null 2>&1 || fail "sa-cli assign failed"
  "$STORE" state --table assignments | grep -q "sa-worker-1" \
    || fail "assignments projection does not hold the owner"

  "$CLI" reply --ticket "$tid" --text "on it" >/dev/null 2>&1 || fail "sa-cli reply failed"
  "$STORE" state --table threads | grep -q "on it" \
    || fail "threads projection does not hold the reply"

  "$CLI" rule --ticket "$tid" --ruling "accept" --rationale "checkable acceptance" \
    >/dev/null 2>&1 || fail "sa-cli rule failed"
  "$STORE" state --table rulings | grep -q "checkable acceptance" \
    || fail "rulings projection does not hold the ruling"

  "$CLI" escalate --ticket "$tid" --to "human" --why "needs a product call" \
    >/dev/null 2>&1 || fail "sa-cli escalate failed"
  out=$("$STORE" query --table events --where type=ticket.escalated 2>&1)
  printf '%s' "$out" | grep -q "$tid" \
    || fail "escalation is not queryable through the store: $out"
  pass "all five verbs round-trip into queryable store state"
}

# --------------------------------------------------------------------------- 6
test_concurrent_tickets_keep_distinct_ids() {
  local i tid ids=() titles=() seen
  for i in 1 2 3 4 5 6 7 8; do
    "$CLI" ticket --title "concurrent-$i" --body "body-$i" --requester "racer-$i" \
      >"$TMP_ROOT/race-$i.out" 2>&1 &
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do
    tid=$(cat "$TMP_ROOT/race-$i.out")
    printf '%s' "$tid" | grep -Eq '^T-[0-9]{4}$' \
      || fail "concurrent ticket $i returned '$tid'"
    ids+=("$tid")
  done
  seen=$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')
  [ "$seen" -eq 8 ] || fail "concurrent tickets collided onto $seen distinct ids: ${ids[*]}"
  for i in 1 2 3 4 5 6 7 8; do
    titles+=("$(ticket_field "${ids[$((i - 1))]}" title)")
  done
  seen=$(printf '%s\n' "${titles[@]}" | sort -u | wc -l | tr -d ' ')
  [ "$seen" -eq 8 ] || fail "concurrent tickets overwrote each other: ${titles[*]}"
  pass "concurrent ticket creation keeps eight distinct ids and eight distinct tickets"
}

# --------------------------------------------------------------------------- 7
test_store_unit_suite() {
  local out
  out=$(cd "$ROOT" && python3 -m unittest discover -s sa/tests 2>&1) \
    || fail "the SA store unit suite failed: $out"
  pass "the SA store unit suite passes"
}

# --------------------------------------------------------------------------- 8
test_extension_registers_five_tools() {
  local fixture out problems tid
  command -v node >/dev/null 2>&1 || { note "node not found - extension surface proof not run"; return 0; }

  # A stub Pi SDK and a stub typebox: the extension only needs registerTool,
  # registerCommand, on, and exec, plus Type.Object/String/Optional. Building
  # them here keeps the proof deterministic instead of depending on whatever
  # happens to be installed on the machine.
  fixture="$TMP_ROOT/ext"
  mkdir -p "$fixture/sa/extensions" \
    "$fixture/node_modules/@earendil-works/pi-coding-agent" \
    "$fixture/node_modules/typebox"
  ln -s "$ROOT/sa/bin" "$fixture/sa/bin"
  ln -s "$ROOT/sa/lib" "$fixture/sa/lib"
  cp "$EXT" "$fixture/sa/extensions/sa-router.ts"
  printf '{"type":"module"}\n' >"$fixture/package.json"
  printf '{"name":"@earendil-works/pi-coding-agent","version":"0.0.0","type":"module","exports":"./index.js"}\n' \
    >"$fixture/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf 'export {};\n' >"$fixture/node_modules/@earendil-works/pi-coding-agent/index.js"
  printf '{"name":"typebox","version":"0.0.0","type":"module","exports":"./index.js"}\n' \
    >"$fixture/node_modules/typebox/package.json"
  cat >"$fixture/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object: (properties) => ({ type: "object", properties }),
  String: (options = {}) => ({ type: "string", ...options }),
  Optional: (schema) => schema,
};
JS

  out=$(cd "$fixture" && node --input-type=module 2>&1 <<'JS'
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);
const mod = await import("./sa/extensions/sa-router.ts");
const tools = [];
const commands = [];
const hooks = [];
const execs = [];
const pi = {
  registerTool(tool) { tools.push(tool); },
  registerCommand(name) { commands.push(name); },
  on(event) { hooks.push(event); },
  async exec(cmd, args, opts) {
    execs.push({ cmd, args, shell: opts?.shell ?? null });
    try {
      const { stdout, stderr } = await run(cmd, args, { env: process.env });
      return { code: 0, stdout, stderr };
    } catch (error) {
      return {
        code: error.code ?? 1,
        stdout: error.stdout ?? "",
        stderr: error.stderr ?? "",
      };
    }
  },
};
mod.default(pi);
const ticket = tools.find((tool) => tool.name === "sa_ticket");
const result = await ticket.execute(
  "call-1",
  { title: "ext ticket", body: "via the extension", requester: "sa-router.test.sh" },
  undefined,
);
console.log(
  JSON.stringify({
    tools: tools.map((tool) => tool.name),
    commands,
    hooks,
    execs,
    text: result.content[0].text,
  }),
);
JS
)

  problems=$(printf '%s' "$out" | python3 -c '
import json, sys

data = json.load(sys.stdin)
expected = ["sa_ticket", "sa_assign", "sa_reply", "sa_rule", "sa_escalate"]
problems = []
if data["tools"] != expected:
    problems.append("tools are %r, expected %r" % (data["tools"], expected))
if data["commands"]:
    problems.append("registered commands: %r" % (data["commands"],))
if data["hooks"]:
    problems.append("registered event hooks: %r" % (data["hooks"],))
if len(data["execs"]) != 1:
    problems.append("sa_ticket made %d exec calls" % len(data["execs"]))
else:
    call = data["execs"][0]
    if call["cmd"] != "python3":
        problems.append("sa_ticket ran %r, not python3" % (call["cmd"],))
    if not call["args"][0].endswith("/sa/bin/sa-cli"):
        problems.append("sa_ticket ran %r, not the sa-cli" % (call["args"][0],))
    if call["args"][1:] != [
        "ticket",
        "--title",
        "ext ticket",
        "--body",
        "via the extension",
        "--requester",
        "sa-router.test.sh",
    ]:
        problems.append("sa_ticket argv is %r" % (call["args"][1:],))
    if call["shell"] is not None:
        problems.append("sa_ticket exec used a shell: %r" % (call["shell"],))
if not data["text"].startswith("T-"):
    problems.append("sa_ticket returned %r" % (data["text"],))
if problems:
    print("; ".join(problems))
    sys.exit(1)
' 2>&1) || fail "extension surface proof failed: $problems"

  tid=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')
  [ "$(ticket_field "$tid" title)" = "ext ticket" ] \
    || fail "the extension's sa_ticket did not reach the store: $out"
  pass "extension registers exactly the five sa_* tools, no commands, no hooks, and sa_ticket reaches the CLI"
}

# --------------------------------------------------------------------------- 9
test_live_router_session() {
  local tools_out got neg_out
  if [ "${SA_LIVE_PI:-0}" != "1" ]; then
    note "SA_LIVE_PI=1 not set - live Router session probe not run (development-only)"
    return 0
  fi
  command -v pi >/dev/null 2>&1 || fail "SA_LIVE_PI=1 but pi is not on PATH"

  tools_out=$(cd "$ROOT" && pi --no-builtin-tools --no-mcp \
    --tools sa_ticket,sa_assign,sa_reply,sa_rule,sa_escalate \
    -e sa/extensions/sa-router.ts \
    -p "List the exact name of every tool you have, one per line, nothing else." 2>&1)
  got=$(printf '%s\n' "$tools_out" | grep -oE 'sa_[a-z]+' | sort -u | tr '\n' ' ')
  [ "$got" = "sa_assign sa_escalate sa_reply sa_rule sa_ticket " ] \
    || fail "Router session tool list is: '$got'"

  neg_out=$(cd "$ROOT" && pi --no-builtin-tools --no-mcp \
    --tools sa_ticket,sa_assign,sa_reply,sa_rule,sa_escalate \
    -e sa/extensions/sa-router.ts \
    -p "Read the file AGENTS.md and print its first line." 2>&1)
  printf '%s\n' "$neg_out" | grep -qF "You are Bob." \
    && fail "Router session read a file it must not reach: $neg_out"
  pass "live Router session has exactly the five sa_* tools and cannot read a file"
}

test_cli_verb_surface
test_unknown_verbs_refused
test_argv_is_never_shell_interpreted
test_cli_never_writes_the_log
test_five_verbs_round_trip
test_concurrent_tickets_keep_distinct_ids
test_store_unit_suite
test_extension_registers_five_tools
test_live_router_session

printf 'ok - sa-router\n'
