#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_tmp_env
  export SKILL_DIR="$(dirname "$SCRIPTS_DIR")"
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  export RUN_ID
}
teardown() { teardown_tmp_env; }

# The runlog file path for the current run (helper for assertions).
runlog_file() {
  local day="${RUN_ID:0:4}-${RUN_ID:4:2}-${RUN_ID:6:2}"
  echo "$OPS_RUNLOG_DIR/$day/$RUN_ID.jsonl"
}

@test "started: writes subagent_started event with profile_id + paths" {
  PID="profile-001"
  PROMPT="$TEST_TMPDIR/prompt.md"; echo "x" > "$PROMPT"
  OUTF="$TEST_TMPDIR/out/profile-001.json"
  run "$SCRIPTS_DIR/spawn-investigation.sh" started \
    --run-id "$RUN_ID" --profile-id "$PID" --prompt-path "$PROMPT" --out-file "$OUTF"
  [ "$status" -eq 0 ]
  ev=$(grep -c '"event":"subagent_started"' "$(runlog_file)")
  [ "$ev" = "1" ]
  pid_ok=$(jq -r 'select(.event == "subagent_started") | .profile_id' "$(runlog_file)")
  [ "$pid_ok" = "$PID" ]
  prompt_ok=$(jq -r 'select(.event == "subagent_started") | .prompt_path' "$(runlog_file)")
  [ "$prompt_ok" = "$PROMPT" ]
}

@test "completed: ok state when child wrote valid JSON with verdict" {
  PID="profile-002"
  OUTF="$TEST_TMPDIR/out/profile-002.json"
  mkdir -p "$(dirname "$OUTF")"
  jq -n -c '{verdict:"LEGITIMATE", reason:"found on 2 hosts", evidence_excerpts:[{host:"a",url:"u",excerpt:"e"}]}' > "$OUTF"
  run "$SCRIPTS_DIR/spawn-investigation.sh" completed \
    --run-id "$RUN_ID" --profile-id "$PID" --out-file "$OUTF"
  [ "$status" -eq 0 ]
  ev=$(grep -c '"event":"subagent_completed_ok"' "$(runlog_file)")
  [ "$ev" = "1" ]
  vd=$(jq -r 'select(.event == "subagent_completed_ok") | .verdict' "$(runlog_file)")
  [ "$vd" = "LEGITIMATE" ]
}

@test "completed: missing_json state when child wrote nothing (exit 3)" {
  PID="profile-003"
  OUTF="$TEST_TMPDIR/out/profile-003.json"
  # Do NOT create the file — simulate failed subagent
  run "$SCRIPTS_DIR/spawn-investigation.sh" completed \
    --run-id "$RUN_ID" --profile-id "$PID" --out-file "$OUTF"
  [ "$status" -eq 3 ]
  ev=$(grep -c '"event":"subagent_completed_missing_json"' "$(runlog_file)")
  [ "$ev" = "1" ]
}

@test "completed: invalid_json state when child wrote garbage (exit 3)" {
  PID="profile-004"
  OUTF="$TEST_TMPDIR/out/profile-004.json"
  mkdir -p "$(dirname "$OUTF")"
  echo "not json {{{" > "$OUTF"
  run "$SCRIPTS_DIR/spawn-investigation.sh" completed \
    --run-id "$RUN_ID" --profile-id "$PID" --out-file "$OUTF"
  [ "$status" -eq 3 ]
  ev=$(grep -c '"event":"subagent_completed_invalid_json"' "$(runlog_file)")
  [ "$ev" = "1" ]
}

@test "completed: invalid_shape when JSON valid but no .verdict (exit 3)" {
  PID="profile-005"
  OUTF="$TEST_TMPDIR/out/profile-005.json"
  mkdir -p "$(dirname "$OUTF")"
  jq -n -c '{reason:"forgot the verdict field"}' > "$OUTF"
  run "$SCRIPTS_DIR/spawn-investigation.sh" completed \
    --run-id "$RUN_ID" --profile-id "$PID" --out-file "$OUTF"
  [ "$status" -eq 3 ]
  ev=$(grep -c '"event":"subagent_completed_invalid_shape"' "$(runlog_file)")
  [ "$ev" = "1" ]
}

@test "started: missing required arg exits 2" {
  run "$SCRIPTS_DIR/spawn-investigation.sh" started --run-id "$RUN_ID"
  [ "$status" -eq 2 ]
}

@test "phase: unknown phase exits 2" {
  run "$SCRIPTS_DIR/spawn-investigation.sh" totally-bogus --run-id "$RUN_ID" --profile-id p1
  [ "$status" -eq 2 ]
}
