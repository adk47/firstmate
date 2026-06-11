#!/usr/bin/env bats
# PII scrub of the structured digest: every string field is run through the
# shared lib/redact-core.sed patterns, and the result must still parse.
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

@test "email inside a JSON string is scrubbed" {
  echo '{"findings":[{"text":"customer john.doe@gmail.com exposed"}]}' > "$WORKDIR/d.json"
  run "$SCRIPTS_DIR/redact-json.sh" "$WORKDIR/d.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<email>"* ]]
  [[ "$output" != *"john.doe"* ]]
}

@test "phone number is scrubbed but 15-16 digit conversation ids survive" {
  echo '{"text":"call 415-555-0123 about conv 215474545718046"}' > "$WORKDIR/d.json"
  run "$SCRIPTS_DIR/redact-json.sh" "$WORKDIR/d.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<phone>"* ]]
  [[ "$output" == *"215474545718046"* ]]
}

@test "em and en dashes are normalized to hyphens" {
  printf '{"text":"voice — tells – everywhere"}\n' > "$WORKDIR/d.json"
  run "$SCRIPTS_DIR/redact-json.sh" "$WORKDIR/d.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"—"* ]]
  [[ "$output" != *"–"* ]]
}

@test "stripe ids are scrubbed" {
  echo '{"text":"refund for cus_AbC123xyz failed"}' > "$WORKDIR/d.json"
  run "$SCRIPTS_DIR/redact-json.sh" "$WORKDIR/d.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<stripe_id>"* ]]
}

@test "output is valid JSON (re-parse gate)" {
  echo '{"a":"x@y.com","b":[1,2],"c":{"d":"— text"}}' > "$WORKDIR/d.json"
  run bash -c "\"$SCRIPTS_DIR/redact-json.sh\" \"$WORKDIR/d.json\" | jq -e ."
  [ "$status" -eq 0 ]
}

@test "invalid JSON input fails loudly" {
  echo 'not json' > "$WORKDIR/d.json"
  run "$SCRIPTS_DIR/redact-json.sh" "$WORKDIR/d.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "reads stdin when no file argument is given" {
  run bash -c "echo '{\"t\":\"a@b.co\"}' | \"$SCRIPTS_DIR/redact-json.sh\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"<email>"* ]]
}
