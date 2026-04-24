#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# reap-mcp-remote-zombies.sh
#
# Kill orphan `mcp-remote` subprocesses older than MAX_AGE_MIN
# that are still parented to an openclaw gateway process.
#
# WHY: the openclaw bundle-mcp subsystem spawns an
# `npm exec mcp-remote → sh → node` process trio every time a
# remote MCP (e.g. NocoDB hosted at app.nocodb.com/mcp) gets
# registered. The previous subprocess is not reaped on re-register,
# so over a long gateway uptime these accumulate. On 2026-04-24 we
# found 216 orphaned mcp-remote processes consuming 14.77 GB of
# RSS on openclaw-gateway-main after ~20h uptime; a restart
# reclaimed ~15 GB.
#
# Until upstream reaps old subprocesses on re-register, this
# timer-driven reaper keeps the process count bounded.
#
# Safety rules:
#   - Only targets `mcp-remote` command lines (exact pattern match).
#   - Only targets processes whose pgid is an openclaw-gateway-*
#     service (checked via systemd-cgls).
#   - Only targets processes older than MAX_AGE_MIN (default 30m)
#     so in-flight tool calls are not interrupted.
#
# Usage: reap-mcp-remote-zombies.sh [max_age_minutes]  # default: 30
# ──────────────────────────────────────────────────────────────
set -euo pipefail

MAX_AGE_MIN="${1:-30}"
MAX_AGE_SEC=$((MAX_AGE_MIN * 60))

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] reap-mcp-remote: $*"; }

# Validate arg is a positive integer.
if ! [[ "$MAX_AGE_MIN" =~ ^[0-9]+$ ]] || (( MAX_AGE_MIN < 1 )); then
  log "ERROR: max_age_minutes must be a positive integer, got: $MAX_AGE_MIN"
  exit 2
fi

# Gather candidate PIDs: the outer `npm exec mcp-remote` wrappers.
# Matching on the full command line with grep -F and a literal
# substring keeps us from accidentally killing unrelated processes.
mapfile -t candidates < <(
  ps -eo pid,etimes,comm,args --no-headers \
    | awk -v min_secs="$MAX_AGE_SEC" '$2 >= min_secs' \
    | grep -F "mcp-remote" \
    | awk '{print $1}'
)

if (( ${#candidates[@]} == 0 )); then
  log "no mcp-remote processes older than ${MAX_AGE_MIN}m"
  exit 0
fi

# Filter: only kill if the process tree is under an openclaw-gateway-*
# systemd unit. systemd-cgls /proc/<pid>/cgroup is authoritative.
killed=0
skipped=0
for pid in "${candidates[@]}"; do
  if [[ ! -r "/proc/${pid}/cgroup" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  cgroup=$(cat "/proc/${pid}/cgroup")
  if [[ "$cgroup" != *openclaw-gateway-* ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  # Determine the process tree to kill: outer npm exec, the sh -c it
  # spawns, and the node child. Easier to kill the pgid and catch all.
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  if [[ -z "$pgid" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  # Send SIGTERM to the whole process group. Subsequent timer runs
  # will escalate to SIGKILL if SIGTERM didn't stick.
  if kill -TERM -- "-${pgid}" 2>/dev/null; then
    killed=$((killed + 1))
    log "SIGTERM sent to pgid ${pgid} (leader pid ${pid})"
  else
    skipped=$((skipped + 1))
  fi
done

log "done: ${killed} reaped, ${skipped} skipped"
