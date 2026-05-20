#!/usr/bin/env bats

# Tests for scan-name-clusters.sh — the proactive sweep that finds dupes
# nobody filed a ticket for, by bucketing matvw_catalog_profile on name.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SWEEP="$REPO_ROOT/scripts/dedup/sweeps/scan-name-clusters.sh"
  TMP=$(mktemp -d)
  # Force find-dupes.sh path lookups to a controlled location so we can stub.
  export DEDUP_FIND_DUPES_BIN="$TMP/find-dupes-stub.sh"
}

teardown() {
  rm -rf "$TMP"
}

make_trino_stub() {
  # First call (the name-bucket query): emit a fixed set of clusters.
  # Stub does NOT receive sub-find-name-matches queries because those will be
  # routed through the stubbed find-dupes binary.
  cat > "$TMP/trino-stub.sh" <<'EOF'
#!/usr/bin/env bash
sql="${1:-}"
if echo "$sql" | grep -q 'GROUP BY lower(name)'; then
  # name, cluster_size
  echo '"ali zain","8"'
  echo '"empire","30"'
  echo '"john smith","3"'
  exit 0
fi
echo "stub: unexpected SQL: $sql" >&2
exit 7
EOF
  chmod +x "$TMP/trino-stub.sh"
}

make_find_dupes_stub() {
  cat > "$TMP/find-dupes-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: records every --name invocation to a log and emits a fake JSONL row.
log_file="${SCAN_STUB_LOG:-/tmp/scan-stub-log}"
echo "$@" >> "$log_file"
echo '{"verdict":"candidate_dupe","detected_via":"name","search_name":"'"$2"'"}'
EOF
  chmod +x "$TMP/find-dupes-stub.sh"
}

@test "scan-name-clusters --dry-run emits one find-dupes call per safe-sized cluster" {
  make_trino_stub
  make_find_dupes_stub
  export SCAN_STUB_LOG="$TMP/log"
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$SWEEP" --max-cluster-size 20 --dry-run
  [ "$status" -eq 0 ]
  # Expect 2 invocations: ali zain (8) and john smith (3). empire (30) is over the cap.
  [ "$(grep -c '^--name' "$TMP/log")" -eq 2 ]
  grep -q "^--name ali zain " "$TMP/log"
  grep -q "^--name john smith " "$TMP/log"
  ! grep -q "^--name empire " "$TMP/log"
}

@test "scan-name-clusters reports skipped oversized clusters on stderr" {
  make_trino_stub
  make_find_dupes_stub
  export SCAN_STUB_LOG="$TMP/log"
  TRINO_QUERY="$TMP/trino-stub.sh" run bash -c "bash '$SWEEP' --max-cluster-size 20 --dry-run 2>&1 >/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "skipping.*empire.*30"
}

@test "scan-name-clusters emits dupe JSONL on stdout from find-dupes invocations" {
  make_trino_stub
  make_find_dupes_stub
  export SCAN_STUB_LOG="$TMP/log"
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$SWEEP" --max-cluster-size 20 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"search_name":"ali zain"'
  echo "$output" | grep -q '"search_name":"john smith"'
}

@test "scan-name-clusters --top-n limit propagates to Trino query" {
  make_find_dupes_stub
  export SCAN_STUB_LOG="$TMP/log"
  # Custom stub that asserts on LIMIT.
  cat > "$TMP/trino-stub.sh" <<'EOF'
#!/usr/bin/env bash
sql="${1:-}"
if echo "$sql" | grep -q "LIMIT 7"; then
  echo '"ali zain","2"'
fi
EOF
  chmod +x "$TMP/trino-stub.sh"
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$SWEEP" --top-n 7 --dry-run
  [ "$status" -eq 0 ]
  grep -q "^--name ali zain " "$TMP/log"
}

@test "scan-name-clusters rejects non-numeric --max-cluster-size" {
  make_trino_stub
  make_find_dupes_stub
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$SWEEP" --max-cluster-size abc
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "max-cluster-size.*integer\|max-cluster-size.*number"
}

@test "scan-name-clusters --help works" {
  run bash "$SWEEP" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q -- "--max-cluster-size"
}
