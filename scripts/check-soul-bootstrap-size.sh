#!/usr/bin/env bash
set -euo pipefail

# Fail if any of Caroline's large bootstrap files exceeds the per-file bootstrap
# CHAR cap, which makes openclaw silently drop load-bearing doctrine from the
# injected context.
#
# WHAT ACTUALLY GETS DROPPED (corrected 2026-07-28 against the 2026.7.1 binary,
# `trimBootstrapContent` in dist/embedded-agent-helpers-Umilw3Yn.js): openclaw
# keeps a HEAD and a TAIL and removes the MIDDLE, inserting a truncation marker.
# The split is BOOTSTRAP_HEAD_RATIO=0.75 / BOOTSTRAP_TAIL_RATIO=0.25 of the
# budget. So the END of the file survives and a band at ~75% of the way through
# is what disappears. This header previously claimed the TAIL was truncated and
# that the trailing Honesty / SLA-breach rules were the content at risk -- that
# was wrong, and it pointed reviewers at the safe part of the file.
#
# This is not hypothetical, twice over:
#   SOUL.md  ~44-45k  (limit 40000) -- fixed by trimming SOUL
#   TOOLS.md  46162   (limit 40000) -- 310 warnings in 24h on 2026-07-28,
#     dropping the profile_credits_status (254 calls), profile_claim_status and
#     cancel_subscription (gated dangerous-tier write) sections on every turn.
# Prose != enforcement; this guard is the mechanical backstop. openclaw counts
# CHARACTERS, so we measure with `wc -m`, not bytes.

# Guard: must be run from repo root.
[ -d workspaces/support ] || {
  echo "Run from repo root; workspaces/support not found." >&2
  exit 2
}

# Every bootstrap file openclaw injects for edge/support. SOUL and TOOLS are the
# two that have actually breached; the rest are listed so a future one cannot
# breach silently.
BOOTSTRAP_FILES=(
  workspaces/support/SOUL.md
  workspaces/support/TOOLS.md
  workspaces/support/AGENTS.md
  workspaces/support/IDENTITY.md
  workspaces/support/USER.md
  workspaces/support/MEMORY.md
)
[ -f workspaces/support/SOUL.md ] || { echo "Missing workspaces/support/SOUL.md" >&2; exit 2; }

# Read the real per-file cap from the edge config so this guard tracks the
# limit even if it's retuned; fall back to the openclaw default of 40000.
CFG=openclaw-edge.json
CAP=$(grep -oE '"bootstrapMaxChars"[[:space:]]*:[[:space:]]*[0-9]+' "$CFG" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
CAP=${CAP:-40000}

# Also assert the aggregate stays under the total cap -- a per-file pass says
# nothing about the sum, and openclaw drops whole files once the total is spent.
TOTAL_CAP=$(grep -oE '"bootstrapTotalMaxChars"[[:space:]]*:[[:space:]]*[0-9]+' "$CFG" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
TOTAL_CAP=${TOTAL_CAP:-120000}

FAILED=0
TOTAL=0
for f in "${BOOTSTRAP_FILES[@]}"; do
  [ -f "$f" ] || continue
  # Force a UTF-8 locale so `wc -m` counts CHARACTERS (what openclaw caps on),
  # not bytes -- in a non-UTF-8 root/CI context `wc -m` falls back to bytes and
  # would over-count any multibyte char, tripping a false FAIL.
  CHARS=$(LC_ALL=C.UTF-8 wc -m < "$f" | tr -d '[:space:]')
  TOTAL=$((TOTAL + CHARS))
  if [ "$CHARS" -gt "$CAP" ]; then
    echo "FAIL: $f is $CHARS chars, over the per-file bootstrap cap of $CAP." >&2
    echo "openclaw keeps a 75% HEAD and a 25% TAIL and drops the MIDDLE, so a band" >&2
    echo "around ~75% through $f vanishes from every injected prompt. Trim it under" >&2
    echo "$CAP, or raise agents.defaults.bootstrapMaxChars in BOTH configs" >&2
    echo "(validate-shared-config.sh requires main and edge to match)." >&2
    FAILED=1
  else
    echo "OK: $f is $CHARS chars (cap $CAP, headroom $((CAP - CHARS)))."
  fi
done

if [ "$TOTAL" -gt "$TOTAL_CAP" ]; then
  echo "FAIL: edge/support bootstrap total is $TOTAL chars, over $TOTAL_CAP." >&2
  FAILED=1
else
  echo "OK: bootstrap total is $TOTAL chars (cap $TOTAL_CAP, headroom $((TOTAL_CAP - TOTAL)))."
fi

exit "$FAILED"
