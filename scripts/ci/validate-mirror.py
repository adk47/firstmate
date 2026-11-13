#!/usr/bin/env python3
"""What the required `validate` check reports for a run that did not validate (a title/body edit).

Used by the `validate` job of .github/workflows/pr-validate.yml, only when its own run's
`validate-code` was skipped. It answers with what the head's REAL suite concluded.

Why it waits. GitHub grades a required check by the NEWEST WORKFLOW RUN that posted it, not by the
newest check run. A body edit starts a newer run than the push it follows, so that run's `validate`
decides the head. Until 2026-11-13 this job read the head once: an edit made while the push's suite
was still running found nothing to mirror, failed, and left a validated head unmergeable until
someone re-ran that failed job by hand (6 of the last 50 merged PRs, 9.0 h unmergeable in total;
data/pr-pipeline-unblock-f1/report.md). A suite that is still running is not a failed suite, so
this waits for it and then mirrors it.

What it never does: report success for a head whose newest real suite did not succeed. No suite on
the head, a suite that failed or was cancelled, a suite still running at the deadline, and a GitHub
read that keeps failing all exit 1.

A head pushed before 2026-11-11 (#1851) was validated by a job named `validate` itself; there is no
`validate-code` on it. For such a head the suite is the newest `validate` of a run that has no
`validate-code` at all. A `validate` from a run that has one is a mirror like this job and is never
read as a suite, so a mirror cannot vouch for a mirror.

A newer run that has not posted its suite yet is waited for too. A retarget onto main, or a close
and reopen, starts a NEW validation of the same head sha. Its `validate-code` job is listed a few
seconds after the run is; an edit landing in that gap used to find only the OLD green suite, and
this job's green `validate`, being the newest run's, then outranked whatever the new validation
went on to conclude (QA review of hydra#1935). So the runs of this workflow on the head are read as
well: one that is newer than the suite, is not this run, and has posted neither a suite nor a
skipped placeholder is not finished speaking. A cancelled or skipped run that posted nothing is
ignored: it changed nothing about the head, and without the edit GitHub would still be grading the
suite before it.

Not covered, on purpose: a RE-RUN of a suite that already succeeded. A re-run keeps its run id and
reads the same merge commit, so it validates nothing the first attempt did not.

Exit 0 = the head's newest real suite succeeded. Exit 1 = anything else. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CODE_CHECK = "validate-code"
LEGACY_CHECK = "validate"  # the suite's own name before the 2026-11-11 split
# Only a job of this repo's own workflows counts. A check run named `validate-code` posted by any
# other app is not a validation.
ACTIONS_APP = "github-actions"
# The runs that can validate a head are this workflow's, started by a pull_request event.
WORKFLOW_PATH = ".github/workflows/pr-validate.yml"
# A completed run that posted no suite and still leaves the head as it was.
SILENT_CONCLUSIONS = ("cancelled", "skipped")
# `validate-code` is capped at 20 minutes (its `timeout-minutes`); 25 leaves room for its queue.
WAIT_SECONDS = 1500
# A push's run exists before its first job does. How long to wait for the head's first suite to
# appear before saying the head has none.
APPEAR_SECONDS = 180
POLL_SECONDS = 15


class ReadError(Exception):
    """GitHub did not give a usable answer. Never a verdict."""


def fetch_head(repo: str, sha: str, token: str, api: str = "https://api.github.com") -> tuple[list[dict], list[dict]]:
    """(check runs, workflow runs) of the head.

    The checks are read FIRST: a run that starts between the two reads is then listed with no check
    and is waited for. In the other order it would be missing from both.
    """
    return fetch_check_runs(repo, sha, token, api), fetch_runs(repo, sha, token, api)


def fetch_check_runs(repo: str, sha: str, token: str, api: str = "https://api.github.com") -> list[dict]:
    """Every `validate-code` and `validate` check run on the head, all attempts of all runs."""
    return _fetch(repo, sha, token, api, CODE_CHECK) + _fetch(repo, sha, token, api, LEGACY_CHECK)


def _fetch(repo: str, sha: str, token: str, api: str, name: str) -> list[dict]:
    return _pages(f"{api}/repos/{repo}/commits/{sha}/check-runs?check_name={name}&filter=all", token, "check_runs")


def fetch_runs(repo: str, sha: str, token: str, api: str = "https://api.github.com") -> list[dict]:
    """Every run of this workflow on the head (needs `actions: read`)."""
    runs = _pages(f"{api}/repos/{repo}/actions/runs?head_sha={sha}&event=pull_request", token, "workflow_runs")
    return [r for r in runs if r.get("path") == WORKFLOW_PATH]


def _pages(url: str, token: str, key: str) -> list[dict]:
    out: list[dict] = []
    page = 1
    while True:
        req = urllib.request.Request(
            f"{url}&per_page=100&page={page}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.load(resp)
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise ReadError(f"{key} read failed: {exc}") from exc
        rows = body.get(key) if isinstance(body, dict) else None
        if not isinstance(rows, list):
            raise ReadError(f"{key} read returned no `{key}` list")
        out += rows
        if len(rows) < 100:
            return out
        page += 1


def run_id(check: dict) -> int:
    """The workflow run a check run belongs to (run ids are monotonic: newer run, larger id)."""
    m = re.search(r"/actions/runs/(\d+)/", check.get("details_url") or "")
    return int(m.group(1)) if m else 0


def newest_real_suite(checks: list[dict]) -> dict | None:
    """The head's newest suite that actually ran or is going to.

    A skipped one is a metadata edit's placeholder, not a suite. Newest workflow run first (the
    order GitHub itself grades in), then the newest attempt of that run. A `validate-code` always
    outranks a pre-split `validate`: the legacy name is read only on a head with no real
    `validate-code` at all.
    """
    ours = [c for c in checks if (c.get("app") or {}).get("slug") == ACTIONS_APP and c.get("conclusion") != "skipped"]
    real = [c for c in ours if c.get("name") == CODE_CHECK]
    if not real:
        # Runs that carry a `validate-code` of ANY conclusion are post-split: their `validate` is a mirror.
        split_runs = {run_id(c) for c in checks if c.get("name") == CODE_CHECK}
        real = [c for c in ours if c.get("name") == LEGACY_CHECK and run_id(c) and run_id(c) not in split_runs]
    return max(real, key=lambda c: (run_id(c), c.get("id") or 0)) if real else None


def unposted_runs(checks: list[dict], runs: list[dict], after: int, own: int) -> list[dict]:
    """Runs newer than run `after`, other than this one, that have posted no suite and no placeholder.

    Newest first. A run that has posted a `validate-code` (skipped included) or a `validate` has
    said what it is, and `newest_real_suite` has already read it.
    """
    posted = {
        run_id(c)
        for c in checks
        if c.get("name") in (CODE_CHECK, LEGACY_CHECK) and (c.get("app") or {}).get("slug") == ACTIONS_APP
    }
    late = [r for r in runs if (r.get("id") or 0) > after and r.get("id") != own and r.get("id") not in posted]
    return sorted(late, key=lambda r: r.get("id") or 0, reverse=True)


def decide(checks: list[dict], runs: list[dict] = (), own: int = 0) -> tuple[str, str]:
    """(`pass` | `fail` | `wait` | `none`, why) for one read of the head.

    `none` covers a head with no suite and a head whose newest suite was cancelled: a reopen or a
    retarget cancels the running suite a moment before its replacement posts a job, so a cancelled
    suite gets the same short wait for a successor as an absent one, and fails after it.

    `runs` are this workflow's runs on the head and `own` is this run's id. A newer run that has
    not posted its suite yet outranks every suite already on the head: its verdict is the one
    GitHub will grade, so it is waited for and an older green is never reported in its place.
    """
    suite = newest_real_suite(checks)
    for late in unposted_runs(checks, runs, run_id(suite) if suite else 0, own):
        if late.get("status") != "completed":
            return "wait", f"run {late.get('id')} of this workflow is {late.get('status')} and has not posted its suite"
        if late.get("conclusion") not in SILENT_CONCLUSIONS:
            return "none", f"run {late.get('id')} of this workflow concluded '{late.get('conclusion')}' without a suite"
    if suite is None:
        return "none", "no suite has run on this head"
    where = f"{suite.get('name')} of run {run_id(suite)}"
    if suite.get("status") != "completed":
        return "wait", f"{where} is {suite.get('status')}"
    if suite.get("conclusion") == "success":
        return "pass", f"{where} succeeded"
    if suite.get("conclusion") == "cancelled":
        return "none", f"{where} was cancelled and nothing has replaced it"
    return "fail", f"{where} concluded '{suite.get('conclusion')}'"


def mirror(
    read, *, wait: float, appear: float, poll: float, own: int = 0, clock=time.monotonic, sleep=time.sleep, log=print
) -> int:
    """Poll `read()` until the head's newest real suite has a verdict, then return it as an exit code.

    `read()` returns (check runs, workflow runs) of the head; `own` is this run's id.
    """
    start = clock()
    last = ""
    while True:
        elapsed = clock() - start
        try:
            checks, runs = read()
            state, why = decide(checks, runs, own)
        except ReadError as exc:
            state, why = "unread", str(exc)
        if why != last:
            log(f"[{int(elapsed)}s] {why}")
            last = why
        if state == "pass":
            log("::notice::metadata edit — the head's suite succeeded, not re-running it")
            return 0
        if state == "fail":
            log(f"::error::metadata edit — {why}. A metadata edit cannot stand in for a validation.")
            return 1
        limit = appear if state == "none" else wait
        if elapsed >= limit:
            if state == "none":
                log(
                    f"::error::metadata edit — {why} after {int(elapsed)}s. Re-run that suite's failed jobs, "
                    "or close and reopen the PR, to start one. A metadata edit cannot stand in for a validation."
                )
            else:
                log(
                    f"::error::metadata edit — no verdict after {int(elapsed)}s ({why}). Re-run this job once "
                    "the suite has finished: it will report what the suite concluded."
                )
            return 1
        sleep(poll)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=os.environ.get("REPO"))
    ap.add_argument("--sha", default=os.environ.get("SHA"))
    ap.add_argument("--run-id", type=int, default=int(os.environ.get("GITHUB_RUN_ID") or 0))
    ap.add_argument("--wait-seconds", type=float, default=WAIT_SECONDS)
    ap.add_argument("--appear-seconds", type=float, default=APPEAR_SECONDS)
    ap.add_argument("--poll-seconds", type=float, default=POLL_SECONDS)
    args = ap.parse_args()
    token = os.environ.get("GH_TOKEN", "")
    if not args.repo or not args.sha or not token:
        print("::error::validate-mirror needs --repo, --sha and GH_TOKEN")
        return 1
    return mirror(
        lambda: fetch_head(args.repo, args.sha, token),
        wait=args.wait_seconds,
        appear=args.appear_seconds,
        poll=args.poll_seconds,
        own=args.run_id,
        # Flushed: a wait is minutes long, and a buffered log shows nothing until it ends.
        log=lambda line: print(line, flush=True),
    )


if __name__ == "__main__":
    sys.exit(main())
