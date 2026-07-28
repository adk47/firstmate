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

# The bootstrap files openclaw injects for edge/support, per the injector's own
# list in dist/workspace-*.js (SOUL, AGENTS, TOOLS, IDENTITY, USER, HEARTBEAT).
#
# SCOPE CAVEAT -- read before trusting a green run. deploy.sh rsync-EXCLUDES
# workspaces/*/{TOOLS,IDENTITY,MEMORY,HEARTBEAT}.md (deploy.sh:791,850,851,858)
# because agents edit them at runtime: the server owns those, and the repo copy
# is only a seed. So for those four this gate measures a file that is never
# deployed -- it catches repo-side bloat, NOT the live file. Measured drift
# today: repo TOOLS.md 46104 chars vs live /opt/hydra 46162.
# Only SOUL.md, AGENTS.md and USER.md are genuinely repo-owned and deployed.
# The authoritative check for the server-owned four is on node-8
# (scripts/memory-health-check.sh, which today measures only SOUL+MEMORY and in
# bytes rather than chars -- extending it is tracked separately).
BOOTSTRAP_FILES=(
  workspaces/support/SOUL.md      # repo-owned, deployed
  workspaces/support/AGENTS.md    # repo-owned, deployed
  workspaces/support/USER.md      # repo-owned, deployed
  workspaces/support/TOOLS.md     # server-owned: seed only
  workspaces/support/IDENTITY.md  # server-owned: seed only
  workspaces/support/HEARTBEAT.md # server-owned: seed only
  workspaces/support/MEMORY.md    # server-owned: seed only
)

CFG=openclaw-edge.json
AGENT=support

# Fail loud if the config is gone: a silent fallback here would let the gate
# pass green while measuring against a default the fleet does not run.
[ -f "$CFG" ] || { echo "FAIL: $CFG not found; cannot resolve the real caps." >&2; exit 2; }

# Resolve a cap the way openclaw itself does, by PATH not by position:
#   resolveAgentConfig(cfg, agentId)?.<key> ?? cfg.agents.defaults.<key>
# (dist/embedded-agent-helpers-*.js, verified on 2026.7.1). A plain
# `grep | head -1` is WRONG here -- openclaw-edge.json now carries the key
# twice (agents.defaults, and the support entry's override) and grep would
# return whichever appears first in the file, which is the wrong one.
# python3 is the house idiom for this (scripts/validate-shared-config.sh:18).
read_cap() { # read_cap <json-key> <default>
  python3 - "$CFG" "$AGENT" "$1" "$2" <<'PY'
import json, sys
cfg_path, agent_id, key, default = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(cfg_path) as fh:
        cfg = json.load(fh)
except Exception:
    print(default); sys.exit(0)
agents = cfg.get("agents") or {}
entry = next((a for a in (agents.get("list") or []) if a.get("id") == agent_id), {})
val = entry.get(key, (agents.get("defaults") or {}).get(key))
print(val if isinstance(val, int) and val > 0 else default)
PY
}
CAP=$(read_cap bootstrapMaxChars 40000)
# A per-file pass says nothing about the sum -- openclaw drops whole files once
# the total budget is spent, so assert the aggregate too.
TOTAL_CAP=$(read_cap bootstrapTotalMaxChars 120000)

FAILED=0
TOTAL=0
for f in "${BOOTSTRAP_FILES[@]}"; do
  # Fail loud on a missing file rather than skipping it: a silent `continue`
  # would let a deleted or renamed TOOLS.md pass this gate forever.
  [ -f "$f" ] || { echo "FAIL: $f is listed as a bootstrap file but does not exist." >&2; FAILED=1; continue; }
  # Force a UTF-8 locale so `wc -m` counts CHARACTERS (what openclaw caps on),
  # not bytes -- in a non-UTF-8 root/CI context `wc -m` falls back to bytes and
  # would over-count any multibyte char, tripping a false FAIL.
  CHARS=$(LC_ALL=C.UTF-8 wc -m < "$f" | tr -d '[:space:]')
  TOTAL=$((TOTAL + CHARS))
  if [ "$CHARS" -gt "$CAP" ]; then
    echo "FAIL: $f is $CHARS chars, over the per-file bootstrap cap of $CAP." >&2
    echo "openclaw keeps a 75% HEAD and a 25% TAIL and drops the MIDDLE, so a band" >&2
    echo "around ~75% through $f vanishes from every injected prompt. Trim it under" >&2
    echo "$CAP, or raise the cap for THIS AGENT ONLY via" >&2
    echo "agents.list[id=$AGENT].bootstrapMaxChars in $CFG." >&2
    echo "Do NOT raise agents.defaults.bootstrapMaxChars to fix one agent: that is" >&2
    echo "compared across both profiles by validate-shared-config.sh, and it also" >&2
    echo "scales memory-health-check.sh's 80% warn threshold for every other agent" >&2
    echo "(raising 40000->50000 moves it 32000->40000 and silences live warnings)." >&2
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
