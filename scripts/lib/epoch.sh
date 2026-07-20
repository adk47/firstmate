#!/usr/bin/env bash
# epoch.sh — sourceable ISO-8601 -> epoch-seconds helper.
#
# Third-repetition extraction (pick-nightly-issue.sh + cto-nightly-driver.sh;
# scripts/lib/cto-push-audit-guard.sh carries an older inline `ts_to_epoch` it
# cannot source as a standalone pre-push hook). GNU date first, BSD/macOS date
# fallback (local dev boxes; CI + node-8 are Linux). Returns nonzero if neither
# parses — callers decide whether that is fatal.
# Pure function, no side effects at source time, safe under `set -e`.

iso_to_epoch() {
  local ts="$1"
  if date -u -d "$ts" +%s 2>/dev/null; then
    return 0
  fi
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null
}
