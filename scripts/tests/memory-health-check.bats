#!/usr/bin/env bats
# Tests for memory-health-check.sh — the weekly node-8 probe that measures each
# agent's injected bootstrap files against that agent's EFFECTIVE caps.
#
# Why this suite exists: this script is the ONLY thing that can catch an
# over-cap live bootstrap file. deploy.sh rsync-EXCLUDES
# workspaces/*/{TOOLS,IDENTITY,MEMORY,HEARTBEAT}.md, so the CI gate
# (check-soul-bootstrap-size.sh) only ever sees a repo seed — the file that
# actually truncated on edge 310x/day is invisible to it. A regression here is
# silent by construction, which is exactly what the guardrail exists to prevent.
#
# Hermetic: fixtures in $TEST_TMPDIR via MEMORY_HEALTH_{MAIN,EDGE}_CONFIG /
# _WORKSPACES_DIR / _SKIP_HOST_GUARD. Always --dry-run, so no Slack post; the
# `muso` binary is never invoked.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/memory-health-check.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export MEMORY_HEALTH_SKIP_HOST_GUARD=1
  export MEMORY_HEALTH_MAIN_CONFIG="$TEST_TMPDIR/main.json"
  export MEMORY_HEALTH_EDGE_CONFIG="$TEST_TMPDIR/edge.json"
  export MEMORY_HEALTH_WORKSPACES_DIR="$TEST_TMPDIR/workspaces"
  mkdir -p "$MEMORY_HEALTH_WORKSPACES_DIR"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# write_configs <edge-support-cap-json-fragment>
write_configs() {
  cat > "$MEMORY_HEALTH_MAIN_CONFIG" <<JSON
{"agents":{"defaults":{"bootstrapMaxChars":40000,"bootstrapTotalMaxChars":120000,
 "bootstrapPromptTruncationWarning":"always"},"list":[{"id":"ops"}]}}
JSON
  cat > "$MEMORY_HEALTH_EDGE_CONFIG" <<JSON
{"agents":{"defaults":{"bootstrapMaxChars":40000,"bootstrapTotalMaxChars":120000,
 "bootstrapPromptTruncationWarning":"always"},"list":[{"id":"support"${1:+,$1}}]}}
JSON
}

# mkfile <agent> <file> <char-count> [char]
mkfile() {
  mkdir -p "$MEMORY_HEALTH_WORKSPACES_DIR/$1"
  head -c "$3" /dev/zero | tr '\0' "${4:-a}" > "$MEMORY_HEALTH_WORKSPACES_DIR/$1/$2"
}

run_check() { run bash "$SCRIPT" --dry-run; }

@test "per-agent override wins: support measured against 50000, not main's 40000" {
  write_configs '"bootstrapMaxChars":50000'
  mkfile support TOOLS.md 46000          # over 40000, under 50000
  run_check
  [ "$status" -eq 0 ]
  # would be an ALERT at 40000; at its real cap it is only a warning
  [[ "$output" != *"🚨"*"support/TOOLS.md"* ]]
  [[ "$output" == *"support/TOOLS.md"*"92% of cap"* ]]
}

@test "falls back to the profile default when the agent has no override" {
  write_configs
  mkfile support TOOLS.md 46000
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"🚨"*"support/TOOLS.md"*"over the 40000 cap"* ]]
}

@test "a HEALTHY TOOLS.md is still visible in the report, not only when warning" {
  # The file that truncated on edge is rsync-excluded, so the CI gate only ever
  # sees a repo seed. If it appears here only once it is already warning, nobody
  # watches it approach the cap — so the per-workspace row must carry it.
  write_configs '"bootstrapMaxChars":50000'
  mkfile support TOOLS.md 1000
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOOLS= 1000"* ]] || {
    echo "healthy TOOLS.md absent from the row — the gap this script exists to close"
    echo "$output"; return 1; }
  [[ "$output" != *"🚨"* ]]
}

@test "an INVALID per-agent cap alerts instead of silently using main's default" {
  # The regression the QA bot caught: a listed agent with a bad value used to be
  # indistinguishable from an unlisted workspace, so the wrong threshold was
  # applied with no signal.
  write_configs '"bootstrapMaxChars":"bad"'
  mkfile support TOOLS.md 1000
  run_check
  [[ "$output" == *"bootstrapMaxChars is invalid in its own profile"* ]]
}

@test "a zero per-agent cap is invalid too, not a silent fallback" {
  write_configs '"bootstrapMaxChars":0'
  mkfile support TOOLS.md 1000
  run_check
  [[ "$output" == *"bootstrapMaxChars is invalid in its own profile"* ]]
}

@test "an UNLISTED workspace falls back quietly — the one benign case" {
  write_configs '"bootstrapMaxChars":50000'
  mkfile orphan SOUL.md 100
  run_check
  [[ "$output" == *"orphan"* ]]
  [[ "$output" != *"orphan\` bootstrapMaxChars is invalid"* ]]
}

@test "sizes are CHARACTERS, not bytes (multibyte must not over-count)" {
  write_configs '"bootstrapMaxChars":50000'
  mkdir -p "$MEMORY_HEALTH_WORKSPACES_DIR/support"
  # 1000 x 'é' = 1000 chars but 2000 bytes. wc -c would double it.
  python3 -c "open('$MEMORY_HEALTH_WORKSPACES_DIR/support/SOUL.md','w',encoding='utf8').write('é'*1000)"
  run_check
  [[ "$output" == *"SOUL= 1000"* ]] || { echo "expected 1000 chars, got: $output"; return 1; }
}

@test "optional missing files are skipped, not counted as zero-size failures" {
  write_configs '"bootstrapMaxChars":50000'
  mkfile support SOUL.md 100          # no TOOLS/AGENTS/etc.
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"🚨"* ]]
}

@test "aggregate uses the per-agent total cap and alerts at the boundary" {
  write_configs '"bootstrapMaxChars":50000,"bootstrapTotalMaxChars":5000'
  mkfile support SOUL.md 3000
  mkfile support TOOLS.md 3000        # 6000 total > 5000
  run_check
  [[ "$output" == *"injected total"*"over the 5000 total cap"* ]]
}
