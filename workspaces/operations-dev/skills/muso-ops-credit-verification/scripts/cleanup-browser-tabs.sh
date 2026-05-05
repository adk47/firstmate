#!/usr/bin/env bash
# cleanup-browser-tabs.sh — close all stale browser tabs and reopen a single
# fresh about:blank, before/after a credit-verification batch.
#
# Why this exists: run 20260504-215412-2067ce showed empty browser snapshots
# (~769 bytes, literal-empty `Source: Browser\n---\n` wrapper) for 4
# distinct Tier-1 hosts after 17 stale tabs had accumulated from prior runs.
# A live probe of the same URLs from a clean browser worked fine. The
# headless Chrome process degrades when tabs pile up — captcha pages,
# service workers, blob: URLs all stay resident. Closing them is the
# mechanical layer; SKILL.md just instructs the agent to call this script.
#
# Usage:
#   cleanup-browser-tabs.sh
#
# Env (read-only):
#   OPENCLAW_BROWSER_PROFILE   defaults to "main"
#
# Output (stdout): single JSON line summarizing the result.
#   {"closed": <int>, "remaining": <int>}
#
# Exit codes:
#   0  cleanup completed (zero or more tabs closed)
#   2  openclaw CLI not available

set -euo pipefail

PROFILE="${OPENCLAW_BROWSER_PROFILE:-main}"

if ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: openclaw CLI not on PATH" >&2
    exit 2
fi

# List tab IDs (32-hex). awk filter is anchored on `id: <hex>` lines because
# the human-readable URL line above each id can also contain hex sequences.
list_tab_ids() {
    openclaw browser tabs --profile "$PROFILE" 2>/dev/null \
      | awk '/^[[:space:]]*id: [A-F0-9]{32}$/ {print $2}'
}

closed=0
for tid in $(list_tab_ids); do
    # Some tabs (service workers, blobs) auto-close when their parent tab
    # is closed, so a "tab not found" rc is expected and not an error.
    if openclaw browser close "$tid" --profile "$PROFILE" >/dev/null 2>&1; then
        closed=$((closed + 1))
    fi
done

# Reopen a fresh about:blank so subsequent batch ops have a tab to navigate
# rather than racing the headless process to spawn a new target.
openclaw browser open "about:blank" --profile "$PROFILE" >/dev/null 2>&1 || true

remaining=$(list_tab_ids | wc -l | tr -d ' ')

printf '{"closed":%d,"remaining":%d}\n' "$closed" "$remaining"
