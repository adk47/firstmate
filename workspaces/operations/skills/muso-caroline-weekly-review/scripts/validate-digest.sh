#!/usr/bin/env bash
# Mechanical contract gate for the STRUCTURED digest the Phase-2 grader emits
# (the successor of assert-digest-contract.sh, which still guards the rendered
# plain-text fallback). Repo doctrine: an instruction in the rubric is not
# enforcement — a fallback model can hallucinate conversation ids, inflate
# theme counts, or fabricate a Tools score. This script is the backstop.
#
# Usage:
#   validate-digest.sh <digest.json> <conversations.jsonl> [audit.jsonl]
#
# On success: writes the NORMALIZED digest to stdout —
#   - every theme's unique_customers is RECOMPUTED via cluster-questions.sh
#     (contact_id dedupe over conversations.jsonl); the grader's claim is
#     overwritten, never trusted;
#   - daily/weekly themes whose recomputed count is < 2 are dropped with a
#     stderr note (informational threshold, not a run failure).
# On a contract violation: emits NOTHING to stdout, prints what is wrong to
# stderr, and exits 1 — the agent must fix digest.json and re-run.
#
# Checks:
#   - schema/shape (kind, date, window, counts, scores, guard, findings, themes)
#   - scores.tools "skipped" iff the join-key prereq is unavailable
#     (CV_TOOL_CTX_CONVERSATION_ID, exported by preflight.sh — a numeric score
#     without the join key is fabricated; "skipped" with it available is lazy)
#   - ANTI-HALLUCINATION: every cited conversation_id must exist in
#     conversations.jsonl. Carve-out (mirrors the SKILL.md hard rule): guard
#     items may cite ids from audit.jsonl instead — an ESCALATED conv had its
#     reply suppressed and is absent from the fetch by design.
#   - kb_gap_candidates: weekly only, and each must have a RECOMPUTED
#     unique_customers >= 3 (they feed KB-edit automation; daily must be empty).
# Optional env: CAROLINE_EXPECTED_KIND (daily|weekly) — set by the SKILL
# invocation so a digest graded in the wrong mode cannot ship.

set -euo pipefail

DIGEST="${1:?usage: validate-digest.sh <digest.json> <conversations.jsonl> [audit.jsonl]}"
CONVS="${2:?usage: validate-digest.sh <digest.json> <conversations.jsonl> [audit.jsonl]}"
AUDIT="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
fail() { echo "validate-digest: $*" >&2; FAILED=1; }
note() { echo "validate-digest: note: $*" >&2; }

[ -f "$CONVS" ] || { echo "validate-digest: conversations file not found: $CONVS" >&2; exit 1; }
jq -e . "$DIGEST" >/dev/null 2>&1 \
  || { echo "validate-digest: digest is not valid JSON: $DIGEST" >&2; exit 1; }

# --- 1. Structural checks (one jq pass; one error per line) -----------------
# Every field access goes through g()/arr() (try/catch-wrapped getpath) and
# every element predicate through ok(): a type-mismatched field (e.g. .scores
# is a string) must surface as a reported error, never as a silently-empty jq
# stream that would let the check pass.
struct_errs=$(jq -r '
  def g(p): try getpath(p) catch null;
  def ok(f): try f catch false;
  def digits: type == "string" and test("^[0-9]{15,16}$");
  def isarr(p): (g(p) // []) | type == "array";
  def arr(p): (g(p) // []) | if type == "array" then . else [] end;
  if type != "object" then ["digest must be a single JSON object"]
  else [
    (if g(["kind"]) == "daily" or g(["kind"]) == "weekly" then empty
     else "kind must be \"daily\" or \"weekly\"" end),
    (if ok(g(["date"]) | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then empty
     else "date (YYYY-MM-DD string) required" end),
    (if ok(g(["window_hours"]) | type == "number" and . > 0) then empty
     else "window_hours (positive number) required" end),
    (if ok(g(["conv_count"]) | type == "number" and . >= 0) then empty
     else "conv_count (non-negative number) required" end),
    (if ([g(["severity","p0"]), g(["severity","p1"]), g(["severity","p2"])]
         | all(type == "number" and . >= 0)) then empty
     else "severity.p0 / .p1 / .p2 (non-negative numbers) required" end),
    (if ok(g(["scores","voice"]) | type == "number" and . >= 0 and . <= 5) then empty
     else "scores.voice (0-5) required" end),
    (if ok(g(["scores","sentiment"]) | type == "number" and . >= 0 and . <= 5) then empty
     else "scores.sentiment (0-5) required" end),
    (if g(["scores","tools"]) == "skipped"
        or ok(g(["scores","tools"]) | type == "number" and . >= 0 and . <= 5) then empty
     else "scores.tools (0-5 or \"skipped\") required" end),
    (if ([g(["guard","caught_stripped"]), g(["guard","caught_escalated"]), g(["guard","missed_shipped"])]
         | all(type == "number" and . >= 0)) then empty
     else "guard.caught_stripped / .caught_escalated / .missed_shipped (numbers) required" end),
    (if g(["guard","source"]) == "journalctl" or g(["guard","source"]) == "syslog"
        or g(["guard","source"]) == "none" then empty
     else "guard.source must be journalctl|syslog|none" end),
    (if isarr(["guard","items"]) and (arr(["guard","items"]) | all(ok(
          (.type == "unanswered_escalation" or .type == "shipped_leak")
          and (.conversation_id | digits)))) then empty
     else "guard.items[] need type unanswered_escalation|shipped_leak + a 15-16 digit conversation_id" end),
    (if isarr(["findings"]) and (arr(["findings"]) | all(ok(
          (.dimension == "voice" or .dimension == "tools" or .dimension == "sentiment" or .dimension == "good_catch")
          and (.severity == "P0" or .severity == "P1" or .severity == "P2" or .severity == "info")
          and ((.text | type) == "string" and (.text | length) > 0)
          and ((.conversation_ids // []) | all(digits))))) then empty
     else "findings[] need dimension voice|tools|sentiment|good_catch, severity P0|P1|P2|info, non-empty text, 15-16 digit conversation_ids" end),
    (if isarr(["themes"]) and (arr(["themes"]) | all(ok(
          (.category == "issue" or .category == "question" or .category == "feature_request" or .category == "escalation_pattern")
          and ((.label | type) == "string" and (.label | length) > 0)
          and ((.summary | type) == "string")
          and ((.conversation_ids // []) | length > 0)
          and ((.conversation_ids // []) | all(digits))))) then empty
     else "themes[] need category issue|question|feature_request|escalation_pattern, label, summary, non-empty 15-16 digit conversation_ids" end),
    (if g(["kind"]) == "daily" and (arr(["kb_gap_candidates"]) | length) > 0
     then "kb_gap_candidates must be empty on the daily run (weekly KB roll-up only)" else empty end),
    (if g(["kind"]) == "weekly" and
        ((isarr(["kb_gap_candidates"]) and (arr(["kb_gap_candidates"]) | all(ok(
          ((.label | type) == "string" and (.label | length) > 0)
          and ((.proposed_kb_note | type) == "string" and (.proposed_kb_note | length) > 0)
          and ((.conversation_ids // []) | length > 0)
          and ((.conversation_ids // []) | all(digits)))))) | not)
     then "kb_gap_candidates[] need label, proposed_kb_note, non-empty 15-16 digit conversation_ids" else empty end),
    (if isarr(["degraded"]) and (arr(["degraded"]) | all(type == "string")) then empty
     else "degraded must be an array of strings" end)
  ] end | .[]
' "$DIGEST")

if [ -n "$struct_errs" ]; then
  while IFS= read -r e; do fail "$e"; done <<< "$struct_errs"
  echo "validate-digest: structural contract NOT met - fix digest.json per references/digest-schema.json and re-run." >&2
  exit 1
fi

# --- 2. Mode + join-key gates ------------------------------------------------
kind=$(jq -r '.kind' "$DIGEST")
if [ -n "${CAROLINE_EXPECTED_KIND:-}" ] && [ "$kind" != "$CAROLINE_EXPECTED_KIND" ]; then
  fail "kind is \"$kind\" but this run expected \"$CAROLINE_EXPECTED_KIND\""
fi

tools=$(jq -r '.scores.tools' "$DIGEST")
case "${CV_TOOL_CTX_CONVERSATION_ID:-}" in
  available)
    [ "$tools" != "skipped" ] \
      || fail "scores.tools is \"skipped\" but preflight reports the join-key prereq is available - grade Dimension B"
    ;;
  unavailable)
    [ "$tools" = "skipped" ] \
      || fail "scores.tools is a number but the join-key prereq is unavailable - a numeric score here is fabricated; use \"skipped\""
    ;;
esac

# --- 3. Anti-hallucination: cited ids must exist in the evidence ------------
conv_ids_file=$(mktemp)
audit_ids_file=$(mktemp)
trap 'rm -f "$conv_ids_file" "$audit_ids_file"' EXIT
jq -r '.id // empty' "$CONVS" 2>/dev/null | sort -u > "$conv_ids_file"
if [ -n "$AUDIT" ] && [ -f "$AUDIT" ]; then
  jq -r 'select(.kind == "reasoning_leak") | .conv // empty' "$AUDIT" 2>/dev/null | sort -u > "$audit_ids_file"
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  grep -qx "$id" "$conv_ids_file" \
    || fail "conversation_id $id (findings/themes/kb) not present in conversations.jsonl - hallucinated evidence is a hard stop"
done < <(jq -r '[
    ((.findings // [])[] | (.conversation_ids // [])[]),
    ((.themes // [])[] | (.conversation_ids // [])[]),
    ((.kb_gap_candidates // [])[] | (.conversation_ids // [])[])
  ] | unique | .[]' "$DIGEST")

while IFS= read -r id; do
  [ -n "$id" ] || continue
  if ! grep -qx "$id" "$conv_ids_file" && ! grep -qx "$id" "$audit_ids_file"; then
    fail "guard item conversation_id $id not present in conversations.jsonl OR audit.jsonl"
  fi
done < <(jq -r '(.guard.items // [])[] | .conversation_id' "$DIGEST")

# --- 4. Theme recompute (never trust the grader's customer counts) ----------
THEME_MIN=2
KB_MIN=3

recompute_customers() {  # $1 = theme/candidate object -> recomputed count
  jq -c '{topic: .label, conversation_ids: .conversation_ids}' <<< "$1" \
    | "$SCRIPT_DIR/cluster-questions.sh" "$CONVS" | jq -r '.unique_customers'
}

append_with_count() {  # $1 = json array, $2 = object, $3 = recomputed count
  jq -c --argjson item "$(jq -c --argjson u "$3" '.unique_customers = $u' <<< "$2")" \
    '. + [$item]' <<< "$1"
}

themes_out="[]"
while IFS= read -r theme; do
  label=$(jq -r '.label' <<< "$theme")
  recomputed=$(recompute_customers "$theme")
  claimed=$(jq -r '.unique_customers // 0' <<< "$theme")
  [ "$claimed" = "$recomputed" ] \
    || note "theme \"$label\": unique_customers $claimed -> recomputed $recomputed (recomputed wins)"
  if [ "$recomputed" -lt "$THEME_MIN" ]; then
    note "dropping theme \"$label\" (recomputed unique_customers $recomputed < $THEME_MIN)"
    continue
  fi
  themes_out=$(append_with_count "$themes_out" "$theme" "$recomputed")
done < <(jq -c '(.themes // [])[]' "$DIGEST")

kb_out="[]"
while IFS= read -r cand; do
  label=$(jq -r '.label' <<< "$cand")
  recomputed=$(recompute_customers "$cand")
  if [ "$recomputed" -lt "$KB_MIN" ]; then
    fail "kb_gap_candidate \"$label\" has recomputed unique_customers $recomputed < $KB_MIN - demote it to a theme or drop it"
    continue
  fi
  kb_out=$(append_with_count "$kb_out" "$cand" "$recomputed")
done < <(jq -c '(.kb_gap_candidates // [])[]' "$DIGEST")

# --- 5. Verdict ---------------------------------------------------------------
if [ "$FAILED" -ne 0 ]; then
  echo "validate-digest: digest contract NOT met - refusing to emit. Fix digest.json and re-run." >&2
  exit 1
fi

jq -c --argjson themes "$themes_out" --argjson kb "$kb_out" \
  '.themes = $themes | .kb_gap_candidates = $kb' "$DIGEST"
