#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"A","customer_email":"a@x"}
{"id":"c2","contact_id":"B","customer_email":"b@x"}
{"id":"c3","contact_id":"C","customer_email":"c@x"}
EOF
  # Fake repo root with a reference file
  export REPO_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$REPO_ROOT/workspaces/support/reference"
  touch "$REPO_ROOT/workspaces/support/reference/common-issues.md"
  # Required so the symlink-escape test creates a valid (non-dangling) link,
  # allowing realpath canonicalization to actually run.
  touch "$REPO_ROOT/workspaces/support/SOUL.md"
}
teardown() { teardown_skill_tmp; }

good_cluster() {
  jq -nc '{
    week_of: "2026-05-12",
    clusters: [{
      topic: "FLAC export",
      unique_customers: 3,
      conversation_ids: ["c1","c2","c3"],
      target_path: "workspaces/support/reference/common-issues.md",
      anchor: "## Audio file export",
      insertion: "If you need FLAC, request it via the audio settings."
    }]
  }'
}

@test "accepts valid cluster" {
  good_cluster > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "rejects hallucinated conversation_id" {
  good_cluster | jq '.clusters[0].conversation_ids = ["c1","c2","HALLUCINATED"]' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HALLUCINATED"* ]]
}

@test "rejects unique-count mismatch" {
  good_cluster | jq '.clusters[0].unique_customers = 99' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unique_customers"* ]]
}

@test "rejects target outside reference/" {
  good_cluster | jq '.clusters[0].target_path = "workspaces/support/SOUL.md"' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path"* ]]
}

@test "rejects path traversal via ..." {
  good_cluster | jq '.clusters[0].target_path = "workspaces/support/reference/../SOUL.md"' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "rejects symlink escape" {
  ln -s "$REPO_ROOT/workspaces/support/SOUL.md" "$REPO_ROOT/workspaces/support/reference/sneaky.md"
  good_cluster | jq '.clusters[0].target_path = "workspaces/support/reference/sneaky.md"' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "rejects em-dash in insertion" {
  good_cluster | jq '.clusters[0].insertion = "Try FLAC — fast and lossless."' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"em-dash"* ]]
}

@test "rejects voice-blacklist phrase" {
  good_cluster | jq '.clusters[0].insertion = "Great question! Try FLAC."' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blacklist"* ]]
}

@test "rejects cluster with missing insertion field" {
  good_cluster | jq 'del(.clusters[0].insertion)' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"insertion"* ]]
}

@test "rejects case-variant voice blacklist (Great Question)" {
  good_cluster | jq '.clusters[0].insertion = "Great Question! Try FLAC."' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blacklist"* ]]
}

@test "rejects cluster with fewer than 3 unique customers (honest count)" {
  # claimed matches recomputed (so the mismatch check passes), but the hard
  # N>=3 evidence bar must still reject a one-customer cluster.
  good_cluster | jq '.clusters[0].conversation_ids = ["c1"] | .clusters[0].unique_customers = 1' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"3"* ]]
}
