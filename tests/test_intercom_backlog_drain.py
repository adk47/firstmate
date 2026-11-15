"""Behaviour tests for scripts/intercom-backlog/drain.py (lane caroline-unanswered-drain-u1).

No network, no replica, no Intercom: the thread reads, the replica reads, the copy gate and the reply
wrapper are fakes handed in as `deps`; the shared message ledger is the real one, in memory.
Stdlib unittest only.
"""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest import mock
from types import SimpleNamespace

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRAIN = os.path.join(ROOT, "scripts", "intercom-backlog", "drain.py")

spec = importlib.util.spec_from_file_location("ib_drain", DRAIN)
drain = importlib.util.module_from_spec(spec)
sys.modules["ib_drain"] = drain
spec.loader.exec_module(drain)

NOW = 1_800_000_000
DAY = 86400
BOT = drain.INTERCOM_ADMIN_ID
OPERATOR = drain.monitor_rules.OPERATOR_BOT_ID


def part(kind, author_type, author_id, ts, body="<p>words</p>"):
    return {"part_type": kind, "author": {"type": author_type, "id": author_id}, "created_at": ts, "body": body}


def conv(cid="1", *, parts=(), source_author="user", created=NOW - 200 * DAY, state="open", admin=BOT,
         team=None, contacts=1, total=None, body="<p>where is my credit request</p>"):
    return {
        "id": cid, "state": state, "created_at": created, "admin_assignee_id": admin, "team_assignee_id": team,
        "source": {"author": {"type": source_author, "id": "c1"}, "body": body},
        "contacts": {"contacts": [{"id": f"k{i}"} for i in range(contacts)]},
        "conversation_parts": {"conversation_parts": list(parts), "total_count": len(parts) if total is None else total},
    }


def census(cid="1", *, action="draft-credit", topic="credit", uid="77", credits=None, claims=None, contact="k0"):
    return {"id": cid, "action": action, "topic": topic, "user_id": uid, "credits": credits or {},
            "claims": claims or {}, "contact_id": contact, "email": "person@example.test", "paid": False,
            "waiting_since": NOW - 200 * DAY}


def facts(**kw):
    return {"shape": "", "erasure": False, "promises": [], "docs_on_file": 0, "need": "", "restricted": False, **kw}


def classify(row, c, who=None, **kw):
    thread = drain.read_thread(c, *who) if who else drain.read_thread(c)
    return drain.classify(row, thread, facts(**kw), NOW)


class ReadThreadTests(unittest.TestCase):
    def test_a_reply_posted_as_the_workspace_bot_is_our_reply(self):
        # 865 answered threads read as customer-last on 2026-11-13 because the statistics flag skips this author
        t = drain.read_thread(conv(parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)]))
        self.assertEqual((t["last_word"], t["last_reply_at"]), ("caroline_as_operator", NOW - 199 * DAY))

    def test_an_attachment_only_customer_comment_is_the_customer_speaking(self):
        for body in ("", "<p></p>", '<img src="https://example.test/shot.png">'):
            with self.subTest(body=body):
                t = drain.read_thread(conv(parts=[part("comment", "user", "c1", NOW - 10, body=body)]))
                self.assertEqual((t["last_word"], t["last_customer_at"]), ("customer", NOW - 10))

    def test_a_bodyless_admin_part_after_the_customer_is_not_our_reply(self):
        t = drain.read_thread(conv(parts=[part("comment", "user", "c1", NOW - 10),
                                          part("comment", "admin", BOT, NOW - 5, body="<p></p>")]))
        self.assertEqual((t["last_word"], t["last_reply_at"]), ("customer", 0))

    def test_a_note_a_close_and_a_wordless_comment_are_not_a_reply(self):
        t = drain.read_thread(conv(parts=[
            part("note", "admin", BOT, NOW - 10), part("close", "admin", "999", NOW - 9, body=""),
            part("comment", "admin", "999", NOW - 8, body="<p> </p>")]))
        self.assertEqual((t["last_word"], t["last_reply_at"]), ("customer", 0))

    def test_a_thread_with_parts_missing_is_not_read(self):
        t = drain.read_thread(conv(parts=[part("comment", "user", "c1", NOW - 5)], total=600))
        self.assertEqual(t, {"read": "truncated"})

    def test_an_error_answer_is_unreadable(self):
        self.assertEqual(drain.read_thread({"_error": 404}), {"read": "unreadable"})

    def test_who_holds_the_thread(self):
        self.assertEqual(drain.read_thread(conv(admin="999"))["holder"], "person")
        self.assertEqual(drain.read_thread(conv(admin=None, team=int(drain.ESCALATION_TEAM)))["holder"], "escalation_team")
        self.assertEqual(drain.read_thread(conv(admin=None, team=2238258))["holder"], "nobody")
        self.assertEqual(drain.read_thread(conv())["holder"], "caroline")
        self.assertEqual(drain.read_thread(conv(admin=int(OPERATOR)))["holder"], "bot")
        self.assertEqual(drain.read_thread(conv(admin=None, team=2238258), ("5763097",), ("2238258",))["holder"],
                         "staffed_team")


class RestrictedTests(unittest.TestCase):
    """The restricted-contact hold must refuse rather than read an empty set as "nobody is restricted"."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def plugin_file(self, text):
        path = os.path.join(self.tmp.name, "restricted-accounts.ts")
        with open(path, "w", encoding="utf8") as f:
            f.write(text)
        return path

    def test_no_contact_ids_is_unmeasured(self):
        path = self.plugin_file('export const RESTRICTED_CATEGORY = "restricted_account";\n'
                                'export const PROOF_REVIEW_CATEGORY = "proof_review_account";\n')
        with self.assertRaises(drain.Unmeasured):
            drain.read_restricted(path)

    def test_a_file_missing_one_set_is_unmeasured(self):
        path = self.plugin_file('export const RESTRICTED_CATEGORY = "restricted_account";\n'
                                'const IDS = new Set(["63bf0173c00101f1a4a458ec"]);\n')
        with self.assertRaises(drain.Unmeasured):
            drain.read_restricted(path)

    def test_the_real_plugin_file_measures_its_restricted_contacts(self):
        ids = drain.read_restricted()
        self.assertTrue(ids)
        self.assertTrue(all(len(contact) == 24 for contact in ids))


class WhoTests(unittest.TestCase):
    """Who is a person comes from the monitor's ONE register, never a second list in this file."""

    def test_the_holder_lists_come_from_the_policy_register(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "caroline-shapes.json")
            with open(path, "w", encoding="utf8") as f:
                json.dump({"monitor": {"non_human_admin_ids": ["5763097", "111222333"],
                                       "staffed_team_ids": ["999888"]}}, f)
            non_human, staffed = drain.read_who(path)
        self.assertIn("111222333", non_human)
        self.assertEqual(staffed, ("999888",))
        self.assertEqual(drain.read_thread(conv(admin="111222333"), non_human, staffed)["holder"], "bot")
        self.assertEqual(drain.read_thread(conv(admin=None, team=999888), non_human, staffed)["holder"],
                         "staffed_team")
        self.assertEqual(drain.read_thread(conv(admin="111222334"), non_human, staffed)["holder"], "person")

    def test_an_id_added_to_the_policy_list_is_ours_as_holder_and_as_author(self):
        non_human = (BOT, "111222333")
        thread = drain.read_thread(conv(admin="111222333", parts=[part("comment", "admin", "111222333", NOW - 60)]),
                                   non_human, ())
        self.assertEqual((thread["holder"], thread["last_word"]), ("bot", "caroline_as_operator"))
        self.assertEqual(drain.who_of({"type": "admin", "id": "111222333"}, non_human), "caroline_as_operator")
        self.assertEqual(drain.who_of({"type": "admin", "id": "999"}, non_human), "person")
        self.assertEqual(drain.who_of({"type": "admin", "id": BOT}, non_human), "caroline")

    def test_the_real_register_names_the_bots(self):
        non_human, _staffed = drain.read_who()
        self.assertIn(drain.INTERCOM_ADMIN_ID, non_human)
        self.assertIn(OPERATOR, non_human)


class ClassifyTests(unittest.TestCase):
    def test_every_request_decided_and_the_thread_asks_about_a_request_is_sent_an_account_line(self):
        got = classify(census(credits={"approved": 3}), conv())
        self.assertEqual(got[:4], ("send", "credit_all_decided", "credits-approved", "answer"))

    def test_no_account_is_told_to_write_from_the_account_email(self):
        got = classify(census(uid="", action="no-identity"), conv())
        self.assertEqual(got[:3], ("send", "no_account", "no-account"))

    def test_an_open_request_or_claim_is_never_sent_here_and_names_its_owner(self):
        cases = [
            (dict(credits={"pending": 2}), dict(docs_on_file=3, need="distributor_dashboard_with_code"), "proof-need-ask"),
            (dict(credits={"pending": 2}), dict(docs_on_file=3), "status-doc-received"),
            (dict(credits={"pending": 2, "uvn": 2}), {}, "uvn-status"),
            (dict(credits={"pending": 1}), {}, "status-team-review"),
            (dict(claims={"pending": 1}), {}, "claim-status"),
        ]
        for row_kw, fact_kw, campaign in cases:
            with self.subTest(campaign=campaign):
                lst, klass, line, _mode, basis = classify(census(**row_kw), conv(), **fact_kw)
                self.assertEqual((lst, line), ("owner", ""))
                self.assertEqual(drain.OWNER_CAMPAIGN[klass], campaign)
                self.assertIn(campaign, basis)

    def test_a_thread_about_something_else_never_gets_an_account_line(self):
        # 2026-11-13, thread 215476530103259: a removal request on an account whose one request was approved
        recent = conv(created=NOW - 21 * DAY)
        got = classify(census(credits={"approved": 1}, topic="removal"), recent, shape="merge_split")
        self.assertEqual(got[:3], ("caroline", "specific_ask", ""))
        old = classify(census(credits={"approved": 1}, topic="removal"), conv(), shape="merge_split")
        self.assertEqual(old[:3], ("send", "specific_ask", "late-reply"))
        # the monitor's shape outranks the census topic: "credit" + credit_wrong is not a status question
        self.assertEqual(classify(census(credits={"approved": 1}), conv(), shape="credit_wrong")[2], "late-reply")
        self.assertEqual(classify(census(credits={"approved": 1}, topic="other"), conv(), shape="proof_sent")[2],
                         "credits-approved")

    def test_billing_legal_erasure_and_hand_read_threads_are_separate(self):
        self.assertEqual(classify(census(action="captain-billing", topic="billing"), conv())[:2], ("separate", "billing"))
        self.assertEqual(classify(census(action="captain-legal", topic="legal"), conv())[:2], ("separate", "legal"))
        self.assertEqual(classify(census(), conv(), erasure=True)[:2], ("separate", "erasure"))
        self.assertEqual(classify(census(action=drain.overrides.HOLD_READ), conv())[:2], ("separate", "hand_read"))

    def test_an_erasure_legal_or_refund_shape_is_separate_whatever_the_topic_says(self):
        """2026-11-15: 11 threads the monitor shaped this way had the census topic "other" and were planned
        for the late-reply line. The shape decides."""
        for shape, klass in (("gdpr_erasure", "erasure"), ("legal_notice", "legal"), ("refund_dispute", "billing")):
            for row in (census(action="draft-other", topic="other"), census(credits={"approved": 2}),
                        census(uid="", action="no-identity"), census(credits={"unverified": 1})):
                with self.subTest(shape=shape, action=row["action"], credits=row["credits"]):
                    self.assertNotEqual(classify(row, conv(), shape="product_question")[0], "separate")
                    got = classify(row, conv(), shape=shape)
                    self.assertEqual(got[:3], ("separate", klass, ""))
                    self.assertIn("monitor shape " + shape, got[4])

    def test_a_separate_shape_is_never_closed_and_never_handed_back(self):
        stale = conv(parts=[part("comment", "admin", BOT, NOW - 199 * DAY)])
        recent = conv(created=NOW - 3 * DAY)
        for shape in drain.SEPARATE_SHAPES:
            with self.subTest(shape=shape):
                self.assertEqual(classify(census(), stale)[0], "close")
                self.assertEqual(classify(census(), stale, shape=shape)[:2], ("not_owed", "answered"))
                self.assertEqual(classify(census(), stale, shape=shape, promises=["unbacked"])[0], "separate")
                self.assertEqual(classify(census(topic="other"), recent, shape="product_question")[0], "caroline")
                got = classify(census(topic="other"), recent, shape=shape)
                self.assertEqual(got[0], "separate")
                row = {"list": got[0], "class": got[1], "mode": got[3], "last_customer_at": NOW - 3 * DAY}
                self.assertEqual(drain.handback_of(row, NOW), "")

    def test_only_the_three_shapes_no_line_answers_are_separate(self):
        for shape in drain.SEPARATE_SHAPES:
            self.assertIn(shape, drain.monitor_rules.SHAPE_IDS)

    def test_an_erasure_request_outranks_automated_mail(self):
        self.assertEqual(classify(census(), conv(), erasure=True, shape="robot_mail")[0], "separate")
        self.assertEqual(classify(census(), conv(), shape="robot_mail")[:2], ("not_owed", "robot_mail"))
        self.assertEqual(classify(census(), conv(), shape="thanks_empty")[0], "not_owed")

    def test_an_attachment_only_last_message_is_owed_not_answered(self):
        shot = conv(parts=[part("comment", "admin", BOT, NOW - 20 * DAY),
                           part("comment", "user", "c1", NOW - 5 * DAY, body="")])
        self.assertEqual(classify(census(credits={"approved": 1}), shot)[:2], ("send", "credit_all_decided"))

    def test_a_thread_a_bot_holds_is_caroline_side_and_not_held(self):
        bot = conv(admin=int(OPERATOR))
        self.assertEqual(classify(census(credits={"approved": 1}), bot)[:4],
                         classify(census(credits={"approved": 1}), conv())[:4])

    def test_a_staffed_team_holds_the_thread(self):
        self.assertEqual(classify(census(credits={"approved": 1}), conv(admin=None, team=555),
                                  who=(("5763097",), ("555",)))[:2], ("held", "staffed_team"))

    def test_a_thread_a_person_or_the_escalation_queue_holds_gets_nothing(self):
        self.assertEqual(classify(census(credits={"approved": 1}), conv(admin="999"))[:2], ("held", "person"))
        self.assertEqual(classify(census(credits={"approved": 1}),
                                  conv(admin=None, team=int(drain.ESCALATION_TEAM)))[:2], ("held", "escalation_team"))
        self.assertEqual(classify(census(credits={"approved": 1}), conv(), restricted=True)[:2], ("held", "restricted"))

    def test_we_wrote_last_recently_is_not_owed(self):
        c = conv(created=NOW - 10 * DAY, parts=[part("comment", "admin", BOT, NOW - 9 * DAY)])
        self.assertEqual(classify(census(), c)[:2], ("not_owed", "answered"))

    def test_we_wrote_last_and_the_customer_is_silent_over_90_days_is_a_close(self):
        c = conv(parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        self.assertEqual(classify(census(), c)[:4], ("close", "stale", "stale-close", "close"))

    def test_an_open_promise_is_answered_not_closed(self):
        c = conv(parts=[part("comment", "admin", BOT, NOW - 199 * DAY)])
        got = classify(census(credits={"approved": 2}), c, promises=["credit_verification"])
        self.assertEqual(got[:4], ("send", "credit_all_decided", "credits-approved", "promise"))

    def test_a_customer_last_thread_with_an_open_promise_gets_no_unrelated_line(self):
        # QA review of #1978: a hidden-profile promise with no request on file used to be told "no-request"
        cases = (
            (census(), ["unbacked"], "no-request"),
            (census(uid="", action="no-identity"), ["merge"], "no-account"),
            (census(credits={"approved": 2}), ["merge"], "credits-approved"),
            (census(credits={"approved": 2}), ["credit_verification", "erasure"], "credits-approved"),
            (census(topic="merge"), ["unbacked"], "late-reply"),
        )
        for row, kinds, line in cases:
            with self.subTest(line=line, kinds=kinds):
                self.assertEqual(classify(row, conv())[2], line)          # the line it gets with no promise
                got = classify(row, conv(), promises=kinds)
                self.assertEqual(got[:4], ("caroline", "open_promise", "", "answer"))
                self.assertIn(line, got[4])

    def test_a_decided_line_is_the_update_a_verification_or_status_promise_asked_for(self):
        for kinds in (["credit_verification"], ["request_status"], ["credit_verification", "request_status"]):
            with self.subTest(kinds=kinds):
                got = classify(census(credits={"approved": 1, "rejected": 1}), conv(), promises=kinds)
                self.assertEqual(got[:4], ("send", "credit_all_decided", "credits-decided", "answer"))

    def test_only_the_three_decided_lines_keep_a_promise(self):
        self.assertEqual(sorted(drain.PROMISE_MET_BY), ["credits-approved", "credits-decided", "credits-declined"])
        for line in drain.LINES:
            with self.subTest(line=line):
                self.assertEqual(drain.promise_unmet(line, []), [])
                self.assertEqual(drain.promise_unmet(line, ["merge"]), ["merge"])
                kept = line in drain.PROMISE_MET_BY
                self.assertEqual(drain.promise_unmet(line, ["credit_verification"]),
                                 [] if kept else ["credit_verification"])

    def test_we_wrote_last_with_a_promise_the_line_does_not_keep_gets_no_line(self):
        c = conv(parts=[part("comment", "admin", BOT, NOW - 199 * DAY)])
        got = classify(census(credits={"approved": 2}), c, promises=["merge"])
        self.assertEqual(got[:4], ("caroline", "open_promise", "", "promise"))

    def test_a_stale_thread_that_is_billing_held_or_restricted_is_left_open(self):
        c = conv(parts=[part("comment", "admin", BOT, NOW - 199 * DAY)])
        self.assertEqual(classify(census(action="captain-billing"), c)[0], "not_owed")
        self.assertEqual(classify(census(), c, restricted=True)[0], "not_owed")
        held = conv(admin="999", parts=[part("comment", "admin", BOT, NOW - 199 * DAY)])
        self.assertEqual(classify(census(), held)[0], "not_owed")

    def test_a_thread_the_customer_spoke_last_is_never_a_close(self):
        self.assertEqual(classify(census(), conv(created=NOW - 400 * DAY))[0], "send")

    def test_an_unread_or_closed_thread_is_never_a_candidate(self):
        self.assertEqual(drain.classify(census(), {"read": "truncated"}, facts(), NOW)[0], "unread")
        self.assertEqual(classify(census(), conv(state="closed"))[:2], ("not_owed", "not_open"))


class AccountLineTests(unittest.TestCase):
    def test_the_line_follows_the_states_read_now(self):
        self.assertEqual(drain.account_line({"approved": 4}, 0), ("credits-approved", ""))
        self.assertEqual(drain.account_line({"approved": 4, "rejected": 1}, 0), ("credits-decided", ""))
        self.assertEqual(drain.account_line({"rejected": 3}, 0), ("credits-declined", ""))
        self.assertEqual(drain.account_line({}, 0), ("no-request", ""))

    def test_anything_open_or_unknown_gets_no_line(self):
        for statuses, claims in (({"approved": 4, "unverified": 1}, 0), ({"processing": 1}, 0),
                                 ({"user_verification_needed": 1}, 0), ({"approved": 1}, 1),
                                 ({"approved": 1, "some_new_state": 1}, 0)):
            with self.subTest(statuses=statuses, claims=claims):
                line, why = drain.account_line(statuses, claims)
                self.assertEqual(line, "")
                self.assertTrue(why)


class LinesTests(unittest.TestCase):
    """What a body may contain at all."""

    def test_no_line_has_a_slot_a_name_a_number_or_a_date(self):
        for key, body in drain.LINES.items():
            with self.subTest(line=key):
                self.assertNotRegex(body, r"[{}]")
                self.assertNotRegex(body, r"\d")

    def test_no_line_promises_a_person_an_update_or_a_time(self):
        banned = (r"teammate", r"\bteam\b", r"we('| wi)ll", r"be in touch", r"hear from us", r"update you",
                  r"\bsoon\b", r"shortly", r"within", r"nothing (else|further|more)? ?is needed", r"escalat")
        for key, body in drain.LINES.items():
            for pat in banned:
                with self.subTest(line=key, pattern=pat):
                    self.assertNotRegex(body.lower(), pat)

    def test_a_denial_gives_no_reason_and_says_resubmit(self):
        body = drain.LINES["credits-decided"]
        self.assertIn("denied for now", body)
        self.assertIn("resubmit", body)
        self.assertNotRegex(body.lower(), r"because|due to|\bfraud|suspicio")

    def test_every_planned_line_and_owner_exists(self):
        self.assertTrue(set(drain.PLAN_LINE.values()) <= set(drain.LINES))
        self.assertTrue(set(drain.ACCOUNT_LINES) <= set(drain.LINES))
        self.assertEqual(set(drain.PLAN_LINE) & set(drain.OWNER_CAMPAIGN), set())

    def test_the_declined_line_is_the_recorded_body(self):
        self.assertEqual(
            drain.LINES["credits-declined"],
            "Sorry for the slow reply. Every credit request on your account has been reviewed and denied for now. "
            "You can resubmit for the credit again later. If you need help with anything else, reply here and tell "
            "us what you need.")
        self.assertIn("credits-declined", drain.ACCOUNT_LINES)


class Deps:
    """Fake reads and writes. `posts` is every real POST; `validated` every --validate call."""

    def __init__(self, convs, *, statuses=None, claims=0, gate="approved", held_users=(), erasure=(), promises=None,
                 restricted=(), post_ok=True, close_state="closed", stage2="", assign_effect=True,
                 staffed=(), shapes=None):
        self.stage2 = stage2
        self.staffed = tuple(staffed)
        self.assign_effect = assign_effect
        self.assignments = []
        self.raise_on = {}
        self.convs, self.statuses, self.claims, self.gate = convs, statuses or {"approved": 2}, claims, gate
        self.held_users, self.post_ok, self.close_state = set(held_users), post_ok, close_state
        self.posts, self.validated, self.closed, self.account_reads = [], [], [], 0
        self.notes, self.notes_validated = [], []
        self.ledger = drain.verify_ledger.connect(":memory:")
        self._erasure, self._promises, self._restricted = set(erasure), promises or {}, frozenset(restricted)
        self._shapes = shapes or {}

    now = staticmethod(lambda: NOW)
    sleep = staticmethod(lambda _s: None)

    def get_conv(self, cid):
        if cid in self.raise_on and (cid not in self.raise_after_assign or cid in self.assignments):
            raise self.raise_on[cid]
        return self.convs[cid]

    def erasure(self):
        return self._erasure

    def monitor(self):
        return self._shapes, self._promises

    def restricted(self):
        return self._restricted

    def presented(self, _rows):
        return {}

    def account_emails(self, uids):
        return {u: f"user{u}@example.test" for u in uids}

    def lens(self, uids):
        return {int(u): SimpleNamespace(held=["velocity"] if u in self.held_users else []) for u in uids}

    def stage2_hold(self, _db, _key, _uid, _cid, _day):
        return self.stage2

    def live_account(self, _uid, _presented):
        self.account_reads += 1
        if self.statuses == "unreadable":
            raise RuntimeError("replica down")
        return self.statuses, self.claims

    def post_reply(self, cid, body, line, validate=False):
        if self.gate != "approved":
            raise drain.copy_gate.CopyHeld("copy_review_" + self.gate, "0" * 64, pending=True)
        if validate:
            self.validated.append((cid, line))
            return {"rc": 0, "stdout": "VALID", "stderr": "", "verdict_id": "ocv-0123456789abcdef"}
        self.posts.append((cid, line, body))
        if not self.post_ok:
            return {"rc": 1, "stdout": "", "stderr": "refused", "verdict_id": "ocv-0123456789abcdef"}
        return {"rc": 0, "stdout": f"POSTED comment conversation={cid} part=p{len(self.posts)}", "stderr": "",
                "verdict_id": "ocv-0123456789abcdef"}

    def who(self):
        return ((BOT, OPERATOR), self.staffed)

    def assign(self, cid):
        self.assignments.append(cid)
        if self.assign_effect:
            self.convs[cid] = {**self.convs[cid], "admin_assignee_id": int(BOT)}

    def close_thread(self, cid):
        self.closed.append(cid)
        return self.close_state

    def post_note(self, cid, body, validate=False):
        if validate:
            self.notes_validated.append((cid, body))
            return {"rc": 0, "stdout": "VALID note", "stderr": ""}
        self.notes.append((cid, body))
        if not self.post_ok:
            return {"rc": 1, "stdout": "", "stderr": "refused"}
        conv_ = self.convs[cid]
        conv_["conversation_parts"]["conversation_parts"].append(
            part("note", "admin", BOT, self.now(), body=body))
        conv_["conversation_parts"]["total_count"] = len(conv_["conversation_parts"]["conversation_parts"])
        return {"rc": 0, "stdout": f"POSTED note conversation={cid} part=n{len(self.notes)}", "stderr": ""}


NOTE_HEADER = "Note to team (internal Ops note, not visible to the customer). Requested in Slack by Nick."


def note_body(marker_line, *, html=False):
    """The stored shape of a note: intercom-ops-write.sh puts its header above the body it is given."""
    if html:
        return f"<p>{NOTE_HEADER}</p>\n<p>{marker_line}</p>"
    return NOTE_HEADER + "\n\n" + marker_line


def handback_row(cid="1", *, reason="specific_ask", klass="specific ask", uid="77", conv_=None, order=1):
    row = plan_row(cid, line="", uid=uid, conv_=conv_, order=order)
    row["list"] = "caroline"
    row["handback"] = (reason, klass)
    return row


def plan_row(cid="1", *, line="credits-approved", mode="answer", uid="77", conv_=None, order=1, contact="k0",
             email=None):
    t = drain.read_thread(conv_ or conv(cid))
    return {"id": cid, "list": "close" if mode == "close" else "send", "class": "x", "line": line, "mode": mode,
            "user_id": uid, "contact_id": contact, "order": order,
            "email": f"c{cid}@example.test" if email is None else email,
            "last_customer_at": t["last_customer_at"], "last_reply_at": t["last_reply_at"]}


class SendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = os.path.join(self.tmp.name, "run.jsonl")
        self.said = []

    def run_send(self, plan, deps, **kw):
        kw.setdefault("apply", True)
        if kw["apply"]:
            kw.setdefault("ledger_path", self.ledger)
        return drain.run_send(plan, deps, out=self.said.append, **kw)

    def phases(self):
        if not os.path.exists(self.ledger):
            return []
        with open(self.ledger, encoding="utf8") as f:
            return [json.loads(line)["phase"] for line in f]

    def test_a_dry_run_posts_nothing_and_writes_no_ledger(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([plan_row()], deps, apply=False)
        self.assertEqual((stats["dry"], stats["sent"], deps.posts), (1, 0, []))
        self.assertEqual(deps.validated, [("1", "credits-approved")])
        self.assertFalse(os.path.exists(self.ledger))

    def test_an_unassigned_thread_is_assigned_to_caroline_then_answered(self):
        deps = Deps({"1": conv("1", admin=None)})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((deps.assignments, [p[0] for p in deps.posts], stats["assigned"]), (["1"], ["1"], 1))
        with open(self.ledger, encoding="utf8") as f:
            rows = [json.loads(line) for line in f]
        self.assertEqual([(r["phase"], r.get("what")) for r in rows][:4],
                         [("run", None), ("intent", "assign"), ("assigned", None), ("intent", None)])
        self.assertEqual(rows[1]["from"], {"admin_assignee_id": None, "team_assignee_id": None})
        self.assertEqual(rows[2]["to"], drain.INTERCOM_ADMIN_ID)

    def test_a_thread_the_operator_bot_holds_is_assigned_then_answered(self):
        deps = Deps({"1": conv("1", admin=int(OPERATOR))})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((deps.assignments, [p[0] for p in deps.posts], stats["assigned"]), (["1"], ["1"], 1))
        self.assertEqual(stats["skipped"], {})

    def test_a_read_back_that_does_not_show_caroline_sends_nothing(self):
        deps = Deps({"1": conv("1", admin=None)}, assign_effect=False)
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((deps.posts, stats["assigned"], stats["failed"]), ([], 0, 1))
        self.assertIn("assignment not confirmed", stats["skipped"])

    def test_an_assignment_that_raises_sends_nothing(self):
        deps = Deps({"1": conv("1", admin=None)})

        def boom(_cid):
            raise TimeoutError("assign")

        deps.assign = boom
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((deps.posts, stats["failed"]), ([], 1))
        self.assertIn("assignment failed: TimeoutError", stats["skipped"])

    def test_a_read_back_that_raises_a_transport_error_does_not_abort_the_run(self):
        import http.client
        deps = Deps({"1": conv("1", admin=None), "2": conv("2")})
        deps.raise_on = {"1": http.client.RemoteDisconnected("reset")}
        deps.raise_after_assign = {"1"}
        stats = self.run_send([plan_row("1"), plan_row("2", order=2)], deps)
        self.assertEqual((deps.posts, stats["assigned"], stats["failed"]), ([("2", "credits-approved",
                          drain.LINES["credits-approved"])], 0, 1))
        self.assertIn("assignment not confirmed", stats["skipped"])
        self.assertEqual(self.phases(), ["run", "intent", "assigned", "error", "intent", "sent"])

    def test_an_attachment_only_last_message_is_not_skipped_at_send_time(self):
        live = conv("1", parts=[part("comment", "user", "c1", NOW - 5 * DAY, body="")])
        deps = Deps({"1": live})
        stats = self.run_send([plan_row("1", conv_=live)], deps)
        self.assertEqual(([p[0] for p in deps.posts], stats["skipped"]), (["1"], {}))

    def test_the_assignment_call_posts_and_reads_nothing_back(self):
        parts, reads = [], []
        for name, value in (("_part", lambda *a, **kw: parts.append((a[1:], kw))),
                            ("get_conv", lambda *a: reads.append(a) or {})):
            old = getattr(drain, name)
            self.addCleanup(setattr, drain, name, old)
            setattr(drain, name, value)
        drain.assign_thread("tok", "7")
        self.assertEqual(parts, [(("7", "assignment"), {"assignee_id": drain.INTERCOM_ADMIN_ID,
                                                        "assignee_type": "admin"})])
        self.assertEqual(reads, [])

    def test_a_row_that_fails_an_earlier_check_is_never_assigned(self):
        deps = Deps({"1": conv("1", admin=None)}, restricted={"k0"})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((deps.assignments, deps.posts), ([], []))
        self.assertIn("restricted contact", stats["skipped"])

    def test_a_dry_run_assigns_nothing_and_says_it_would(self):
        deps = Deps({"1": conv("1", admin=None)})
        stats = self.run_send([plan_row()], deps, apply=False)
        self.assertEqual((deps.assignments, stats["dry"], stats["assigned"]), ([], 1, 0))
        self.assertIn("DRY-ASSIGN 1 from nobody", self.said)

    def test_no_non_held_holder_is_skipped_as_unassigned(self):
        for holder in (BOT, int(OPERATOR), None):
            with self.subTest(holder=holder):
                deps = Deps({"1": conv("1", admin=holder)})
                stats = self.run_send([plan_row()], deps)
                self.assertEqual([p[0] for p in deps.posts], ["1"])
                self.assertEqual(stats["skipped"], {})

    def test_apply_posts_the_fixed_body_once_and_records_it_before_and_after(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((stats["sent"], stats["failed"]), (1, 0))
        self.assertEqual(deps.posts, [("1", "credits-approved", drain.LINES["credits-approved"])])
        self.assertEqual(self.phases(), ["run", "intent", "sent"])

    def test_the_line_is_picked_from_the_states_read_at_send_time_not_from_the_plan(self):
        deps = Deps({"1": conv("1")}, statuses={"approved": 2, "rejected": 1})
        self.run_send([plan_row(line="credits-approved")], deps)
        self.assertEqual([p[1] for p in deps.posts], ["credits-decided"])

    def test_a_promise_that_opened_since_the_plan_sends_nothing(self):
        for line, uid in (("credits-approved", "77"), ("late-reply", "77"), ("no-account", "")):
            with self.subTest(line=line):
                deps = Deps({"1": conv("1")}, promises={"1": ["merge"]})
                stats = self.run_send([plan_row(line=line, uid=uid)], deps)
                self.assertEqual((deps.posts, deps.validated, stats["sent"]), ([], [], 0))
                self.assertEqual(stats["skipped"], {"an open promise this line does not keep": 1})

    def test_a_line_that_changed_at_send_time_is_checked_against_the_promise(self):
        # planned as credits-approved, which keeps the promise; the live read finds no request at all
        deps = Deps({"1": conv("1")}, statuses={"approved": 0}, promises={"1": ["credit_verification"]})
        stats = self.run_send([plan_row(line="credits-approved")], deps)
        self.assertEqual((deps.posts, stats["sent"]), ([], 0))
        self.assertEqual(stats["skipped"], {"an open promise this line does not keep": 1})

    def test_a_decided_line_goes_out_on_the_promise_it_keeps(self):
        deps = Deps({"1": conv("1")}, promises={"1": ["credit_verification"]})
        stats = self.run_send([plan_row(line="credits-approved")], deps)
        self.assertEqual(([p[1] for p in deps.posts], stats["sent"]), (["credits-approved"], 1))

    def test_a_request_that_opened_since_the_plan_sends_nothing(self):
        deps = Deps({"1": conv("1")}, statuses={"approved": 2, "user_verification_needed": 1})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual((stats["sent"], deps.posts, deps.validated), (0, [], []))
        self.assertIn("an open request or claim: owned by the verification senders", stats["skipped"])

    def test_unreadable_account_facts_send_nothing(self):
        deps = Deps({"1": conv("1")}, statuses="unreadable")
        stats = self.run_send([plan_row()], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("account facts unreadable (refuse, never guess)", stats["skipped"])

    def test_no_signed_approval_no_post_and_no_ledger_claim(self):
        for gate in ("pending", "observed", "refuse"):
            with self.subTest(gate=gate):
                deps = Deps({"1": conv("1")}, gate=gate)
                stats = self.run_send([plan_row()], deps)
                self.assertEqual((stats["sent"], deps.posts), (0, []))
                self.assertEqual(stats["copy_held"], {"credits-approved": 1})
                self.assertEqual(deps.ledger.execute("select count(*) from verify_messages").fetchone()[0], 0)

    def test_a_customer_message_or_a_reply_since_the_plan_skips_the_row(self):
        row = plan_row()
        wrote_again = conv("1", parts=[part("comment", "user", "c1", NOW - 60)])
        answered = conv("1", parts=[part("comment", "admin", BOT, NOW - 60)])
        for live, reason in ((wrote_again, "the customer wrote again since the plan"), (answered, "answered since the plan"),
                             (conv("1", state="closed"), "no longer open"), (conv("1", admin="999"), "held by person")):
            with self.subTest(reason=reason):
                deps = Deps({"1": live})
                stats = self.run_send([row], deps)
                self.assertEqual(deps.posts, [])
                self.assertIn(reason, stats["skipped"])

    def test_an_account_line_is_never_posted_on_a_thread_with_two_contacts(self):
        # 2026-11-13: a customer had CC'd a second address on the thread her status would have gone to
        deps = Deps({"1": conv("1", contacts=2)})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("more than one contact on the thread: no account facts are stated there", stats["skipped"])
        deps = Deps({"1": conv("1", contacts=2)})
        self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual([p[1] for p in deps.posts], ["late-reply"])

    def test_a_document_on_file_or_an_open_ask_holds_an_account_line(self):
        deps = Deps({"1": conv("1")}, stage2="stage-2 guard: document on file in the last 30 days")
        stats = self.run_send([plan_row()], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("stage-2 guard: document on file in the last 30 days", stats["skipped"])

    def test_the_real_stage_2_guard_fails_closed_when_the_proof_store_cannot_be_read(self):
        db = drain.verify_ledger.connect(":memory:")
        old = drain.backlog.PROOF_STORE
        drain.backlog.PROOF_STORE = os.path.join(self.tmp.name, "absent.sqlite")
        try:
            why = drain.backlog.stage2_hold(db, "p@example.test", "77", "1", "2026-11-13")
        finally:
            drain.backlog.PROOF_STORE = old
        self.assertIn("stage-2 guard", why)

    def test_a_line_with_no_account_facts_reads_no_account(self):
        deps = Deps({"1": conv("1")}, statuses="unreadable")
        self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual(([p[1] for p in deps.posts], deps.account_reads), (["late-reply"], 0))
        deps = Deps({"2": conv("2")})
        self.run_send([plan_row("2", line="no-account", uid="")], deps)
        self.assertEqual([p[1] for p in deps.posts], ["no-account"])

    def test_a_user_the_fraud_lens_holds_and_a_restricted_contact_get_nothing(self):
        deps = Deps({"1": conv("1")}, held_users={"77"})
        stats = self.run_send([plan_row()], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("fraud lens: held or unmeasured", stats["skipped"])
        deps = Deps({"1": conv("1")}, restricted={"k0"})
        stats = self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("restricted contact", stats["skipped"])

    def test_a_restricted_contact_on_a_multi_contact_thread_gets_nothing(self):
        # the census names only the first contact, so the hold must come from the live thread's contacts
        deps = Deps({"1": conv("1", contacts=2)}, restricted={"k1"})
        stats = self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("restricted contact", stats["skipped"])

    def test_an_erasure_request_filed_since_the_plan_skips_the_row(self):
        deps = Deps({"1": conv("1")}, erasure={"1"})
        stats = self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual(deps.posts, [])
        self.assertIn("open erasure or access request on this thread", stats["skipped"])

    def test_a_shape_the_monitor_reads_at_send_time_is_never_posted(self):
        deps = Deps({"1": conv("1")}, shapes={"1": "refund_dispute"})
        stats = self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual((deps.posts, deps.validated, stats["sent"]), ([], [], 0))
        self.assertEqual(stats["skipped"], {"monitor shape refund_dispute: outside this sender": 1})

    def test_a_shape_read_at_send_time_closes_nothing_and_hands_nothing_back(self):
        stale = conv("1", parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        deps = Deps({"1": stale}, shapes={"1": "gdpr_erasure"})
        stats = self.run_send([plan_row(line="stale-close", mode="close", conv_=stale)], deps)
        self.assertEqual((deps.posts, deps.closed, stats["closed"]), ([], [], 0))
        self.assertEqual(stats["skipped"], {"monitor shape gdpr_erasure: outside this sender": 1})
        deps = Deps({"1": conv("1")}, shapes={"1": "legal_notice"})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((deps.notes, deps.notes_validated, stats["handback_posted"]), ([], [], 0))
        self.assertEqual(stats["skipped"], {"monitor shape legal_notice: outside this sender": 1})

    def test_a_shape_that_did_not_change_still_sends(self):
        deps = Deps({"1": conv("1")}, shapes={"1": "proof_sent"})
        stats = self.run_send([plan_row(line="late-reply")], deps)
        self.assertEqual((stats["sent"], [p[0] for p in deps.posts], stats["skipped"]), (1, ["1"], {}))

    def test_one_message_per_user_per_day_and_one_reply_per_conversation_ever(self):
        convs = {"1": conv("1"), "2": conv("2")}
        deps = Deps(convs)
        plan = [plan_row("1", line="late-reply", order=1), plan_row("2", line="late-reply", order=2)]
        stats = self.run_send(plan, deps)
        self.assertEqual([p[0] for p in deps.posts], ["1"])            # same account: the second waits a day
        self.assertIn("user messaged today (ledger)", stats["skipped"])
        again = drain.run_send(plan[:1], deps, apply=True, ledger_path=self.ledger, out=self.said.append)
        self.assertEqual((again["sent"], [p[0] for p in deps.posts]), (0, ["1"]))
        self.assertIn("already answered (ledger)", again["skipped"])

    def test_a_stale_thread_is_closed_only_after_this_runs_note_posted(self):
        stale = conv("1", parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        deps = Deps({"1": stale})
        stats = self.run_send([plan_row(line="stale-close", mode="close", conv_=stale)], deps)
        self.assertEqual((stats["sent"], stats["closed"], deps.closed), (1, 1, ["1"]))
        self.assertEqual(self.phases(), ["run", "intent", "sent", "close_intent", "closed"])

    def test_a_failed_note_closes_nothing(self):
        stale = conv("1", parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        deps = Deps({"1": stale}, post_ok=False)
        stats = self.run_send([plan_row(line="stale-close", mode="close", conv_=stale)], deps)
        self.assertEqual((stats["sent"], stats["closed"], stats["failed"], deps.closed), (0, 0, 1, []))

    def test_a_close_that_does_not_read_back_closed_is_a_failure(self):
        stale = conv("1", parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        deps = Deps({"1": stale}, close_state="open")
        stats = self.run_send([plan_row(line="stale-close", mode="close", conv_=stale)], deps)
        self.assertEqual((stats["sent"], stats["closed"], stats["failed"]), (1, 0, 1))
        self.assertIn("error", self.phases())

    def test_a_declined_account_line_is_picked_at_send_time_and_still_held_by_the_gate(self):
        deps = Deps({"1": conv("1")}, statuses={"rejected": 2})
        self.run_send([plan_row(line="credits-approved")], deps)
        self.assertEqual([p[1] for p in deps.posts], ["credits-declined"])
        deps = Deps({"1": conv("1")}, statuses={"rejected": 2}, gate="pending")
        stats = self.run_send([plan_row(line="credits-declined")], deps)
        self.assertEqual((stats["sent"], deps.posts, stats["copy_held"]), (0, [], {"credits-declined": 1}))

    def test_a_thread_with_no_email_is_keyed_on_its_contact_and_told_no_account(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([plan_row(line="no-account", uid="", contact="c1abc", email="")], deps)
        self.assertEqual(([p[1] for p in deps.posts], stats["sent"]), (["no-account"], 1))
        self.assertEqual(deps.ledger.execute("select user_key from verify_messages").fetchone()[0],
                         "intercom-contact:c1abc")

    def test_a_second_thread_from_that_contact_the_same_utc_day_is_held(self):
        deps = Deps({"1": conv("1"), "2": conv("2")})
        plan = [plan_row("1", line="no-account", uid="", contact="c1abc", email="", order=1),
                plan_row("2", line="no-account", uid="", contact="c1abc", email="", order=2)]
        stats = self.run_send(plan, deps)
        self.assertEqual([p[0] for p in deps.posts], ["1"])
        self.assertIn("user messaged today (ledger)", stats["skipped"])

    def test_a_failing_thread_read_skips_that_row_and_the_rest_still_send(self):
        deps = Deps({"1": conv("1"), "2": conv("2"), "3": conv("3")})
        good = deps.get_conv

        def get_conv(cid):
            if cid == "2":
                raise TimeoutError("boom")
            return good(cid)

        deps.get_conv = get_conv
        plan = [plan_row(str(i), line="late-reply", uid=str(70 + i), order=i) for i in (1, 2, 3)]
        stats = self.run_send(plan, deps)
        self.assertEqual([p[0] for p in deps.posts], ["1", "3"])
        self.assertEqual(stats["skipped"].get("thread unreadable: TimeoutError"), 1)

    def test_a_thread_with_no_email_and_no_contact_is_counted_as_no_ledger_key(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([plan_row(line="no-account", uid="", contact="", email="")], deps)
        self.assertEqual((deps.posts, stats["skipped"].get("no_ledger_key")), ([], 1))

    def test_each_row_is_keyed_to_the_utc_day_it_is_sent_on(self):
        # the day a row carries is the day it is SENT on, not the day the run started: the ledger records a confirmed
        # send on the day it went out, so a POST accepted after midnight holds the next day (QA 2026-11-15).
        late = dt.datetime(2026, 11, 13, 23, 58, tzinfo=dt.timezone.utc).timestamp()
        after = dt.datetime(2026, 11, 14, 0, 0, 5, tzinfo=dt.timezone.utc).timestamp()
        # four reads of the clock per row: the pre-check day, the live-thread check, the claim day, the finalize day
        clock = [late, late, late, late, after, after, after, after]
        deps = Deps({"1": conv("1"), "2": conv("2")})
        deps.now = lambda: clock.pop(0)
        plan = [plan_row("1", line="late-reply", uid="77", order=1),
                plan_row("2", line="late-reply", uid="77", order=2)]
        stats = self.run_send(plan, deps)
        self.assertEqual((stats["sent"], [p[0] for p in deps.posts]), (2, ["1", "2"]))
        days = [r[0] for r in deps.ledger.execute("select day from verify_messages order by day").fetchall()]
        self.assertEqual(days, ["2026-11-13", "2026-11-14"])

    def test_a_thread_with_an_open_promise_or_a_recent_customer_message_is_not_closed(self):
        stale = conv("1", parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        deps = Deps({"1": stale}, promises={"1": ["unbacked"]})
        stats = self.run_send([plan_row(line="stale-close", mode="close", conv_=stale)], deps)
        self.assertEqual((deps.posts, deps.closed), ([], []))
        self.assertIn("an open promise on this thread: answer it, do not close it", stats["skipped"])
        fresh = conv("2", created=NOW - 40 * DAY, parts=[part("comment", "bot", OPERATOR, NOW - 39 * DAY)])
        deps = Deps({"2": fresh})
        stats = self.run_send([plan_row("2", line="stale-close", mode="close", conv_=fresh)], deps)
        self.assertEqual((deps.posts, deps.closed), ([], []))
        self.assertIn("not silent for over 90 days", stats["skipped"])

    def test_the_cap_is_200_a_run_and_apply_needs_a_ledger(self):
        deps = Deps({"1": conv("1")})
        with self.assertRaises(drain.Refused):
            drain.run_send([plan_row()], deps, apply=False, max_rows=201)
        with self.assertRaises(drain.Refused):
            drain.run_send([plan_row()], deps, apply=True, ledger_path="")
        with self.assertRaises(drain.Refused):
            drain.run_send([plan_row()], deps, apply=False, only=("invented",))
        self.assertEqual(deps.posts, [])

    def test_max_counts_sends_and_rows_outside_send_and_close_are_never_walked(self):
        convs = {str(i): conv(str(i)) for i in range(1, 5)}
        plan = [plan_row(str(i), line="late-reply", uid=str(70 + i), order=i) for i in range(1, 5)]
        plan.append({**plan_row("9", uid="99", order=0), "list": "owner"})
        deps = Deps(convs)
        stats = self.run_send(plan, deps, max_rows=2)
        self.assertEqual((stats["sent"], [p[0] for p in deps.posts]), (2, ["1", "2"]))

    def test_an_unmeasured_store_sends_nothing_at_all(self):
        deps = Deps({"1": conv("1")})
        deps.erasure = lambda: (_ for _ in ()).throw(drain.Unmeasured("erasure register unreadable"))
        with self.assertRaises(drain.Refused):
            self.run_send([plan_row()], deps)
        self.assertEqual(deps.posts, [])


class HandbackTests(unittest.TestCase):
    """A customer-last thread no fixed line can answer is handed to Caroline's live turn by one note."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = os.path.join(self.tmp.name, "run.jsonl")
        self.said = []

    def run_send(self, plan, deps, **kw):
        kw.setdefault("apply", True)
        if kw["apply"]:
            kw.setdefault("ledger_path", self.ledger)
        return drain.run_send(plan, deps, out=self.said.append, **kw)

    def phases(self):
        with open(self.ledger, encoding="utf8") as f:
            return [json.loads(line)["phase"] for line in f]

    def test_the_note_names_the_marker_the_reason_and_the_class(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual(stats["handback_posted"], 1)
        self.assertEqual(deps.notes, [("1", "hydra-handback: reason=specific_ask class=specific ask")])
        self.assertEqual(self.phases(), ["run", "intent", "handback_posted"])
        self.assertEqual(deps.posts, [])

    def test_a_hand_back_on_an_unassigned_thread_assigns_then_notes(self):
        deps = Deps({"1": conv("1", admin=None)})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((deps.assignments, [n[0] for n in deps.notes], stats["assigned"]), (["1"], ["1"], 1))
        self.assertEqual(self.phases(), ["run", "intent", "assigned", "intent", "handback_posted"])
        self.assertEqual(deps.posts, [])

    def test_a_hand_back_on_a_bot_held_thread_assigns_then_notes(self):
        deps = Deps({"1": conv("1", admin=int(OPERATOR))})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((deps.assignments, stats["handback_posted"]), (["1"], 1))

    def test_a_dry_run_posts_no_note_and_writes_no_ledger(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([handback_row()], deps, apply=False)
        self.assertEqual((stats["handback_dry"], stats["handback_posted"], deps.notes, deps.notes_validated[0][0]),
                         (1, 0, [], "1"))
        self.assertFalse(os.path.exists(self.ledger))

    def test_a_hand_back_claims_the_users_utc_day(self):
        deps = Deps({"1": conv("1"), "2": conv("2")})
        plan = [handback_row("1", order=1), handback_row("2", order=2)]
        stats = self.run_send(plan, deps)
        self.assertEqual(([n[0] for n in deps.notes], stats["skipped"].get("ledger: daily_cap")), (["1"], 1))

    def test_hand_backs_count_inside_max(self):
        deps = Deps({"1": conv("1"), "2": conv("2")})
        plan = [plan_row("1", order=1), handback_row("2", order=2)]
        stats = self.run_send(plan, deps, max_rows=1)
        self.assertEqual((stats["sent"], deps.notes), (1, []))

    def test_the_per_run_hand_back_cap_is_25(self):
        convs = {str(i): conv(str(i)) for i in range(1, 28)}
        plan = [handback_row(str(i), uid=str(100 + i), order=i) for i in range(1, 28)]
        deps = Deps(convs)
        stats = self.run_send(plan, deps)
        self.assertEqual((stats["handback_posted"], len(deps.notes)), (25, 25))

    def test_every_send_time_refusal_skips_the_hand_back(self):
        cases = {
            "no longer open": (conv("1", state="closed"), {}),
            "the customer no longer spoke last": (conv("1", parts=[part("comment", "admin", BOT, NOW - 60)]), {}),
            "held by person": (conv("1", admin="999"), {}),
            "held by staffed team": (conv("1", admin=None, team=555), {"staffed": ("555",)}),
            "restricted contact": (conv("1", contacts=2), {"restricted": ("k1",)}),
            "open erasure or access request on this thread": (conv("1"), {"erasure": ("1",)}),
        }
        for reason, (live, kw) in cases.items():
            with self.subTest(reason=reason):
                deps = Deps({"1": live}, **kw)
                stats = self.run_send([handback_row()], deps)
                self.assertEqual((deps.notes, stats["handback_posted"]), ([], 0))
                self.assertIn(reason, stats["skipped"])

    def test_a_hand_back_with_no_email_is_keyed_on_its_contact(self):
        row = handback_row(uid="")
        row["email"] = ""
        deps = Deps({"1": conv("1")})
        self.run_send([row], deps)
        self.assertEqual(deps.ledger.execute("select user_key from verify_messages").fetchone()[0],
                         "intercom-contact:k0")

    def test_a_failing_thread_read_skips_the_hand_back_and_keeps_going(self):
        deps = Deps({"1": conv("1"), "2": conv("2")})
        good = deps.get_conv

        def get_conv(cid):
            if cid == "1":
                raise TimeoutError("boom")
            return good(cid)

        deps.get_conv = get_conv
        plan = [handback_row("1", uid="77", order=1), handback_row("2", uid="78", order=2)]
        stats = self.run_send(plan, deps)
        self.assertEqual([n[0] for n in deps.notes], ["2"])
        self.assertEqual(stats["skipped"].get("thread unreadable: TimeoutError"), 1)

    def note_posted_at(self):
        with open(self.ledger, encoding="utf8") as f:
            rows = [json.loads(line) for line in f]
        return next(r for r in rows if r["phase"] == "handback_posted")

    def test_the_note_claims_one_shared_key_and_posts_once(self):
        deps = Deps({"1": conv("1")})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((stats["handback_posted"], len(deps.notes)), (1, 1))
        self.assertEqual(drain.verify_ledger.blocked_ids(deps.ledger, [drain.handback_key("1")],
                                                         drain.backlog.CAMPAIGN), {"handback-1"})

    def note_on(self, cid="1", *, age, body=None, html=False):
        return conv(cid, parts=[part("note", "admin", BOT, NOW - age, body=body or note_body(
            drain.HANDBACK_MARKER + " reason=specific_ask class=specific ask", html=html))])

    def test_a_note_younger_than_the_window_is_pending_and_not_a_new_hand_back(self):
        thread = drain.read_thread(self.note_on(age=3600))
        self.assertEqual(thread["handback_note_at"], NOW - 3600)
        plan = drain.build_plan([census("1")], [thread], set(), {}, {}, {}, {}, frozenset(), NOW)
        self.assertEqual((plan[0]["handback"], plan[0]["handback_state"]), ("", "pending"))
        summary = drain.summarize(plan)
        self.assertEqual((summary["handback"], summary["handback_pending"]), (0, 1))
        deps = Deps({"1": self.note_on(age=3600)})
        stats = self.run_send(plan, deps)
        self.assertEqual((stats["handback_posted"], stats["sent"], deps.posts, deps.notes), (0, 0, [], []))
        self.assertIn("hand-back already posted (pending)", stats["skipped"])

    def test_a_note_past_the_window_is_unconfirmed_with_its_id(self):
        thread = drain.read_thread(self.note_on(age=25 * 3600))
        plan = drain.build_plan([census("1")], [thread], set(), {}, {}, {}, {}, frozenset(), NOW)
        summary = drain.summarize(plan)
        self.assertEqual((summary["handback"], summary["handback_unconfirmed"],
                          summary["handback_unconfirmed_ids"]), (0, 1, ["1"]))
        deps = Deps({"1": self.note_on(age=25 * 3600)})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((stats["handback_posted"], stats["handback_unconfirmed"],
                          stats["handback_unconfirmed_ids"], deps.notes), (0, 1, ["1"], []))
        self.assertIn("HANDBACK UNCONFIRMED 1", " ".join(self.said))

    def test_our_worded_reply_after_the_note_confirms_it(self):
        thread = drain.read_thread(conv("1", parts=[
            part("note", "admin", BOT, NOW - 25 * 3600,
                 body=note_body(drain.HANDBACK_MARKER + " reason=specific_ask class=x")),
            part("comment", "admin", BOT, NOW - 24 * 3600, body="<p>Update for you</p>")]))
        self.assertEqual(thread["handback_note_at"], NOW - 25 * 3600)
        plan = drain.build_plan([census("1")], [thread], set(), {}, {}, {}, {}, frozenset(), NOW)
        summary = drain.summarize(plan)
        self.assertEqual((plan[0]["handback_state"], summary["handback_confirmed"], summary["handback_unconfirmed"]),
                         ("confirmed", 1, 0))
        deps = Deps({"1": conv("1", parts=[
            part("note", "admin", BOT, NOW - 25 * 3600,
                 body=note_body(drain.HANDBACK_MARKER + " reason=x class=y"))])})
        stats = self.run_send(plan, deps)
        self.assertEqual((stats["handback_posted"], stats["sent"], deps.posts, deps.notes), (0, 0, [], []))

    def test_a_bodyless_reply_of_ours_or_a_second_note_is_not_a_confirmation(self):
        for kind, body in (("comment", ""), ("comment", "<p></p>"), ("note", "another note")):
            with self.subTest(kind=kind, body=body):
                thread = drain.read_thread(conv("1", parts=[
                    part("note", "admin", BOT, NOW - 25 * 3600,
                         body=note_body(drain.HANDBACK_MARKER + " reason=x class=y")),
                    part(kind, "admin", BOT, NOW - 3600, body=body)]))
                self.assertEqual(drain.handback_state_of({**thread, "last_word": "customer"}, NOW),
                                 "unconfirmed")

    def test_the_marker_must_be_our_own_note(self):
        cases = (
            part("comment", "user", "c1", NOW - 3600, body=drain.HANDBACK_MARKER),
            part("note", "admin", "999", NOW - 3600, body=note_body(drain.HANDBACK_MARKER + " reason=x class=y")),
            part("comment", "user", "c1", NOW - 3600, body="hello"),
        )
        for p in cases:
            with self.subTest(p=p["part_type"]):
                self.assertEqual(drain.read_thread(conv("1", parts=[p]))["handback_note_at"], 0)

    def test_the_marker_is_found_in_the_body_the_writer_really_stores(self):
        for html in (False, True):
            with self.subTest(html=html):
                thread = drain.read_thread(self.note_on(age=3600, html=html))
                self.assertEqual(thread["handback_note_at"], NOW - 3600)

    def test_a_headerless_marker_body_is_still_a_hand_back_note(self):
        thread = drain.read_thread(self.note_on(
            age=3600, body=drain.HANDBACK_MARKER + " reason=specific_ask class=specific ask"))
        self.assertEqual(thread["handback_note_at"], NOW - 3600)

    def test_the_body_post_note_sends_is_recognised_once_the_writer_wraps_it(self):
        deps = Deps({"1": conv("1")})
        note = drain.handback_note("specific_ask", "specific ask")
        deps.post_note("1", note)
        stored = note_body(note, html=True)
        thread = drain.read_thread(conv("1", parts=[part("note", "admin", BOT, NOW, body=stored)]))
        self.assertEqual(thread["handback_note_at"], NOW)

    def test_the_hold_file_stops_every_hand_back(self):
        """The hold is a file, not a promise: until the plugin that reads the note is deployed, a
        bare marker note makes Caroline greet someone waiting months (firstmate 2026-11-15 15:03Z)."""
        hold = os.path.join(self.tmp.name, "handback.disabled")
        open(hold, "w").close()
        deps = Deps({"1": conv("1")})
        with mock.patch.object(drain, "HANDBACK_HOLD_FILE", hold):
            stats = self.run_send([handback_row()], deps)
        self.assertEqual((stats["handback_posted"], deps.notes), (0, []))
        self.assertTrue(any(k.startswith("hand-back held") for k in stats["skipped"]), stats["skipped"])

    def test_a_plan_built_before_the_note_is_counted_by_its_age(self):
        for age, state, counted in ((3600, "pending", "handback_pending"),
                                    (25 * 3600, "unconfirmed", "handback_unconfirmed")):
            with self.subTest(age=age):
                self.said.clear()
                deps = Deps({"1": self.note_on(age=age)})
                stats = self.run_send([handback_row()], deps)
                self.assertEqual((stats["handback_posted"], deps.notes, stats[counted]), (0, [], 1))
                self.assertIn("hand-back already posted (" + state + ")", stats["skipped"])
                said = " ".join(self.said)
                self.assertEqual("HANDBACK UNCONFIRMED 1" in said, state == "unconfirmed")
                self.assertEqual("HANDBACK PENDING 1" in said, state == "pending")

    def test_a_fresh_plan_prints_the_hand_back_state_of_rows_the_sender_does_not_post(self):
        for age, state, counted in ((3600, "pending", "handback_pending"),
                                    (25 * 3600, "unconfirmed", "handback_unconfirmed")):
            with self.subTest(age=age):
                self.said.clear()
                cid = "1"
                live = conv(cid, parts=[part("comment", "user", "c1", NOW - 2 * 3600,
                                             body="<p>any update?</p>")])
                live["conversation_parts"]["conversation_parts"].append(
                    part("note", "admin", BOT, NOW - age,
                         body=note_body(drain.HANDBACK_MARKER + " reason=specific_ask class=specific ask")))
                plan = drain.build_plan([census(cid, topic="merge")], [drain.read_thread(live)],
                                        set(), {}, {}, {}, {}, frozenset(), NOW)
                self.assertEqual((plan[0]["list"], plan[0]["handback_state"]), ("caroline", state))
                deps = Deps({cid: live})
                stats = self.run_send(plan, deps)
                said = " ".join(self.said)
                self.assertEqual((deps.notes, deps.posts, stats["handback_posted"]), ([], [], 0))
                self.assertEqual(stats[counted], 1)
                self.assertEqual("HANDBACK UNCONFIRMED " + cid in said, state == "unconfirmed")
                self.assertEqual("HANDBACK PENDING " + cid in said, state == "pending")
                self.assertEqual(stats["handback_unconfirmed_ids"], [cid] if state == "unconfirmed" else [])

    def reported(self, age):
        """(conversation, plan) for a thread the sender does not post on: it carries a marker note `age` old."""
        live = conv("1", parts=[part("comment", "user", "c1", NOW - 30 * 3600, body="<p>any update?</p>")])
        live["conversation_parts"]["conversation_parts"].append(
            part("note", "admin", BOT, NOW - age,
                 body=note_body(drain.HANDBACK_MARKER + " reason=specific_ask class=specific ask")))
        plan = drain.build_plan([census("1", topic="merge")], [drain.read_thread(live)],
                                set(), {}, {}, {}, {}, frozenset(), NOW)
        return live, plan

    def test_a_hand_back_answered_after_the_plan_is_not_reported_as_owed(self):
        # QA review of #1978: the report used to copy the plan's state without reading the thread again
        for age, state in ((3600, "pending"), (25 * 3600, "unconfirmed")):
            with self.subTest(state=state):
                self.said.clear()
                live, plan = self.reported(age)
                self.assertEqual(plan[0]["handback_state"], state)
                live["conversation_parts"]["conversation_parts"].append(
                    part("comment", "admin", BOT, NOW - 60, body="<p>Here is where your merge stands.</p>"))
                stats = self.run_send(plan, Deps({"1": live}))
                said = " ".join(self.said)
                self.assertNotIn("HANDBACK UNCONFIRMED", said)
                self.assertNotIn("HANDBACK PENDING", said)
                self.assertEqual((stats["handback_unconfirmed"], stats["handback_unconfirmed_ids"],
                                  stats["handback_pending"], stats["handback_confirmed"]), (0, [], 0, 1))

    def test_the_reported_state_is_the_one_the_thread_shows_now(self):
        # the plan saw the note inside its window; by the time of the run the thread no longer carries it
        live, plan = self.reported(3600)
        gone = conv("1", parts=[part("comment", "user", "c1", NOW - 30 * 3600, body="<p>any update?</p>")])
        stats = self.run_send(plan, Deps({"1": gone}))
        self.assertEqual((stats["handback_pending"], stats["handback_unconfirmed"], stats["handback_confirmed"]),
                         (0, 0, 0))
        self.assertEqual(self.said, [])

    def test_a_reported_thread_that_cannot_be_read_is_unread_not_owed_and_not_answered(self):
        live, plan = self.reported(25 * 3600)
        deps = Deps({"1": live, "2": conv("2")})
        deps.raise_on = {"1": TimeoutError("read")}
        deps.raise_after_assign = set()
        stats = self.run_send(plan + [plan_row("2", order=2)], deps)
        self.assertEqual((stats["handback_unread"], stats["handback_unread_ids"]), (1, ["1"]))
        self.assertEqual((stats["handback_unconfirmed"], stats["handback_unconfirmed_ids"],
                          stats["handback_confirmed"]), (0, [], 0))
        self.assertIn("HANDBACK UNREAD 1: TimeoutError", self.said)
        self.assertEqual(stats["sent"], 1)                       # the run goes on

    def test_an_open_promise_no_line_keeps_is_handed_back_with_its_own_reason(self):
        live = conv("1")
        plan = drain.build_plan([census("1")], [drain.read_thread(live)], set(), {}, {"1": ["unbacked"]},
                                {}, {}, frozenset(), NOW)
        self.assertEqual((plan[0]["list"], plan[0]["class"], plan[0]["handback"]),
                         ("caroline", "open_promise", ("open_promise", "open promise")))
        deps = Deps({"1": live}, promises={"1": ["unbacked"]})
        stats = self.run_send(plan, deps)
        self.assertEqual((stats["handback_posted"], deps.posts), (1, []))
        self.assertEqual(deps.notes, [("1", "hydra-handback: reason=open_promise class=open promise")])

    def test_a_claim_with_no_visible_note_stays_owed(self):
        deps = Deps({"1": conv("1")})
        claim = drain.verify_ledger.claim(
            deps.ledger, user_key="user77@example.test", day=drain.utc_day(NOW),
            request_ids=[drain.handback_key("1")], message_type="note", approved_by=drain.APPROVER,
            approval_ref="backlog-handback:specific_ask", contact_id="k0", campaign=drain.backlog.CAMPAIGN,
            user_id="77")
        drain.backlog.ledger_finalize(deps.ledger, claim["message_row"], "1", 4, "", "", "note", part_type="note")
        self.assertEqual(drain.verify_ledger.blocked_ids(deps.ledger, [drain.handback_key("1")],
                                                         drain.backlog.CAMPAIGN), {"handback-1"})
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((stats["handback_posted"], stats["handback_unconfirmed"],
                          stats["handback_unconfirmed_ids"], deps.notes), (0, 1, ["1"], []))
        self.assertIn("HANDBACK UNCONFIRMED 1", " ".join(self.said))

    def test_two_runs_with_different_ledgers_behave_like_one(self):
        deps = Deps({"1": conv("1")})
        self.run_send([handback_row()], deps)
        other = os.path.join(self.tmp.name, "run2.jsonl")
        later = Deps({"1": deps.convs["1"]})
        later.now = staticmethod(lambda: NOW + 25 * 3600)
        stats = drain.run_send([handback_row()], later, apply=True, ledger_path=other, out=self.said.append)
        self.assertEqual((stats["handback_posted"], stats["handback_unconfirmed"], later.notes), (0, 1, []))

    def test_a_failed_note_is_a_failure_and_hands_nothing_back(self):
        deps = Deps({"1": conv("1")}, post_ok=False)
        stats = self.run_send([handback_row()], deps)
        self.assertEqual((stats["handback_posted"], stats["failed"]), (0, 1))
        self.assertEqual(self.phases(), ["run", "intent", "error"])


class PlanTests(unittest.TestCase):
    def test_proof_sent_first_then_oldest_and_closes_after_every_answer(self):
        rows = [census("a", credits={"approved": 1}), census("b", credits={"approved": 1}),
                census("c", credits={"approved": 1}), census("d")]
        rows[0]["waiting_since"], rows[1]["waiting_since"], rows[2]["waiting_since"] = 300, 200, 100
        stale = conv("d", parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)])
        threads = [drain.read_thread(c) for c in (conv("a"), conv("b"), conv("c"), stale)]
        plan = drain.build_plan(rows, threads, set(), {"b": "proof_sent"}, {}, {}, {}, frozenset(), NOW)
        self.assertEqual([(x["id"], x["list"]) for x in plan],
                         [("b", "send"), ("c", "send"), ("a", "send"), ("d", "close")])
        self.assertEqual(drain.summarize(plan)["by_list"], {"send": 3, "close": 1})

    def test_a_paying_customer_comes_first_then_proof_sent_then_oldest(self):
        # six answers and two closes; waiting_since ascending = oldest first
        ids = ("old_free", "paid_new", "paid_old", "proof_free", "paid_proof", "free_new")
        rows = [census(i, credits={"approved": 1}, uid=str(n)) for n, i in enumerate(ids, 70)]
        for r, since, paid in zip(rows, (100, 600, 500, 400, 700, 300), (False, True, True, False, True, False)):
            r["waiting_since"], r["paid"] = since, paid
        closes = [census("close_free", uid="90"), census("close_paid", uid="91")]
        closes[0]["waiting_since"], closes[1]["waiting_since"], closes[1]["paid"] = 50, 60, True
        stale = [conv(c["id"], parts=[part("comment", "bot", OPERATOR, NOW - 199 * DAY)]) for c in closes]
        threads = [drain.read_thread(conv(i)) for i in ids] + [drain.read_thread(c) for c in stale]
        shapes = {"proof_free": "proof_sent", "paid_proof": "proof_sent"}
        plan = drain.build_plan(rows + closes, threads, set(), shapes, {}, {}, {}, frozenset(), NOW)
        self.assertEqual([(x["id"], x["list"]) for x in plan], [
            ("paid_proof", "send"), ("paid_old", "send"), ("paid_new", "send"),      # paid: proof first, then oldest
            ("proof_free", "send"), ("old_free", "send"), ("free_new", "send"),      # then the same for the rest
            ("close_paid", "close"), ("close_free", "close")])                       # closes after every answer
        self.assertEqual([x["order"] for x in plan], list(range(1, 9)))

    def test_a_capped_run_answers_the_paying_customer_before_an_older_unpaid_one(self):
        rows = [census("free", credits={"approved": 1}, uid="70"), census("paid", credits={"approved": 1}, uid="71")]
        rows[0]["waiting_since"], rows[1]["waiting_since"], rows[1]["paid"] = 100, 900, True
        rows[0]["email"], rows[1]["email"] = "free@example.test", "paid@example.test"
        convs = {"free": conv("free"), "paid": conv("paid")}
        plan = drain.build_plan(rows, [drain.read_thread(convs[r["id"]]) for r in rows], set(), {}, {}, {}, {},
                                frozenset(), NOW)
        said = []
        stats = drain.run_send(plan, Deps(convs), apply=False, max_rows=1, out=said.append)
        self.assertEqual((stats["dry"], [m for m in said if m.startswith("DRY ")]),
                         (1, ["DRY paid answer credits-approved"]))

    def test_an_unpaid_or_accountless_row_is_never_ahead_of_a_paid_one(self):
        for unpaid in (False, None, 0, ""):
            with self.subTest(unpaid=unpaid):
                older = {"list": "send", "paid": unpaid, "shape": "proof_sent", "waiting_since": 1}
                paid = {"list": "send", "paid": True, "shape": "", "waiting_since": 999}
                self.assertLess(drain.plan_order(paid), drain.plan_order(older))
        self.assertLess(drain.plan_order({"list": "send", "paid": False, "waiting_since": 999}),
                        drain.plan_order({"list": "close", "paid": True, "waiting_since": 1}))

    def test_the_hand_backs_are_walked_paid_first_then_oldest(self):
        convs = {i: conv(i) for i in ("free_old", "paid_new", "paid_old")}
        rows = [handback_row(i, uid=str(n), conv_=convs[i]) for n, i in enumerate(convs, 70)]
        for r, since, paid in zip(rows, (100, 900, 500), (False, True, True)):
            r["waiting_since"], r["paid"] = since, paid
        said = []
        stats = drain.run_send(rows, Deps(convs), apply=False, out=said.append)
        self.assertEqual(stats["handback_dry"], 3)
        self.assertEqual([m.split()[1] for m in said if m.startswith("DRY-HANDBACK")],
                         ["paid_old", "paid_new", "free_old"])

    def test_a_restricted_second_contact_holds_the_row(self):
        rows = [census("a", credits={"approved": 1})]
        threads = [drain.read_thread(conv("a", contacts=2))]
        plan = drain.build_plan(rows, threads, set(), {}, {}, {}, {}, frozenset({"k1"}), NOW)
        self.assertEqual((plan[0]["list"], plan[0]["class"]), ("held", "restricted"))

    def test_the_plan_counts_rows_with_no_ledger_key(self):
        row = census("a", uid="")
        row["email"], row["contact_id"] = "", ""
        plan = drain.build_plan([row], [drain.read_thread(conv("a"))], set(), {}, {}, {}, {}, frozenset(), NOW)
        self.assertEqual(drain.summarize(plan)["no_ledger_key"], 1)

    def test_a_row_the_run_cannot_act_on_is_never_counted_as_missing_a_ledger_key(self):
        row = census("a", uid="")
        row["email"], row["contact_id"] = "", ""
        held = conv("a", admin="999")
        plan = drain.build_plan([row], [drain.read_thread(held)], set(), {}, {}, {}, {}, frozenset(), NOW)
        self.assertEqual(plan[0]["list"], "held")
        self.assertEqual(drain.summarize(plan)["no_ledger_key"], 0)

    def test_the_plan_does_not_count_a_hand_back_the_sender_cannot_post(self):
        rows = [census("a", topic="removal"), census("b", topic="removal")]
        promise = conv("a", parts=[part("comment", "user", "c1", NOW - 10 * DAY),
                                   part("comment", "admin", BOT, NOW - 5 * DAY, body="<p>we will update you</p>")])
        threads = [drain.read_thread(promise), drain.read_thread(conv("b", created=NOW - 10 * DAY))]
        plan = drain.build_plan(rows, threads, set(), {}, {"a": [{"text": "update you"}]}, {}, {}, frozenset(), NOW)
        self.assertEqual({x["id"]: (x["list"], x["mode"], x["handback"]) for x in plan}["a"],
                         ("caroline", "promise", ""))
        self.assertEqual(drain.summarize(plan)["handback"], 1)
        deps = Deps({"a": promise, "b": conv("b", created=NOW - 10 * DAY)})
        plan_rows = [x for x in plan if x.get("handback")]
        stats = drain.run_send(plan_rows, deps, apply=False, out=lambda _m: None)
        self.assertEqual(stats["handback_dry"], drain.summarize(plan)["handback"])

    def test_the_plan_hands_back_a_customer_last_open_promise_and_counts_it(self):
        rows = [census("a"), census("b"), census("c", credits={"approved": 1})]
        ours_last = conv("b", parts=[part("comment", "admin", BOT, NOW - 199 * DAY, body="<p>we will merge them</p>")])
        threads = [drain.read_thread(conv("a")), drain.read_thread(ours_last), drain.read_thread(conv("c"))]
        promises = {"a": ["merge"], "b": ["merge"], "c": ["credit_verification"]}
        plan = drain.build_plan(rows, threads, set(), {}, promises, {}, {}, frozenset(), NOW)
        got = {x["id"]: (x["list"], x["class"], x["mode"], x["handback"]) for x in plan}
        self.assertEqual(got["a"], ("caroline", "open_promise", "answer", ("open_promise", "open promise")))
        self.assertEqual(got["b"], ("caroline", "open_promise", "promise", ""))    # not customer-last: no note
        self.assertEqual(got["c"][:3], ("send", "credit_all_decided", "answer"))
        summary = drain.summarize(plan)
        self.assertEqual((summary["handback"], summary["handback_by_class"]), (1, {"open promise": 1}))
        self.assertEqual(summary["caroline_by_class"], {"open_promise": 2})
        deps = Deps({"a": conv("a"), "b": ours_last, "c": conv("c")}, promises=promises)
        stats = drain.run_send(plan, deps, apply=False, out=lambda _m: None)
        self.assertEqual((stats["handback_dry"], stats["by_line"]), (summary["handback"], {"credits-approved": 1}))

    def test_the_plan_marks_the_hand_back_rows_and_the_recent_owner_only(self):
        rows = [census("a", topic="removal"), census("b", credits={"pending": 1}), census("c", credits={"pending": 1})]
        threads = [drain.read_thread(conv("a", created=NOW - 10 * DAY)),
                   drain.read_thread(conv("b", created=NOW - 10 * DAY)),
                   drain.read_thread(conv("c", created=NOW - 40 * DAY))]
        plan = drain.build_plan(rows, threads, set(), {}, {}, {}, {}, frozenset(), NOW)
        got = {x["id"]: (x["list"], x["handback"]) for x in plan}
        self.assertEqual(got["a"], ("caroline", ("specific_ask", "specific ask")))
        self.assertEqual(got["b"], ("owner", ("owner_recent", "status-team-review")))
        self.assertEqual(got["c"], ("owner", ""))
        self.assertEqual(drain.summarize(plan)["handback"], 2)


class UnarmedTests(unittest.TestCase):
    """The drain ships unarmed: nothing in this repo may schedule it with --apply."""

    def scheduled_commands(self):
        commands = []
        with open(os.path.join(ROOT, "cron-jobs.json"), encoding="utf8") as f:
            doc = json.load(f)

        def walk(node):
            if isinstance(node, list) and node and all(isinstance(item, str) for item in node):
                commands.append(" ".join(node))
            elif isinstance(node, list):
                for item in node:
                    walk(item)
            elif isinstance(node, dict):
                for value in node.values():
                    walk(value)
            elif isinstance(node, str):
                commands.append(node)

        walk(doc)
        skip = {".git", "node_modules", "dist", "__pycache__", ".venv", "worktrees"}
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [d for d in dirnames if d not in skip]
            for name in filenames:
                if name.endswith((".service", ".timer", ".path")):
                    with open(os.path.join(dirpath, name), encoding="utf8", errors="replace") as f:
                        commands.append(" ".join(f.read().splitlines()))
        return commands

    def test_no_cron_job_or_unit_runs_the_drain_with_apply(self):
        armed = [c for c in self.scheduled_commands() if "intercom-backlog/drain.py" in c and "--apply" in c]
        self.assertEqual(armed, [])


class PlanSummaryTests(unittest.TestCase):
    def test_the_plan_counts_the_rows_that_will_need_an_assignment(self):
        rows = [census("a", credits={"approved": 1}), census("b", credits={"approved": 1}),
                census("c", credits={"approved": 1}), census("d", credits={"approved": 1})]
        threads = [drain.read_thread(conv("a")),
                   drain.read_thread(conv("b", admin=None)),
                   drain.read_thread(conv("c", admin=int(OPERATOR))),
                   drain.read_thread(conv("d", admin="999"))]
        plan = drain.build_plan(rows, threads, set(), {}, {}, {}, {}, frozenset(), NOW)
        summary = drain.summarize(plan)
        self.assertEqual(summary["needs_assignment"], 2)


class UnassignTests(unittest.TestCase):
    """Undo restores the inverse each `assigned` row recorded, and never restores to a person."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = os.path.join(self.tmp.name, "run.jsonl")
        with open(self.ledger, "w", encoding="utf8") as f:
            for row in (
                {"phase": "assigned", "id": "1", "from": {"admin_assignee_id": None, "team_assignee_id": "777"}},
                {"phase": "assigned", "id": "2", "from": {"admin_assignee_id": OPERATOR, "team_assignee_id": None}},
                {"phase": "assigned", "id": "3", "from": {"admin_assignee_id": "999", "team_assignee_id": None}},
            ):
                f.write(json.dumps(row) + "\n")
        self.calls, self.state = [], {}
        self.live = {"1": {"admin": BOT, "team": "777"}, "2": {"admin": BOT}}
        self.raise_on = {}
        for name, value in (("assign_thread", self.fake_assign), ("get_conv", self.fake_get),
                            ("read_who", lambda: ((BOT, OPERATOR), ()))):
            old = getattr(drain, name)
            self.addCleanup(setattr, drain, name, old)
            setattr(drain, name, value)

    def fake_assign(self, _token, cid, assignee_id=drain.INTERCOM_ADMIN_ID, assignee_type="admin"):
        self.calls.append((cid, assignee_id, assignee_type))
        if assignee_type == "admin":
            self.state[cid] = {**self.state.get(cid, {}), "admin": "" if assignee_id == "0" else assignee_id}
        else:
            self.state[cid] = {**self.state.get(cid, {}), "team": assignee_id}

    def fake_get(self, _token, cid):
        if cid in self.raise_on:
            raise self.raise_on[cid]
        seen = {**self.live.get(cid, {}), **(self.state.get(cid) or {})}
        return conv(cid, admin=seen.get("admin") or None, team=seen.get("team") or None,
                    state=seen.get("state") or "open")

    def test_the_undo_restores_the_recorded_before_values(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = drain.cmd_unassign(SimpleNamespace(ledger=self.ledger), "tok")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue()), {"restored": 2, "refused": 1, "failed": 0})
        self.assertEqual(self.calls, [("1", "0", "admin"), ("1", "777", "team"), ("2", OPERATOR, "admin")])

    def undo(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = drain.cmd_unassign(SimpleNamespace(ledger=self.ledger), "tok")
        return rc, json.loads(buf.getvalue())

    def test_the_undo_refuses_a_thread_a_person_holds_now(self):
        self.live["1"] = {"admin": "999"}
        rc, stats = self.undo()
        self.assertEqual((rc, stats), (0, {"restored": 1, "refused": 2, "failed": 0}))
        self.assertEqual(self.calls, [("2", OPERATOR, "admin")])

    def test_the_undo_refuses_a_thread_escalated_since(self):
        self.live["1"] = {"admin": None, "team": drain.ESCALATION_TEAM}
        self.undo()
        self.assertEqual(self.calls, [("2", OPERATOR, "admin")])

    def test_the_undo_refuses_a_thread_a_staffed_team_holds_now(self):
        self.live["1"] = {"admin": None, "team": "555"}
        drain.read_who = lambda: ((BOT, OPERATOR), ("555",))
        self.undo()
        self.assertEqual(self.calls, [("2", OPERATOR, "admin")])

    def test_the_undo_refuses_a_thread_closed_since(self):
        self.live["1"] = {"admin": BOT, "team": "777", "state": "closed"}
        self.undo()
        self.assertEqual(self.calls, [("2", OPERATOR, "admin")])

    def test_the_undo_refuses_a_thread_it_cannot_read(self):
        self.raise_on["1"] = RuntimeError("unreadable")
        self.undo()
        self.assertEqual(self.calls, [("2", OPERATOR, "admin")])

    def test_the_undo_refuses_a_thread_a_bot_took_since(self):
        self.live["1"] = {"admin": OPERATOR, "team": "777"}
        self.undo()
        self.assertEqual(self.calls, [("2", OPERATOR, "admin")])

    def test_every_refusal_names_the_conversation_and_the_reason(self):
        self.live["1"] = {"admin": "999"}
        self.undo()
        with open(self.ledger + ".unassign", encoding="utf8") as f:
            rows = [json.loads(line) for line in f]
        self.assertEqual([(r["id"], r["result"], r["why"]) for r in rows if r["result"] == "refused"],
                         [("1", "refused", "held by person"),
                          ("3", "refused", "the recorded holder is a person, not 0 or a bot")])

    def test_the_undo_records_what_it_did(self):
        with contextlib.redirect_stdout(io.StringIO()):
            drain.cmd_unassign(SimpleNamespace(ledger=self.ledger), "tok")
        with open(self.ledger + ".unassign", encoding="utf8") as f:
            rows = [json.loads(line) for line in f]
        self.assertEqual([(r["id"], r["result"]) for r in rows], [("1", "restored"), ("2", "restored"),
                                                                 ("3", "refused")])

    def test_the_undo_does_nothing_when_the_who_is_unreadable(self):
        def blind():
            raise drain.Unmeasured("caroline shapes unreadable")

        drain.read_who = blind
        with self.assertRaises(drain.Refused):
            drain.cmd_unassign(SimpleNamespace(ledger=self.ledger), "tok")
        self.assertEqual(self.calls, [])


class PlanCommandTests(unittest.TestCase):
    """One failing conversation read must not discard the whole measurement."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = os.path.join(self.tmp.name, "census.jsonl")
        self.out = os.path.join(self.tmp.name, "plan.jsonl")
        with open(self.source, "w", encoding="utf8") as f:
            for cid in ("1", "2", "3"):
                row = census(cid, credits={"approved": 1})
                row["waiting_since"] = int(time.time()) - 10 * DAY
                f.write(json.dumps(row) + "\n")
        for name, value in (("read_erasure", set), ("read_monitor", lambda: ({}, {})),
                            ("read_documents", lambda _uids: ({}, {})),
                            ("read_restricted", lambda: frozenset({"a" * 24}))):
            old = getattr(drain, name)
            self.addCleanup(setattr, drain, name, old)
            setattr(drain, name, value)
        old_get = drain.get_conv
        self.addCleanup(setattr, drain, "get_conv", old_get)

        def get_conv(_token, cid):
            if cid == "2":
                raise TimeoutError("boom")
            return conv(cid)

        drain.get_conv = get_conv

    def test_one_failing_read_still_writes_the_plan_and_names_the_error(self):
        rc = drain.cmd_plan(SimpleNamespace(source=self.source, out=self.out, overrides=None), "tok")
        self.assertEqual(rc, 0)
        with open(self.out, encoding="utf8") as f:
            plan = [json.loads(line) for line in f]
        got = {x["id"]: x for x in plan}
        self.assertEqual(got["2"]["list"], "unread")
        self.assertIn("TimeoutError", got["2"]["basis"])
        self.assertEqual((got["1"]["list"], got["3"]["list"]), ("send", "send"))


class Response:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def read(self):
        return json.dumps(self.payload).encode()


class WritePathTests(unittest.TestCase):
    """What actually leaves this file: the gate ask, the wrapper argv, and the admin identity on a part."""

    def setUp(self):
        self.runs, self.asks, self.requests = [], [], []
        for owner, name in ((drain.subprocess, "run"), (drain.copy_gate, "require"),
                            (drain.urllib.request, "urlopen")):
            old = getattr(owner, name)
            self.addCleanup(setattr, owner, name, old)

    def stub_gate(self, answer):
        def require(*args, **kwargs):
            self.asks.append((args, kwargs))
            if isinstance(answer, Exception):
                raise answer
            return answer
        drain.copy_gate.require = require

    def stub_wrapper(self, rc=0, stdout="POSTED comment conversation=1 part=p1"):
        def run(argv, **_kwargs):
            with open(argv[argv.index("--body-file") + 1], encoding="utf8") as f:
                self.runs.append({"argv": list(argv), "body": f.read()})
            return SimpleNamespace(returncode=rc, stdout=stdout, stderr="")
        drain.subprocess.run = run

    def test_a_body_the_gate_has_not_approved_never_reaches_the_wrapper(self):
        self.stub_wrapper()
        for answer in ({"result": "observed", "review": "rewrite"}, {"result": "pending"},
                       drain.copy_gate.CopyHeld("copy_review_refuse", "0" * 64)):
            with self.subTest(answer=str(answer)):
                self.stub_gate(answer)
                with self.assertRaises(drain.copy_gate.CopyHeld):
                    drain.post_reply("1", "hello", "late-reply", validate=True)
        self.assertEqual(self.runs, [])

    def test_the_reply_goes_through_the_wrapper_as_caroline_and_assigns_nobody(self):
        self.stub_gate({"result": "approved", "verdict_id": "ocv-0123456789abcdef"})
        self.stub_wrapper()
        got = drain.post_reply("42", "hello there", "late-reply")
        argv = self.runs[0]["argv"]
        self.assertEqual(argv[0], drain.OPS_WRITE)
        self.assertEqual(argv[1], "reply")
        self.assertEqual(argv[argv.index("--conversation") + 1], "42")
        self.assertEqual(argv[argv.index("--requested-by") + 1], drain.APPROVER)
        self.assertEqual(argv[argv.index("--approved-by") + 1], drain.APPROVER)
        self.assertIn("--customer-facing", argv)
        self.assertNotIn("--assignee", " ".join(argv))
        self.assertNotIn("snooze", " ".join(argv).lower())
        self.assertEqual(self.runs[0]["body"], "hello there")
        self.assertEqual(self.asks, [((drain.GATE_CAMPAIGN, "hello there"),
                                      {"copy": "late-reply", "message_type": "comment"})])
        self.assertEqual(got["verdict_id"], "ocv-0123456789abcdef")

    def test_a_part_is_authored_by_the_caroline_admin_and_a_close_is_a_close(self):
        def urlopen(req, timeout=None):
            if req.data:
                self.requests.append(json.loads(req.data.decode()))
            return Response({"state": "closed"})
        drain.urllib.request.urlopen = urlopen
        self.assertEqual(drain.close_thread("tok", "42"), "closed")
        self.assertEqual(self.requests, [{"message_type": "close", "type": "admin",
                                          "admin_id": drain.INTERCOM_ADMIN_ID}])

    def test_the_short_lines_are_the_bodies_the_reviewer_approved(self):
        self.assertEqual(drain.LINES["late-reply"],
                         "Sorry, we did not reply to this message when you sent it. If you still need help, reply "
                         "here and tell us what you need, and you will get an answer in this conversation.")
        self.assertEqual(drain.LINES["stale-close"],
                         "Your last message here was answered and the conversation has been quiet since, so we are "
                         "closing it. If you still need help, reply here at any time and it will open again.")


TRIAGE = os.path.join(ROOT, "scripts", "intercom-backlog", "triage.py")
tspec = importlib.util.spec_from_file_location("ib_triage", TRIAGE)
triage = importlib.util.module_from_spec(tspec)
sys.modules["ib_triage"] = triage
tspec.loader.exec_module(triage)


class TriageIdentityTests(unittest.TestCase):
    """Who the contact is comes from credit_review/identity_resolver.py, through triage.main() itself.

    The replica is a fake that answers each statement by what it reads; the verify ledger is a real,
    empty SQLite file. On 2026-11-14 triage's own users-only matcher called 20 mobile claimants
    "no account" and the drain told them to write from the address they were already signed in with."""

    PROFILE = "0f0e7a52-9b1c-4c6e-8a55-3d2f6b1c9a10"       # what the mobile app logs into Intercom with

    def run_triage(self, census_rows, *, users=(), claims=(), requests=(), claim_counts=(), users_by_id=()):
        seen = []

        def replica(sql, timeout=900):
            seen.append(sql)
            if "FROM postgresql_core.public.users" in sql:
                if "neptuneprofessionalid" in sql:
                    return [list(r) for r in users]
                asked = sql.split("users WHERE id IN (", 1)[1].split(")", 1)[0].split(",")
                have = {str(x) for x in users_by_id}
                return [[i.strip()] for i in asked if i.strip() in have]
            if "FROM postgresql_core.public.claiming WHERE CAST(profileid" in sql:
                return [list(r) for r in claims]
            if "team_users" in sql:
                return []
            if "credit_requests" in sql:
                return [list(r) for r in requests]
            if "public.claiming" in sql:
                return [list(r) for r in claim_counts]
            raise AssertionError("a replica statement this test does not know: " + sql[:90])

        tmp = tempfile.mkdtemp()
        src = os.path.join(tmp, "census.jsonl")
        with open(src, "w") as f:
            for r in census_rows:
                f.write(json.dumps(r) + "\n")
        ledger = os.path.join(tmp, "ledger.sqlite3")
        db = sqlite3.connect(ledger)
        db.execute("create table verify_messages (account_id text, day text, status text)")
        db.commit()
        db.close()
        old = triage.trino, triage.LEDGER, sys.argv
        triage.trino, triage.LEDGER, sys.argv = replica, ledger, ["triage.py", src]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                triage.main()
        finally:
            triage.trino, triage.LEDGER, sys.argv = old
        with open(src.replace(".jsonl", ".triage.jsonl")) as f:
            out = [json.loads(l) for l in f]
        return {str(r["id"]): r for r in out}, seen

    def contact(self, cid, external_id, topic="credit"):
        return {"id": cid, "external_id": external_id, "topic": topic, "band": "30-90d"}

    def test_a_mobile_contact_whose_intercom_id_is_a_claimed_profile_resolves_to_its_account(self):
        # no users row carries the profile id (it is not a professional id or an Auth0 subject): the only
        # tie is the account's own PROCESSED claim on that profile
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE)],
            claims=[(self.PROFILE, "77", "processed")],
            requests=[("77", "unverified", "0", "2")])
        row = got["1"]
        self.assertEqual((row["user_id"], row["matched_by"]), ("77", "presented_profile"))
        self.assertEqual(row["action"], "gate-team-review")
        self.assertEqual(row["credits"]["pending"], 2)

    def test_that_contact_is_not_sent_the_no_account_line(self):
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE)],
            claims=[(self.PROFILE, "77", "processed")],
            requests=[("77", "approved", "0", "3")])
        thread = drain.read_thread(conv("1"))
        listed, klass, line, _mode, _basis = drain.classify(got["1"], thread, facts(), NOW)
        self.assertEqual((listed, klass, line), ("send", "credit_all_decided", "credits-approved"))

    def test_a_represented_profile_resolves_too(self):
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE)],
            users=[("77", "pro-77", "auth0|abc", self.PROFILE)])
        self.assertEqual((got["1"]["user_id"], got["1"]["matched_by"]), ("77", "presented_profile"))

    def test_a_web_contact_still_resolves_by_professional_id_and_auth0_subject(self):
        got, _seen = self.run_triage(
            [self.contact("1", "pro-77"), self.contact("2", "abc")],
            users=[("77", "pro-77", "auth0|zzz", ""), ("78", "pro-78", "auth0|abc", "")])
        self.assertEqual((got["1"]["user_id"], got["1"]["matched_by"]), ("77", "professional_id"))
        self.assertEqual((got["2"]["user_id"], got["2"]["matched_by"]), ("78", "auth0_subject"))

    def test_a_pending_claim_on_the_profile_confers_nothing(self):
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE)],
            claims=[(self.PROFILE, "77", "pending")])
        self.assertEqual((got["1"]["user_id"], got["1"]["action"]), (None, "no-identity"))
        self.assertEqual(got["1"]["identity_why"], "no Muso account owns this external_id")

    def test_a_profile_two_accounts_hold_is_ambiguous_never_one_of_them(self):
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE)],
            claims=[(self.PROFILE, "77", "processed"), (self.PROFILE, "78", "processed")])
        self.assertEqual((got["1"]["user_id"], got["1"]["action"]), (None, "ambiguous-identity"))

    def test_another_accounts_reverted_claim_refuses_the_match(self):
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE)],
            claims=[(self.PROFILE, "77", "processed"), (self.PROFILE, "78", "reverted")])
        self.assertEqual((got["1"]["user_id"], got["1"]["action"]), (None, "ambiguous-identity"))
        self.assertIn("reverted", got["1"]["identity_why"])

    def test_a_contact_with_no_external_id_is_no_identity(self):
        got, _seen = self.run_triage([self.contact("1", "")])
        self.assertEqual((got["1"]["user_id"], got["1"]["action"]), (None, "no-identity"))

    def test_a_bare_account_number_still_resolves_to_that_account(self):
        # the users.id fallback: the resolver owns nothing here, and users 77 is the contact's own row
        got, _seen = self.run_triage(
            [self.contact("1", "77")],
            users=[("77", "pro-77", "auth0|abc", "")],
            users_by_id=["77"],
            requests=[("77", "unverified", "0", "2")])
        row = got["1"]
        self.assertEqual((row["user_id"], row["matched_by"]), ("77", "users_id"))
        self.assertEqual(row["identity_why"], "")
        self.assertEqual(row["action"], "gate-team-review")
        self.assertEqual(row["credits"]["pending"], 2)

    def test_the_resolver_wins_over_the_bare_account_number(self):
        # "77" is BOTH a profile account 77 holds a processed claim on and the users.id of account 99
        got, _seen = self.run_triage(
            [self.contact("1", "77")],
            users=[("99", "pro-99", "auth0|xyz", "")],
            claims=[("77", "77", "processed")],
            users_by_id=["77", "99"],
            requests=[("77", "unverified", "0", "1"), ("99", "approved", "0", "4")])
        row = got["1"]
        self.assertEqual((row["user_id"], row["matched_by"]), ("77", "presented_profile"))
        self.assertEqual(row["credits"]["pending"], 1)

    def test_the_bare_account_number_never_overrides_a_refusal(self):
        got, _seen = self.run_triage(
            [self.contact("1", "77")],
            users=[("77", "pro-77", "auth0|abc", "")],
            claims=[("77", "77", "processed"), ("77", "78", "processed")],
            users_by_id=["77"])
        self.assertEqual((got["1"]["user_id"], got["1"]["action"]), (None, "ambiguous-identity"))
        self.assertEqual(got["1"]["matched_by"], "")

    def test_a_bare_account_number_no_users_row_has_is_no_identity(self):
        got, _seen = self.run_triage(
            [self.contact("1", "77")],
            users=[("99", "pro-99", "auth0|xyz", "")],
            users_by_id=["99"])
        self.assertEqual((got["1"]["user_id"], got["1"]["action"]), (None, "no-identity"))
        self.assertEqual(got["1"]["identity_why"], "no Muso account owns this external_id")

    def test_a_legal_or_billing_topic_keeps_its_list_whoever_the_contact_is(self):
        got, _seen = self.run_triage(
            [self.contact("1", self.PROFILE, topic="legal"), self.contact("2", self.PROFILE, topic="billing")],
            claims=[(self.PROFILE, "77", "processed")])
        self.assertEqual((got["1"]["action"], got["2"]["action"]), ("captain-legal", "captain-billing"))


if __name__ == "__main__":
    unittest.main()
