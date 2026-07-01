#!/usr/bin/env bats
# Tests for scripts/validate-caroline-rag.sh -- the post-deploy RAG smoke test.
# It now branches its retrieval assertions on $PROFILE/$AGENT and runs NON-FATAL
# in deploy post-flight, so a wrong branch would silently "pass" a broken deploy.
# These cases lock the branch selection + the exit-code contract.
#
# Hermeticity (CI bats run on the live host -- see memory
# hydra-ci-bats-live-host-hermeticity): openclaw is PATH-stubbed so the suite
# never calls the real gateway. Modeled on caroline-rag-index-watchdog.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/validate-caroline-rag.sh"

# A single search line carrying every basename this suite asserts on, so any
# assert_retrieval's `grep -qF "$want"` finds its file.
ALL_HITS="founding-member.md credits-and-profiles.md subscriptions-and-billing.md common-issues.md active-incidents.md b2b-ads-pipeline.md"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# write_openclaw_stub HIT [no-dreaming] -- `memory status` => healthy; `memory
# search` emits HIT (a line of basenames) so every assert grep matches; empty HIT
# => No matches. Pass "no-dreaming" as $2 to omit the "Dreaming: off" line (to
# exercise the profile-scoped dreaming assertion).
write_openclaw_stub() {
  local hit="$1" dreaming_line="Dreaming: off"
  [ "${2:-}" = "no-dreaming" ] && dreaming_line=""
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"memory status"* ]]; then
  printf '%s\n' "Embeddings: ready" "Vector store: ready" "$dreaming_line" "Issues:"
elif [[ "\$args" == *"memory search"* ]]; then
  if [ -n "$hit" ]; then echo "  [0.70] $hit :: chunk"; else echo "No matches"; fi
fi
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

@test "main/cmo: a grounded index passes (exit 0)" {
  write_openclaw_stub "$ALL_HITS"
  run env PROFILE=main AGENT=cmo "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrieval hit b2b-ads-pipeline.md"* ]]
  [[ "$output" == *"All Caroline RAG checks passed."* ]]
  # main asserts ONLY its canary doc, not the customer-KB files.
  [[ "$output" != *"founding-member.md"* ]]
}

@test "main/cmo: an empty/paused index fails (exit 1) with a main-correct hint" {
  write_openclaw_stub ""
  run env PROFILE=main AGENT=cmo "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No matches"* ]]
  # The remediation hint is main-correct: status --index, NOT index --force.
  [[ "$output" == *"memory status --index"* ]]
  [[ "$output" != *"memory index --force"* ]]
}

@test "edge/support (default): the customer-KB assertions still run (exit 0)" {
  write_openclaw_stub "$ALL_HITS"
  run env PROFILE=edge AGENT=support "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrieval hit founding-member.md"* ]]
  [[ "$output" == *"retrieval hit common-issues.md"* ]]
  [[ "$output" == *"All Caroline RAG checks passed."* ]]
}

@test "main/cmo: passes even when status omits 'Dreaming: off' (dreaming is edge-only)" {
  write_openclaw_stub "$ALL_HITS" no-dreaming
  run env PROFILE=main AGENT=cmo "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All Caroline RAG checks passed."* ]]
}

@test "edge/support: still HARD-fails when status omits 'Dreaming: off' (edge behavior unchanged)" {
  write_openclaw_stub "$ALL_HITS" no-dreaming
  run env PROFILE=edge AGENT=support "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dreaming not reporting off"* ]]
}
