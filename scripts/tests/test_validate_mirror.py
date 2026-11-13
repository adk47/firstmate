#!/usr/bin/env python3
"""Tests for scripts/ci/validate-mirror.py, the required `validate` check of a metadata-edit run.

Two failure modes matter, in this order:
  1. it must never report success for a head whose newest real suite did not succeed;
  2. it must not fail a head whose suite is merely still running (the 2026-11 poisoning).
The workflow wiring is pinned too: a mirror nobody calls protects nothing. Stdlib only.
"""
import importlib.util
import json
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "validate-mirror.py")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "pr-validate.yml")

_spec = importlib.util.spec_from_file_location("validate_mirror", SCRIPT)
vm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vm)

CODE_RUN = 43343801217  # hydra#1926: the push's run
META_RUN = 43344100339  # hydra#1926: the body edit 2m20s later; a NEWER run


def check(run, cid, status="completed", conclusion="success", name="validate-code", app="github-actions"):
    return {
        "id": cid,
        "name": name,
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "details_url": f"https://github.com/Muso-AI/hydra/actions/runs/{run}/job/{cid}",
        "app": {"slug": app},
    }


SKIPPED = check(META_RUN, 131619218790, conclusion="skipped")


class Clock:
    """A fake monotonic clock that `sleep` advances, so no test waits."""

    def __init__(self):
        self.now = 0.0
        self.sleeps = 0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        self.sleeps += 1


def run_mirror(reads, wait=1500, appear=180, poll=15, own=0):
    """Drive `mirror` over a scripted series of reads; the last one repeats."""
    clock, lines, calls = Clock(), [], {"n": 0}

    def read():
        item = reads[min(calls["n"], len(reads) - 1)]
        calls["n"] += 1
        if isinstance(item, Exception):
            raise item
        return item if isinstance(item, tuple) else (item, [])  # a bare list = checks, no run listing

    rc = vm.mirror(read, wait=wait, appear=appear, poll=poll, own=own, clock=clock, sleep=clock.sleep, log=lines.append)
    return rc, clock, "\n".join(lines)


class DecideTests(unittest.TestCase):
    def test_a_skipped_placeholder_is_not_a_suite(self):
        self.assertEqual(vm.decide([SKIPPED])[0], "none")

    def test_a_running_suite_is_wait_not_fail(self):
        # hydra#1926 at 01:20:05Z: the push's suite had 3m45s left. The old job failed here.
        running = check(CODE_RUN, 131618178383, status="in_progress")
        self.assertEqual(vm.decide([running, SKIPPED])[0], "wait")
        queued = check(CODE_RUN, 131618178383, status="queued")
        self.assertEqual(vm.decide([queued, SKIPPED])[0], "wait")

    def test_a_finished_suite_is_mirrored_either_way(self):
        self.assertEqual(vm.decide([check(CODE_RUN, 1), SKIPPED])[0], "pass")
        for bad in ("failure", "timed_out", "action_required", "stale", "neutral"):
            self.assertEqual(vm.decide([check(CODE_RUN, 1, conclusion=bad), SKIPPED])[0], "fail", bad)

    def test_the_newest_run_decides_not_the_newest_green(self):
        # An older run's success must not outvote a newer run's failure on the same head.
        older_green = check(100, 9, conclusion="success")
        newer_red = check(200, 5, conclusion="failure")
        self.assertEqual(vm.decide([older_green, newer_red])[0], "fail")
        self.assertEqual(vm.decide([newer_red, older_green])[0], "fail")

    def test_a_rerun_attempt_of_the_same_run_supersedes_its_first_attempt(self):
        first = check(CODE_RUN, 10, conclusion="failure")
        second = check(CODE_RUN, 20, conclusion="success")
        self.assertEqual(vm.decide([first, second])[0], "pass")
        self.assertEqual(vm.decide([check(CODE_RUN, 30, status="in_progress"), first, second])[0], "wait")

    def test_a_cancelled_suite_is_never_a_pass_and_waits_only_for_a_successor(self):
        self.assertEqual(vm.decide([check(CODE_RUN, 1, conclusion="cancelled")])[0], "none")

    def test_only_this_repos_actions_jobs_count(self):
        forged = check(CODE_RUN + 10, 99, app="some-other-app")
        self.assertEqual(vm.decide([forged])[0], "none")
        self.assertEqual(vm.decide([forged, check(CODE_RUN, 1, conclusion="failure")])[0], "fail")
        # Any other green job is not a suite (a lone `validate` is the pre-split case: LegacyHeadTests).
        other_name = check(CODE_RUN + 10, 98, name="pr-title")
        self.assertEqual(vm.decide([other_name])[0], "none")


class MirrorTests(unittest.TestCase):
    def test_waits_for_the_running_suite_then_passes(self):
        running = [check(CODE_RUN, 1, status="in_progress"), SKIPPED]
        done = [check(CODE_RUN, 1), SKIPPED]
        rc, clock, out = run_mirror([running, running, running, done])
        self.assertEqual(rc, 0)
        self.assertEqual(clock.sleeps, 3)
        self.assertIn("succeeded", out)

    def test_waits_for_the_running_suite_then_fails_with_it(self):
        running = [check(CODE_RUN, 1, status="in_progress")]
        rc, _, out = run_mirror([running, [check(CODE_RUN, 1, conclusion="failure")]])
        self.assertEqual(rc, 1)
        self.assertIn("concluded 'failure'", out)

    def test_a_suite_still_running_at_the_deadline_fails(self):
        rc, clock, out = run_mirror([[check(CODE_RUN, 1, status="in_progress")]], wait=60, poll=15)
        self.assertEqual(rc, 1)
        self.assertGreaterEqual(clock.now, 60)
        self.assertIn("no verdict after", out)

    def test_a_head_with_no_suite_fails_after_the_short_wait_not_the_long_one(self):
        rc, clock, out = run_mirror([[SKIPPED]], wait=1500, appear=180, poll=15)
        self.assertEqual(rc, 1)
        self.assertLess(clock.now, 300)
        self.assertIn("no suite has run on this head", out)

    def test_a_suite_that_appears_inside_the_short_wait_is_followed(self):
        rc, _, _ = run_mirror([[SKIPPED], [SKIPPED], [check(CODE_RUN, 1, status="queued")], [check(CODE_RUN, 1)]])
        self.assertEqual(rc, 0)

    def test_a_cancelled_suite_with_no_successor_fails(self):
        rc, clock, out = run_mirror([[check(CODE_RUN, 1, conclusion="cancelled")]])
        self.assertEqual(rc, 1)
        self.assertLess(clock.now, 300)
        self.assertIn("cancelled", out)

    def test_a_cancelled_suite_replaced_by_a_reopen_follows_the_replacement(self):
        cancelled = check(CODE_RUN, 1, conclusion="cancelled")
        rc, _, _ = run_mirror([[cancelled], [cancelled, check(CODE_RUN + 5, 2, status="queued")],
                               [cancelled, check(CODE_RUN + 5, 2, conclusion="failure")]])
        self.assertEqual(rc, 1)
        rc, _, _ = run_mirror([[cancelled], [cancelled, check(CODE_RUN + 5, 2)]])
        self.assertEqual(rc, 0)

    def test_a_read_that_keeps_failing_is_never_a_pass(self):
        rc, clock, out = run_mirror([vm.ReadError("check-runs read failed: 502")], wait=60, poll=15)
        self.assertEqual(rc, 1)
        self.assertGreaterEqual(clock.now, 60)
        self.assertIn("502", out)

    def test_one_failed_read_does_not_fail_a_green_head(self):
        rc, _, _ = run_mirror([vm.ReadError("check-runs read failed: 502"), [check(CODE_RUN, 1)]])
        self.assertEqual(rc, 0)

    def test_an_already_green_head_passes_without_sleeping(self):
        rc, clock, _ = run_mirror([[check(CODE_RUN, 1), SKIPPED]])
        self.assertEqual((rc, clock.sleeps), (0, 0))


LEGACY_RUN = 42455765843  # hydra#1856: validated 2026-11-08, before the validate / validate-code split


class LegacyHeadTests(unittest.TestCase):
    """A head validated before #1851 has no `validate-code`: its suite is named `validate`."""

    def legacy(self, **kw):
        return check(LEGACY_RUN, 1, name="validate", **kw)

    def mirror_of(self, run, cid, **kw):
        # A post-split metadata-edit run: skipped placeholder plus its own `validate`.
        return [check(run, cid, conclusion="skipped"), check(run, cid + 1, name="validate", **kw)]

    def test_a_green_pre_split_suite_is_mirrored(self):
        # 131 of 192 open heads on 2026-11-13. Without this, any body edit turned them red.
        self.assertEqual(vm.decide([self.legacy()])[0], "pass")
        self.assertEqual(vm.decide([self.legacy()] + self.mirror_of(META_RUN, 10, status="in_progress"))[0], "pass")

    def test_a_failed_or_running_pre_split_suite_is_mirrored_as_such(self):
        self.assertEqual(vm.decide([self.legacy(conclusion="failure")])[0], "fail")
        self.assertEqual(vm.decide([self.legacy(status="in_progress")])[0], "wait")
        self.assertEqual(vm.decide([self.legacy(conclusion="skipped")])[0], "none")

    def test_a_mirror_never_vouches_for_a_mirror(self):
        # Only mirrors on the head, one of them green: there is still no suite.
        checks = self.mirror_of(CODE_RUN, 10) + self.mirror_of(META_RUN, 20, status="in_progress")
        self.assertEqual(vm.decide(checks)[0], "none")

    def test_a_green_mirror_does_not_outrank_a_failed_pre_split_suite(self):
        checks = [self.legacy(conclusion="failure")] + self.mirror_of(META_RUN, 10)
        self.assertEqual(vm.decide(checks)[0], "fail")

    def test_a_real_validate_code_always_outranks_a_pre_split_validate(self):
        # Retargeted or reopened after the split: the new suite failed, the old green must not count.
        checks = [self.legacy(), check(META_RUN, 30, conclusion="failure"), check(META_RUN, 31, name="validate", conclusion="failure")]
        self.assertEqual(vm.decide(checks)[0], "fail")
        running = [self.legacy(), check(META_RUN, 30, status="in_progress")]
        self.assertEqual(vm.decide(running)[0], "wait")

    def test_a_validate_with_no_run_id_or_from_another_app_is_not_a_suite(self):
        bare = dict(self.legacy(), details_url="https://example.invalid/x")
        self.assertEqual(vm.decide([bare])[0], "none")
        self.assertEqual(vm.decide([check(LEGACY_RUN, 1, name="validate", app="some-app")])[0], "none")

    def test_both_names_are_fetched(self):
        with open(SCRIPT, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("_fetch(repo, sha, token, api, CODE_CHECK) + _fetch(repo, sha, token, api, LEGACY_CHECK)", src)


def wf(run, status="completed", conclusion="success", path=".github/workflows/pr-validate.yml"):
    """One entry of the Actions run listing for the head."""
    return {"id": run, "status": status, "conclusion": conclusion if status == "completed" else None, "path": path}


class NewerRunTests(unittest.TestCase):
    """A retarget onto main or a close/reopen starts a NEW validation of the same head sha.

    Its run is listed a few seconds before its `validate-code` job is. An edit landing in that gap
    found only the old green suite, this job went green, and being the newest run's `validate` it
    outranked whatever the new validation concluded (QA review of hydra#1935, Critical).
    """

    OLD, NEW, EDIT = 43343801217, 43344100000, 43344100339  # old suite < the new validation < this edit run
    GREEN = check(OLD, 1)

    def runs(self, **new):
        return [wf(self.OLD), wf(self.NEW, **new), wf(self.EDIT, status="in_progress")]

    def test_an_old_green_is_not_reported_while_a_newer_run_has_not_posted_its_suite(self):
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            state, why = vm.decide([self.GREEN], self.runs(status=status), self.EDIT)
            self.assertEqual(state, "wait", status)
            self.assertIn(str(self.NEW), why)

    def test_the_new_validation_is_followed_to_its_failure(self):
        gap = ([self.GREEN], self.runs(status="queued"))
        started = ([self.GREEN, check(self.NEW, 2, status="in_progress")], self.runs(status="in_progress"))
        failed = ([self.GREEN, check(self.NEW, 2, conclusion="failure")], self.runs(status="in_progress"))
        rc, clock, out = run_mirror([gap, gap, started, started, failed], own=self.EDIT)
        self.assertEqual(rc, 1)
        self.assertIn(f"validate-code of run {self.NEW} concluded 'failure'", out)
        self.assertNotIn("succeeded", out)

    def test_the_new_validation_is_followed_to_its_success(self):
        gap = ([self.GREEN], self.runs(status="queued"))
        passed = ([self.GREEN, check(self.NEW, 2)], self.runs(status="in_progress"))
        rc, clock, out = run_mirror([gap, gap, passed], own=self.EDIT)
        self.assertEqual(rc, 0)
        self.assertIn(f"validate-code of run {self.NEW} succeeded", out)
        self.assertEqual(clock.sleeps, 2)

    def test_a_newer_run_that_never_posts_fails_at_the_deadline(self):
        rc, clock, out = run_mirror([([self.GREEN], self.runs(status="queued"))], own=self.EDIT)
        self.assertEqual(rc, 1)
        self.assertGreaterEqual(clock.now, 1500)

    def test_a_first_validation_that_is_listed_but_has_no_job_yet_gets_the_long_wait(self):
        # No suite on the head at all, but its run exists: that is a wait, not "this head has none".
        first = [wf(self.NEW, status="queued"), wf(self.EDIT, status="in_progress")]
        self.assertEqual(vm.decide([], first, self.EDIT)[0], "wait")
        rc, clock, _ = run_mirror([([], first)] * 20 + [([check(self.NEW, 2)], first)], own=self.EDIT)
        self.assertEqual(rc, 0)
        self.assertGreater(clock.now, 180)

    def test_this_run_is_never_waited_for(self):
        # This job runs inside EDIT; its own run is in progress by definition.
        runs = [wf(self.OLD), wf(self.EDIT, status="in_progress")]
        self.assertEqual(vm.decide([self.GREEN], runs, self.EDIT)[0], "pass")
        self.assertEqual(vm.decide([self.GREEN], runs, 0)[0], "wait")  # ...and only because it is told which it is

    def test_a_run_that_posted_a_placeholder_is_another_edit_not_a_validation(self):
        other_edit = check(self.NEW, 2, conclusion="skipped")
        self.assertEqual(vm.decide([self.GREEN, other_edit], self.runs(status="in_progress"), self.EDIT)[0], "pass")

    def test_a_run_older_than_the_suite_is_not_waited_for(self):
        newer_suite = check(self.NEW, 2)
        runs = [wf(self.OLD, status="in_progress"), wf(self.NEW), wf(self.EDIT, status="in_progress")]
        self.assertEqual(vm.decide([newer_suite], runs, self.EDIT)[0], "pass")

    def test_a_cancelled_or_skipped_run_that_posted_nothing_leaves_the_head_as_it_was(self):
        # Two edits a second apart: the first edit's run is cancelled before it lists a job. Failing
        # on it would leave the head red for good, since that run never changes again.
        for conclusion in ("cancelled", "skipped"):
            state, why = vm.decide([self.GREEN], self.runs(conclusion=conclusion), self.EDIT)
            self.assertEqual(state, "pass", conclusion)
            self.assertIn(str(self.OLD), why)

    def test_a_run_that_ended_any_other_way_without_a_suite_is_never_a_pass(self):
        for conclusion in ("failure", "startup_failure", "timed_out", "action_required", "success", None):
            late = self.runs(conclusion=conclusion)
            self.assertEqual(vm.decide([self.GREEN], late, self.EDIT)[0], "none", conclusion)
            rc, clock, out = run_mirror([([self.GREEN], late)], own=self.EDIT)
            self.assertEqual(rc, 1)
            self.assertIn("without a suite", out)

    def test_another_apps_check_does_not_speak_for_a_run(self):
        forged = check(self.NEW, 2, app="some-other-app")
        self.assertEqual(vm.decide([self.GREEN, forged], self.runs(status="queued"), self.EDIT)[0], "wait")

    def test_a_failed_older_suite_still_fails_when_no_run_is_pending(self):
        self.assertEqual(vm.decide([check(self.OLD, 1, conclusion="failure")], self.runs(conclusion="cancelled"), self.EDIT)[0], "fail")


class ReadTests(unittest.TestCase):
    """What the mirror asks GitHub, with the HTTP layer replaced."""

    def setUp(self):
        self.calls = []
        self.pages = {}
        self._pages = vm._pages
        vm._pages = self.fake_pages

    def tearDown(self):
        vm._pages = self._pages

    def fake_pages(self, url, token, key):
        self.calls.append(key)
        answer = self.pages.get(key, [])
        if isinstance(answer, Exception):
            raise answer
        return answer

    def test_only_runs_of_this_workflow_are_listed(self):
        self.pages["workflow_runs"] = [wf(1), wf(2, path=".github/workflows/pr-title-check.yml"), wf(3, path=None)]
        self.assertEqual([r["id"] for r in vm.fetch_runs("o/r", "sha", "t")], [1])

    def test_the_run_listing_asks_for_this_head_and_pull_request_runs(self):
        seen = []
        vm._pages = lambda url, token, key: seen.append(url) or []
        vm.fetch_runs("o/r", "abc123", "t")
        self.assertEqual(seen, ["https://api.github.com/repos/o/r/actions/runs?head_sha=abc123&event=pull_request"])

    def test_the_workflow_path_is_this_workflow(self):
        self.assertTrue(WORKFLOW.endswith(vm.WORKFLOW_PATH))

    def test_checks_are_read_before_runs(self):
        # A run that starts between the two reads is then listed with no check, and waited for.
        vm.fetch_head("o/r", "sha", "t")
        self.assertEqual(self.calls, ["check_runs", "check_runs", "workflow_runs"])

    def test_an_unreadable_run_listing_is_not_an_empty_one(self):
        self.pages["check_runs"] = [check(1, 1)]
        self.pages["workflow_runs"] = vm.ReadError("workflow_runs read failed: HTTP Error 403: Forbidden")
        with self.assertRaises(vm.ReadError):
            vm.fetch_head("o/r", "sha", "t")
        rc, clock, out = run_mirror([vm.ReadError("workflow_runs read failed: HTTP Error 403: Forbidden")])
        self.assertEqual(rc, 1)
        self.assertNotIn("succeeded", out)

    def test_main_reads_runs_as_well_as_checks_and_says_which_run_it_is(self):
        with open(SCRIPT, encoding="utf-8") as fh:
            src = fh.read()
        main = src[src.index("def main()") :]
        self.assertIn("lambda: fetch_head(args.repo, args.sha, token)", main)
        self.assertIn("own=args.run_id", main)
        self.assertNotIn("fetch_check_runs", main)


class HttpTests(unittest.TestCase):
    """A read GitHub refused is an error, never an empty answer (a 403 on the run listing is what a
    missing `actions: read` looks like, and an empty listing would read as "no newer run")."""

    def setUp(self):
        self._urlopen = vm.urllib.request.urlopen
        self.urls = []

    def tearDown(self):
        vm.urllib.request.urlopen = self._urlopen

    def answer(self, *bodies):
        import io

        queue = list(bodies)

        def urlopen(req, timeout=None):
            self.urls.append(req.full_url)
            body = queue.pop(0)
            if isinstance(body, Exception):
                raise body
            return io.BytesIO(json.dumps(body).encode())

        vm.urllib.request.urlopen = urlopen

    def test_a_refused_read_raises(self):
        import urllib.error

        self.answer(urllib.error.HTTPError("u", 403, "Forbidden", {}, None))
        with self.assertRaises(vm.ReadError):
            vm.fetch_runs("o/r", "sha", "t")

    def test_an_answer_without_the_list_raises(self):
        for body in ({"message": "Resource not accessible by integration"}, [], {"workflow_runs": None}):
            self.answer(body)
            with self.assertRaises(vm.ReadError):
                vm.fetch_runs("o/r", "sha", "t")

    def test_every_page_is_read(self):
        self.answer({"workflow_runs": [wf(i) for i in range(100)]}, {"workflow_runs": [wf(100)]})
        self.assertEqual(len(vm.fetch_runs("o/r", "sha", "t")), 101)
        self.assertEqual([u.rsplit("&", 1)[1] for u in self.urls], ["page=1", "page=2"])


class WorkflowWiringTests(unittest.TestCase):
    """The `validate` job is the required check. Pin how it calls the mirror."""

    @classmethod
    def setUpClass(cls):
        with open(WORKFLOW, encoding="utf-8") as fh:
            text = fh.read()
        start = text.index("\n  validate:\n")
        cls.job = text[start : text.index("\n  validate-code:\n", start)]

    def test_the_required_check_keeps_its_exact_name_and_always_posts(self):
        self.assertIn("\n    name: validate\n", self.job)
        self.assertIn("\n    if: always()\n", self.job)
        self.assertIn("needs: [validate-code]", self.job)

    def test_a_skipped_suite_goes_to_the_mirror_and_nowhere_else(self):
        self.assertIn("python3 scripts/ci/validate-mirror.py", self.job)
        skipped = self.job[self.job.index("skipped)") :]
        branch = skipped[: skipped.index(";;")]
        self.assertIn("validate-mirror.py", branch)
        self.assertNotIn("exit 0", branch)

    def test_the_mirror_is_told_its_run_and_may_list_runs(self):
        self.assertIn('validate-mirror.py --repo "$REPO" --sha "$SHA" --run-id "$GITHUB_RUN_ID"', self.job)
        perms = self.job[self.job.index("\n    permissions:\n") : self.job.index("\n    steps:\n")]
        granted = dict(re.findall(r"^      ([a-z-]+): (\w+)$", perms, flags=re.M))
        self.assertEqual(granted, {"actions": "read", "checks": "read", "contents": "read"})

    def test_only_success_exits_zero_without_the_mirror(self):
        body = self.job[self.job.index('case "$RESULT" in') :]
        arms = re.findall(r"^\s+([a-z*|]+)\)\n(.*?);;", body, flags=re.S | re.M)
        self.assertEqual([a for a, _ in arms], ["success", "skipped", "*"])
        self.assertIn("exit 1", dict(arms)["*"])

    def test_the_job_outlives_the_mirrors_longest_wait(self):
        minutes = int(re.search(r"timeout-minutes: (\d+)", self.job).group(1))
        self.assertGreater(minutes * 60, vm.WAIT_SECONDS + 120)

    def test_the_mirror_waits_at_least_as_long_as_the_suite_may_run(self):
        with open(WORKFLOW, encoding="utf-8") as fh:
            text = fh.read()
        start = text.index("\n  validate-code:\n")
        suite = text[start : text.index("\n    steps:\n", start)]
        suite_minutes = int(re.search(r"timeout-minutes: (\d+)", suite).group(1))
        self.assertGreaterEqual(vm.WAIT_SECONDS, suite_minutes * 60)

    def test_the_mirror_script_is_checked_out_only_for_a_skipped_suite(self):
        checkout = self.job[self.job.index("actions/checkout") - 200 : self.job.index("actions/checkout") + 400]
        self.assertIn("needs.validate-code.result == 'skipped'", checkout)
        self.assertIn("scripts/ci/validate-mirror.py", checkout)


if __name__ == "__main__":
    unittest.main()
