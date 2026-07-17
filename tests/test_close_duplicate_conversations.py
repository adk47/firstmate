"""Behavioral tests for scripts/close-duplicate-conversations.py.

This is a ONE-WAY-DOOR script (it closes customer conversations). The
pure grouping/tiering/keep-selection core is unit-tested exhaustively here
with no network. Stdlib unittest + stubs only, matching
tests/test_cs_needs_human_digest.py's convention.
"""
import importlib.util
import pathlib
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
        g1 = {"email": "a@x.com", "kept": conv("K1"), "closable": [
            {"older": conv("O1"), "kept": conv("K1"), "tier": "A", "email": "a@x.com"}]}
        g2 = {"email": "b@x.com", "kept": conv("K2"), "closable": [
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
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertNotEqual(rc, 0)
        self.assertEqual(close_calls, [])


class TestNotifyCandidates(unittest.TestCase):
    def test_notify_candidates_posts_even_on_dry_run(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=200, lcr=100, created_at=1000)
        kept = conv("K", email="x@y.com", lar=300, lcr=100, created_at=5000)
        posted = []
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "post_slack_summary",
                                side_effect=lambda text, *a, **k: posted.append(text) or True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
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
             mock.patch.object(m, "post_slack_summary") as m_post, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
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
             mock.patch.object(m, "close_conversation") as m_close, \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
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
             mock.patch.object(m, "open_shadow_log", return_value=(None, None)), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_close.assert_called_once_with("t", "5763097", "O")


class TestPointerPostedDedupe(unittest.TestCase):
    """Partial-failure dedupe: a pointer_posted record must be written
    BEFORE the close attempt; a later run must never re-post the pointer,
    even if the earlier close failed."""

    def test_pointer_not_reposted_when_already_recorded_but_close_retried(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={"O": True}), \
             mock.patch.object(m, "save_pointer_state") as m_save, \
             mock.patch.object(m, "post_pointer_comment") as m_pointer, \
             mock.patch.object(m, "close_conversation",
                                return_value={"state": "closed"}) as m_close, \
             mock.patch.object(m, "open_shadow_log", return_value=(None, None)), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_pointer.assert_not_called()
        m_save.assert_not_called()
        m_close.assert_called_once()

    def test_pointer_posted_before_close_is_attempted_for_a_fresh_tier_b_target(self):
        import sys as _sys
        older = conv("O", email="x@y.com", lar=0, lcr=0, created_at=1000)
        kept = conv("K", email="x@y.com", lar=50, lcr=10, created_at=1000 + 86400)
        order = []
        with mock.patch.object(m, "fetch_open_convs", return_value=[older, kept]), \
             mock.patch.object(m, "owned_ids", return_value=set()), \
             mock.patch.object(m, "reverify_still_valid", return_value=True), \
             mock.patch.object(m, "load_pointer_state", return_value={}), \
             mock.patch.object(m, "save_pointer_state",
                                side_effect=lambda *a: order.append("save")), \
             mock.patch.object(m, "post_pointer_comment",
                                side_effect=lambda *a, **k: order.append("pointer")), \
             mock.patch.object(m, "close_conversation",
                                side_effect=lambda *a, **k: order.append("close") or {"state": "closed"}), \
             mock.patch.object(m, "open_shadow_log", return_value=(None, None)), \
             mock.patch.object(m, "post_slack_summary", return_value=True), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(order, ["pointer", "save", "close"])


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
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t"}), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        self.assertEqual(len(writes), 1)
        import json as _json
        rec = _json.loads(writes[0])
        self.assertEqual(rec["id"], "O")
        self.assertEqual(rec["kept_id"], "K")
        self.assertNotIn("conv_id", rec)


if __name__ == "__main__":
    unittest.main()
