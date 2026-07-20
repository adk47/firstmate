#!/usr/bin/env python3
"""Fail-loud guard against silently deleting a live-created cron on deploy.

Every main deploy reconciles the SQLite cron store to cron-jobs.json via
openclaw's saveCronStore ("delete-by-store_key + re-insert"), so ANY cron
present in the live store but absent from cron-jobs.json is wiped. The existing
orphan guard in deploy.sh cannot catch these: it inspects the stale
cron/jobs.json file, which the 7.x runtime never writes to, so a cron created
directly on the gateway (`openclaw cron add`) is invisible to it and silently
lost (incident 2026-07-16: Aaron's ChartMogul MRR/SaaS crons, PR #702).

This helper reads the REAL store (a loadCronStore dump) and reports any DURABLE
(recurring, non-ephemeral) cron the repo does not declare, so the deploy can
halt BEFORE the destructive import. The operator then commits the cron to
cron-jobs.json (as we did in #702) or sets HYDRA_ALLOW_ORPHAN_CRON=1 to drop it.

Usage:
  detect-store-only-crons.py <repo-cron-jobs.json> <store-dump.json>

  store-dump.json is openclaw loadCronStore output: a {"jobs": [...]} object
  (a bare list is also accepted for robustness).

Exit codes:
  0  no durable store-only orphans, OR HYDRA_ALLOW_ORPHAN_CRON=1 (drop allowed)
  2  bad args / unreadable or malformed input
  3  durable store-only orphan(s) found — the deploy should halt
"""
import json
import os
import sys


def load_jobs(path):
    with open(path) as handle:
        data = json.load(handle)
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        jobs = data.get("jobs")
        if isinstance(jobs, list):
            return jobs
        # A dict without a `jobs` array is not an empty cron set — it is a
        # store/repo dump whose shape we do not recognize (loadCronStore
        # always emits {"jobs": [...]}). Returning [] here would fail OPEN:
        # the live store would look empty, no orphans would be detected, and
        # saveCronStore would go on to DELETE every durable store-only cron —
        # the exact wipe this guard exists to prevent. Fail closed so main()
        # exits 2 (per the "malformed input" contract) and halts the deploy.
        raise ValueError(
            f"{path}: object has no 'jobs' array "
            f"(got jobs={type(jobs).__name__}); refusing to treat as empty"
        )
    raise ValueError(
        f"{path}: expected a JSON list or an object with a 'jobs' array, "
        f"got {type(data).__name__}"
    )


def is_ephemeral(job):
    """Agent one-shots (deleteAfterRun + a one-time `at` schedule) self-delete
    after firing and are never committed to the repo — the QA auto-review and
    cto-alert-triage jobs, etc. Not protected orphan state. Mirrors the
    live_ephemeral rule in scripts/deploy.sh so both guards agree."""
    schedule = job.get("schedule") or {}
    return job.get("deleteAfterRun") is True and schedule.get("kind") == "at"


def describe(job):
    schedule = job.get("schedule") or {}
    sched = schedule.get("expr") or schedule.get("everyMs") or schedule.get("kind") or "?"
    return f"{job.get('id')} ({job.get('name') or '<unnamed>'}; schedule={sched})"


def main(argv):
    if len(argv) != 3:
        print(
            "usage: detect-store-only-crons.py <repo-cron-jobs.json> <store-dump.json>",
            file=sys.stderr,
        )
        return 2
    repo_path, store_path = argv[1], argv[2]
    try:
        repo_jobs = load_jobs(repo_path)
        store_jobs = load_jobs(store_path)
    except (OSError, ValueError) as exc:
        print(f"detect-store-only-crons: cannot read input: {exc}", file=sys.stderr)
        return 2

    repo_ids = {job.get("id") for job in repo_jobs if job.get("id")}
    orphans = [
        job
        for job in store_jobs
        if job.get("id") and job["id"] not in repo_ids and not is_ephemeral(job)
    ]

    if not orphans:
        return 0

    listing = ", ".join(describe(job) for job in orphans)

    if os.environ.get("HYDRA_ALLOW_ORPHAN_CRON") == "1":
        print(
            f"  HYDRA_ALLOW_ORPHAN_CRON=1: dropping {len(orphans)} live-created cron(s) "
            f"present in the SQLite store but absent from cron-jobs.json: {listing}",
            file=sys.stderr,
        )
        return 0

    print(
        f"refusing to drop {len(orphans)} live-created cron(s) present in the SQLite cron "
        f"store but absent from cron-jobs.json: {listing}. These were created directly on "
        f"the gateway (e.g. `openclaw cron add`) and the deploy's saveCronStore import would "
        f"DELETE them. Commit them to cron-jobs.json (see the ChartMogul restore, PR #702), "
        f"or set HYDRA_ALLOW_ORPHAN_CRON=1 to intentionally drop them.",
        file=sys.stderr,
    )
    return 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
