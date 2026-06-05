#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  # Fake intercom plugin config with botAdminId
  export INTERCOM_CONFIG_JSON="$WORKDIR/intercom.json"
  # Mirror the real edge gateway-config shape: channels.intercom.accounts.default
  cat > "$INTERCOM_CONFIG_JSON" <<EOF
{"channels":{"intercom":{"accounts":{"default":{"botAdminId":"caroline-admin-123"}}}}}
EOF
  # Fake support-tools source path (Dimension B prereq probe target)
  export SUPPORT_TOOLS_INDEX="$WORKDIR/support-tools-index.ts"
  echo "export const tool = (ctx) => { return ctx.sessionId; };" > "$SUPPORT_TOOLS_INDEX"
}
teardown() { teardown_skill_tmp; }

@test "fails when MUSOAI_INTERCOM_TOKEN unset" {
  unset MUSOAI_INTERCOM_TOKEN
  run "$SCRIPTS_DIR/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN"* ]]
}

@test "fails when intercom config missing botAdminId" {
  echo '{"channels":{"intercom":{"accounts":{"default":{}}}}}' > "$INTERCOM_CONFIG_JSON"
  cd "$TEST_TMPDIR"
  run "$SCRIPTS_DIR/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"botAdminId"* ]]
}

@test "exports CAROLINE_BOT_ADMIN_ID and WORKDIR on success" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123","email":"caroline@muso.ai"}]}
EOF
  cd "$TEST_TMPDIR"
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CAROLINE_BOT_ADMIN_ID|\$WORKDIR\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"caroline-admin-123"* ]]
  # WORKDIR is a mktemp dir; on macOS it lives under /var/folders, not /tmp
  [[ "$output" == *"caroline-review-"* ]]
}

@test "fails when git worktree dirty" {
  cd "$TEST_TMPDIR"
  git init -q
  echo "x" > untracked.txt
  run "$SCRIPTS_DIR/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"clean"* ]] || [[ "$output" == *"dirty"* ]]
}

@test "detects CV_TOOL_CTX_CONVERSATION_ID unavailable when support-tools doesn't read ctx.conversationId" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CV_TOOL_CTX_CONVERSATION_ID\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable"* ]]
}

@test "detects CV_TOOL_CTX_CONVERSATION_ID available when support-tools reads ctx.conversationId" {
  echo "export const tool = (ctx) => { return ctx.conversationId; };" > "$SUPPORT_TOOLS_INDEX"
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CV_TOOL_CTX_CONVERSATION_ID\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"available"* ]]
}

@test "passes when conversations/search reachability probe returns 200" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  echo "200" > "$TEST_TMPDIR/curl-http-code"
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh'"
  [ "$status" -eq 0 ]
}

@test "fails when conversations/search reachability probe returns non-200" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  echo "400" > "$TEST_TMPDIR/curl-http-code"
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe returned HTTP"* ]]
}

@test "reasoning-leak source = journalctl when the edge journal is readable" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CAROLINE_REASONING_LEAK_SOURCE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"journalctl"* ]]
}

@test "reasoning-leak source falls back to syslog when journalctl is unreadable" {
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  : > "$TEST_TMPDIR/fake-syslog"
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "cd '$TEST_TMPDIR' && export CAROLINE_SYSLOG_PATH='$TEST_TMPDIR/fake-syslog' && source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CAROLINE_REASONING_LEAK_SOURCE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"syslog"* ]]
}

@test "reasoning-leak source = none when neither journalctl nor syslog is readable (still exits 0)" {
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "cd '$TEST_TMPDIR' && export CAROLINE_SYSLOG_PATH='$TEST_TMPDIR/does-not-exist' && source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CAROLINE_REASONING_LEAK_SOURCE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]]
}

@test "fails when gh auth status fails" {
  # Override the gh stub to fail for auth status
  cat > "$TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 1
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  run bash -c "cd '$TEST_TMPDIR' && source '$SCRIPTS_DIR/preflight.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh auth"* ]]
}
