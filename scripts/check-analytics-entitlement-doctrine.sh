#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for Caroline's analytics entitlement doctrine.
#
# On 2026-09-30, Caroline disclosed another customer's lifetime stream figures
# to a non-subscriber, twice. The fix: analytics figures are entitlement-gated.
# Caroline must check profile_analytics_status and only reveal figures if
# analytics.entitled is true. If the entitlement check does not clearly pass,
# she must refuse and explain the plan+seat requirement. The rule lives in
# workspaces/support/SOUL.md so it is always injected at bootstrap (authoritative
# over the reference library, where stale guidance could shadow it).
#
# Prose != enforcement, so this guard fails CI if any load-bearing anchor of that
# doctrine is silently removed. It does NOT police runtime output -- that is the
# SOUL rule's job at inference time; this only stops the rule from disappearing.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SOUL="${SUPPORT_SOUL_FILE:-$ROOT/workspaces/support/SOUL.md}"

[ -f "$SOUL" ] || { echo "Missing $SOUL (run from repo root, or set SUPPORT_SOUL_FILE)." >&2; exit 2; }

fail=0

# require <file> <label> <fixed-substring>
# Fails loudly (does not exit) if the substring is absent, so every missing anchor is
# reported in one pass.
# Both matchers compare WHITESPACE-NORMALIZED text: the whole file is flattened
# to a single space-separated line before matching, and so is the pattern.
#
# `grep -qF` matches within one line, but every anchor here is prose in a
# Markdown file. An ordinary re-wrap splits "NEVER state, quote, summarise,
# reformat or screenshot" across two lines and the require stops matching —
# the rule reads exactly as before while CI goes green. That is a gate failing
# OPEN, which is the one direction it must never fail.
#
# require() gets the same treatment so a harmless re-flow cannot turn into a red
# run that someone then "fixes" by deleting the anchor.
_normalized() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }
_normalize_pat() { printf '%s' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '; }

require() {
  local file="$1" label="$2" pat="$3"
  if ! _normalized "$file" | grep -qF -- "$(_normalize_pat "$pat")" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    fail=1
  fi
}

# --- support SOUL.md: analytics entitlement doctrine -------------------------
# Anchors are on SOUL.md only. TOOLS.md is rsync-excluded from deploy (scripts/deploy.sh:1105),
# so a gate anchored there proves the text exists where nothing reads it: fail-open certification.
# Before anchoring on any workspace file, check deploy.sh for an exclude.
require "$SOUL" "the analytics figures prohibition" \
  "NEVER state, quote, summarise, reformat or screenshot stream or analytics figures"
require "$SOUL" "the profile_analytics_status field (entitlement check)" \
  "profile_analytics_status"
require "$SOUL" "the analytics.entitled boolean" \
  "analytics.entitled"
require "$SOUL" "the allow-list condition: entitlement is required to see figures" \
  "unless the customer is entitled to them"
require "$SOUL" "the deny-list protection: is not true (not false)" \
  "if \`analytics.entitled\` is not \`true\`, Caroline states no figures"
require "$SOUL" "the allow-list: active Pro or Business plan" \
  "active Pro or Business plan with a seat"
require "$SOUL" "the allow-list concept: plan+seat requirement" \
  "analytics need an active Pro or Business plan with a seat"
require "$SOUL" "the reformatting evasion clause" \
  "Reformatting figures you should not have given is still giving them"
require "$SOUL" "the refusal copy" \
  "Stream and analytics figures come with Pro"
# Verify the refusal describes the actual plan/seat requirement.
# The copy is customer-facing and was reviewed for word cleanliness.
require "$SOUL" "the complete refusal copy with pro+seat requirement" \
  "Stream and analytics figures come with Pro – on an active Pro or Business plan with a seat"
# Figure-disclosure cases the original prohibition did not cover (MUS-10647).
require "$SOUL" "the per-reply entitlement rule" \
  "Entitlement is per reply, not per thread"
require "$SOUL" "the fresh status check on this turn" \
  'you need a fresh `profile_analytics_status` saying `analytics.entitled` is `true` on THIS turn'
require "$SOUL" "the customer-supplied figure rule" \
  "A figure the customer gave you is still a figure you may not repeat"
require "$SOUL" "the data-fix confirmation rule" \
  "After a data fix: confirm that the fix landed, never the number"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Analytics entitlement doctrine has regressed. Restore the missing anchors above." >&2
  echo "Context: scripts/check-analytics-entitlement-doctrine.sh header (2026-09-30 incident)." >&2
  exit 1
fi

echo "OK: analytics entitlement doctrine intact (workspaces/support/SOUL.md)."
