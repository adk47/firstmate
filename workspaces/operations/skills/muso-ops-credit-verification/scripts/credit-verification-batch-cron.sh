#!/usr/bin/env bash
# credit-verification-batch-cron.sh — deterministic entrypoint for the
# 4-hourly `credit-verification-batch-4h` cron.
#
# WHY THIS FILE EXISTS (2026-09-17, hydra#961 follow-up)
# ------------------------------------------------------
# The cron calls the Lobster dispatcher directly, so that the dispatcher's exit
# code IS the run status (an isolated agent turn reports the MODEL finishing,
# which is how six days of zero-work runs read `ok`; see dispatch-cv-batch.sh's
# zero-work guard). But the cron argv cannot call the dispatcher with the
# positional arguments it needs:
#
#   * the runtime's cron persistence validator rejects a `command` payload
#     whose argv contains ANY empty string —
#     `getInvalidPersistedCronJobReason()`: `payload.kind === "command"` is
#     invalid when `argv.some(a => typeof a !== "string" || a.length === 0)`;
#   * the dispatcher takes the Slack thread ts as positional arg 2, so reaching
#     apply_mode / selector_kind means passing "" for it.
#
# argv `[... , "500", "", "real", "queue", ""]` therefore made the whole
# cron-jobs.json unpersistable: the deploy aborted at Step 5a with
# "Cannot persist cron store with 1 invalid job(s)" and rolled back. Passing
# the batch size alone is the fix, because every later parameter already has a
# safe default in the dispatcher (Missing → "real" for apply_mode, "queue" for
# selector_kind, "" for the thread ts), and this file makes that explicit
# instead of relying on a reader noticing which positionals were omitted.
#
# Exit code is the cron run status and is the dispatcher's, unchanged:
#   0  ok / no_work / no_eligible / dry_run
#   6  silent_noop / all_failed / unaccounted   (a run that did NOT do its job)
#   2/3/4/5  argument / gateway-auth / pipeline / lock failures
#
# Usage: credit-verification-batch-cron.sh [<batch_size>]   (default 500)
# Env:   CV_BATCH_SIZE   batch size override (1..500, clamped by the dispatcher)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATCH_SIZE="${1:-${CV_BATCH_SIZE:-500}}"

exec bash "$HERE/lobster-mvp/dispatch-cv-batch.sh" "$BATCH_SIZE"
