#!/usr/bin/env bash
# gateway_restart_needed — decide whether a deploy must restart a gateway.
#
# Filename note: this file stays edge-restart-gate.sh (the gate began as
# edge-only). It now governs BOTH gateways via gateway_restart_needed(); the
# file is deliberately NOT renamed because renaming a deployed script trips the
# deploy-preflight rsync --delete gate (CI blocks any /opt/hydra deletion).
#
# Applies to BOTH gateways (main + edge): a restart is pure churn when a deploy
# provably changed nothing the gateway process loads. Every restart costs ~12-30s
# of agent unavailability (agents rebind after `systemctl restart`); on edge it
# ALSO pauses the memory_search vector index and forces a full re-embed
# (openclaw-edge-reindex-on-start.sh heals it, but the re-embed still runs) — so
# the edge case is the strongest motivation, but the main gateway churn is real
# too. This gate lets deploy.sh SKIP the restart when the changed-file set proves
# it's safe.
#
# Strictly FAIL-OPEN: returns 0 (restart) unless the changed-file set is KNOWN
# and EVERY changed path is provably gateway-inert. A mis-skip would leave the
# gateway stale, so the inert allowlist is deliberately tight (directory-level,
# things NEITHER gateway process ever reads): CI, docs, Claude personas, bats
# tests, systemd reference templates, and the repo-root doc files. Everything
# else — including general scripts/*, which can carry the openclaw version pin
# (deploy.sh) or unit definitions (install-aux-units.sh) — restarts. Widen the
# allowlist only once observed safe.
#
# Inputs (globals set by scripts/deploy.sh):
#   DEPLOY_DIFF_COMPUTED   1 iff Step 0 computed a valid baseline diff
#   DEPLOY_CHANGED_FILES   newline-separated changed paths since last deploy
#   HYDRA_FORCE            1 => forced deploy (always restart)
#   HYDRA_FORCE_RESTART    1 => explicit "restart anyway" escape hatch
#
# Returns 0 = restart, 1 = safe to skip. Sourced by scripts/deploy.sh and
# scripts/tests/edge-restart-gate.bats.

gateway_restart_needed() {
  [ "${HYDRA_FORCE:-0}" = "1" ] && return 0             # forced deploy -> restart
  [ "${HYDRA_FORCE_RESTART:-0}" = "1" ] && return 0     # explicit escape hatch
  [ "${DEPLOY_DIFF_COMPUTED:-0}" = "1" ] || return 0    # diff unknown -> restart
  [ -n "${DEPLOY_CHANGED_FILES:-}" ] || return 0        # no/empty diff -> restart
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      # Inert = the gateway process never reads it. Root docs are enumerated by
      # exact name (no slash) on purpose: a bare *.md glob would also match
      # skills-all/**/SKILL.md and wrongly skip a restart on a real skill change.
      .github/*|docs/*|.claude/*|scripts/tests/*|scripts/aux-units/*|README.md|CLAUDE.md|AGENTS.md) ;;  # inert
      *) return 0 ;;   # anything else could affect a gateway -> restart
    esac
  done <<< "${DEPLOY_CHANGED_FILES:-}"
  return 1             # every changed file was gateway-inert -> safe to skip
}
