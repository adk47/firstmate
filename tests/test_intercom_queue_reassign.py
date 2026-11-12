"""Tests for scripts/intercom-queue-reassign.py: clearing one person's open Intercom queue back
to the AI queue.

WHY (2026-11-11, intercom-no-human-assignment-k1): 581 conversations sat open on one person,
511 of them put there by the plugin, and every customer reply in them was dropped. The tool that
clears that queue writes to a live customer inbox, so these lock what it may never do: close a
conversation, send a customer-visible message, post as anyone but Caroline, move a thread a human
is entitled to keep, or write without a ledger row carrying the way back.

Stdlib unittest and an in-memory Intercom: no network, no pytest.
"""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("intercom_queue_reassign", ROOT / "scripts" / "intercom-queue-reassign.py")
qr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(qr)

PERSON = "111"
BOT = qr.INTERCOM_ADMIN_ID
NOW = 1_800_000_000
HANDOFF = "<p>I&#39;m pulling in a teammate to take this from here.</p>"
FAREWELL = (
    "<p>I\u2019m pulling in a teammate to take this from here. You\u2019ll hear from us in this "
    "conversation and by email. Reference: 86abc123.</p>"
)


def part(ptype, author_type, author_id, at, body=None, to=None):
    p = {"part_type": ptype, "author": {"type": author_type, "id": author_id}, "created_at": at, "body": body}
    if to is not None:
        p["assigned_to"] = {"type": "admin", "id": to}
    return p


def conv(cid, parts, admin=PERSON, state="open", tags=(), contacts=("c" * 24,), team=None, source=None):
    return {
        "id": cid,
        "state": state,
        "created_at": NOW - 90 * 86400,
        "admin_assignee_id": int(admin) if admin else None,
        "team_assignee_id": team,
        "tags": {"tags": [{"name": t} for t in tags]},
        "contacts": {"contacts": [{"id": c} for c in contacts]},
        "source": source or {"author": {"type": "user", "id": "u1"}},
        "conversation_parts": {"conversation_parts": parts, "total_count": len(parts)},
    }


def guard_blocked(cid):
    return conv(
        cid,
        [
            part("comment", "user", "u1", NOW - 5000, "where is my request"),
            part("comment", "admin", BOT, NOW - 4000, HANDOFF),
            part("assignment", "admin", BOT, NOW - 3999, to=PERSON),
        ],
        tags=("ai:output-guard",),
    )


def escalated(cid, extra=()):
    return conv(
        cid,
        [
            part("comment", "user", "u1", NOW - 5000, "I will sue"),
            part("comment", "admin", BOT, NOW - 4000, FAREWELL),
            part("assignment", "admin", BOT, NOW - 3999, to=PERSON),
            *extra,
        ],
    )


class FakeApi(qr.Api):
    """An in-memory Intercom. Every write is recorded; an assignment really moves the thread."""

    def __init__(self, convs, tickets=None, fail_assign=()):
        super().__init__("tok", "ck", sleep=lambda _s: None)
        self.convs = {c["id"]: c for c in convs}
        self.tickets = tickets or {}
        self.fail_assign = set(fail_assign)
        self.unreadable = set()
        self.writes = []

    def request(self, method, url, headers, body):
        if url.startswith(qr.CLICKUP_API):
            tid = url.rsplit("/", 1)[1]
            if tid not in self.tickets:
                raise urllib.error.HTTPError(url, 404, "nf", None, None)
            return {"description": self.tickets[tid]}
        path = url[len(qr.INTERCOM_API):]
        if path == "/conversations/search":
            if body["query"].get("field") == "updated_at":  # verify: everything touched in the window
                return {"conversations": [{"id": c["id"]} for c in self.convs.values()], "pages": {}}
            want = {v["field"]: v["value"] for v in body["query"]["value"]}
            hits = [
                {"id": c["id"]}
                for c in self.convs.values()
                if str(c["admin_assignee_id"] or "") == want["admin_assignee_id"] and c["state"] == want["state"]
            ]
            return {"conversations": hits, "pages": {}}
        if path == "/admins":
            return {"admins": [{"id": PERSON, "name": "Pat Person"}]}
        cid = path.split("/")[2].split("?")[0]
        if method == "GET":
            if cid in self.unreadable:
                raise urllib.error.HTTPError(url, 404, "nf", None, None)
            return self.convs[cid]
        self.writes.append((path, body))
        assert headers["Intercom-Version"] == qr.INTERCOM_VERSION
        if path.endswith("/parts"):
            if cid in self.fail_assign:
                raise urllib.error.HTTPError(url, 403, "no", None, None)
            c = self.convs[cid]
            if body["type"] == "team":
                c["team_assignee_id"] = int(body["assignee_id"])
            else:
                c["admin_assignee_id"] = int(body["assignee_id"]) or None
        return {}


def plan(api, restricted=frozenset()):
    return qr.build_plan(api, PERSON, restricted, workers=1, now_s=NOW)


def run_apply(api, rows, ledger, cap=50, team=""):
    return qr.apply_plan(api, rows, PERSON, "Pat Person", ledger, "run-1", cap, team, pace_s=0)


class ClassifyTests(unittest.TestCase):
    def test_guard_blocked_thread_goes_to_the_ai_queue(self):
        (row,) = plan(FakeApi([guard_blocked("1")]))
        self.assertEqual((row["action"], row["mechanism"]), ("reassign", "output_guard"))
        self.assertFalse(row["human_replied"])

    def test_escalation_for_a_human_seat_reason_is_left(self):
        api = FakeApi([escalated("2")], tickets={"86abc123": '{"escalation_reason": "legal_threat"}'})
        (row,) = plan(api)
        self.assertEqual((row["action"], row["reason"]), ("leave", "left_explicit_escalation"))
        self.assertEqual(row["escalation_reason"], "legal_threat")

    def test_escalation_for_a_turn_cap_goes_to_the_ai_queue(self):
        api = FakeApi([escalated("3")], tickets={"86abc123": '{"escalation_reason": "turn_count_cap"}'})
        (row,) = plan(api)
        self.assertEqual((row["action"], row["mechanism"]), ("reassign", "risk_escalation"))

    def test_escalation_whose_reason_cannot_be_read_is_left_not_assumed_safe(self):
        (row,) = plan(FakeApi([escalated("4")]))  # ticket 404s
        self.assertEqual((row["action"], row["reason"]), ("leave", "left_escalation_unread"))

    def test_snoozed_and_restricted_are_left_with_their_reason(self):
        snoozed = guard_blocked("5")
        snoozed["state"] = "snoozed"
        restricted = guard_blocked("6")
        restricted["contacts"]["contacts"] = [{"id": "a" * 24}]
        noted = guard_blocked("7")
        noted["conversation_parts"]["conversation_parts"].append(
            part("note", "admin", BOT, NOW - 100, "account restored, credits under proof review - escalate")
        )
        rows = {r["id"]: r for r in plan(FakeApi([snoozed, restricted, noted]), frozenset({"a" * 24}))}
        self.assertEqual(rows["5"]["reason"], "left_snoozed")
        self.assertEqual(rows["6"]["reason"], "left_restricted")
        self.assertEqual(rows["7"]["reason"], "left_restricted")

    def test_a_reply_by_the_person_marks_the_thread_for_a_resume_note(self):
        c = guard_blocked("8")
        c["conversation_parts"]["conversation_parts"].append(part("comment", "admin", PERSON, NOW - 86400, "on it"))
        (row,) = plan(FakeApi([c]))
        self.assertTrue(row["human_replied"] and row["mid_reply_recent"])
        old = guard_blocked("9")
        old["conversation_parts"]["conversation_parts"].append(part("comment", "admin", PERSON, NOW - 40 * 86400, "on it"))
        (row,) = plan(FakeApi([old]))
        self.assertTrue(row["human_replied"])
        self.assertFalse(row["mid_reply_recent"])

    def test_mechanisms_are_named(self):
        self_assigned = conv("10", [part("assignment", "admin", PERSON, NOW - 10, to=PERSON)])
        bulk = conv("11", [part("bulk_reassignment", "admin", PERSON, NOW - 10, to=PERSON)])
        operator = conv("12", [part("message_assignment", "bot", "4359478", NOW - 10, to=PERSON)])
        none = conv("13", [part("comment", "user", "u1", NOW - 10, "hi")])
        rows = {r["id"]: r["mechanism"] for r in plan(FakeApi([self_assigned, bulk, operator, none]))}
        self.assertEqual(
            rows,
            {"10": "self_assigned", "11": "self_bulk_reassigned", "12": "intercom_operator_rule", "13": "no_assignment_part"},
        )

    def test_an_unreadable_conversation_is_reported_never_moved(self):
        api = FakeApi([guard_blocked("14")])
        api.unreadable.add("14")
        (row,) = plan(api)
        self.assertEqual((row["action"], row["reason"]), ("leave", "left_unreadable"))


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Path(self.tmp.name) / "run.jsonl"

    def ledger_rows(self):
        return [json.loads(line) for line in self.ledger.read_text().splitlines()]

    def test_apply_moves_to_caroline_and_writes_the_way_back_before_the_write(self):
        api = FakeApi([guard_blocked("1")])
        stats = run_apply(api, plan(api), self.ledger)
        self.assertEqual((stats["moved"], stats["failed"], stats["notes"], stats["closed_by_this_run"]), (1, 0, 0, 0))
        self.assertEqual(api.convs["1"]["admin_assignee_id"], int(BOT))
        self.assertEqual(api.convs["1"]["state"], "open")
        rows = self.ledger_rows()
        self.assertEqual([r["phase"] for r in rows], ["intent", "done"])
        self.assertEqual(rows[0]["before"]["admin_assignee_id"], PERSON)
        self.assertTrue(rows[1]["verified"])

    def test_every_write_is_an_assignment_or_an_internal_note_as_caroline(self):
        replied = guard_blocked("2")
        replied["conversation_parts"]["conversation_parts"].append(part("comment", "admin", PERSON, NOW - 86400, "on it"))
        api = FakeApi([guard_blocked("1"), replied])
        stats = run_apply(api, plan(api), self.ledger)
        self.assertEqual((stats["moved"], stats["notes"]), (2, 1))
        for path, body in api.writes:
            self.assertEqual(body["admin_id"], BOT)
            self.assertIn(body["message_type"], ("assignment", "note"))
            self.assertNotIn(body["message_type"], ("comment", "close", "snoozed", "open"))
        notes = [b for p, b in api.writes if b["message_type"] == "note"]
        self.assertEqual(len(notes), 1)
        self.assertIn("not visible to the customer", notes[0]["body"])
        self.assertIn("Pat Person", notes[0]["body"])

    def test_left_rows_are_never_written_to(self):
        api = FakeApi([escalated("3")], tickets={"86abc123": '{"escalation_reason": "legal_threat"}'})
        stats = run_apply(api, plan(api), self.ledger)
        self.assertEqual(stats["moved"], 0)
        self.assertEqual(api.writes, [])
        self.assertEqual(api.convs["3"]["admin_assignee_id"], int(PERSON))

    def test_explicit_escalations_move_to_the_team_queue_only_when_asked(self):
        api = FakeApi([escalated("3")], tickets={"86abc123": '{"escalation_reason": "legal_threat"}'})
        stats = run_apply(api, plan(api), self.ledger, team="777")
        self.assertEqual(stats["moved_to_escalation_team"], 1)
        self.assertEqual([(b["type"], b["assignee_id"]) for _p, b in api.writes], [("admin", "0"), ("team", "777")])
        self.assertIsNone(api.convs["3"]["admin_assignee_id"])
        self.assertEqual(api.convs["3"]["team_assignee_id"], 777)

    def test_over_the_cap_refuses_before_any_write(self):
        api = FakeApi([guard_blocked(str(i)) for i in range(5)])
        with self.assertRaises(SystemExit):
            run_apply(api, plan(api), self.ledger, cap=4)
        self.assertEqual(api.writes, [])
        self.assertFalse(self.ledger.exists())

    def test_a_failed_assignment_is_counted_and_ledgered_and_the_run_goes_on(self):
        api = FakeApi([guard_blocked("1"), guard_blocked("2")], fail_assign={"1"})
        stats = run_apply(api, plan(api), self.ledger)
        self.assertEqual((stats["moved"], stats["failed"]), (1, 1))
        self.assertEqual(api.convs["1"]["admin_assignee_id"], int(PERSON))
        self.assertIn("error", [r["phase"] for r in self.ledger_rows() if r["id"] == "1"])

    def test_revert_restores_the_previous_assignee(self):
        api = FakeApi([guard_blocked("1"), guard_blocked("2")])
        run_apply(api, plan(api), self.ledger)
        api.convs["2"]["admin_assignee_id"] = 999  # somebody took it since
        stats = qr.revert(api, self.ledger, pace_s=0)
        self.assertEqual((stats["reverted"], stats["left_moved_since"]), (1, 1))
        self.assertEqual(api.convs["1"]["admin_assignee_id"], int(PERSON))
        self.assertEqual(api.convs["2"]["admin_assignee_id"], 999)


class VerifyTests(unittest.TestCase):
    """The 24-hour check: zero means MEASURED zero, and a person resuming a thread is not a default."""

    def recent(self, cid, author, admin=PERSON):
        import time as _t

        return conv(cid, [part("assignment", "admin", author, int(_t.time()) - 600, to=PERSON)], admin=admin)

    def test_an_assignment_by_the_plugin_is_not_zero(self):
        api = FakeApi([self.recent("1", BOT)])
        out = qr.verify(api, PERSON, 24, workers=1)
        self.assertEqual((out["verdict"], out["assignments_not_self"], out["by_author"]), ("NOT_ZERO", 1, {"plugin_or_caroline": 1}))
        self.assertEqual(out["open_on_admin_now"], 1)

    def test_a_person_assigning_to_themself_is_the_resume_path_and_stays_zero(self):
        api = FakeApi([self.recent("1", PERSON)])
        out = qr.verify(api, PERSON, 24, workers=1)
        self.assertEqual((out["verdict"], out["assignments"], out["assignments_not_self"]), ("ZERO", 1, 0))

    def test_an_old_assignment_is_outside_the_window(self):
        api = FakeApi([conv("1", [part("assignment", "admin", BOT, 1_700_000_000, to=PERSON)])])
        self.assertEqual(qr.verify(api, PERSON, 24, workers=1)["assignments"], 0)

    def test_an_unreadable_conversation_is_unmeasured_never_zero(self):
        api = FakeApi([self.recent("1", PERSON), self.recent("2", BOT)])
        api.unreadable.add("2")
        out = qr.verify(api, PERSON, 24, workers=1)
        self.assertEqual((out["verdict"], out["unreadable"]), ("UNMEASURED", 1))

    def test_verify_writes_nothing(self):
        api = FakeApi([self.recent("1", BOT)])
        qr.verify(api, PERSON, 24, workers=1)
        self.assertEqual(api.writes, [])


class SourceTests(unittest.TestCase):
    """What the file may contain at all: a write this tool does not make cannot be added quietly."""

    def setUp(self):
        self.src = (ROOT / "scripts" / "intercom-queue-reassign.py").read_text(encoding="utf8")

    def test_no_close_snooze_or_customer_comment_in_the_source(self):
        for forbidden in ('"message_type": "close"', '"message_type": "comment"', '"message_type": "snoozed"', "/tags"):
            self.assertNotIn(forbidden, self.src)

    def test_the_posting_identity_is_pinned_to_caroline(self):
        self.assertIn('INTERCOM_ADMIN_ID = "5763097"', self.src)

    def test_the_source_admin_is_an_argument_never_a_literal(self):
        # the person whose queue is cleared is named on the command line, so the tool is not
        # "the Jan script" and the reply-identity gate has nothing to mistake for a posting id
        self.assertNotIn("5465657", self.src)

    def test_curly_quotes_fold_so_the_hand_off_line_matches(self):
        self.assertIn(qr.HANDOFF_LINE, qr.text_of(FAREWELL))


if __name__ == "__main__":
    unittest.main()
