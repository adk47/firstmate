#!/usr/bin/env bats

# Regression tests for find-siblings.sh — primarily the exit-4 propagation
# from Trino failures. Code-reviewer second-pass caught that the previous
# implementation kept the error counter in a subshell (under `{ ... } | sort -u`),
# making the exit-4 path unreachable. These tests pin the parent-shell behavior.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SIB="$REPO_ROOT/scripts/dedup/lib/find-siblings.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

make_muso_stub() {
  # Args: comma-separated tokens to fail on. Stub exits 1 on those and
  # returns a fake sibling NDJSON row for any other query.
  # Invoked as: muso query --format json <sql> — SQL is argv[4].
  local fail_tokens="$1"
  cat > "$TMP/muso-stub" <<EOF
#!/usr/bin/env bash
q="\${4:-}"
for tok in $fail_tokens; do
  if echo "\$q" | grep -qF "\$tok"; then
    echo "stub: forced trino failure on \$tok" >&2
    exit 1
  fi
done
echo '{"_id":"sibling-fake-uuid"}'
EOF
  chmod +x "$TMP/muso-stub"
  echo "$TMP/muso-stub"
}

@test "find-siblings exits 4 when Trino fails on a raw_id lookup" {
  MUSO_BIN=$(make_muso_stub "spotify:abc")
  export MUSO_BIN
  profile='{"id":"self","raw_ids":["spotify:abc","tidal:xyz"],"ipis":[]}'
  run bash -c "echo '$profile' | bash '$SIB' self"
  [ "$status" -eq 4 ]
  # Stderr should explain — but bats `run` merges stderr/stdout when run without -e flag.
  echo "$output" | grep -q "trino lookups failed"
}

@test "find-siblings exits 0 when all Trino lookups succeed" {
  MUSO_BIN=$(make_muso_stub "NEVER_FAIL")
  export MUSO_BIN
  profile='{"id":"self","raw_ids":["spotify:abc"],"ipis":[]}'
  run bash -c "echo '$profile' | bash '$SIB' self"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sibling-fake-uuid"
}

@test "find-siblings exits 0 when profile has no external IDs (clean no-op)" {
  MUSO_BIN=$(make_muso_stub "NEVER_FAIL")
  export MUSO_BIN
  profile='{"id":"self","raw_ids":[],"ipis":[]}'
  run bash -c "echo '$profile' | bash '$SIB' self"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find-siblings soft-skips non-numeric IPI without exiting 4" {
  MUSO_BIN=$(make_muso_stub "NEVER_FAIL")
  export MUSO_BIN
  profile='{"id":"self","raw_ids":["spotify:abc"],"ipis":["12345","not-a-number"]}'
  run bash -c "echo '$profile' | bash '$SIB' self"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sibling-fake-uuid"
  # Soft-skip note appears on stderr but does not change exit code
}
