#!/usr/bin/env bash
# test_router.sh - the SA-02 proof script.
#
# Proves the Router premise (design.md section 0.1) rather than describing it:
#   * sa-cli has exactly five verbs and no shell/read/edit/write escape
#   * sa-cli never writes the event log itself (the Engine is the sole writer)
#   * sa-router.ts registers exactly five tools and no commands
#   * a real ticket + assign round-trips through the store projections
#   * a Router Pi session, launched with only the five sa_* tools, has exactly
#     those five tools and cannot read a file
#
# Usage:  sa/tests/test_router.sh            (from anywhere)
#         SA_SKIP_PI=1 sa/tests/test_router.sh   (skip the two Pi session proofs)
#
# The store-dependent steps need sa/bin/sa-store (SA-01, design.md section 6).
# When it is absent they SKIP with a loud message and the script exits non-zero,
# so a missing dependency can never look like a pass.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO/sa/bin/sa-cli"
EXT="$REPO/sa/extensions/sa-router.ts"
STORE="$REPO/sa/bin/sa-store"

VERBS=(ticket assign reply rule escalate)
FORBIDDEN=(bash sh exec read cat edit write)

pass=0
fail=0
skip=0

ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf 'SKIP  %s\n' "$1"; skip=$((skip + 1)); }

section() { printf '\n== %s ==\n' "$1"; }

# --------------------------------------------------------------------------- 1
section "sa-cli verb surface"

help_out="$("$CLI" --help 2>&1)"
help_rc=$?
if [ "$help_rc" -eq 0 ]; then ok "sa-cli --help exits 0"; else bad "sa-cli --help exits $help_rc"; fi

for v in "${VERBS[@]}"; do
  if printf '%s\n' "$help_out" | grep -Eq "^[[:space:]]+$v([[:space:]]|$)"; then
    ok "help lists verb: $v"
  else
    bad "help does not list verb: $v"
  fi
done

# Exactly five verbs: no other word may appear in the help's verb block.
listed="$(printf '%s\n' "$help_out" | sed -n '/^verbs:/,/^$/p' | grep -E '^  [a-z]+$' | sed 's/^  //' | sort | tr '\n' ' ')"
if [ "$listed" = "assign escalate reply rule ticket " ]; then
  ok "help lists exactly five verbs: $listed"
else
  bad "help verb block is not exactly the five verbs: '$listed'"
fi

# --------------------------------------------------------------------------- 2
section "unknown verbs are refused"

for v in "${FORBIDDEN[@]}" definitely-not-a-verb; do
  out="$("$CLI" "$v" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "unknown command: $v"; then
    ok "sa-cli $v -> exit 2, 'unknown command: $v'"
  else
    bad "sa-cli $v -> exit $rc, output: $out"
  fi
  if printf '%s' "$out" | grep -q "ticket"; then
    ok "sa-cli $v prints the verb list"
  else
    bad "sa-cli $v does not print the verb list"
  fi
done

# --------------------------------------------------------------------------- 3
section "no execution escape in the CLI source"

if grep -q "events.jsonl" "$CLI"; then
  bad "sa-cli mentions events.jsonl - the Engine must be the sole writer"
else
  ok "sa-cli never touches events.jsonl"
fi

for pat in 'shell=True' 'os\.system' 'os\.exec' 'os\.popen' 'eval\(' 'exec\(' 'pty\.' 'shutil\.'; do
  if grep -Eq "$pat" "$CLI"; then
    bad "sa-cli source contains forbidden pattern: $pat"
  else
    ok "sa-cli source has no $pat"
  fi
done

# The only external command the CLI may run is the store.
ext_cmds="$(grep -oE 'subprocess\.[a-z_]+' "$CLI" | sort -u | tr '\n' ' ')"
if [ "$ext_cmds" = "subprocess.run " ]; then
  ok "sa-cli runs external commands only via subprocess.run ($ext_cmds)"
else
  bad "sa-cli external command surface is unexpected: '$ext_cmds'"
fi

# --------------------------------------------------------------------------- 4
section "sa-router.ts registers exactly five tools"

tool_names="$(grep -oE 'name: "sa_[a-z]+"' "$EXT" | sed 's/name: "//; s/"//' | sort | tr '\n' ' ')"
if [ "$tool_names" = "sa_assign sa_escalate sa_reply sa_rule sa_ticket " ]; then
  ok "extension registers exactly: $tool_names"
else
  bad "extension tool names are: '$tool_names'"
fi

reg_count="$(grep -c 'pi\.registerTool(' "$EXT")"
if [ "$reg_count" -eq 5 ]; then
  ok "extension calls pi.registerTool exactly 5 times"
else
  bad "extension calls pi.registerTool $reg_count times"
fi

if grep -q 'pi\.registerCommand' "$EXT"; then
  bad "extension registers a command - the Router must have no command surface"
else
  ok "extension registers no commands"
fi

if grep -q 'pi\.on(' "$EXT"; then
  bad "extension registers an event hook - keep the surface to five tools"
else
  ok "extension registers no event hooks"
fi

if grep -q 'shell: true' "$EXT"; then
  bad "extension uses a shell"
else
  ok "extension never uses a shell"
fi

# --------------------------------------------------------------------------- 5
section "ticket + assign round-trip through the store"

if [ ! -x "$STORE" ] && [ ! -f "$STORE" ]; then
  skipped "sa/bin/sa-store is absent (SA-01 owns it, design.md section 6)"
  printf '\n  !! The store-dependent proofs did NOT run. This is not a pass.\n'
  printf '  !! Re-run once sa/bin/sa-store exists: %s\n' "$0"
  store_ok=0
else
  store_ok=1
  export SA_HOME="$(mktemp -d)"
  trap 'rm -rf "$SA_HOME"' EXIT

  tid="$("$CLI" ticket --title "Router smoke" --body "prove the router can open a ticket" \
        --requester "test_router.sh" --acceptance '{"command":"true"}' 2>&1)"
  if printf '%s' "$tid" | grep -Eq '^T-[0-9]+$'; then
    ok "sa-cli ticket -> $tid"
  else
    bad "sa-cli ticket did not return a ticket id: $tid"
  fi

  if "$CLI" assign --ticket "$tid" --owner "sa-worker-1" --reason "only worker with the scope" >/dev/null 2>&1; then
    ok "sa-cli assign $tid -> sa-worker-1"
  else
    bad "sa-cli assign failed"
  fi

  tickets="$("$STORE" state --table tickets 2>&1)"
  if printf '%s' "$tickets" | grep -q "$tid"; then
    ok "store tickets projection contains $tid"
  else
    bad "store tickets projection does not contain $tid: $tickets"
  fi

  assignments="$("$STORE" state --table assignments 2>&1)"
  if printf '%s' "$assignments" | grep -q "sa-worker-1"; then
    ok "store assignments projection contains the owner"
  else
    bad "store assignments projection does not contain the owner: $assignments"
  fi

  if "$CLI" reply --ticket "$tid" --text "on it" >/dev/null 2>&1; then
    ok "sa-cli reply $tid"
  else
    bad "sa-cli reply failed"
  fi

  if "$CLI" rule --ticket "$tid" --ruling "accept" --rationale "checkable acceptance" >/dev/null 2>&1; then
    ok "sa-cli rule $tid"
  else
    bad "sa-cli rule failed"
  fi

  if "$CLI" escalate --ticket "$tid" --to "human" --why "needs a product call" >/dev/null 2>&1; then
    ok "sa-cli escalate $tid"
  else
    bad "sa-cli escalate failed"
  fi

  if "$STORE" state --table events 2>&1 | grep -q "ticket.created"; then
    ok "store events projection recorded ticket.created"
  else
    bad "store events projection has no ticket.created"
  fi
fi

# --------------------------------------------------------------------------- 6
section "Router Pi session tool surface"

if [ "${SA_SKIP_PI:-0}" = "1" ]; then
  skipped "SA_SKIP_PI=1 - Pi session proofs not run"
elif ! command -v pi >/dev/null 2>&1; then
  skipped "pi is not on PATH - Pi session proofs not run"
else
  tools_out="$(cd "$REPO" && pi --no-builtin-tools --no-mcp \
      --tools sa_ticket,sa_assign,sa_reply,sa_rule,sa_escalate \
      -e sa/extensions/sa-router.ts \
      -p "List the exact name of every tool you have, one per line, nothing else." 2>&1)"
  printf '%s\n' "$tools_out" | sed 's/^/      | /'

  got="$(printf '%s\n' "$tools_out" | grep -oE 'sa_[a-z]+' | sort -u | tr '\n' ' ')"
  if [ "$got" = "sa_assign sa_escalate sa_reply sa_rule sa_ticket " ]; then
    ok "Router session has exactly the five sa_* tools"
  else
    bad "Router session tool list is: '$got'"
  fi

  for t in read bash edit write grep find ls; do
    if printf '%s\n' "$tools_out" | grep -qx "$t"; then
      bad "Router session has the built-in tool: $t"
    fi
  done
  ok "Router session has no built-in tool in its list"

  neg_out="$(cd "$REPO" && pi --no-builtin-tools --no-mcp \
      --tools sa_ticket,sa_assign,sa_reply,sa_rule,sa_escalate \
      -e sa/extensions/sa-router.ts \
      -p "Read the file sa/README.md and print its first line." 2>&1)"
  printf '%s\n' "$neg_out" | sed 's/^/      | /'
  if printf '%s\n' "$neg_out" | grep -qiE 'no (such )?(tool|file)|cannot|can.t|don.t have|unable|not available'; then
    ok "Router session reports it has no file-read tool"
  else
    bad "Router session did not clearly refuse the file read"
  fi
fi

# --------------------------------------------------------------------------- summary
printf '\n== summary ==\n'
printf 'pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"

if [ "$fail" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi
if [ "${store_ok:-0}" -ne 1 ]; then
  printf 'RESULT: INCOMPLETE (store-dependent proofs skipped)\n'
  exit 1
fi
if [ "$skip" -ne 0 ]; then
  printf 'RESULT: INCOMPLETE (%d step(s) skipped)\n' "$skip"
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
