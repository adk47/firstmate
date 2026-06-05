#!/usr/bin/env bash
# Dimension A (Voice) MECHANICAL scan, deterministic. Scans SHIPPED Caroline reply
# bodies for the rubric's voice tells -- em/en-dashes and the phrase blacklist --
# and emits structured rows the grader COUNTS, rather than the grader composing its
# own ad-hoc jq/bash.
#
# WHY a script: the rubric used to describe this scan in prose ("Mechanical scans
# first: Em-dash count...; Phrase blacklist: ..."), so the LLM grader hand-rolled it
# inline inside the pipeline's `set -euo pipefail` session -- and a single non-zero
# sub-exit (e.g. a no-match grep, or a jq quirk) aborted the WHOLE daily run with
# nothing delivered (shadow proof-run 2026-06-05; the 4th instance of this class
# after the weekly proof-runs). A deterministic script removes that failure mode,
# mirroring scan-shipped-leaks.sh / redact.sh (see feedback_llm_instruction_insufficient:
# prose in a rubric is not enforcement).
#
# Output: $WORKDIR/voice-scan.jsonl, one row per hit:
#   {conv, kind:"blacklist", marker:<name>, sample}            (one per phrase hit)
#   {conv, kind:"dash",      marker:"em-dash"|"en-dash", count, sample}  (per body)
# Scans ONLY Caroline-authored (admin + her id) parts -- never the customer .source
# opener (a customer writing "great question" must not score against Caroline). Input
# is already PII-redacted (redact.sh, which does NOT touch dashes), so the sample is
# safe to emit. Blacklist phrases mirror grading-rubric.md Dimension A verbatim.
set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

IN="${1:-$WORKDIR/conversations.redacted.jsonl}"
OUT="$WORKDIR/voice-scan.jsonl"
: > "$OUT"

[ -f "$IN" ] || { echo "scan-voice: no redacted conversations at $IN; empty result"; exit 0; }

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

echo "scan-voice: wrote $(wc -l < "$OUT") voice-scan hits"
