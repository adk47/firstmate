#!/usr/bin/env bash
# reindex_verify_retry PROFILE AGENT [HEAL_CMD] -- rebuild the memory_search
# index for one (profile, agent), then VERIFY (re-probe for the pause signature)
# and RETRY once. Profile-generic: serves both edge (heals via `index --force`)
# and main (heals via `status --index`).
#
# Per-profile heal command (HEAL_CMD, 3rd arg; DERIVED from PROFILE when empty):
#   edge/* -> `index --force`  -- the caller (deploy post-flight) must RE-EMBED on
#             shipped-KB changes, not merely un-pause; and a `--force` can "complete"
#             yet immediately re-pause on a small index / just-restarted (busy)
#             gateway (docs/lessons/openclaw-and-codex.md:180-181). Observed live
#             2026-07-01 in the PR #618 verify -- the bare post-flight `--force`
#             re-paused edge/support and left retrieval ungrounded ~8 min until the
#             10-min watchdog. Verify+retry is why we no longer trust a single pass.
#   main   -> `status --index`  -- main's pause is an IDENTITY-METADATA pause that
#             `index --force` "completes" but does NOT clear; `status --index` resets
#             the metadata and actually clears it (operator-confirmed 2026-07-01).
# The derivation MIRRORS caroline-rag-index-watchdog.sh's HEAL_CMD -- keep the two
# in LOCKSTEP.
#
# Returns 0 if the index is GROUNDED afterwards, non-zero if it is STILL paused.
# The verdict is the final pause probe, not the heal command's own rc (a time-boxed
# heal that raced still leaves a paused index -> return 1). Emits progress via the
# caller's log() if one is defined, else echo.
#
# Env:
#   OPENCLAW_BIN          openclaw binary (default openclaw; tests stub it)
#   REINDEX_SETTLE_SECS   settle before the retry (default 5; the race is worst
#                         right after a restart while the gateway warms; 0 in tests)
#
# Sourced by scripts/deploy.sh and scripts/tests/reindex-verify-retry.bats.

_reindex_log() {
  if declare -F log >/dev/null 2>&1; then log "  $1"; else echo "[reindex-verify-retry] $1"; fi
}

# _reindex_heal_cmd PROFILE -> the `memory <...>` heal subcommand for PROFILE.
# LOCKSTEP with caroline-rag-index-watchdog.sh's HEAL_CMD derivation.
_reindex_heal_cmd() {
  if [ "$1" = "main" ]; then echo "status --index"; else echo "index --force"; fi
}

# _reindex_grounded PROFILE AGENT -> 0 ONLY when a SUCCESSFUL status probe shows
# NO pause signature. A failed/timed-out probe (rc!=0) OR a pause signature both
# return non-zero, so a caller never reports success it could not actually verify
# (a timed-out `memory status` must NOT read as "grounded"). Time-boxed like
# _reindex_heal so a hung gateway/CLI can't stall the deploy post-flight; the var
# capture + `printf | grep` avoids the pipefail mask (grep exits 0 on match and
# closes the pipe, openclaw then EPIPEs non-zero, and pipefail would return that).
_reindex_grounded() {
  local out
  out="$(timeout 60 "${OPENCLAW_BIN:-openclaw}" --profile "$1" memory status --agent "$2" --deep 2>&1)" || return 1
  printf '%s\n' "$out" | grep -qiE "paused until memory is rebuilt|Vector search:[[:space:]]*paused|index metadata is missing" && return 1
  return 0
}

# _reindex_heal PROFILE AGENT HEAL_CMD -> rc of a time-boxed heal (124 on timeout).
_reindex_heal() {
  # shellcheck disable=SC2086  # HEAL_CMD ($3) is a script-controlled two-word subcommand
  timeout 300 "${OPENCLAW_BIN:-openclaw}" --profile "$1" memory $3 --agent "$2" >/dev/null 2>&1
}

reindex_verify_retry() {
  local profile="$1" agent="$2" heal_cmd="${3:-}" heal_ok=0
  [ -n "$heal_cmd" ] || heal_cmd="$(_reindex_heal_cmd "$profile")"
  _reindex_log "reindexing memory (profile=$profile agent=$agent, 'memory $heal_cmd')..."
  if _reindex_heal "$profile" "$agent" "$heal_cmd"; then heal_ok=1; else _reindex_log "heal command failed (will retry + verify)."; fi

  # Retry once if the heal didn't succeed OR the index isn't confirmed grounded
  # (still paused, or the status probe itself failed -- both must not pass as success).
  if [ "$heal_ok" -eq 0 ] || ! _reindex_grounded "$profile" "$agent"; then
    _reindex_log "index not confirmed grounded after rebuild -- settling ${REINDEX_SETTLE_SECS:-5}s and retrying once..."
    sleep "${REINDEX_SETTLE_SECS:-5}"
    if _reindex_heal "$profile" "$agent" "$heal_cmd"; then heal_ok=1; else _reindex_log "retry heal command failed."; fi
  fi

  # Success requires BOTH a successful heal (so the shipped KB was actually
  # re-embedded / the identity metadata reset, not just an old healthy index) AND a
  # clean grounded probe.
  if [ "$heal_ok" -eq 1 ] && _reindex_grounded "$profile" "$agent"; then
    _reindex_log "index rebuilt and grounded."
    return 0
  fi
  _reindex_log "index NOT confirmed grounded after rebuild + retry (still paused, or the heal/status probe failed) -- the 10-min watchdog is the backstop."
  return 1
}
