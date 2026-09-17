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
# platform.md is COMMITTED, so a grounded index always returns it and its
# assertion in validate-caroline-rag.sh is HARD -- it belongs in this fixture.
# platform-api.md is deliberately NOT here: it is generated on the server by
# sync-platform-llms.sh and rsync-excluded, so it is legitimately absent on a
# fresh box. Leaving it out keeps this fixture honest AND proves its assertion
# really is soft -- if someone promotes that one to a hard assert, this test
# goes red instead of passing on a stub that lies about what is on disk.
ALL_HITS="founding-member.md credits-and-profiles.md subscriptions-and-billing.md common-issues.md active-incidents.md b2b-ads-pipeline.md platform.md"

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
# $3 = provider line override. Defaults to the real node-8 shape:
#   Memory Search (support)
#   Provider: openai (requested: openai)
# The script's environment guard keys on `^Provider:`, so the stub MUST carry it
# or every suite aborts (exit 2) before reaching its assertions. Pass "none" to
# model an unconfigured profile (the wrong-host case) and "" to model the line
# being absent entirely.
# The stub emits the REAL output shape: a path-qualified source label
# ("reference/<file>.md:<start>-<end>") followed by the chunk text. It used to emit
# a bare basename, which is why no test could reproduce the false green that shipped
# -- a chunk from one file quoting another file's NAME. DECOY_TEXT models exactly
# that: a hit on api-access.md whose text mentions another reference file.
write_openclaw_stub() {
  local hit="$1" dreaming_line="Dreaming: off"
  local provider_line="Provider: openai (requested: openai)"
  [ "${2:-}" = "no-dreaming" ] && dreaming_line=""
  case "${3-unset}" in
    none) provider_line="Provider: none (requested: auto)" ;;
    "")   provider_line="" ;;
  esac
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
DECOY_TEXT="\${DECOY_TEXT:-}"
args="\$*"
if [[ "\$args" == *"memory status"* ]]; then
  printf '%s\n' "$provider_line" "Embeddings: ready" "Vector store: ready" "$dreaming_line" "Issues:"
elif [[ "\$args" == *"memory search"* ]]; then
  if [ -n "$hit" ]; then
    for h in $hit; do
      printf '%s\n' "  0.70 reference/\$h:1-10" "    chunk text for \$h"
    done
    [ -z "\$DECOY_TEXT" ] || printf '%s\n' "  0.65 reference/api-access.md:1-10" "    \$DECOY_TEXT"
  else echo "No matches"; fi
fi
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

@test "main/cmo: a grounded index passes (exit 0)" {
  write_openclaw_stub "$ALL_HITS"
  run env PROFILE=main AGENT=cmo "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrieval hit reference/b2b-ads-pipeline.md"* ]]
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
  [[ "$output" == *"retrieval hit reference/founding-member.md"* ]]
  [[ "$output" == *"retrieval hit reference/common-issues.md"* ]]
  [[ "$output" == *"All Caroline RAG checks passed."* ]]
}

@test "a decoy chunk quoting a BARE filename does not satisfy that file's canary" {
  # The original production false green: the canary grepped the whole output for a
  # bare basename, and api-access.md's prose says "retrieve `platform.md`". Measured
  # on node-8 2026-09-17: matched 1 while platform.md was absent from the results.
  local hits="founding-member.md credits-and-profiles.md subscriptions-and-billing.md common-issues.md"
  DECOY_TEXT='For the full picture retrieve platform.md and quote from it.' write_openclaw_stub "$hits"
  run env PROFILE=edge AGENT=support DECOY_TEXT='For the full picture retrieve platform.md and quote from it.' "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "canary passed on a bare-name decoy" >&2; echo "$output" >&2; return 1; }
  [[ "$output" == *"retrieval missed reference/platform.md"* ]]
}

@test "a decoy chunk quoting the FULL PATH does not satisfy the canary either" {
  # The remaining class after path-anchoring: `grep -F` still scanned chunk PROSE, so
  # a chunk saying "retrieve reference/platform.md" would satisfy the assert with the
  # file absent. No KB file writes that today -- but a CRITICAL-radius deploy gate
  # must not rest on nobody ever writing it. The gate now parses source-label RECORDS
  # ("<score> <path>:<start>-<end>" on its own line), so prose cannot match at all.
  local hits="founding-member.md credits-and-profiles.md subscriptions-and-billing.md common-issues.md"
  DECOY_TEXT='See reference/platform.md for the full doctrine.' write_openclaw_stub "$hits"
  run env PROFILE=edge AGENT=support DECOY_TEXT='See reference/platform.md for the full doctrine.' "$SCRIPT"
  [ "$status" -eq 1 ] || {
    echo "canary passed on a FULL-PATH decoy -- prose is still being scanned" >&2
    echo "$output" >&2; return 1; }
  [[ "$output" == *"retrieval missed reference/platform.md"* ]]
}

@test "the miss message lists the sources that WERE retrieved" {
  # A bare "missed X" is unactionable at 04:00; naming what came back instead turns
  # the failure into a diagnosis.
  DECOY_TEXT='' write_openclaw_stub "founding-member.md credits-and-profiles.md subscriptions-and-billing.md common-issues.md"
  run env PROFILE=edge AGENT=support "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sources: reference/founding-member.md"* ]]
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

# ── environment guard ────────────────────────────────────────────────────────
# Regression cover for the false-alarm class this guard exists to kill: run on a
# host where the profile is unconfigured and every positive-marker grep misses,
# so the script used to report five CONTENT failures plus a "run memory index
# --force" hint that could not possibly help. It must abort instead.

@test "guard: 'Provider: none' aborts (exit 2), does not report content failures" {
  write_openclaw_stub "$ALL_HITS" "" none
  run env PROFILE=edge AGENT=support "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no embedding provider"* ]]
  # must NOT masquerade as a content/index problem
  [[ "$output" != *"embeddings not ready"* ]]
  [[ "$output" != *"memory index --force"* ]]
}

@test "guard: a missing Provider line aborts (exit 2)" {
  write_openclaw_stub "$ALL_HITS" "" ""
  run env PROFILE=edge AGENT=support "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no embedding provider"* ]]
}
