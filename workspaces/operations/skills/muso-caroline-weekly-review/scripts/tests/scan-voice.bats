#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

write_convs() { cat > "$WORKDIR/conversations.redacted.jsonl"; }

@test "flags a phrase-blacklist hit in a Caroline-authored body" {
  write_convs <<'EOF'
{"id":"100000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question! Let me check on that."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' "$WORKDIR/voice-scan.jsonl")" = "blacklist" ]
  [ "$(jq -r '.marker' "$WORKDIR/voice-scan.jsonl")" = "great-question" ]
  [ "$(jq -r '.conv' "$WORKDIR/voice-scan.jsonl")" = "100000000000001" ]
}

@test "emits one row per blacklist phrase in a body" {
  write_convs <<'EOF'
{"id":"200000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"I understand your frustration. I will investigate this."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 2 ]
  grep -q 'understand-frustration' "$WORKDIR/voice-scan.jsonl"
  grep -q '"marker":"investigate"' "$WORKDIR/voice-scan.jsonl"
}

@test "counts em-dashes and en-dashes per body as dash rows" {
  write_convs <<'EOF'
{"id":"300000000000003","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Range 1–2 and — also — done."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.marker=="em-dash").count' "$WORKDIR/voice-scan.jsonl")" = "2" ]
  [ "$(jq -r 'select(.marker=="en-dash").count' "$WORKDIR/voice-scan.jsonl")" = "1" ]
}

@test "ignores tells that appear only in a CUSTOMER (non-admin) part" {
  write_convs <<'EOF'
{"id":"400000000000004","parts":[{"author":{"type":"user","id":"x"},"body":"Great question — really? I understand your frustration."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "ignores a Caroline reply that is on-voice (no dashes, no blacklist)" {
  write_convs <<'EOF'
{"id":"500000000000005","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Thanks for reaching out! Your export is ready to download."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "exits 0 with empty output over many clean convs (no set -e abort)" {
  # THE regression this script exists for: the deterministic scan must NEVER abort
  # the run when there are zero voice issues. The prose-instructed inline grader did
  # (a no-match sub-command under set -euo pipefail killed the whole daily run).
  write_convs <<'EOF'
{"id":"600000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Happy to help, your data is updating now."}]}
{"id":"600000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"All set, let me know if anything else comes up."}]}
{"id":"600000000000003","parts":[{"author":{"type":"user","id":"y"},"body":"thanks so much"}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "a null/absent body does not crash the scan" {
  write_convs <<'EOF'
{"id":"700000000000007","parts":[{"author":{"type":"admin","id":"caroline-admin-123"}}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "a malformed redacted line fails loud (non-zero), not a silent empty scan" {
  # Regression (QA review, PR #431): a broken conversations.redacted.jsonl (or any jq
  # failure) must abort the run, NOT report an empty successful scan that lets
  # Dimension A score a false clean. jq exits 0 on a no-match, so there is no `|| true`
  # to mask a real failure.
  printf '%s\n' '{"id":"1","parts":[]}' 'this is not valid json' > "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -ne 0 ]
}

@test "no input file -> empty result, exits 0" {
  rm -f "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl" 2>/dev/null || echo 0)" -eq 0 ]
}
