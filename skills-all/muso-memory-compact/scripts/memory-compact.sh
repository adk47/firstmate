#!/usr/bin/env bash
# memory-compact.sh — deterministic toolkit for the muso-memory-compact skill.
#
# Keeps an agent's MEMORY.md (Tier-1 bootstrap file) under the openclaw per-file
# bootstrap cap by giving the skill safe, consistent primitives for the
# mechanical parts of a compaction pass:
#
#   scan       JSON inventory of every workspace MEMORY.md, flagging which are
#              over the Tier-1 target / over the hard cap (default-target picker).
#   measure    JSON snapshot for ONE agent (chars, target, cap, today's dated
#              memory path, profile) — call before and after the edit.
#   backup     timestamped copy of MEMORY.md into the rsync-excluded memory/ dir.
#   append     append STDIN (cold-but-durable entries the agent decided to MOVE)
#              to the agent's dated memory/YYYY-MM-DD.md, under a provenance
#              header, so the knowledge stays memory_search-indexed.
#   watermark  record the last compaction (UTC + final char count) under memory/.
#
# What this script DOES NOT do: it never rewrites MEMORY.md and never decides
# which entries are cold/obsolete. That is judgment, and it belongs to the agent
# driving SKILL.md (it edits MEMORY.md itself via exec). This toolkit only
# guarantees the I/O around that edit is backed-up, atomic, and consistent.
#
# Write surface (ALL under the agent's OWN workspace, agent-owned + rsync-excluded):
#   /opt/hydra/workspaces/<agent>/memory/MEMORY.md.bak-<UTC>   (backup)
#   /opt/hydra/workspaces/<agent>/memory/<YYYY-MM-DD>.md       (append)
#   /opt/hydra/workspaces/<agent>/memory/.memory-compact-watermark  (watermark)
# It NEVER writes MEMORY.md, reference/*.md, SOUL.md, skills/, or anything
# deploy-authoritative. The MEMORY.md rewrite is the agent's job (Edit via exec).
#
# Live paths verified against the sibling skill (skills-all/muso-devops-self-improve)
# and docs/guides/WORKSPACE-FILE-OWNERSHIP.md (Tiered Memory Layout, issue #165).
set -euo pipefail

# --- defaults --------------------------------------------------------------
WORKSPACES_ROOT="/opt/hydra/workspaces"
TARGET=8000           # Tier-1 compaction target (chars). Comfortable margin
                      # under the 40000 cap; the guide's ~3500 is the stretch
                      # ideal for a pure index, not a hard floor for this skill.
CAP=40000             # live agents.defaults.bootstrapMaxChars (over-cap files
                      # are silently MIDDLE-dropped by openclaw bootstrap.ts).
PROFILE="main"        # gateway profile (threaded into `measure` output so the
                      # agent passes the right --profile to native memory CLI).
AGENT=""
# Agents under a STANDING compaction halt -- never auto-compacted. coordinator
# (clio): Aaron directive in workspaces/coordinator/HEARTBEAT.md (2026-03-19),
# "DO NOT compress or compact memory files". Unset MEMCOMPACT_EXCLUDE -> this
# default; set MEMCOMPACT_EXCLUDE="" to disable, or to a space-separated list.
EXCLUDE_AGENTS="${MEMCOMPACT_EXCLUDE-coordinator}"

usage() {
  cat <<'EOF'
Usage:
  memory-compact.sh scan      [--target N] [--cap N] [--workspaces-root DIR]
  memory-compact.sh measure   --agent NAME [--target N] [--cap N] [--profile P]
                              [--workspaces-root DIR]
  memory-compact.sh backup    --agent NAME [--workspaces-root DIR]
  memory-compact.sh append    --agent NAME [--workspaces-root DIR]   # text on STDIN
  memory-compact.sh watermark --agent NAME [--chars N] [--workspaces-root DIR]

Deterministic primitives for the muso-memory-compact skill. Char counts use
`wc -m` to match openclaw's bootstrap cap accounting. All writes land under the
target agent's own rsync-excluded memory/ dir; MEMORY.md itself is rewritten by
the agent, never by this script.
EOF
}

die() { echo "memory-compact.sh: $*" >&2; exit 2; }

# --- arg parse -------------------------------------------------------------
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
CMD="$1"; shift
CHARS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)           AGENT="$2"; shift 2 ;;
    --target)          TARGET="$2"; shift 2 ;;
    --cap)             CAP="$2"; shift 2 ;;
    --profile)         PROFILE="$2"; shift 2 ;;
    --workspaces-root) WORKSPACES_ROOT="$2"; shift 2 ;;
    --chars)           CHARS_ARG="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found"

# Char count. LC_ALL=C.UTF-8 pins locale (code points, not bytes) to match the
# sibling SOUL-size CI guard (scripts/check-soul-bootstrap-size.sh); close enough
# to openclaw's accounting given the 8000/40000 margins.
char_count() { LC_ALL=C.UTF-8 wc -m < "$1" | tr -d '[:space:]'; }

require_agent() {
  [[ -n "$AGENT" ]] || die "$CMD requires --agent NAME"
  # Reject anything but a bare workspace dir name -- blocks path traversal
  # (../ or absolute paths) so a write can never escape the workspace.
  [[ "$AGENT" =~ ^[A-Za-z0-9._-]+$ && "$AGENT" != ".." ]] \
    || die "invalid agent name: '$AGENT' (expected a bare workspace dir name)"
}

is_excluded() { case " $EXCLUDE_AGENTS " in *" $1 "*) return 0 ;; esac; return 1; }

# Refuse a mutating op on an agent under a standing compaction halt.
refuse_if_excluded() {
  is_excluded "$AGENT" || return 0
  die "agent '$AGENT' is under a compaction HALT (Aaron, coordinator/HEARTBEAT.md 2026-03-19); refusing $CMD. If lifted, re-run with MEMCOMPACT_EXCLUDE=''"
}

# Refuse a mutating op whose agent workspace doesn't already exist, so a typo'd
# --agent can never create a stray /opt/hydra/workspaces/<typo>/ dir (the write
# surface is promised to be an EXISTING agent's own workspace).
require_workspace() {
  [[ -d "$WORKSPACES_ROOT/$AGENT" ]] \
    || die "$CMD: workspace not found: $WORKSPACES_ROOT/$AGENT (refusing to create a stray dir for '$AGENT')"
}

agent_mem()      { printf '%s/%s/MEMORY.md' "$WORKSPACES_ROOT" "$AGENT"; }
agent_memdir()   { printf '%s/%s/memory'    "$WORKSPACES_ROOT" "$AGENT"; }

case "$CMD" in
  # ----------------------------------------------------------------- scan ---
  scan)
    [[ -d "$WORKSPACES_ROOT" ]] || die "workspaces root not found: $WORKSPACES_ROOT"
    {
      for mem in "$WORKSPACES_ROOT"/*/MEMORY.md; do
        [[ -f "$mem" ]] || continue
        a="$(basename "$(dirname "$mem")")"
        is_excluded "$a" && continue   # halted agent (EXCLUDE_AGENTS) -- never a default target
        c="$(char_count "$mem")"
        jq -n --arg a "$a" --argjson c "${c:-0}" --argjson t "$TARGET" --argjson cap "$CAP" \
          '{agent:$a, chars:$c, over_target:($c>$t), over_cap:($c>$cap)}'
      done
    } | jq -s --argjson t "$TARGET" --argjson cap "$CAP" --arg exclude "$EXCLUDE_AGENTS" '{
          target: $t,
          cap: $cap,
          excluded: ($exclude | split(" ") | map(select(length > 0))),
          agents: (sort_by(-.chars)),
          over_target_agents: (map(select(.over_target)) | sort_by(-.chars) | map(.agent)),
          over_cap_agents:    (map(select(.over_cap))    | sort_by(-.chars) | map(.agent))
        }'
    ;;

  # -------------------------------------------------------------- measure ---
  measure)
    require_agent
    mem="$(agent_mem)"
    memdir="$(agent_memdir)"
    today="$(date -u +%Y-%m-%d)"
    dated="${memdir}/${today}.md"
    if [[ -f "$mem" ]]; then exists=true; chars="$(char_count "$mem")"; else exists=false; chars=0; fi
    jq -n \
      --arg   agent   "$AGENT" \
      --arg   profile "$PROFILE" \
      --arg   mem     "$mem" \
      --arg   memdir  "$memdir" \
      --arg   dated   "$dated" \
      --arg   today   "$today" \
      --argjson exists "$exists" \
      --argjson chars  "${chars:-0}" \
      --argjson target "$TARGET" \
      --argjson cap    "$CAP" '{
        agent: $agent,
        profile: $profile,
        memory_path: $mem,
        memory_exists: $exists,
        chars: $chars,
        target: $target,
        cap: $cap,
        over_target: ($chars > $target),
        over_cap:    ($chars > $cap),
        chars_over_target: (if $chars > $target then ($chars - $target) else 0 end),
        memory_dir: $memdir,
        dated_memory_path: $dated,
        today: $today
      }'
    ;;

  # --------------------------------------------------------------- backup ---
  backup)
    require_agent; refuse_if_excluded
    mem="$(agent_mem)"
    [[ -f "$mem" ]] || die "no MEMORY.md to back up at: $mem"
    memdir="$(agent_memdir)"
    mkdir -p "$memdir"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    bak="${memdir}/MEMORY.md.bak-${ts}"
    cp "$mem" "$bak"
    echo "$bak"
    ;;

  # --------------------------------------------------------------- append ---
  # Reads cold-but-durable entries on STDIN and appends them to the agent's
  # dated memory file under a provenance header. These entries leave the
  # bootstrap-injected MEMORY.md but stay retrievable via memory_search (the
  # memory/ dir is auto-indexed). Append is the pressure valve that needs NO PR.
  append)
    require_agent; refuse_if_excluded; require_workspace
    memdir="$(agent_memdir)"
    today="$(date -u +%Y-%m-%d)"
    dated="${memdir}/${today}.md"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    cat > "$tmp"
    # Refuse to append nothing (a silent no-op would hide a broken move).
    if [[ ! -s "$tmp" ]] || ! grep -q '[^[:space:]]' "$tmp"; then
      die "append: STDIN was empty — nothing moved (did the agent forget to pipe the entries?)"
    fi
    mkdir -p "$memdir"
    [[ -f "$dated" ]] || printf '# %s — working memory\n' "$today" > "$dated"
    {
      printf '\n<!-- moved from MEMORY.md by muso-memory-compact at %s — durable but cold; kept here for memory_search -->\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      cat "$tmp"
      printf '\n'
    } >> "$dated"
    echo "$dated"
    ;;

  # ------------------------------------------------------------ watermark ---
  watermark)
    require_agent; refuse_if_excluded; require_workspace
    memdir="$(agent_memdir)"
    mkdir -p "$memdir"
    wm="${memdir}/.memory-compact-watermark"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mem="$(agent_mem)"
    if [[ -n "$CHARS_ARG" ]]; then
      final="$CHARS_ARG"
    elif [[ -f "$mem" ]]; then
      final="$(char_count "$mem")"
    else
      final="0"
    fi
    printf '%s\tchars=%s\ttarget=%s\tcap=%s\n' "$ts" "$final" "$TARGET" "$CAP" > "$wm"
    echo "$wm"
    ;;

  *)
    die "unknown subcommand: $CMD (try --help)"
    ;;
esac
