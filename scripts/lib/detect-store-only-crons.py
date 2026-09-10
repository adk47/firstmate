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
(recurring, non-ephemeral, not runtime-declared) cron the repo does not declare,
so the deploy can halt BEFORE the destructive import. The operator then commits the cron to
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


# What openclaw itself declares, read off the 2026.8.2 runtime on node-8
# (/usr/lib/node_modules/openclaw/dist) and cross-checked against every live
# declared row in BOTH profiles (14/14 match, 2026-09-10):
#
#   namespace                              runtime payload invariant
#   heartbeat:<agent>                      payload.kind == "heartbeat"
#   heartbeat-task:<...>                   (system-owned; see below)
#   skill-collection-review:<agent>        payload.kind == "skillCollectionReview"
#   memory-core:memory-dreaming-promotion  agentTurn + the internal sentinel message
#
# WHY THE PAYLOAD, NOT JUST THE KEY (QA finding, PR #924): the runtime refuses a
# user `cron add` only for SYSTEM_OWNED_DECLARATION_PREFIXES — heartbeat-task:
# and skill-collection-review:. `heartbeat:` is NOT on that list, so an operator
# can create an ordinary durable cron keyed `heartbeat:billing`; on the key
# alone all four guards would exempt it and the replace-all import would delete
# it. The payload IS the non-forgeable half: `openclaw cron add` can only build
# command/message/script/system-event/webhook payloads — there is no flag that
# produces payload.kind "heartbeat" or "skillCollectionReview", and the runtime
# constructs those in exactly one place each.
#
# heartbeat-task: needs no payload check: the runtime refuses it from any
# non-system caller, so the namespace itself is unforgeable through the CLI.
#
# Keep in step with runtime_declared in scripts/lib/cron-store.sh and the two JS
# copies (cron_store_reimport, deploy.sh) — see the note in cron-store.sh.
MEMORY_DREAM_MESSAGE = "__openclaw_memory_core_short_term_promotion_dream__"


def is_runtime_declared(job):
    """True only for a cron openclaw DECLARES from config at boot.

    Those rows regenerate their ids every boot, so they can never be committed
    to cron-jobs.json — counting them made this guard refuse every deploy on
    2026-09-10 ("loaded 44, repo declares 33"; 11 unexpected, 0 missing).

    Matches on the namespace AND the runtime's payload invariant, so an
    operator-forged `heartbeat:billing` stays protected. Fails closed on
    everything else — blank, whitespace, non-string, custom, a near-miss on the
    exact key, or a real namespace carrying a user payload. A namespace added by
    a future runtime therefore halts the deploy loudly instead of being silently
    dropped; add it here when that happens."""
    key = job.get("declarationKey")
    if not isinstance(key, str):
        return False
    payload = job.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    kind = payload.get("kind")
    if key.startswith("heartbeat:"):
        return kind == "heartbeat"
    if key.startswith("heartbeat-task:"):
        return True
    if key.startswith("skill-collection-review:"):
        return kind == "skillCollectionReview"
    if key == "memory-core:memory-dreaming-promotion":
        return kind == "agentTurn" and payload.get("message") == MEMORY_DREAM_MESSAGE
    return False


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
    store_only = [
        job for job in store_jobs if job.get("id") and job["id"] not in repo_ids
    ]
    # Report what was skipped rather than dropping it silently: a behaviour
    # change nobody can see is how the next incident hides.
    declared_by_runtime = [j for j in store_only if is_runtime_declared(j)]
    if declared_by_runtime:
        print(
            f"  ignoring {len(declared_by_runtime)} runtime-declared cron(s) "
            f"(openclaw declares these from config at boot; ids regenerate, so they "
            f"are not committable): "
            + ", ".join(sorted(j.get("declarationKey", "?") for j in declared_by_runtime)),
            file=sys.stderr,
        )
    orphans = [
        job
        for job in store_only
        if not is_ephemeral(job) and not is_runtime_declared(job)
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
