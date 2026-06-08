#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }   # exports WORKDIR + CAROLINE_BOT_ADMIN_ID
teardown() { teardown_skill_tmp; }

# scan-tools.sh reads the RAW conversations.jsonl (NOT the redacted file) — see the
# script header: redact.sh scrubs support@muso.ai to "<email>", so the rubric's
# `email support@muso\.ai` regex can only match pre-redaction.
write_raw() { cat > "$WORKDIR/conversations.jsonl"; }

@test "flags 'email support@muso.ai' in a Caroline-authored reply" {
  write_raw <<'EOF'
{"id":"100000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Please email support@muso.ai for that."}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  grep -q '"marker":"email-support-address"' "$WORKDIR/tools-scan.jsonl"
  [ "$(jq -r '.conv' "$WORKDIR/tools-scan.jsonl" | head -1)" = "100000000000001" ]
}

@test "flags contact/reach-out-to/email support punts" {
  write_raw <<'EOF'
{"id":"200000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Please contact support about this."}]}
{"id":"200000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"You can reach out to support directly."}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"marker":"punt-to-support"' "$WORKDIR/tools-scan.jsonl")" -eq 2 ]
}

@test "does NOT flag the phrase in a CUSTOMER (non-admin) part" {
  write_raw <<'EOF'
{"id":"300000000000003","parts":[{"author":{"type":"user","id":"cust"},"body":"should I just email support@muso.ai or contact support?"}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/tools-scan.jsonl")" -eq 0 ]
  grep -q '^regression-convs: 0' "$WORKDIR/tools-summary.txt"
}

@test "emits conv+marker ONLY — never a body sample (PII-safe over raw bodies)" {
  write_raw <<'EOF'
{"id":"400000000000004","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Email support@muso.ai — ref jane.doe@example.com, ph 415-555-1212."}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  # No sample field at all, and none of the raw-body PII leaks into the output.
  [ "$(jq -r 'has("sample")' "$WORKDIR/tools-scan.jsonl" | sort -u)" = "false" ]
  ! grep -q 'example.com' "$WORKDIR/tools-scan.jsonl"
  ! grep -q '555-1212' "$WORKDIR/tools-scan.jsonl"
}

@test "documents the false-clean: the REDACTED form (<email>) does not match" {
  # This is the whole reason scan-tools reads the raw file. If it were pointed at
  # redacted data, support@muso.ai would already be "<email>" and the rubric regex
  # would score a silent false clean.
  write_raw <<'EOF'
{"id":"500000000000005","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Please email <email> for that."}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"marker":"email-support-address"' "$WORKDIR/tools-scan.jsonl")" -eq 0 ]
}

@test "summary regression-convs counts DISTINCT convs, not raw hits" {
  write_raw <<'EOF'
{"id":"600000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"email support@muso.ai and also contact support"}]}
{"id":"600000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"reach out to support"}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  grep -q '^regression-convs: 2' "$WORKDIR/tools-summary.txt"
}

@test "exits 0 with all-zero summary over clean convs (no-set-e-abort regression)" {
  write_raw <<'EOF'
{"id":"700000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Your export is ready, all set!"}]}
{"id":"700000000000002","parts":[{"author":{"type":"user","id":"c"},"body":"thanks!"}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/tools-scan.jsonl")" -eq 0 ]
  [ -f "$WORKDIR/tools-summary.txt" ]
  grep -q '^regression-convs: 0' "$WORKDIR/tools-summary.txt"
  grep -q 'top-regression-convs: (none)' "$WORKDIR/tools-summary.txt"
}

@test "a null/absent body does not crash the scan" {
  write_raw <<'EOF'
{"id":"800000000000007","parts":[{"author":{"type":"admin","id":"caroline-admin-123"}}]}
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/tools-scan.jsonl")" -eq 0 ]
}

@test "missing conversations.jsonl yields an all-zero summary, exit 0" {
  rm -f "$WORKDIR/conversations.jsonl"
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/tools-summary.txt" ]
  grep -q '^regression-convs: 0' "$WORKDIR/tools-summary.txt"
}

@test "a malformed JSONL line fails LOUDLY (no silent false-clean)" {
  write_raw <<'EOF'
{"id":"900000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"contact support"}]}
this is not json
EOF
  run "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -ne 0 ]
}

@test "requires WORKDIR" {
  run env -u WORKDIR "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -ne 0 ]
}

@test "requires CAROLINE_BOT_ADMIN_ID" {
  run env -u CAROLINE_BOT_ADMIN_ID "$SCRIPTS_DIR/scan-tools.sh"
  [ "$status" -ne 0 ]
}
