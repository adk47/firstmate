#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; install_router; }
teardown() { teardown_skill_tmp; }

# Per-id GET router (the shared helpers curl stub only serves one fixture).
# Per-id failure injection: if conv-<id>.status exists, its contents are used as the
# status line (e.g. "HTTP/1.1 404 Not Found") so a GET can be made to fail per conv.
install_router() {
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
H=""; B=""; U=""; a=("$@")
for i in "${!a[@]}"; do case "${a[$i]}" in -D) H="${a[$((i+1))]}";; -o) B="${a[$((i+1))]}";; https://*) U="${a[$i]}";; esac; done
id="${U##*/conversations/}"; id="${id%%\?*}"
status_line="HTTP/1.1 200 OK"
[ -f "${TEST_TMPDIR}/conv-$id.status" ] && status_line="$(cat "${TEST_TMPDIR}/conv-$id.status")"
[ -n "$H" ] && printf '%s\r\n' "$status_line" > "$H"
if [ -n "$B" ]; then
  if [ -f "${TEST_TMPDIR}/conv-$id.json" ]; then cat "${TEST_TMPDIR}/conv-$id.json" > "$B"; else echo '{}' > "$B"; fi
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
}

@test "flags an escalated conv with no human reply as open (human_replied=false) + builds the URL" {
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"AAA","markers":[]}
EOF
  cat > "$TEST_TMPDIR/conv-AAA.json" <<'EOF'
{"id":"AAA","conversation_parts":{"conversation_parts":[{"author":{"type":"user","id":"x"},"body":"hello? anyone?"}]}}
EOF
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.human_replied' "$WORKDIR/escalated-status.jsonl")" = "false" ]
  [ "$(jq -r '.url' "$WORKDIR/escalated-status.jsonl")" = "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/AAA" ]
}

@test "Caroline's own admin part does NOT count as a human reply" {
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"CARO","markers":[]}
EOF
  cat > "$TEST_TMPDIR/conv-CARO.json" <<'EOF'
{"id":"CARO","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"earlier caroline reply"}]}}
EOF
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.human_replied' "$WORKDIR/escalated-status.jsonl")" = "false" ]
}

@test "marks an escalated conv answered when a non-Caroline admin replied after the customer" {
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"BBB","markers":[]}
EOF
  cat > "$TEST_TMPDIR/conv-BBB.json" <<'EOF'
{"id":"BBB","source":{"author":{"type":"user"},"created_at":1000},"conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"jan-human-999"},"created_at":2000,"body":"I will help you out."}]}}
EOF
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.human_replied' "$WORKDIR/escalated-status.jsonl")" = "true" ]
}

@test "keeps an escalation OPEN when the only human reply predates the customer's latest message" {
  # Regression (QA review, PR #424): a human part from BEFORE the escalation must
  # not mark the conv answered while the customer is still waiting on a reply.
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"BEF","markers":[]}
EOF
  cat > "$TEST_TMPDIR/conv-BEF.json" <<'EOF'
{"id":"BEF","source":{"author":{"type":"user"},"created_at":1000},"conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"jan-human-999"},"created_at":1500,"body":"earlier human note"},{"author":{"type":"user"},"created_at":2000,"body":"hello? still waiting"}]}}
EOF
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.human_replied' "$WORKDIR/escalated-status.jsonl")" = "false" ]
}

@test "keeps an escalation OPEN when no customer message is timestamped (ordering unprovable)" {
  # Regression (QA review, PR #424): if the customer opener has no created_at we
  # cannot prove a timestamped human reply came AFTER the customer, so fail safe and
  # leave the escalation open rather than marking it answered.
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"NOTS","markers":[]}
EOF
  cat > "$TEST_TMPDIR/conv-NOTS.json" <<'EOF'
{"id":"NOTS","source":{"author":{"type":"user"},"body":"need help"},"conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"jan-human-999"},"created_at":1500,"body":"on it"}]}}
EOF
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.human_replied' "$WORKDIR/escalated-status.jsonl")" = "false" ]
}

@test "emits a conservative open row when the per-id GET fails (fail safe)" {
  # Regression (QA review, PR #424): a transient/4xx GET must not drop an escalated
  # conv from the P1 list -- emit human_replied:false + the URL instead of skipping.
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"FAIL","markers":[]}
EOF
  printf 'HTTP/1.1 404 Not Found' > "$TEST_TMPDIR/conv-FAIL.status"
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/escalated-status.jsonl")" -eq 1 ]
  [ "$(jq -r '.conv' "$WORKDIR/escalated-status.jsonl")" = "FAIL" ]
  [ "$(jq -r '.human_replied' "$WORKDIR/escalated-status.jsonl")" = "false" ]
  [ "$(jq -r '.url' "$WORKDIR/escalated-status.jsonl")" = "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/FAIL" ]
}

@test "checks only escalated rows (ignores stripped + non-reasoning audit rows)" {
  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"stripped","conv":"CCC","markers":[]}
{"kind":"leak","marker":"tool-leak","snippet":"x"}
EOF
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/escalated-status.jsonl")" -eq 0 ]
}

@test "no audit.jsonl -> no-op, exits 0" {
  rm -f "$WORKDIR/audit.jsonl"
  run "$SCRIPTS_DIR/check-escalated.sh"
  [ "$status" -eq 0 ]
}
