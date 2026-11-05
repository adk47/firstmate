#!/usr/bin/env bash
# sa/tests/test_dispatch.sh - SA-03's proof: the DoD gate, dispatch, the Mandate,
# and the kill switch (design.md §8, §10).
#
# Every test runs against a throwaway SA_HOME. The dispatch path is exercised
# with a stub spawner (SA_SPAWN_CMD) so the suite never launches a real agent;
# the real spawner is proven separately in the report's pass proof.
#
# A missing sa/bin/sa-store is never a pass: the suite prints a loud SKIP line
# and exits non-zero with RESULT: INCOMPLETE.
#
# Usage: sa/tests/test_dispatch.sh
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
DISPATCH="$REPO/sa/bin/sa-dispatch"
KILL="$REPO/sa/bin/sa-kill"
STORE="$REPO/sa/bin/sa-store"

pass=0
fail=0
skip=0

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf '      | %s\n' "$1"; }

section() { printf '\n== %s ==\n' "$1"; }

# assert_exit <expected> <description> <command...>
# Sets OUT to the command's combined output; prints only the verdict.
OUT=
assert_exit() {
  local want=$1 desc=$2
  shift 2
  local status
  OUT=$("$@" 2>&1)
  status=$?
  if [ "$status" -eq "$want" ]; then
    ok "$desc (exit $status)"
  else
    bad "$desc (wanted exit $want, got $status)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  fi
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *)
      bad "$3"
      note "wanted substring: $2"
      note "in: $1"
      ;;
  esac
}

# assert_absent <haystack> <needle> <description>
assert_absent() {
  case "$1" in
    *"$2"*)
      bad "$3"
      note "unexpected substring: $2"
      ;;
    *) ok "$3" ;;
  esac
}

# ticket <id> <acceptance-json> [title]
ticket() {
  local id=$1 acceptance=$2 title=${3:-Ticket $1}
  "$STORE" append --type ticket.created --actor router --ticket "$id" \
    --payload "{\"title\":\"$title\",\"body\":\"body of $id\",\"requester\":\"aaron\",\"acceptance\":$acceptance}" \
    >/dev/null
}

# ---------------------------------------------------------------------------
section "dependencies"
# ---------------------------------------------------------------------------
if [ ! -x "$STORE" ]; then
  printf 'SKIP: sa-store not yet on main - SA-03 cannot be proven without the SA-01 store.\n'
  printf 'SKIP: merge origin/main (or the SA-01 store branch) and re-run.\n'
  printf '\n== summary ==\npass=0 fail=0 skip=1\nRESULT: INCOMPLETE\n'
  exit 1
fi
ok "sa/bin/sa-store is present"
[ -x "$DISPATCH" ] && ok "sa/bin/sa-dispatch is executable" || bad "sa/bin/sa-dispatch is executable"
[ -x "$KILL" ] && ok "sa/bin/sa-kill is executable" || bad "sa/bin/sa-kill is executable"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sa-dispatch-test.XXXXXX")
export SA_HOME="$WORK/home"
mkdir -p "$SA_HOME"
export SA_TMUX_SESSION="sa-test-$$"
STUB="$WORK/stub-spawn.sh"
cat >"$STUB" <<'STUB_EOF'
#!/bin/sh
# Stub spawner: prints the handle line fm-spawn.sh prints, creates nothing.
printf 'spawned %s harness=stub kind=ship mode=direct-PR yolo=off window=%s:fm-%s worktree=%s\n' \
  "$1" "${SA_TMUX_SESSION:-sa-workers}" "$1" "$SA_HOME/stub-worktree/$1"
STUB_EOF
chmod +x "$STUB"
export SA_SPAWN_CMD="$STUB"

cleanup() {
  tmux kill-session -t "$SA_TMUX_SESSION" 2>/dev/null || true
  tmux kill-session -t "sa-test-worker-$$" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "the DoD gate refuses a ticket with no checkable acceptance"
# ---------------------------------------------------------------------------
ticket T-0001 '{}'
assert_exit 3 "intake T-0001 (empty acceptance) is refused" "$DISPATCH" intake --ticket T-0001
out=$OUT
assert_contains "$out" "REFUSED: ticket T-0001 has no checkable acceptance signal." \
  "refusal names the ticket and the missing signal"
assert_contains "$out" 'Missing question: "What command proves this ticket is done?"' \
  "refusal names the missing question"

refused=$("$STORE" query --table events --where type=ticket.refused)
assert_contains "$refused" '"missing_question":"What command proves this ticket is done?"' \
  "ticket.refused event carries the missing question"
assert_contains "$refused" '"ticket":"T-0001"' "ticket.refused event names the ticket"

ticket T-0002 '{"command":""}'
assert_exit 3 "intake T-0002 (empty command) is refused" "$DISPATCH" intake --ticket T-0002

ticket T-0003 '{"signal":"done"}'
assert_exit 3 "intake T-0003 (signal 'done') is refused" "$DISPATCH" intake --ticket T-0003

ticket T-0004 '{"signal":"EXIT:0"}'
assert_exit 3 "intake T-0004 (signal 'EXIT:0' is not the documented shape) is refused" \
  "$DISPATCH" intake --ticket T-0004

ticket T-0005 '{"note":"it works, trust me"}'
assert_exit 3 "intake T-0005 (prose acceptance) is refused" "$DISPATCH" intake --ticket T-0005

assert_exit 2 "intake of an unknown ticket exits 2" "$DISPATCH" intake --ticket T-9999

# ---------------------------------------------------------------------------
section "the DoD gate passes every checkable acceptance shape"
# ---------------------------------------------------------------------------
ticket T-0010 '{"command":"echo hello"}'
assert_exit 0 "command acceptance passes the gate" "$DISPATCH" intake --ticket T-0010 --dry-run

for shape in 'exit:0' 'file:out.txt' 'grep:^ok$' 'http://localhost:8080/health'; do
  id="T-01$(printf '%s' "$shape" | cksum | cut -d' ' -f1 | cut -c1-2)"
  ticket "$id" "{\"signal\":\"$shape\"}"
  assert_exit 0 "signal '$shape' passes the gate" "$DISPATCH" intake --ticket "$id" --dry-run
done

# ---------------------------------------------------------------------------
section "--dry-run creates nothing"
# ---------------------------------------------------------------------------
ticket T-0020 '{"command":"echo hello","scope_paths":["sa/bin"]}'
before_events=$("$STORE" state --table events | wc -c)
assert_exit 0 "dry run exits 0" "$DISPATCH" intake --ticket T-0020 --dry-run
out=$OUT
assert_contains "$out" "PLAN: ticket T-0020" "dry run prints the plan"
assert_contains "$out" "gate: PASS" "dry run reports the gate result"
assert_contains "$out" "dry run: nothing created" "dry run says it created nothing"
[ -e "$SA_HOME/data/T-0020/brief.md" ] && bad "dry run wrote no brief" || ok "dry run wrote no brief"
[ -e "$SA_HOME/workers.json" ] && bad "dry run wrote no worker registry" || ok "dry run wrote no worker registry"
after_events=$("$STORE" state --table events | wc -c)
[ "$before_events" = "$after_events" ] && ok "dry run appended no event" || bad "dry run appended no event"

# ---------------------------------------------------------------------------
section "a checkable ticket dispatches: worktree, brief, worker, mandate"
# ---------------------------------------------------------------------------
ticket T-0030 '{"command":"echo hello","scope_paths":["sa/bin"]}'
assert_exit 0 "intake T-0030 dispatches" "$DISPATCH" intake --ticket T-0030
out=$OUT
assert_contains "$out" "DISPATCHED: ticket T-0030" "dispatch reports the ticket"
assert_contains "$out" "worktree:" "dispatch reports a worktree"
assert_contains "$out" "brief:" "dispatch reports a brief"
assert_contains "$out" "worker:" "dispatch reports a worker endpoint"

brief="$SA_HOME/data/T-0030/brief.md"
[ -f "$brief" ] && ok "the brief file exists" || bad "the brief file exists"
if [ -f "$brief" ]; then
  body=$(cat "$brief")
  assert_absent "$body" '{TASK}' "the brief has no {TASK} placeholder"
  assert_absent "$body" '{FIRSTMATE_SPEC}' "the brief has no {FIRSTMATE_SPEC} placeholder"
  assert_contains "$body" "echo hello" "the brief carries the acceptance command"
  assert_contains "$body" "sa/bin" "the brief carries the scope paths"
fi

registry=$(cat "$SA_HOME/workers.json" 2>/dev/null || true)
assert_contains "$registry" '"id":"T-0030"' "the worker registry records the ticket"
assert_contains "$registry" "\"endpoint\":\"$SA_TMUX_SESSION:fm-T-0030\"" \
  "the worker registry records the exact endpoint"

mandates=$("$STORE" state --table mandates)
assert_contains "$mandates" '"T-0030"' "the mandates table holds the mandate"
assert_contains "$mandates" '"requester":"aaron"' "the mandate carries the requester"
assert_contains "$mandates" '"scope_paths":["sa/bin"]' "the mandate carries the scope paths"
assert_contains "$mandates" '"rules_in_force":[' "the mandate carries the rules in force"
assert_contains "$mandates" '"expires_at":"' "the mandate carries an expiry"

dispatched=$("$STORE" query --table events --where type=ticket.dispatched)
assert_contains "$dispatched" '"worktree":' "ticket.dispatched carries the worktree"
assert_contains "$dispatched" '"brief":' "ticket.dispatched carries the brief"
assert_contains "$dispatched" '"worker":' "ticket.dispatched carries the worker"
assert_contains "$dispatched" '"mandate":' "ticket.dispatched carries the mandate"

issued=$("$STORE" query --table events --where type=mandate.issued)
assert_contains "$issued" '"requester":"aaron"' "mandate.issued carries the requester"
assert_contains "$issued" '"scope_paths":["sa/bin"]' "mandate.issued carries the scope paths"
assert_contains "$issued" '"rules_in_force":[' "mandate.issued carries the rules in force"
assert_contains "$issued" '"expires_at":"' "mandate.issued carries the expiry"

# ---------------------------------------------------------------------------
section "sa-dispatch mandate prints the canonical JSON mandate"
# ---------------------------------------------------------------------------
assert_exit 0 "mandate T-0030 exits 0" "$DISPATCH" mandate --ticket T-0030
out=$OUT
assert_contains "$out" '"ticket":"T-0030"' "the mandate names its ticket"
assert_contains "$out" '"requester":"aaron"' "the mandate names the requester"
assert_contains "$out" '"scope_paths":["sa/bin"]' "the mandate names the scope paths"
assert_contains "$out" '"rules_in_force":[' "the mandate names the rules in force"
assert_contains "$out" '"expires_at":"' "the mandate names the expiry"
canonical_form=$(printf '%s' "$out" | tr -d '\n')
assert_absent "$canonical_form" ', ' "the mandate is canonical JSON (no spaces after separators)"
assert_exit 2 "mandate for a ticket with no mandate exits 2" "$DISPATCH" mandate --ticket T-0001

# ---------------------------------------------------------------------------
section "sa-dispatch check-scope"
# ---------------------------------------------------------------------------
assert_exit 0 "a path inside the scope is allowed" \
  "$DISPATCH" check-scope --ticket T-0030 --path sa/bin/sa-kill
assert_exit 0 "the scope path itself is allowed" \
  "$DISPATCH" check-scope --ticket T-0030 --path sa/bin
assert_exit 4 "a path outside the scope is refused" \
  "$DISPATCH" check-scope --ticket T-0030 --path bin/fm-spawn.sh
assert_exit 4 "a sibling prefix is not inside the scope" \
  "$DISPATCH" check-scope --ticket T-0030 --path sa/bin-extra/x
assert_exit 2 "check-scope without a mandate exits 2" \
  "$DISPATCH" check-scope --ticket T-0001 --path sa/bin

# ---------------------------------------------------------------------------
section "the kill switch stops SA workers and never touches firstmate"
# ---------------------------------------------------------------------------
dummy="sa-test-worker-$$"
tmux new-session -d -s "$dummy" || bad "could not create the dummy tmux session"
tmux has-session -t "$dummy" 2>/dev/null && ok "the dummy tmux session exists" \
  || bad "the dummy tmux session exists"
tmux has-session -t firstmate 2>/dev/null && ok "the firstmate tmux session exists" \
  || bad "the firstmate tmux session exists"

printf '[{"id":"%s","backend":"tmux","endpoint":"%s"}]\n' "$dummy" "$dummy" >"$SA_HOME/workers.json"

assert_exit 0 "sa-kill --dry-run exits 0" "$KILL" --dry-run
out=$OUT
assert_contains "$out" "WOULD STOP: $dummy" "the dry run lists the dummy"
assert_contains "$out" "nothing stopped" "the dry run stops nothing"
tmux has-session -t "$dummy" 2>/dev/null && ok "the dry run left the dummy alive" \
  || bad "the dry run left the dummy alive"

assert_exit 0 "sa-kill exits 0" "$KILL"
out=$OUT
assert_contains "$out" "STOPPED: $dummy" "sa-kill reports the dummy stopped"
tmux has-session -t "$dummy" 2>/dev/null && bad "the dummy tmux session is gone" \
  || ok "the dummy tmux session is gone"
tmux has-session -t firstmate 2>/dev/null && ok "the firstmate tmux session is still alive" \
  || bad "the firstmate tmux session is still alive"

assert_exit 0 "sa-kill is idempotent" "$KILL"
out=$OUT
assert_contains "$out" "ALREADY-GONE: $dummy" "a second run reports the worker already gone"

for protected in firstmate fm-something ak47-anchor; do
  printf '[{"id":"%s","backend":"tmux","endpoint":"%s"}]\n' "$protected" "$protected" \
    >"$SA_HOME/workers.json"
  assert_exit 6 "sa-kill refuses the protected name '$protected'" "$KILL"
  out=$OUT
  assert_contains "$out" "REFUSED:" "the refusal is reported for '$protected'"
done

printf '[{"id":"x","backend":"tmux","endpoint":"firstmate:fm-abc"}]\n' >"$SA_HOME/workers.json"
assert_exit 6 "sa-kill refuses a window inside firstmate's session" "$KILL"
out=$OUT
assert_contains "$out" "REFUSED:" "the firstmate-session refusal is reported"
tmux has-session -t firstmate 2>/dev/null && ok "firstmate survived the refusal" \
  || bad "firstmate survived the refusal"

printf '[{"id":"x","backend":"tmux","endpoint":"other-session:fm-abc"}]\n' >"$SA_HOME/workers.json"
assert_exit 6 "sa-kill refuses a window outside the SA worker session" "$KILL"
out=$OUT
assert_contains "$out" "REFUSED:" "the foreign-session refusal is reported"

printf '[{"id":"x","backend":"bogus","endpoint":"x"}]\n' >"$SA_HOME/workers.json"
assert_exit 6 "sa-kill refuses an unsupported backend" "$KILL"

printf 'not json\n' >"$SA_HOME/workers.json"
assert_exit 2 "sa-kill refuses a corrupt registry" "$KILL"

rm -f "$SA_HOME/workers.json"
assert_exit 0 "sa-kill with no registry exits 0" "$KILL"
out=$OUT
assert_contains "$out" "no SA workers registered" "an empty registry is reported, not an error"

# ---------------------------------------------------------------------------
section "nothing in sa/ writes into firstmate's home"
# ---------------------------------------------------------------------------
if grep -rn 'Projects/firstmate' "$REPO/sa/bin" >/dev/null 2>&1; then
  bad "no sa/ path names firstmate's home"
else
  ok "no sa/ path names firstmate's home"
fi
if grep -q 'events_path\|sa_store' "$DISPATCH"; then
  bad "sa-dispatch never opens the event log itself"
else
  ok "sa-dispatch never opens the event log itself"
fi
if grep -q 'events_path\|sa_store' "$KILL"; then
  bad "sa-kill never opens the event log itself"
else
  ok "sa-kill never opens the event log itself"
fi

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
printf 'pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
if [ "$fail" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi
printf 'RESULT: PASS\n'
