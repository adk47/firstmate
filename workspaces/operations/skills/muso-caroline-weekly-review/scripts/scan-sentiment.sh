#!/usr/bin/env bash
# Dimension D (Customer sentiment) MECHANICAL scan, deterministic. Scans CUSTOMER-
# authored (non-admin) message bodies for the rubric's explicit-frustration phrases
# and emits both per-hit rows AND a precomputed aggregate (sentiment-summary.txt) the
# grader reads VERBATIM, rather than the grader composing its own ad-hoc jq.
#
# WHY a script: exactly the scan-voice.sh story (#432), one dimension over. The rubric
# describes Dimension D in prose ("Explicit-frustration regex: ..."), so the LLM grader
# hand-rolled it inline inside the pipeline's `set -euo pipefail` session -- and on
# 2026-06-08 the daily run errored HERE: the agent's
#   jq -r 'select([.parts[]?.body? // ""] | join("\n") | test("you.?re a bot|are you
#          actually checking|this is useless|...")'
# exited non-zero and aborted the WHOLE run (status=error, delivered=false, finalLen=0
# -- nothing reached #cs_chats). #432 moved the VOICE scan into a script but left the
# SENTIMENT scan in prose; this closes that gap. The scan + aggregation happen HERE
# where the jq is correct, leaving the grader nothing to hand-roll. Mirrors
# scan-voice.sh / scan-shipped-leaks.sh (feedback_llm_instruction_insufficient: prose
# in a rubric is not enforcement).
#
# Output (two files):
#   $WORKDIR/sentiment-scan.jsonl -- one row per hit (per-hit EVIDENCE, for drill-down):
#     {conv, marker:<phrase-name>, sample}
#   $WORKDIR/sentiment-summary.txt -- the precomputed AGGREGATE the grader pastes into
#     the digest: frustrated-conv count (the Dimension D score input), total hits, and
#     the top repeat convs with a sample. Always present (an empty scan -> all-zero).
# Scans ONLY CUSTOMER-authored parts (author.type != "admin") -- the COMPLEMENT of
# scan-voice.sh, which scans Caroline's admin parts. A frustration phrase inside a
# Caroline (or any other admin) reply must NOT score against customer sentiment; this
# also correctly excludes a human agent who jumped in. The rubric's
# "repeat-question-after-Caroline-reply" signal is intentionally NOT mechanized here --
# it needs conversation-flow judgment the grader applies qualitatively. Input is already
# PII-redacted (redact.sh); the frustration phrases are not PII, so the sample is safe.
set -euo pipefail

: "${WORKDIR:?WORKDIR required}"

IN="${1:-$WORKDIR/conversations.redacted.jsonl}"
OUT="$WORKDIR/sentiment-scan.jsonl"
SUMMARY="$WORKDIR/sentiment-summary.txt"
: > "$OUT"

# Precompute the aggregate the grader reads VERBATIM. The slurp (`jq -rs`) happens HERE
# -- the grader must never aggregate sentiment-scan.jsonl itself. Reads the rows in
# $OUT; an empty $OUT yields an all-zero summary, so $SUMMARY ALWAYS exists for the
# grader. NO `|| true`: a jq failure here is a real bug and must fail the run loudly
# under set -e, not ship a blank summary.
write_summary() {
  jq -rs '
    ( group_by(.conv)
      | map({conv: .[0].conv, n: length, sample: .[0].sample})
      | sort_by(.n) | reverse )                                              as $byconv
    | "sentiment-summary v1",
      "frustrated-convs: \($byconv | length)   (Dimension D score = 5 - this, floor 0)",
      "frustration-hits: \(length)",
      "top-frustrated-convs: " + (if ($byconv | length) > 0
          then ($byconv[0:3] | map("\(.conv)(\(.n)) \"\(.sample)\"") | join(" | "))
          else "(none)" end)
  ' "$OUT" > "$SUMMARY"
}

[ -f "$IN" ] || { echo "scan-sentiment: no redacted conversations at $IN; empty result"; write_summary; exit 0; }

# Apostrophe-tolerant like scan-shipped-leaks.sh ([\x27\x{2019}]? = straight/curly/none),
# so "youre", "you're", "you’re" all match. Phrases mirror grading-rubric.md Dimension D.
jq -c '
  ([
    {n:"youre-a-bot",      re:"\\byou[\\x27\\x{2019}]?re a bot\\b", f:"i"},
    {n:"are-you-checking", re:"\\bare you actually checking\\b",    f:"i"},
    {n:"this-is-useless",  re:"\\bthis is useless\\b",             f:"i"},
    {n:"human-please",     re:"\\bhuman please\\b",                f:"i"}
  ]) as $FR
  | . as $c
  | .parts[]?
  | select(.author.type != "admin")
  | (.body // "") as $b
  | ($b | gsub("\\s+"; " ") | .[0:200]) as $sample
  | $FR[] as $m
  | select($b | test($m.re; $m.f))
  | {conv: ($c.id | tostring), marker: $m.n, sample: $sample}
' "$IN" >> "$OUT"
# Deliberately NO `|| true`: jq exits 0 on a no-match (empty output is success), so the
# only thing `|| true` would swallow is a REAL failure -- a malformed
# conversations.redacted.jsonl line, or a jq runtime/build error. That must fail the run
# LOUDLY (set -e aborts here), not silently report "0 frustrated" and let Dimension D
# score a false clean. (redact.sh already guarantees valid JSON, so this never fires in
# practice.)

write_summary
echo "scan-sentiment: wrote $(wc -l < "$OUT") frustration hits; aggregate -> $SUMMARY"
