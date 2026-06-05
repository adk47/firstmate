#!/usr/bin/env bash
# Fail-loud header contract for the daily glanceable digest.
#
# The digest is LLM-assembled freeform text, and repo doctrine is that an
# instruction in the rubric is not enforcement (feedback_llm_instruction_insufficient):
# a weaker fallback model (gemini / sonnet) can silently drop the at-a-glance
# header that is the whole point of the daily pulse. This is the mechanical
# backstop. Run it as the LAST stage of Phase 3:
#
#   <assemble review text> | scripts/redact-output.sh | scripts/assert-digest-contract.sh
#
# On success it passes the digest through UNCHANGED on stdout (so it becomes the
# final assistant message). On a contract violation it emits NOTHING to stdout,
# prints exactly what is missing to stderr, and exits 1 -- so a header-less or
# score-less partial digest can never reach #cs_chats. The agent must fix the
# Phase-3 assembly and re-run.
set -euo pipefail

digest="$(cat)"
errors=()

# Line 1 (headline) MUST carry the severity triplet "<n> P0 / <n> P1 / <n> P2"
# (zeros included) and the conversation count, so the post is readable at a glance.
header="${digest%%$'\n'*}"   # first line, via parameter expansion (no pipe -> no SIGPIPE under set -e)
if ! printf '%s' "$header" | grep -qE '[0-9]+ P0 / [0-9]+ P1 / [0-9]+ P2'; then
  errors+=("line 1 missing the '<n> P0 / <n> P1 / <n> P2' severity triplet (zeros included)")
fi
if ! printf '%s' "$header" | grep -qiE '[0-9]+ *conv'; then
  errors+=("line 1 missing the conversation count (e.g. '23 convs')")
fi

# The scores line is line 2 and MUST carry all three retained dimension labels
# (KB dropped). Check ONLY line 2: a malformed digest with no scores line must not
# pass just because a later detail bullet happens to mention these words.
scores_line=""
if [ "$digest" != "${digest#*$'\n'}" ]; then   # a second line exists
  after_l1="${digest#*$'\n'}"        # everything after line 1 (+ its newline)
  scores_line="${after_l1%%$'\n'*}"  # line 2
fi
for label in Voice Tools Sentiment; do
  if ! printf '%s' "$scores_line" | grep -qE "(^|[^A-Za-z])${label}([^A-Za-z]|\$)"; then
    errors+=("missing the '$label' score label on line 2")
  fi
done

# The reasoning-leak guard block is mandatory: it always prints at least a one-line
# healthy summary, so requiring it guarantees the section is never silently dropped
# (a quiet guard log alone does not prove zero leaks -- the digest must say so).
if ! printf '%s' "$digest" | grep -qiE 'guard'; then
  errors+=("missing the reasoning-leak guard line (required every run: healthy summary or findings)")
fi

if [ "${#errors[@]}" -ne 0 ]; then
  {
    echo "assert-digest-contract: daily digest header contract NOT met -- refusing to emit:"
    for e in "${errors[@]}"; do echo "  - $e"; done
    echo "Fix Phase-3 assembly so line 1 has '<emoji> ... <N> convs ... <p0> P0 / <p1> P1 / <p2> P2'"
    echo "and line 2 has 'Voice <s> | Tools <s or skipped> | Sentiment <s>', then re-run."
  } >&2
  exit 1
fi

printf '%s\n' "$digest"
