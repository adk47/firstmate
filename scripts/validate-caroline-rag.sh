#!/usr/bin/env bash
# Post-deploy smoke test for Caroline memorySearch RAG.
#
# Verifies on the LIVE edge profile:
#   1. memory subsystem reports embeddings + vector store ready
#   2. semantic search returns hits for a known-indexed query
#   3. no Issues lines appear in memory status --deep
#
# Wired into deploy.sh post-flight. Non-fatal (deploy continues on failure,
# but a Slack ping fires).
#
# Usage:  validate-caroline-rag.sh
# Env:    PROFILE (default: edge), AGENT (default: support)
# Exit:   0 clean, 1 invariant violated

set -euo pipefail

PROFILE="${PROFILE:-edge}"
AGENT="${AGENT:-support}"
FAILURES=0

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

echo "Validating Caroline RAG on profile=$PROFILE agent=$AGENT..."

# 1. memorySearch enabled + provider ready
status_output=$(openclaw --profile "$PROFILE" memory status --agent "$AGENT" --deep 2>&1 || true)

if echo "$status_output" | grep -q "Embeddings: ready"; then
  pass "embeddings ready"
else
  fail "embeddings not ready (check OPENROUTER_API_KEY in shared.env)"
fi

if echo "$status_output" | grep -q "Vector store: ready"; then
  pass "vector store ready"
else
  fail "vector store not ready (sqlite-vec extension missing?)"
fi

if echo "$status_output" | grep -q "Dreaming: off"; then
  pass "dreaming confirmed off"
else
  fail "dreaming not reporting off (check memory-core.dreaming.enabled)"
fi

# 2. Issues block must be empty
if echo "$status_output" | awk "/^Issues:/{flag=1; next} flag && NF{print; exit 1}" >/dev/null; then
  pass "no memory issues reported"
else
  fail "memory status reports issues"
fi

# 3. Semantic retrieval must return a HIT per key reference file. A
#    partial or paused index silently returns nothing, so one hit per
#    file turns that silent failure into a post-flight FAILURE.
#
#    --min-score 0 is REQUIRED: a non-zero floor drops valid
#    natural-language matches (verified live -- "what happens to my
#    founding member status if my payment fails" scores ~0.33 against
#    the correct chunk and returns "No matches" at the default floor).
#
#    Each pair is a representative customer question and the reference
#    file (workspaces/support/reference/<file>) it must retrieve. The
#    file basename appears in the search output's source label.
assert_retrieval() {
  local query="$1" want="$2" out
  out=$(openclaw --profile "$PROFILE" memory search "$query" \
    --agent "$AGENT" --max-results 5 --min-score 0 2>&1 || true)
  if echo "$out" | grep -qF "$want"; then
    pass "retrieval hit $want"
  elif echo "$out" | grep -q "No matches"; then
    fail "retrieval No matches for '$query' (want $want; index empty/paused? run: openclaw memory index --force --agent $AGENT --profile $PROFILE)"
  else
    fail "retrieval missed $want for '$query' (first 200 chars): ${out:0:200}"
  fi
}

# Soft variant for files whose CONTENT is intentionally transient: confirm the
# index can reach the file when its content matches, but never FAIL the deploy on
# a miss (the file may legitimately be empty). Index-health is still enforced by
# the hard assertions on the stable files below.
assert_retrieval_soft() {
  local query="$1" want="$2" out
  out=$(openclaw --profile "$PROFILE" memory search "$query" \
    --agent "$AGENT" --max-results 5 --min-score 0 2>&1 || true)
  if echo "$out" | grep -qF "$want"; then
    pass "retrieval hit $want"
  else
    echo "  ~ (soft) no current hit for $want via '$query' -- expected when no matching incident is live."
  fi
}

# Hard assertions: stable doctrine files. A miss = a partial/paused index = deploy FAIL.
assert_retrieval "what happens to my founding member status if my payment fails" "founding-member.md"
assert_retrieval "how do music credits work for my recordings and tracks" "credits-and-profiles.md"
assert_retrieval "what is the difference between the Pro and Business subscription plans" "subscriptions-and-billing.md"
assert_retrieval "I tried to claim my profile but nothing is happening" "common-issues.md"
# active-incidents.md is TRANSIENT by design (sections deleted when an incident
# ends), so its probe is SOFT -- a miss here must not false-fail every deploy.
assert_retrieval_soft "why are my stream counts frozen and not updating" "active-incidents.md"

if [ "$FAILURES" -eq 0 ]; then
  echo "All Caroline RAG checks passed."
  exit 0
else
  echo "FAILED: $FAILURES Caroline RAG check(s) failed."
  exit 1
fi
