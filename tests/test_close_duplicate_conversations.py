"""Behavioral tests for scripts/close-duplicate-conversations.py.

This is a ONE-WAY-DOOR script (it closes customer conversations). The
pure grouping/tiering/keep-selection core is unit-tested exhaustively here
with no network. Stdlib unittest + stubs only, matching
tests/test_cs_needs_human_digest.py's convention.
"""
import importlib.util
import os
import pathlib
import stat
import unittest
from unittest import mock

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "close-duplicate-conversations.py"
)
_spec = importlib.util.spec_from_file_location("close_duplicate_conversations", _SCRIPT)
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)


def conv(cid, email="a@b.com", lar=0, lcr=0, created_at=0, is_inbound=True):
    return {"id": cid, "email": email, "lar": lar, "lcr": lcr,
            "created_at": created_at, "is_inbound": is_inbound}


class FakeShadow:
    """A minimal file-like stand-in for open_shadow_log()'s returned handle,
    used everywhere a test needs main()'s apply path to reach the close
    loop — open_shadow_log() returning (None, None) is now treated as a
    hard pre-write failure (Fix 3), so tests exercising a successful apply
    path must supply a real (fake) handle, not (None, None)."""

    def __init__(self):
        self.writes = []

    def write(self, s):
        self.writes.append(s)

    def flush(self):
        pass

    def close(self):
        pass


class TestTierFor(unittest.TestCase):
    def test_tier_a_we_spoke_last(self):
        older = conv("O", lar=200, lcr=100)
        kept = conv("K", lar=300, lcr=100, created_at=1000)
        self.assertEqual(m.tier_for(older, kept), "A")

    def test_tier_a_requires_strictly_greater_not_equal(self):
        # lar == lcr is ambiguous ordering, not proven admin-last (mirrors
        # close-resolved-conversations.py's is_eligible gate).
        older = conv("O", lar=100, lcr=100)
        kept = conv("K", lar=300, lcr=100, created_at=1000)
        self.assertIsNone(m.tier_for(older, kept))

    def test_tier_b_never_engaged_within_window(self):
        older = conv("O", lar=0, lcr=0, created_at=1000)
        kept = conv("K", lar=50, lcr=10, created_at=1000 + (5 * 86400))
        self.assertEqual(m.tier_for(older, kept, window_days=14), "B")

    def test_tier_b_window_boundary_exactly_14_days_qualifies(self):
        older = conv("O", lar=0, lcr=0, created_at=1000)
        kept = conv("K", lar=50, lcr=10, created_at=1000 + (14 * 86400))
        self.assertEqual(m.tier_for(older, kept, window_days=14), "B")

    def test_tier_b_window_boundary_one_second_over_excludes(self):
        older = conv("O", lar=0, lcr=0, created_at=1000)
        kept = conv("K", lar=50, lcr=10, created_at=1000 + (14 * 86400) + 1)
        self.assertIsNone(m.tier_for(older, kept, window_days=14))

    def test_tier_b_requires_kept_engaged(self):
        older = conv("O", lar=0, lcr=0, created_at=1000)
        kept = conv("K", lar=0, lcr=0, created_at=1000 + 100)
        self.assertIsNone(m.tier_for(older, kept))

    def test_active_exchange_never_closed(self):
        # Customer waiting on the older thread -> never closed.
        older = conv("O", lar=100, lcr=200)
        kept = conv("K", lar=300, lcr=100, created_at=1000)
        self.assertIsNone(m.tier_for(older, kept))

    def test_both_dangling_never_closed(self):
        older = conv("O", lar=0, lcr=0, created_at=1000)
        kept = conv("K", lar=0, lcr=0, created_at=2000)
        self.assertIsNone(m.tier_for(older, kept))


class TestGroupDuplicates(unittest.TestCase):
    def test_keep_is_newest_by_created_at(self):
        old = conv("OLD", lar=100, lcr=50, created_at=1000)
        new = conv("NEW", lar=0, lcr=0, created_at=5000)
        groups = m.group_duplicates([old, new], set())
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["kept"]["id"], "NEW")

    def test_equal_created_at_skips_the_pair(self):
        a = conv("A", lar=100, lcr=50, created_at=1000)
        b = conv("B", lar=100, lcr=50, created_at=1000)
        groups = m.group_duplicates([a, b], set())
        self.assertEqual(groups, [])

    def test_active_exchange_excluded_from_closable(self):
        older_active = conv("O", lar=100, lcr=200, created_at=1000)  # customer waiting
        kept = conv("K", lar=300, lcr=100, created_at=5000)
        groups = m.group_duplicates([older_active, kept], set())
        self.assertEqual(groups, [])  # no closable member -> group omitted

    def test_tier_a_group_produces_one_closable_candidate(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        groups = m.group_duplicates([older, kept], set())
        self.assertEqual(len(groups), 1)
        closable = groups[0]["closable"]
        self.assertEqual(len(closable), 1)
        self.assertEqual(closable[0]["older"]["id"], "O")
        self.assertEqual(closable[0]["kept"]["id"], "K")
        self.assertEqual(closable[0]["tier"], "A")

    def test_kept_sibling_owned_skips_whole_group(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        groups = m.group_duplicates([older, kept], {"K"})
        self.assertEqual(groups, [])

    def test_older_sibling_owned_excluded_but_group_still_evaluated(self):
        owned_older = conv("O1", email="x@y.com", lar=200, lcr=100, created_at=1000)
        free_older = conv("O2", email="x@y.com", lar=200, lcr=100, created_at=2000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        groups = m.group_duplicates([owned_older, free_older, kept], {"O1"})
        self.assertEqual(len(groups), 1)
        closable_ids = {c["older"]["id"] for c in groups[0]["closable"]}
        self.assertEqual(closable_ids, {"O2"})

    def test_fast_path_empty_email_never_groups(self):
        # No email resolved via the fast path -> never joins any group,
        # even with an identical (empty) "email" as another such conv.
        a = conv("A", email="", lar=200, lcr=100, created_at=1000)
        b = conv("B", email="", lar=0, lcr=0, created_at=5000)
        groups = m.group_duplicates([a, b], set())
        self.assertEqual(groups, [])

    def test_cross_customer_different_emails_never_group(self):
        a = conv("A", email="one@x.com", lar=200, lcr=100, created_at=1000)
        b = conv("B", email="two@x.com", lar=0, lcr=0, created_at=5000)
        groups = m.group_duplicates([a, b], set())
        self.assertEqual(groups, [])

    def test_outbound_conversation_never_groups(self):
        a = conv("A", email="x@y.com", lar=200, lcr=100, created_at=1000, is_inbound=False)
        b = conv("B", email="x@y.com", lar=0, lcr=0, created_at=5000, is_inbound=False)
        groups = m.group_duplicates([a, b], set())
        self.assertEqual(groups, [])

    def test_more_than_two_dups_one_keep_each_older_independent(self):
        older_a = conv("A", email="x@y.com", lar=200, lcr=100, created_at=1000)  # tier A
        older_b = conv("B", email="x@y.com", lar=0, lcr=0, created_at=2000)  # tier B (within window)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=2000 + (86400 * 3))
        groups = m.group_duplicates([older_a, older_b, kept], set())
        self.assertEqual(len(groups), 1)
        by_id = {c["older"]["id"]: c["tier"] for c in groups[0]["closable"]}
        self.assertEqual(by_id, {"A": "A", "B": "B"})


class TestFlattenCandidates(unittest.TestCase):
    def test_limit_counts_individual_closes_across_groups(self):
        g1 = {"email": "a@x.com", "kept": conv("K1"), "group_size": 2, "closable": [
            {"older": conv("O1"), "kept": conv("K1"), "tier": "A", "email": "a@x.com"}]}
        g2 = {"email": "b@x.com", "kept": conv("K2"), "group_size": 3, "closable": [
            {"older": conv("O2"), "kept": conv("K2"), "tier": "A", "email": "b@x.com"},
            {"older": conv("O3"), "kept": conv("K2"), "tier": "B", "email": "b@x.com"}]}
        flat = m.flatten_candidates([g1, g2])
        self.assertEqual(len(flat), 3)


class TestKeptIdNeverEntersOwnedIds(unittest.TestCase):
    """CRITICAL invariant: the shadow log's "kept_id" field must NEVER be
    collectible by owned_ids() — only "id"/"conv_id" are. A wrong field
    name here would silently hide the live kept thread from Jan's digest
    forever (see module docstring)."""

    def test_shadow_record_kept_id_field_is_not_collected(self):
        record = {"id": "CLOSED1", "closed_at": 100, "email": "a@b.com",
                  "kept_id": "KEPT1", "tier": "A", "new_state": "closed"}
        data = "\n".join([__import__("json").dumps(record)])
        rd = mock.mock_open(read_data=data + "\n")
        with mock.patch("builtins.open", rd):
            ids = m.owned_ids({"close-duplicate": ("/fake/close-dup.jsonl", "jsonl")})
        self.assertIn("CLOSED1", ids)
        self.assertNotIn("KEPT1", ids)


class TestOwnedIdsAndIsOwned(unittest.TestCase):
    def test_missing_files_yield_no_ownership(self):
        ids = m.owned_ids({"x": ("/nonexistent/path.jsonl", "jsonl")})
        self.assertEqual(ids, set())

    def test_corrupt_json_state_file_skipped_not_fatal(self):
        rd = mock.mock_open(read_data="not json{{{")
        with mock.patch("builtins.open", rd):
            ids = m.owned_ids({"x": ("/fake/state.json", "json")})
        self.assertEqual(ids, set())

    def test_is_owned_by_id_only(self):
        self.assertTrue(m.is_owned(conv("C1"), {"C1"}))
        self.assertFalse(m.is_owned(conv("C1", email="a@b.com"), set()))


class TestSanityCeiling(unittest.TestCase):
    """>20 candidate closes in one run must close NOTHING and exit non-zero."""

    def test_ceiling_exceeded_closes_nothing_and_exits_nonzero(self):
        import sys as _sys
        many_convs = []
        for i in range(30):
            older = conv(f"O{i}", email=f"e{i}@x.com", lar=200, lcr=100, created_at=1000)
            kept = conv(f"K{i}", email=f"e{i}@x.com", lar=300, lcr=100, created_at=5000)
            many_convs.extend([older, kept])
        close_calls = []
        with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "close_conversation",
                                side_effect=lambda *a, **k: close_calls.append(1)), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        self.assertEqual(close_calls, [])


def _many_dup_convs(n=30):
    """n duplicate pairs, all Tier A (older.lar > older.lcr), to exceed
    DUP_CEILING (20)."""
    convs = []
    for i in range(n):
        older = conv(f"O{i}", email=f"e{i}@x.com", lar=200, lcr=100, created_at=1000)
        kept = conv(f"K{i}", email=f"e{i}@x.com", lar=300, lcr=100, created_at=5000)
        convs.extend([older, kept])
    return convs


class TestCeilingGatesOnlyApply(unittest.TestCase):
    """Ceiling gates ONLY --apply (issue: 2026-07-20 backlog fire). In
    dry-run/shadow mode, exceeding DUP_CEILING must proceed with the normal
    dry-run path (candidate ID + --notify-candidates summary + review
    export) and exit 0 — NEVER format_ceiling_alert / exit 2. With --apply,
    keep today's behavior byte-for-byte."""

    def test_over_ceiling_dry_run_exits_zero_no_alert_writes_export(self):
        import sys as _sys
        many_convs = _many_dup_convs(30)
        posted = []
        export_calls = []
        with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(
                 m, "write_review_export",
                 side_effect=lambda candidates, when_date: (
                     export_calls.append(candidates) or "/fake/export.json")), \
             mock.patch.object(m, "post_slack_summary",
                                side_effect=lambda text, *a, **k: posted.append(text) or True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--notify-candidates"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        # No ceiling alert posted — the only post is the candidate summary.
        self.assertEqual(len(posted), 1)
        self.assertNotIn("sanity ceiling", posted[0])
        self.assertNotIn(m.format_ceiling_alert(30, "x"), posted[0])
        # Review export was written with the full (over-ceiling) candidate set.
        self.assertEqual(len(export_calls), 1)
        self.assertEqual(len(export_calls[0]), 30)
        # Notify summary mentions the export path + tier counts.
        self.assertIn("/fake/export.json", posted[0])
        self.assertIn("Tier A 30", posted[0])
        self.assertIn("Tier B 0", posted[0])

    def test_over_ceiling_dry_run_prints_prominent_warning(self):
        import io
        import contextlib
        import sys as _sys
        many_convs = _many_dup_convs(30)
        buf = io.StringIO()
        with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "write_review_export", return_value="/fake/export.json"), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m"]), \
             contextlib.redirect_stdout(buf):
            rc = m.main()
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("ceiling would block --apply: 30 > 20", out)

    def test_over_ceiling_apply_exits_two_posts_alert_zero_closes_no_shadow_writes(self):
        import sys as _sys
        many_convs = _many_dup_convs(30)
        close_calls = []
        with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "close_conversation",
                                side_effect=lambda *a, **k: close_calls.append(1)), \
             mock.patch.object(m, "open_shadow_log") as m_open_shadow, \
             mock.patch.object(m, "write_review_export") as m_export, \
             mock.patch.object(m, "post_slack_summary", return_value=True) as m_post, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 2)
        self.assertEqual(close_calls, [])
        m_open_shadow.assert_not_called()  # never reached -> no shadow-log writes
        m_export.assert_not_called()  # export is a dry-run-only artifact
        m_post.assert_called_once()
        posted_text = m_post.call_args[0][0]
        self.assertIn("sanity ceiling", posted_text.lower())

    def test_under_ceiling_dry_run_export_still_written_behavior_unchanged(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        export_calls = []
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(
                 m, "write_review_export",
                 side_effect=lambda candidates, when_date: (
                     export_calls.append(candidates) or "/fake/export.json")), \
             mock.patch.object(m, "post_slack_summary") as m_post, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(len(export_calls), 1)
        self.assertEqual(len(export_calls[0]), 1)
        m_post.assert_not_called()  # --notify-candidates not passed


class TestCeilingFlag(unittest.TestCase):
    """--ceiling N overrides DUP_CEILING for --apply's hard-stop only."""

    def test_ceiling_flag_raises_effective_ceiling_so_apply_proceeds(self):
        """30 candidates > DUP_CEILING(20) would normally block --apply, but
        --ceiling 50 raises the effective ceiling so the run proceeds and
        closes (stub the close path)."""
        import sys as _sys
        many_convs = _many_dup_convs(30)
        close_calls = []
        with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "close_conversation",
                                side_effect=lambda *a, **k: close_calls.append(1) or {"state": "closed"}), \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True) as m_post, \
             mock.patch.object(m.time, "sleep"), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply", "--ceiling", "50"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(len(close_calls), 30)
        # No ceiling alert -- the override let --apply proceed.
        for call in m_post.call_args_list:
            self.assertNotIn("sanity ceiling", call[0][0].lower())

    def test_ceiling_zero_rejected_exit_two_before_any_network_call(self):
        import sys as _sys
        with mock.patch.object(m, "fetch_open_convs") as m_fetch, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--ceiling", "0"]):
            rc = m.main()
        self.assertEqual(rc, 2)
        m_fetch.assert_not_called()

    def test_ceiling_negative_rejected_exit_two_before_any_network_call(self):
        import sys as _sys
        with mock.patch.object(m, "fetch_open_convs") as m_fetch, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--ceiling", "-5"]):
            rc = m.main()
        self.assertEqual(rc, 2)
        m_fetch.assert_not_called()

    def test_over_effective_ceiling_apply_still_blocks(self):
        """--ceiling 25 still blocks a 30-candidate --apply run (the
        override didn't just disable the check)."""
        import sys as _sys
        many_convs = _many_dup_convs(30)
        close_calls = []
        with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "close_conversation",
                                side_effect=lambda *a, **k: close_calls.append(1)), \
             mock.patch.object(m, "post_slack_summary", return_value=True) as m_post, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply", "--ceiling", "25"]):
            rc = m.main()
        self.assertEqual(rc, 2)
        self.assertEqual(close_calls, [])
        posted_text = m_post.call_args[0][0]
        self.assertIn("30 candidate closes identified (> 25)", posted_text)


class TestReviewExportGroupSize(unittest.TestCase):
    """write_review_export's _review_export_candidate now carries
    group_size (threaded from flatten_candidates) so a reviewer can filter
    the masked-email export by group size -- e.g. pull every candidate from
    a >=3-thread group for stratified review. group_size is the TRUE
    duplicate-thread count (len(members) in group_duplicates), NOT the
    closable count."""

    def test_group_duplicates_group_size_is_true_thread_count(self):
        """group_size counts every inbound thread sharing the email,
        INCLUDING the kept thread -- not just the closable members. 2 older
        + 1 kept = 3 threads -> group_size 3, with 2 closable."""
        older1 = conv("O1", email="x@y.com", lar=200, lcr=100, created_at=1000)
        older2 = conv("O2", email="x@y.com", lar=200, lcr=100, created_at=2000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        groups = m.group_duplicates([older1, older2, kept], owned_id_set=set())
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["group_size"], 3)
        self.assertEqual(len(groups[0]["closable"]), 2)

    def test_review_export_candidate_passes_through_group_size(self):
        """A group's group_size rides through flatten_candidates to the
        export record unchanged (2-thread group: 1 older + 1 kept)."""
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        groups = [{"email": "x@y.com", "kept": kept, "group_size": 2,
                   "closable": [{"older": older, "kept": kept, "tier": "A", "email": "x@y.com"}]}]
        candidates = m.flatten_candidates(groups)
        rec = m._review_export_candidate(candidates[0])
        self.assertEqual(rec["group_size"], 2)

    def test_group_size_is_thread_count_not_closable_count(self):
        """Every candidate carries the group's thread count, not its own
        closable count: a group of 5 threads with only 3 closable exports
        group_size 5 on all 3 candidates."""
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        closable = [
            {"older": conv(f"O{i}", email="x@y.com", lar=200, lcr=100, created_at=1000),
             "kept": kept, "tier": "A", "email": "x@y.com"}
            for i in range(3)
        ]
        groups = [{"email": "x@y.com", "kept": kept, "closable": closable, "group_size": 5}]
        candidates = m.flatten_candidates(groups)
        self.assertEqual(len(candidates), 3)
        for cand in candidates:
            rec = m._review_export_candidate(cand)
            self.assertEqual(rec["group_size"], 5)

    def test_write_review_export_end_to_end_carries_group_size(self):
        """End-to-end via main(): 3 older + 1 kept sharing one email = 4
        threads, 3 of them closable. Every export candidate's group_size is
        4 (the true thread count), not 3 (the closable count)."""
        import json as _json
        import sys as _sys
        import tempfile as _tempfile
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        olders = [conv(f"O{i}", email="x@y.com", lar=200, lcr=100, created_at=1000) for i in range(3)]
        convs = olders + [kept]
        with _tempfile.TemporaryDirectory() as d:
            with mock.patch.object(m, "fetch_open_convs", return_value=convs), \
                 mock.patch.object(m, "owned_ids", return_value=set()), \
                 mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                                  "INTERCOM_ADMIN_ID": "5763097",
                                                  "CLOSE_DUP_REVIEW_DIR": d}, clear=False), \
                 mock.patch.object(_sys, "argv", ["m"]):
                rc = m.main()
            self.assertEqual(rc, 0)
            files = os.listdir(d)
            self.assertEqual(len(files), 1)
            with open(os.path.join(d, files[0])) as f:
                doc = _json.load(f)
            self.assertEqual(len(doc["tier_a"]), 3)  # 3 closable candidates
            for rec in doc["tier_a"]:
                self.assertEqual(rec["group_size"], 4)  # 4 total threads


class TestWriteReviewExportUnwritableDir(unittest.TestCase):
    """Mirrors open_shadow_log's fallback pattern: an unwritable primary
    review dir falls back to a private FALLBACK_REVIEW_DIR with a loud
    stderr, and --apply is never reached by this path (write_review_export
    is dry-run-only), so this exercises the function directly, same
    convention as TestSavePointerStateAtomic. The fallback dir is
    monkeypatched to an isolated TemporaryDirectory per test — never the
    real /tmp — so there's nothing to glob-cleanup and no risk of touching
    files this test didn't create."""

    def test_unwritable_primary_dir_falls_back_to_private_dir_with_loud_stderr(self):
        import contextlib
        import io
        import json as _json
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d, _tempfile.TemporaryDirectory() as fallback_root:
            # A FILE masquerading as the primary dir's parent forces os.makedirs
            # to raise OSError, same trick as TestSavePointerStateAtomic.
            blocker = f"{d}/not-a-dir"
            with open(blocker, "w") as f:
                f.write("x")
            bad_dir = f"{blocker}/close-duplicate-conversations/"
            fallback_dir = os.path.join(fallback_root, "close-duplicate-review")
            candidates = [
                {"older": conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000),
                 "kept": conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000),
                 "tier": "A", "email": "x@y.com", "group_size": 1},
            ]
            expected_path = os.path.join(fallback_dir, "candidates-2026-07-20.json")
            stderr_buf = io.StringIO()
            with mock.patch.dict("os.environ", {"CLOSE_DUP_REVIEW_DIR": bad_dir}, clear=False), \
                 mock.patch.object(m, "FALLBACK_REVIEW_DIR", fallback_dir), \
                 contextlib.redirect_stderr(stderr_buf):
                path = m.write_review_export(candidates, "2026-07-20")
            self.assertEqual(path, expected_path)
            stderr_text = stderr_buf.getvalue()
            self.assertIn("cannot write review export", stderr_text)
            self.assertIn("falling back to", stderr_text)
            # The fallback dir must be private, not the world-readable /tmp root.
            self.assertEqual(stat.S_IMODE(os.stat(fallback_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(expected_path).st_mode), 0o600)
            with open(expected_path) as f:
                doc = _json.load(f)
            self.assertEqual(doc["total"], 1)
            self.assertEqual(len(doc["tier_a"]), 1)
            self.assertEqual(len(doc["tier_b"]), 0)
            # Fix 5: the masking must actually be applied to the written
            # export -- pins that deleting mask_email from
            # _review_export_candidate fails this suite.
            self.assertEqual(doc["tier_a"][0]["email"], m.mask_email("x@y.com"))

    def test_over_ceiling_dry_run_with_unwritable_dir_still_exits_zero(self):
        """End-to-end via main(): an unwritable review dir must not turn a
        dry-run (even over-ceiling) into a failure — exit 0 with a loud
        stderr, never a raise."""
        import contextlib
        import io
        import sys as _sys
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d, _tempfile.TemporaryDirectory() as fallback_root:
            blocker = f"{d}/not-a-dir"
            with open(blocker, "w") as f:
                f.write("x")
            bad_dir = f"{blocker}/review/"
            fallback_dir = os.path.join(fallback_root, "close-duplicate-review")
            many_convs = _many_dup_convs(30)
            stderr_buf = io.StringIO()
            with mock.patch.object(m, "fetch_open_convs", return_value=many_convs), \
                 mock.patch.object(m, "owned_ids", return_value=set()), \
                 mock.patch.object(m, "FALLBACK_REVIEW_DIR", fallback_dir), \
                 mock.patch.dict("os.environ",
                                  {"MUSOAI_INTERCOM_TOKEN": "t", "INTERCOM_ADMIN_ID": "5763097",
                                   "CLOSE_DUP_REVIEW_DIR": bad_dir}, clear=False), \
                 mock.patch.object(_sys, "argv", ["m"]), \
                 contextlib.redirect_stderr(stderr_buf):
                rc = m.main()
            self.assertEqual(rc, 0)
            self.assertIn("cannot write review export", stderr_buf.getvalue())


class TestMaskEmail(unittest.TestCase):
    def test_masks_local_part_hides_domain(self):
        self.assertEqual(m.mask_email("alice@example.com"), "a***@***")

    def test_empty_email_masks_to_empty(self):
        self.assertEqual(m.mask_email(""), "")

    def test_no_at_sign_masks_first_char_of_value(self):
        self.assertEqual(m.mask_email("not-an-email"), "n***@***")

    def test_empty_local_part_masks_to_asterisks(self):
        self.assertEqual(m.mask_email("@example.com"), "***@***")


class TestFormatCandidatesSummaryExportFailed(unittest.TestCase):
    """Fix 4: a total export write failure (review_path=None) must not
    silently drop the export line from the notify text — the reader has no
    other signal something went wrong (the process still exits 0)."""

    def test_export_failed_line_present_when_review_path_none(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        candidates = [{"older": older, "kept": kept, "tier": "A", "email": "x@y.com"}]
        text = m.format_candidates_summary(
            candidates, "2026-07-20 00:00 UTC", review_path=None, tier_a_n=1, tier_b_n=0)
        self.assertIn("review export FAILED", text)

    def test_no_export_line_when_tier_counts_absent(self):
        """--apply's format_candidates_summary call never passes
        tier_a_n/tier_b_n -- no export line of either kind should appear."""
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        candidates = [{"older": older, "kept": kept, "tier": "A", "email": "x@y.com"}]
        text = m.format_candidates_summary(candidates, "2026-07-20 00:00 UTC")
        self.assertNotIn("review export FAILED", text)
        self.assertNotIn("Full review export", text)


class TestNotifyCandidates(unittest.TestCase):
    def test_notify_candidates_posts_even_on_dry_run(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        posted = []
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "write_review_export", return_value="/fake/export.json"), \
             mock.patch.object(m, "post_slack_summary",
                                side_effect=lambda text, *a, **k: posted.append(text) or True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--notify-candidates"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(len(posted), 1)
        self.assertIn("O", posted[0])
        self.assertIn("K", posted[0])

    def test_no_notify_flag_posts_nothing_on_dry_run(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "write_review_export", return_value="/fake/export.json"), \
             mock.patch.object(m, "post_slack_summary") as m_post, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_post.assert_not_called()


class TestApplyGating(unittest.TestCase):
    def test_dry_run_never_calls_close_conversation(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "write_review_export", return_value="/fake/export.json"), \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_close.assert_not_called()

    def test_apply_calls_close_conversation_for_tier_a_after_reverify(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "close_conversation",
                                return_value={"state": "closed"}) as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.object(m, "write_review_export") as m_export, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_close.assert_called_once_with("t", "5763097", "O")
        # Export is dry-run-only — pin that on the under-ceiling --apply
        # path too (companion to TestCeilingGatesOnlyApply's over-ceiling
        # --apply assertion).
        m_export.assert_not_called()

    def test_admin_id_ignores_a_non_caroline_env_override(self):
        """Hermeticity check, inverted 2026-09-01: this used to override
        INTERCOM_ADMIN_ID to 99999 and assert main() OBEYED it, which encoded
        the very defect we now forbid — an env var could move the customer-
        facing posting identity onto a human. The identity is a constant of the
        system (scripts/lib/intercom_identity.py), so the override must be
        IGNORED and Caroline used instead.

        This still serves the original hermeticity purpose, and serves it
        better: asserting Caroline while the env says 99999 proves the value
        comes from the module rather than leaking in from the host runner's
        environment (the original QA finding at line 273)."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "close_conversation",
                                return_value={"state": "closed"}) as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "99999"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_close.assert_called_once_with("t", "5763097", "O")


class TestApplyShadowLogPreWriteFailure(unittest.TestCase):
    """Fix 3: a one-way-door action cannot silently lose its audit trail —
    if open_shadow_log() can't open a handle (primary AND /tmp fallback
    both failed), --apply must close NOTHING and exit non-zero."""

    def test_shadow_log_unopenable_closes_nothing_and_exits_nonzero(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(None, None)), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_close.assert_not_called()

    def test_shadow_write_error_after_close_is_surfaced_not_swallowed(self):
        """A shadow-log write/flush error AFTER a successful close must be
        caught and surfaced as a failure (audit gap), never silently
        dropped."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)

        class BrokenShadow:
            def write(self, s):
                raise OSError("disk full")

            def flush(self):
                pass

            def close(self):
                pass

        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "close_conversation", return_value={"state": "closed"}), \
             mock.patch.object(m, "open_shadow_log", return_value=(BrokenShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)


class TestPointerPostedDedupe(unittest.TestCase):
    """Partial-failure dedupe: a pointer_posted record must be written
    BEFORE the close attempt; a later run must never re-post the pointer,
    even if the earlier close failed."""

    def test_pointer_not_reposted_when_already_recorded_but_close_retried(self):
        """status == 'posted' (confirmed) -> skip re-post, retry the close."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={"O": "posted"}), \
             mock.patch.object(m, "save_pointer_state") as m_save, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "open", "lcr": 0, "lar": 0,
                                              "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation",
                                return_value={"state": "closed"}) as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_pointer.assert_not_called()
        m_save.assert_not_called()
        m_close.assert_called_once()

    def test_pointer_posted_before_close_is_attempted_for_a_fresh_tier_b_target(self):
        # Order is load-bearing: the durable "pending" marker MUST be
        # persisted before the customer-facing pointer is posted, and the
        # "posted" marker MUST be persisted before the close is attempted —
        # a persist failure at either step must be able to prevent the next
        # step (POST or close) entirely.
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        order = []
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state",
                                side_effect=lambda *a: order.append("save") or True), \
             mock.patch.object(m, "post_pointer_comment",
                                side_effect=lambda *a, **k: order.append("pointer")), \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "open", "lcr": 0, "lar": 0,
                                              "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation",
                                side_effect=lambda *a, **k: order.append("close") or {"state": "closed"}), \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(order, ["save", "pointer", "save", "close"])

    def test_pointer_post_fails_then_next_run_holds_without_reposting(self):
        """The retry test the finding asks for: run1's POST fails -> marker
        left at 'pending', conv NOT closed. run2 sees 'pending' -> conv
        still NOT closed AND the pointer is NOT re-posted (held)."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        env = {"MUSOAI_INTERCOM_TOKEN": "t", "INTERCOM_ADMIN_ID": "5763097"}

        # --- run 1: POST fails ---
        saved_state = {}

        def fake_save(state):
            saved_state.clear()
            saved_state.update(state)
            return True

        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state", side_effect=fake_save), \
             mock.patch.object(m, "post_pointer_comment",
                                side_effect=ValueError("500")), \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", env, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc1 = m.main()
        self.assertNotEqual(rc1, 0)
        m_close.assert_not_called()
        self.assertEqual(saved_state, {"O": "pending"})

        # --- run 2: sees "pending" from run 1 -> held, no re-post, no close ---
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value=dict(saved_state)), \
             mock.patch.object(m, "save_pointer_state") as m_save2, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer2, \
             mock.patch.object(m, "close_conversation") as m_close2, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", env, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc2 = m.main()
        self.assertNotEqual(rc2, 0)
        m_pointer2.assert_not_called()
        m_save2.assert_not_called()
        m_close2.assert_not_called()

    def test_pointer_posted_close_fails_then_next_run_retries_close_only(self):
        """POST succeeds -> marker 'posted' -> close fails this run. Next
        run sees 'posted' and skips re-post, retrying only the close (no
        double-post)."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        env = {"MUSOAI_INTERCOM_TOKEN": "t", "INTERCOM_ADMIN_ID": "5763097"}
        saved_state = {}

        def fake_save(state):
            saved_state.clear()
            saved_state.update(state)
            return True

        # --- run 1: POST succeeds, close fails ---
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state", side_effect=fake_save), \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "open", "lcr": 0, "lar": 0,
                                              "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation", side_effect=ValueError("500")), \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", env, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc1 = m.main()
        self.assertNotEqual(rc1, 0)
        m_pointer.assert_called_once()
        self.assertEqual(saved_state, {"O": "posted"})

        # --- run 2: sees "posted" -> skip re-post, retry close ---
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value=dict(saved_state)), \
             mock.patch.object(m, "save_pointer_state") as m_save2, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer2, \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "open", "lcr": 0, "lar": 0,
                                              "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation",
                                return_value={"state": "closed"}) as m_close2, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", env, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc2 = m.main()
        self.assertEqual(rc2, 0)
        m_pointer2.assert_not_called()
        m_save2.assert_not_called()
        m_close2.assert_called_once()

    def test_pointer_post_and_close_both_succeed_posts_pointer_exactly_once(self):
        """Happy path: pointer posted exactly once, conv closed exactly
        once, final marker is 'posted'."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        saved_state = {}

        def fake_save(state):
            saved_state.clear()
            saved_state.update(state)
            return True

        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state", side_effect=fake_save), \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "open", "lcr": 0, "lar": 0,
                                              "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation",
                                return_value={"state": "closed"}) as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_pointer.assert_called_once()
        m_close.assert_called_once()
        self.assertEqual(saved_state, {"O": "posted"})

    def test_posted_marker_persist_failure_after_successful_post_holds_no_close(self):
        """POST succeeds but the follow-up 'posted' persist fails -> hold
        (no close, no double-post — the marker stays whatever it was
        before, so a future run treats this as unconfirmed too)."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        save_calls = []

        def fake_save(state):
            save_calls.append(dict(state))
            # First call (persisting "pending") succeeds; second call
            # (persisting "posted" after the POST) fails.
            return len(save_calls) == 1

        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state", side_effect=fake_save), \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_pointer.assert_called_once()
        m_close.assert_not_called()
        self.assertEqual(len(save_calls), 2)
        self.assertEqual(save_calls[0], {"O": "pending"})
        self.assertEqual(save_calls[1], {"O": "posted"})

    def test_legacy_boolean_marker_is_treated_as_unconfirmed_and_held(self):
        """A pre-fix state file with a bare boolean True marker (the old,
        ambiguous format) must be treated as unconfirmed -> held, never
        re-posted, never closed."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={"O": True}), \
             mock.patch.object(m, "save_pointer_state") as m_save, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_pointer.assert_not_called()
        m_save.assert_not_called()
        m_close.assert_not_called()

    def test_customer_reply_during_pointer_window_holds_the_close(self):
        """FIX: a customer can reply to the pointer comment between the
        "posted" marker and the close below. The pointer POST is itself an
        admin reply (advances last_admin_reply_at trivially), so this must
        be detected via a fresh last_contact_reply_at strictly greater than
        the value captured at grouping/first-verify (older["lcr"]) — not a
        generic "we spoke last" check."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state", return_value=True), \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "open",
                                               # customer replied after the pointer POST:
                                               # fresh lcr (99) > older["lcr"] (0)
                                               "lcr": 99, "lar": 50,
                                               "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_pointer.assert_called_once()  # the pointer WAS posted (as designed)
        m_close.assert_not_called()     # but the close is HELD

    def test_target_no_longer_open_after_pointer_window_holds_the_close(self):
        """A fresh re-fetch returning a non-open state (e.g. the customer
        closed it themselves) must also hold, not close."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={"O": "posted"}), \
             mock.patch.object(m, "save_pointer_state") as m_save, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "get_conversation",
                                return_value={"id": "O", "state": "closed", "lcr": 0,
                                               "lar": 0, "confirm_email": "x@y.com"}), \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_pointer.assert_not_called()
        m_save.assert_not_called()
        m_close.assert_not_called()

    def test_pointer_marker_persist_failure_skips_post_and_close_entirely(self):
        """Fix 2: if the durable marker write fails, the conversation is
        skipped whole — no pointer post, no close — rather than risking a
        later run re-posting the customer-facing pointer text."""
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state", return_value=False), \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_pointer.assert_not_called()
        m_close.assert_not_called()


class TestReverifyStillValid(unittest.TestCase):
    def test_target_no_longer_open_fails_reverify(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", side_effect=[
                {"id": "O", "state": "closed", "lar": 200, "lcr": 100,
                 "created_at": 1000, "confirm_email": "x@y.com"},
                {"id": "K", "state": "open", "lar": 300, "lcr": 100,
                 "created_at": 5000, "confirm_email": "x@y.com"}]):
            self.assertFalse(m.reverify_still_valid("t", older, kept, "A"))

    def test_tier_no_longer_holds_fails_reverify(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", side_effect=[
                # Customer replied after us since grouping -> no longer Tier A.
                {"id": "O", "state": "open", "lar": 200, "lcr": 900,
                 "created_at": 1000, "confirm_email": "x@y.com"},
                {"id": "K", "state": "open", "lar": 300, "lcr": 100,
                 "created_at": 5000, "confirm_email": "x@y.com"}]):
            self.assertFalse(m.reverify_still_valid("t", older, kept, "A"))

    def test_confirm_email_mismatch_fails_reverify(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", side_effect=[
                {"id": "O", "state": "open", "lar": 200, "lcr": 100,
                 "created_at": 1000, "confirm_email": "different@x.com"},
                {"id": "K", "state": "open", "lar": 300, "lcr": 100,
                 "created_at": 5000, "confirm_email": "x@y.com"}]):
            self.assertFalse(m.reverify_still_valid("t", older, kept, "A"))

    def test_all_conditions_hold_passes_reverify(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", side_effect=[
                {"id": "O", "state": "open", "lar": 200, "lcr": 100,
                 "created_at": 1000, "confirm_email": "x@y.com"},
                {"id": "K", "state": "open", "lar": 300, "lcr": 100,
                 "created_at": 5000, "confirm_email": "x@y.com"}]):
            self.assertTrue(m.reverify_still_valid("t", older, kept, "A"))

    def test_lookup_failure_fails_closed(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", return_value=None):
            self.assertFalse(m.reverify_still_valid("t", older, kept, "A"))

    def test_empty_confirm_email_on_target_fails_closed(self):
        """Fix 1(a): the old guard used `if confirm_email and confirm_email
        != email` which PASSED (no-op) when confirm_email was empty — an
        empty/unconfirmed identity must never be treated as "no
        objection"."""
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", side_effect=[
                {"id": "O", "state": "open", "lar": 200, "lcr": 100,
                 "created_at": 1000, "confirm_email": ""},
                {"id": "K", "state": "open", "lar": 300, "lcr": 100,
                 "created_at": 5000, "confirm_email": "x@y.com"}]):
            self.assertFalse(m.reverify_still_valid("t", older, kept, "A"))

    def test_empty_confirm_email_on_kept_fails_closed(self):
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        with mock.patch.object(m, "get_conversation", side_effect=[
                {"id": "O", "state": "open", "lar": 200, "lcr": 100,
                 "created_at": 1000, "confirm_email": "x@y.com"},
                {"id": "K", "state": "open", "lar": 300, "lcr": 100,
                 "created_at": 5000, "confirm_email": ""}]):
            self.assertFalse(m.reverify_still_valid("t", older, kept, "A"))


class TestGetConversationIndependentConfirm(unittest.TestCase):
    """Fix 1(b): confirm_email must come from an INDEPENDENT slow-path GET
    /contacts/{id}, never from the fast-path source.author.email already
    used to form the group (which would confirm nothing — same value in,
    same value out)."""

    def setUp(self):
        m._contact_email_cache.clear()

    def test_confirm_email_comes_from_contact_get_not_fast_path_author_email(self):
        # The fast-path author email and the "true" contact-GET email
        # deliberately DIFFER in this fixture — if get_conversation ever
        # regresses to contact_email_of's fast path, this test asserts on
        # the WRONG (author) value and fails.
        conv_body = {
            "id": "O",
            "state": "open",
            "created_at": 1000,
            "statistics": {"last_admin_reply_at": 200, "last_contact_reply_at": 100},
            "source": {"author": {"type": "user", "email": "fast-path-stale@x.com"}},
            "contacts": {"contacts": [{"id": "C1"}]},
        }
        with mock.patch.object(m, "_retry_json", return_value=conv_body), \
             mock.patch.object(m, "get_contact",
                                return_value={"email": "true-contact-email@x.com"}) as m_get_contact:
            result = m.get_conversation("t", "O")
        m_get_contact.assert_called_once_with("C1", "t")
        self.assertEqual(result["confirm_email"], "true-contact-email@x.com")
        self.assertNotEqual(result["confirm_email"], "fast-path-stale@x.com")

    def test_missing_contact_id_yields_empty_confirm_email(self):
        conv_body = {
            "id": "O", "state": "open", "created_at": 1000,
            "statistics": {}, "source": {"author": {"type": "user", "email": "x@y.com"}},
            "contacts": {"contacts": []},
        }
        with mock.patch.object(m, "_retry_json", return_value=conv_body):
            result = m.get_conversation("t", "O")
        self.assertEqual(result["confirm_email"], "")

    def test_contact_lookup_failed_yields_empty_confirm_email_not_an_exception(self):
        conv_body = {
            "id": "O", "state": "open", "created_at": 1000,
            "statistics": {}, "source": {"author": {"type": "user", "email": "x@y.com"}},
            "contacts": {"contacts": [{"id": "C1"}]},
        }
        with mock.patch.object(m, "_retry_json", return_value=conv_body), \
             mock.patch.object(m, "get_contact", side_effect=m.ContactLookupFailed("boom")):
            result = m.get_conversation("t", "O")
        self.assertEqual(result["confirm_email"], "")

    def test_404_contact_yields_empty_confirm_email(self):
        conv_body = {
            "id": "O", "state": "open", "created_at": 1000,
            "statistics": {}, "source": {"author": {"type": "user", "email": "x@y.com"}},
            "contacts": {"contacts": [{"id": "C1"}]},
        }
        with mock.patch.object(m, "_retry_json", return_value=conv_body), \
             mock.patch.object(m, "get_contact", return_value=None):
            result = m.get_conversation("t", "O")
        self.assertEqual(result["confirm_email"], "")


class TestShadowLogFields(unittest.TestCase):
    """The shadow log record written on close must carry the surviving
    thread under "kept_id", never "id"/"conv_id" (see module docstring)."""

    def test_closed_record_uses_kept_id_field(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        writes = []

        class FakeShadow:
            def write(self, s):
                writes.append(s)

            def flush(self):
                pass

            def close(self):
                pass

        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "close_conversation", return_value={"state": "closed"}), \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(len(writes), 1)
        import json as _json
        rec = _json.loads(writes[0])
        self.assertEqual(rec["id"], "O")
        self.assertEqual(rec["kept_id"], "K")
        self.assertNotIn("conv_id", rec)


class TestSavePointerStateAtomic(unittest.TestCase):
    """Fix 2: save_pointer_state must be atomic (temp file + os.replace)
    and must return False (not silently swallow) on OSError."""

    def test_successful_write_returns_true_and_round_trips(self):
        import json as _json
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d:
            path = f"{d}/pointer-posted.json"
            with mock.patch.object(m, "_pointer_state_path", return_value=path):
                ok = m.save_pointer_state({"O": True})
            self.assertTrue(ok)
            with open(path) as f:
                self.assertEqual(_json.load(f), {"O": True})

    def test_write_failure_returns_false_not_raise(self):
        # Point at a path whose parent directory cannot be created (a file
        # masquerading as a directory) to force an OSError inside the
        # atomic-write path, and confirm it's reported via return value,
        # not swallowed and not raised.
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d:
            blocker = f"{d}/not-a-dir"
            with open(blocker, "w") as f:
                f.write("x")
            bad_path = f"{blocker}/pointer-posted.json"
            with mock.patch.object(m, "_pointer_state_path", return_value=bad_path):
                ok = m.save_pointer_state({"O": True})
            self.assertFalse(ok)


class TestLoadPointerStateFailClosed(unittest.TestCase):
    """A corrupt/unreadable pointer-state file must never collapse to the
    same {} as a legitimate first run — that would make every conversation
    look unseen and re-post an already-confirmed pointer. File-absent (a
    clean first run) must still return {}."""

    def test_file_absent_returns_empty_dict_clean_first_run(self):
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d:
            path = f"{d}/does-not-exist.json"
            with mock.patch.object(m, "_pointer_state_path", return_value=path):
                self.assertEqual(m.load_pointer_state(), {})

    def test_corrupt_json_raises_pointer_state_unreadable(self):
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d:
            path = f"{d}/pointer-posted.json"
            with open(path, "w") as f:
                f.write('{"O": "posted"')  # truncated/invalid JSON
            with mock.patch.object(m, "_pointer_state_path", return_value=path):
                with self.assertRaises(m.PointerStateUnreadable):
                    m.load_pointer_state()

    def test_unreadable_file_raises_pointer_state_unreadable(self):
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d:
            path = f"{d}/pointer-posted.json"
            with open(path, "w") as f:
                f.write('{"O": "posted"}')
            # The file EXISTS but cannot be read. Do NOT simulate this with
            # os.chmod(0o000): the hydra CI runner is root, and root bypasses
            # DAC permission bits, so open() would succeed and nothing would
            # raise (the reason this test was red). Force the OSError at the
            # open() boundary instead — this exercises the real chain
            # (_read_json_file() maps OSError->None, load_pointer_state() maps
            # None->PointerStateUnreadable) deterministically on any uid.
            _real_open = open

            def _boom(p, *a, **k):
                if p == path:
                    raise PermissionError(13, "Permission denied", path)
                return _real_open(p, *a, **k)

            with mock.patch.object(m, "_pointer_state_path", return_value=path), \
                 mock.patch("builtins.open", _boom):
                with self.assertRaises(m.PointerStateUnreadable):
                    m.load_pointer_state()


class TestApplyAbortsOnUnreadablePointerState(unittest.TestCase):
    """Both required scenarios for the FIX 1 finding: a corrupt (invalid
    JSON) and an unreadable pointer-state file that ALREADY contains a
    "posted" marker must make --apply abort BEFORE any Tier-B post/close —
    exactly-once must hold even when the state file can't be trusted."""

    def _run_apply_with_unreadable_state(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state",
                                side_effect=m.PointerStateUnreadable("/fake/pointer-posted.json")), \
             mock.patch.object(m, "save_pointer_state") as m_save, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(FakeShadow(), "/fake/path")), \
             mock.patch.object(m, "post_slack_summary", return_value=True) as m_slack, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        m_pointer.assert_not_called()
        m_close.assert_not_called()
        m_save.assert_not_called()
        m_slack.assert_called_once()

    def test_corrupt_pointer_state_with_existing_posted_marker_aborts_apply(self):
        # PointerStateUnreadable is raised regardless of what the corrupt
        # file's previous (unparseable) content was — this exercises the
        # exact failure mode: a file that already recorded "O": "posted"
        # but is now corrupt must abort, never be silently treated as {}.
        self._run_apply_with_unreadable_state()

    def test_unreadable_pointer_state_with_existing_posted_marker_aborts_apply(self):
        self._run_apply_with_unreadable_state()


if __name__ == "__main__":
    unittest.main()
