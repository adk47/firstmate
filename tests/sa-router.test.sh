#!/usr/bin/env bash
# SA-02 Router: the five-verb CLI and the five-tool Pi extension.
#
# Proves the Router premise (design.md section 0.1) by driving the interfaces:
#   * sa-cli exposes exactly five verbs and refuses every shell/read/edit verb
#   * argv values are never interpreted by a shell
#   * sa-cli never writes the event log itself; the store is the sole writer
#   * all five verbs round-trip into the store's projections
#   * concurrent ticket creation keeps distinct ids and both tickets
#   * the extension registers exactly five tools, no commands, no event hooks
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
test_extension_registers_five_tools() {
  local pkg typebox fixture out
  command -v node >/dev/null 2>&1 || { note "node not found - extension surface proof not run"; return 0; }
  pkg=${FM_PI_PACKAGE_DIR:-}
  if [ -z "$pkg" ] && command -v npm >/dev/null 2>&1; then
    pkg="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
  fi
  if [ ! -f "$pkg/package.json" ] && command -v pi >/dev/null 2>&1; then
    pkg=$(python3 -c 'import os,sys; print(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1])))))' "$(command -v pi)")
  fi
  [ -f "$pkg/package.json" ] || { note "installed pi package not found - extension surface proof not run"; return 0; }
  typebox="$pkg/node_modules/typebox"
  [ -d "$typebox" ] || { note "typebox not found - extension surface proof not run"; return 0; }

  fixture="$TMP_ROOT/ext"
  mkdir -p "$fixture/node_modules/@earendil-works/pi-coding-agent"
  printf '{"name":"@earendil-works/pi-coding-agent","version":"0.0.0","type":"module","main":"index.js"}\n' \
    >"$fixture/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf 'export {};\n' >"$fixture/node_modules/@earendil-works/pi-coding-agent/index.js"
  ln -s "$typebox" "$fixture/node_modules/typebox"
  printf '{"type":"module"}\n' >"$fixture/package.json"
  printf 'const n: number = 1;\nconsole.log(n);\n' >"$fixture/probe.ts"
  node "$fixture/probe.ts" >/dev/null 2>&1 \
    || { note "node cannot run TypeScript - extension surface proof not run"; return 0; }
  cp "$EXT" "$fixture/sa-router.ts"

  out=$(cd "$fixture" && node --input-type=module 2>&1 <<'JS'
const mod = await import("./sa-router.ts");
const tools = [];
const commands = [];
const hooks = [];
const pi = {
  registerTool(tool) { tools.push(tool.name); },
  registerCommand(name) { commands.push(name); },
  on(event) { hooks.push(event); },
  exec: async () => ({ code: 0, stdout: "", stderr: "" }),
};
mod.default(pi);
console.log(JSON.stringify({ tools, commands, hooks }));
JS
)
  printf '%s' "$out" | grep -q '"tools":\["sa_ticket","sa_assign","sa_reply","sa_rule","sa_escalate"\]' \
    || fail "extension did not register exactly the five sa_* tools: $out"
  printf '%s' "$out" | grep -q '"commands":\[\]' \
    || fail "extension registered a command: $out"
  printf '%s' "$out" | grep -q '"hooks":\[\]' \
    || fail "extension registered an event hook: $out"
  pass "extension registers exactly the five sa_* tools, no commands, no hooks"
}

# --------------------------------------------------------------------------- 8
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
test_extension_registers_five_tools
test_live_router_session

printf 'ok - sa-router\n'
