#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for Caroline's data-sourcing answer doctrine.
#
# Aaron's directive (2026-07-17): if Caroline is EVER asked how Muso gets its
# data / where the data comes from, she must strictly answer "via data
# partnerships" -- never naming a specific platform/provider and never saying we
# scrape, crawl, or buy it. The rule lives in workspaces/support/SOUL.md so it is
# always injected at bootstrap (authoritative over the retrieval-based reference
# library, where a KB row could otherwise shadow it).
#
# Prose != enforcement, so this guard fails CI if any load-bearing anchor of that
# doctrine is silently removed. It does NOT police runtime output -- that is the
# SOUL rule's job at inference time; this only stops the rule from disappearing.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SOUL="${SUPPORT_SOUL_FILE:-$ROOT/workspaces/support/SOUL.md}"

[ -f "$SOUL" ] || { echo "Missing $SOUL (run from repo root, or set SUPPORT_SOUL_FILE)." >&2; exit 2; }

fail=0

# require <file> <label> <fixed-substring>
# Fails loudly (does not exit) so every missing anchor is reported in one pass.
require() {
  local file="$1" label="$2" pat="$3"
  if ! grep -qF -- "$pat" "$file" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    fail=1
  fi
}

require "$SOUL" "the Data Sourcing doctrine section" \
  "Data Sourcing"
require "$SOUL" "the mandated 'via data partnerships' framing (Aaron's directive)" \
  "via data partnerships"
require "$SOUL" "the strictness (this is the ONLY permitted answer)" \
  "ONLY permitted answer"
require "$SOUL" "the never-name-a-specific-source ban" \
  "never name a specific data source"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Caroline's data-sourcing doctrine has regressed. Restore the missing anchors above." >&2
  echo "Context: scripts/check-data-sourcing-doctrine.sh header (Aaron directive 2026-07-17)." >&2
  exit 1
fi

echo "OK: data-sourcing doctrine intact (workspaces/support/SOUL.md)."
