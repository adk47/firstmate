#!/usr/bin/env python3
"""Re-run, in place, the check that is holding an open PR for no reason of its code.

A head can be validated and still unmergeable: the required `validate` of a title/body-edit run
failed before the suite finished and now outranks the suite's green; a suite was cancelled or
timed out and never gave a verdict; `credit-approval-guard` is red on a body that has since been
fixed. Each is cleared by re-running the failed jobs of ONE workflow run. Until this script a
person had to notice and do it (`scripts/pr-doctor.py plan N --apply`), so a validated head sat
until someone looked, or got an empty commit that also threw away its QA verdict.

This is the unattended caller of that same planner. It decides nothing itself:

  * WHAT may be re-run is `pr-doctor.plan_pr`: only its `rerun` steps, and it never offers one for
    a suite that FAILED (a person reads that first). A re-run reports what is true. It cannot
    invent a pass, so the rule that an unvalidated head cannot merge is untouched.
  * At most ONE re-run per PR per pass, and none while the plan says something is still running:
    PR Validation and the guard each cancel an in-progress run of their own concurrency group, so
    two re-runs at once cancel each other.
  * A run is re-run at most `MAX_ATTEMPTS - 1` times. Past that it is reported and left for a
    person: a run that is cancelled or fails the same way every time must not loop.
  * A head that conflicts, a suite that failed, a QA NO-GO: never touched, never reported as fixed.

"Could not read" is exit 3, never a clean pass: a PR nobody could read was not swept.

  pr-rerun-sweep.py --repo O/R --sha SHA [--apply]      the open PRs whose head is SHA
  pr-rerun-sweep.py --repo O/R --pr N [N ...] [--apply]
  pr-rerun-sweep.py --repo O/R --all [--apply]          every open PR on `main` GitHub shows as red

Without --apply nothing is re-run; the plan is printed. Token: GH_TOKEN / GITHUB_TOKEN
(`actions: write` to re-run). Stdlib only: the ARC runner has no `gh`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCTOR = os.path.join(ROOT, "scripts", "pr-doctor.py")

API = "https://api.github.com"
BASE = "main"  # PR Validation only runs for main
VALIDATION_PATH = ".github/workflows/pr-validate.yml"
GUARD_PATH = ".github/workflows/credit-approval-guard.yaml"
PLANNED_CHECKS = ("validate", "validate-code", "credit-approval-guard")

# The original run is attempt 1. Two automatic re-runs, then a person.
MAX_ATTEMPTS = 3
# One pass re-runs at most this many runs: a suite re-run holds a runner for ~20 minutes.
MAX_RERUNS = 25
# What GitHub's own roll-up calls red. PENDING / EXPECTED heads have something running or nothing
# listed, and no re-run of a finished run helps either.
RED_ROLLUPS = ("FAILURE", "ERROR")

EXIT_OK, EXIT_REFUSED, EXIT_USAGE, EXIT_UNREAD = 0, 1, 2, 3


class ReadError(Exception):
    """GitHub did not give a usable answer. Never a verdict."""


def load_doctor():
    spec = importlib.util.spec_from_file_location("pr_doctor", DOCTOR)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class GitHub:
    """The four calls this needs. Every failure to read is a ReadError."""

    def __init__(self, repo: str, token: str, api: str = API, opener=urllib.request.urlopen):
        self.repo, self.token, self.api, self.opener = repo, token, api, opener
        self.calls = 0

    def _send(self, method: str, url: str, payload: dict | None = None):
        self.calls += 1
        req = urllib.request.Request(
            url,
            method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"},
        )
        with self.opener(req, timeout=30) as resp:
            raw = resp.read()
        return json.loads(raw) if raw.strip() else None

    def get(self, path: str):
        try:
            return self._send("GET", f"{self.api}/repos/{self.repo}/{path}")
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise ReadError(f"GET {path.split('?')[0]}: {exc}") from exc

    def pages(self, path: str, key: str | None = None) -> list[dict]:
        out: list[dict] = []
        page = 1
        while True:
            body = self.get(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            rows = body.get(key) if key and isinstance(body, dict) else body
            if not isinstance(rows, list):
                raise ReadError(f"GET {path.split('?')[0]}: no list in the answer")
            out += rows
            if len(rows) < 100:
                return out
            page += 1

    def graphql(self, query: str, variables: dict) -> dict:
        try:
            body = self._send("POST", f"{self.api}/graphql", {"query": query, "variables": variables})
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise ReadError(f"graphql: {exc}") from exc
        if not isinstance(body, dict) or body.get("errors") or not isinstance(body.get("data"), dict):
            raise ReadError(f"graphql: {json.dumps((body or {}).get('errors'))[:300]}")
        return body["data"]

    def rerun_failed(self, run: int) -> None:
        """Raises urllib.error.HTTPError when GitHub refuses (running already, too old, no permission)."""
        self._send("POST", f"{self.api}/repos/{self.repo}/actions/runs/{run}/rerun-failed-jobs")


RED_PRS = """
query($owner: String!, $name: String!, $base: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: 50, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number mergeable commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
    }
  }
}
"""


def red_prs(gh: GitHub) -> tuple[list[int], dict[str, int]]:
    """Open PRs on main that GitHub shows as red and that do not conflict: the only ones a re-run
    could help. One query per 50 PRs, so a sweep of 200 PRs does not cost 200 reads to find 60."""
    owner, name = gh.repo.split("/", 1)
    numbers: list[int] = []
    seen: dict[str, int] = {"open": 0, "conflicting": 0, "not_red": 0}
    cursor = None
    while True:
        data = gh.graphql(RED_PRS, {"owner": owner, "name": name, "base": BASE, "cursor": cursor})
        try:
            conn = data["repository"]["pullRequests"]
            for node in conn["nodes"]:
                seen["open"] += 1
                commits = node["commits"]["nodes"]
                rollup = ((commits[0]["commit"].get("statusCheckRollup") or {}) if commits else {}).get("state")
                if node.get("mergeable") == "CONFLICTING":
                    seen["conflicting"] += 1
                elif rollup not in RED_ROLLUPS:
                    seen["not_red"] += 1
                else:
                    numbers.append(int(node["number"]))
            more, cursor = conn["pageInfo"]["hasNextPage"], conn["pageInfo"]["endCursor"]
        except (KeyError, TypeError, IndexError) as exc:
            raise ReadError(f"graphql: unexpected shape ({exc!r})") from exc
        if not more:
            return sorted(numbers, reverse=True), seen


def prs_of_sha(gh: GitHub, sha: str) -> list[int]:
    """Open PRs on main whose CURRENT head is this commit. A superseded head has nothing to heal."""
    rows = gh.pages(f"commits/{sha}/pulls")
    return sorted(int(p["number"]) for p in rows
                  if p.get("state") == "open" and (p.get("base") or {}).get("ref") == BASE
                  and (p.get("head") or {}).get("sha") == sha)


def read_pr(gh: GitHub, number: int, sleep=time.sleep) -> tuple[dict, list[dict], list[int], list[dict], list[int]]:
    """One head, in the shape `pr-doctor.plan_pr` takes (its `fetch_pr`, without `gh` and without
    the merge queue's listing: this plans `validate` and the guard only, and never says "clear")."""
    raw = gh.get(f"pulls/{number}")
    for _ in range(3):  # `mergeable` is null while GitHub computes it; the first read starts that
        if not isinstance(raw, dict) or raw.get("mergeable") is not None or raw.get("state") != "open":
            break
        sleep(2)
        raw = gh.get(f"pulls/{number}")
    try:
        pr = {"number": number, "state": raw["state"], "base": raw["base"]["ref"], "sha": raw["head"]["sha"],
              "mergeable": raw.get("mergeable"), "body": raw.get("body")}
    except (KeyError, TypeError) as exc:
        raise ReadError(f"pulls/{number}: unexpected shape ({exc!r})") from exc
    if pr["state"] != "open":
        return pr, [], [], [], []
    checks: list[dict] = []
    for name in PLANNED_CHECKS:
        checks += gh.pages(f"commits/{pr['sha']}/check-runs?check_name={name}&filter=all", "check_runs")
    runs = gh.pages(f"actions/runs?head_sha={pr['sha']}", "workflow_runs")
    of_suite = [r for r in runs if r.get("path") == VALIDATION_PATH and r.get("event") == "pull_request"]
    validation = [r["id"] for r in of_suite]
    running = [r["id"] for r in of_suite if r.get("status") != "completed"]
    guard_runs = [{"id": r["id"], "event": r.get("event")} for r in runs if r.get("path") == GUARD_PATH]
    return pr, checks, validation, guard_runs, running


def choose(steps: list[dict]) -> dict | None:
    """The one re-run this pass may perform for a PR, or None.

    None while anything in the plan is still running: both workflows cancel an in-progress run of
    their own concurrency group, so a re-run started beside a running one cancels it (and two
    re-runs at once cancel each other). The run that is running fires this again when it ends."""
    if any(s["kind"] in ("wait", "unknown") for s in steps):
        return None
    return next((s for s in steps if s["kind"] == "rerun"), None)


def sweep_pr(gh: GitHub, doctor, guard, number: int, now: datetime, apply: bool, max_attempts: int = MAX_ATTEMPTS,
             sleep=time.sleep) -> dict:
    """Plan one PR and perform at most one re-run. Returns what happened; raises ReadError."""
    pr, checks, validation, guard_runs, running = read_pr(gh, number, sleep)
    out = {"pr": number, "sha": pr["sha"], "outcome": "nothing", "why": "", "run": 0}
    if pr["state"] != "open":
        out["why"] = f"PR is {pr['state']}"
        return out
    steps = doctor.plan_pr(pr, checks, guard.section_problems(pr["body"]), now, validation, guard_runs, None, (), running)
    step = choose(steps)
    if step is None:
        first = steps[0] if steps else None
        # Not "clear": this reads `validate` and the guard only. It says what it would not touch.
        out["outcome"] = first["kind"] if first else "nothing"
        out["why"] = first["why"] if first else "`validate` and the guard need no re-run on this head"
        return out
    out["run"], out["why"] = step["run"], step["why"]
    run = gh.get(f"actions/runs/{step['run']}")
    attempt, status = (run or {}).get("run_attempt"), (run or {}).get("status")
    if not isinstance(attempt, int):
        raise ReadError(f"actions/runs/{step['run']}: no run_attempt")
    if status != "completed":
        out["outcome"], out["why"] = "wait", f"run {step['run']} is {status} (attempt {attempt}): already re-running"
    elif attempt >= max_attempts:
        out["outcome"] = "gave-up"
        out["why"] = (f"run {step['run']} has had {attempt} attempts and is still not green: left for a person "
                      f"({step['why']})")
    elif not apply:
        out["outcome"] = "would-rerun"
    else:
        try:
            gh.rerun_failed(step["run"])
            out["outcome"] = "rerun"
        except urllib.error.HTTPError as exc:
            # Another pass (or a person) may have re-run it between the read above and this request.
            if (gh.get(f"actions/runs/{step['run']}") or {}).get("status") != "completed":
                out["outcome"], out["why"] = "wait", f"run {step['run']} is already re-running"
            else:
                out["outcome"] = "refused"
                out["why"] = f"GitHub refused to re-run {step['run']}: HTTP {exc.code} ({step['why']})"
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise ReadError(f"re-run of {step['run']}: {exc}") from exc
    return out


def sweep(gh: GitHub, doctor, guard, numbers: list[int], now: datetime, apply: bool, max_reruns: int = MAX_RERUNS,
          max_attempts: int = MAX_ATTEMPTS, log=print, sleep=time.sleep) -> tuple[list[dict], list[str]]:
    results: list[dict] = []
    unread: list[str] = []
    done = 0
    for n in numbers:
        if apply and done >= max_reruns:
            results.append({"pr": n, "sha": "", "outcome": "deferred", "run": 0,
                            "why": f"this pass already re-ran {max_reruns} runs; the next pass takes it"})
            log(f"#{n}: deferred: {results[-1]['why']}")
            continue
        try:
            r = sweep_pr(gh, doctor, guard, n, now, apply, max_attempts, sleep)
        except ReadError as exc:
            unread.append(f"#{n}: {exc}")
            log(f"#{n}: NOT READ: {exc}")
            continue
        results.append(r)
        done += r["outcome"] == "rerun"
        log(f"#{n} head {r['sha'][:9]}: {r['outcome']}" + (f" run {r['run']}" if r["run"] else "") + f": {r['why']}")
    return results, unread


def summarize(results: list[dict], unread: list[str], scope: str, apply: bool) -> str:
    counts: dict[str, int] = {}
    for r in results:
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    lines = [f"### PR re-run sweep ({scope}; {'apply' if apply else 'dry run'})", "",
             ", ".join(f"{k}: {v}" for k, v in sorted(counts.items())) or "no PR in scope",
             f"not read: {len(unread)}", ""]
    for r in results:
        if r["outcome"] in ("rerun", "would-rerun", "gave-up", "refused"):
            lines.append(f"- #{r['pr']} `{r['sha'][:9]}` **{r['outcome']}** run {r['run']}: {r['why']}")
    lines += [f"- NOT READ {u}" for u in unread]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None, gh: GitHub | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True)
    scope = ap.add_mutually_exclusive_group(required=True)
    scope.add_argument("--sha")
    scope.add_argument("--pr", nargs="+", type=int)
    scope.add_argument("--all", action="store_true")
    ap.add_argument("--apply", action="store_true", help="perform the re-runs (re-runs of failed jobs only)")
    ap.add_argument("--max-reruns", type=int, default=MAX_RERUNS)
    ap.add_argument("--max-attempts", type=int, default=MAX_ATTEMPTS)
    ap.add_argument("--json", help="also write the results to this file")
    args = ap.parse_args(argv)

    if gh is None:
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if not token:
            print("::error::no GH_TOKEN / GITHUB_TOKEN", file=sys.stderr)
            return EXIT_USAGE
        gh = GitHub(args.repo, token, os.environ.get("GITHUB_API_URL") or API)
    doctor = load_doctor()
    guard = doctor.load_guard()
    now = datetime.now(timezone.utc)

    seen: dict[str, int] = {}
    try:
        if args.all:
            numbers, seen = red_prs(gh)
            label = f"all: {seen['open']} open on {BASE}, {seen['conflicting']} conflicting, {seen['not_red']} not red, {len(numbers)} read"
        elif args.sha:
            numbers = prs_of_sha(gh, args.sha)
            label = f"head {args.sha[:9]}"
        else:
            numbers, label = list(args.pr), "named PRs"
    except ReadError as exc:
        print(f"::error::could not list the PRs to sweep, so nothing was swept: {exc}")
        return EXIT_UNREAD

    results, unread = sweep(gh, doctor, guard, numbers, now, args.apply, args.max_reruns, args.max_attempts)
    text = summarize(results, unread, label, args.apply)
    print("\n" + text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(text)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"at": now.isoformat(), "scope": label, "apply": args.apply, "seen": seen, "api_calls": gh.calls,
                       "results": results, "unread": unread}, fh, indent=1)
    for r in results:
        if r["outcome"] == "gave-up":
            print(f"::warning::#{r['pr']}: {r['why']}")
        if r["outcome"] == "refused":
            print(f"::error::#{r['pr']}: {r['why']}")
    if unread:
        print(f"::error::{len(unread)} PR(s) could not be read: this was not a clean sweep")
        return EXIT_UNREAD
    return EXIT_REFUSED if any(r["outcome"] == "refused" for r in results) else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
