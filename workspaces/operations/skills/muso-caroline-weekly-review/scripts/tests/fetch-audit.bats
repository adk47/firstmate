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
