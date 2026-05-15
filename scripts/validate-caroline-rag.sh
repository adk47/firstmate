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

# 3. Semantic retrieval must return at least one match for known doctrine
search_out=$(openclaw --profile "$PROFILE" memory search "analytics streams stuck not updating" --agent "$AGENT" --max-results 3 2>&1 || true)

if echo "$search_out" | grep -qE "common-issues\.md|active-incidents\.md"; then
  pass "retrieval returns analytics doctrine"
elif echo "$search_out" | grep -q "No matches"; then
  fail "retrieval returns No matches (index may be empty; run: openclaw memory index --force --agent $AGENT --profile $PROFILE)"
else
  fail "retrieval output unexpected (first 200 chars): ${search_out:0:200}"
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "All Caroline RAG checks passed."
  exit 0
else
  echo "FAILED: $FAILURES Caroline RAG check(s) failed."
  exit 1
fi
