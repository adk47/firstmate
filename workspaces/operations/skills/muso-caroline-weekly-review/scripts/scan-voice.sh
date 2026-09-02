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
#
# SANITIZER ATTRIBUTION (v2). plugins/intercom/src/sanitize-typography.ts rewrites
# EVERY em-dash Caroline writes into an en-dash before the reply ships -- a
# guaranteed one-codepoint swap, by design. This script scans SHIPPED bodies, so
# without correction the em-dash count here is structurally ~0 and most en-dashes
# it finds are OUR OWN guard's output rather than Caroline reaching for one.
# Grading her prose on that measured the guardrail, not the agent: it produced a
# "6 en-dash tells" finding and a SOUL.md rewrite (PR #892) that could not
# possibly have moved the number, while deleting the sentence documenting the
# sanitizer. So: fetch-audit.sh collects the guard's own per-conversation rewrite
# count ({kind:"typography"}), and this script subtracts it from the observed
# en-dashes and reports it separately as `em-dash-rewritten` -- which IS the real
# pre-sanitizer em-dash signal, previously invisible.
# When the journal was unreadable the counts CANNOT be attributed; the summary
# then says `unavailable` rather than printing 0, because a measured zero and an
# unmeasured zero are different facts and conflating them is what caused this.
# Scans ONLY Caroline-authored (admin + her id) parts -- never the customer .source
# opener (a customer writing "great question" must not score against Caroline). Input
# is already PII-redacted (redact.sh, which does NOT touch dashes), so the sample is
# safe to emit. Blacklist phrases mirror grading-rubric.md Dimension A verbatim.
set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

IN="${1:-$WORKDIR/conversations.redacted.jsonl}"
AUDIT="${2:-$WORKDIR/audit.jsonl}"
OUT="$WORKDIR/voice-scan.jsonl"
SUMMARY="$WORKDIR/voice-summary.txt"
: > "$OUT"

# Per-conversation sanitizer rewrite counts, or JSON null when we cannot know.
# ONLY the journalctl source is attributable. `none` is what fetch-audit.sh uses
# when no journal is readable: it yields an audit with no typography rows, which
# is INDISTINGUISHABLE from a clean week. `syslog` is no better for THIS number --
# fetch-audit.sh documents it as best-effort over "whatever the file retains",
# with no --since window, so its rewrite count is an unknown fraction of the
# scanned window. Subtracting a partial count silently UNDER-corrects and reports
# the result as measured, which is the same conflation this correction exists to
# remove. Both degraded sources are therefore unattributable, not zero.
REWRITES='null'
case "${CAROLINE_REASONING_LEAK_SOURCE:-journalctl}" in
  none|syslog) ;;
  *)
    if [ -f "$AUDIT" ]; then
      # ANY unparseable typography line makes the whole map untrustworthy: the
      # missing rows shrink the rewrite counts, and subtracting a short count
      # while reporting `available` grades our own guard output as Caroline's
      # prose. A partial measurement is not a measurement -- degrade to
      # unavailable and say so.
      if [ "$(jq -s '[.[]|select(.kind == "typography_error")]|length' "$AUDIT" 2>/dev/null || echo 0)" -gt 0 ]; then
        REWRITES='null'
      else
        REWRITES="$(jq -s '
            map(select(.kind == "typography"))
            | group_by(.conv)
            | map({key: .[0].conv, value: (map(.count) | add)})
            | from_entries
          ' "$AUDIT")" || REWRITES='null'
      fi
    fi
    ;;
esac

# Precompute the aggregate the grader reads VERBATIM. The slurp (`jq -s`) and group_by
# happen HERE -- the grader must never aggregate voice-scan.jsonl itself (running
# group_by WITHOUT -s threw "Cannot index string with string" and errored the
# 2026-06-04 daily run). Reads the rows in $OUT; an empty $OUT yields an all-zero
# summary, so $SUMMARY ALWAYS exists for the grader to read. NO `|| true`: a jq failure
# here is a real bug and must fail the run loudly under set -e, not ship a blank summary.
write_summary() {
  jq -rs --argjson rw "$REWRITES" '
    # Rewrites the guard performed on this conversation, 0 when unattributed.
    def rewritten($c): $rw[$c] // 0;   # null[$c] is null, so // 0 covers unattributed
    (map(select(.kind == "dash" and .marker == "em-dash")))                  as $em
    # Subtract the swaps the guard performed; floor at 0 so a mid-window restart
    # that logged more rewrites than the sampled bodies contain cannot go negative.
    # COLLAPSE TO ONE ROW PER CONV FIRST. scan-voice emits one row per Caroline
    # PART, so a conversation with three replies yields three en-dash rows, while
    # the guard reports one count per CONVERSATION. Subtracting that from each row
    # separately over-corrects by (parts - 1) x rewrites -- a 3-reply conv with 4
    # en-dashes and 2 rewrites scored 0 instead of 2, i.e. the same "the number is
    # not what it says" bug this correction exists to fix, pointing the other way.
    # (No apostrophes in this block: the jq program is single-quoted shell.)
    | ( map(select(.kind == "dash" and .marker == "en-dash"))
        | group_by(.conv)
        | map({conv: .[0].conv,
               count: ([((map(.count) | add) - rewritten(.[0].conv)), 0] | max)})
        | map(select(.count > 0)) )                                          as $en
    | (map(select(.kind == "blacklist")))                                    as $bl
    | (($em | map(.count) | add) // 0)                                       as $emt
    | (($en | map(.count) | add) // 0)                                       as $ent
    | ($em | map(.conv) | unique | length)                                   as $emc
    | ($en | map(.conv) | unique | length)                                   as $enc
    | (if $rw == null then null else (($rw | add) // 0) end)                 as $rwt
    | (if $rw == null then null else ($rw | keys | length) end)               as $rwc
    | ( ($em + $en) | group_by(.conv)
        | map({conv: .[0].conv, n: (map(.count) | add)})
        | sort_by(.n) | reverse | .[0:5] )                                   as $top
    | ( $bl | group_by(.marker)
        | map({marker: .[0].marker, hits: length}) ) as $blm
    | "voice-summary v2",
      "em-dash: \($emt) tells across \($emc) convs",
      "en-dash: \($ent) tells across \($enc) convs",
      "dash-total: \($emt + $ent) tells",
      # The pre-sanitizer em-dash signal. `unavailable` is a THIRD state, not a
      # synonym for 0: it means the journal could not be read this run.
      "em-dash-rewritten: " + (if $rwt == null then "unavailable"
                               else "\($rwt) tells across \($rwc) convs" end),
      "sanitizer-attribution: " + (if $rw == null then "unavailable" else "available" end),
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
