#!/usr/bin/env bats
load helpers

setup() {
  setup_tmp_env
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_AUDIT_LOG_DIR/${TODAY}.jsonl"
}
teardown() { teardown_tmp_env; }

@test "returns 0 when log file does not exist" {
  run "$SCRIPTS_DIR/count-approvals.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "counts only operator=clio, requester=clio, status=approved" {
  cat > "$LOG_FILE" <<'EOF'
{"operator":"clio","requester":"clio","status":"approved","endpoint":"/credit-requests"}
{"operator":"clio","requester":"clio","status":"approved","endpoint":"/credit-requests"}
{"operator":"clio","requester":"U038BM16T7W","status":"approved","endpoint":"/credit-requests"}
{"operator":"clio","requester":"clio","status":"user_verification_needed","endpoint":"/credit-requests"}
{"operator":"clio","requester":"clio","status":"rejected","endpoint":"/credit-requests"}
{"operator":"jan","requester":"clio","status":"approved","endpoint":"/credit-requests"}
EOF
  run "$SCRIPTS_DIR/count-approvals.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "uses UTC date for log file selection" {
  # Create a log file for yesterday UTC — should be ignored
  YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d "yesterday" +%Y-%m-%d)
  echo '{"operator":"clio","requester":"clio","status":"approved","endpoint":"/credit-requests"}' \
    > "$OPS_AUDIT_LOG_DIR/${YESTERDAY}.jsonl"
  run "$SCRIPTS_DIR/count-approvals.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "fails with exit 2 when OPS_AUDIT_LOG_DIR unset" {
  unset OPS_AUDIT_LOG_DIR
  run "$SCRIPTS_DIR/count-approvals.sh"
  [ "$status" -eq 2 ]
}

@test "fails with exit 4 when log has corrupt (non-JSON) lines" {
  # Refuse to silently undercount — a corrupt log could otherwise return 0
  # and make the bot uncap itself.
  cat > "$LOG_FILE" <<'EOF'
{"operator":"clio","requester":"clio","status":"approved"}
this is not json
{"operator":"clio","requester":"clio","status":"approved"}
EOF
  run "$SCRIPTS_DIR/count-approvals.sh"
  [ "$status" -eq 4 ]
  [[ "$stderr$output" == *"corrupt"* ]]
}

@test "fails with exit 5 when log path is a directory not a file" {
  # Defensive: someone mkdir'd today's path. Old script silently returned 0
  # via the `! -f` check, hiding the misconfiguration.
  rm -f "$LOG_FILE"
  mkdir -p "$LOG_FILE"
  run "$SCRIPTS_DIR/count-approvals.sh"
  [ "$status" -eq 5 ]
}
