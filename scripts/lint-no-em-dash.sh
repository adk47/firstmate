#!/usr/bin/env bash
set -euo pipefail

# Fail if em-dashes (U+2014) appear anywhere in Caroline's customer-facing
# surface. There are no legitimate exceptions: the Forbidden-phrasing block
# in common-issues.md uses en-dashes only, and any new instance is a bug.
#
# Mirror discovery is dynamic so the lint can't silently miss a new
# workspaces/<agent>/skills/muso-intercom/ copy. Per
# feedback_skill_dual_tree.md, the hardcoded {ceo,cto,operations} brace-
# expansion has bitten us 3× in the past and would bite again here.

# Guard: must be run from repo root.
[ -d workspaces/support ] || {
  echo "Run from repo root; workspaces/support not found." >&2
  exit 2
}

TARGETS=( workspaces/support skills-all/muso-intercom )
while IFS= read -r -d '' d; do
  TARGETS+=("$d")
done < <(find workspaces -mindepth 3 -maxdepth 3 -type d -name muso-intercom -print0)

for t in "${TARGETS[@]}"; do
  [ -d "$t" ] || { echo "Lint target missing: $t" >&2; exit 2; }
done

set +e
BAD=$(grep -rn $'\xe2\x80\x94' "${TARGETS[@]}")
rc=$?
set -e

case $rc in
  0) ;;                                # matches found
  1) BAD="" ;;                         # clean
  *) echo "grep failed (exit $rc) scanning: ${TARGETS[*]}" >&2; exit 3 ;;
esac

if [ -n "$BAD" ]; then
  echo "Em-dashes found in customer-facing knowledge base:"
  echo "$BAD"
  exit 1
fi
echo "OK: no stray em-dashes in customer-facing surface."
