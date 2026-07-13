#!/usr/bin/env bats
# Contract gate for the structured digest: schema, join-key honesty,
# anti-hallucination id checks, and the mechanical theme/KB recompute.
load helpers

setup() {
  setup_skill_tmp
  setup_digest_fixtures
  export CV_TOOL_CTX_CONVERSATION_ID="unavailable"
  unset CAROLINE_EXPECTED_KIND || true
}
teardown() { teardown_skill_tmp; }

run_validate() {  # $1 = digest file
  run "$SCRIPTS_DIR/validate-digest.sh" "$1" \
    "$WORKDIR/conversations.jsonl" "$WORKDIR/audit.jsonl"
}

mutate() {  # $1 = source fixture, $2 = jq program -> $WORKDIR/digest.json
  jq "$2" "$1" > "$WORKDIR/digest.json"
}

@test "valid daily digest passes and emits normalized JSON" {
  run_validate "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.kind == "daily"'
  [ "$(echo "$output" | jq -r '.themes[0].unique_customers')" = "2" ]
}

@test "valid weekly digest passes with kb candidate recomputed to 3" {
  run_validate "$WORKDIR/digest-weekly.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.kb_gap_candidates[0].unique_customers')" = "3" ]
}

@test "inflated theme unique_customers is overwritten with the recomputed count" {
  mutate "$WORKDIR/digest-daily.json" '.themes[0].unique_customers = 9'
  # capture stdout alone: run merges the recompute stderr notes into $output
  run bash -c "\"$SCRIPTS_DIR/validate-digest.sh\" \"$WORKDIR/digest.json\" \"$WORKDIR/conversations.jsonl\" \"$WORKDIR/audit.jsonl\" 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.themes[0].unique_customers')" = "2" ]
}

@test "daily theme below 2 recomputed unique customers is dropped, run still passes" {
  # convs 1+4 are the SAME contact -> recomputed 1
  mutate "$WORKDIR/digest-daily.json" \
    '.themes[0].conversation_ids = ["215474000000001","215474000000004"]'
  run bash -c "\"$SCRIPTS_DIR/validate-digest.sh\" \"$WORKDIR/digest.json\" \"$WORKDIR/conversations.jsonl\" \"$WORKDIR/audit.jsonl\" 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.themes | length')" = "0" ]
}

@test "hallucinated conversation_id in a finding fails and names the id" {
  mutate "$WORKDIR/digest-daily.json" \
    '.findings[0].conversation_ids = ["215474999999111"]'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"215474999999111"* ]]
  [[ "$output" == *"hallucinated"* ]]
}

@test "finding id present only in email-leak audit.jsonl passes" {
  mutate "$WORKDIR/digest-daily.json" \
    '.findings += [{"dimension":"voice","severity":"P0","text":"1 internal email echo caught","conversation_ids":["215474000000077"]}] | .severity.p0 = 1'
  printf '%s\n' '{"kind":"leak","marker":"email-leak","leak_class":"internal","snippet":"Jul 10 21:24:00 host openclaw[1]: [intercom:email-leak] conv=215474000000077 count=1 redacted=[\"<email>\"]"}' >> "$WORKDIR/audit.jsonl"
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 0 ]
}

@test "theme id present only in audit.jsonl still fails (no audit carve-out for themes)" {
  mutate "$WORKDIR/digest-daily.json" \
    '.themes[0].conversation_ids = ["215474000000099"]'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"215474000000099"* ]]
  [[ "$output" == *"themes/kb"* ]]
}

@test "malformed audit.jsonl line fails closed with a loud error" {
  printf '%s\n' 'NOT VALID JSON' >> "$WORKDIR/audit.jsonl"
  run_validate "$WORKDIR/digest-daily.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failing closed"* ]]
}

@test "guard item id present only in audit.jsonl passes (escalation carve-out)" {
  mutate "$WORKDIR/digest-daily.json" \
    '.guard.items = [{"type":"unanswered_escalation","conversation_id":"215474000000099"}] | .guard.caught_escalated = 1 | .severity.p1 = 1'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 0 ]
}

@test "guard item id in neither source fails" {
  mutate "$WORKDIR/digest-daily.json" \
    '.guard.items = [{"type":"unanswered_escalation","conversation_id":"215474999999222"}]'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
}

@test "tools skipped while join-key available fails" {
  export CV_TOOL_CTX_CONVERSATION_ID="available"
  run_validate "$WORKDIR/digest-daily.json"
  [ "$status" -eq 1 ]
}

@test "numeric tools score while join-key unavailable fails (fabricated)" {
  mutate "$WORKDIR/digest-daily.json" '.scores.tools = 5'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
}

@test "daily digest carrying kb_gap_candidates fails" {
  mutate "$WORKDIR/digest-daily.json" \
    '.kb_gap_candidates = [{"category":"question","label":"x","summary":"y","conversation_ids":["215474000000001","215474000000002","215474000000003"],"unique_customers":3,"proposed_kb_note":"z"}]'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
}

@test "weekly kb candidate with recomputed unique_customers < 3 fails" {
  # convs 1+2+4: contacts A,B,A -> recomputed 2
  mutate "$WORKDIR/digest-weekly.json" \
    '.kb_gap_candidates[0].conversation_ids = ["215474000000001","215474000000002","215474000000004"]'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
}

@test "missing scores.voice fails with a precise structural error" {
  mutate "$WORKDIR/digest-daily.json" 'del(.scores.voice)'
  run bash -c "\"$SCRIPTS_DIR/validate-digest.sh\" \"$WORKDIR/digest.json\" \"$WORKDIR/conversations.jsonl\" 2>&1 >/dev/null"
  [[ "$output" == *"scores.voice"* ]]
}

@test "type-mismatched scores object is reported, not silently passed" {
  mutate "$WORKDIR/digest-daily.json" '.scores = "broken"'
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
}

@test "CAROLINE_EXPECTED_KIND mismatch fails" {
  export CAROLINE_EXPECTED_KIND="weekly"
  run_validate "$WORKDIR/digest-daily.json"
  [ "$status" -eq 1 ]
}

@test "non-object digest fails" {
  echo '["not","an","object"]' > "$WORKDIR/digest.json"
  run_validate "$WORKDIR/digest.json"
  [ "$status" -eq 1 ]
}

@test "nothing is emitted on stdout when validation fails" {
  mutate "$WORKDIR/digest-daily.json" 'del(.guard)'
  # run merges stderr into $output, so capture stdout alone explicitly
  run bash -c "\"$SCRIPTS_DIR/validate-digest.sh\" \"$WORKDIR/digest.json\" \"$WORKDIR/conversations.jsonl\" 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
