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
         is_inbound=True, last_closed_by_id=None, last_close_at=0):
    """Conversation shaped like fetch_window_convs/fetch_open_convs output."""
    return {
        "id": cid, "created_at": created_at, "lar": lar, "lcr": lcr,
        "first_admin_reply_at": first_admin_reply_at,
        "count_reopens": count_reopens, "has_statistics": has_statistics,
        "is_inbound": is_inbound, "last_closed_by_id": last_closed_by_id,
        "last_close_at": last_close_at,
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


class TestResolvedCounts(unittest.TestCase):
    """docs/plans/autonomous-cs-machine.md Sec.5's headline honesty metric:
    AI-resolved / total-inbound, with reopen-rate as the honesty check.
    "Closed" is not "resolved" - a reopened close counts toward neither
    bucket. A close is credited only once it is at least one observation
    window old (close_cutoff); the AGED_CLOSE fixtures below are closed well
    before CLOSE_CUTOFF so these tests isolate closer-classification -
    close-recency is exercised in test_recently_closed_* and
    TestCohortPartition."""

    CAROLINE_ID = "5763097"
    CLOSE_CUTOFF = 1000
    AGED_CLOSE = 100    # <= CLOSE_CUTOFF: closed long enough ago to be credited

    def test_machine_close_no_reopens_counts_as_ai_resolved(self):
        c = conv(cid="c1", last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                 last_close_at=self.AGED_CLOSE)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 1)
        self.assertEqual(result["human_resolved"], 0)

    def test_human_close_counts_as_human_resolved(self):
        c = conv(cid="c1", last_closed_by_id="1234567", count_reopens=0,
                 last_close_at=self.AGED_CLOSE)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 0)
        self.assertEqual(result["human_resolved"], 1)

    def test_machine_close_with_reopens_excluded_from_ai_resolved(self):
        # A close that reopened did not actually resolve the customer (Sec.5:
        # "closed is not resolved") - it must not inflate ai_resolved, and it
        # must not fall into human_resolved either (it was never human-closed).
        c = conv(cid="c1", last_closed_by_id=self.CAROLINE_ID, count_reopens=1,
                 last_close_at=self.AGED_CLOSE)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 0)
        self.assertEqual(result["human_resolved"], 0)

    def test_human_close_with_reopens_excluded_from_human_resolved(self):
        c = conv(cid="c1", last_closed_by_id="1234567", count_reopens=2,
                 last_close_at=self.AGED_CLOSE)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 0)
        self.assertEqual(result["human_resolved"], 0)

    def test_never_closed_conversation_counts_toward_neither_bucket(self):
        c = conv(cid="c1", last_closed_by_id=None, count_reopens=0)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 0)
        self.assertEqual(result["human_resolved"], 0)

    def test_recently_closed_machine_close_excluded_from_numerator(self):
        # Machine-closed, zero reopens, but closed MORE recently than one
        # observation window (last_close_at > close_cutoff): it has had no
        # chance to reopen yet, so crediting it would inflate the metric. It
        # must count toward neither bucket - while still (per the caller)
        # remaining in the total_inbound denominator.
        c = conv(cid="c1", last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                 last_close_at=self.CLOSE_CUTOFF + 1)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 0)
        self.assertEqual(result["human_resolved"], 0)
        # denominator is the caller's len(cohort) = 1; numerator excluded -> 0%.
        self.assertEqual(s.ai_resolved_ratio(result, total_inbound=1), 0.0)

    def test_missing_close_timestamp_excluded_from_numerator(self):
        # Defensive: a closer id present but no last_close_at (0) can't be
        # aged, so it is not credited (conservative - can only under-count).
        c = conv(cid="c1", last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                 last_close_at=0)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF)
        self.assertEqual(result["ai_resolved"], 0)
        self.assertEqual(result["human_resolved"], 0)

    def test_custom_admin_id_respected(self):
        c = conv(cid="c1", last_closed_by_id="42", count_reopens=0,
                 last_close_at=self.AGED_CLOSE)
        result = s.resolved_counts([c], self.CLOSE_CUTOFF, caroline_admin_id="42")
        self.assertEqual(result["ai_resolved"], 1)
        self.assertEqual(result["human_resolved"], 0)

    def test_ratio_math(self):
        convs = [
            conv(cid="ai1", last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                 last_close_at=self.AGED_CLOSE),
            conv(cid="ai2", last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                 last_close_at=self.AGED_CLOSE),
            conv(cid="hum1", last_closed_by_id="1234567", count_reopens=0,
                 last_close_at=self.AGED_CLOSE),
            conv(cid="open1", last_closed_by_id=None),
        ]
        # total_inbound is the cohort's inbound-created denominator (see
        # TestCohortPartition), not just len(convs) with a resolution - the
        # caller supplies it separately.
        resolved = s.resolved_counts(convs, self.CLOSE_CUTOFF)
        ratio = s.ai_resolved_ratio(resolved, total_inbound=4)
        self.assertEqual(resolved["ai_resolved"], 2)
        self.assertEqual(resolved["human_resolved"], 1)
        self.assertAlmostEqual(ratio, 0.5)

    def test_ratio_none_when_no_inbound_traffic(self):
        self.assertIsNone(
            s.ai_resolved_ratio({"ai_resolved": 0, "human_resolved": 0}, total_inbound=0))


class TestCohortPartition(unittest.TestCase):
    """The AI-resolved/total-inbound ratio judges a LAGGED ARRIVAL COHORT
    (inbound created 7-14 days ago), not this week's arrivals - judging
    same-week arrivals against same-week closes double-biases: it undercounts
    still-in-progress conversations AND inflates the youngest machine-closes,
    which had no time to reopen (oracle-mandated fix, docs/plans/
    autonomous-cs-machine.md Sec.5)."""

    NOW = 20 * 86400
    CUTOFF_7D = NOW - 7 * 86400
    CUTOFF_14D = NOW - 14 * 86400
    CAROLINE_ID = "5763097"

    def test_too_recent_conversation_excluded_from_cohort_entirely(self):
        # Created 3 days ago: inside trailing_7d (the existing #721
        # population), but too recent for the cohort - it must not enter
        # either the numerator or the denominator of the AI-resolved ratio,
        # even though it's already machine-closed.
        recent = conv(cid="recent", created_at=self.NOW - 3 * 86400,
                      last_closed_by_id=self.CAROLINE_ID, count_reopens=0)
        trailing, cohort = s.cohort_partition([recent], self.CUTOFF_14D, self.CUTOFF_7D)
        self.assertEqual([c["id"] for c in trailing], ["recent"])
        self.assertEqual(cohort, [])
        resolved = s.resolved_counts(cohort, self.CUTOFF_7D)
        self.assertEqual(s.ai_resolved_ratio(resolved, total_inbound=len(cohort)), None)

    def test_cohort_conv_with_reopens_counts_denominator_only(self):
        # 10 days old (inside the 7-14d cohort window), machine-closed 8 days
        # ago (aged past the observation window) but reopened: it must count
        # toward total_inbound (the denominator) but NOT ai_resolved
        # (reopen-adjustment stays numerator-only per the oracle directive -
        # adjusting the denominator would inflate the ratio, the Sec.5 gaming
        # mode). Close age is aged here so the ONLY reason for exclusion is
        # the reopen.
        reopened = conv(cid="reopened", created_at=self.NOW - 10 * 86400,
                        last_closed_by_id=self.CAROLINE_ID, count_reopens=1,
                        last_close_at=self.NOW - 8 * 86400)
        trailing, cohort = s.cohort_partition([reopened], self.CUTOFF_14D, self.CUTOFF_7D)
        self.assertEqual(trailing, [])
        self.assertEqual([c["id"] for c in cohort], ["reopened"])
        resolved = s.resolved_counts(cohort, self.CUTOFF_7D)
        total_inbound = len(cohort)
        self.assertEqual(resolved["ai_resolved"], 0)
        self.assertEqual(total_inbound, 1)
        self.assertEqual(s.ai_resolved_ratio(resolved, total_inbound), 0.0)

    def test_cohort_conv_no_reopens_counts_both_numerator_and_denominator(self):
        # 10 days old, machine-closed 8 days ago (aged past the observation
        # window), never reopened: counts toward BOTH ai_resolved and
        # total_inbound.
        clean = conv(cid="clean", created_at=self.NOW - 10 * 86400,
                     last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                     last_close_at=self.NOW - 8 * 86400)
        trailing, cohort = s.cohort_partition([clean], self.CUTOFF_14D, self.CUTOFF_7D)
        self.assertEqual(trailing, [])
        self.assertEqual([c["id"] for c in cohort], ["clean"])
        resolved = s.resolved_counts(cohort, self.CUTOFF_7D)
        total_inbound = len(cohort)
        self.assertEqual(resolved["ai_resolved"], 1)
        self.assertEqual(total_inbound, 1)
        self.assertEqual(s.ai_resolved_ratio(resolved, total_inbound), 1.0)

    def test_cohort_member_closed_within_window_counts_denominator_only(self):
        # 10 days old (inside the cohort), machine-closed only 1 day ago:
        # arrival-lag put it in the cohort, but the close is younger than one
        # observation window (last_close_at > cutoff_7d) so it had no chance to
        # reopen. It must count toward total_inbound but NOT ai_resolved -
        # otherwise a just-closed conversation would inflate the headline
        # ratio, the exact bias the lagged cohort exists to remove.
        just_closed = conv(cid="just_closed", created_at=self.NOW - 10 * 86400,
                           last_closed_by_id=self.CAROLINE_ID, count_reopens=0,
                           last_close_at=self.NOW - 1 * 86400)
        trailing, cohort = s.cohort_partition([just_closed], self.CUTOFF_14D, self.CUTOFF_7D)
        self.assertEqual(trailing, [])
        self.assertEqual([c["id"] for c in cohort], ["just_closed"])
        resolved = s.resolved_counts(cohort, self.CUTOFF_7D)
        total_inbound = len(cohort)
        self.assertEqual(resolved["ai_resolved"], 0)
        self.assertEqual(total_inbound, 1)
        self.assertEqual(s.ai_resolved_ratio(resolved, total_inbound), 0.0)

    def test_boundary_conv_at_exactly_cutoff_7d_is_in_cohort_not_trailing(self):
        # created_at == cutoff_7d is NOT > cutoff_7d, so it's excluded from
        # trailing_7d; the cohort's upper bound is inclusive (<=), so it
        # lands in the cohort - the two populations partition, never overlap.
        boundary = conv(cid="boundary", created_at=self.CUTOFF_7D)
        trailing, cohort = s.cohort_partition([boundary], self.CUTOFF_14D, self.CUTOFF_7D)
        self.assertEqual(trailing, [])
        self.assertEqual([c["id"] for c in cohort], ["boundary"])


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
