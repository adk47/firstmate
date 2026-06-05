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

# --- voice-summary.txt: the deterministic AGGREGATE the grader reads verbatim. ---
# scan-voice.sh emits per-hit rows (voice-scan.jsonl) AND a precomputed summary so the
# grader never aggregates the JSONL itself. Letting the LLM aggregate caused the
# 2026-06-04 shadow proof-run to error: the codex agent ran `group_by(.kind+":"+.marker)`
# over voice-scan.jsonl WITHOUT `-s`, jq threw "Cannot index string with string", and the
# whole daily run failed with nothing delivered (slurp must happen inside the script).

@test "voice-summary.txt aggregates em/en dash totals and distinct conv counts" {
  write_convs <<'EOF'
{"id":"111","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"a — b — c"},{"author":{"type":"admin","id":"caroline-admin-123"},"body":"one more —"}]}
{"id":"222","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"x – y – z – w"}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/voice-summary.txt" ]
  grep -qx 'em-dash: 3 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'en-dash: 3 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'dash-total: 6 tells' "$WORKDIR/voice-summary.txt"
  # conv 111 = 3 em-dash tells, conv 222 = 3 en-dash tells -> both surface in top-dash-convs
  grep -q '111(3)' "$WORKDIR/voice-summary.txt"
  grep -q '222(3)' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt tallies phrase-blacklist hits by marker" {
  write_convs <<'EOF'
{"id":"333","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question! I will investigate this."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'blacklist-total: 2' "$WORKDIR/voice-summary.txt"
  grep -q 'great-question:1' "$WORKDIR/voice-summary.txt"
  grep -q 'investigate:1' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt blacklist-by-marker counts HITS (rows), consistent with blacklist-total, when a marker repeats across parts in one conv" {
  # Regression (QA #432): blacklist-total counts rows and the rubric scores -1 PER hit
  # (per {kind:"blacklist"} row), so blacklist-by-marker must also be a hit count. Two
  # "Great question" hits in ONE conversation = 2 rows -> total 2 AND great-question:2,
  # not 1 (a distinct-conv count would disagree with the total and the score).
  write_convs <<'EOF'
{"id":"555","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question, let me look."},{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question again, checking now."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -rs 'map(select(.kind=="blacklist"))|length' "$WORKDIR/voice-scan.jsonl")" -eq 2 ]
  grep -qx 'blacklist-total: 2' "$WORKDIR/voice-summary.txt"
  grep -q 'great-question:2' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt reports all-zero on a clean run" {
  write_convs <<'EOF'
{"id":"444","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Thanks for reaching out, your export is ready."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'em-dash: 0 tells across 0 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'dash-total: 0 tells' "$WORKDIR/voice-summary.txt"
  grep -qx 'top-dash-convs: (none)' "$WORKDIR/voice-summary.txt"
  grep -qx 'blacklist-total: 0' "$WORKDIR/voice-summary.txt"
  grep -qx 'blacklist-by-marker: (none)' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt is written (all-zero) even when there is no input file" {
  rm -f "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/voice-summary.txt" ]
  grep -qx 'dash-total: 0 tells' "$WORKDIR/voice-summary.txt"
  grep -qx 'blacklist-total: 0' "$WORKDIR/voice-summary.txt"
}
