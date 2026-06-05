#!/usr/bin/env bash
# Dimension A (Voice) MECHANICAL scan, deterministic. Scans SHIPPED Caroline reply
# bodies for the rubric's voice tells -- em/en-dashes and the phrase blacklist --
# and emits both per-hit rows AND a precomputed aggregate (voice-summary.txt) the
# grader reads VERBATIM, rather than the grader composing its own ad-hoc jq/bash.
#
# WHY a script: the rubric used to describe this scan in prose ("Mechanical scans
# first: Em-dash count...; Phrase blacklist: ..."), so the LLM grader hand-rolled it
# inline inside the pipeline's `set -euo pipefail` session -- and a single non-zero
# sub-exit (e.g. a no-match grep, or a jq quirk) aborted the WHOLE daily run with
# nothing delivered (the 4th instance of this class after the weekly proof-runs).
# #431 made the SCAN deterministic but still told the grader to "COUNT its rows", so
# the agent then hand-rolled the AGGREGATION: the 2026-06-04 shadow proof-run errored
# when codex ran `group_by(.kind+":"+.marker)` over voice-scan.jsonl WITHOUT `-s`
# ("Cannot index string with string") and the whole run failed undelivered. So this
# script now also precomputes the aggregate -- the slurp + group_by happen HERE where
# they are correct, leaving the grader nothing to hand-roll. Mirrors
# scan-shipped-leaks.sh / redact.sh (see feedback_llm_instruction_insufficient:
# prose in a rubric is not enforcement).
#
# Output (two files):
#   $WORKDIR/voice-scan.jsonl -- one row per hit (per-hit EVIDENCE, for drill-down):
#     {conv, kind:"blacklist", marker:<name>, sample}            (one per phrase hit)
#     {conv, kind:"dash",      marker:"em-dash"|"en-dash", count, sample}  (per body)
#   $WORKDIR/voice-summary.txt -- the precomputed AGGREGATE the grader pastes into the
#     digest: per-marker tell totals, distinct-conv counts, top repeat convs, and the
#     blacklist tally. Always present (an empty scan yields an all-zero summary).
# Scans ONLY Caroline-authored (admin + her id) parts -- never the customer .source
# opener (a customer writing "great question" must not score against Caroline). Input
# is already PII-redacted (redact.sh, which does NOT touch dashes), so the sample is
# safe to emit. Blacklist phrases mirror grading-rubric.md Dimension A verbatim.
set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

IN="${1:-$WORKDIR/conversations.redacted.jsonl}"
OUT="$WORKDIR/voice-scan.jsonl"
SUMMARY="$WORKDIR/voice-summary.txt"
: > "$OUT"

# Precompute the aggregate the grader reads VERBATIM. The slurp (`jq -s`) and group_by
# happen HERE -- the grader must never aggregate voice-scan.jsonl itself (running
# group_by WITHOUT -s threw "Cannot index string with string" and errored the
# 2026-06-04 daily run). Reads the rows in $OUT; an empty $OUT yields an all-zero
# summary, so $SUMMARY ALWAYS exists for the grader to read. NO `|| true`: a jq failure
# here is a real bug and must fail the run loudly under set -e, not ship a blank summary.
write_summary() {
  jq -rs '
    (map(select(.kind == "dash" and .marker == "em-dash")))                 as $em
    | (map(select(.kind == "dash" and .marker == "en-dash")))               as $en
    | (map(select(.kind == "blacklist")))                                   as $bl
    | (($em | map(.count) | add) // 0)                                      as $emt
    | (($en | map(.count) | add) // 0)                                      as $ent
    | ($em | map(.conv) | unique | length)                                  as $emc
    | ($en | map(.conv) | unique | length)                                  as $enc
    | ( map(select(.kind == "dash")) | group_by(.conv)
        | map({conv: .[0].conv, n: (map(.count) | add)})
        | sort_by(.n) | reverse | .[0:5] )                                  as $top
    | ( $bl | group_by(.marker)
        | map({marker: .[0].marker, hits: length}) ) as $blm
    | "voice-summary v1",
      "em-dash: \($emt) tells across \($emc) convs",
      "en-dash: \($ent) tells across \($enc) convs",
      "dash-total: \($emt + $ent) tells",
      "top-dash-convs: " + (if ($top | length) > 0 then ($top | map("\(.conv)(\(.n))") | join(", ")) else "(none)" end),
      "blacklist-total: \($bl | length)",
      "blacklist-by-marker: " + (if ($blm | length) > 0 then ($blm | map("\(.marker):\(.hits)") | join(", ")) else "(none)" end)
  ' "$OUT" > "$SUMMARY"
}

[ -f "$IN" ] || { echo "scan-voice: no redacted conversations at $IN; empty result"; write_summary; exit 0; }

jq -c --arg admin "$CAROLINE_BOT_ADMIN_ID" '
  ([
    {n:"great-question",          re:"\\bgreat question\\b",                  f:"i"},
    {n:"understand-frustration",  re:"\\bi understand your frustration\\b",   f:"i"},
    {n:"investigate",             re:"\\binvestigate\\b",                     f:"i"},
    {n:"sorry-analytics-delayed", re:"\\bsorry the analytics are delayed\\b", f:"i"},
    {n:"sorry-latency",           re:"\\bsorry for the latency\\b",           f:"i"}
  ]) as $BL
  | . as $c
  | .parts[]?
  | select(.author.type == "admin" and ((.author.id | tostring) == $admin))
  | (.body // "") as $b
  | ($b | gsub("\\s+"; " ") | .[0:200]) as $sample
  | ([$b | scan("—")] | length) as $em
  | ([$b | scan("–")] | length) as $en
  | (
      ( $BL[] as $m | select($b | test($m.re; $m.f))
        | {conv: ($c.id | tostring), kind: "blacklist", marker: $m.n, sample: $sample} ),
      ( if $em > 0 then {conv: ($c.id | tostring), kind: "dash", marker: "em-dash", count: $em, sample: $sample} else empty end ),
      ( if $en > 0 then {conv: ($c.id | tostring), kind: "dash", marker: "en-dash", count: $en, sample: $sample} else empty end )
    )
' "$IN" >> "$OUT"
# Deliberately NO `|| true`: jq already exits 0 on a no-match (empty output is success),
# so the only thing `|| true` would swallow is a REAL failure -- a malformed
# conversations.redacted.jsonl line, or a jq runtime/build error. That must fail the run
# LOUDLY (set -e aborts here), not silently report "0 hits" and let Dimension A score a
# false clean. (redact.sh already guarantees valid JSON, so this never fires in practice.)

write_summary
echo "scan-voice: wrote $(wc -l < "$OUT") voice-scan hits; aggregate -> $SUMMARY"
