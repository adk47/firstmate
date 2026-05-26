#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# release-cron.sh
#
# systemd-invoked wrapper around scripts/release.sh for the daily
# release cron. Called by hydra-release.service, which is triggered
# by hydra-release.timer (OnCalendar=Mon..Fri *-*-* 08:00 Europe/Rome).
#
# Three responsibilities beyond just calling release.sh:
#
#   1. Run from a real git checkout, NOT /opt/hydra. /opt/hydra is
#      the rsync target and intentionally excludes .git (see
#      RSYNC_EXCLUDES in scripts/deploy.sh) — release.sh would die
#      immediately with "fatal: not a git repository". Use a
#      dedicated checkout at $RELEASE_REPO_DIR, set up by
#      install-aux-units.sh on first deploy. Refuse loudly if the
#      checkout is missing rather than auto-creating from inside the
#      service (cron is a bad place for first-time auth dialogs).
#
#   2. Date-gate (default 2026-05-28T06:00:00Z = Thu 08:00 Europe/Rome
#      CEST). Before the gate, exit 0 with "not yet active" — lets the
#      timer be enabled now without auto-publishing before the first
#      manual cuts have validated the flow. Override via
#      $RELEASE_CRON_ACTIVATION_UTC (also used by the bats tests).
#      Remove the gate in a follow-up PR after the first clean
#      auto-fire — or just let the condition pass forever (it does).
#
#   3. Fetch + hard-reset to origin/main before each invocation. This
#      keeps the dedicated checkout aligned with what's on origin no
#      matter what state it landed in last time (half-applied tag,
#      stale branch ref, manual poke). release.sh's exact-equality
#      preflight depends on this.
#
# Exit codes (propagated to systemd):
#   0  = nothing to do (gate not yet open, or release.sh said
#         "no commits in range — nothing to release" via exit 10)
#   1  = real failure (refuse-to-run, dirty checkout that fetch
#         couldn't fix, gh auth missing, push failed, etc.)
#  10  = release.sh's "no commits" — translated to 0 here, but
#         hydra-release.service ALSO whitelists 10 via
#         SuccessExitStatus= so either path works.
#
# Why a wrapper instead of a date check + git setup inside release.sh:
# the gate AND the dedicated-checkout dance are operational concerns
# specific to the cron path. Operators running release.sh by hand
# should not pay for them. Keep them separable.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# Where the cron operates. NOT /opt/hydra (no .git there).
# install-aux-units.sh initializes this on first deploy.
RELEASE_REPO_DIR="${RELEASE_REPO_DIR:-/var/lib/hydra-release/repo}"

# Default activation: 2026-05-28 06:00 UTC = 2026-05-28 08:00 Europe/Rome (CEST).
# Override via env if you need to shift it (e.g. testing).
ACTIVATION_UTC="${RELEASE_CRON_ACTIVATION_UTC:-2026-05-28T06:00:00Z}"

log() { echo "[release-cron] $*"; }
die() { echo "[release-cron] ERROR: $*" >&2; exit 1; }

# ─── Date gate ─────────────────────────────────────────────────
now_unix=$(date -u +%s)
# ISO-8601 parsing: GNU date (Linux) accepts `-d`, BSD date (macOS)
# doesn't. Python is already a hard dep for release.sh's Slack-payload
# generation, so use it here too — portable and trivially testable.
gate_unix=$(python3 -c "
import sys
from datetime import datetime
try:
    s = '$ACTIVATION_UTC'.replace('Z', '+00:00')
    print(int(datetime.fromisoformat(s).timestamp()))
except Exception as e:
    sys.exit(1)
") || die "could not parse activation timestamp '$ACTIVATION_UTC'"

if (( now_unix < gate_unix )); then
  remaining=$(( gate_unix - now_unix ))
  log "not yet active — gate ${ACTIVATION_UTC} (${remaining}s remaining)"
  log "  current UTC: $(date -u --iso-8601=seconds 2>/dev/null || date -u)"
  exit 0
fi

log "gate cleared (activation: $ACTIVATION_UTC)"

# ─── Refuse if release checkout missing ────────────────────────
# install-aux-units.sh is supposed to set this up on first deploy.
# If it's missing, that's an install bug — fail loud rather than
# auto-cloning from the service (avoids first-time auth surprises
# in cron context).
if [[ ! -d "$RELEASE_REPO_DIR/.git" ]]; then
  die "$RELEASE_REPO_DIR is not a git checkout. Re-run install-aux-units.sh on node-8 as root, or check the clone-init block there."
fi

# ─── Fetch + reset to origin/main ──────────────────────────────
log "syncing $RELEASE_REPO_DIR to origin/main..."
cd "$RELEASE_REPO_DIR"

# `git fetch --tags --prune` updates tag refs (release.sh's
# `git describe --tags --abbrev=0` reads them). --prune removes
# server-deleted tags so we don't keep zombie locals.
git fetch --tags --prune origin main >/dev/null 2>&1 \
  || die "git fetch origin main failed (check gh auth / network)"

# Hard reset to wipe any in-progress state from a previous fire
# that died after staging changes. The checkout is cron-managed —
# nothing should be edited here manually.
git checkout -q main
git reset --hard origin/main >/dev/null 2>&1 \
  || die "git reset --hard origin/main failed"
git clean -fdx >/dev/null 2>&1 || true

log "checkout at $(git rev-parse --short HEAD) ($(git log -1 --pretty='format:%s'))"

# ─── Invoke release.sh ─────────────────────────────────────────
log "invoking release.sh --no-edit"
exec ./scripts/release.sh --no-edit
