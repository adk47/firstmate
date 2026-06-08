#!/usr/bin/env bash
# Dimension B (Tool/escalation hygiene) REGRESSION-WATCH scan, deterministic.
# Scans Caroline's shipped reply bodies for the rubric's regression patterns --
# Caroline punting the customer to email/contact support instead of handling it --
# and emits per-hit rows + a precomputed aggregate (tools-summary.txt) the grader
# reads VERBATIM, so the grader never hand-rolls jq for this (the abort footgun
# that killed the 2026-06-08 daily run on the SENTIMENT dimension; mirrors the
# scan-voice.sh #432 fix and scan-sentiment.sh).
#
# Scope: ONLY the rubric's two "Regression watch (P0 each)" regexes. The other
# Dimension-B checks (profile_status coverage, create_ticket actionType/tier,
# refund 3-gate) require cross-referencing tool calls in audit.jsonl against
# TOOLS.md and stay with the LLM grader -- they are not mechanizable regexes.
#
# WHY THIS READS THE *RAW* conversations.jsonl, NOT the redacted file (unlike
# scan-voice/scan-sentiment/scan-shipped-leaks): redact.sh scrubs EVERY email to
# the literal "<email>" (redact.sh: gsub("...@...";"<email>")), INCLUDING
# support@muso.ai. So the rubric's `email support@muso\.ai` regex can NEVER match
# the redacted file -- the grader hand-rolling it over conversations.redacted.jsonl
# silently scores a FALSE CLEAN (it has, every run). Matching the fixed company
# address requires the pre-redaction body. To stay PII-safe we emit ONLY
# {conv, marker} -- NEVER a body sample (the raw body can carry customer PII).
# The grader/human opens the cited conv id in Intercom for context.
#
# Output (two files):
#   $WORKDIR/tools-scan.jsonl   -- one row per hit: {conv, marker}  (no sample)
#   $WORKDIR/tools-summary.txt  -- the precomputed AGGREGATE the grader reads:
#     regression-conv count (each a P0), total hits, by-marker tally, top conv ids.
#     Always present (an empty scan yields an all-zero summary).
# Scans ONLY Caroline-authored (admin + her id) parts -- a CUSTOMER writing
# "I'll just email support" must not score as Caroline's regression.
set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

# NOTE: raw fetch, not the redacted file -- see header. Runs after fetch-conversations.sh.
IN="${1:-$WORKDIR/conversations.jsonl}"
OUT="$WORKDIR/tools-scan.jsonl"
SUMMARY="$WORKDIR/tools-summary.txt"
: > "$OUT"

# Precompute the aggregate the grader reads VERBATIM. The slurp (`jq -rs`) happens
# HERE -- the grader must never aggregate tools-scan.jsonl itself. An empty $OUT
# yields an all-zero summary, so $SUMMARY ALWAYS exists. NO `|| true`: a jq failure
# here is a real bug and must fail the run loudly under set -e.
write_summary() {
  jq -rs '
    ( group_by(.conv) | map(.[0].conv) )                       as $convs
    | ( group_by(.marker) | map({m: .[0].marker, n: length}) ) as $bym
    | "tools-summary v1",
      "regression-convs: \($convs | length)   (each is a P0; Dimension B cannot score 5 if > 0)",
      "regression-hits: \(length)",
      "regression-by-marker: " + (if ($bym | length) > 0 then ($bym | map("\(.m):\(.n)") | join(", ")) else "(none)" end),
      "top-regression-convs: " + (if ($convs | length) > 0 then ($convs[0:5] | join(", ")) else "(none)" end) + "  (conv ids only; open in Intercom -- no PII sample emitted)"
  ' "$OUT" > "$SUMMARY"
}

[ -f "$IN" ] || { echo "scan-tools: no conversations at $IN; empty result"; write_summary; exit 0; }

# Markers mirror grading-rubric.md Dimension B "Regression watch" VERBATIM.
# Scanned against the RAW body (support@muso.ai survives here; it is "<email>" in
# the redacted file). Emit conv + marker ONLY -- no body sample (raw = PII).
jq -c --arg admin "$CAROLINE_BOT_ADMIN_ID" '
  ([
    {n:"email-support-address", re:"email support@muso\\.ai",          f:"i"},
    {n:"punt-to-support",       re:"(contact|reach out to|email) support", f:"i"}
  ]) as $RG
  | . as $c
  | .parts[]?
  | select(.author.type == "admin" and ((.author.id | tostring) == $admin))
  | (.body // "") as $b
  | $RG[] as $m
  | select($b | test($m.re; $m.f))
  | {conv: ($c.id | tostring), marker: $m.n}
' "$IN" >> "$OUT"
# Deliberately NO `|| true`: jq exits 0 on a no-match (empty output is success), so
# the only thing `|| true` would swallow is a REAL failure -- a malformed
# conversations.jsonl line or a jq runtime/build error. That must fail the run
# LOUDLY (set -e), not silently report "0 regressions" and score a false clean.

write_summary
echo "scan-tools: wrote $(wc -l < "$OUT") regression hits; aggregate -> $SUMMARY"
