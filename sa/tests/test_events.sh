#!/usr/bin/env bash
# test_events.sh - the SA-04 proof script.
#
# Proves the delivery contract (design.md section 9) rather than describing it:
#   * a PR check failure reaches the owning worker's inbox by code, with a
#     receipt, and the receipt is a real sha256 of the delivered bytes
#   * emitting the same event twice delivers exactly once
#   * a delivery failure records outbox.failed with its attempt and error, and
#     `sa-events retry` succeeds once the target is writable
#   * the delivery path contains no model call and no sa-cli verb
#   * sa-events never opens events.jsonl itself (the Engine is the sole writer)
#
# Usage:  sa/tests/test_events.sh            (from anywhere)
#
# The store-dependent steps need sa/bin/sa-store (SA-01, design.md section 6).
# When it is absent they SKIP with a loud message and the script exits non-zero,
# so a missing dependency can never look like a pass.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVENTS="$REPO/sa/bin/sa-events"
STORE="$REPO/sa/bin/sa-store"

VERBS=(emit deliver outbox retry)

pass=0
fail=0
skip=0

ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf 'SKIP  %s\n' "$1"; skip=$((skip + 1)); }

section() { printf '\n== %s ==\n' "$1"; }

# --------------------------------------------------------------------------- 0
section "dependency: the SA-01 store"

if [ ! -x "$STORE" ]; then
  skipped "SKIP: sa-store not yet on main - sa/bin/sa-store is absent"
  printf '\n== summary ==\npass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
  printf 'RESULT: INCOMPLETE (sa-store missing; this is not a pass)\n'
  exit 1
fi
ok "sa/bin/sa-store is present"

# --------------------------------------------------------------------------- 1
section "sa-events verb surface"

help_out="$("$EVENTS" --help 2>&1)"
help_rc=$?
if [ "$help_rc" -eq 0 ]; then ok "sa-events --help exits 0"; else bad "sa-events --help exits $help_rc"; fi

for v in "${VERBS[@]}"; do
  if printf '%s\n' "$help_out" | grep -Eq "^[[:space:]]+$v([[:space:]]|$)"; then
    ok "help lists verb: $v"
  else
    bad "help does not list verb: $v"
  fi
done

out="$("$EVENTS" definitely-not-a-verb 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then ok "unknown verb exits non-zero ($rc)"; else bad "unknown verb exited 0"; fi
if printf '%s' "$out" | grep -q "invalid choice"; then
  ok "unknown verb is refused with a usage error"
else
  bad "unknown verb output: $out"
fi

# --------------------------------------------------------------------------- 2
section "no model call and no sa-cli in the delivery path"

if grep -nE 'sa-cli|openrouter|anthropic|openai|gpt-|claude|langchain' "$EVENTS" >/dev/null 2>&1; then
  bad "delivery path mentions a router verb or a model provider"
else
  ok "no router verb and no model provider anywhere in sa/bin/sa-events"
fi

if grep -n 'events\.jsonl' "$EVENTS" >/dev/null 2>&1; then
  bad "sa-events references events.jsonl directly"
else
  ok "sa-events never opens events.jsonl (the Engine is the sole writer)"
fi

runs="$(grep -c 'subprocess\.run(' "$EVENTS")"
if [ "$runs" = "1" ] && grep -q 'str(STORE)' "$EVENTS"; then
  ok "the only external process spawned is sa-store"
else
  bad "subprocess.run appears $runs times without a single sa-store target"
fi

# --------------------------------------------------------------------------- 3
section "delivery: a PR check failure reaches the owner's inbox"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SA_HOME="$TMP/home"
mkdir -p "$SA_HOME"

"$STORE" append --type ticket.created --actor router --ticket T-0001 \
  --payload '{"title":"Fix CI","body":"the ci check is red","requester":"test_events.sh","acceptance":{"command":"true"}}' >/dev/null
"$STORE" append --type assignment.created --actor router --ticket T-0001 \
  --payload '{"owner":"sa-worker-1","reason":"only worker with the scope"}' >/dev/null

eid="$("$EVENTS" emit --type pr.check_failed --ticket T-0001 --payload '{"check":"ci"}')"
if printf '%s' "$eid" | grep -Eq '^ev-[0-9]{16}$'; then
  ok "emit printed an event id: $eid"
else
  bad "emit printed '$eid', not an event id"
fi

deliver_out="$("$EVENTS" deliver)"
deliver_rc=$?
if [ "$deliver_rc" -eq 0 ]; then ok "deliver exits 0"; else bad "deliver exits $deliver_rc: $deliver_out"; fi
if printf '%s' "$deliver_out" | grep -q '"state":"delivered"'; then
  ok "deliver printed a delivered receipt"
else
  bad "deliver printed: $deliver_out"
fi

msg="$SA_HOME/inbox/sa-worker-1/$eid.json"
if [ -f "$msg" ]; then ok "message landed at inbox/sa-worker-1/$eid.json"; else bad "no message at $msg"; fi

if grep -q '"type":"pr.check_failed"' "$msg" 2>/dev/null; then
  ok "message body carries the event type"
else
  bad "message body does not carry the event type"
fi

want_sha="$(sha256sum "$msg" | cut -d' ' -f1)"
got_sha="$(printf '%s' "$deliver_out" | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p')"
if [ -n "$got_sha" ] && [ "$want_sha" = "$got_sha" ]; then
  ok "receipt sha256 matches the delivered bytes"
else
  bad "receipt sha256 '$got_sha' != file sha256 '$want_sha'"
fi

outbox="$("$EVENTS" outbox)"
if printf '%s' "$outbox" | grep -q '"state":"delivered"'; then
  ok "outbox shows the delivered row"
else
  bad "outbox: $outbox"
fi

# --------------------------------------------------------------------------- 4
section "idempotency: the same event emitted twice delivers once"

eid2="$("$EVENTS" emit --type pr.check_failed --ticket T-0001 --payload '{"check":"ci"}')"
if [ "$eid2" = "$eid" ]; then
  ok "re-emitting the same event returns the same id ($eid)"
else
  bad "re-emit produced a different id: $eid2 != $eid"
fi

"$EVENTS" deliver >/dev/null
"$EVENTS" deliver >/dev/null

count="$(find "$SA_HOME/inbox/sa-worker-1" -maxdepth 1 -type f | wc -l | tr -d ' ')"
if [ "$count" = "1" ]; then
  ok "exactly one message in the owner's inbox"
else
  bad "inbox holds $count messages, expected 1"
fi

receipts="$(grep -c '"type":"outbox.delivered"' "$SA_HOME/events.jsonl")"
if [ "$receipts" = "1" ]; then
  ok "exactly one outbox.delivered receipt in the log"
else
  bad "log holds $receipts outbox.delivered events, expected 1"
fi

enqueued="$(grep -c '"type":"outbox.enqueued"' "$SA_HOME/events.jsonl")"
if [ "$enqueued" = "1" ]; then
  ok "exactly one outbox.enqueued row for the event"
else
  bad "log holds $enqueued outbox.enqueued events, expected 1"
fi

# --------------------------------------------------------------------------- 5
section "retry: a failed delivery is recorded and then succeeds"

"$STORE" append --type ticket.created --actor router --ticket T-0002 \
  --payload '{"title":"Fix lint","body":"the lint check is red","requester":"test_events.sh","acceptance":{"command":"true"}}' >/dev/null
"$STORE" append --type assignment.created --actor router --ticket T-0002 \
  --payload '{"owner":"sa-worker-2","reason":"only worker with the scope"}' >/dev/null

# The target is unwritable: the owner's inbox path is a regular file, so the
# message cannot be created there. Deterministic regardless of the test uid.
mkdir -p "$SA_HOME/inbox"
: > "$SA_HOME/inbox/sa-worker-2"

eid3="$("$EVENTS" emit --type pr.check_failed --ticket T-0002 --payload '{"check":"lint"}')"
fail_out="$("$EVENTS" deliver)"
fail_rc=$?
if [ "$fail_rc" -ne 0 ]; then ok "deliver exits non-zero on a failed delivery"; else bad "deliver exited 0 despite an unwritable target"; fi
if printf '%s' "$fail_out" | grep -q '"state":"failed"'; then
  ok "deliver printed a failed receipt"
else
  bad "deliver printed: $fail_out"
fi
if printf '%s' "$fail_out" | grep -q '"attempt":1'; then
  ok "the failure records attempt 1"
else
  bad "the failure does not record attempt 1: $fail_out"
fi
if printf '%s' "$fail_out" | grep -q 'not a directory'; then
  ok "the failure records the error"
else
  bad "the failure does not record the error: $fail_out"
fi

failed_rows="$("$EVENTS" outbox --state failed)"
if printf '%s' "$failed_rows" | grep -q "\"$eid3\""; then
  ok "outbox --state failed shows the failed event"
else
  bad "outbox --state failed: $failed_rows"
fi

# Fix the target and retry.
rm -f "$SA_HOME/inbox/sa-worker-2"
retry_out="$("$EVENTS" retry)"
retry_rc=$?
if [ "$retry_rc" -eq 0 ]; then ok "retry exits 0 once the target is writable"; else bad "retry exits $retry_rc: $retry_out"; fi
if printf '%s' "$retry_out" | grep -q '"state":"delivered"'; then
  ok "retry printed a delivered receipt"
else
  bad "retry printed: $retry_out"
fi
if [ -f "$SA_HOME/inbox/sa-worker-2/$eid3.json" ]; then
  ok "the retried message landed in the owner's inbox"
else
  bad "the retried message did not land"
fi

delivered_rows="$("$EVENTS" outbox --state delivered)"
if printf '%s' "$delivered_rows" | grep -q "\"$eid3\""; then
  ok "outbox --state delivered shows the retried event"
else
  bad "outbox --state delivered: $delivered_rows"
fi

# A second retry has nothing to do and must not re-deliver.
retry_again="$("$EVENTS" retry)"
if [ -z "$retry_again" ]; then
  ok "a second retry is a no-op"
else
  bad "a second retry produced output: $retry_again"
fi

# --------------------------------------------------------------------------- 6
section "unassigned tickets fail loudly instead of silently dropping"

"$STORE" append --type ticket.created --actor router --ticket T-0003 \
  --payload '{"title":"Nobody owns this","body":"no assignment","requester":"test_events.sh","acceptance":{"command":"true"}}' >/dev/null
eid4="$("$EVENTS" emit --type pr.check_failed --ticket T-0003 --payload '{"check":"ci"}')"
unassigned_out="$("$EVENTS" deliver --event-id "$eid4")"
unassigned_rc=$?
if [ "$unassigned_rc" -ne 0 ]; then ok "an unassigned ticket fails delivery"; else bad "an unassigned ticket delivered anyway"; fi
if printf '%s' "$unassigned_out" | grep -q 'no assigned owner'; then
  ok "the failure names the missing assignment"
else
  bad "the failure does not name the missing assignment: $unassigned_out"
fi

# --------------------------------------------------------------------------- 7
section "canonical JSON"

if "$EVENTS" outbox | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "outbox prints valid JSON"
else
  bad "outbox does not print valid JSON"
fi

if "$EVENTS" outbox | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
obj = json.loads(raw)
want = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
sys.exit(0 if raw == want else 1)
' 2>/dev/null; then
  ok "outbox prints canonical JSON"
else
  bad "outbox is not canonical JSON"
fi

# --------------------------------------------------------------------------- 8
section "summary"

printf 'pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
if [ "$fail" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi
if [ "$skip" -ne 0 ]; then
  printf 'RESULT: INCOMPLETE\n'
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
