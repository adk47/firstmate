#!/usr/bin/env python3
"""Tests for scripts/pr-doctor.py.

What must hold: it only ever proposes a RE-RUN as something it will perform (a re-run reports what
is true, it cannot fabricate a pass); a retarget, a rebase and a body edit are printed for the
owner and never applied; and it reads a head the way GitHub does (newest workflow run decides).
Stdlib only.
"""
import importlib.util
import json
import os
import unittest
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "pr-doctor.py")

_spec = importlib.util.spec_from_file_location("pr_doctor", SCRIPT)
doc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(doc)

NOW = datetime(2026, 11, 13, 3, 0, tzinfo=timezone.utc)
SUITE_RUN, EDIT_RUN = 43075293658, 43075294616  # hydra#1887: the edit run is the newer one


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


def pr(base="main", mergeable=True):
    return {"number": 1887, "base": base, "mergeable": mergeable, "sha": "898e5d1b9", "body": ""}


def poisoned():
    return [
        check("validate-code", SUITE_RUN, 1),
        check("validate", SUITE_RUN, 4),  # newer check run, older workflow run
        check("validate-code", EDIT_RUN, 2, conclusion="skipped"),
        check("validate", EDIT_RUN, 3, conclusion="failure"),
    ]


def kinds(steps):
    return [s["kind"] for s in steps]


class PlanTests(unittest.TestCase):
    def test_a_green_head_needs_nothing(self):
        checks = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2)]
        self.assertEqual(doc.plan_pr(pr(), checks, [], NOW), [])

    def test_a_poisoned_head_gets_one_rerun_of_the_edit_run_not_the_suite(self):
        steps = doc.plan_pr(pr(), poisoned(), [], NOW)
        self.assertEqual(kinds(steps), ["rerun"])
        self.assertEqual(steps[0]["run"], EDIT_RUN)
        self.assertIn("the head IS validated", steps[0]["why"])

    def test_a_failed_suite_is_never_rerun_blind_and_never_called_validated(self):
        checks = [
            check("validate-code", SUITE_RUN, 1, conclusion="failure"),
            check("validate", SUITE_RUN, 2, conclusion="failure"),
        ]
        steps = doc.plan_pr(pr(), checks, [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("--log-failed", steps[0]["do"])
        self.assertIn("gh pr reopen", steps[0]["do"])
        self.assertNotIn("IS validated", steps[0]["why"])
        self.assertNotIn("commit --allow-empty", steps[0]["do"])

    def test_an_interrupted_suite_is_rerun_in_place(self):
        for how in ("cancelled", "timed_out"):
            checks = [
                check("validate-code", SUITE_RUN, 1, conclusion=how),
                check("validate", SUITE_RUN, 2, conclusion="failure"),
            ]
            steps = doc.plan_pr(pr(), checks, [], NOW)
            self.assertEqual(kinds(steps), ["rerun"], how)
            self.assertEqual(steps[0]["run"], SUITE_RUN)
            self.assertNotIn("IS validated", steps[0]["why"])

    def test_an_interrupted_suite_under_a_newer_edit_run_is_rerun_first(self):
        checks = [
            check("validate-code", SUITE_RUN, 1, conclusion="cancelled"),
            check("validate", SUITE_RUN, 4, conclusion="failure"),
            check("validate-code", EDIT_RUN, 2, conclusion="skipped"),
            check("validate", EDIT_RUN, 3, conclusion="failure"),
        ]
        steps = doc.plan_pr(pr(), checks, [], NOW)
        self.assertEqual(kinds(steps), ["rerun", "then"])
        self.assertEqual(steps[0]["run"], SUITE_RUN)
        self.assertIn(str(EDIT_RUN), steps[1]["do"])

    def test_a_running_suite_is_waited_for(self):
        checks = [
            check("validate-code", SUITE_RUN, 1, status="in_progress"),
            check("validate-code", EDIT_RUN, 2, conclusion="skipped"),
            check("validate", EDIT_RUN, 3, conclusion="failure"),
        ]
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW)), ["wait"])

    def test_on_a_head_validated_before_the_split_validate_is_the_suite(self):
        steps = doc.plan_pr(pr(), [check("validate", SUITE_RUN, 1, conclusion="failure")], [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn(str(SUITE_RUN), steps[0]["do"])
        steps = doc.plan_pr(pr(), [check("validate", SUITE_RUN, 1, conclusion="cancelled")], [], NOW)
        self.assertEqual(kinds(steps), ["rerun"])
        self.assertEqual(steps[0]["run"], SUITE_RUN)

    def test_an_edit_run_with_no_suite_at_all_is_not_a_rerun(self):
        checks = [check("validate-code", EDIT_RUN, 2, conclusion="skipped"), check("validate", EDIT_RUN, 3, conclusion="failure")]
        steps = doc.plan_pr(pr(), checks, [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("gh pr reopen", steps[0]["do"])

    def test_a_green_validate_under_a_newer_run_that_posted_none_is_named(self):
        # hydra#1856: validated 2026-11-08 06:41, three later edit runs skipped whole. BLOCKED for 5 days.
        checks = [check("validate", 42455765843, 1)]
        steps = doc.plan_pr(pr(), checks, [], NOW, [42455765843, 42458448059, 42472033262])
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("42472033262", steps[0]["why"])
        self.assertEqual(doc.plan_pr(pr(), checks, [], NOW, [42455765843]), [])

    def test_a_head_whose_validation_is_running_is_never_told_to_reopen(self):
        # hydra#1935 at 08:48Z, a minute after a push: `validate` needs the suite, so it is not listed
        # until the suite ends, and the plan said "no validation ever ran: close and reopen".
        for status in ("queued", "in_progress"):
            steps = doc.plan_pr(pr(), [check("validate-code", SUITE_RUN, 1, status=status, conclusion=None)], [], NOW,
                                [SUITE_RUN], running_runs=[SUITE_RUN])
            self.assertEqual(kinds(steps), ["wait"], status)
            self.assertIn(str(SUITE_RUN), steps[0]["why"])
            self.assertNotIn("reopen", steps[0]["do"])
            # the check alone says so, whatever the run listing has caught up with
            alone = doc.plan_pr(pr(), [check("validate-code", SUITE_RUN, 1, status=status, conclusion=None)], [], NOW, [SUITE_RUN])
            self.assertEqual(kinds(alone), ["wait"], status)
        # the suite has ended and its `validate` job is seconds from being listed
        for conclusion in ("success", "failure"):
            ended = [check("validate-code", SUITE_RUN, 1, conclusion=conclusion)]
            steps = doc.plan_pr(pr(), ended, [], NOW, [SUITE_RUN], running_runs=[SUITE_RUN])
            self.assertEqual(kinds(steps), ["wait"], conclusion)
        # the suite's whole run is over and `validate` never came: that is not a wait
        over = lambda how: doc.plan_pr(pr(), [check("validate-code", SUITE_RUN, 1, conclusion=how)], [], NOW, [SUITE_RUN])
        self.assertEqual(kinds(over("cancelled")), ["rerun"])
        self.assertEqual(over("cancelled")[0]["run"], SUITE_RUN)
        self.assertEqual(kinds(over("failure")), ["manual"])
        self.assertIn("--log-failed", over("failure")[0]["do"])
        # the run exists and has listed no job at all yet
        steps = doc.plan_pr(pr(), [], [], NOW, [SUITE_RUN], running_runs=[SUITE_RUN])
        self.assertEqual(kinds(steps), ["wait"])
        self.assertIn(str(SUITE_RUN), steps[0]["why"])
        # a run that completed and posted nothing is not running: that head does need a validation
        steps = doc.plan_pr(pr(), [], [], NOW, [SUITE_RUN])
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("gh pr reopen", steps[0]["do"])
        # an edit run's skipped placeholder is not a suite
        steps = doc.plan_pr(pr(), [check("validate-code", EDIT_RUN, 3, conclusion="skipped")], [], NOW, [EDIT_RUN])
        self.assertEqual(kinds(steps), ["manual"])

    def test_a_reopened_head_waits_for_its_new_validation_instead_of_an_edit(self):
        # A reopen or a retarget validates the same head again; until that run posts, the old green is listed.
        checks = [check("validate", SUITE_RUN, 1)]
        steps = doc.plan_pr(pr(), checks, [], NOW, [SUITE_RUN, EDIT_RUN], running_runs=[EDIT_RUN])
        self.assertEqual(kinds(steps), ["wait"])
        self.assertIn(str(EDIT_RUN), steps[0]["why"])
        self.assertNotIn("edit the PR", steps[0]["do"])
        # the same newer run, completed with nothing posted, is the pre-split whole-run skip: still named
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW, [SUITE_RUN, EDIT_RUN])), ["manual"])
        # an older run still running says nothing about the newest one
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW, [SUITE_RUN - 5, SUITE_RUN, EDIT_RUN], running_runs=[SUITE_RUN - 5])), ["manual"])

    def test_no_validation_at_all_says_reopen_not_empty_commit(self):
        steps = doc.plan_pr(pr(), [], [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("gh pr reopen", steps[0]["do"])
        self.assertNotIn("commit --allow-empty", steps[0]["do"])

    def test_a_wrong_base_is_named_and_never_applied(self):
        steps = doc.plan_pr(pr(base="fm/some-lane"), poisoned(), [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("--base main", steps[0]["do"])

    def test_unmeasured_mergeability_is_not_mergeable(self):
        steps = doc.plan_pr(pr(mergeable=None), poisoned(), [], NOW)
        self.assertEqual(kinds(steps), ["unknown"])

    def test_a_conflict_gets_no_rerun(self):
        steps = doc.plan_pr(pr(mergeable=False), poisoned(), [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("rebase", steps[0]["do"])

    def test_a_run_older_than_thirty_days_is_not_offered_as_a_rerun(self):
        old = NOW - timedelta(days=31)
        checks = [
            check("validate-code", SUITE_RUN, 1, started=old),
            check("validate", SUITE_RUN, 4, started=old),
            check("validate-code", EDIT_RUN, 2, conclusion="skipped", started=old),
            check("validate", EDIT_RUN, 3, conclusion="failure", started=old),
        ]
        steps = doc.plan_pr(pr(), checks, [], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("older than 30 days", steps[0]["why"])

    def test_a_stale_guard_red_is_a_rerun_only_when_the_body_passes(self):
        checks = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2),
                  check("credit-approval-guard", 500, 9, conclusion="failure")]
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW)), ["rerun"])
        steps = doc.plan_pr(pr(), checks, ["section must give a measured AFTER value"], NOW)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("dry run", steps[0]["do"])

    def test_a_newer_guard_success_outranks_an_older_failure(self):
        checks = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2),
                  check("credit-approval-guard", 500, 9, conclusion="failure"),
                  check("credit-approval-guard", 600, 8)]
        self.assertEqual(doc.plan_pr(pr(), checks, [], NOW), [])

    # hydra#1935, 2026-11-13T05:51:53Z: a body edit and a review landed in the same second. The
    # guard's two events share a concurrency group, so the review's run cancelled the edit's.
    GREEN = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2)]

    @staticmethod
    def guard(run, cid, event, conclusion, minutes_ago=120):
        """One guard check and the run that names its event."""
        return (check("credit-approval-guard", run, cid, conclusion=conclusion, started=NOW - timedelta(minutes=minutes_ago)),
                {"id": run, "event": event})

    def plan_guard(self, *pairs, body_problems=()):
        checks = self.GREEN + [c for c, _ in pairs]
        return doc.plan_pr(pr(), checks, list(body_problems), NOW, guard_runs=[r for _, r in pairs])

    def test_a_cancelled_guard_run_beside_the_other_events_green_is_rerun(self):
        steps = self.plan_guard(self.guard(43374784650, 1, "pull_request_target", "cancelled"),
                                self.guard(43374833406, 2, "pull_request_review", "success", minutes_ago=119))
        self.assertEqual(kinds(steps), ["rerun"])
        self.assertEqual(steps[0]["run"], 43374784650)
        self.assertIn("never gave a verdict", steps[0]["why"])

    def test_a_cancelled_guard_run_replaced_on_its_own_event_holds_nothing(self):
        steps = self.plan_guard(self.guard(100, 1, "pull_request_target", "cancelled", minutes_ago=120),
                                self.guard(200, 2, "pull_request_target", "success", minutes_ago=110),
                                self.guard(150, 3, "pull_request_review", "success", minutes_ago=115))
        self.assertEqual(steps, [])

    def test_the_guard_check_that_started_last_speaks_for_its_event(self):
        # hydra#1768: an OLDER review run was re-run later and cancelled. `gh pr checks`, which the
        # merge queue reads, lists that one, not the newer run id.
        steps = self.plan_guard(self.guard(41937209986, 1, "pull_request_review", "success", minutes_ago=30),
                                self.guard(41928214820, 2, "pull_request_review", "cancelled", minutes_ago=10))
        self.assertEqual([(s["kind"], s["run"]) for s in steps], [("rerun", 41928214820)])

    def test_each_guard_event_is_read_by_itself(self):
        # The other event's newer green does not clear this event's red (`gh pr checks` lists both).
        steps = self.plan_guard(self.guard(100, 1, "pull_request_target", "failure", minutes_ago=120),
                                self.guard(200, 2, "pull_request_review", "success", minutes_ago=60))
        self.assertEqual([(s["kind"], s["run"]) for s in steps], [("rerun", 100)])

    def test_a_guard_the_body_fails_is_one_edit_and_no_rerun(self):
        steps = self.plan_guard(self.guard(100, 1, "pull_request_target", "failure"),
                                self.guard(200, 2, "pull_request_review", "cancelled"),
                                body_problems=["no section"])
        self.assertEqual(kinds(steps), ["manual"])

    def test_only_reruns_carry_a_run_to_apply(self):
        for steps in (
            doc.plan_pr(pr(base="x"), poisoned(), [], NOW),
            doc.plan_pr(pr(mergeable=False), poisoned(), [], NOW),
            doc.plan_pr(pr(mergeable=None), poisoned(), [], NOW),
            doc.plan_pr(pr(), [], ["no section"], NOW),
        ):
            for s in steps:
                self.assertNotEqual(s["kind"], "rerun")
                self.assertNotIn("run", s)


def row(name, bucket="pass", run=SUITE_RUN, started=NOW - timedelta(hours=2)):
    """One row of `gh pr checks --json name,bucket,link,startedAt`."""
    link = f"https://github.com/Muso-AI/hydra/actions/runs/{run}/job/7" if run else "https://github.com/Muso-AI/hydra/pull/1887#pullrequestreview-1"
    return {"name": name, "bucket": bucket, "link": link, "startedAt": started.isoformat().replace("+00:00", "Z")}


class QueueTests(unittest.TestCase):
    """The merge queue holds on ANY check that is not a pass or a skip, and on QA. A plan that
    reads `validate` and the guard only called hydra#1935 clear at 06:09Z on 2026-11-13 with three
    Bats shards still running (QA review of that PR)."""

    GREEN = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2)]
    QUEUE_GREEN = [row("validate"), row("validate-code", "skipping"), row("pr-title"),
                   row("Bats (scripts/ + ops-admin gates) (1/4)"), row("qa-review", run=0)]

    def plan(self, queue):
        return doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue)

    def swap(self, name, **kw):
        return [row(name, **kw) if r["name"] == name else r for r in self.QUEUE_GREEN]

    def test_every_check_green_and_qa_passed_is_clear(self):
        self.assertEqual(self.plan(self.QUEUE_GREEN), [])

    def test_a_running_bats_shard_is_a_wait_not_clear(self):
        steps = self.plan(self.swap("Bats (scripts/ + ops-admin gates) (1/4)", bucket="pending"))
        self.assertEqual(kinds(steps), ["wait"])
        self.assertIn("Bats", steps[0]["why"])

    def test_a_failed_job_that_is_not_required_still_holds_and_is_never_rerun_blind(self):
        steps = self.plan(self.swap("Bats (scripts/ + ops-admin gates) (1/4)", bucket="fail"))
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("--log-failed", steps[0]["do"])

    def test_a_cancelled_job_is_rerun_once_per_run(self):
        queue = self.QUEUE_GREEN + [row("Shellcheck", "cancel"), row("Plugin tests (vitest)", "cancel")]
        queue = [r if r["name"] != "Bats (scripts/ + ops-admin gates) (1/4)" else row(r["name"], "cancel") for r in queue]
        steps = self.plan(queue)
        self.assertEqual([(s["kind"], s["run"]) for s in steps], [("rerun", SUITE_RUN)])

    def test_a_red_title_is_named_as_the_title(self):
        steps = self.plan(self.swap("pr-title", bucket="fail"))
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("--title", steps[0]["do"])

    def test_a_qa_no_go_is_never_a_rerun(self):
        steps = self.plan(self.swap("qa-review", bucket="fail", run=0))
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("NO-GO", steps[0]["why"])

    def test_one_failing_qa_verdict_outranks_a_passing_one(self):
        steps = self.plan(self.QUEUE_GREEN + [row("qa-review", "fail", run=0)])
        self.assertEqual(kinds(steps), ["manual"])

    def test_no_qa_verdict_with_nothing_running_names_the_redispatch(self):
        steps = self.plan([r for r in self.QUEUE_GREEN if r["name"] != "qa-review"])
        self.assertEqual(kinds(steps), ["manual"])
        self.assertIn("qa-autoreview.yml", steps[0]["do"])
        self.assertIn("sha=898e5d1b9", steps[0]["do"])

    def test_no_qa_verdict_while_the_suite_runs_is_only_a_wait(self):
        queue = [r for r in self.swap("Bats (scripts/ + ops-admin gates) (1/4)", bucket="pending") if r["name"] != "qa-review"]
        steps = self.plan(queue)
        self.assertEqual(kinds(steps), ["wait", "wait"])
        self.assertNotIn("qa-autoreview.yml", " ".join(s["do"] for s in steps))

    def test_validate_and_the_guard_are_not_planned_twice(self):
        # Their steps come from the check runs; the red queue row adds no second one.
        red = [check("validate-code", SUITE_RUN, 1, conclusion="failure"), check("validate", SUITE_RUN, 2, conclusion="failure"),
               check("credit-approval-guard", EDIT_RUN, 3, conclusion="failure")]
        queue = [r for r in self.QUEUE_GREEN if r["name"] != "validate"] + [row("credit-approval-guard", "fail"), row("validate", "fail")]
        self.assertEqual(kinds(doc.plan_pr(pr(), red, [], NOW, queue=queue)), ["manual", "rerun"])

    def test_a_red_row_the_check_runs_do_not_show_is_unknown_never_clear(self):
        # The two readings can disagree: the check runs are ranked by run id, `gh pr checks` by
        # start time, and a re-run of an older run starts later. This test used to expect [].
        queue = [r for r in self.QUEUE_GREEN if r["name"] != "validate"] + [row("credit-approval-guard", "fail"), row("validate", "fail")]
        steps = self.plan(queue)
        self.assertEqual(kinds(steps), ["unknown"])
        self.assertIn("credit-approval-guard", steps[0]["why"])
        self.assertIn("validate", steps[0]["why"])
        self.assertIn("gh pr checks", steps[0]["do"])

    def test_the_cli_always_reads_the_queue_before_it_calls_a_head_clear(self):
        with open(SCRIPT, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("validation_runs, guard_runs, read_queue(n),\n                        suite_jobs, running_runs)", src)
        self.assertIn("pr, checks, validation_runs, guard_runs, suite_jobs, running_runs = fetch_pr(n)", src)
        self.assertIn("/actions/runs/{suite_run(checks)}/jobs?filter=latest", src)
        self.assertIn(".workflow_runs[] | {id, name, event, status}", src)  # no status, no "still running"
        self.assertNotIn("nothing in CI is holding", src)

    def test_the_output_of_gh_pr_checks_decides_not_its_exit_status(self):
        rows = doc.parse_queue('[{"name": "validate", "bucket": "pending"}]', "")
        self.assertEqual(rows[0]["bucket"], "pending")
        self.assertEqual(doc.parse_queue("", "no checks reported on the 'x' branch"), [])

    def test_an_unreadable_queue_is_an_error_never_no_checks(self):
        for out, err in (("", ""), ("", "HTTP 502"), ("not json", ""), ('{"message": "x"}', ""), ('[{"name": "x"}]', "")):
            with self.assertRaises(RuntimeError):
                doc.parse_queue(out, err)


def job(name, status="completed", conclusion="success", run=SUITE_RUN):
    """One job of the suite's run, as `actions/runs/<run>/jobs` lists it."""
    return {"name": name, "status": status, "conclusion": conclusion if status == "completed" else None,
            "started_at": (NOW - timedelta(hours=2)).isoformat().replace("+00:00", "Z"),
            "html_url": f"https://github.com/Muso-AI/hydra/actions/runs/{run}/job/9"}


class ClearIsPositiveTests(unittest.TestCase):
    """`plan` says clear only when the merge queue's own view is green, never because no rule
    fired. Bats running (head 2), a suite job behind an edit's skip (head 5) and a guard in
    progress (head 6) each fell through the rules of the day and read as clear on hydra#1935."""

    GREEN = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2)]
    QUEUE = [row("validate"), row("validate-code", "skipping"), row("pr-title"), row("Shellcheck"), row("qa-review", run=0)]

    def test_green_is_green(self):
        self.assertEqual(doc.not_green(self.QUEUE), [])
        self.assertEqual(doc.plan_pr(pr(), self.GREEN, [], NOW, queue=self.QUEUE), [])

    def test_every_bucket_but_pass_and_skipping_is_not_green_for_every_name(self):
        for name in ("validate", "validate-code", "credit-approval-guard", "pr-title", "Shellcheck", "a check nobody has a rule for"):
            for bucket in ("pending", "fail", "cancel", "", "some bucket gh adds next year"):
                queue = [r for r in self.QUEUE if r["name"] != name] + [row(name, bucket)]
                self.assertEqual(doc.not_green(queue), [name], (name, bucket))
                self.assertTrue(doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue), (name, bucket))

    def test_qa_must_be_listed_and_passing(self):
        self.assertEqual(doc.not_green([r for r in self.QUEUE if r["name"] != "qa-review"]), ["qa-review"])
        self.assertEqual(doc.not_green(self.QUEUE + [row("qa-review", "fail", run=0)]), ["qa-review"])
        self.assertEqual(doc.not_green([]), ["qa-review"])

    def test_a_suite_job_behind_an_edits_skip_counts(self):
        queue = self.QUEUE + [row("Python unit tests (watchdog)", "skipping", run=EDIT_RUN)]
        for kw in ({"status": "in_progress", "conclusion": None}, {"conclusion": "failure"}, {"conclusion": "cancelled"}, {"conclusion": None}):
            self.assertEqual(doc.not_green(queue, [job("Python unit tests (watchdog)", **kw)]), ["Python unit tests (watchdog)"], kw)
        for how in ("success", "skipped", "neutral"):
            self.assertEqual(doc.not_green(queue, [job("Python unit tests (watchdog)", conclusion=how)]), [], how)

    def test_unknown_is_added_only_when_no_rule_fired(self):
        queue = [r for r in self.QUEUE if r["name"] != "Shellcheck"] + [row("Shellcheck", "fail")]
        self.assertEqual(kinds(doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue)), ["manual"])
        odd = self.QUEUE + [row("validate", "")]
        self.assertEqual(kinds(doc.plan_pr(pr(), self.GREEN, [], NOW, queue=odd)), ["unknown"])

    def test_unknown_is_never_applied_and_is_counted(self):
        with open(SCRIPT, encoding="utf-8") as fh:
            src = fh.read()
        self.assertTrue('if args.apply and s["kind"] == "rerun" and not applied:' in src)  # the only kind applied
        self.assertEqual(src.count("nothing is holding this head"), 1)
        self.assertTrue("        if not steps:\n            tally[\"clear\"]" in src)  # clear = no step, unknown included

    def test_without_the_queue_view_there_is_no_clear_to_give(self):
        # plan_pr with queue=None plans `validate` and the guard only; the CLI always passes the queue.
        self.assertEqual(doc.plan_pr(pr(), self.GREEN, [], NOW), [])
        with open(SCRIPT, encoding="utf-8") as fh:
            self.assertIn("read_queue(n)", fh.read())


class PlannedPendingTests(unittest.TestCase):
    """`validate`, `validate-code` and the guard are planned from their check runs, and the queue
    rows of those names are left out of the rest. Left out entirely, a RUNNING one was nobody's:
    the plan was empty and the tool called the head clear while the merge queue held it (QA review
    of hydra#1935, head 174127db4: a guard in progress under a green `validate` and a QA GO)."""

    GUARD = "credit-approval-guard"
    GUARD_RUN = EDIT_RUN + 7
    GREEN = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2)]
    QUEUE_GREEN = [row("validate"), row("validate-code"), row("pr-title"), row("qa-review", run=0)]

    def running_guard(self, status="in_progress"):
        return check(self.GUARD, self.GUARD_RUN, 9, status=status)

    def test_a_guard_run_with_no_verdict_yet_is_a_wait_from_its_check_run(self):
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            steps = doc.plan_pr(pr(), self.GREEN + [self.running_guard(status)], [], NOW)  # no queue view at all
            self.assertEqual(kinds(steps), ["wait"], status)
            self.assertIn(str(self.GUARD_RUN), steps[0]["why"])
            self.assertIn(status, steps[0]["why"])

    def test_a_guard_green_on_one_event_and_running_on_the_other_is_a_wait(self):
        checks = self.GREEN + [check(self.GUARD, self.GUARD_RUN - 1, 8), self.running_guard()]
        events = [{"id": self.GUARD_RUN - 1, "event": "pull_request_review"}, {"id": self.GUARD_RUN, "event": "pull_request_target"}]
        steps = doc.plan_pr(pr(), checks, [], NOW, guard_runs=events)
        self.assertEqual(kinds(steps), ["wait"])
        self.assertIn("pull_request_target", steps[0]["why"])
        # the same two as one event: the running one started last, so it is still the verdict awaited
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW)), ["wait"])
        # an older running entry under a newer verdict of the same event is history, not a hold
        older = check(self.GUARD, self.GUARD_RUN - 1, 8, status="in_progress", started=NOW - timedelta(hours=3))
        self.assertEqual(doc.plan_pr(pr(), self.GREEN + [older, check(self.GUARD, self.GUARD_RUN, 9)], [], NOW), [])

    def test_a_running_guard_beside_a_failed_one_keeps_both(self):
        checks = self.GREEN + [check(self.GUARD, self.GUARD_RUN - 1, 8, conclusion="failure"), self.running_guard()]
        events = [{"id": self.GUARD_RUN - 1, "event": "pull_request_review"}, {"id": self.GUARD_RUN, "event": "pull_request_target"}]
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW, guard_runs=events)), ["wait", "rerun"])
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, ["no AFTER figure"], NOW, guard_runs=events)), ["wait", "manual"])

    def test_a_pending_queue_row_of_any_planned_check_is_never_clear(self):
        # The check runs read green (they missed the running one); the queue's own row says pending.
        self.assertEqual(doc.plan_pr(pr(), self.GREEN, [], NOW, queue=self.QUEUE_GREEN), [])
        self.assertGreaterEqual(set(doc.PLANNED), {"validate", "validate-code", self.GUARD})
        for name in doc.PLANNED:
            queue = [r for r in self.QUEUE_GREEN if r["name"] != name] + [row(name, "pending", run=self.GUARD_RUN)]
            steps = doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue)
            self.assertEqual(kinds(steps), ["wait"], name)
            self.assertIn(name, steps[0]["why"])
        # beside its own passing row from the other event, a pending guard row still holds
        queue = self.QUEUE_GREEN + [row(self.GUARD), row(self.GUARD, "pending", run=self.GUARD_RUN)]
        self.assertEqual(kinds(doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue)), ["wait"])

    def test_the_exact_input_qa_reproduced(self):
        steps = doc.plan_pr(pr(), self.GREEN + [self.running_guard()], [], NOW,
                            queue=self.QUEUE_GREEN + [row(self.GUARD, "pending", run=self.GUARD_RUN)])
        self.assertTrue(steps)
        self.assertEqual(set(kinds(steps)), {"wait"})

    def test_a_suite_running_again_under_its_old_green_validate_is_a_wait(self):
        # A re-run keeps the run id: the first attempt's `validate` is green and still listed.
        again = check("validate-code", SUITE_RUN, 11, status="in_progress")
        steps = doc.plan_pr(pr(), self.GREEN + [again], [], NOW, [SUITE_RUN])
        self.assertEqual(kinds(steps), ["wait"])
        self.assertIn("running again", steps[0]["why"])
        # an edit run's skipped placeholder under a green validate is not a suite running
        placeholder = check("validate-code", EDIT_RUN, 12, conclusion="skipped")
        self.assertEqual(doc.plan_pr(pr(), self.GREEN + [placeholder, check("validate", EDIT_RUN, 13)], [], NOW, [SUITE_RUN, EDIT_RUN]), [])

    def test_a_running_planned_check_with_no_qa_verdict_waits_and_does_not_redispatch(self):
        queue = [row("validate"), row("validate-code"), row("pr-title"), row(self.GUARD, "pending", run=self.GUARD_RUN)]
        steps = doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue)
        self.assertEqual(kinds(steps), ["wait", "wait"])
        self.assertNotIn("qa-autoreview", " ".join(s["do"] for s in steps))

    def test_a_review_in_progress_is_one_wait_and_not_a_running_check(self):
        queue = [r for r in self.QUEUE_GREEN if r["name"] != "qa-review"] + [row("qa-review", "pending", run=0)]
        steps = doc.plan_pr(pr(), self.GREEN, [], NOW, queue=queue)
        self.assertEqual(kinds(steps), ["wait"])
        self.assertIn("QA is reviewing", steps[0]["why"])

    def test_a_red_planned_row_is_still_planned_once_from_its_check_run(self):
        queue = self.QUEUE_GREEN + [row(self.GUARD, "fail", run=self.GUARD_RUN)]
        checks = self.GREEN + [check(self.GUARD, self.GUARD_RUN, 9, conclusion="failure")]
        self.assertEqual(kinds(doc.plan_pr(pr(), checks, [], NOW, queue=queue)), ["rerun"])


class HiddenJobTests(unittest.TestCase):
    """`gh pr checks` keeps one row per name, the newest. An edit after a push starts a run whose
    jobs are all skipped, and its placeholders hide the suite's own jobs from that listing and so
    from the merge queue. hydra#1935 at 2026-11-13T08:05Z: `Python unit tests (watchdog)` was in
    progress in the suite's run 43389275267 and listed as `skipping` from edit run 43389284777."""

    PY = "Python unit tests (watchdog)"
    CHECKS = [check("validate-code", SUITE_RUN, 1), check("validate", SUITE_RUN, 2),
              check("validate-code", EDIT_RUN, 3, conclusion="skipped"), check("validate", EDIT_RUN, 4)]
    QUEUE = [row("validate", run=EDIT_RUN), row("validate-code", "skipping", run=EDIT_RUN), row("pr-title"),
             row(PY, "skipping", run=EDIT_RUN), row("Shellcheck", "skipping", run=EDIT_RUN),
             row("Bats (scripts/ + ops-admin gates) (1/4)"), row("qa-review", run=0)]

    def plan(self, jobs, queue=None):
        return doc.plan_pr(pr(), self.CHECKS, [], NOW, queue=self.QUEUE if queue is None else queue, suite_jobs=jobs)

    def jobs(self, **py):
        return [job("validate-code"), job("validate"), job(self.PY, **py), job("Shellcheck"),
                job("Bats (scripts/ + ops-admin gates) (1/4)")]

    def test_a_suite_whose_hidden_jobs_all_passed_is_clear(self):
        self.assertEqual(self.plan(self.jobs()), [])

    def test_a_running_job_hidden_by_an_edit_runs_placeholder_is_a_wait(self):
        for status in ("in_progress", "queued"):
            steps = self.plan(self.jobs(status=status))
            self.assertEqual(kinds(steps), ["wait"], status)
            self.assertIn(self.PY, steps[0]["why"])

    def test_a_failed_job_hidden_by_an_edit_runs_placeholder_is_named_and_never_rerun_blind(self):
        for conclusion in ("failure", "timed_out"):
            steps = self.plan(self.jobs(conclusion=conclusion))
            self.assertEqual(kinds(steps), ["manual"], conclusion)
            self.assertIn(self.PY, steps[0]["why"])
            self.assertIn("does not see it", steps[0]["why"])
            self.assertIn(f"gh run view {SUITE_RUN} --log-failed", steps[0]["do"])

    def test_a_hidden_job_with_any_other_ending_is_held_not_assumed_green(self):
        for conclusion in ("action_required", "startup_failure", "stale", None):
            j = self.jobs()
            j[2] = {**j[2], "conclusion": conclusion}
            self.assertEqual(kinds(self.plan(j)), ["manual"], conclusion)
        for conclusion in ("skipped", "neutral"):
            self.assertEqual(self.plan(self.jobs(conclusion=conclusion)), [], conclusion)

    def test_cancelled_hidden_jobs_are_rerun_once_for_their_run(self):
        jobs = self.jobs(conclusion="cancelled") + [job("Plugin tests (vitest)", conclusion="cancelled")]
        steps = self.plan(jobs)
        self.assertEqual(kinds(steps), ["rerun"])
        self.assertEqual(steps[0]["run"], SUITE_RUN)

    def test_a_job_the_queue_lists_from_the_suites_own_run_is_planned_once(self):
        queue = [row(self.PY, "fail") if r["name"] == self.PY else r for r in self.QUEUE]
        steps = self.plan(self.jobs(conclusion="failure"), queue)
        self.assertEqual(kinds(steps), ["manual"])
        self.assertNotIn("does not see it", steps[0]["why"])

    def test_validate_and_the_suite_job_itself_are_planned_by_name_not_here(self):
        jobs = [job("validate-code", conclusion="failure"), job("validate", conclusion="failure")]
        self.assertEqual(doc.queue_steps(pr(), self.QUEUE, NOW, jobs), [])

    def test_no_qa_verdict_while_a_hidden_job_runs_is_a_wait_not_a_redispatch(self):
        queue = [r for r in self.QUEUE if r["name"] != "qa-review"]
        steps = self.plan(self.jobs(status="in_progress"), queue)
        self.assertEqual(kinds(steps), ["wait", "wait"])

    def test_only_a_job_the_listing_shows_from_another_run_is_hidden(self):
        mine = [job(self.PY, conclusion="failure")]
        self.assertEqual(doc.hidden_jobs([row(self.PY, "fail", run=SUITE_RUN)], mine), [])
        hidden = doc.hidden_jobs([row(self.PY, "skipping", run=EDIT_RUN)], mine)
        self.assertEqual([j["name"] for j in hidden], [self.PY])
        self.assertEqual(doc.run_id(hidden[0]), SUITE_RUN)
        self.assertEqual([j["name"] for j in doc.hidden_jobs([], mine)], [self.PY])  # not listed at all is hidden too

    def fetch(self, checks, runs=None):
        """`fetch_pr` over a fake `gh api`: what it asks for, and what it hands back as the suite's jobs."""
        asked = []
        lines = lambda rows: "\n".join(json.dumps(r) for r in rows)

        def fake(*args):
            url = next(a for a in args if a.startswith("repos/"))
            asked.append(url)
            if "/pulls/" in url:
                return json.dumps({"state": "open", "base": {"ref": "main"}, "head": {"sha": "898e5d1b9"}, "mergeable": True, "body": ""})
            if "check-runs?check_name=" in url:
                name = url.split("check_name=")[1].split("&")[0]
                return lines([c for c in checks if c["name"] == name])
            if "/jobs?" in url:
                return lines([job(self.PY, conclusion="failure")])
            return lines(runs or [{"id": SUITE_RUN, "name": "PR Validation", "event": "pull_request", "status": "completed"}])

        real, doc.gh = doc.gh, fake
        try:
            return doc.fetch_pr(1887), asked
        finally:
            doc.gh = real

    def test_the_jobs_fetched_are_the_latest_attempt_of_the_suites_run(self):
        (_, _, _, _, jobs, _), asked = self.fetch(self.CHECKS)
        self.assertEqual([(j["name"], j["conclusion"]) for j in jobs], [(self.PY, "failure")])
        self.assertEqual([u for u in asked if "/jobs?" in u],
                         [f"repos/Muso-AI/hydra/actions/runs/{SUITE_RUN}/jobs?filter=latest&per_page=100"])

    def test_a_head_with_no_suite_asks_for_no_jobs(self):
        (_, _, _, _, jobs, _), asked = self.fetch([check("validate-code", EDIT_RUN, 3, conclusion="skipped"), check("validate", EDIT_RUN, 4)])
        self.assertEqual(jobs, [])
        self.assertEqual([u for u in asked if "/jobs?" in u], [])

    def test_the_validation_runs_still_running_are_handed_back(self):
        wf = lambda rid, status, name="PR Validation", event="pull_request": {"id": rid, "name": name, "event": event, "status": status}
        runs = [wf(SUITE_RUN, "completed"), wf(EDIT_RUN, "in_progress"), wf(EDIT_RUN + 1, "queued"),
                wf(EDIT_RUN + 2, "in_progress", name="PR Title Check"), wf(EDIT_RUN + 3, "in_progress", event="workflow_dispatch")]
        (_, _, validation, _, _, running), asked = self.fetch(self.CHECKS, runs)
        self.assertEqual(validation, [SUITE_RUN, EDIT_RUN, EDIT_RUN + 1])
        self.assertEqual(running, [EDIT_RUN, EDIT_RUN + 1])
        self.assertTrue(any(u.endswith(f"actions/runs?head_sha=898e5d1b9&per_page=100") for u in asked))

    def test_the_suite_is_the_newest_run_that_validated_not_the_edit_run(self):
        self.assertEqual(doc.suite_run(self.CHECKS), SUITE_RUN)
        self.assertEqual(doc.suite_run([check("validate", SUITE_RUN, 2)]), SUITE_RUN)  # a head validated before the split
        self.assertEqual(doc.suite_run([check("validate-code", EDIT_RUN, 3, conclusion="skipped"), check("validate", EDIT_RUN, 4)]), 0)
        self.assertEqual(doc.suite_run([]), 0)


class ApplyBoundaryTests(unittest.TestCase):
    """--apply may POST exactly one endpoint. Pin it in the source."""

    def test_the_only_write_is_rerun_failed_jobs(self):
        with open(SCRIPT, encoding="utf-8") as fh:
            src = fh.read()
        self.assertEqual(src.count('"-X"'), 1)
        self.assertIn('gh("-X", "POST", f"repos/{REPO}/actions/runs/{s[\'run\']}/rerun-failed-jobs")', src)
        for forbidden in ("/merge", "PATCH", "PUT", "DELETE", "update-branch", "/reviews", "/labels"):
            self.assertNotIn(forbidden, src)

    def test_the_guard_rules_are_imported_not_copied(self):
        guard = doc.load_guard()
        body = "## Credit approval impact\nBefore: 12 approved on prod. After: not measured, nothing is deployed, the read comes later in the week.\n"
        self.assertTrue(any("AFTER" in p for p in guard.section_problems(body)))
        dry = body.replace("After: not measured", "After (dry run on the same prod rows, queue off): 12 approved")
        self.assertEqual(guard.section_problems(dry), [])


if __name__ == "__main__":
    unittest.main()
