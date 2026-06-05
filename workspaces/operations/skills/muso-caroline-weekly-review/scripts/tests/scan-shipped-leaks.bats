#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

write_convs() { cat > "$WORKDIR/conversations.redacted.jsonl"; }

@test "catches an INTERNAL tell in a Caroline-authored shipped reply" {
  write_convs <<'EOF'
{"id":"100000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"The ticket_id is set; here is your answer."}]}
EOF
  run "$SCRIPTS_DIR/scan-shipped-leaks.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.marker' "$WORKDIR/shipped-leaks.jsonl")" = "json-ticket-id" ]
  [ "$(jq -r '.conv' "$WORKDIR/shipped-leaks.jsonl")" = "100000000000001" ]
}

@test "catches a META_STRONG tell" {
  write_convs <<'EOF'
{"id":"200000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"in her artist name she goes by X, so I updated it."}]}
EOF
  run "$SCRIPTS_DIR/scan-shipped-leaks.sh"
  [ "$status" -eq 0 ]
  grep -q 'in-pronoun-artist-name' "$WORKDIR/shipped-leaks.jsonl"
}

@test "ignores a clean reply" {
  write_convs <<'EOF'
{"id":"300000000000003","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Thanks for reaching out! Your export is ready."}]}
EOF
  run "$SCRIPTS_DIR/scan-shipped-leaks.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/shipped-leaks.jsonl")" -eq 0 ]
}

@test "ignores a tell that appears only in a CUSTOMER (non-admin) part" {
  write_convs <<'EOF'
{"id":"400000000000004","parts":[{"author":{"type":"user","id":"x"},"body":"your SKILL.md says to email support"}]}
EOF
  run "$SCRIPTS_DIR/scan-shipped-leaks.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/shipped-leaks.jsonl")" -eq 0 ]
}

@test "ignores a META_WEAK-only body (META_WEAK is intentionally not mirrored)" {
  # "let her know" is a META_WEAK marker in the guard; it must NOT fire a standalone
  # shipped-leak hit (context-free single META_WEAK markers are ordinary CS language).
  write_convs <<'EOF'
{"id":"500000000000005","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"I will let her know once your export is ready."}]}
EOF
  run "$SCRIPTS_DIR/scan-shipped-leaks.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/shipped-leaks.jsonl")" -eq 0 ]
}

@test "no input file -> empty result, no error" {
  rm -f "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-shipped-leaks.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/shipped-leaks.jsonl" 2>/dev/null || echo 0)" -eq 0 ]
}

@test "drift sentinel: MIRRORED_MARKER_COUNT matches INTERNAL+META_STRONG in the guard source" {
  # If someone adds/removes a marker in sanitize-reasoning-leak.ts without re-syncing
  # the mirror in scan-shipped-leaks.sh, this fails loudly.
  ts="$SCRIPTS_DIR/../../../../../plugins/intercom/src/sanitize-reasoning-leak.ts"
  [ -f "$ts" ] || skip "guard source not found at $ts"
  # Count only entry lines (`{ name: "skill-md", ... }`), NOT the type-annotation
  # `{ name: string; re: RegExp }[]` on each `const` declaration line.
  internal=$(awk '/const INTERNAL/,/^\];/' "$ts" | grep -c 'name: "')
  strong=$(awk '/const META_STRONG/,/^\];/' "$ts" | grep -c 'name: "')
  live=$((internal + strong))
  mirrored=$(grep -oE 'MIRRORED_MARKER_COUNT=[0-9]+' "$SCRIPTS_DIR/scan-shipped-leaks.sh" | cut -d= -f2)
  [ "$live" -eq "$mirrored" ] || {
    echo "guard source has $live INTERNAL+META_STRONG markers but the mirror declares $mirrored; re-sync scan-shipped-leaks.sh" >&2
    return 1
  }
}
