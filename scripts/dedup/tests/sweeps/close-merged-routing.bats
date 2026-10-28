#!/usr/bin/env bats

# Pins the audit-routing logic in close-merged-tickets.sh: after the
# match step, each match consults check-customer-replied.py and the
# exit code routes to to_close.jsonl vs needs_human_reply.jsonl
# (with reason: audit_error / no_admin_reply_after_merge /
# no_customer_email). Without this test, a refactor that swaps the
# routing arms ships silently.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh"
  STAGE=$(mktemp -d)
  # PATH-shadow curl with a stub that emits a ClickUp-shaped tasks-list
  # response on the first call (so the ticket-pull loop has data) and an
  # empty page after.
  mkdir -p "$STAGE/bin"
  # Build the response payload up-front so heredocs don't have to escape it.
  cat > "$STAGE/tasks.json" <<'TASKSEOF'
{"tasks":[
  {"id":"T_REPLIED","description":"x ---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P_REPLIED\", \"customer_email\": \"replied@x.com\"} ---END-ACTION-REQUEST--- y","status":{"status":"to do"},"url":"u"},
  {"id":"T_NOTOLD","description":"x ---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P_NOTOLD\", \"customer_email\": \"notold@x.com\"} ---END-ACTION-REQUEST--- y","status":{"status":"to do"},"url":"u"},
  {"id":"T_ERR","description":"x ---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P_ERR\", \"customer_email\": \"err@x.com\"} ---END-ACTION-REQUEST--- y","status":{"status":"to do"},"url":"u"}
]}
TASKSEOF
  printf '{"tasks":[]}' > "$STAGE/empty.json"
  cat > "$STAGE/bin/curl" <<CURLEOF
#!/usr/bin/env bash
# Stub: ClickUp tasks-list on the first call, empty after. Honors
# real curl's -o <file> + -w '%{http_code}' contract.
STATE="$STAGE/curl-state"
out=/dev/stdout
emit_code=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) [ "\$2" = '%{http_code}' ] && emit_code=1; shift 2 ;;
    *) shift ;;
  esac
done
if [ ! -f "\$STATE" ]; then
  : > "\$STATE"
  cat "$STAGE/tasks.json" > "\$out"
else
  cat "$STAGE/empty.json" > "\$out"
fi
[ "\$emit_code" -eq 1 ] && printf '200'
exit 0
CURLEOF
  chmod +x "$STAGE/bin/curl"

  # Stub muso: emits one merge per ticket profile_id so all three match.
  # Real call shape: muso query --format json - (SQL on stdin) -> NDJSON.
  cat > "$STAGE/bin/muso-stub" <<'MUSOEOF'
#!/usr/bin/env bash
[ "${4:-}" = "-" ] && cat >/dev/null   # drain the stdin SQL
echo '{"merge_into":"P_REPLIED","profiles_ids":"[]","at":"2026-05-15 12:00:00.000 UTC"}'
echo '{"merge_into":"P_NOTOLD","profiles_ids":"[]","at":"2026-05-15 12:00:00.000 UTC"}'
echo '{"merge_into":"P_ERR","profiles_ids":"[]","at":"2026-05-15 12:00:00.000 UTC"}'
MUSOEOF
  chmod +x "$STAGE/bin/muso-stub"

  # Stub audit binary: route by email.
  cat > "$STAGE/bin/audit-stub.py" <<'AUDITEOF'
#!/usr/bin/env python3
import sys
email = sys.argv[1]
if 'replied@' in email: sys.exit(0)
if 'notold@' in email: sys.exit(1)
if 'err@'    in email: sys.exit(2)
sys.exit(3)
AUDITEOF
  chmod +x "$STAGE/bin/audit-stub.py"
}

teardown() {
  rm -rf "$STAGE"
  rm -f /tmp/.bats-curl-state-$$
}

@test "audit-routing: exit 0 -> to_close, exit 1 -> no_admin_reply, exit 2 -> audit_error" {
  rm -f /tmp/.bats-curl-state-$$
  run env \
    PATH="$STAGE/bin:$PATH" \
    MUSO_BIN="$STAGE/bin/muso-stub" \
    CHECK_CUSTOMER_REPLIED_BIN="$STAGE/bin/audit-stub.py" \
    CLICKUP_API_KEY=fake \
    MUSOAI_INTERCOM_TOKEN=fake \
    CLOSE_ADD_ASSIGNEES="" \
    bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  # T_REPLIED routed to to_close (no needs_human_reply_reason field).
  echo "$output" | grep -q '"task_id":"T_REPLIED"'
  echo "$output" | grep '"task_id":"T_REPLIED"' | grep -qv 'needs_human_reply_reason'
  # T_NOTOLD routed to needs_human_reply with no_admin_reply_after_merge.
  echo "$output" | grep '"task_id":"T_NOTOLD"' | grep -q 'no_admin_reply_after_merge'
  # T_ERR (audit exit 2) routed to needs_human_reply with audit_error.
  echo "$output" | grep '"task_id":"T_ERR"' | grep -q 'audit_error'
}

@test "audit-routing: non-2 audit exit codes (127, etc.) route to audit_error, not no_admin_reply" {
  # Regression: previously only exit 2 routed to audit_error; 127/137/etc.
  # silently routed to no_admin_reply_after_merge.
  rm -f /tmp/.bats-curl-state-$$
  cat > "$STAGE/bin/audit-stub.py" <<'AUDITEOF'
#!/usr/bin/env python3
import sys
sys.exit(127)
AUDITEOF
  chmod +x "$STAGE/bin/audit-stub.py"
  run env \
    PATH="$STAGE/bin:$PATH" \
    MUSO_BIN="$STAGE/bin/muso-stub" \
    CHECK_CUSTOMER_REPLIED_BIN="$STAGE/bin/audit-stub.py" \
    CLICKUP_API_KEY=fake \
    MUSOAI_INTERCOM_TOKEN=fake \
    CLOSE_ADD_ASSIGNEES="" \
    bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  # All tickets route to audit_error.
  echo "$output" | grep -q 'audit_error'
  if echo "$output" | grep -q 'no_admin_reply_after_merge'; then echo "unexpected match: no_admin_reply_after_merge" >&2; return 1; fi
}

@test "audit-routing: --skip-customer-reply-check copies all matches to to_close" {
  rm -f /tmp/.bats-curl-state-$$
  run env \
    PATH="$STAGE/bin:$PATH" \
    MUSO_BIN="$STAGE/bin/muso-stub" \
    CHECK_CUSTOMER_REPLIED_BIN="$STAGE/bin/audit-stub.py" \
    CLICKUP_API_KEY=fake \
    CLOSE_ADD_ASSIGNEES="" \
    bash "$SCRIPT" --dry-run --skip-customer-reply-check
  [ "$status" -eq 0 ]
  # All three tickets land in to_close; nothing under needs_human_reply.
  echo "$output" | grep -q '"task_id":"T_REPLIED"'
  echo "$output" | grep -q '"task_id":"T_NOTOLD"'
  echo "$output" | grep -q '"task_id":"T_ERR"'
  if echo "$output" | grep -q 'needs_human_reply_reason'; then echo "unexpected match: needs_human_reply_reason" >&2; return 1; fi
}
