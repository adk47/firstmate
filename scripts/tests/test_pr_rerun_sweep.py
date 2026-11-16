#!/usr/bin/env python3
"""Tests for scripts/ci/pr-rerun-sweep.py and .github/workflows/pr-rerun-sweep.yml.

What must hold, in this order:
  1. the only thing it can do to GitHub is re-run the failed jobs of a run. It never re-runs a
     suite that FAILED, a conflicting head, or anything while a run of the head is in progress;
  2. it cannot loop: a run past its attempt cap is left alone, and one pass re-runs one run per PR;
  3. "could not read" is never a clean pass.
The workflow wiring is pinned too: a sweep nobody triggers, or one that holds more than
`actions: write`, is not the thing reviewed here. Stdlib only.
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import unittest
import urllib.error
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "pr-rerun-sweep.py")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "pr-rerun-sweep.yml")
VALIDATE = os.path.join(ROOT, ".github", "workflows", "pr-validate.yml")
TITLE_CHECK = os.path.join(ROOT, ".github", "workflows", "pr-title-check.yml")

_spec = importlib.util.spec_from_file_location("pr_rerun_sweep", SCRIPT)
sw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sw)
doctor = sw.load_doctor()

NOW = datetime(2026, 11, 13, 12, 0, tzinfo=timezone.utc)
SHA = "b2b03fc0a0000000000000000000000000000000"
SUITE_RUN, EDIT_RUN = 43387660492, 43388110812  # hydra#1936: the edit run is the newer one
GUARD_EDIT, GUARD_REVIEW = 43309380001, 43309383982  # hydra#1915: the review run kept the old red


class Guard:
    """The guard's section check, answered: the body passes unless the test says otherwise."""

    def __init__(self, problems=()):
        self.problems = list(problems)

    def section_problems(self, body):
        return list(self.problems)


def check(name, run, cid, conclusion="success", status="completed", started=NOW - timedelta(hours=2)):
    return {
        "id": cid,
        "name": name,
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "started_at": started.isoformat().replace("+00:00", "Z"),
        "details_url": f"https://github.com/Muso-AI/hydra/actions/runs/{run}/job/{cid}",
        "app": {"slug": "github-actions"},
    }


def run(rid, path=sw.VALIDATION_PATH, event="pull_request", status="completed"):
    return {"id": rid, "path": path, "event": event, "status": status}


def pull(number, sha=SHA, state="open", base="main", mergeable=True):
    return {"number": number, "state": state, "base": {"ref": base}, "head": {"sha": sha}, "mergeable": mergeable, "body": "x"}


def stale_mirror(suite=SUITE_RUN, edit=EDIT_RUN):
    """A validated head held by an edit run's red `validate` (hydra#1936 on 2026-11-13)."""
    return [
        check("validate-code", suite, 1),
        check("validate", suite, 4),
        check("validate-code", edit, 2, conclusion="skipped"),
        check("validate", edit, 3, conclusion="failure"),
    ]


class Fake:
    """GitHub, as far as the sweep reads it. Records every re-run it is asked for."""

    repo = "Muso-AI/hydra"

    def __init__(self, heads, attempts=None, refuse=(), unreadable=(), graph=None, jobs=None):
        self.heads = heads  # number -> (pull, checks, runs)
        self.state = {rid: {"run_attempt": a, "status": "completed"} for rid, a in (attempts or {}).items()}
        self.refuse, self.unreadable, self.graph = set(refuse), set(unreadable), graph
        # run id -> the attempt's jobs. Absent means "every job started", the ordinary case; a test
        # that sets [] is a run cancelled while it was still queued (2026-11-14, hydra#1961).
        self.jobs = dict(jobs or {})
        self.reran: list[int] = []
        self.calls = 0

    def _by_sha(self, sha):
        return [h for h in self.heads.values() if h[0]["head"]["sha"] == sha]

    def get(self, path):
        self.calls += 1
        if path.startswith("pulls/"):
            n = int(path.split("/")[1])
            if n in self.unreadable:
                raise sw.ReadError(f"GET pulls/{n}: HTTP Error 502")
            return self.heads[n][0]
        if path.startswith("actions/runs/"):
            return self.state.setdefault(int(path.split("/")[2]), {"run_attempt": 1, "status": "completed"})
        raise AssertionError(f"unexpected read: {path}")

    def pages(self, path, key=None):
        self.calls += 1
        m = re.match(r"actions/runs/(\d+)/attempts/\d+/jobs$", path)
        if m:
            rid = int(m.group(1))
            return self.jobs[rid] if rid in self.jobs else [{"started_at": "2026-11-13T09:00:00Z"}]
        sha = re.search(r"(?:commits/|head_sha=)([0-9a-f]{40})", path).group(1)
        if "/check-runs" in path:
            name = re.search(r"check_name=([\w-]+)", path).group(1)
            return [c for h in self._by_sha(sha) for c in h[1] if c["name"] == name]
        if path.startswith("actions/runs?"):
            return [r for h in self._by_sha(sha) for r in h[2]]
        if path.endswith("/pulls"):
            return [h[0] for h in self._by_sha(sha)]
        raise AssertionError(f"unexpected list: {path}")

    def graphql(self, query, variables):
        self.calls += 1
        if isinstance(self.graph, Exception):
            raise self.graph
        return self.graph.pop(0)

    def rerun_failed(self, rid):
        if rid in self.refuse:
            raise urllib.error.HTTPError("u", 403, "Forbidden", {}, None)
        self.reran.append(rid)
        self.state.setdefault(rid, {"run_attempt": 1})["status"] = "queued"


def one(checks, runs=None, apply=True, guard=None, number=1936, **fake):
    gh = Fake({number: (pull(number), checks, runs if runs is not None else [run(SUITE_RUN), run(EDIT_RUN)])}, **fake)
    out = sw.sweep_pr(gh, doctor, guard or Guard(), number, NOW, apply, sleep=lambda s: None)
    return out, gh


class WhatItReRunsTests(unittest.TestCase):
    def test_a_validated_head_held_by_an_edit_runs_red_gets_that_run_re_run(self):
        out, gh = one(stale_mirror())
        self.assertEqual((out["outcome"], out["run"]), ("rerun", EDIT_RUN))
        self.assertEqual(gh.reran, [EDIT_RUN])  # the edit run, never the green suite

    def test_a_dry_run_re_runs_nothing(self):
        out, gh = one(stale_mirror(), apply=False)
        self.assertEqual((out["outcome"], out["run"]), ("would-rerun", EDIT_RUN))
        self.assertEqual(gh.reran, [])

    def test_a_cancelled_suite_is_re_run_in_place(self):
        checks = [check("validate-code", SUITE_RUN, 1, conclusion="cancelled"), check("validate", SUITE_RUN, 2, conclusion="failure")]
        out, gh = one(checks, runs=[run(SUITE_RUN)])
        self.assertEqual(gh.reran, [SUITE_RUN])
        self.assertEqual(out["outcome"], "rerun")

    def test_a_run_cancelled_before_any_job_started_is_not_re_run(self):
        """hydra#1961 (2026-11-14): cancelled AT THE CONCURRENCY GATE, no job ever got a runner.

        Re-running that is not a rescue, it is the canceller: the request cancels the attempt that is
        still queued and starts another one at the back of the same queue. Measured four times on one
        run (attempts 08:46:41, 08:54:33, 08:59:34, 09:18:07, all `cancelled`, every job started_at
        null) against an ovh-hydra pool already at its cap.
        """
        checks = [check("validate-code", SUITE_RUN, 1, conclusion="cancelled"), check("validate", SUITE_RUN, 2, conclusion="failure")]
        out, gh = one(checks, runs=[run(SUITE_RUN)], jobs={SUITE_RUN: []})
        self.assertEqual(gh.reran, [])
        self.assertEqual(out["outcome"], "queued-cancel")
        self.assertIn("before any job started", out["why"])

    def test_an_unreadable_jobs_list_re_runs_as_before(self):
        """A failed read must not silently disable the sweep's one job: fall back to the old answer."""
        checks = [check("validate-code", SUITE_RUN, 1, conclusion="cancelled"), check("validate", SUITE_RUN, 2, conclusion="failure")]
        gh = Fake({1936: (pull(1936), checks, [run(SUITE_RUN)])})
        real_pages = gh.pages

        def pages(path, key=None):
            if "/attempts/" in path:
                raise sw.ReadError("GET attempts/2/jobs: HTTP 502")
            return real_pages(path, key)

        gh.pages = pages
        out = sw.sweep_pr(gh, doctor, Guard(), 1936, NOW, True, sleep=lambda s: None)
        self.assertEqual(out["outcome"], "rerun")
        self.assertEqual(gh.reran, [SUITE_RUN])

    def test_a_stale_guard_red_on_a_body_that_passes_today_is_re_run(self):
        checks = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2),
                  check("credit-approval-guard", GUARD_EDIT, 5),
                  check("credit-approval-guard", GUARD_REVIEW, 6, conclusion="failure")]
        runs = [run(SUITE_RUN), run(GUARD_EDIT, sw.GUARD_PATH, "pull_request_target"),
                run(GUARD_REVIEW, sw.GUARD_PATH, "pull_request_review")]
        out, gh = one(checks, runs=runs)
        self.assertEqual(gh.reran, [GUARD_REVIEW])


class WhatItNeverReRunsTests(unittest.TestCase):
    def test_a_suite_that_failed_is_never_re_run(self):
        # A re-run of a real failure reads the same merge commit: it would only spend a runner,
        # and a flake that passes on retry is a decision for a person.
        checks = [check("validate-code", SUITE_RUN, 1, conclusion="failure"), check("validate", SUITE_RUN, 2, conclusion="failure")]
        out, gh = one(checks, runs=[run(SUITE_RUN)])
        self.assertEqual(gh.reran, [])
        self.assertEqual(out["outcome"], "manual")

    def test_a_failed_suite_under_a_red_edit_run_is_not_re_run_either(self):
        checks = [check("validate-code", SUITE_RUN, 1, conclusion="failure"), check("validate", SUITE_RUN, 4, conclusion="failure"),
                  check("validate-code", EDIT_RUN, 2, conclusion="skipped"), check("validate", EDIT_RUN, 3, conclusion="failure")]
        out, gh = one(checks)
        self.assertEqual(gh.reran, [])

    def test_a_guard_red_on_a_body_that_does_not_pass_is_not_re_run(self):
        checks = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2),
                  check("credit-approval-guard", GUARD_REVIEW, 6, conclusion="failure")]
        runs = [run(SUITE_RUN), run(GUARD_REVIEW, sw.GUARD_PATH, "pull_request_review")]
        out, gh = one(checks, runs=runs, guard=Guard(["PR body has no '## Credit approval impact' section."]))
        self.assertEqual(gh.reran, [])
        self.assertEqual(out["outcome"], "manual")

    def test_a_conflicting_head_is_left_alone(self):
        gh = Fake({7: (pull(7, mergeable=False), stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)])})
        out = sw.sweep_pr(gh, doctor, Guard(), 7, NOW, True, sleep=lambda s: None)
        self.assertEqual((gh.reran, out["outcome"]), ([], "manual"))

    def test_a_head_whose_mergeability_is_unknown_is_left_alone(self):
        gh = Fake({7: (pull(7, mergeable=None), stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)])})
        out = sw.sweep_pr(gh, doctor, Guard(), 7, NOW, True, sleep=lambda s: None)
        self.assertEqual((gh.reran, out["outcome"]), ([], "unknown"))

    def test_a_pr_on_another_base_or_a_closed_one_is_left_alone(self):
        for p in (pull(7, base="fm/other"), pull(7, state="closed")):
            gh = Fake({7: (p, stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)])})
            sw.sweep_pr(gh, doctor, Guard(), 7, NOW, True, sleep=lambda s: None)
            self.assertEqual(gh.reran, [])

    def test_a_green_head_gets_nothing_and_is_not_called_clear(self):
        out, gh = one([check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2)], runs=[run(SUITE_RUN)])
        self.assertEqual((gh.reran, out["outcome"]), ([], "nothing"))
        self.assertNotIn("clear", out["why"])  # it read `validate` and the guard, not the queue

    def test_nothing_is_re_run_while_a_run_of_the_head_is_in_progress(self):
        # Both workflows cancel an in-progress run of their own concurrency group. A guard re-run
        # started beside a running suite is safe; one started beside a running guard cancels it.
        # The pass does not tell them apart: it waits for the running one to end.
        checks = [check("validate-code", SUITE_RUN, 1, status="in_progress"),
                  check("credit-approval-guard", GUARD_REVIEW, 6, conclusion="failure")]
        runs = [run(SUITE_RUN, status="in_progress"), run(GUARD_REVIEW, sw.GUARD_PATH, "pull_request_review")]
        out, gh = one(checks, runs=runs)
        self.assertEqual((gh.reran, out["outcome"]), ([], "wait"))

    def test_choose_takes_the_first_re_run_and_only_re_runs(self):
        steps = [{"kind": "manual", "why": "m"}, {"kind": "rerun", "why": "a", "run": 1}, {"kind": "rerun", "why": "b", "run": 2}]
        self.assertEqual(sw.choose(steps)["run"], 1)
        self.assertIsNone(sw.choose([{"kind": "manual", "why": "m"}, {"kind": "then", "why": "t"}]))
        self.assertIsNone(sw.choose(steps + [{"kind": "wait", "why": "w"}]))
        self.assertIsNone(sw.choose([]))


class NoLoopTests(unittest.TestCase):
    def test_a_run_at_its_attempt_cap_is_left_for_a_person(self):
        out, gh = one(stale_mirror(), attempts={EDIT_RUN: sw.MAX_ATTEMPTS})
        self.assertEqual((gh.reran, out["outcome"]), ([], "gave-up"))

    def test_a_run_below_the_cap_is_re_run(self):
        out, gh = one(stale_mirror(), attempts={EDIT_RUN: sw.MAX_ATTEMPTS - 1})
        self.assertEqual(gh.reran, [EDIT_RUN])

    def test_the_cap_allows_two_automatic_re_runs_and_no_more(self):
        self.assertEqual(sw.MAX_ATTEMPTS, 3)

    def test_a_run_that_is_already_re_running_is_not_asked_again(self):
        gh = Fake({1936: (pull(1936), stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)])})
        gh.state[EDIT_RUN] = {"run_attempt": 2, "status": "in_progress"}
        out = sw.sweep_pr(gh, doctor, Guard(), 1936, NOW, True, sleep=lambda s: None)
        self.assertEqual((gh.reran, out["outcome"]), ([], "wait"))

    def test_one_pr_gets_one_re_run_per_pass_even_with_two_red_guard_events(self):
        # hydra#1115: both events red. Two re-runs in one concurrency group cancel each other.
        checks = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2),
                  check("credit-approval-guard", GUARD_EDIT, 5, conclusion="failure"),
                  check("credit-approval-guard", GUARD_REVIEW, 6, conclusion="failure")]
        runs = [run(SUITE_RUN), run(GUARD_EDIT, sw.GUARD_PATH, "pull_request_target"),
                run(GUARD_REVIEW, sw.GUARD_PATH, "pull_request_review")]
        out, gh = one(checks, runs=runs)
        self.assertEqual(len(gh.reran), 1)

    def test_a_pass_stops_re_running_at_its_cap_and_says_which_prs_it_deferred(self):
        heads = {}
        for i, n in enumerate((11, 12, 13)):
            sha, suite, edit = f"{i:040x}", SUITE_RUN + 10 * i, EDIT_RUN + 10 * i  # a run belongs to one head
            heads[n] = (pull(n, sha=sha), stale_mirror(suite, edit), [run(suite), run(edit)])
        gh = Fake(heads)
        results, unread = sw.sweep(gh, doctor, Guard(), [13, 12, 11], NOW, True, max_reruns=2, log=lambda s: None,
                                   sleep=lambda s: None)
        self.assertEqual([r["outcome"] for r in results], ["rerun", "rerun", "deferred"])
        self.assertEqual(len(gh.reran), 2)

    def test_a_refusal_because_someone_else_re_ran_it_is_a_wait_not_an_error(self):
        gh = Fake({1936: (pull(1936), stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)])}, refuse=[EDIT_RUN])
        states = iter([{"run_attempt": 1, "status": "completed"}, {"run_attempt": 2, "status": "queued"}])
        real_get = gh.get
        gh.get = lambda path: next(states) if path.startswith("actions/runs/") else real_get(path)
        out = sw.sweep_pr(gh, doctor, Guard(), 1936, NOW, True, sleep=lambda s: None)
        self.assertEqual(out["outcome"], "wait")


class NeverACleanPassOnAnUnreadTests(unittest.TestCase):
    def heads(self):
        return {11: (pull(11, sha="1" * 40), stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)]),
                12: (pull(12, sha="2" * 40), stale_mirror(), [run(SUITE_RUN), run(EDIT_RUN)])}

    def main(self, gh, *argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc = sw.main(["--repo", "Muso-AI/hydra", *argv], gh=gh)
        return rc, buf.getvalue()

    def test_an_unreadable_pr_is_exit_3_and_the_others_are_still_swept(self):
        gh = Fake(self.heads(), unreadable=[12])
        rc, text = self.main(gh, "--pr", "12", "11", "--apply")
        self.assertEqual(rc, sw.EXIT_UNREAD)
        self.assertEqual(len(gh.reran), 1)
        self.assertIn("NOT READ", text)
        self.assertIn("not a clean sweep", text)

    def test_a_list_that_cannot_be_read_sweeps_nothing_and_is_exit_3(self):
        gh = Fake(self.heads(), graph=sw.ReadError("graphql: HTTP Error 504"))
        rc, text = self.main(gh, "--all", "--apply")
        self.assertEqual((rc, gh.reran), (sw.EXIT_UNREAD, []))
        self.assertIn("nothing was swept", text)

    def test_a_refused_re_run_is_exit_1(self):
        gh = Fake(self.heads(), refuse=[EDIT_RUN])
        rc, text = self.main(gh, "--pr", "11", "--apply")
        self.assertEqual(rc, sw.EXIT_REFUSED)
        self.assertIn("refused", text)

    def test_a_clean_pass_is_exit_0_and_names_what_it_re_ran(self):
        gh = Fake(self.heads())
        rc, text = self.main(gh, "--pr", "11", "--apply")
        self.assertEqual(rc, sw.EXIT_OK)
        self.assertIn(f"**rerun** run {EDIT_RUN}", text)

    def test_no_token_is_a_usage_error_not_a_pass(self):
        saved = {k: os.environ.pop(k, None) for k in ("GH_TOKEN", "GITHUB_TOKEN")}
        try:
            rc, _ = self.main(None, "--all")
        finally:
            os.environ.update({k: v for k, v in saved.items() if v is not None})
        self.assertEqual(rc, sw.EXIT_USAGE)


class ScopeTests(unittest.TestCase):
    def test_a_sha_selects_only_open_prs_on_main_whose_head_it_still_is(self):
        gh = Fake({1: (pull(1), [], []), 2: (pull(2, state="closed"), [], []), 3: (pull(3, base="fm/x"), [], []),
                   4: (pull(4, sha="4" * 40), [], [])})
        self.assertEqual(sw.prs_of_sha(gh, SHA), [1])

    def node(self, n, mergeable="MERGEABLE", state="FAILURE"):
        rollup = None if state is None else {"state": state}
        return {"number": n, "mergeable": mergeable, "commits": {"nodes": [{"commit": {"statusCheckRollup": rollup}}]}}

    def page(self, nodes, more=False):
        return {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": more, "endCursor": "c"}, "nodes": nodes}}}

    def test_the_full_sweep_reads_only_red_heads_that_do_not_conflict(self):
        gh = Fake({}, graph=[
            self.page([self.node(5), self.node(6, mergeable="CONFLICTING"), self.node(7, state="SUCCESS")], more=True),
            self.page([self.node(8, state="ERROR"), self.node(9, state="PENDING"), self.node(10, state=None),
                       self.node(11, mergeable="UNKNOWN")]),
        ])
        numbers, seen = sw.red_prs(gh)
        self.assertEqual(numbers, [11, 8, 5])
        self.assertEqual(seen, {"open": 7, "conflicting": 1, "not_red": 3})

    def test_an_answer_of_the_wrong_shape_is_a_read_error_not_an_empty_list(self):
        with self.assertRaises(sw.ReadError):
            sw.red_prs(Fake({}, graph=[{"repository": None}]))


class Response:
    def __init__(self, body):
        self.body = json.dumps(body).encode() if body is not None else b""

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return self.body


class ClientTests(unittest.TestCase):
    def client(self, answers):
        sent = []

        def opener(req, timeout=0):
            sent.append(req)
            item = answers.pop(0)
            if isinstance(item, Exception):
                raise item
            return Response(item)

        return sw.GitHub("Muso-AI/hydra", "tok", opener=opener), sent

    def test_pages_follow_until_a_short_page(self):
        gh, sent = self.client([{"check_runs": [{"id": i} for i in range(100)]}, {"check_runs": [{"id": 100}]}])
        self.assertEqual(len(gh.pages("commits/abc/check-runs?filter=all", "check_runs")), 101)
        self.assertIn("page=2", sent[1].full_url)

    def test_an_http_error_or_a_wrong_shape_on_a_read_is_a_read_error(self):
        gh, _ = self.client([urllib.error.HTTPError("u", 502, "Bad Gateway", {}, None)])
        with self.assertRaises(sw.ReadError):
            gh.get("pulls/1")
        gh, _ = self.client([{"message": "nope"}])
        with self.assertRaises(sw.ReadError):
            gh.pages("actions/runs?head_sha=abc", "workflow_runs")
        gh, _ = self.client([{"errors": [{"message": "x"}]}])
        with self.assertRaises(sw.ReadError):
            gh.graphql("query{}", {})

    def test_the_re_run_is_a_post_to_rerun_failed_jobs_of_that_run(self):
        gh, sent = self.client([None])
        gh.rerun_failed(43388110812)
        self.assertEqual(sent[0].get_method(), "POST")
        self.assertEqual(sent[0].full_url, "https://api.github.com/repos/Muso-AI/hydra/actions/runs/43388110812/rerun-failed-jobs")
        self.assertEqual(sent[0].get_header("Authorization"), "Bearer tok")


class OnlyAReRunTests(unittest.TestCase):
    """The script's whole write surface, read from its source."""

    @classmethod
    def setUpClass(cls):
        with open(SCRIPT, encoding="utf-8") as fh:
            cls.src = fh.read()

    def test_the_only_writes_are_the_re_run_and_the_read_only_query(self):
        sends = re.findall(r'self\._send\("(\w+)", ([^\n]+)', self.src)
        self.assertEqual(sorted(m for m, _ in sends), ["GET", "POST", "POST"])
        posts = [rest for m, rest in sends if m == "POST"]
        self.assertTrue(any("/graphql" in p for p in posts))
        self.assertTrue(any("/rerun-failed-jobs" in p for p in posts))
        self.assertNotIn("mutation", self.src.lower().replace("mutations", ""))

    def test_it_names_no_other_write_endpoint(self):
        for needle in ('"PATCH"', '"PUT"', '"DELETE"', "/merge", "/dispatches", "/statuses", "/rerun\"", "/cancel", "/approve"):
            self.assertNotIn(needle, self.src, needle)

    def test_what_may_be_re_run_is_the_planners_decision(self):
        self.assertIn("doctor.plan_pr(", self.src)
        self.assertEqual(self.src.count("rerun_failed("), 2)  # the method and its one call


# Every workflow that can queue a run per PR must CANCEL a superseded run of the same PR instead of
# queueing it behind the one it replaces. Measured 2026-11-16T04:5xZ on the hydra fleet: 43 queued
# PR Validation runs over 21 refs, 12 queued PR Title Check runs over 12 refs, 18 queued sweep
# passes over 17 heads. A superseded run is a queue slot spent on a verdict the newer run reaches
# anyway, and the fleet is the bottleneck (9 hosts at 69-89% CPU, report-024-hydra-ci.md).
PER_PR_WORKFLOWS = (
    (WORKFLOW, "pr-rerun-sweep-"),
    (TITLE_CHECK, "pr-title-check-"),
    (VALIDATE, "pr-validate-"),
)

# The sweep's `cancel-in-progress` must cancel a per-PR pass and must NOT cancel the scheduled
# `all-open-prs` net. In the 18 h to 2026-11-16T05:00Z the scheduled pass waited 1h15m-2h38m for a
# runner while the cron fires every 2 h, so a cancellable net is one each tick cancels while it is
# still waiting: it can be starved for as long as the pool stays saturated, and it is the only
# trigger for a credit-guard red that no PR Validation run follows (Opus review of #2089).
SWEEP_CANCEL = (
    "${{ github.event_name == 'workflow_run'"
    " || (github.event_name == 'workflow_dispatch' && inputs.pr != '') }}"
)

# The net's own group key. No branch name and no PR number may produce it: a branch is a name
# anybody can choose, and the net is the one pass that is not cancellable, so a branch that joined
# it would share the group's single slot and the net would wait behind a pass that keeps being
# replaced (QA review of #2089).
SWEEP_NET = "pr-rerun-sweep-net"


def sweep_group(
    head_branch: str | None = None,
    pr: str = "",
    event: str = "workflow_run",
    head_pr: str = "",
    head_repo_id: str = "",
) -> str:
    """`pr-rerun-sweep.yml`'s `group:` expression, evaluated.

    Mirrors the workflow line; `sweep_group_problems` fails when the two disagree, so this cannot
    drift into describing a shape the workflow no longer has.

    A branch name is not an identity (QA review of #2089): two fork PRs can both be `fix`, and a
    pass for one must not cancel the other's. So the PR is named by its number when the run names
    it, and otherwise by its head repository's numeric id plus its branch.
    """
    if event == "workflow_run" and head_pr:
        return f"pr-rerun-sweep-pr-{head_pr}"
    if event == "workflow_run" and head_repo_id:
        return f"pr-rerun-sweep-fork-{head_repo_id}-{head_branch}"
    if pr:
        return f"pr-rerun-sweep-pr-{pr}"
    return SWEEP_NET


def sweep_group_problems(text: str) -> list[str]:
    """The key must name the PR, not just its branch, and never reach the net's own key."""
    try:
        block = concurrency_block(text)
    except ValueError:
        return ["the workflow has no workflow-level `concurrency:` block"]
    group = re.search(r"^  group: (.+)$", block, flags=re.M)
    if group is None:
        return ["the concurrency block has no `group:`"]
    key = group.group(1)
    problems = []
    if "format('pr-{0}'" not in key:
        problems.append(f"the group {key!r} never keys on a PR number")
    if "format('fork-{0}-{1}'" not in key or "head_repository.id" not in key:
        problems.append(
            f"the group {key!r} does not fall back to the head repository's id: a branch name is "
            "not an identity, and two fork PRs both called `fix` would share one group"
        )
    if "'net'" not in key:
        problems.append(f"the group {key!r} does not name the net's own key")
    if "branch-" in key:
        problems.append(
            f"the group {key!r} still keys on a bare branch name: it is not a PR identity"
        )
    return problems


def _without_comments(text: str) -> str:
    """The workflow with its comment lines stripped: a comment is not a setting."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def concurrency_block(text: str) -> str:
    """The workflow-level `concurrency:` block, comments stripped."""
    code = _without_comments(text)
    start = code.index("\nconcurrency:\n")
    return code[start : code.index("\njobs:\n", start)]


def concurrency_problems(text: str, prefix: str, cancel: str = "true") -> list[str]:
    """Everything wrong with this workflow's concurrency. Empty means: per PR, and it cancels.

    `cancel` is the exact `cancel-in-progress` value this workflow must carry: the literal `true`
    for a workflow whose only group is a PR, and `SWEEP_CANCEL` for the sweep, whose scheduled
    `all-open-prs` net must survive the next tick.

    The real files and every mutation go through THIS function, so a mutation that puts a
    superseded run back in the queue fails for the same reason the real file would.
    """
    try:
        block = concurrency_block(text)
    except ValueError:
        return ["the workflow has no workflow-level `concurrency:` block"]
    problems = []
    group = re.search(r"^  group: (.+)$", block, flags=re.M)
    if group is None:
        problems.append("the concurrency block has no `group:`")
    else:
        key = group.group(1)
        if not key.startswith(prefix):
            problems.append(f"the group {key!r} does not start with {prefix!r}: it could share a group with another workflow")
        if not any(part in key for part in ("github.ref", "head_branch", "inputs.pr")):
            problems.append(f"the group {key!r} is not keyed on the PR: a superseded run would queue, not cancel")
    found = re.search(r"^  cancel-in-progress: (.+)$", block, flags=re.M)
    if found is None:
        problems.append("the concurrency block has no `cancel-in-progress:`")
    elif found.group(1).strip() != cancel:
        problems.append(f"cancel-in-progress is {found.group(1).strip()!r}, not {cancel!r}")
    return problems


def _top_block(text: str, key: str) -> str:
    """The body of the top-level `key:` block, comments stripped, up to the next top-level key."""
    code = _without_comments(text)
    found = re.search(rf"(?ms)^{re.escape(key)}:\n(.*?)(?=^\S|\Z)", code)
    return found.group(1) if found else ""


# A `pull_request` `edited` event is a title or body change (or a retarget, which is why it is a
# trigger at all). It must never RUN a code suite and must never DISPLACE one: on 2026-11-16 four
# open PRs had a body edit land while their push-triggered suite was queued. The suite is 20-60
# minutes of a saturated pool, and the edit can say nothing about the code it would test.
#
# The fix lives in `pr-validate.yml` since QA #1813 Critical (a metadata edit shared the code
# group, so it cancelled the validation it could not replace) and has two halves, both load-bearing:
#   1. the concurrency group keys on the ACTION, so an `edited` run lands in a `meta` bucket and
#      never enters the code bucket's group;
#   2. every code job carries `github.event.action != 'edited'` in its `if:`.
# `scripts/tests/pr-validate-retarget.bats` pins both for that one workflow. What was missing is a
# check over EVERY workflow: a new one on `edited` types would reintroduce the bug silently.
EDITED_GUARD = "github.event.action != 'edited'"

# The invocations that make a job a code suite. Deliberately about what a job RUNS, not about its
# name: `validate` in pr-validate.yml reads the runs API (`scripts/ci/validate-mirror.py`) and is
# not one of these, while `py-syntax` and `shellcheck` are.
CODE_TOOL_MARKERS = (
    "scripts/tests/",
    "python3 -m pytest",
    "python3 -m unittest",
    "unittest.main",
    "py_compile",
    "shellcheck",
    "vitest",
    "bats ",
)

WORKFLOWS_DIR = os.path.join(ROOT, ".github", "workflows")


def workflow_texts() -> dict[str, str]:
    """Every workflow file in the repo, by name."""
    out = {}
    for name in sorted(os.listdir(WORKFLOWS_DIR)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(WORKFLOWS_DIR, name), encoding="utf-8") as fh:
            out[name] = fh.read()
    return out


def triggers_on_edited(text: str) -> bool:
    """True when an `on:` trigger lists `edited` (a comment saying `edited` is not a trigger)."""
    return re.search(r"\bedited\b", _top_block(text, "on")) is not None


def job_blocks(text: str) -> dict[str, str]:
    """{job id: its block} for every job declared under `jobs:`."""
    out: dict[str, list[str]] = {}
    current = None
    for line in _top_block(text, "jobs").splitlines():
        found = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
        if found:
            current = found.group(1)
            out[current] = []
        elif current is not None:
            out[current].append(line)
    return {name: "\n".join(lines) for name, lines in out.items()}


def code_jobs(text: str) -> list[str]:
    """The jobs that run a suite, a linter or a compile check."""
    return [
        name
        for name, block in job_blocks(text).items()
        if any(marker in block for marker in CODE_TOOL_MARKERS)
    ]


def edited_event_problems(text: str) -> list[str]:
    """Everything that would let an `edited` event run or displace a code suite. Empty is safe.

    The real files and every mutation go through THIS function, so a mutation fails for the same
    reason the real workflow would.
    """
    if not triggers_on_edited(text):
        return []
    suites = code_jobs(text)
    if not suites:
        return []  # a metadata-only workflow may run on `edited`; there is no suite to displace
    problems = []
    try:
        group = re.search(r"^  group: (.+)$", concurrency_block(text), flags=re.M)
    except ValueError:
        group = None
    if group is None or "github.event.action == 'edited'" not in group.group(1):
        problems.append(
            "the concurrency group does not key on the action, so an `edited` run enters the code "
            "group and cancels the validation it cannot replace"
        )
    blocks = job_blocks(text)
    for name in suites:
        guard = re.search(rf"(?m)^    if: .*{re.escape(EDITED_GUARD)}", blocks[name])
        if guard is None:
            problems.append(f"{name}: a code job with no `if: {EDITED_GUARD} ...` guard")
    return problems


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(WORKFLOW, encoding="utf-8") as fh:
            cls.text = fh.read()
        cls.code = "\n".join(line for line in cls.text.splitlines() if not line.lstrip().startswith("#"))

    def test_it_fires_when_pr_validation_completes_and_on_a_schedule(self):
        on = self.code[self.code.index("\non:\n") : self.code.index("\npermissions:\n")]
        self.assertRegex(on, r'workflow_run:\n\s+workflows: \["PR Validation"\]\n\s+types: \[completed\]')
        self.assertRegex(on, r'schedule:\n\s+- cron: "\d+ \*/2 \* \* \*"')
        self.assertIn("workflow_dispatch:", on)
        with open(VALIDATE, encoding="utf-8") as fh:
            self.assertRegex(fh.read(), r"(?m)^name: PR Validation$")  # workflow_run keys off this name

    def test_its_only_write_permission_is_actions(self):
        perms = self.code[self.code.index("\npermissions:\n") : self.code.index("\nconcurrency:\n")]
        granted = dict(re.findall(r"^  ([a-z-]+): (\w+)", perms, flags=re.M))
        self.assertEqual(granted, {"actions": "write", "checks": "read", "contents": "read", "pull-requests": "read",
                                   "statuses": "read"})
        self.assertEqual(self.code.count("permissions:"), 1)  # no job widens it

    def test_it_has_a_kill_switch_and_ignores_runs_that_are_not_a_pull_request(self):
        cond = re.search(r"^    if: (.+)$", self.code, flags=re.M).group(1)
        self.assertIn("vars.PR_RERUN_SWEEP_DISABLED != '1'", cond)
        self.assertIn("github.event.workflow_run.event == 'pull_request'", cond)

    def test_it_runs_the_default_branchs_planner_not_pr_code(self):
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", self.code)
        for path in ("scripts/ci/pr-rerun-sweep.py", "scripts/pr-doctor.py", ".github/credit-approval/guard.py"):
            self.assertIn(path, self.code)

    def test_no_event_value_is_interpolated_into_the_shell(self):
        script = self.code[self.code.index("        run: |") :]
        self.assertNotIn("${{", script)
        self.assertIn('[[ "$INPUT_PR" =~ ^[0-9]+$ ]]', script)

    def test_a_superseded_pass_for_the_same_pr_is_cancelled(self):
        # The group is the PR, not the head: a pass for a head the PR has already moved past is
        # stale work, and the pass for the newer head covers it.
        self.assertEqual(concurrency_problems(self.text, "pr-rerun-sweep-", SWEEP_CANCEL), [])
        conc = concurrency_block(self.text)
        self.assertIn("pull_requests[0].number", conc)
        self.assertIn("head_repository.id", conc)
        self.assertIn("github.event.inputs.pr", conc)
        # Two runs of one PR land in one group, and two PRs never share one.
        self.assertEqual(sweep_group(head_pr="2089"), sweep_group(head_pr="2089"))
        self.assertNotEqual(sweep_group(head_pr="2089"), sweep_group(head_pr="2090"))

    def test_a_fork_pr_is_keyed_by_repository_not_branch(self):
        # `workflow_run.pull_requests` is empty for a fork PR, so the key falls back to the head
        # repository's numeric id and its branch: two forks whose branches are both called `fix`
        # are two groups, and one fork's pass cannot cancel the other's (QA review of #2089).
        self.assertEqual(sweep_group_problems(self.text), [])
        a = sweep_group(head_branch="fix", head_repo_id="1001")
        b = sweep_group(head_branch="fix", head_repo_id="1002")
        self.assertNotEqual(a, b)
        self.assertIn("1001", a)
        self.assertIn("1002", b)
        # One fork, one branch, two runs: one group. That is the cancellation this PR wants.
        self.assertEqual(a, sweep_group(head_branch="fix", head_repo_id="1001"))

    def test_no_branch_name_can_join_the_nets_group(self):
        # A branch is a name anybody can choose, and the net is the one pass that is not
        # cancellable. Keyed bare, a branch called `net` (or whatever the net's key is) would sit in
        # the net's group, and the two would share its one running plus one pending slot, so the net
        # would wait behind a pass that keeps being replaced. QA review of #2089.
        self.assertEqual(sweep_group_problems(self.text), [])
        net = sweep_group(event="schedule")
        self.assertEqual(net, SWEEP_NET)
        # A bare `--all` dispatch is a net too, so it joins the net rather than making a second one.
        self.assertEqual(sweep_group(event="workflow_dispatch"), net)
        for name in ("net", "all-open-prs", "pr-rerun-sweep-net", "main"):
            self.assertNotEqual(sweep_group(head_branch=name, head_repo_id="1"), net, name)
        # The namespaced keys cannot equal a bare one whatever the branch is called.
        for name in ("net", "all-open-prs", "-net", "net-"):
            self.assertNotEqual(sweep_group(head_branch=name, head_repo_id="1"), net, name)
            self.assertNotEqual(sweep_group(pr=name), net, name)
        # A dispatch that names a PR and that PR's `workflow_run` pass are both per-PR, and neither
        # is the net.
        self.assertNotEqual(sweep_group(pr="2089", event="workflow_dispatch"), net)

    def test_a_bare_branch_key_fails_this_test(self):
        # The mutation is the shape this PR first shipped: `head_branch || inputs.pr || '<net>'`.
        bare = re.sub(
            r"(?m)^  group: .+$",
            "  group: pr-rerun-sweep-${{ github.event.workflow_run.head_branch || github.event.inputs.pr || 'net' }}",
            self.text,
        )
        self.assertNotEqual(bare, self.text)
        self.assertTrue(sweep_group_problems(bare))
        # ... and it is a real collision, not a wording problem: under that shape a branch named
        # `net` produces exactly the net's own key.
        bare_key = lambda head_branch=None, pr="": "pr-rerun-sweep-" + (head_branch or pr or "net")
        self.assertEqual(bare_key(head_branch="net"), bare_key())
        # The same bug with the prefix still on it: namespacing a BRANCH is not naming the PR, and
        # two forks whose branches share a name would still share a group.
        branch_only = re.sub(
            r"(?m)^  group: .+$",
            "  group: pr-rerun-sweep-${{ github.event.workflow_run.head_branch || github.event.inputs.pr "
            "|| 'net' }}",
            self.text,
        )
        self.assertTrue(sweep_group_problems(branch_only))
        self.assertNotEqual(
            "pr-rerun-sweep-branch-fix",
            sweep_group(head_branch="fix", head_repo_id="1001"),
        )

    def test_the_scheduled_net_is_never_cancelled(self):
        # The net is the only trigger for a credit-guard red that no PR Validation run follows, and
        # in the 18 h to 2026-11-16T05:00Z it waited 1h15m-2h38m for a runner while the cron fires
        # every 2 h. A cancellable net is one each tick cancels while it is still waiting.
        conc = concurrency_block(self.text)
        self.assertIn(SWEEP_CANCEL, conc)
        # The expression is false for `schedule` and for a dispatch that names no PR, and true for
        # the two events that carry a PR.
        self.assertNotIn("schedule", SWEEP_CANCEL)
        self.assertIn("github.event_name == 'workflow_run'", SWEEP_CANCEL)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.pr != ''", SWEEP_CANCEL)

    def test_making_the_net_cancellable_fails_this_test(self):
        # The mutation is the tempting simplification: `cancel-in-progress: true` for every event.
        mutated = re.sub(r"(?m)^  cancel-in-progress: .+$", "  cancel-in-progress: true", self.text)
        self.assertNotEqual(mutated, self.text)
        self.assertTrue(concurrency_problems(mutated, "pr-rerun-sweep-", SWEEP_CANCEL))

    def test_queueing_a_superseded_pass_again_fails_this_test(self):
        # The mutation is the revert: put `cancel-in-progress: false` back and the contract must go
        # red for the same reason the real file would.
        mutated = re.sub(r"(?m)^  cancel-in-progress: .+$", "  cancel-in-progress: false", self.text)
        self.assertNotEqual(mutated, self.text)
        self.assertTrue(concurrency_problems(mutated, "pr-rerun-sweep-", SWEEP_CANCEL))
        # A group keyed on the head instead of the PR is the same bug in a different place.
        head_keyed = re.sub(
            r"(?m)^  group: .+$",
            "  group: pr-rerun-sweep-${{ github.event.workflow_run.head_sha || 'all' }}",
            self.text,
        )
        self.assertNotEqual(head_keyed, self.text)
        self.assertTrue(concurrency_problems(head_keyed, "pr-rerun-sweep-", SWEEP_CANCEL))
        # And a group that could collide with another workflow's is not per-PR either.
        shared = re.sub(r"(?m)^  group: .+$", "  group: ci-${{ github.ref }}", self.text)
        self.assertTrue(concurrency_problems(shared, "pr-rerun-sweep-", SWEEP_CANCEL))

    def test_the_other_per_pr_workflows_already_cancel_a_superseded_run(self):
        # PR Title Check was fixed on 2026-11-04 and PR Validation carries an event-aware per-ref
        # group. Pinned here so a later edit cannot quietly put a superseded run back in the queue
        # on either of them, and so this PR's claim about them is a test rather than a sentence.
        for path, prefix in PER_PR_WORKFLOWS[1:]:
            with open(path, encoding="utf-8") as fh:
                self.assertEqual(concurrency_problems(fh.read(), prefix), [], path)

    def test_it_applies_unless_asked_for_a_dry_run(self):
        script = self.code[self.code.index("        run: |") :]
        self.assertRegex(script, r'if \[ "\$INPUT_DRY_RUN" != "true" \]; then\n\s+args\+=\(--apply\)')
        self.assertIn('python3 scripts/ci/pr-rerun-sweep.py "${args[@]}"', script)

    def test_it_is_off_node_8(self):
        self.assertRegex(self.code, r"(?m)^    runs-on: ovh-hydra$")

    def test_pr_validation_runs_these_tests(self):
        with open(VALIDATE, encoding="utf-8") as fh:
            self.assertIn("python3 scripts/tests/test_pr_rerun_sweep.py", fh.read())


class EditedEventTests(unittest.TestCase):
    """A title or body edit must never run a code suite, and never displace the one it has."""

    # Enumerated, not discovered: a NEW workflow on `edited` types has to be argued for here, so
    # the next one cannot arrive with a code suite and nobody noticing. 2026-11-16T07:0xZ.
    EDITED_WORKFLOWS = {
        "credit-approval-guard.yaml",  # `types: [..., edited, ...]` — re-runs the guard on a body fix
        "pr-title-check.yml",  # `types: [opened, edited, synchronize, reopened]` — the title check
        "pr-validate.yml",  # `types: [..., edited]` — the only one with a code suite
        "qa-tier-recheck.yml",  # `pull_request_target: types: [labeled, edited]`
    }

    @classmethod
    def setUpClass(cls):
        cls.workflows = workflow_texts()

    def test_only_the_expected_workflows_run_on_edited(self):
        found = {name for name, text in self.workflows.items() if triggers_on_edited(text)}
        self.assertEqual(found, self.EDITED_WORKFLOWS)

    def test_no_workflow_lets_edited_run_or_displace_a_code_suite(self):
        for name in sorted(self.EDITED_WORKFLOWS):
            self.assertEqual(edited_event_problems(self.workflows[name]), [], name)

    def test_pr_validation_is_the_code_suite_and_it_is_guarded_job_by_job(self):
        text = self.workflows["pr-validate.yml"]
        suites = code_jobs(text)
        # The guard has to be on every suite, so the list has to be more than one job or this test
        # would pass on a workflow that runs nothing.
        self.assertGreaterEqual(len(suites), 7, suites)
        for name in suites:
            self.assertRegex(
                job_blocks(text)[name],
                rf"(?m)^    if: .*{re.escape(EDITED_GUARD)}",
                f"{name} runs a suite on an `edited` event",
            )

    def test_a_code_job_without_the_guard_fails_this_test(self):
        # The mutation is the one a future edit makes: add a job, forget the `if:`.
        text = self.workflows["pr-validate.yml"]
        mutated = re.sub(rf"(?m)^    if: .*{re.escape(EDITED_GUARD)}.*$", "    if: always()", text)
        self.assertNotEqual(mutated, text)
        problems = edited_event_problems(mutated)
        self.assertEqual(len(problems), len(code_jobs(text)), problems)

    def test_one_missing_guard_fails_this_test(self):
        # One job is enough: break only `py-syntax`'s guard, in its own block.
        text = self.workflows["pr-validate.yml"]
        mutated = re.sub(
            r"(?ms)(^  py-syntax:\n)(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)",
            lambda m: m.group(1) + m.group(2).replace(EDITED_GUARD, "true"),
            text,
        )
        self.assertNotEqual(mutated, text)
        self.assertEqual(
            edited_event_problems(mutated),
            [f"py-syntax: a code job with no `if: {EDITED_GUARD} ...` guard"],
        )

    def test_an_edited_run_in_the_code_group_fails_this_test(self):
        # The QA #1813 regression: key the group on the ref alone and an `edited` run cancels the
        # validation it cannot replace.
        text = self.workflows["pr-validate.yml"]
        mutated = re.sub(
            r"(?m)^  group: .+$", "  group: pr-validate-${{ github.ref }}", text
        )
        self.assertNotEqual(mutated, text)
        self.assertIn(
            "the concurrency group does not key on the action",
            " ".join(edited_event_problems(mutated)),
        )

    def test_a_code_suite_in_a_metadata_workflow_fails_this_test(self):
        # PR Title Check runs on `edited` and is cheap because it only reads the title. Give it a
        # suite and it must be refused, guard or no guard: it has no `meta` bucket to land in.
        text = self.workflows["pr-title-check.yml"]
        mutated = text.replace(
            "jobs:\n",
            "jobs:\n  suite:\n    runs-on: ovh-hydra\n    steps:\n      - run: python3 scripts/tests/test_pr_rerun_sweep.py\n",
            1,
        )
        self.assertNotEqual(mutated, text)
        problems = " ".join(edited_event_problems(mutated))
        self.assertIn("suite: a code job with no", problems)
        self.assertIn("does not key on the action", problems)


if __name__ == "__main__":
    unittest.main()
