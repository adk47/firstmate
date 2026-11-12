#!/usr/bin/env python3
"""Tests for scripts/cycle-time.py.

The table is read to decide where delivery time goes, so its failure mode matters more
than its arithmetic: a stage that has not finished must never read as zero, a stage
nobody measured must never read as a number, and a deploy that failed or predates the
merge must never read as "deployed". Stdlib only.
"""
import importlib.util
import os
import json
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "cycle-time.py")
EVIDENCE = os.path.join(ROOT, "data", "fleet-velocity-fable-v1", "evidence.json")
TABLE = os.path.join(ROOT, "data", "fleet-velocity-fable-v1", "cycle-time.md")

_spec = importlib.util.spec_from_file_location("cycle_time", SCRIPT)
ct = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ct)


def ts(text):
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc)


class SpanTests(unittest.TestCase):
    def test_closed_stage_is_its_hours(self):
        span = ct.Span(ts("2026-11-11T10:00:00"), ts("2026-11-11T13:30:00"), ts("2026-11-12T00:00:00"))
        self.assertEqual(span.state, "closed")
        self.assertEqual(span.render(), "3.5")

    def test_open_stage_counts_to_the_record_time_and_says_open(self):
        # merged, never deployed: the most expensive row, not a blank and not a zero
        span = ct.Span(ts("2026-11-11T18:00:00"), None, ts("2026-11-12T01:00:00"))
        self.assertEqual(span.state, "open")
        self.assertEqual(span.render(), ">=7.0 open")
        self.assertEqual(span.hours, 7.0)

    def test_unmeasured_stage_is_never_a_number(self):
        for span in (ct.Span(None, None, ts("2026-11-12T01:00:00")),
                     ct.Span(ts("2026-11-11T18:00:00"), ts("2026-11-11T19:00:00"), measured=False)):
            self.assertEqual(span.state, "unmeasured")
            self.assertEqual(span.render(), "unmeasured")
            self.assertIsNone(span.hours)


class DeployedAtTests(unittest.TestCase):
    MAIN = ["c3", "c2", "c1", "c0"]  # newest first
    MERGED = ts("2026-11-11T18:00:00")

    def run_(self, head, conclusion, done):
        return {"head_sha": head, "conclusion": conclusion, "updated_at": done}

    def test_a_successful_deploy_of_a_later_head_deploys_the_merge(self):
        got = ct.deployed_at("c1", self.MERGED, [self.run_("c2", "success", "2026-11-12T04:20:00Z")], self.MAIN)
        self.assertEqual(got, ts("2026-11-12T04:20:00"))

    def test_a_failed_deploy_deployed_nothing(self):
        # the nightly run that died in its first second on the tick guard
        got = ct.deployed_at("c1", self.MERGED, [self.run_("c2", "failure", "2026-11-12T04:04:20Z")], self.MAIN)
        self.assertIsNone(got)

    def test_a_deploy_of_an_older_head_does_not_contain_the_merge(self):
        got = ct.deployed_at("c2", self.MERGED, [self.run_("c1", "success", "2026-11-12T04:20:00Z")], self.MAIN)
        self.assertIsNone(got)

    def test_a_deploy_that_finished_before_the_merge_is_not_this_merge(self):
        got = ct.deployed_at("c1", self.MERGED, [self.run_("c2", "success", "2026-11-11T17:00:00Z")], self.MAIN)
        self.assertIsNone(got)

    def test_a_head_or_merge_outside_main_proves_nothing(self):
        self.assertIsNone(ct.deployed_at("c1", self.MERGED, [self.run_("zz", "success", "2026-11-12T04:20:00Z")], self.MAIN))
        self.assertIsNone(ct.deployed_at("zz", self.MERGED, [self.run_("c3", "success", "2026-11-12T04:20:00Z")], self.MAIN))

    def test_the_first_containing_deploy_wins(self):
        runs = [self.run_("c3", "success", "2026-11-12T09:00:00Z"), self.run_("c1", "success", "2026-11-12T04:20:00Z")]
        self.assertEqual(ct.deployed_at("c1", self.MERGED, runs, self.MAIN), ts("2026-11-12T04:20:00"))


class CountingTests(unittest.TestCase):
    def test_only_reviews_that_state_a_verdict_are_rounds(self):
        reviews = [
            {"body": "Verdict: NO-GO - 1 Important", "submitted_at": "2026-11-11T11:00:00Z", "commit_id": "a"},
            {"body": "looks fine to me", "submitted_at": "2026-11-11T11:30:00Z", "commit_id": "a"},
            {"body": "Verdict: GO - 0 Critical", "submitted_at": "2026-11-11T10:00:00Z", "commit_id": "b"},
        ]
        self.assertEqual([(v, sha) for _, v, sha in ct.qa_verdicts(reviews)], [("GO", "b"), ("NO-GO", "a")])

    def test_a_cancelled_or_seconds_long_run_is_not_a_ci_round(self):
        def run(conclusion, start, end, name="PR Validation"):
            return {"name": name, "conclusion": conclusion, "created_at": start, "updated_at": end, "head_sha": "a"}
        runs = [
            run("success", "2026-11-11T10:00:00Z", "2026-11-11T10:44:00Z"),
            run("failure", "2026-11-11T11:00:00Z", "2026-11-11T11:40:00Z"),
            run("cancelled", "2026-11-11T12:00:00Z", "2026-11-11T12:30:00Z"),   # a superseded push
            run("success", "2026-11-11T13:00:00Z", "2026-11-11T13:00:30Z"),     # a metadata stand-in
            run("success", "2026-11-11T14:00:00Z", "2026-11-11T14:40:00Z", name="PR Title"),
        ]
        self.assertEqual(len(ct.real_ci_runs(runs)), 2)

    def test_totals_count_open_time_and_report_unmeasured_by_count(self):
        now = ts("2026-11-12T01:00:00")
        blank = {key: ct.Span(None, None, now) for key, _ in ct.STAGES}
        one = dict(blank, merge_to_deploy=ct.Span(ts("2026-11-11T18:00:00"), None, now))
        two = dict(blank, merge_to_deploy=ct.Span(ts("2026-11-11T20:00:00"), ts("2026-11-11T22:00:00"), now))
        three = dict(blank)
        got = ct.totals([{"spans": one}, {"spans": two}, {"spans": three}])["merge_to_deploy"]
        self.assertEqual(got, {"hours": 9.0, "open": 1, "unmeasured": 1})
        self.assertEqual(ct.top_costs([{"spans": one}, {"spans": two}, {"spans": three}]),
                         [("merge_to_deploy", got)])  # a stage with no hours is not a "top cost"


class PlacedMergeTests(unittest.TestCase):
    """The evidence holds a bounded window of main; a merge outside it is not 'still undeployed'."""

    def row(self, merge_sha, main_order):
        pr = {"number": 1, "title": "t", "state": "closed", "created_at": "2026-10-01T10:00:00Z",
              "merged_at": "2026-10-01T12:00:00Z", "closed_at": "2026-10-01T12:00:00Z", "head_sha": "h",
              "merge_commit_sha": merge_sha, "commit_times": ["2026-10-01T09:00:00Z"], "reviews": [], "runs": []}
        evidence = {"recorded_at": "2026-11-12T01:00:00Z", "deploys": [], "main_order": main_order}
        return ct.timeline(pr, evidence)["spans"]["merge_to_deploy"]

    def test_a_merge_outside_the_recorded_window_of_main_is_unmeasured(self):
        span = self.row("old", ["c2", "c1"])
        self.assertEqual(span.render(), "unmeasured")   # not ">=N open": nothing here shows it is undeployed

    def test_a_merge_inside_the_window_with_no_deploy_is_open(self):
        span = self.row("c1", ["c2", "c1"])
        self.assertEqual(span.state, "open")


FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CT_GH_LOG"], "a") as handle:
    handle.write(json.dumps(args) + "\n")
path = args[1]
paged = "--paginate" in args and "--slurp" in args
if "/reviews" in path:  # oldest first, as the forge pages them: the newest verdict is on page 2
    pages = [[{"submitted_at": "2026-11-11T10:00:00Z", "commit_id": "a", "body": "Verdict: NO-GO"}],
             [{"submitted_at": "2026-11-11T12:00:00Z", "commit_id": "b", "body": "Verdict: GO"}]]
elif "/commits" in path:
    pages = [[{"commit": {"author": {"date": "2026-11-11T09:00:00Z"}}}]]
elif "actions/runs?" in path:
    pages = [{"workflow_runs": []}]
else:
    print(json.dumps({"number": 7, "title": "t", "state": "open", "created_at": "2026-11-11T09:30:00Z",
                      "merged_at": None, "closed_at": None, "merge_commit_sha": None,
                      "head": {"sha": "b", "ref": "fm/x"}}))
    sys.exit(0)
print(json.dumps(pages if paged else pages[0]))
'''


class PaginatedReadTests(unittest.TestCase):
    """Reviews page oldest first, so an unpaginated read drops the NEWEST verdict.

    scripts/check-review-reads-paginated.sh cannot see through gh(), and the read carries a
    `paginated-ok:` marker; these cases are what makes that marker true.
    """

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        fake = os.path.join(self.dir.name, "gh")
        with open(fake, "w", encoding="utf-8") as handle:
            handle.write(FAKE_GH)
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        self.log = os.path.join(self.dir.name, "calls.jsonl")
        patch = mock.patch.dict(os.environ, {"PATH": self.dir.name + os.pathsep + os.environ["PATH"],
                                             "CT_GH_LOG": self.log})
        patch.start()
        self.addCleanup(patch.stop)

    def calls(self):
        with open(self.log, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle]

    def test_a_paginated_read_asks_for_every_page_and_merges_them(self):
        got = ct.gh("repos/o/r/pulls/7/reviews?per_page=100", paginate=True)
        self.assertEqual([r["commit_id"] for r in got], ["a", "b"])
        self.assertIn("--paginate", self.calls()[0])
        self.assertIn("--slurp", self.calls()[0])

    def test_record_pr_reads_every_page_of_reviews(self):
        recorded = ct.record_pr("o/r", 7)
        self.assertEqual([r["commit_id"] for r in recorded["reviews"]], ["a", "b"])  # page 2 holds the GO
        review_call = next(c for c in self.calls() if "/reviews" in c[1])
        self.assertIn("--paginate", review_call)


class RecordedTableTests(unittest.TestCase):
    """The committed table is the evidence file rendered, byte for byte, with no network."""

    def render(self):
        env = dict(os.environ, PATH="/nonexistent")  # `table` must not be able to reach gh
        return subprocess.run([sys.executable, SCRIPT, "table", "--evidence", EVIDENCE],
                              capture_output=True, text=True, env=env, check=True).stdout

    def test_table_is_reproducible_and_matches_the_committed_copy(self):
        first, second = self.render(), self.render()
        self.assertEqual(first, second)
        with open(TABLE, encoding="utf-8") as handle:
            self.assertEqual(first, handle.read())

    def test_the_recorded_table_never_shows_an_unfinished_stage_as_done(self):
        text = self.render()
        row = next(line for line in text.splitlines() if line.startswith("| #1885 "))
        self.assertIn(">=", row)              # GO and still unmerged at record time
        self.assertIn("open", row)
        self.assertNotIn("| 0.0 | 0.0 | 0.0 | 0.0 |", row)


if __name__ == "__main__":
    unittest.main()
