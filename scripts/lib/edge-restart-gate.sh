#!/usr/bin/env bash
# edge_restart_needed — decide whether a deploy must restart the edge gateway.
#
# openclaw 2026.6.1 pauses the memory_search vector index on every edge gateway
# restart (openclaw-edge-reindex-on-start.sh heals it, but a full re-embed still
# runs), so a NEEDLESS edge restart is pure churn. This gate lets deploy.sh SKIP
# the edge restart when a deploy provably changed nothing the edge gateway loads.
#
# Strictly FAIL-OPEN: returns 0 (restart) unless the changed-file set is KNOWN
# and EVERY changed path is provably gateway-inert. A mis-skip would leave the
# gateway stale, so the inert allowlist is deliberately tight (directory-level,
# things the gateway process never reads): CI, docs, Claude personas, bats
# tests, and systemd reference templates. Everything else — including general
# scripts/*, which can carry the openclaw version pin (deploy.sh) or unit
# definitions (install-aux-units.sh) — restarts. Widen the allowlist only once
# observed safe.
#
# Inputs (globals set by scripts/deploy.sh):
#   DEPLOY_DIFF_COMPUTED   1 iff Step 0 computed a valid baseline diff
#   DEPLOY_CHANGED_FILES   newline-separated changed paths since last deploy
#   HYDRA_FORCE            1 => forced deploy (always restart)
#   HYDRA_FORCE_RESTART    1 => explicit "restart anyway" escape hatch
#
# Returns 0 = restart, 1 = safe to skip. Sourced by scripts/deploy.sh and
# scripts/tests/edge-restart-gate.bats.

edge_restart_needed() {
  [ "${HYDRA_FORCE:-0}" = "1" ] && return 0             # forced deploy -> restart
  [ "${HYDRA_FORCE_RESTART:-0}" = "1" ] && return 0     # explicit escape hatch
  [ "${DEPLOY_DIFF_COMPUTED:-0}" = "1" ] || return 0    # diff unknown -> restart
  [ -n "${DEPLOY_CHANGED_FILES:-}" ] || return 0        # no/empty diff -> restart
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      .github/*|docs/*|.claude/*|scripts/tests/*|scripts/aux-units/*) ;;  # inert
      *) return 0 ;;   # anything else could affect the gateway -> restart
    esac
  done <<< "${DEPLOY_CHANGED_FILES:-}"
  return 1             # every changed file was gateway-inert -> safe to skip
}
