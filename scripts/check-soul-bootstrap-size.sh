#!/usr/bin/env bash
set -euo pipefail

# Fail if Caroline's SOUL.md exceeds the per-file bootstrap CHAR cap, which makes
# openclaw TRUNCATE its tail in the injected context and silently drop
# load-bearing doctrine (the Honesty / SLA-breach rules live near the end).
#
# This is not hypothetical: the edge gateway logged, on every turn for days,
#   [agent/embedded] workspace bootstrap file SOUL.md is 44028 chars
#   (limit 40000); truncating in injected context
# while SOUL sat at ~44-45k. Prose != enforcement; this guard is the mechanical
# backstop that keeps SOUL under the cap forever. openclaw counts CHARACTERS, so
# we measure with `wc -m`, not bytes.

# Guard: must be run from repo root.
[ -d workspaces/support ] || {
  echo "Run from repo root; workspaces/support not found." >&2
  exit 2
}

SOUL=workspaces/support/SOUL.md
[ -f "$SOUL" ] || { echo "Missing $SOUL" >&2; exit 2; }

# Read the real per-file cap from the edge config so this guard tracks the
# limit even if it's retuned; fall back to the openclaw default of 40000.
CFG=openclaw-edge.json
CAP=$(grep -oE '"bootstrapMaxChars"[[:space:]]*:[[:space:]]*[0-9]+' "$CFG" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
CAP=${CAP:-40000}

# Force a UTF-8 locale so `wc -m` counts CHARACTERS (what openclaw caps on), not
# bytes -- in a non-UTF-8 root/CI context `wc -m` falls back to bytes and would
# over-count any multibyte char, tripping a false FAIL with little headroom.
CHARS=$(LC_ALL=C.UTF-8 wc -m < "$SOUL" | tr -d '[:space:]')

if [ "$CHARS" -gt "$CAP" ]; then
  echo "FAIL: $SOUL is $CHARS chars, over the bootstrap cap of $CAP." >&2
  echo "openclaw truncates the TAIL of any bootstrap file past $CAP chars, dropping doctrine" >&2
  echo "(the Honesty / SLA-breach rules sit near the end). Trim SOUL.md back under $CAP." >&2
  exit 1
fi

echo "OK: SOUL.md is $CHARS chars (cap $CAP, headroom $((CAP - CHARS)))."
