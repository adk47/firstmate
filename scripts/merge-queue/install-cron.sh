#!/usr/bin/env bash
# The ONE writer of the profile-merge queue's cron files on node-8:
#   /etc/cron.d/merge-queue-census         */30   read-only census, refreshes plan.json
#   /etc/cron.d/merge-queue-variant-queue  10:17  the approved reply pass (sends)
#
# Why this file exists at all: both schedules were hand-installed on 2026-10-27/11-03 and
# lived only in /etc/cron.d, so nothing in review could see them. On 2026-11-05 a hand edit
# added `> plan.daily.json && cp plan.daily.json plan.json` to the variant line; plan.py
# writes plan.json itself, so every downstream step read a 267-byte summary as if it were
# the ~457 KB plan (firstmate inbox 087, fixed live the same day). A schedule nobody can
# review is a schedule nobody can catch.
#
# install-aux-units.sh calls this instead of carrying heredocs, so the cron files have a
# single author and the tests can EXECUTE the installer against a temp CRON_DIR and assert
# the installed result (firstmate ruling 2026-11-04: run the installer into a temp root,
# assert the installed files, never grep source text).
#
#   CRON_DIR    where the cron.d files go   (default /etc/cron.d)
#   CHAIN_DIR   the deployed chain copies   (default /root/q1)
#   HYDRA_ROOT  the deployed repo           (default /opt/hydra)
#
# Both lines run a versioned script in HYDRA_ROOT, never an inline `bash -c`, so the
# commands in cron.d stay one path each and the logic is testable.
#
# Kill switches (a human's pause, no deploy needed):
#   /etc/hydra/merge-queue-variant.disabled   stops every customer send
#   /etc/hydra/merge-queue-census.disabled    stops the plan refresh
#
# The chain code itself is core-backend's (scripts/ops/merge-queue/); CHAIN_DIR must match
# scripts/merge-queue/chain-manifest.sha256 or both scripts refuse to run.
set -euo pipefail

CRON_DIR="${CRON_DIR:-/etc/cron.d}"
CHAIN_DIR="${CHAIN_DIR:-/root/q1}"
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] install-merge-queue-cron: $*"; }

[ -d "$CRON_DIR" ] || { log "FATAL cron dir missing: $CRON_DIR"; exit 1; }

cat > "$CRON_DIR/merge-queue-census" << CRONCENSUS
# MANAGED BY scripts/install-aux-units.sh - DO NOT EDIT BY HAND.
# Read-only census of the profile-merge queue (core-backend scripts/ops/merge-queue/README.md).
# Refreshes clickup.json and plan.json; messages nobody. Kill: /etc/hydra/merge-queue-census.disabled
SHELL=/bin/bash
*/30 * * * * root $HYDRA_ROOT/scripts/merge-queue/run-census.sh >> $CHAIN_DIR/census-cron.log 2>&1
CRONCENSUS
chmod 644 "$CRON_DIR/merge-queue-census"

cat > "$CRON_DIR/merge-queue-variant-queue" << CRONVARIANT
# MANAGED BY scripts/install-aux-units.sh - DO NOT EDIT BY HAND.
# Customer replies for the profile-merge queue: one pass a day at 10:17Z, refreshing the plan
# from the live queue and sending the APPROVED copy (q1-copy-1103, Fable 2026-11-03) to whoever
# the one-message-per-user-per-day cap held back. The sender is fail-closed and idempotent:
# never the same ticket twice, never a human-assigned thread, never a drifted chain, and
# anything it cannot reach is tagged q1-variant-skipped for #cs_priority.
# Pause without a deploy: touch /etc/hydra/merge-queue-variant.disabled
SHELL=/bin/bash
17 10 * * * root $HYDRA_ROOT/scripts/merge-queue/run-variant-queue.sh >> $CHAIN_DIR/variant-cron.log 2>&1
CRONVARIANT
chmod 644 "$CRON_DIR/merge-queue-variant-queue"

log "installed $CRON_DIR/merge-queue-census and $CRON_DIR/merge-queue-variant-queue (chain $CHAIN_DIR, root $HYDRA_ROOT)"
