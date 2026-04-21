#!/usr/bin/env bash
# lockfile.sh — acquire/release lockfile for credit verification batch runs.
#
# Usage:
#   lockfile.sh acquire [<caller_pid>]
#       exit 0 on success, 10 if held by live PID, 2 on env error.
#       caller_pid: optional. If provided, written to the lockfile so future
#       acquirers can `kill -0` against the *actual long-running batch process*,
#       not this short-lived helper script (which exits the moment acquire
#       returns). Defaults to $$ (the helper's own PID) for backwards compat,
#       but the SKILL.md Batch Mode B0b should pass `$$` from its caller scope:
#           bash "$SKILL_DIR/scripts/lockfile.sh" acquire $$
#   lockfile.sh release
#       removes lockfile; exit 0 even if absent.
#
# Env:
#   OPS_BATCH_LOCK_PATH   required — absolute path to lockfile
#   OPS_WORKSPACE         optional — "operations-dev" or "operations" (default: unknown)

set -euo pipefail

STALE_SECONDS=$((3*3600 + 30*60))  # 3h30m — sits inside the 4h cron cadence so a SIGKILL-stuck lock is self-stolen by the next tick

require_env() {
  if [[ -z "${OPS_BATCH_LOCK_PATH:-}" ]]; then
    echo "ERROR: OPS_BATCH_LOCK_PATH is not set" >&2
    exit 2
  fi
}

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

is_stale_by_mtime() {
  local file="$1"
  local now mtime age
  now=$(date +%s)
  # macOS and Linux have different stat flags
  mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  age=$((now - mtime))
  [[ "$age" -ge "$STALE_SECONDS" ]]
}

cmd_acquire() {
  require_env
  # Caller PID: defaults to this helper's PID ($$). The helper exits as soon as
  # acquire returns, so $$ becomes a dead PID immediately — meaning the next
  # acquirer would always treat the lock as dead and rely entirely on the
  # mtime fallback for liveness. Pass the caller's $$ as $1 to fix this.
  local pid_to_record="${1:-$$}"
  if ! [[ "$pid_to_record" =~ ^[0-9]+$ ]]; then
    echo "ERROR: caller_pid must be numeric, got '$pid_to_record'" >&2
    exit 2
  fi

  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"

  if [[ -f "$OPS_BATCH_LOCK_PATH" ]]; then
    local existing_pid
    existing_pid=$(cut -d: -f1 "$OPS_BATCH_LOCK_PATH" 2>/dev/null || echo "")
    if [[ -z "$existing_pid" ]]; then
      # Malformed lockfile (no PID parseable) — log and steal.
      echo "WARN: malformed lockfile contents at $OPS_BATCH_LOCK_PATH; stealing" >&2
    elif is_pid_alive "$existing_pid"; then
      if is_stale_by_mtime "$OPS_BATCH_LOCK_PATH"; then
        # Live PID but stale mtime — likely a different process reusing the PID.
        # (The held batch process never bumps mtime during a run, so any run
        # legitimately exceeding 3h30m would be self-stolen. The batch never
        # exceeds ~30min in practice, and the 4h cron cadence would re-collide
        # on the tick after anyway.)
        # Safe to steal.
        :
      else
        # Live lock, recent — honor it.
        exit 10
      fi
    fi
    # Dead PID or stale mtime → steal.
  fi

  local workspace="${OPS_WORKSPACE:-unknown}"
  local hostname
  hostname=$(hostname)
  echo "${pid_to_record}:${hostname}:${workspace}" > "$OPS_BATCH_LOCK_PATH"
}

cmd_release() {
  require_env
  rm -f "$OPS_BATCH_LOCK_PATH"
}

case "${1:-}" in
  acquire) shift; cmd_acquire "$@" ;;
  release) cmd_release ;;
  *) echo "usage: $0 {acquire [<caller_pid>]|release}" >&2; exit 64 ;;
esac
