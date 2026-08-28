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
#   operations/SOUL.md 43569 (limit 40000) on 2026-08-28 -- the dropped band was
#     the refund money-gates (>$500 needs Aaron, the --override-confirmed-by
#     token, the daily-5 throttle) plus "Honesty -- never fabricate a process"
#     and "Confirm writes by their result". Found only because someone measured
#     by hand. THIS GATE DID NOT CATCH IT: it was scoped to workspaces/support
#     alone, so the other nine agents were unmeasured. Scope, not logic, was the
#     defect -- the cap resolution below was already correct. Now every agent in
#     both profiles is measured, and the agent list comes from the CONFIG rather
#     than a hand-maintained list here, so a new agent is covered on the day it
#     is added instead of the day someone remembers to add it.
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
# openclaw's canonical set is 8 (workspace-DkQ7irPD.js): AGENTS, SOUL, TOOLS,
# IDENTITY, USER, HEARTBEAT, BOOTSTRAP, MEMORY. Note MEMORY is declared via
# DEFAULT_MEMORY_FILENAME = CANONICAL_ROOT_MEMORY_FILENAME = "MEMORY.md", so a
# grep for the literal string misses it -- it IS a bootstrap file.
# The bootstrap files openclaw injects, per the injector's own list in
# dist/workspace-*.js (SOUL, AGENTS, TOOLS, IDENTITY, USER, HEARTBEAT) plus MEMORY,
# which is declared via DEFAULT_MEMORY_FILENAME and so is missed by a grep for the
# literal string but IS a bootstrap file.
#
# SCOPE CAVEAT -- read before trusting a green run. deploy.sh rsync-EXCLUDES
# workspaces/*/{TOOLS,IDENTITY,MEMORY,HEARTBEAT}.md because agents edit them at
# runtime: the server owns those and the repo copy is only a seed. For those four
# this gate measures a file that is never deployed -- it catches repo-side bloat,
# NOT the live file. Only SOUL.md, AGENTS.md and USER.md are repo-owned and
# deployed. The authoritative check for the server-owned four is on node-8
# (scripts/memory-health-check.sh).
BOOTSTRAP_NAMES=(SOUL AGENTS USER TOOLS IDENTITY HEARTBEAT MEMORY)

# BOOTSTRAP.md is the 8th canonical name but is NOT required: it is the
# un-onboarded-workspace marker (isWorkspaceBootstrapPending), so its ABSENCE is
# the healthy steady state. Size it when present, never demand it.
OPTIONAL_NAMES=(BOOTSTRAP)

# Only these three are repo-owned; the rest are seeds. A missing repo-owned file is
# a FAIL (a renamed SOUL.md must not pass forever); a missing seed is skipped.
REPO_OWNED=(SOUL AGENTS USER)

# EVERY profile, not just edge. The 2026-08-28 miss was a scope miss.
CONFIGS=(openclaw-main.json openclaw-edge.json)
for _c in "${CONFIGS[@]}"; do
  # Fail loud if a config is gone: a silent fallback would let the gate pass green
  # while measuring against a default the fleet does not run.
  [ -f "$_c" ] || { echo "FAIL: $_c not found; cannot resolve the real caps." >&2; exit 2; }
done

# Enumerate (config, agent-id, workspace-dir) from the configs themselves, so a new
# agent is measured the day it is added. openclaw resolves the workspace from the
# agent entry's `workspace` path; we map it back to a repo-relative dir.
#
# FAILS CLOSED, and this is the whole point of the block. The first version swallowed
# a parse error per-config and moved on: with a malformed openclaw-main.json and a
# valid openclaw-edge.json, main vanished from the measurement, edge still produced
# rows, the non-empty check passed, and the gate went GREEN having measured only
# support -- reconstructing precisely the silent scope hole this change exists to
# close. An unreadable config is "I could not check", which is a different answer
# from "there was nothing to find", and only the second one is an answer.
# An entry missing `id` or `workspace` is refused for the same reason rather than
# skipped: a row we cannot resolve is an agent we are not measuring.
set +e
AGENT_ROWS="$(python3 - "${CONFIGS[@]}" 2>&1 <<'PY'
import json, sys, os
rows, errs = [], []
for cfg_path in sys.argv[1:]:
    try:
        with open(cfg_path) as fh:
            cfg = json.load(fh)
    except Exception as e:
        errs.append(f"{cfg_path}: cannot read or parse ({e.__class__.__name__}: {e})")
        continue
    entries = ((cfg.get("agents") or {}).get("list") or [])
    if not isinstance(entries, list) or not entries:
        errs.append(f"{cfg_path}: agents.list is missing or empty")
        continue
    for i, a in enumerate(entries):
        if not isinstance(a, dict):
            errs.append(f"{cfg_path}: agents.list[{i}] is not an object")
            continue
        aid = a.get("id")
        ws = a.get("workspace") or a.get("cwd") or a.get("workspaceDir") or ""
        if not aid or not ws:
            errs.append(f"{cfg_path}: agents.list[{i}] has no usable id/workspace "
                        f"(id={aid!r}) -- refusing to skip an agent we cannot resolve")
            continue
        rows.append(f"{cfg_path}\t{aid}\tworkspaces/{os.path.basename(ws.rstrip('/'))}")
if errs:
    for e in errs:
        print("ENUMERATION FAILURE: " + e, file=sys.stderr)
    sys.exit(3)
print("\n".join(rows))
PY
)"
_enum_rc=$?
set -e
if [ "$_enum_rc" -ne 0 ]; then
  echo "FAIL: could not enumerate the agents to measure. The gate refuses to run on a" >&2
  echo "      partial view -- a profile that cannot be parsed is a profile whose agents" >&2
  echo "      would silently go unmeasured, which is the exact failure this gate exists" >&2
  echo "      to prevent. Fix the config, do not narrow the scope." >&2
  printf '%s\n' "$AGENT_ROWS" | sed 's/^/      /' >&2
  exit 2
fi
[ -n "$AGENT_ROWS" ] || { echo "FAIL: enumerated zero agents from ${CONFIGS[*]}; refusing to pass on an empty measurement." >&2; exit 2; }


# (Config existence is asserted per-config in the CONFIGS loop above, before any
# agent is enumerated -- a missing config must not degrade into a default cap.)

# Resolve a cap the way openclaw itself does, by PATH not by position:
#   resolveAgentConfig(cfg, agentId)?.<key> ?? cfg.agents.defaults.<key>
# (dist/embedded-agent-helpers-*.js, verified on 2026.7.1). A plain
# `grep | head -1` is WRONG here -- openclaw-edge.json now carries the key
# twice (agents.defaults, and the support entry's override) and grep would
# return whichever appears first in the file, which is the wrong one.
# python3 is the house idiom for this (scripts/validate-shared-config.sh:18).
read_cap() { # read_cap <cfg> <agent-id> <json-key> <default>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
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
FAILED=0

# HEAD/TAIL split openclaw uses when it trims (BOOTSTRAP_HEAD_RATIO=0.75 /
# BOOTSTRAP_TAIL_RATIO=0.25). Used only to NAME what would disappear -- a gate that
# says "3569 chars over" sends you to count characters; one that says "the band that
# vanishes contains 'Honesty -- never fabricate a process'" sends you to the fix.
HEAD_RATIO_PCT=75

while IFS=$'\t' read -r CFG AGENT WSDIR; do
  [ -n "${CFG:-}" ] || continue
  CAP=$(read_cap "$CFG" "$AGENT" bootstrapMaxChars 40000)
  # A per-file pass says nothing about the sum -- openclaw drops whole files once the
  # total budget is spent, so assert the aggregate too.
  TOTAL_CAP=$(read_cap "$CFG" "$AGENT" bootstrapTotalMaxChars 120000)
  TOTAL=0

  for NAME in "${BOOTSTRAP_NAMES[@]}" "${OPTIONAL_NAMES[@]}"; do
    f="$WSDIR/$NAME.md"
    if [ ! -f "$f" ]; then
      # A missing REPO-OWNED file is a failure: a renamed or deleted SOUL.md must not
      # pass this gate forever. A missing seed or optional marker is normal.
      case " ${REPO_OWNED[*]} " in
        *" $NAME "*) echo "FAIL: $f is repo-owned and listed as a bootstrap file but does not exist." >&2; FAILED=1 ;;
      esac
      continue
    fi
    # Force UTF-8 so `wc -m` counts CHARACTERS (what openclaw caps on), not bytes --
    # in a non-UTF-8 CI context it falls back to bytes and over-counts multibyte text.
    CHARS=$(LC_ALL=C.UTF-8 wc -m < "$f" | tr -d '[:space:]')
    TOTAL=$((TOTAL + CHARS))
    if [ "$CHARS" -gt "$CAP" ]; then
      HEAD=$(( CAP * HEAD_RATIO_PCT / 100 ))
      DROP_END=$(( CHARS - (CAP - HEAD) ))
      echo "FAIL: $f is $CHARS chars, over the per-file bootstrap cap of $CAP (agent '$AGENT', $CFG)." >&2
      echo "      openclaw keeps a ${HEAD_RATIO_PCT}% HEAD and the rest as TAIL and drops the MIDDLE," >&2
      echo "      so chars ${HEAD}..${DROP_END} vanish from EVERY injected prompt. That band is:" >&2
      # python3, not awk: the cap counts CHARACTERS and awk's length() counts BYTES in
      # a C locale, so on any file with an em-dash the two disagree and the band slides.
      # Naming the wrong headings is worse than naming none.
      python3 - "$f" "$HEAD" "$DROP_END" >&2 <<'PY' || true
import sys
path, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
n = 0
hits = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        start = n
        n += len(line)
        if line.startswith("#") and start < b and n > a:
            hits.append("        " + line.rstrip())
print("\n".join(hits) if hits else "        (no headings in the band -- it lands mid-section, so the loss is prose, not a whole rule)")
PY
      echo "      Fix by moving REFERENCE material to $WSDIR/reference/ with a pointer stub," >&2
      echo "      keeping binding rules in the first ${HEAD} chars. Raising the cap is NOT the fix:" >&2
      echo "      it exists for boot-memory reasons. If an agent genuinely needs more, raise it for" >&2
      echo "      THAT AGENT ONLY via agents.list[id=$AGENT].bootstrapMaxChars in $CFG -- never" >&2
      echo "      agents.defaults, which validate-shared-config.sh compares across both profiles and" >&2
      echo "      which also scales memory-health-check.sh's 80% warn threshold for every other agent." >&2
      FAILED=1
    else
      HEADROOM=$(( CAP - CHARS ))
      # Non-blocking, because a thin margin is not yet a defect -- but it is the state
      # every one of these incidents passed through on the way to being one.
      if [ "$HEADROOM" -lt $(( CAP / 10 )) ]; then
        echo "WARN: $f is $CHARS chars (cap $CAP) -- only $HEADROOM chars of headroom (<10%). Plan the trim before it is urgent."
      else
        echo "OK: $f is $CHARS chars (cap $CAP, headroom $HEADROOM)."
      fi
    fi
  done

  if [ "$TOTAL" -gt "$TOTAL_CAP" ]; then
    echo "FAIL: $AGENT bootstrap total is $TOTAL chars, over $TOTAL_CAP." >&2
    FAILED=1
  else
    echo "OK: $AGENT bootstrap total is $TOTAL chars (cap $TOTAL_CAP, headroom $((TOTAL_CAP - TOTAL)))."
  fi
done <<< "$AGENT_ROWS"

exit "$FAILED"
