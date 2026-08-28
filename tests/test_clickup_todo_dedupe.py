"""Behavioral tests for scripts/clickup-todo-dedupe.py.

This script MOVES customer support tickets out of the TO DO queue, so its
classification core is unit-tested exhaustively here with no network. Stdlib
unittest + stubs only, matching tests/test_close_duplicate_conversations.py.

The regression tests below are seeded with the REAL ticket pairs that the
hand-run "same conversation link -> duplicate" rule wrongly moved to Waiting
(7 of 7 historical moves were different-action-type tickets, i.e. distinct
customer requests). If any of those start being auto-moved again, these fail.
"""
import importlib.util
import pathlib
import tempfile
import unittest

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "clickup-todo-dedupe.py"
)
_spec = importlib.util.spec_from_file_location("clickup_todo_dedupe", _SCRIPT)
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)

FIELD = "c32dbf6e-f680-4ff1-a532-192bb96245c3"
EMAIL_FIELD = "e8618c74-d065-4b75-9a5a-86d658392409"
LINK = "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/{}"
# Tier A reproduces create_ticket's key, which includes the customer email, so
# fixtures carry one by default. All 43 linked TO DO tickets on the live board
# have this field populated (checked 2026-08-28); email=None exercises the
# fail-closed path explicitly.


def task(tid, conv_id, action, created=1000, handoff=False, name=None,
         link_in_desc=False, email="a@b.com"):
    tags = []
    if action is not None:
        tags.append({"name": f"action:{action}"})
    if handoff:
        tags.append({"name": "intercom-auto-handoff"})
    t = {
        "id": tid,
        "name": name or f"[{action}] ticket {tid}",
        "date_created": str(created),
        "tags": tags,
        "custom_fields": [],
        "description": "",
    }
    if email is not None:
        t["custom_fields"].append({"id": EMAIL_FIELD, "value": email})
    if conv_id is not None:
        if link_in_desc:
            t["description"] = f"**Conversation:** {LINK.format(conv_id)}"
        else:
            t["custom_fields"].append({"id": FIELD, "value": LINK.format(conv_id)})
    return t


def ids(moves):
    return sorted(mv["task"]["id"] for mv in moves)


class TierA(unittest.TestCase):
    """Same conversation AND same action type — create_ticket's own dedupe key."""

    def test_same_conv_same_action_moves_newer(self):
        a = task("keep", "C1", "credit-claim", created=100)
        b = task("dup", "C1", "credit-claim", created=200)
        moves, digest, _linked = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])
        self.assertEqual(moves[0]["tier"], "A")
        self.assertEqual(moves[0]["keep"]["id"], "keep")
        self.assertEqual(digest, [])

    def test_oldest_is_the_keeper_regardless_of_input_order(self):
        newest = task("new", "C1", "credit-claim", created=900)
        oldest = task("old", "C1", "credit-claim", created=100)
        middle = task("mid", "C1", "credit-claim", created=500)
        moves, _, _linked = m.classify([newest, middle, oldest])
        self.assertEqual(ids(moves), ["mid", "new"])
        self.assertTrue(all(mv["keep"]["id"] == "old" for mv in moves))

    def test_action_type_comes_from_tag_not_name_prefix(self):
        # Cosmetic [bracket] prefixes agree, but the authoritative action: tags
        # differ — these are NOT duplicates and must not be moved.
        a = task("t1", "C1", "credit-claim", created=100, name="[support] whatever")
        b = task("t2", "C1", "analytics-followup", created=200, name="[support] whatever")
        moves, digest, _linked = m.classify([a, b])
        self.assertEqual(moves, [])
        self.assertEqual(len(digest), 1)

    def test_untagged_tickets_are_never_tier_a(self):
        a = task("t1", "C1", None, created=100)
        b = task("t2", "C1", None, created=200)
        moves, digest, _linked = m.classify([a, b])
        self.assertEqual(moves, [])
        self.assertEqual(len(digest), 1)


class TierB(unittest.TestCase):
    """Bare auto-handoff escalations on a conversation that has real work."""

    def test_handoff_moved_when_a_real_ticket_exists(self):
        real = task("real", "C1", "credit-correction", created=100)
        esc = task("esc", "C1", "support-general", created=200, handoff=True)
        moves, digest, _linked = m.classify([real, esc])
        self.assertEqual(ids(moves), ["esc"])
        self.assertEqual(moves[0]["tier"], "B")
        self.assertEqual(moves[0]["keep"]["id"], "real")
        self.assertEqual(digest, [])

    def test_handoffs_alone_on_a_conversation_are_never_moved(self):
        # Nothing else carries the work — moving these would drop the request.
        a = task("h1", "C1", "support-general", created=100, handoff=True)
        b = task("h2", "C1", "support-general", created=200, handoff=True)
        moves, digest, _linked = m.classify([a, b])
        # h2 is still a Tier A duplicate of h1, but h1 must survive.
        self.assertEqual(ids(moves), ["h2"])
        self.assertEqual(moves[0]["tier"], "A")
        self.assertNotIn("h1", ids(moves))

    def test_every_handoff_moves_when_real_work_exists(self):
        real = task("real", "C1", "profile-merge", created=100)
        h1 = task("h1", "C1", "support-general", created=200, handoff=True)
        h2 = task("h2", "C1", "support-general", created=300, handoff=True)
        moves, digest, _linked = m.classify([real, h1, h2])
        self.assertEqual(ids(moves), ["h1", "h2"])
        self.assertEqual(digest, [])

    def test_non_handoff_support_general_is_not_tier_b(self):
        # A real support-general ask is work, not an auto-escalation.
        real = task("real", "C1", "credit-correction", created=100)
        sup = task("sup", "C1", "support-general", created=200, handoff=False)
        moves, digest, _linked = m.classify([real, sup])
        self.assertEqual(moves, [])
        self.assertEqual(len(digest), 1)


class DigestOnlyRegressions(unittest.TestCase):
    """The real pairs the naive rule wrongly buried. None may ever auto-move."""

    CASES = [
        # (conv, keeper id/action, wrongly-moved id/action, gap)
        ("215475613317927", "869envrwe", "support-general",
         "869epbwfc", "profile-merge"),
        ("215475618779683", "869ep6x0q", "analytics-followup",
         "869ep7bfk", "support-general"),
        ("C-credit", "869epapx7", "credit-correction",
         "869epaqb6", "support-general"),
        ("C-verify", "869epb6ud", "credit-verify",
         "869epb7qg", "analytics-followup"),
        ("C-update", "869epb8gw", "profile-update",
         "869epb8ve", "analytics-followup"),
        ("C-claim", "869epckta", "profile-claim",
         "869epckxp", "support-general"),
        ("C-corr", "869ep9998", "credit-correction",
         "869ep99tt", "analytics-followup"),
    ]

    def test_none_of_the_historical_false_positives_are_moved(self):
        for conv, keep_id, keep_a, dup_id, dup_a in self.CASES:
            with self.subTest(conv=conv):
                a = task(keep_id, conv, keep_a, created=100)
                b = task(dup_id, conv, dup_a, created=200)
                moves, digest, _linked = m.classify([a, b])
                self.assertEqual(
                    moves, [],
                    f"{dup_id} ({dup_a}) is a DISTINCT request from "
                    f"{keep_id} ({keep_a}) — it must never be auto-moved")
                self.assertEqual(len(digest), 1)
                self.assertEqual(digest[0]["conv"], conv)

    def test_close_in_time_does_not_make_them_duplicates(self):
        # 5 of the 7 real false positives were filed within 4 minutes.
        a = task("t1", "C1", "credit-correction", created=1_787_580_808_814)
        b = task("t2", "C1", "analytics-followup", created=1_787_580_808_814 + 72_000)
        moves, _, _linked = m.classify([a, b])
        self.assertEqual(moves, [])


class Scoping(unittest.TestCase):
    def test_tickets_without_a_conversation_link_are_ignored(self):
        # 1,383 of ~1,444 TO DO tickets are bulk-imported with no link.
        a = task("t1", None, "credit-claim", created=100)
        b = task("t2", None, "credit-claim", created=200)
        moves, digest, _linked = m.classify([a, b])
        self.assertEqual(moves, [])
        self.assertEqual(digest, [])

    def test_lone_ticket_on_a_conversation_is_untouched(self):
        moves, digest, _linked = m.classify([task("t1", "C1", "credit-claim")])
        self.assertEqual(moves, [])
        self.assertEqual(digest, [])

    def test_description_deeplink_is_honoured(self):
        a = task("keep", "C1", "credit-claim", created=100, link_in_desc=True)
        b = task("dup", "C1", "credit-claim", created=200)
        moves, _, _linked = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])

    def test_distinct_conversations_never_group(self):
        a = task("t1", "C1", "credit-claim", created=100)
        b = task("t2", "C2", "credit-claim", created=200)
        moves, digest, _linked = m.classify([a, b])
        self.assertEqual(moves, [])
        self.assertEqual(digest, [])

    def test_mixed_group_moves_only_the_redundant(self):
        real = task("real", "C1", "credit-correction", created=100)
        dup = task("dup", "C1", "credit-correction", created=200)
        other = task("other", "C1", "profile-merge", created=300)
        esc = task("esc", "C1", "support-general", created=400, handoff=True)
        moves, digest, _linked = m.classify([real, dup, other, esc])
        self.assertEqual(ids(moves), ["dup", "esc"])
        # real + other are distinct requests and stay in TO DO, reported only.
        self.assertEqual(len(digest), 1)
        self.assertEqual(sorted(t["id"] for t in digest[0]["tasks"]), ["other", "real"])


class Paging(unittest.TestCase):
    def test_duplicate_rows_across_pages_are_counted_once(self):
        pages = [
            {"tasks": [task("a", "C1", "credit-claim"), task("b", "C1", "credit-claim")],
             "last_page": False},
            # ClickUp has served the same task on two adjacent pages.
            {"tasks": [task("b", "C1", "credit-claim")], "last_page": True},
        ]
        calls = []

        class FakeResp:
            def __init__(self, payload):
                self.payload = payload

            def read(self):
                import json as _j
                return _j.dumps(self.payload).encode()

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def fake_urlopen(req, timeout=None):
            return FakeResp(pages[len(calls)])

        real_urlopen = m.urllib.request.urlopen
        real_load = m.json.load
        m.urllib.request.urlopen = lambda req, timeout=None: (
            calls.append(1), FakeResp(pages[len(calls) - 1]))[1]
        m.json.load = lambda fh: __import__("json").loads(fh.read().decode())
        try:
            out = m.fetch_status("tok", "list", "to do")
        finally:
            m.urllib.request.urlopen = real_urlopen
            m.json.load = real_load
        self.assertEqual([t["id"] for t in out], ["a", "b"])


class AuditComment(unittest.TestCase):
    def test_tier_a_comment_names_the_keeper_and_the_rule(self):
        mv = {"task": task("dup", "C1", "credit-claim", created=200),
              "keep": task("keep", "C1", "credit-claim", created=100),
              "tier": "A", "conv": "C1"}
        text = m.audit_comment(mv)
        self.assertIn("keep", text)
        self.assertIn("credit-claim", text)
        self.assertIn("Tier A", text)
        self.assertIn("No customer notification was sent", text)

    def test_tier_b_comment_explains_the_handoff_rule(self):
        mv = {"task": task("esc", "C1", "support-general", created=200, handoff=True),
              "keep": task("real", "C1", "credit-correction", created=100),
              "tier": "B", "conv": "C1"}
        text = m.audit_comment(mv)
        self.assertIn("auto-handoff", text)
        self.assertIn("real", text)
        self.assertIn("Tier B", text)


class CircuitBreaker(unittest.TestCase):
    def test_dry_run_makes_no_writes(self):
        mv = [{"task": task("dup", "C1", "credit-claim"),
               "keep": task("keep", "C1", "credit-claim"),
               "tier": "A", "conv": "C1"}]
        # No batch helper invocation, no exception, rc 0.
        self.assertEqual(m.apply_moves(mv, dry_run=True), 0)

    def test_no_moves_is_a_noop(self):
        self.assertEqual(m.apply_moves([], dry_run=False), 0)


class SharedResolverStaysInSync(unittest.TestCase):
    """scripts/lib/intercom_link.py is the canonical conversation-link resolver,
    but four existing scripts still carry their own byte-identical copy behind a
    "keep this in sync" comment. A comment is not enforcement — this test is.

    A conv id extracted one way but not another silently breaks cross-script
    matching (a notifier defer set keyed on a different id fails to defer), and
    that failure is invisible at runtime. If someone edits the canonical regex
    without updating the copies, this goes red instead of shipping the drift.
    """

    MIRRORS = [
        "scripts/close-resolved-conversations.py",
        "scripts/resolve-notify.py",
        "scripts/overdue-verification-notifier.py",
        "scripts/resolution-matcher.py",
    ]

    def _repo_root(self):
        return pathlib.Path(__file__).resolve().parent.parent

    def test_every_copy_of_the_conv_id_regex_is_byte_identical(self):
        import re as _re
        import sys as _sys
        root = self._repo_root()
        _sys.path.insert(0, str(root / "scripts"))
        from lib.intercom_link import CONV_ID_RE

        pattern = _re.compile(r'_CONV_ID_RE = re\.compile\(r"(.*)"\)')
        found = {}
        for rel in self.MIRRORS:
            src = (root / rel).read_text()
            m = pattern.search(src)
            self.assertIsNotNone(
                m, f"{rel} no longer defines _CONV_ID_RE — update MIRRORS or migrate it")
            found[rel] = m.group(1)

        # Guard against a vacuous pass: we must actually have inspected all four.
        self.assertEqual(len(found), len(self.MIRRORS))
        for rel, literal in found.items():
            self.assertEqual(
                literal, CONV_ID_RE.pattern,
                f"{rel} has drifted from scripts/lib/intercom_link.py. Conversation "
                f"ids must be byte-identical across every script or cross-script "
                f"ticket<->conversation matching silently breaks.")

    def test_every_copy_of_the_link_field_id_is_byte_identical(self):
        # The regex is only half the resolver. The "Intercom Link" custom-field
        # UUID is duplicated in all five files too, and a drift there breaks
        # cross-script matching exactly as silently — a guard that covers only
        # the easy half is the hole, not the fix.
        import re as _re
        root = self._repo_root()
        pattern = _re.compile(
            r'"CLICKUP_INTERCOM_LINK_FIELD_ID",\s*"([0-9a-fA-F-]+)"\)')
        canonical = pattern.search(
            (root / "scripts" / "lib" / "intercom_link.py").read_text())
        self.assertIsNotNone(canonical, "canonical module no longer defines the field id")
        found = {}
        for rel in self.MIRRORS:
            m = pattern.search((root / rel).read_text())
            self.assertIsNotNone(m, f"{rel} no longer defines INTERCOM_LINK_FIELD")
            found[rel] = m.group(1)
        self.assertEqual(len(found), len(self.MIRRORS))
        for rel, literal in found.items():
            self.assertEqual(
                literal, canonical.group(1),
                f"{rel}'s Intercom Link field id has drifted from "
                f"scripts/lib/intercom_link.py — ticket<->conversation matching "
                f"silently breaks for every ticket that uses the #417 field.")

    def test_each_mirror_points_readers_at_the_canonical_module(self):
        root = self._repo_root()
        for rel in self.MIRRORS:
            with self.subTest(script=rel):
                self.assertIn("scripts/lib/intercom_link.py", (root / rel).read_text(),
                              f"{rel} lost its pointer to the canonical resolver")


class LinkedCount(unittest.TestCase):
    def test_classify_reports_how_many_tickets_carry_a_link(self):
        tasks = [
            task("t1", "C1", "credit-claim", created=100),
            task("t2", "C1", "credit-claim", created=200),
            task("t3", "C2", "profile-merge", created=300),
            task("t4", None, "support-general", created=400),   # no link
        ]
        _moves, _digest, linked = m.classify(tasks)
        self.assertEqual(linked, 3)

    def test_linked_count_is_zero_when_nothing_carries_a_link(self):
        _moves, _digest, linked = m.classify([task("t1", None, "credit-claim")])
        self.assertEqual(linked, 0)


class HandoffIsNotADedupeKeeper(unittest.TestCase):
    """create-ticket.ts:196 excludes `intercom-auto-handoff` tickets from its own
    dedupe lookup ("appending a normal action request onto a human-takeover
    record would bury it"). So a real ticket that shares an action tag with an
    older auto-handoff was let through ON PURPOSE — treating it as an escaped
    dedupe buries exactly the customer work this sweeper exists to protect."""

    def test_real_ticket_is_not_a_tier_a_duplicate_of_an_older_handoff(self):
        h = task("h", "C1", "support-general", created=100, handoff=True)
        sup = task("sup", "C1", "support-general", created=200, handoff=False)
        moves, digest, _linked = m.classify([h, sup])
        # The handoff is the redundant one — the real ask carries the work.
        self.assertEqual(ids(moves), ["h"])
        self.assertEqual(moves[0]["tier"], "B")
        self.assertEqual(moves[0]["keep"]["id"], "sup")
        self.assertEqual(digest, [])

    def test_real_ticket_survives_alongside_an_unrelated_action_ticket(self):
        real = task("real", "C1", "profile-merge", created=100)
        h1 = task("h1", "C1", "support-general", created=200, handoff=True)
        sup = task("sup", "C1", "support-general", created=300, handoff=False)
        moves, digest, _linked = m.classify([real, h1, sup])
        self.assertEqual(ids(moves), ["h1"], "the real support-general ask must stay")
        self.assertEqual(len(digest), 1)


class KeeperMustSurvive(unittest.TestCase):
    def test_no_move_points_at_a_ticket_that_is_also_moved(self):
        # real + two handoffs sharing an action tag: h2 is a Tier A duplicate of
        # h1, and h1 is then a Tier B redundant handoff. Pointing h2's audit
        # comment at h1 sends a human to another ticket sitting in Waiting.
        real = task("real", "C1", "profile-merge", created=100)
        h1 = task("h1", "C1", "support-general", created=200, handoff=True)
        h2 = task("h2", "C1", "support-general", created=300, handoff=True)
        moves, _digest, _linked = m.classify([real, h1, h2])
        moved = {mv["task"]["id"] for mv in moves}
        self.assertEqual(moved, {"h1", "h2"})
        for mv in moves:
            self.assertNotIn(mv["keep"]["id"], moved,
                             f"{mv['task']['id']} was kept-by a ticket that is also moved")
        h2_move = next(mv for mv in moves if mv["task"]["id"] == "h2")
        # The reason must stay true as well as the pointer: h2 is a handoff, so
        # the Tier B wording is the accurate one once its keeper is `real`.
        self.assertEqual(h2_move["tier"], "B")
        self.assertIn("real", m.audit_comment(h2_move))


class SummaryRendering(unittest.TestCase):
    def test_read_back_failures_render_as_id_and_status(self):
        text = m.format_summary([], [], [], 10, 2, [("86abc", None)], False)
        self.assertIn("86abc (status=None)", text)
        self.assertNotIn("('86abc'", text, "raw Python tuple leaked into Slack")


class NotifyRepeatCooldown(unittest.TestCase):
    """The sweep never clears digest groups, and an aborted run makes no writes,
    so both conditions stand until a human acts. On an hourly timer an unchanged
    message would be 24 identical Slack posts a day."""

    def setUp(self):
        self.posted = []
        self._real_post = m.post_slack
        m.post_slack = lambda text, ch, cfg, acct: (self.posted.append((ch, text)) or True)
        self._tmp = tempfile.TemporaryDirectory()
        self.state = str(pathlib.Path(self._tmp.name) / "notify.json")

    def tearDown(self):
        m.post_slack = self._real_post
        self._tmp.cleanup()

    def _notify(self, text, now):
        return m.notify_once(text, "C1", "cfg", "operations", self.state,
                             cooldown=100, now=now)

    def test_identical_message_is_not_reposted_within_the_cooldown(self):
        self.assertTrue(self._notify("same standing digest", now=1000))
        self.assertFalse(self._notify("same standing digest", now=1050))
        self.assertEqual(len(self.posted), 1)

    def test_changed_message_posts_immediately(self):
        self._notify("digest with 1 group", now=1000)
        self.assertTrue(self._notify("digest with 2 groups", now=1001))
        self.assertEqual(len(self.posted), 2)

    def test_unchanged_message_reposts_once_the_cooldown_lapses(self):
        self._notify("still unresolved", now=1000)
        self.assertTrue(self._notify("still unresolved", now=1101))
        self.assertEqual(len(self.posted), 2)

    def test_a_failed_post_is_not_recorded_so_the_next_fire_retries(self):
        m.post_slack = lambda *a, **k: False
        self.assertFalse(self._notify("page me", now=1000))
        m.post_slack = lambda text, ch, cfg, acct: (self.posted.append((ch, text)) or True)
        self.assertTrue(self._notify("page me", now=1001))

    def test_an_unwritable_state_path_still_posts(self):
        # Fail-open: a missed page is worse than a repeated one, so a state file
        # we can neither read nor write must never suppress.
        for now in (1000, 1001):
            self.assertTrue(m.notify_once("x", "C1", "cfg", "op",
                                          "/proc/1/never/notify.json",
                                          cooldown=100, now=now))
        self.assertEqual(len(self.posted), 2)


class UnorderableGroups(unittest.TestCase):
    """Ordering decides which customer request survives. If we cannot establish
    it, we must not sweep the group — a missing date_created previously
    defaulted to 0, sorting that ticket first and making it the keeper, which
    moved the genuinely-oldest ticket to Waiting instead."""

    def test_missing_date_created_moves_nothing_and_reports(self):
        a = task("keep", "C1", "credit-claim", created=100)
        b = task("dup", "C1", "credit-claim", created=200)
        del b["date_created"]
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(moves, [], "an unorderable group must not be swept")
        self.assertEqual(len(digest), 1)
        self.assertTrue(digest[0].get("unorderable"))

    def test_unparseable_date_created_moves_nothing(self):
        a = task("keep", "C1", "credit-claim", created=100)
        b = task("dup", "C1", "credit-claim", created=200)
        b["date_created"] = "not-a-number"
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(moves, [])
        self.assertTrue(digest[0].get("unorderable"))

    def test_empty_string_date_created_moves_nothing(self):
        a = task("keep", "C1", "credit-claim", created=100)
        b = task("dup", "C1", "credit-claim", created=200)
        b["date_created"] = ""
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(moves, [])

    def test_a_handoff_with_no_date_is_not_swept_either(self):
        real = task("real", "C1", "credit-correction", created=100)
        esc = task("esc", "C1", "support-general", created=200, handoff=True)
        del esc["date_created"]
        moves, digest, _ = m.classify([real, esc])
        self.assertEqual(moves, [], "Tier B must not fire on an unorderable group")

    def test_created_returns_none_rather_than_zero(self):
        self.assertIsNone(m.created({}))
        self.assertIsNone(m.created({"date_created": None}))
        self.assertIsNone(m.created({"date_created": "abc"}))
        self.assertEqual(m.created({"date_created": "1787551399501"}), 1787551399501)


class TierAFreshnessWindow(unittest.TestCase):
    """create_ticket only dedupes against open tickets created inside a 7-day
    window (create-ticket.ts:125); beyond it, a same-type ask is deliberately
    filed as A NEW REQUEST. Tier A claims "this escaped create_ticket's dedupe",
    so it may only fire where that dedupe could have fired."""

    DAY = 24 * 60 * 60 * 1000

    def test_same_action_inside_the_window_is_a_duplicate(self):
        a = task("keep", "C1", "credit-claim", created=0)
        b = task("dup", "C1", "credit-claim", created=6 * self.DAY)
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])
        self.assertEqual(moves[0]["tier"], "A")

    def test_same_action_past_the_window_is_a_new_request_not_a_duplicate(self):
        a = task("older", "C1", "credit-claim", created=0)
        b = task("reopened", "C1", "credit-claim", created=8 * self.DAY)
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(
            moves, [],
            "create_ticket deliberately files this as a new request; moving it "
            "would bury a legitimate re-raise on a reopened conversation")
        self.assertEqual(len(digest), 1)

    def test_the_window_boundary_is_inclusive(self):
        a = task("keep", "C1", "credit-claim", created=0)
        b = task("dup", "C1", "credit-claim", created=7 * self.DAY)
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"], "exactly 7 days must still dedupe")

    def test_a_chain_dedupes_against_its_predecessor_not_the_first_ticket(self):
        # t3 is 9 days from t1 but 4 from t2 — create_ticket WOULD have found the
        # still-open t2, so t3 is a genuine escape and must move.
        t1 = task("t1", "C1", "credit-claim", created=0)
        t2 = task("t2", "C1", "credit-claim", created=5 * self.DAY)
        t3 = task("t3", "C1", "credit-claim", created=9 * self.DAY)
        moves, _digest, _ = m.classify([t1, t2, t3])
        self.assertEqual(ids(moves), ["t2", "t3"])

    def test_a_broken_chain_starts_a_new_canonical(self):
        t1 = task("t1", "C1", "credit-claim", created=0)
        t2 = task("t2", "C1", "credit-claim", created=10 * self.DAY)
        t3 = task("t3", "C1", "credit-claim", created=11 * self.DAY)
        moves, _digest, _ = m.classify([t1, t2, t3])
        self.assertEqual(ids(moves), ["t3"], "t2 opens a new chain; only t3 dupes it")
        self.assertEqual(moves[0]["keep"]["id"], "t2")

    def test_handoffs_obey_the_window_too(self):
        h1 = task("h1", "C1", "support-general", created=0, handoff=True)
        h2 = task("h2", "C1", "support-general", created=8 * self.DAY, handoff=True)
        moves, _digest, _ = m.classify([h1, h2])
        self.assertEqual(moves, [])


class NotifyCooldownClock(unittest.TestCase):
    """The cooldown is documented fail-open. A future-dated record must not mute
    the page: a clock step backwards or a corrupt `at` would otherwise suppress
    an abort alert until that future timestamp arrives."""

    def _state(self, tmpdir, at, sha_of="hello"):
        import hashlib, json as _j, os
        path = os.path.join(tmpdir, "notify.json")
        with open(path, "w") as f:
            _j.dump({"C1": {"sha": hashlib.sha256(sha_of.encode()).hexdigest(),
                            "at": at}}, f)
        return path

    def test_a_future_dated_record_still_posts(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            path = self._state(d, at=10_000_000)
            with mock.patch.object(m, "post_slack", return_value=True) as posted:
                sent = m.notify_once("hello", "C1", "cfg", "acct", path,
                                     cooldown=3600, now=1_000_000)
            self.assertTrue(sent, "a future timestamp must never suppress the page")
            posted.assert_called_once()

    def test_a_recent_identical_message_is_suppressed(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            path = self._state(d, at=999_000)
            with mock.patch.object(m, "post_slack", return_value=True) as posted:
                sent = m.notify_once("hello", "C1", "cfg", "acct", path,
                                     cooldown=3600, now=1_000_000)
            self.assertFalse(sent)
            posted.assert_not_called()

    def test_an_expired_record_posts_again(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            path = self._state(d, at=1_000)
            with mock.patch.object(m, "post_slack", return_value=True) as posted:
                sent = m.notify_once("hello", "C1", "cfg", "acct", path,
                                     cooldown=3600, now=1_000_000)
            self.assertTrue(sent)
            posted.assert_called_once()

    def test_a_different_message_is_never_suppressed(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            path = self._state(d, at=999_000, sha_of="hello")
            with mock.patch.object(m, "post_slack", return_value=True) as posted:
                sent = m.notify_once("DIFFERENT", "C1", "cfg", "acct", path,
                                     cooldown=3600, now=1_000_000)
            self.assertTrue(sent)
            posted.assert_called_once()


class TierBEvidenceStandard(unittest.TestCase):
    """Tier B claims "this conversation already has a real action ticket". An
    untagged ticket does not establish that — Tier A already refuses to act
    without the authoritative `action:` tag, and Tier B must hold the same bar
    or it moves a human-takeover record on the strength of an unknown."""

    def test_an_untagged_sibling_does_not_license_moving_a_handoff(self):
        untagged = task("untagged", "C1", None, created=100)
        esc = task("esc", "C1", "support-general", created=200, handoff=True)
        moves, digest, _ = m.classify([untagged, esc])
        self.assertEqual(moves, [],
                         "an untagged ticket is not proof real action work survives")
        self.assertEqual(len(digest), 1)

    def test_a_tagged_sibling_still_licenses_it(self):
        real = task("real", "C1", "credit-correction", created=100)
        esc = task("esc", "C1", "support-general", created=200, handoff=True)
        moves, _digest, _ = m.classify([real, esc])
        self.assertEqual(ids(moves), ["esc"])
        self.assertEqual(moves[0]["keep"]["id"], "real")

    def test_the_keeper_named_in_the_audit_comment_always_has_an_action_type(self):
        real = task("real", "C1", "profile-merge", created=100)
        untagged = task("untagged", "C1", None, created=150)
        esc = task("esc", "C1", "support-general", created=200, handoff=True)
        moves, _digest, _ = m.classify([real, untagged, esc])
        for mv in moves:
            self.assertIsNotNone(
                m.action_type(mv["keep"]),
                "audit comments must never render a keeper action type of None")


class UnhandledFailurePages(unittest.TestCase):
    """A crash before the normal notify path is otherwise silent: systemd marks
    the unit failed, the timer still reads active, and the sweep just stops."""

    def setUp(self):
        self._prev = m._PAGING_ENABLED
        m._PAGING_ENABLED = True

    def tearDown(self):
        m._PAGING_ENABLED = self._prev

    def test_the_pager_sends_a_stable_message_naming_the_exception_type(self):
        from unittest import mock
        with mock.patch.object(m, "notify_once", return_value=True) as notified:
            m._page_unhandled(ValueError("boom"))
        notified.assert_called_once()
        text = notified.call_args[0][0]
        self.assertIn("ValueError", text)
        self.assertIn("journalctl", text)
        # Stable across repeats so the cooldown collapses an hourly crash-loop
        # instead of paging 24x/day.
        self.assertNotIn("boom", text)

    def test_the_pager_never_raises_even_if_slack_is_broken(self):
        from unittest import mock
        with mock.patch.object(m, "notify_once", side_effect=RuntimeError("no slack")):
            m._page_unhandled(ValueError("boom"))  # must not propagate

    def test_it_pages_the_devops_alert_channel_not_the_digest_channel(self):
        from unittest import mock
        with mock.patch.object(m, "notify_once", return_value=True) as notified:
            m._page_unhandled(RuntimeError("x"))
        self.assertEqual(notified.call_args[0][1], m.DEFAULT_ALERT_CHANNEL)
        self.assertNotEqual(m.DEFAULT_ALERT_CHANNEL, m.DEFAULT_SUMMARY_CHANNEL)


class AlertChannelIsReachable(unittest.TestCase):
    """A page nobody receives is worse than no page: post_slack swallows
    channel_not_found as a WARN, so a wrong channel id makes the circuit breaker
    and the crash pager decorative while looking wired up.

    Verified against the live workspace 2026-08-28:
      C0ADV2W76G4 = #clio_devops  — operations bot IS a member
      C0BA8QMV3ME = #prod-alerts  — operations bot is NOT a member
      C0ANM0PN9L5 = #cs_chats     — operations bot IS a member
    """

    def test_alerts_go_to_clio_devops_not_prod_alerts(self):
        self.assertEqual(m.DEFAULT_ALERT_CHANNEL, "C0ADV2W76G4")
        self.assertNotEqual(
            m.DEFAULT_ALERT_CHANNEL, "C0BA8QMV3ME",
            "#prod-alerts is unreachable for the operations bot; a page there "
            "fails silently")

    def test_the_digest_channel_is_cs_chats(self):
        self.assertEqual(m.DEFAULT_SUMMARY_CHANNEL, "C0ANM0PN9L5")

    def test_alerts_and_digests_are_different_channels(self):
        self.assertNotEqual(m.DEFAULT_ALERT_CHANNEL, m.DEFAULT_SUMMARY_CHANNEL)


class PagingIsGatedOnRealRuns(unittest.TestCase):
    """A human testing by hand with --dry-run/--no-notify must not page."""

    def setUp(self):
        self._prev = m._PAGING_ENABLED

    def tearDown(self):
        m._PAGING_ENABLED = self._prev

    def test_a_suppressed_run_does_not_page(self):
        from unittest import mock
        m._PAGING_ENABLED = False
        with mock.patch.object(m, "notify_once") as notified:
            m._page_unhandled(ValueError("boom"))
        notified.assert_not_called()

    def test_a_real_run_still_pages(self):
        from unittest import mock
        m._PAGING_ENABLED = True
        with mock.patch.object(m, "notify_once", return_value=True) as notified:
            m._page_unhandled(ValueError("boom"))
        notified.assert_called_once()

    def _run_main(self, argv):
        """Drive main() end-to-end with the network stubbed, so the flag wiring
        itself is under test — setting _PAGING_ENABLED by hand would pass even
        if main() never computed it."""
        from unittest import mock
        with mock.patch.object(m.sys, "argv", ["clickup-todo-dedupe.py"] + argv), \
             mock.patch.object(m, "clickup_token", return_value="tok"), \
             mock.patch.object(m, "fetch_status", return_value=[]), \
             mock.patch.object(m, "post_slack", return_value=True):
            return m.main()

    def test_main_disables_paging_for_a_dry_run(self):
        m._PAGING_ENABLED = True
        self._run_main(["--dry-run"])
        self.assertFalse(m._PAGING_ENABLED,
                         "--dry-run must not page #clio_devops on a crash")

    def test_main_disables_paging_for_no_notify(self):
        m._PAGING_ENABLED = True
        self._run_main(["--no-notify"])
        self.assertFalse(m._PAGING_ENABLED)

    def test_main_enables_paging_for_a_real_run(self):
        m._PAGING_ENABLED = False
        self._run_main([])
        self.assertTrue(m._PAGING_ENABLED,
                        "a real scheduled run must page when it crashes")


class TierAMatchesTheProducerKey(unittest.TestCase):
    """create_ticket keys its dedupe on the customer email as well as the action
    type — sessionTickets.get(sessionId, actionType, customerEmail) and
    lookupOpenTicket's `User Email = customerEmail` filter. Tier A claims a
    ticket escaped that dedupe, so it has to group on the same key."""

    def test_two_customers_in_one_conversation_are_not_duplicates(self):
        a = task("cust-a", "C1", "credit-claim", created=100, email="a@x.com")
        b = task("cust-b", "C1", "credit-claim", created=200, email="b@x.com")
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(moves, [],
                         "different customers are distinct requests, not duplicates")
        self.assertEqual(len(digest), 1)

    def test_the_same_customer_still_dedupes(self):
        a = task("keep", "C1", "credit-claim", created=100, email="same@x.com")
        b = task("dup", "C1", "credit-claim", created=200, email="same@x.com")
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])

    def test_email_matching_is_case_and_whitespace_insensitive(self):
        a = task("keep", "C1", "credit-claim", created=100, email="Same@X.com")
        b = task("dup", "C1", "credit-claim", created=200, email="  same@x.com ")
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])

    def test_a_missing_email_fails_closed(self):
        a = task("t1", "C1", "credit-claim", created=100, email=None)
        b = task("t2", "C1", "credit-claim", created=200, email=None)
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(moves, [],
                         "without the email we cannot reproduce create_ticket's key")
        self.assertEqual(len(digest), 1)

    def test_the_real_live_duplicate_pair_still_dedupes(self):
        # 869eradyz / 869erae4c, found on the live board 2026-08-28: identical
        # titles, action:profile-merge, same conversation, 37s apart, and the
        # SAME customer email. The email key must not lose this.
        a = task("869eradyz", "215475689021596", "profile-merge", created=0,
                 email="samantha@soundsofcrenshaw.com")
        b = task("869erae4c", "215475689021596", "profile-merge", created=37_000,
                 email="samantha@soundsofcrenshaw.com")
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["869erae4c"])
        self.assertEqual(moves[0]["keep"]["id"], "869eradyz")

    def test_tier_b_does_not_require_a_matching_email(self):
        # Tier B is not create_ticket's key: handoffs are excluded from that
        # dedupe entirely, and they routinely carry unknown@unknown.
        real = task("real", "C1", "credit-correction", created=100, email="a@x.com")
        esc = task("esc", "C1", "support-general", created=200, handoff=True,
                   email=None)
        moves, _digest, _ = m.classify([real, esc])
        self.assertEqual(ids(moves), ["esc"])
        self.assertEqual(moves[0]["tier"], "B")


class FailClosedExitsPage(unittest.TestCase):
    """The fail-closed aborts raise SystemExit. Re-raising blind meant the sweep
    could fail every hour with the timer still reading active and nobody told."""

    def _exit_code_pages(self, code):
        """Exercise the SHIPPED decision, not a copy of it: re-implementing the
        condition here would pass even if the handler stopped calling it."""
        from unittest import mock
        if not m.should_page_exit(SystemExit(code).code):
            return 0
        with mock.patch.object(m, "notify_once", return_value=True) as notified:
            m._PAGING_ENABLED = True
            m._page_unhandled(SystemExit(code), reason="aborted: x")
            return notified.call_count

    def test_the_handler_delegates_to_should_page_exit(self):
        import inspect
        src = inspect.getsource(m)
        self.assertIn("if should_page_exit(exc.code):", src,
                      "the __main__ handler must use the tested predicate")

    def test_a_message_exit_pages(self):
        self.assertEqual(
            self._exit_code_pages("CLICKUP_API_KEY or MUSOAI_CLICKUP_API_KEY is required"), 1)

    def test_a_partial_scan_abort_pages(self):
        self.assertEqual(self._exit_code_pages("paged 40 times without reaching last_page"), 1)

    def test_clean_and_already_reported_exits_do_not_double_page(self):
        for code in (None, 0, 1, 2):
            with self.subTest(code=code):
                self.assertEqual(self._exit_code_pages(code), 0)

    def test_the_page_names_the_abort_reason(self):
        from unittest import mock
        m._PAGING_ENABLED = True
        with mock.patch.object(m, "notify_once", return_value=True) as notified:
            m._page_unhandled(SystemExit("no api key"), reason="aborted: no api key")
        self.assertIn("no api key", notified.call_args[0][0])


class MergeActionsUseTheProducersShorterWindow(unittest.TestCase):
    """create-ticket.ts:365 skips lookupOpenTicket for profile-merge AND
    track-merge, so their only dedupe is SessionTicketRegistry (TTL_MS = 24h,
    session-ticket-registry.ts:1). A second merge request in the same
    conversation more than 24h later is created ON PURPOSE — and burying a
    distinct merge request is exactly the harm create-ticket.ts guards against
    ("could be closed unexecuted")."""

    HOUR = 60 * 60 * 1000
    DAY = 24 * 60 * 60 * 1000

    def test_a_second_profile_merge_after_24h_is_not_a_duplicate(self):
        a = task("first", "C1", "profile-merge", created=0)
        b = task("second", "C1", "profile-merge", created=2 * self.DAY)
        moves, digest, _ = m.classify([a, b])
        self.assertEqual(moves, [],
                         "a distinct merge request must not be buried")
        self.assertEqual(len(digest), 1)

    def test_a_second_track_merge_after_24h_is_not_a_duplicate(self):
        a = task("first", "C1", "track-merge", created=0)
        b = task("second", "C1", "track-merge", created=2 * self.DAY)
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(moves, [])

    def test_merges_inside_24h_still_dedupe(self):
        for action in ("profile-merge", "track-merge"):
            with self.subTest(action=action):
                a = task("keep", "C1", action, created=0)
                b = task("dup", "C1", action, created=12 * self.HOUR)
                moves, _digest, _ = m.classify([a, b])
                self.assertEqual(ids(moves), ["dup"])

    def test_the_24h_boundary_is_inclusive(self):
        a = task("keep", "C1", "profile-merge", created=0)
        b = task("dup", "C1", "profile-merge", created=self.DAY)
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])

    def test_non_merge_actions_keep_the_seven_day_window(self):
        # 2 days would be outside the merge window but is well inside the
        # ClickUp fallback the producer DOES run for these.
        a = task("keep", "C1", "credit-claim", created=0)
        b = task("dup", "C1", "credit-claim", created=2 * self.DAY)
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["dup"])

    def test_the_window_helper_matches_the_producer_per_action(self):
        self.assertEqual(m.tier_a_window_ms("profile-merge"), 24 * 60 * 60 * 1000)
        self.assertEqual(m.tier_a_window_ms("track-merge"), 24 * 60 * 60 * 1000)
        self.assertEqual(m.tier_a_window_ms("credit-claim"), 7 * 24 * 60 * 60 * 1000)
        self.assertEqual(m.tier_a_window_ms("support-general"), 7 * 24 * 60 * 60 * 1000)

    def test_the_real_live_profile_merge_duplicate_still_dedupes(self):
        # 869eradyz / 869erae4c were 37 SECONDS apart, far inside 24h.
        a = task("869eradyz", "215475689021596", "profile-merge", created=0,
                 email="samantha@soundsofcrenshaw.com")
        b = task("869erae4c", "215475689021596", "profile-merge", created=37_000,
                 email="samantha@soundsofcrenshaw.com")
        moves, _digest, _ = m.classify([a, b])
        self.assertEqual(ids(moves), ["869erae4c"])


if __name__ == "__main__":
    unittest.main()
