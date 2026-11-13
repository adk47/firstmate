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

    def __init__(self, heads, attempts=None, refuse=(), unreadable=(), graph=None):
        self.heads = heads  # number -> (pull, checks, runs)
        self.state = {rid: {"run_attempt": a, "status": "completed"} for rid, a in (attempts or {}).items()}
        self.refuse, self.unreadable, self.graph = set(refuse), set(unreadable), graph
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

    def test_a_pass_is_never_cancelled_half_way(self):
        conc = self.code[self.code.index("\nconcurrency:\n") : self.code.index("\njobs:\n")]
        self.assertIn("cancel-in-progress: false", conc)

    def test_it_applies_unless_asked_for_a_dry_run(self):
        script = self.code[self.code.index("        run: |") :]
        self.assertRegex(script, r'if \[ "\$INPUT_DRY_RUN" != "true" \]; then\n\s+args\+=\(--apply\)')
        self.assertIn('python3 scripts/ci/pr-rerun-sweep.py "${args[@]}"', script)

    def test_it_is_off_node_8(self):
        self.assertRegex(self.code, r"(?m)^    runs-on: ovh-hydra$")

    def test_pr_validation_runs_these_tests(self):
        with open(VALIDATE, encoding="utf-8") as fh:
            self.assertIn("python3 scripts/tests/test_pr_rerun_sweep.py", fh.read())


if __name__ == "__main__":
    unittest.main()
