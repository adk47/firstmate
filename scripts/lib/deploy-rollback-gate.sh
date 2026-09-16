#!/usr/bin/env bash
set -euo pipefail

# deploy-rollback-gate.sh: decide whether the workflow's "Rollback on
# failure" step should actually run scripts/rollback.sh. Extracted out of
# .github/workflows/deploy.yml so the decision logic is unit-testable (see
# scripts/tests/deploy-rollback-gate.bats).
#
# Usage: deploy-rollback-gate.sh <deploy-path> <run-token>
#   Reads a single marker file: <deploy-path>/.deploy-mutating, whose content
#   is the OWNER token written by the deploy that started mutating. The
#   caller passes its own token (the workflow passes gha-<run_id>-<attempt>,
#   the same value it exported to deploy.sh as HYDRA_DEPLOY_RUN_ID). Only a
#   marker owned by THIS run yields rollback=true: a marker owned by another
#   deploy means that deploy is mid-flight (or died) and rolling back under
#   it would rsync and restart production underneath live work.
#
# Prints exactly one line to stdout: `rollback=true` or `rollback=false`.
# Human-readable reasoning goes to stderr. Always exits 0; the caller reads
# the printed decision, this script never fails the job itself. Exits 2 only
# on a missing or empty argument (either of the two).
#
# ── The incident class this prevents ────────────────────────────────────
# deploy.sh Step 0 (drift check) and Step 4a (pre-flight) are READ-ONLY and
# halt with exit 1 BEFORE any rsync when the server has agent-edited files.
# On a daily schedule (rather than one deploy per merge) that halt is
# common. The workflow's "Rollback on failure" step used to run
# scripts/rollback.sh on ANY failure(), including these read-only halts, and
# rollback.sh rsyncs the last-known-good tree over /opt/hydra and restarts
# both gateways. That would restart production for a failure that never
# touched node-8.
#
# The marker `.deploy-mutating` is the signal that a rollback has anything
# to undo:
#   - deploy.sh writes it immediately after Step 4a passes (before Step 4b's
#     rsync, i.e. before the first byte moves) and removes it immediately
#     after the `.deployed-sha` baseline write is verified.
#   - rollback.sh also removes it after a successful rollback (so a
#     rollback itself doesn't look like an unfinished mutation to the next
#     run).
# Its presence means a deploy started mutating node-8 and never reached a
# clean end state (baseline write or rollback), exactly when a rollback is
# warranted. Its absence means the run halted before touching node-8 (or a
# previous deploy/rollback already completed cleanly).
# ─────────────────────────────────────────────────────────────────────────

if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: $0 <deploy-path> <run-token>" >&2
  exit 2
fi
DEPLOY_PATH="$1"
RUN_TOKEN="$2"
MARKER="$DEPLOY_PATH/.deploy-mutating"
if [ ! -f "$MARKER" ]; then
  echo "no $MARKER; this run halted before mutating node-8 (or a previous run already cleaned up); nothing to roll back" >&2
  echo "rollback=false"
  exit 0
fi
# A marker we cannot READ is an unknown owner, and an unknown owner is a
# rollback=false decision, never a crash: this script runs inside the
# workflow's unattended failure handler, and a non-zero exit here would
# abort that step before it pages. head's own status is captured
# explicitly (a plain assignment would turn a read error into exit 1 under
# set -e).
read_rc=0
OWNER="$(head -n 1 "$MARKER" 2>/dev/null | tr -d '[:space:]')" || read_rc=$?
if [ "$read_rc" -ne 0 ]; then
  echo "found $MARKER but could not read it (rc=$read_rc): owner unknown; refusing to roll back on a guess. Inspect the marker by hand." >&2
  echo "rollback=false"
  exit 0
fi
if [ "$OWNER" = "$RUN_TOKEN" ]; then
  echo "found $MARKER owned by this run ($RUN_TOKEN): the deploy started mutating node-8 and never reached a clean end state; rollback warranted" >&2
  echo "rollback=true"
else
  echo "found $MARKER but it is owned by '${OWNER:-<empty>}', not this run ($RUN_TOKEN): another deploy is mid-flight or died; refusing to roll back underneath it" >&2
  echo "rollback=false"
fi
