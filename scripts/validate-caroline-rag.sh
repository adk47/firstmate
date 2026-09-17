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

# Remediation hint for a paused/empty index is per-profile: main's identity-
# metadata pause is cleared by `status --index`, NOT `index --force`.
if [ "$PROFILE" = "main" ]; then HEAL_HINT="memory status --index"; else HEAL_HINT="memory index --force"; fi

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

echo "Validating Caroline RAG on profile=$PROFILE agent=$AGENT..."

# 1. memorySearch enabled + provider ready
status_output=$(openclaw --profile "$PROFILE" memory status --agent "$AGENT" --deep 2>&1 || true)

# Environment guard. Every check below greps for a positive marker, so an
# unconfigured profile makes ALL of them miss and the script confidently
# reports content failures plus a "run memory index --force" hint that cannot
# possibly help. That is the opposite of fail-loud: it manufactures a
# customer-facing-sounding incident out of running the wrong host.
#
# This is a post-deploy smoke test for the LIVE gateway and only means anything
# on node-8. `Provider: none` means memorySearch resolved no embedding provider
# at all -- an environment/config problem, never an index-content one.
if ! echo "$status_output" | grep -q "^Provider:" \
   || echo "$status_output" | grep -q "^Provider: none"; then
  echo "ABORT: memorySearch reports no embedding provider for $PROFILE/$AGENT." >&2
  echo "       This is an environment/config problem, NOT a stale index --" >&2
  echo "       reindexing cannot fix it. Most common cause: this script was" >&2
  echo "       run somewhere other than node-8, where the profile is empty." >&2
  echo "       Observed:" >&2
  echo "$status_output" | sed -n '1,6p' | sed 's/^/         /' >&2
  exit 2
fi

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

# Dreaming is a memory-core CONFIG toggle, not a pause signal (the watchdog's
# health classifier deliberately doesn't check it). edge/support disables it for
# the customer-RAG use case; other profiles' dreaming state is out of scope for a
# RAG-pause smoke test, so only hard-assert it there -- the retrieval check below
# is the definitive pause detector for every profile.
if [ "$PROFILE/$AGENT" = "edge/support" ]; then
  if echo "$status_output" | grep -q "Dreaming: off"; then
    pass "dreaming confirmed off"
  else
    fail "dreaming not reporting off (check memory-core.dreaming.enabled)"
  fi
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
#    --max-results 10, not 5. The contract is "is this file REACHABLE in the
#    index", not "does it rank top-5" -- and the result window is shared with every
#    other reference file, so adding one shifts the others. app-pricing.md joins this
#    index on the next deploy and its header necessarily says "NOT platform.muso.ai,
#    the developer platform" (the disambiguation that stops Caroline quoting API
#    rates for a Pro plan), which makes it semantically adjacent to the platform
#    canary's own query BY CONSTRUCTION. Measured 2026-09-17 before that file exists:
#    at 5 the platform canary holds 2 of 5 slots against 3 competitors; at 10 it holds
#    3 with headroom. A hard assert that fails the 04:00 deploy must not be one new
#    KB file away from a false red.
#
#    --min-score 0 is REQUIRED: a non-zero floor drops valid
#    natural-language matches (verified live -- "what happens to my
#    founding member status if my payment fails" scores ~0.33 against
#    the correct chunk and returns "No matches" at the default floor).
#
#    Each pair is a representative customer question and the reference
#    file it must retrieve.
#
#    THE WANT IS THE PATH ("reference/<file>.md"), NEVER THE BARE BASENAME.
#    `memory search` prints a source label of the form
#    "reference/<file>.md:<start>-<end>" followed by the chunk text, and these
#    reference files cite each other by filename in their prose. A bare-basename
#    grep therefore matches a chunk from a DIFFERENT file that merely mentions the
#    one being asserted -- measured 2026-09-17: the platform.md canary passed with
#    a match count of 1 while platform.md was absent from the results entirely.
#    The path form scores 0 when absent and >0 when present.
# retrieved_sources -- emit ONE PATH PER LINE for each source-label record in the
# search output, and nothing else.
#
# A source label is its own line, "<score> <path>:<start>-<end>"; the chunk text that
# follows can say anything. Substring-matching the whole output is what made the
# previous canary unfalsifiable: a chunk from api-access.md quoting a filename
# satisfied that file's assert. Anchoring on the path narrowed it, but `grep -F` still
# scanned prose, so a chunk saying "retrieve reference/platform.md" would pass too --
# no KB file says that TODAY, but a CRITICAL-radius deploy gate must not depend on
# nobody ever writing it. Parsing the record makes prose structurally unable to match.
retrieved_sources() {
  awk '$0 ~ /^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]+[^[:space:]]+:[0-9]+-[0-9]+[[:space:]]*$/ {
         split($2, a, ":"); print a[1]
       }'
}

# retrieval_hit <output> <want> -- exact, whole-line match against a source path.
retrieval_hit() {
  printf '%s\n' "$1" | retrieved_sources | grep -qxF "$2"
}

assert_retrieval() {
  local query="$1" want="$2" out
  out=$(openclaw --profile "$PROFILE" memory search "$query" \
    --agent "$AGENT" --max-results 10 --min-score 0 2>&1 || true)
  if retrieval_hit "$out" "$want"; then
    pass "retrieval hit $want"
  elif echo "$out" | grep -q "No matches"; then
    fail "retrieval No matches for '$query' (want $want; index empty/paused? run: openclaw $HEAL_HINT --agent $AGENT --profile $PROFILE)"
  else
    fail "retrieval missed $want for '$query' (sources: $(printf '%s\n' "$out" | retrieved_sources | tr '\n' ' '))"
  fi
}

# Soft variant for files whose CONTENT is intentionally transient: confirm the
# index can reach the file when its content matches, but never FAIL the deploy on
# a miss (the file may legitimately be empty). Index-health is still enforced by
# the hard assertions on the stable files below.
assert_retrieval_soft() {
  local query="$1" want="$2" out
  out=$(openclaw --profile "$PROFILE" memory search "$query" \
    --agent "$AGENT" --max-results 10 --min-score 0 2>&1 || true)
  if retrieval_hit "$out" "$want"; then
    pass "retrieval hit $want"
  else
    echo "  ~ (soft) no current hit for $want via '$query' -- expected when no matching incident is live."
  fi
}

# Hard assertions: stable doctrine files. A miss = a partial/paused index = deploy FAIL.
# The query->file pairs are per (profile, agent): edge/support probes the customer
# KB; main/<agent> probes that agent's workspaces/<agent>/reference/ corpus.
case "$PROFILE/$AGENT" in
  main/cmo)
    # cmo canary for the main gateway. workspaces/cmo/reference/b2b-ads-pipeline.md
    # ("# B2B Muso Ads Pipeline") is stable doctrine -- "NocoDB = source of truth
    # for leads", "the B2B-Ads-Clio lead pipeline".
    assert_retrieval "how does the B2B ads lead pipeline work and what is the source of truth for leads" "reference/b2b-ads-pipeline.md"
    ;;
  *)  # edge/support (default): the customer-facing knowledge base.
    # QUERIES MEASURED, not assumed. Parsing source-label records (above) exposed
    # that these three canaries had been passing on PROSE for as long as they have
    # existed: their files are not retrieved by their own queries at all -- the
    # match came from common-issues.md / faq.md chunks mentioning the filename.
    # Verified live on node-8 2026-09-17, each query below returns its file.
    assert_retrieval "founding member perks and badge" "reference/founding-member.md"
    assert_retrieval "master side recordings versus publishing side" "reference/credits-and-profiles.md"
    # Deliberately NOT a plan-name/price question: #964 strips the priced headings
    # from this file, so a query tuned to them would go red on the next deploy.
    # "payment method update" matches content that change does not touch.
    assert_retrieval "payment method update" "reference/subscriptions-and-billing.md"
    assert_retrieval "I tried to claim my profile but nothing is happening" "reference/common-issues.md"
    # active-incidents.md is TRANSIENT by design (sections deleted when an incident
    # ends), so its probe is SOFT -- a miss here must not false-fail every deploy.
    assert_retrieval_soft "why are my stream counts frozen and not updating" "reference/active-incidents.md"
    # recent-changes.md is GENERATED on the server by support-changelog-sync.sh
    # and is rsync-excluded, so it is legitimately ABSENT on a fresh box, before
    # the timer is enabled, or in any window where nothing customer-visible
    # shipped. Soft for the same reason as active-incidents.md: a miss must not
    # false-fail every deploy. A HIT proves the generated feed is reachable by
    # the index, which is the whole delivery path for it.
    assert_retrieval_soft "what changed on the platform recently" "reference/recent-changes.md"
    # platform.md is COMMITTED, so it must always be retrievable -- this is the
    # doctrine file that stops Caroline answering catalog-API questions from the
    # stale "coming soon / custom contract" story she used to carry.
    #
    # ANCHORED ON THE PATH, and the query is one that actually retrieves this file.
    # Both were measured on node-8 2026-09-17 against a live index:
    #   "how do I get API access to your whole catalog" does NOT return platform.md
    #   at all, yet a bare grep for "platform.md" matched 1 -- because four other
    #   reference files quote the filename in their prose. The assert passed while
    #   the file it names was absent from the results.
    #   "workspace key versus platform key" returns it twice, and the path form
    #   "reference/platform.md" scores 0 when absent and 2 when present.
    # openclaw memory search prints "reference/<file>.md:<start>-<end>", so the path
    # form matches a SOURCE LINE and never a filename mentioned inside a chunk.
    assert_retrieval "workspace key versus platform key" "reference/platform.md"
    # platform-api.md is GENERATED by sync-platform-llms.sh and rsync-excluded,
    # so it is legitimately absent on a fresh box or before the first timer tick.
    # Soft for the same reason as recent-changes.md. A HIT proves the pricing
    # feed reaches the index, which is the entire point of syncing it.
    assert_retrieval_soft "what does the Muso Platform API cost per call" "reference/platform-api.md"
    # app-pricing.md is GENERATED by sync-app-pricing.sh and rsync-excluded, so it is
    # legitimately absent on a fresh box or before the first timer tick -- soft for
    # the same reason as the two above. A HIT proves the plan-pricing feed reaches
    # the index, which is the whole delivery path for it.
    assert_retrieval_soft "how much does the Business plan cost per month" "reference/app-pricing.md"
    ;;
esac

if [ "$FAILURES" -eq 0 ]; then
  echo "All Caroline RAG checks passed."
  exit 0
else
  echo "FAILED: $FAILURES Caroline RAG check(s) failed."
  exit 1
fi
