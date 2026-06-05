#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }   # exports WORKDIR + CAROLINE_BOT_ADMIN_ID
teardown() { teardown_skill_tmp; }

@test "extracts leak audit lines (tool-leak + email-leak)" {
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<EOF
May 30 10:00:00 host openclaw[1]: [intercom:tool-leak] conv abc tool exposed
May 30 11:00:00 host openclaw[1]: ordinary log line, nothing to see
May 30 12:00:00 host openclaw[1]: [intercom:email-leak] conv def email shown
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"kind":"leak"' "$WORKDIR/audit.jsonl")" -eq 2 ]
}

@test "scrubs the leaked email from a leak record (no raw PII reaches the LLM)" {
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
May 30 10:00:00 host openclaw[1]: [intercom:email-leak] caroline exposed alice@example.com in a reply
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"kind":"leak"' "$WORKDIR/audit.jsonl")" -eq 1 ]
  ! grep -q "alice@example.com" "$WORKDIR/audit.jsonl"
  grep -q "<email>" "$WORKDIR/audit.jsonl"
  grep -q '"marker":"email-leak"' "$WORKDIR/audit.jsonl"
}

@test "allowlists tool-call args to safe categorical fields (drops all PII, not just emails)" {
  export CV_TOOL_CTX_CONVERSATION_ID="available"
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
May 30 10:00:00 host openclaw[1]: {"tool":"create_ticket","conversation_id":"215474545718046","args":{"email":"bob@example.com","name":"Jane Doe","profile_url":"https://muso.ai/p/abc","summary":"angry about FLAC export","customerProfileId":"uuid-123","details":"call me at 555-123-4567","tier":"2","actionType":"analytics-followup"}}
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  # join key + safe categorical fields are kept
  grep -q '"conversation_id":"215474545718046"' "$WORKDIR/audit.jsonl"
  grep -q '"tier":"2"' "$WORKDIR/audit.jsonl"
  grep -q '"actionType":"analytics-followup"' "$WORKDIR/audit.jsonl"
  # every PII / free-text arg is dropped (not just the email)
  ! grep -q "bob@example.com" "$WORKDIR/audit.jsonl"
  ! grep -q "Jane Doe" "$WORKDIR/audit.jsonl"
  ! grep -q "muso.ai/p/abc" "$WORKDIR/audit.jsonl"
  ! grep -q "angry about FLAC" "$WORKDIR/audit.jsonl"
  ! grep -q "uuid-123" "$WORKDIR/audit.jsonl"
  ! grep -q "555-123-4567" "$WORKDIR/audit.jsonl"
}

@test "writes an empty audit (no records) when nothing matches" {
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<EOF
May 30 10:00:00 host openclaw[1]: nothing interesting here
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/audit.jsonl")" -eq 0 ]
}

@test "surfaces a journalctl failure (exit non-zero, not a silent empty audit)" {
  # Override the journalctl stub to fail — a silent failure used to leave the
  # audit empty and the LLM with nothing to grade.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"journalctl read failed"* ]]
}

@test "extracts a valid tool-call JSON line when tool-ctx is available" {
  export CV_TOOL_CTX_CONVERSATION_ID="available"
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
May 30 10:00:00 host openclaw[1]: {"tool":"profile_status","conversation_id":"conv-1","args":{"x":1}}
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"kind":"tool_call"' "$WORKDIR/audit.jsonl")" -eq 1 ]
  grep -q '"conversation_id":"conv-1"' "$WORKDIR/audit.jsonl"
}

@test "skips a tool-call line missing conversation_id (invalid shape)" {
  export CV_TOOL_CTX_CONVERSATION_ID="available"
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
May 30 10:00:00 host openclaw[1]: {"tool":"create_ticket","args":{"no":"convid"}}
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  ! grep -q '"kind":"tool_call"' "$WORKDIR/audit.jsonl"
}

@test "does not extract tool calls when tool-ctx is unavailable (prereq gate)" {
  export CV_TOOL_CTX_CONVERSATION_ID="unavailable"
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
May 30 10:00:00 host openclaw[1]: {"tool":"profile_status","conversation_id":"conv-1","args":{}}
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  ! grep -q '"kind":"tool_call"' "$WORKDIR/audit.jsonl"
}

@test "journal window tracks CAROLINE_WINDOW_HOURS (default 30h, overridable to 168h)" {
  # Leak markers carry no conversation_id and no timestamp, so the journal --since
  # window MUST match the conversation fetch (same 30h default). A fixed 7d window
  # would re-surface the same leak as a fresh P0 on every daily run for a week.
  # Capture the --since arg verbatim (the shared stub's %q escapes the spaces in
  # "30 hours ago", so grep on the raw arg would not match).
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMPDIR}/journalctl.args"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"

  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--since 30 hours ago" "$TEST_TMPDIR/journalctl.args"

  : > "$TEST_TMPDIR/journalctl.args"
  export CAROLINE_WINDOW_HOURS=168
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--since 168 hours ago" "$TEST_TMPDIR/journalctl.args"
}

@test "parses ESCALATED and stripped reasoning-leak lines into reasoning_leak records" {
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
Jun 04 10:00:00 host openclaw[1]: [intercom:reasoning-leak] [intercom:default] ESCALATED conv=215474545718046 reason=internal-monologue markers=["skill-md","tone-calibration"] sample="Looking at the previous history"
Jun 04 11:00:00 host openclaw[1]: [intercom:reasoning-leak] [intercom:default] conv=998877665544001 action=stripped markers=["looking-at-history"] sample="some monologue"
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"kind":"reasoning_leak"' "$WORKDIR/audit.jsonl")" -eq 2 ]
  esc=$(jq -c 'select(.action=="escalated")' "$WORKDIR/audit.jsonl")
  [ "$(printf '%s' "$esc" | jq -r '.conv')" = "215474545718046" ]
  [ "$(printf '%s' "$esc" | jq -r '.reason')" = "internal-monologue" ]
  [ "$(printf '%s' "$esc" | jq -r '.markers | join(",")')" = "skill-md,tone-calibration" ]
  st=$(jq -c 'select(.action=="stripped")' "$WORKDIR/audit.jsonl")
  [ "$(printf '%s' "$st" | jq -r '.conv')" = "998877665544001" ]
  [ "$(printf '%s' "$st" | jq -r '.reason')" = "" ]
  [ "$(printf '%s' "$st" | jq -r '.markers[0]')" = "looking-at-history" ]
}

@test "scrubs PII from the reasoning-leak sample (no raw email reaches the audit)" {
  cat > "$TEST_TMPDIR/journal-fixture.txt" <<'EOF'
Jun 04 10:00:00 host openclaw[1]: [intercom:reasoning-leak] [intercom:default] ESCALATED conv=111 reason=no-separator markers=[] sample="email the customer at alice@example.com now"
EOF
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  ! grep -q "alice@example.com" "$WORKDIR/audit.jsonl"
  grep -q "<email>" "$WORKDIR/audit.jsonl"
}

@test "reads reasoning-leak lines from syslog when source=syslog" {
  cat > "$TEST_TMPDIR/fake-syslog" <<'EOF'
Jun 04 09:00:00 host openclaw-gateway-edge[1]: [intercom:reasoning-leak] [intercom:default] conv=222 action=stripped markers=["forbidden-words"] sample="x"
EOF
  export CAROLINE_REASONING_LEAK_SOURCE=syslog
  export CAROLINE_SYSLOG_PATH="$TEST_TMPDIR/fake-syslog"
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"kind":"reasoning_leak"' "$WORKDIR/audit.jsonl")" -eq 1 ]
  grep -q '"action":"stripped"' "$WORKDIR/audit.jsonl"
}

@test "source=none yields an empty audit without error" {
  export CAROLINE_REASONING_LEAK_SOURCE=none
  run "$SCRIPTS_DIR/fetch-audit.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/audit.jsonl")" -eq 0 ]
}
