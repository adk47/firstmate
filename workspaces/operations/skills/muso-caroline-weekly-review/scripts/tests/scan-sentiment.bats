#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

write_convs() { cat > "$WORKDIR/conversations.redacted.jsonl"; }

@test "flags an explicit-frustration phrase in a CUSTOMER-authored body" {
  write_convs <<'EOF'
{"id":"100000000000001","parts":[{"author":{"type":"user","id":"c1"},"body":"are you actually checking my account?"}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.marker' "$WORKDIR/sentiment-scan.jsonl")" = "are-you-checking" ]
  [ "$(jq -r '.conv' "$WORKDIR/sentiment-scan.jsonl")" = "100000000000001" ]
}

@test "emits one row per frustration phrase in a body" {
  write_convs <<'EOF'
{"id":"200000000000002","parts":[{"author":{"type":"user","id":"c2"},"body":"this is useless, are you actually checking anything?"}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/sentiment-scan.jsonl")" -eq 2 ]
  grep -q '"marker":"this-is-useless"' "$WORKDIR/sentiment-scan.jsonl"
  grep -q '"marker":"are-you-checking"' "$WORKDIR/sentiment-scan.jsonl"
}

@test "does NOT score a frustration phrase inside an admin (Caroline) reply" {
  # The whole point of the customer-only filter: Caroline quoting/paraphrasing the
  # phrase (or a human agent) must not score against the customer's sentiment.
  write_convs <<'EOF'
{"id":"300000000000003","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"I hear that this is useless feels frustrating — let me fix it."}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/sentiment-scan.jsonl")" -eq 0 ]
  grep -q '^frustrated-convs: 0' "$WORKDIR/sentiment-summary.txt"
}

@test "matches you're-a-bot across apostrophe variants (straight / curly / none)" {
  write_convs <<'EOF'
{"id":"400000000000001","parts":[{"author":{"type":"user","id":"a"},"body":"honestly you're a bot"}]}
{"id":"400000000000002","parts":[{"author":{"type":"user","id":"b"},"body":"honestly you’re a bot"}]}
{"id":"400000000000003","parts":[{"author":{"type":"user","id":"c"},"body":"honestly youre a bot"}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/sentiment-scan.jsonl")" -eq 3 ]
}

@test "summary frustrated-convs counts DISTINCT convs, not raw hits" {
  write_convs <<'EOF'
{"id":"500000000000001","parts":[{"author":{"type":"user","id":"a"},"body":"this is useless and are you actually checking"}]}
{"id":"500000000000002","parts":[{"author":{"type":"user","id":"b"},"body":"human please"}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  grep -q '^frustrated-convs: 2' "$WORKDIR/sentiment-summary.txt"
  grep -q '^frustration-hits: 3' "$WORKDIR/sentiment-summary.txt"
}

@test "exits 0 with all-zero summary over clean convs (the no-set-e-abort regression)" {
  # THE regression this script exists for (2026-06-08): a hand-rolled jq with zero
  # frustration hits aborted the whole daily run under set -euo pipefail. The
  # deterministic scan must exit 0 and still write a summary.
  write_convs <<'EOF'
{"id":"600000000000001","parts":[{"author":{"type":"user","id":"a"},"body":"thanks so much, this worked great"}]}
{"id":"600000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Happy to help!"}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/sentiment-scan.jsonl")" -eq 0 ]
  [ -f "$WORKDIR/sentiment-summary.txt" ]
  grep -q '^frustrated-convs: 0' "$WORKDIR/sentiment-summary.txt"
  grep -q 'top-frustrated-convs: (none)' "$WORKDIR/sentiment-summary.txt"
}

@test "a null/absent body does not crash the scan" {
  write_convs <<'EOF'
{"id":"700000000000007","parts":[{"author":{"type":"user","id":"a"}}]}
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/sentiment-scan.jsonl")" -eq 0 ]
}

@test "missing redacted file yields an all-zero summary, exit 0" {
  rm -f "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/sentiment-summary.txt" ]
  grep -q '^frustrated-convs: 0' "$WORKDIR/sentiment-summary.txt"
}

@test "a malformed JSONL line fails LOUDLY (no silent false-clean)" {
  write_convs <<'EOF'
{"id":"800000000000001","parts":[{"author":{"type":"user","id":"a"},"body":"this is useless"}]}
this is not json
EOF
  run "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -ne 0 ]
}

@test "requires WORKDIR" {
  run env -u WORKDIR "$SCRIPTS_DIR/scan-sentiment.sh"
  [ "$status" -ne 0 ]
}
