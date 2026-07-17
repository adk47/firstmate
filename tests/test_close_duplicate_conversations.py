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
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
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
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                              "INTERCOM_ADMIN_ID": "5763097"}, clear=False), \
             mock.patch.object(_sys, "argv", ["m", "--apply"]):
            rc = m.main()
        self.assertEqual(rc, 0)
        m_close.assert_called_once_with("t", "5763097", "O")

    def test_admin_id_read_from_env_not_hardcoded(self):
        """Fix 4: hermeticity check — override INTERCOM_ADMIN_ID to a value
        that could never be the module's hardcoded default, and confirm
        main() actually uses it (proves the suite isn't accidentally
        passing only because the host runner happens to have the default
        set — see test_close_duplicate_conversations.py:273 QA finding)."""
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
        m_close.assert_called_once_with("t", "99999", "O")


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
        import os as _os
        import tempfile as _tempfile
        with _tempfile.TemporaryDirectory() as d:
            path = f"{d}/pointer-posted.json"
            with open(path, "w") as f:
                f.write('{"O": "posted"}')
            _os.chmod(path, 0o000)
            try:
                with mock.patch.object(m, "_pointer_state_path", return_value=path):
                    with self.assertRaises(m.PointerStateUnreadable):
                        m.load_pointer_state()
            finally:
                _os.chmod(path, 0o644)  # allow TemporaryDirectory cleanup


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
