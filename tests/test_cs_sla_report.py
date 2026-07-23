"""Behavioral tests for scripts/cs-sla-report.py.

Weekly READ-ONLY SLA report posted to #cs_chats — the SLA denominator. This
script is deliberately standalone (copies the digest's Intercom-client /
pagination / masking / waiting_since patterns rather than importing
scripts/cs-needs-human-digest.py — see the module docstring). Stdlib
unittest + stubs only — no pytest dependency, no network, same bare
python3 -m unittest shape as tests/test_cs_needs_human_digest.py.
"""
import importlib.util
import pathlib
import unittest
from unittest import mock

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "cs-sla-report.py"
)
_spec = importlib.util.spec_from_file_location("cs_sla_report", _SCRIPT)
s = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(s)


def conv(cid="c1", created_at=0, lar=0, lcr=0,
         first_admin_reply_at=None, count_reopens=0, has_statistics=True,
         is_inbound=True):
    """Conversation shaped like fetch_window_convs/fetch_open_convs output."""
    return {
        "id": cid, "created_at": created_at, "lar": lar, "lcr": lcr,
        "first_admin_reply_at": first_admin_reply_at,
        "count_reopens": count_reopens, "has_statistics": has_statistics,
        "is_inbound": is_inbound,
    }


class TestFirstResponseDistribution(unittest.TestCase):
    def test_known_first_response_times_used(self):
        c1 = conv(cid="c1", created_at=1000, first_admin_reply_at=1100)
        c2 = conv(cid="c2", created_at=1000, first_admin_reply_at=1200)
        result = s.first_response_distribution([c1, c2])
        self.assertEqual(result["known_count"], 2)
        self.assertEqual(result["unknown_count"], 0)
        self.assertEqual(result["median_seconds"], 150)

    def test_missing_statistics_counts_as_unknown_not_dropped(self):
        c1 = conv(cid="c1", created_at=1000, first_admin_reply_at=1100)
        c2 = conv(cid="c2", created_at=1000, first_admin_reply_at=None,
                   has_statistics=False)
        result = s.first_response_distribution([c1, c2])
        self.assertEqual(result["known_count"], 1)
        self.assertEqual(result["unknown_count"], 1)

    def test_p90_computed(self):
        # [100..1000] (created_at=1000, fra=1000+i*100) -> p90 is the exact
        # linear-interpolated value: rank = .9*9 = 8.1 -> values[8..9]=(900,
        # 1000) -> 900 + .1*100 = 910.0. A range check here would be vacuous
        # (any monotonic implementation passes); pin the real number.
        times = [conv(cid=f"c{i}", created_at=1000, first_admin_reply_at=1000 + i * 100)
                  for i in range(1, 11)]
        result = s.first_response_distribution(times)
        self.assertEqual(result["known_count"], 10)
        self.assertEqual(result["p90_seconds"], 910.0)

    def test_empty_input_never_crashes(self):
        result = s.first_response_distribution([])
        self.assertEqual(result["known_count"], 0)
        self.assertEqual(result["unknown_count"], 0)
        self.assertIsNone(result["median_seconds"])
        self.assertIsNone(result["p90_seconds"])

    def test_missing_created_at_counts_as_unknown_not_garbage_duration(self):
        # created_at=0 (missing/unset field, per _conv_record's `or 0`
        # normalization) with a real first_admin_reply_at would otherwise
        # yield a ~54-year duration (fra - 0) — must be "unknown", not a
        # silently-wrong known duration.
        c = conv(cid="c1", created_at=0, first_admin_reply_at=1_700_000_000)
        result = s.first_response_distribution([c])
        self.assertEqual(result["known_count"], 0)
        self.assertEqual(result["unknown_count"], 1)

    def test_fra_before_created_at_counts_as_unknown_not_clamped(self):
        # Inconsistent data (fra < created_at) must not silently clamp to a
        # 0-second known duration.
        c = conv(cid="c1", created_at=1000, first_admin_reply_at=500)
        result = s.first_response_distribution([c])
        self.assertEqual(result["known_count"], 0)
        self.assertEqual(result["unknown_count"], 1)


class TestReopenRate(unittest.TestCase):
    def test_rate_is_fraction_of_conversations_reopened(self):
        # One conversation reopened (twice) + one never reopened = 50%, NOT the
        # average-reopen-count 100%. count_reopens=2 counts the conversation
        # ONCE toward the numerator.
        c1 = conv(cid="c1", count_reopens=2, first_admin_reply_at=100)
        c2 = conv(cid="c2", count_reopens=0, first_admin_reply_at=200)
        c3 = conv(cid="c3", count_reopens=0, first_admin_reply_at=None,
                   has_statistics=False)  # never replied to -> excluded from denominator
        result = s.reopen_rate([c1, c2, c3])
        self.assertEqual(result["total_reopens"], 2)          # raw event count (diagnostic)
        self.assertEqual(result["reopened_conversations"], 1)  # numerator: distinct convs
        self.assertEqual(result["replied_conversations"], 2)
        self.assertAlmostEqual(result["rate"], 0.5)

    def test_repeated_reopens_never_exceed_100_percent(self):
        # A single conversation reopened many times must not render >100%.
        c1 = conv(cid="c1", count_reopens=5, first_admin_reply_at=100)
        result = s.reopen_rate([c1])
        self.assertEqual(result["total_reopens"], 5)
        self.assertEqual(result["reopened_conversations"], 1)
        self.assertAlmostEqual(result["rate"], 1.0)

    def test_zero_denominator_reports_unavailable_not_a_crash(self):
        c1 = conv(cid="c1", count_reopens=0, first_admin_reply_at=None,
                   has_statistics=False)
        result = s.reopen_rate([c1])
        self.assertEqual(result["replied_conversations"], 0)
        self.assertEqual(result["reopened_conversations"], 0)
        self.assertIsNone(result["rate"])

    def test_numerator_excludes_never_replied_reopens(self):
        # A conversation closed-without-reply then reopened has a nonzero
        # count_reopens but no first_admin_reply_at — it must not inflate
        # the numerator while being excluded from the denominator (that
        # would overstate the rate for the replied population).
        replied = conv(cid="c1", count_reopens=1, first_admin_reply_at=100)
        never_replied = conv(cid="c2", count_reopens=5, first_admin_reply_at=None,
                              has_statistics=False)
        result = s.reopen_rate([replied, never_replied])
        self.assertEqual(result["total_reopens"], 1)
        self.assertEqual(result["reopened_conversations"], 1)
        self.assertEqual(result["replied_conversations"], 1)
        self.assertAlmostEqual(result["rate"], 1.0)


class TestInboundFilter(unittest.TestCase):
    """The SLA target is first action on INBOUND conversations; outbound /
    campaign / bot-initiated threads must not enter the first-response or
    reopen denominators (they would skew both latency and the rate)."""

    def test_inbound_only_drops_outbound(self):
        inbound = conv(cid="IN", is_inbound=True)
        outbound = conv(cid="OUT", is_inbound=False)
        self.assertEqual([c["id"] for c in s.inbound_only([inbound, outbound])], ["IN"])

    def test_outbound_excluded_from_first_response_and_reopen(self):
        # A fast-answered outbound thread would drag the median DOWN and pad
        # the reopen denominator; an inbound-only population must ignore it.
        inbound = conv(cid="IN", created_at=1000, first_admin_reply_at=1300,
                       count_reopens=1, is_inbound=True)
        outbound = conv(cid="OUT", created_at=1000, first_admin_reply_at=1001,
                        count_reopens=0, is_inbound=False)
        population = s.inbound_only([inbound, outbound])
        fr = s.first_response_distribution(population)
        self.assertEqual(fr["known_count"], 1)
        self.assertEqual(fr["median_seconds"], 300)   # only the inbound 300s
        rr = s.reopen_rate(population)
        self.assertEqual(rr["replied_conversations"], 1)
        self.assertAlmostEqual(rr["rate"], 1.0)       # 1 reopen / 1 inbound


class TestWaitingSince(unittest.TestCase):
    def test_never_replied_falls_back_to_created_at(self):
        c = conv(cid="c1", created_at=500, lar=0, lcr=0)
        self.assertEqual(s.waiting_since(c), 500)

    def test_customer_reply_time_used_when_present(self):
        c = conv(cid="c1", created_at=100, lcr=900)
        self.assertEqual(s.waiting_since(c), 900)


class TestResidueSnapshot(unittest.TestCase):
    def test_counts_customer_last_waiting_over_24h(self):
        now = 1_000_000
        stale = conv(cid="STALE", lar=100, lcr=100, created_at=0)  # waiting since 100
        fresh = conv(cid="FRESH", lar=0, lcr=now - 3600, created_at=0)  # 1h old
        admin_last = conv(cid="ADM", lar=now, lcr=100, created_at=0)  # not waiting on us
        result = s.residue_over_24h([stale, fresh, admin_last], now)
        self.assertEqual(result["count"], 1)
        self.assertEqual([c["id"] for c in result["oldest"]], ["STALE"])

    def test_top_3_oldest_ages_reported(self):
        now = 1_000_000
        convs = [
            conv(cid=f"C{i}", lar=0, lcr=now - (i * 200000), created_at=0)
            for i in range(1, 6)
        ]
        result = s.residue_over_24h(convs, now)
        self.assertEqual(result["count"], 5)
        self.assertEqual(len(result["oldest"]), 3)
        # oldest (largest elapsed, i.e. smallest lcr) first.
        self.assertEqual([c["id"] for c in result["oldest"]], ["C5", "C4", "C3"])

    def test_outbound_zero_zero_excluded_from_residue(self):
        now = 1_000_000
        outbound = conv(cid="OUT", lar=0, lcr=0, created_at=0, is_inbound=False)
        result = s.residue_over_24h([outbound], now)
        self.assertEqual(result["count"], 0)


class TestCreditQueueDepth(unittest.TestCase):
    def test_muso_bin_resolution_precedence(self):
        # explicit MUSO_CLI_BIN wins; else `muso` on PATH; else the deployed
        # /usr/local/bin/muso — mirrors slack-notify.sh / clickup-muso.sh so the
        # metric is not silently dead when the unit forgets to export the var.
        import os as _os
        with mock.patch.dict("os.environ", {"MUSO_CLI_BIN": "/explicit/muso"}):
            self.assertEqual(s._resolve_muso_bin(), "/explicit/muso")
        with mock.patch.dict("os.environ", {}, clear=False):
            _os.environ.pop("MUSO_CLI_BIN", None)
            with mock.patch.object(s.shutil, "which", return_value="/on/path/muso"):
                self.assertEqual(s._resolve_muso_bin(), "/on/path/muso")
            with mock.patch.object(s.shutil, "which", return_value=None), \
                    mock.patch.object(s.os, "access", return_value=True):
                self.assertEqual(s._resolve_muso_bin(), "/usr/local/bin/muso")

    def test_unavailable_when_no_binary_resolvable(self):
        import os as _os
        with mock.patch.dict("os.environ", {}, clear=False):
            _os.environ.pop("MUSO_CLI_BIN", None)
            with mock.patch.object(s.shutil, "which", return_value=None), \
                    mock.patch.object(s.os, "access", return_value=False):
                result = s.unverified_credit_queue_depth()
        self.assertIsNone(result["count"])
        self.assertIn("not found", result["note"])

    def test_subprocess_error_reported_not_crashed(self):
        with mock.patch.dict("os.environ", {"MUSO_CLI_BIN": "/usr/bin/muso"}):
            with mock.patch.object(
                s.subprocess, "run", side_effect=OSError("no such file")
            ):
                result = s.unverified_credit_queue_depth()
        self.assertIsNone(result["count"])
        self.assertIn("no such file", result["note"])

    def test_successful_parse_returns_count(self):
        fake = mock.Mock(returncode=0, stdout='{"data":{"pending":42}}', stderr="")
        with mock.patch.dict("os.environ", {"MUSO_CLI_BIN": "/usr/bin/muso"}):
            with mock.patch.object(s.subprocess, "run", return_value=fake) as m_run:
                result = s.unverified_credit_queue_depth()
        self.assertEqual(result["count"], 42)
        m_run.assert_called_once()
        call_args, call_kwargs = m_run.call_args
        self.assertEqual(
            call_args[0],
            ["/usr/bin/muso", "api", "GET", "/admin/credit-requests/counts", "--json"])
        self.assertNotIn("shell", call_kwargs)

    def test_nonzero_exit_reported_not_crashed(self):
        fake = mock.Mock(returncode=1, stdout="", stderr="401 unauthorized")
        with mock.patch.dict("os.environ", {"MUSO_CLI_BIN": "/usr/bin/muso"}):
            with mock.patch.object(s.subprocess, "run", return_value=fake):
                result = s.unverified_credit_queue_depth()
        self.assertIsNone(result["count"])
        self.assertIn("401 unauthorized", result["note"])

    def test_non_dict_body_reported_not_crashed(self):
        # e.g. {"body": "unauthorized"} — a non-dict "body" value must not
        # AttributeError out of the shape walk (`.get("data")` on a str).
        fake = mock.Mock(returncode=0, stdout='{"body":"unauthorized"}', stderr="")
        with mock.patch.dict("os.environ", {"MUSO_CLI_BIN": "/usr/bin/muso"}):
            with mock.patch.object(s.subprocess, "run", return_value=fake):
                result = s.unverified_credit_queue_depth()
        self.assertIsNone(result["count"])
        self.assertIn("unrecognized response shape", result["note"])


class TestPagination(unittest.TestCase):
    """Model: tests/test_cs_needs_human_digest.py's fetch_open_convs fixtures
    (contact_ref / statistics shape) — extended here to a genuine two-page
    walk, which the digest's own tests don't exercise either."""

    def _two_page_fake_search(self, calls):
        def fake_search(token, body):
            calls.append(body)
            if "starting_after" not in body["pagination"]:
                return {
                    "conversations": [{"id": "C1", "statistics": {}}],
                    "pages": {"next": {"starting_after": "cursor-1"}},
                }
            return {
                "conversations": [{"id": "C2", "statistics": {}}],
                "pages": {"next": None},
            }
        return fake_search

    def test_fetch_window_convs_paginates_and_terminates(self):
        calls = []
        with mock.patch.object(s, "intercom_search", self._two_page_fake_search(calls)):
            out = s.fetch_window_convs("tok", cutoff_epoch=0)
        self.assertEqual([c["id"] for c in out], ["C1", "C2"])
        self.assertEqual(len(calls), 2)
        self.assertNotIn("starting_after", calls[0]["pagination"])
        self.assertEqual(calls[1]["pagination"]["starting_after"], "cursor-1")

    def test_fetch_open_convs_paginates_and_terminates(self):
        calls = []
        with mock.patch.object(s, "intercom_search", self._two_page_fake_search(calls)):
            out = s.fetch_open_convs("tok")
        self.assertEqual([c["id"] for c in out], ["C1", "C2"])
        self.assertEqual(len(calls), 2)
        self.assertNotIn("starting_after", calls[0]["pagination"])
        self.assertEqual(calls[1]["pagination"]["starting_after"], "cursor-1")

    def test_fetch_window_convs_terminates_on_empty_pages_dict(self):
        def fake_search(token, body):
            return {"conversations": [{"id": "ONLY", "statistics": {}}], "pages": {}}
        with mock.patch.object(s, "intercom_search", fake_search):
            out = s.fetch_window_convs("tok", cutoff_epoch=0)
        self.assertEqual([c["id"] for c in out], ["ONLY"])

    def test_fetch_open_convs_terminates_on_next_null(self):
        def fake_search(token, body):
            return {"conversations": [{"id": "ONLY", "statistics": {}}],
                    "pages": {"next": None}}
        with mock.patch.object(s, "intercom_search", fake_search):
            out = s.fetch_open_convs("tok")
        self.assertEqual([c["id"] for c in out], ["ONLY"])


class TestMaskEmail(unittest.TestCase):
    def test_masks_like_the_digest(self):
        self.assertEqual(s.mask_email("joe@example.com"), "j***@***")
        self.assertEqual(s.mask_email(""), "no email")


class TestRollupPersistence(unittest.TestCase):
    def test_writes_json_file_named_by_iso_date(self):
        import tempfile
        rollup = {"window_days": 7, "first_response": {}, "residue": {},
                  "reopen_rate": {}, "credit_queue": {}}
        with tempfile.TemporaryDirectory() as tmp:
            path = s.persist_rollup(rollup, tmp, now_epoch=1_700_000_000)
            self.assertTrue(pathlib.Path(path).exists())
            # 1_700_000_000 UTC is 2023-11-14 — pins the UTC (not local) date.
            self.assertEqual(pathlib.Path(path).name, "sla-2023-11-14.json")
            import json
            with open(path) as f:
                on_disk = json.load(f)
            self.assertEqual(on_disk, rollup)


class TestSelfTest(unittest.TestCase):
    def test_self_test_passes(self):
        self.assertTrue(s._self_test())


class TestPostSlackReportBestEffort(unittest.TestCase):
    def test_network_and_read_failures_are_non_fatal(self):
        import io
        from contextlib import redirect_stderr
        for exc in (TimeoutError("read timed out"), OSError("connection reset"),
                    ValueError("bad json"), RuntimeError("anything else")):
            with mock.patch.object(s, "_read_slack_token", return_value="xoxb-test"), \
                 mock.patch.object(s.urllib.request, "urlopen", side_effect=exc), \
                 redirect_stderr(io.StringIO()):
                self.assertFalse(
                    s.post_slack_report([], "text", "C0ANM0PN9L5", "/cfg", "operations"))

    def test_missing_token_is_non_fatal(self):
        import io
        from contextlib import redirect_stderr
        with mock.patch.object(s, "_read_slack_token", return_value=None), \
             redirect_stderr(io.StringIO()):
            self.assertFalse(
                s.post_slack_report([], "text", "C0ANM0PN9L5", "/cfg", "operations"))


if __name__ == "__main__":
    unittest.main()
