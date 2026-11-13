#!/usr/bin/env python3
"""Say what is holding a hydra PR, and the cheapest correct way to clear it.

  pr-doctor.py preflight --body FILE [--base origin/main]
      Before `gh pr create`: does this branch trip the credit-approval guard, and does the body
      already satisfy it? Getting the body right at open means no body edit after the push.

  pr-doctor.py plan [PR ...] [--all] [--apply]
      Per PR: what GitHub and the merge queue are waiting on and the one command that clears it.
      Read-only unless --apply, which performs ONLY re-runs of failed jobs on the PR's current head.
      A head is called clear only when every check the merge queue reads (`gh pr checks`) is a pass
      or a skip, every job of the head's own suite is too, and QA passed it: a running Bats shard
      is a wait, not clear. The suite's jobs are read from its run, not from `gh pr checks`: after
      a title/body edit that listing shows the edit run's SKIPPED placeholder under each job's name
      and hides the suite's own job, running or failed (seen on hydra#1935, 2026-11-13T08:05Z).

It never fabricates a pass. A re-run makes a job read the head again and report what is true now;
it changes no code, no base and no PR text. Retargets, rebases and body edits are printed for the
PR's owner and never performed here.

Why re-runs are enough (and an empty commit never is the cheapest path):
  * `validate` red on a validated head: a metadata-edit run failed before the suite finished and,
    being the NEWER workflow run, outranks the suite's green. Re-running that one job takes seconds.
  * the suite was cancelled or timed out: it never gave a verdict. Re-running its failed jobs gets
    one in place; an empty commit restarts every job and invalidates the QA verdict on the old head.
  * the suite FAILED: never re-run blind (--apply does not). A re-run reads the SAME merge commit as
    the original run, so it clears a flake and nothing else. `gh pr close N && gh pr reopen N`
    validates the head against today's main with no commit, which is what clears a failure that came
    from main's state that day (the 2026-11-09 exec-posture expiry reddened three heads that way).
  * `credit-approval-guard` red with a body that passes today: the run predates the body edit or
    the 2026-11-08 guard change (#1849). Re-run it.
  * `credit-approval-guard` CANCELLED on one of its two events: a review and a body edit landed
    together and one run cancelled the other. It never gave a verdict, stays listed, and the merge
    queue holds on it. Re-run it.
  * `validate` green but GitHub still "expects" it: a metadata edit before 2026-11-11 skipped the
    whole run and posted nothing. A new title/body edit starts a run that mirrors the head's suite.
  * GitHub refuses to re-run a run older than 30 days. Then, and only then: a body edit re-triggers
    the guard, and `gh pr close N && gh pr reopen N` starts a fresh validation without a commit.

Stdlib only. The guard's own functions are imported from .github/credit-approval/guard.py, so the
rules live in one place.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, ".github", "credit-approval", "guard.py")
REPO = "Muso-AI/hydra"
RERUN_WINDOW = timedelta(days=30)  # GitHub: a run can be re-run for 30 days after it first ran
ACTIONS_APP = "github-actions"
QA_CHECK = "qa-review"
PLANNED = ("validate", "validate-code", "credit-approval-guard")  # planned by name, not by queue_steps

AFTER_HINT = (
    "The AFTER figure does not have to wait for a deploy: run the new code read-only against the same "
    "production data (queue off, --dry-run, shadow) and give that figure, saying it is a dry run. "
    "'After: not measured' is refused."
)


def load_guard():
    spec = importlib.util.spec_from_file_location("credit_approval_guard", GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def gh(*args: str) -> str:
    r = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"gh api {' '.join(args)[:100]}: {r.stderr.strip()[:300]}")
    return r.stdout


def ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def run_id(check: dict) -> int:
    m = re.search(r"/actions/runs/(\d+)/", check.get("details_url") or "")
    return int(m.group(1)) if m else 0


def newest(checks: list[dict], name: str, real_only: bool = False) -> dict | None:
    """The check run GitHub grades for `name`: newest workflow run, then newest attempt."""
    mine = [
        c
        for c in checks
        if c.get("name") == name
        and (c.get("app") or {}).get("slug") == ACTIONS_APP
        and not (real_only and c.get("conclusion") == "skipped")
    ]
    return max(mine, key=lambda c: (run_id(c), c.get("id") or 0)) if mine else None


def rerun_step(check: dict, why: str, now: datetime, too_old: str) -> dict:
    run = run_id(check)
    if now - ts(check["started_at"]) > RERUN_WINDOW:
        return {"kind": "manual", "why": f"{why}; run {run} is older than 30 days and GitHub will not re-run it", "do": too_old}
    return {"kind": "rerun", "why": why, "run": run, "do": f"gh run rerun {run} --failed --repo {REPO}"}


def suite_step(suite: dict, now: datetime, reopen: str) -> dict:
    """A suite that did not succeed. Interrupted: re-run it. Failed: a person reads it first."""
    run, how = run_id(suite), suite.get("conclusion")
    if how == "failure":
        return {
            "kind": "manual",
            "why": f"the suite FAILED (run {run}). A re-run reads the same merge commit as that run, so it clears a "
                   "flake and nothing else; a failure that survives a validation against today's main is real",
            "do": f"gh run view {run} --log-failed --repo {REPO}   # read the failing step, then either fix it or:\n"
                  f"      {reopen}",
        }
    return rerun_step(
        suite,
        f"the suite was '{how}' (run {run}) and never gave a verdict: re-run its failed jobs in place, no commit",
        now, reopen,
    )


def plan_pr(pr: dict, checks: list[dict], body_problems: list[str], now: datetime, validation_runs: list[int] = (),
            guard_runs: list[dict] = (), queue: list[dict] | None = None, suite_jobs: list[dict] = (),
            running_runs: list[int] = ()) -> list[dict]:
    """Ordered steps for one PR. Only `kind == "rerun"` is ever applied, and only the first one.

    `validation_runs` = ids of every PR Validation workflow run on the head; `running_runs` = those
    of them that have not completed. `queue` = the head as
    the merge queue reads it (`parse_queue`); None plans `validate` and the guard only, and the
    caller must not then call the head clear."""
    n = pr["number"]
    steps: list[dict] = []
    if pr["base"] != "main":
        steps.append({
            "kind": "manual",
            "why": f"base is `{pr['base']}`, not main: PR Validation only runs for main, so this PR can never go green",
            "do": f"gh pr edit {n} --base main --repo {REPO}   # starts a validation; do it once the base PR has merged or been dropped",
        })
        return steps
    if pr["mergeable"] is None:
        # Unmeasured is not "mergeable": a re-run on a head that turns out to conflict helps nothing.
        steps.append({"kind": "unknown", "why": "GitHub has not said whether this head conflicts with main", "do": "ask again in a minute"})
        return steps
    if pr["mergeable"] is False:
        steps.append({
            "kind": "manual",
            "why": "conflicts with main: GitHub starts no pull_request run for a conflicting head, so no re-run helps",
            "do": "rebase the branch on origin/main and push (one push, one validation)",
        })
        return steps

    val = newest(checks, "validate")
    suite = newest(checks, "validate-code", real_only=True)
    reopen = f"gh pr close {n} --repo {REPO} && gh pr reopen {n} --repo {REPO}   # fresh validation, no commit"
    if val is None:
        # `validate` needs `validate-code`, so it is not even listed until the suite ends: a head
        # whose validation is running has no `validate` yet. Reopening it would restart the suite.
        if suite is not None and suite.get("status") == "completed" and run_id(suite) not in running_runs:
            steps.append(suite_step(suite, now, reopen))  # its run is over and `validate` never came
        elif suite is not None:
            state = suite.get("status") if suite.get("status") != "completed" else "finished"
            steps.append({"kind": "wait", "why": f"the suite (run {run_id(suite)}) is {state} and has not posted `validate` yet",
                          "do": "nothing; `validate` is posted when the suite ends"})
        elif running_runs:
            steps.append({"kind": "wait", "why": f"PR Validation run {max(running_runs)} is running and has posted no check yet",
                          "do": "nothing; it is starting"})
        else:
            steps.append({"kind": "manual", "why": "no `validate` on this head: no validation ever ran for it", "do": reopen})
    elif val.get("status") != "completed":
        steps.append({"kind": "wait", "why": f"`validate` of run {run_id(val)} is {val.get('status')}", "do": "nothing; it is running"})
    elif val.get("conclusion") != "success":
        if suite is None:
            placeholder = any(c.get("name") == "validate-code" and run_id(c) == run_id(val) for c in checks)
            if placeholder:
                steps.append({"kind": "manual", "why": "`validate` is red and no suite has run on this head (only a metadata-edit run)", "do": reopen})
            else:
                # A head validated before the validate / validate-code split: `validate` IS the suite.
                steps.append(suite_step(val, now, reopen))
        elif suite.get("status") != "completed":
            steps.append({"kind": "wait", "why": f"the suite (run {run_id(suite)}) is {suite.get('status')}",
                          "do": f"when it finishes: gh run rerun {run_id(val)} --failed --repo {REPO}"})
        elif suite.get("conclusion") == "success":
            steps.append(rerun_step(
                val,
                f"`validate` is red only because metadata-edit run {run_id(val)} outranks the suite's green "
                f"(run {run_id(suite)}); the head IS validated",
                now, reopen,
            ))
        else:
            steps.append(suite_step(suite, now, reopen))
            if run_id(val) != run_id(suite):
                steps.append({"kind": "then", "why": "after that suite is green, the newer metadata-edit run still shows its old failure",
                              "do": f"gh run rerun {run_id(val)} --failed --repo {REPO}"})

    elif suite is not None and suite.get("status") != "completed":
        # A re-run of the suite keeps its run id: the old attempt's green `validate` is still listed
        # and the new attempt has not posted one. The queue holds on the running job.
        steps.append({"kind": "wait", "why": f"`validate` is green (run {run_id(val)}) but the suite is running again "
                                             f"(run {run_id(suite)}, {suite.get('status')}) and will post its own",
                      "do": "nothing; it is running"})
    else:
        newest_run = max(validation_runs, default=0)
        unposted = newest_run > run_id(val) and not any(c.get("name") == "validate" and run_id(c) == newest_run for c in checks)
        if unposted and newest_run in running_runs:
            # A reopen or a retarget: a new validation of this head. Its `validate` is not listed until its suite ends.
            steps.append({"kind": "wait", "why": f"`validate` is green (run {run_id(val)}) but the newer PR Validation run "
                                                 f"{newest_run} is still running and will post its own",
                          "do": "nothing; GitHub grades the newer run's `validate` once it is posted"})
        elif unposted:
            steps.append({
                "kind": "manual",
                "why": f"`validate` is green (run {run_id(val)}) but the newer PR Validation run {newest_run} posted none: a "
                       "metadata edit before 2026-11-11 skipped the whole run, so GitHub still shows the required check as expected",
                "do": "edit the PR title or body (any real change): the run that starts mirrors this head's own suite in "
                      "seconds. Re-running the skipped run repeats the old workflow and changes nothing",
            })

    steps += guard_steps(checks, guard_runs, body_problems, now)
    if queue is not None:
        steps += queue_steps(pr, queue, now, suite_jobs)
        left = not_green(queue, suite_jobs)
        if not steps and left:
            # Clear is a positive reading, never the absence of a rule that fired. Three times a
            # head the queue was holding fell through every rule above and read as clear.
            steps.append({"kind": "unknown",
                          "why": "not green in the merge queue's own view, and no rule here says why: " + ", ".join(left),
                          "do": f"gh pr checks {n} --repo {REPO}   # read it; this head is not clear"})
    return steps


def not_green(queue: list[dict], suite_jobs: list[dict] = ()) -> list[str]:
    """Every name the merge queue would hold this head for, read the way it reads: a row that is
    not a pass or a skip, a job of the suite that an edit's skip hides and that did not pass, and
    `qa-review` unless it is listed and passing. Empty = clear. It knows no cause and needs none."""
    names = {c["name"] for c in queue if c["bucket"] not in ("pass", "skipping")}
    names |= {j["name"] for j in hidden_jobs(queue, suite_jobs)
              if j.get("status") != "completed" or j.get("conclusion") not in ("success", "skipped", "neutral")}
    if not any(c["name"] == QA_CHECK and c["bucket"] == "pass" for c in queue):
        names.add(QA_CHECK)
    return sorted(names)


def suite_run(checks: list[dict]) -> int:
    """The run of the head's newest real suite: a `validate-code` that ran, else (a head validated
    before the 2026-11-11 split) a `validate` from a run with no `validate-code` in it. 0 = none."""
    suite = newest(checks, "validate-code", real_only=True)
    if suite is None:
        split = {run_id(c) for c in checks if c.get("name") == "validate-code"}
        old = [c for c in checks if c.get("name") == "validate" and run_id(c) not in split]
        suite = newest(old, "validate", real_only=True)
    return run_id(suite) if suite else 0


def hidden_jobs(queue: list[dict], suite_jobs: list[dict]) -> list[dict]:
    """The suite's jobs that `gh pr checks` does not list. `suite_jobs` = the jobs of the suite's
    run (`name`, `status`, `conclusion`, `started_at`, `html_url`).

    `gh pr checks` keeps one row per check name, the one that started last. A title/body edit made
    after a push starts a run whose jobs are all skipped, so its placeholders replace the suite's
    own jobs in that listing, and the merge queue, which reads it, takes a skip for green."""
    listed = {(c["name"], run_id({"details_url": c.get("link") or ""})) for c in queue}
    out = []
    for j in suite_jobs:
        as_check = {"details_url": j.get("html_url") or "", "started_at": j.get("started_at") or ""}
        if j["name"] in PLANNED or (j["name"], run_id(as_check)) in listed:
            continue
        out.append({**j, **as_check})
    return out


def queue_steps(pr: dict, queue: list[dict], now: datetime, suite_jobs: list[dict] = ()) -> list[dict]:
    """Everything else the merge queue holds a head for. `queue` = the head's checks as
    `gh pr checks` lists them (`name`, `bucket`, `link`, `startedAt`), which is what the queue reads.

    The queue (firstmate `bin/fm-merge-queue.sh`) keeps a row while ANY check is not a pass or a
    skip, required or not, and until `qa-review` is on the head and passing. What is wrong with
    `validate` and the guard is planned above; that they are still running is held here too.
    Without this a head with Bats still running read as clear."""
    n = pr["number"]
    steps: list[dict] = []
    rest = [c for c in queue if c["name"] not in PLANNED and c["name"] != QA_CHECK]
    hidden = hidden_jobs(queue, suite_jobs)
    # `validate`, `validate-code` and the guard are planned from their check runs, above. Their red
    # is; a PENDING row of theirs is counted here as well, so no reading of the check runs that
    # misses a running one (another event, a re-run, a run GitHub has not listed yet) reads as clear.
    pending = sorted({c["name"] for c in queue if c["name"] != QA_CHECK and c["bucket"] == "pending"}
                     | {j["name"] for j in hidden if j.get("status") != "completed"})
    if pending:
        shown = ", ".join(pending[:4]) + (f" and {len(pending) - 4} more" if len(pending) > 4 else "")
        steps.append({"kind": "wait", "why": f"{len(pending)} check(s) still running: {shown}",
                      "do": "wait: the merge queue holds on a running check, required or not"})
    seen: set[int] = set()
    for c in rest:
        if c["bucket"] in ("pass", "skipping", "pending"):
            continue
        as_check = {"details_url": c.get("link") or "", "started_at": c.get("startedAt") or ""}
        run = run_id(as_check)
        if c["name"] == "pr-title":
            steps.append({"kind": "manual", "why": "`pr-title` is red: the title does not pass the title check (a required check)",
                          "do": f"gh pr edit {n} --repo {REPO} --title '<type>: <subject>'   # the edit re-runs it"})
        elif run in seen:
            continue
        elif c["bucket"] == "cancel" and run and as_check["started_at"]:
            steps.append(rerun_step(
                as_check, f"`{c['name']}` (run {run}) was cancelled and never gave a verdict; the merge queue holds on it",
                now, f"gh pr close {n} --repo {REPO} && gh pr reopen {n} --repo {REPO}",
            ))
        else:
            where = f"run {run}" if run else (c.get("link") or "no link")
            steps.append({
                "kind": "manual",
                "why": f"`{c['name']}` is {c['bucket']} ({where}): not a required check, but the merge queue holds on it",
                "do": (f"gh run view {run} --log-failed --repo {REPO}   # read the failing step; a re-run clears a flake and nothing else"
                       if run else "open the link and read it"),
            })
        seen.add(run)
    for j in hidden:
        run = run_id(j)
        if j.get("status") != "completed" or j.get("conclusion") in ("success", "skipped", "neutral") or run in seen:
            continue
        unseen = "the merge queue does not see it: a later title/body edit's skipped placeholder has taken its name"
        if j.get("conclusion") == "cancelled" and run and j["started_at"]:
            steps.append(rerun_step(
                j, f"`{j['name']}` of the suite (run {run}) was cancelled and never gave a verdict; {unseen}",
                now, f"gh pr close {n} --repo {REPO} && gh pr reopen {n} --repo {REPO}",
            ))
        else:
            steps.append({
                "kind": "manual",
                "why": f"`{j['name']}` of the suite (run {run}) concluded '{j.get('conclusion')}'; {unseen}",
                "do": f"gh run view {run} --log-failed --repo {REPO}   # read the failing step; a re-run clears a flake and nothing else",
            })
        seen.add(run)

    qa = [c["bucket"] for c in queue if c["name"] == QA_CHECK]
    if any(b == "fail" for b in qa):
        steps.append({"kind": "manual", "why": "QA reviewed this head and said NO-GO",
                      "do": "read the review on the PR. A finding is fixed by a push; a missing tier by a `tier:N` label, which "
                            "re-reviews by itself"})
    elif any(b == "pending" for b in qa):
        steps.append({"kind": "wait", "why": "QA is reviewing this head", "do": "wait for the verdict"})
    elif not any(b == "pass" for b in qa):
        if pending:
            steps.append({"kind": "wait", "why": "no QA verdict on this head yet: the review is dispatched when PR Validation completes",
                          "do": "wait"})
        else:
            steps.append({
                "kind": "manual",
                "why": "no QA verdict on this head and nothing is running: the review was never dispatched or was lost",
                "do": f"gh workflow run qa-autoreview.yml --repo {REPO} -f pr={n} -f sha={pr['sha']}   # re-fires the review, no CI re-run",
            })
    return steps


def guard_steps(checks: list[dict], guard_runs: list[dict], body_problems: list[str], now: datetime) -> list[dict]:
    """What `credit-approval-guard` is holding. `guard_runs` = its workflow runs on the head (`id`, `event`).

    The guard runs on two events (`pull_request_target`, `pull_request_review`) that share one
    concurrency group, so a review landing in the same second as a body edit CANCELS the edit's
    run. The merge queue reads `gh pr checks`, which keeps one check per event: the one that
    STARTED last. The cancelled one stays listed beside the other event's green and the queue
    holds on it for good. So this reads the guard the same way: per event, newest start. With no
    run list every check counts as one event."""
    edit = "edit the PR body (any edit re-triggers the guard)"
    event_of = {r["id"]: r["event"] for r in guard_runs}
    latest: dict[str, dict] = {}
    for c in checks:
        if c.get("name") != "credit-approval-guard" or (c.get("app") or {}).get("slug") != ACTIONS_APP:
            continue
        event = event_of.get(run_id(c), "")
        key = (c.get("started_at") or "", run_id(c), c.get("id") or 0)
        if event not in latest or key > latest[event][0]:
            latest[event] = (key, dict(c, event=event))
    verdicts = [latest[event][1] for event in sorted(latest)]

    steps: list[dict] = []
    for v in verdicts:
        if v.get("status") != "completed":
            steps.append({"kind": "wait", "why": f"credit-approval-guard's newest {v['event'] or 'run'} run (run {run_id(v)}) "
                                                 f"is {v.get('status')}: no verdict yet, and the merge queue holds on it",
                          "do": "nothing; it is running"})
    failed = [v for v in verdicts if v.get("conclusion") == "failure"]
    if failed and body_problems:
        steps.append({"kind": "manual", "why": "credit-approval-guard: the PR body does not meet it: " + " | ".join(body_problems),
                      "do": f"fix the '## Credit approval impact' section (one edit). {AFTER_HINT}"})
        return steps  # that edit starts a new run on every event; a re-run before it reads the same body
    for v in failed:
        steps.append(rerun_step(
            v,
            "credit-approval-guard is red but the body passes its section check today (the red predates the body "
            "edit or the 2026-11-08 guard change)",
            now, edit,
        ))
    for v in verdicts:
        if v.get("conclusion") == "cancelled":
            steps.append(rerun_step(
                v,
                f"credit-approval-guard's newest {v['event'] or 'run'} run (run {run_id(v)}) was cancelled and never gave "
                "a verdict; it stays listed beside the other event's result and the merge queue holds on it",
                now, edit,
            ))
    return steps


def parse_queue(stdout: str, stderr: str) -> list[dict]:
    """Rows of `gh pr checks --json`. The output decides, never the exit status: gh exits 8 on a
    running check and 1 on a failed one. No rows at all is an answer only when gh says so."""
    if stdout.strip():
        try:
            rows = json.loads(stdout)
        except ValueError:
            rows = None
        if isinstance(rows, list) and all(isinstance(r, dict) and "name" in r and "bucket" in r for r in rows):
            return rows
    elif "no checks reported" in stderr:
        return []
    raise RuntimeError(f"gh pr checks gave no usable answer: {(stderr or stdout).strip()[:300]}")


def read_queue(number: int) -> list[dict]:
    r = subprocess.run(["gh", "pr", "checks", str(number), "--repo", REPO, "--json", "name,bucket,link,startedAt"],
                       capture_output=True, text=True)
    return parse_queue(r.stdout, r.stderr)


def fetch_pr(number: int) -> tuple[dict, list[dict], list[int], list[dict], list[dict], list[int]]:
    raw = json.loads(gh(f"repos/{REPO}/pulls/{number}"))
    for _ in range(3):  # `mergeable` is null while GitHub computes it; the first read starts that
        if raw.get("mergeable") is not None or raw["state"] != "open":
            break
        time.sleep(2)
        raw = json.loads(gh(f"repos/{REPO}/pulls/{number}"))
    pr = {
        "number": number,
        "state": raw["state"],
        "base": raw["base"]["ref"],
        "sha": raw["head"]["sha"],
        "mergeable": raw.get("mergeable"),
        "body": raw.get("body"),
    }
    checks: list[dict] = []
    for name in ("validate", "validate-code", "credit-approval-guard"):
        out = gh("--paginate", f"repos/{REPO}/commits/{pr['sha']}/check-runs?check_name={name}&filter=all&per_page=100",
                 "--jq", ".check_runs[] | {id, name, status, conclusion, started_at, details_url, app: {slug: .app.slug}}")
        checks += [json.loads(line) for line in out.splitlines() if line.strip()]
    out = gh("--paginate", f"repos/{REPO}/actions/runs?head_sha={pr['sha']}&per_page=100",
             "--jq", ".workflow_runs[] | {id, name, event, status}")
    runs = [json.loads(line) for line in out.splitlines() if line.strip()]
    of_suite = [r for r in runs if r["name"] == "PR Validation" and r["event"] == "pull_request"]
    validation = [r["id"] for r in of_suite]
    running = [r["id"] for r in of_suite if r.get("status") != "completed"]
    jobs: list[dict] = []
    if suite_run(checks):
        out = gh("--paginate", f"repos/{REPO}/actions/runs/{suite_run(checks)}/jobs?filter=latest&per_page=100",
                 "--jq", ".jobs[] | {name, status, conclusion, started_at, html_url}")
        jobs = [json.loads(line) for line in out.splitlines() if line.strip()]
    return pr, checks, validation, [r for r in runs if r["name"] == "credit-approval-guard"], jobs, running


def cmd_plan(args: argparse.Namespace) -> int:
    guard = load_guard()
    numbers = list(args.pr)
    if args.all:
        out = gh("--paginate", f"repos/{REPO}/pulls?state=open&per_page=100", "--jq", ".[].number")
        numbers = sorted({int(x) for x in out.split()} | set(numbers))
    if not numbers:
        print("give PR numbers or --all", file=sys.stderr)
        return 2
    now = datetime.now(timezone.utc)
    tally: dict[str, int] = {}
    for n in numbers:
        pr, checks, validation_runs, guard_runs, suite_jobs, running_runs = fetch_pr(n)
        if pr["state"] != "open":
            print(f"#{n}: {pr['state']}, nothing to do")
            continue
        steps = plan_pr(pr, checks, guard.section_problems(pr["body"]), now, validation_runs, guard_runs, read_queue(n),
                        suite_jobs, running_runs)
        if not steps:
            tally["clear"] = tally.get("clear", 0) + 1
            if not args.all:
                print(f"#{n}: nothing is holding this head ({pr['sha'][:9]}): every check the merge queue reads and every job "
                      "of the head's suite is green, and QA passed it")
            continue
        print(f"#{n} head {pr['sha'][:9]}")
        applied = False
        for s in steps:
            tally[s["kind"]] = tally.get(s["kind"], 0) + 1
            print(f"  [{s['kind']}] {s['why']}\n      {s['do']}")
            if args.apply and s["kind"] == "rerun" and not applied:
                gh("-X", "POST", f"repos/{REPO}/actions/runs/{s['run']}/rerun-failed-jobs")
                applied = True
                print(f"      APPLIED: re-running the failed jobs of run {s['run']}")
    print("\n" + ", ".join(f"{k}: {v}" for k, v in sorted(tally.items())))
    if not args.apply and tally.get("rerun"):
        print("re-runs above were NOT performed; add --apply to perform them (re-runs only, nothing else)")
    return 0


def cmd_preflight(args: argparse.Namespace) -> int:
    guard = load_guard()

    def git(*a: str) -> str:
        return subprocess.run(["git", "-C", ROOT, *a], check=True, capture_output=True, text=True).stdout

    base = git("merge-base", args.base, "HEAD").strip()
    files = [f for f in git("diff", "--no-renames", "--name-only", f"{base}...HEAD").splitlines() if f]
    texts = [guard.codeowners_at(sha) for sha in (args.base, "HEAD")]
    patterns = sorted({p for t in texts for p in guard.parse_block(t)})
    rules = sorted({r for t in texts for r in guard.parse_content_rules(t)})
    hits = guard.matching_files(files, patterns)
    hits += guard.content_hits(
        [f for f in files if f not in hits], rules,
        lambda path: git("diff", "--no-renames", "-U0", f"{base}...HEAD", "--", path),
    )
    if not hits:
        print(f"credit-approval-guard will not fire ({len(files)} changed files, none on a credit-approval path).")
        return 0
    print(f"credit-approval-guard WILL fire on {len(hits)} file(s): " + ", ".join(hits[:6]) + (" ..." if len(hits) > 6 else ""))
    with open(args.body, encoding="utf-8") as fh:
        problems = guard.section_problems(fh.read())
    if not problems:
        print("body passes the guard's section check. Open the PR with this body and do not edit it after the push.")
        return 0
    for p in problems:
        print(f"  PROBLEM: {p}")
    print(f"  {AFTER_HINT}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    pre = sub.add_parser("preflight")
    pre.add_argument("--body", required=True)
    pre.add_argument("--base", default="origin/main")
    plan = sub.add_parser("plan")
    plan.add_argument("pr", nargs="*", type=int)
    plan.add_argument("--all", action="store_true")
    plan.add_argument("--apply", action="store_true", help="perform the re-runs (re-runs only)")
    args = ap.parse_args()
    return cmd_preflight(args) if args.cmd == "preflight" else cmd_plan(args)


if __name__ == "__main__":
    sys.exit(main())
