#!/usr/bin/env bash
# reindex_edge_verify_retry PROFILE AGENT -- force-reindex the memory_search
# index, then VERIFY (re-probe for the pause signature) and RETRY once.
#
# The documented remedy for the busy-gateway re-pause race: a `memory index
# --force` can "complete" yet immediately re-pause the vector index on a small
# index / just-restarted (busy) gateway (docs/lessons/openclaw-and-codex.md:
# 180-181). Observed live 2026-07-01 during the PR #618 verify -- the deploy's
# bare post-flight `--force` re-paused the edge/support index and left retrieval
# ungrounded ~8 min until the 10-min watchdog. This keeps the `--force` (the
# caller -- deploy post-flight -- must re-embed on shipped KB content changes,
# not merely un-pause) but no longer trusts a single pass.
#
# Returns 0 if the index is GROUNDED afterwards, non-zero if it is STILL paused.
# The verdict is the final pause probe, not the reindex command's own rc (a
# time-boxed reindex that raced still leaves a paused index -> return 1). Emits
# progress via the caller's log() if one is defined, else echo.
#
# Env:
#   OPENCLAW_BIN          openclaw binary (default openclaw; tests stub it)
#   REINDEX_SETTLE_SECS   settle before the retry (default 5; the race is worst
#                         right after a restart while the gateway warms; 0 in tests)
#
# Sourced by scripts/deploy.sh and scripts/tests/reindex-edge-verify-retry.bats.

_reindex_log() {
  if declare -F log >/dev/null 2>&1; then log "  $1"; else echo "[reindex-edge-verify-retry] $1"; fi
}

# _reindex_grounded PROFILE AGENT -> 0 ONLY when a SUCCESSFUL status probe shows
# NO pause signature. A failed/timed-out probe (rc!=0) OR a pause signature both
# return non-zero, so a caller never reports success it could not actually verify
# (a timed-out `memory status` must NOT read as "grounded"). Time-boxed like
# _reindex_force so a hung gateway/CLI can't stall the deploy post-flight; the var
# capture + `printf | grep` avoids the pipefail mask (grep exits 0 on match and
# closes the pipe, openclaw then EPIPEs non-zero, and pipefail would return that).
_reindex_grounded() {
  local out
  out="$(timeout 60 "${OPENCLAW_BIN:-openclaw}" --profile "$1" memory status --agent "$2" --deep 2>&1)" || return 1
  printf '%s\n' "$out" | grep -qiE "paused until memory is rebuilt|Vector search:[[:space:]]*paused|index metadata is missing" && return 1
  return 0
}

# _reindex_force PROFILE AGENT -> rc of a time-boxed force reindex (124 on timeout).
_reindex_force() {
  timeout 300 "${OPENCLAW_BIN:-openclaw}" --profile "$1" memory index --force --agent "$2" >/dev/null 2>&1
}

reindex_edge_verify_retry() {
  local profile="$1" agent="$2" force_ok=0
  _reindex_log "reindexing memory (profile=$profile agent=$agent)..."
  if _reindex_force "$profile" "$agent"; then force_ok=1; else _reindex_log "reindex command failed (will retry + verify)."; fi

  # Retry once if the reindex didn't succeed OR the index isn't confirmed grounded
  # (still paused, or the status probe itself failed -- both must not pass as success).
  if [ "$force_ok" -eq 0 ] || ! _reindex_grounded "$profile" "$agent"; then
    _reindex_log "index not confirmed grounded after rebuild -- settling ${REINDEX_SETTLE_SECS:-5}s and retrying once..."
    sleep "${REINDEX_SETTLE_SECS:-5}"
    if _reindex_force "$profile" "$agent"; then force_ok=1; else _reindex_log "retry reindex command failed."; fi
  fi

  # Success requires BOTH a successful force reindex (so the shipped KB was
  # actually re-embedded, not just an old healthy index) AND a clean grounded probe.
  if [ "$force_ok" -eq 1 ] && _reindex_grounded "$profile" "$agent"; then
    _reindex_log "index rebuilt and grounded."
    return 0
  fi
  _reindex_log "index NOT confirmed grounded after rebuild + retry (still paused, or the reindex/status probe failed) -- the 10-min watchdog is the backstop."
  return 1
}
