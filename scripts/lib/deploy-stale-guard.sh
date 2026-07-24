#!/usr/bin/env bash
set -euo pipefail

# deploy-stale-guard.sh — decide whether a "Deploy HYDRA" run should proceed,
# given the commit it checked out (CUR) and the current tip of origin/main
# (TIP). Extracted out of .github/workflows/deploy.yml's "Refuse stale
# deploys" step so the decision logic is unit-testable (see
# scripts/tests/deploy-stale-guard.bats).
#
# Usage: deploy-stale-guard.sh <cur-sha> <tip-sha>
#   Must be run inside a git repo that has both shas reachable (the caller
#   is responsible for `git fetch origin main` beforehand — this script only
#   reads history, it does not fetch).
#   Reads the override from env var HYDRA_ALLOW_STALE_DEPLOY.
#
# Prints exactly one line to stdout: `proceed=true` or `proceed=false`.
# Human-readable reasoning goes to stderr. Always exits 0 — the caller reads
# the printed decision, this script never fails the job itself.
#
# ── The bugs this closes ─────────────────────────────────────────────────
# 1. Ancestor case (incident 2026-07-23, run 29992449557): a push-event run
#    for an OLDER main commit (23dd1cd9) was created 3 minutes AFTER a
#    newer commit's run (cf5859fc4) had already deployed — delayed
#    push-event delivery let the older run start after the newer one
#    finished, and it rsynced the stale tree over /opt/hydra
#    (workflow-green, silently wrong content). The workflow's `concurrency`
#    group serializes runs but does not reorder or drop them, so it didn't
#    catch this. Fix: when CUR is an ancestor of TIP, refuse — the run for
#    TIP owns this deploy.
# 2. Diverged case (QA adk47 finding on PR #731, c0cbec91): the first cut
#    of this guard let a DIVERGED sha (not TIP, not an ancestor of TIP —
#    e.g. a force-push, or a delayed run for an abandoned/rewritten
#    lineage) proceed by default with only a warning. That reproduces the
#    exact same failure class the ancestor check was built to prevent: a
#    delayed run for old, no-longer-current history rsyncs an obsolete
#    tree over /opt/hydra. Diverged now defaults CLOSED (proceed=false);
#    HYDRA_ALLOW_STALE_DEPLOY=1 is required to deploy any non-tip SHA,
#    covering both the ancestor case and the diverged case alike — the
#    override exists for deliberate rollback deploys, not as a silent
#    default.
# ─────────────────────────────────────────────────────────────────────────

if [ $# -ne 2 ]; then
  echo "usage: $0 <cur-sha> <tip-sha>" >&2
  exit 1
fi

CUR="$1"
TIP="$2"

PROCEED=""

if [ "$CUR" = "$TIP" ]; then
  PROCEED=true
  echo "ok: $CUR is the current tip of main" >&2
elif git merge-base --is-ancestor "$CUR" "$TIP" 2>/dev/null; then
  PROCEED=false
  echo "superseded by $TIP: $CUR is an ancestor of the current main tip — the run for $TIP owns this deploy" >&2
else
  # DIVERGED: CUR is neither TIP nor an ancestor of TIP (force-push, or a
  # delayed run for a lineage main has since rewritten/abandoned). Default
  # CLOSED per QA finding on PR #731 — proceeding here is exactly the stale-
  # tree-over-/opt/hydra failure this guard exists to prevent.
  PROCEED=false
  echo "refusing to deploy non-tip SHA $CUR; force-push/old-lineage — set HYDRA_ALLOW_STALE_DEPLOY=1 for a deliberate rollback deploy" >&2
fi

# Override evaluated LAST so it wins over any refusal above (ancestor or
# diverged alike) — the escape hatch for deliberate rollback deploys.
if [ "${HYDRA_ALLOW_STALE_DEPLOY:-}" = "1" ]; then
  PROCEED=true
  echo "HYDRA_ALLOW_STALE_DEPLOY=1: overriding staleness guard" >&2
fi

echo "proceed=$PROCEED"
