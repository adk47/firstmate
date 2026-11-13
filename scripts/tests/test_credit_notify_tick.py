"""notify-tick (credit_review/notify_tick.py): the class precedent_v1_untold, the subtraction of users already
tried, paid-first order, and a dry run of its list that sends nothing. Hermetic: fake replica, fake route,
in-memory ledgers. One assertion per line."""
from __future__ import annotations

import json
import sqlite3
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import decision_told as dt  # noqa: E402
from credit_review import notify_tick as nt  # noqa: E402

NOW = datetime(2026, 11, 13, 20, 0, 0, 914000, tzinfo=timezone.utc)
#: the committed class statement's sha256[:12]. A change to CLASS_SQL changes who is in the class: update this
#: value in the same commit, on purpose, never to make the test pass.
CLASS_SHA = "6b9db46561a7"


def rid(n: int) -> str:
    return f"{n:08x}-1111-4111-8111-111111111111"


def row(user: int, n: int, paid: bool = False, status: str = "approved") -> list[str]:
    """One class row as the replica returns it: user id, request id, status, updatedat, paid 0/1."""
    return [str(user), rid(n), status, "2026-11-01 10:00:00.000", "1" if paid else "0"]


#: ids and paid flags disagree on purpose: the two paid users have the HIGHEST ids, so id order is not paid order
CLASS_ROWS = [row(10, 1), row(10, 2), row(20, 3), row(30, 4), row(80, 5, paid=True), row(90, 6),
              row(90, 7, paid=True), row(90, 8)]


def replica(class_rows, profiles=None):
    """The class statement answers with `class_rows`; decision_told's re-read answers per request id."""
    seen: list[str] = []

    def q(sql: str) -> list[list[str]]:
        seen.append(sql)
        if sql == nt.CLASS_SQL:
            return [list(r) for r in class_rows]
        return [[r[1], r[2], "false", "false", "w", (profiles or {}).get(r[1], f"p{r[0]}")]
                for r in class_rows if f"'{r[1]}'" in sql]
    q.seen = seen
    return q


def ledger() -> sqlite3.Connection:
    db = sqlite3.connect(":memory:", isolation_level=None)
    dt.ensure_table(db)
    return db


def tried(db: sqlite3.Connection, user: int, mode: str, outcome: str) -> None:
    db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, outcome) "
               "VALUES ('r', '2026-11-11T00:00:00Z', ?, 'w|p', 'decision-approved', '[]', ?, ?)", (user, mode, outcome))


def notes_db() -> sqlite3.Connection:
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, status TEXT, request_ids_json TEXT, day TEXT, "
               "sent_at TEXT)")
    return db


class Route:
    """Core's status route: an affirmative report for whatever it is asked, and a record of every body it got."""

    def __init__(self):
        self.calls: list[dict] = []

    def __call__(self, b):
        self.calls.append(b)
        return {"dryRun": not b["apply"], "userId": str(b["userId"]), "copyRef": b["copyRef"], "blockedBy": [],
                "group": {"subjects": list(b["subjectIds"])}, "sent": bool(b["apply"]),
                "outcome": "sent" if b["apply"] else "would_send"}


def ids(users) -> list[int]:
    return [int(u["user_id"]) for u in users]


class ClassDefinition(unittest.TestCase):
    def test_the_statement_is_the_committed_one(self):
        # Reviewed-statement contract, not a behavior test: the class's membership cannot be executed hermetically
        # (Trino syntax over the core replica), so this pin proves no predicate. It makes a change to who is in the
        # class a deliberate edit in the same commit.
        self.assertEqual(nt.query_sha(), CLASS_SHA)

    def test_the_list_is_built_from_the_class_statement_once(self):
        q = replica(CLASS_ROWS)
        nt.build_list(q, NOW)
        self.assertEqual(q.seen, [nt.CLASS_SQL])

    def test_the_header_names_the_class(self):
        self.assertEqual(nt.build_list(replica(CLASS_ROWS), NOW)["class"], "precedent_v1_untold")

    def test_the_header_carries_the_statement_sha(self):
        self.assertEqual(nt.build_list(replica(CLASS_ROWS), NOW)["query_sha"], CLASS_SHA)

    def test_the_header_counts_users(self):
        self.assertEqual(nt.build_list(replica(CLASS_ROWS), NOW)["counts"]["users"], 5)

    def test_the_header_counts_requests(self):
        self.assertEqual(nt.build_list(replica(CLASS_ROWS), NOW)["counts"]["requests"], 8)

    def test_the_header_carries_the_time_it_was_built(self):
        self.assertEqual(nt.build_list(replica(CLASS_ROWS), NOW)["generated_at"], "2026-11-13T20:00:00.914Z")

    def test_the_same_rows_build_the_same_users(self):
        a = nt.build_list(replica(CLASS_ROWS), NOW)["users"]
        self.assertEqual(nt.build_list(replica(CLASS_ROWS), NOW)["users"], a)

    def test_row_order_does_not_change_the_users(self):
        a = nt.build_list(replica(CLASS_ROWS), NOW)["users"]
        self.assertEqual(nt.build_list(replica(list(reversed(CLASS_ROWS))), NOW)["users"], a)

    def test_a_user_carries_every_request_of_theirs(self):
        users = {u["user_id"]: u for u in nt.build_list(replica(CLASS_ROWS), NOW)["users"]}
        self.assertEqual([f[0] for f in users[90]["facts"]], [rid(6), rid(7), rid(8)])

    def test_the_list_is_one_decision_told_reads(self):
        raw = json.dumps(nt.build_list(replica(CLASS_ROWS), NOW)).encode()
        header, users = dt.load_list(raw, dt.file_sha(raw))
        self.assertEqual(ids(users), [10, 20, 30, 80, 90])

    def test_an_empty_class_is_an_empty_list(self):
        self.assertEqual(nt.build_list(replica([]), NOW)["counts"], {"users": 0, "requests": 0})

    def test_an_empty_class_is_refused_by_the_loader(self):
        raw = json.dumps(nt.build_list(replica([]), NOW)).encode()
        with self.assertRaises(dt.DecisionToldError):
            dt.load_list(raw, dt.file_sha(raw))

    def test_a_row_of_the_wrong_width_refuses_the_build(self):
        with self.assertRaises(nt.NotifyTickError):
            nt.build_list(lambda sql: [row(10, 1)[:4]], NOW)

    def test_a_row_with_no_user_id_refuses_the_build(self):
        with self.assertRaises(nt.NotifyTickError):
            nt.build_list(lambda sql: [["", rid(1), "approved", "t", "0"]], NOW)

    def test_a_row_whose_request_id_is_not_a_uuid_refuses_the_build(self):
        with self.assertRaises(nt.NotifyTickError):
            nt.build_list(lambda sql: [["10", "1' OR '1'='1", "approved", "t", "0"]], NOW)

    def test_a_row_whose_paid_flag_is_unreadable_refuses_the_build(self):
        with self.assertRaises(nt.NotifyTickError):
            nt.build_list(lambda sql: [["10", rid(1), "approved", "t", ""]], NOW)

    def test_a_replica_that_cannot_answer_is_not_an_empty_class(self):
        def down(sql):
            raise RuntimeError("trino rc=1")
        with self.assertRaises(RuntimeError):
            nt.build_list(down, NOW)


class SubtractsTheUsersAlreadyTried(unittest.TestCase):
    def setUp(self):
        self.doc = nt.build_list(replica(CLASS_ROWS), NOW)
        self.db = ledger()

    def left(self) -> list[int]:
        return sorted(ids(nt.select(self.doc, nt.already_told(self.db))["users"]))

    def test_nobody_tried_leaves_the_whole_class(self):
        self.assertEqual(self.left(), [10, 20, 30, 80, 90])

    def test_a_sent_user_is_taken_out(self):
        tried(self.db, 20, "apply", "attempt")
        tried(self.db, 20, "apply", "sent")
        self.assertEqual(self.left(), [10, 30, 80, 90])

    def test_a_user_whose_send_errored_is_taken_out(self):
        tried(self.db, 30, "apply", "attempt")
        tried(self.db, 30, "apply", "error")
        self.assertEqual(self.left(), [10, 20, 80, 90])

    def test_a_user_with_only_a_reserved_attempt_is_taken_out(self):
        tried(self.db, 10, "apply", "attempt")
        self.assertEqual(self.left(), [20, 30, 80, 90])

    def test_a_dry_run_takes_nobody_out(self):
        tried(self.db, 20, "dry", "dry_ok")
        tried(self.db, 30, "dry", "dry_refused")
        self.assertEqual(self.left(), [10, 20, 30, 80, 90])

    def test_a_never_automated_user_is_taken_out(self):
        doc = nt.build_list(replica(CLASS_ROWS + [row(15, 9, paid=True)]), NOW)
        self.assertNotIn(15, ids(nt.select(doc, set())["users"]))

    def test_the_never_automated_count_is_one_when_the_user_is_in_the_class(self):
        doc = nt.build_list(replica(CLASS_ROWS + [row(15, 9, paid=True)]), NOW)
        self.assertEqual(nt.select(doc, set())["counts"]["never_automated_users"], 1)

    def test_the_never_automated_count_is_zero_when_the_user_is_not_in_the_class(self):
        self.assertEqual(nt.select(self.doc, set())["counts"]["never_automated_users"], 0)

    def test_the_header_identity_holds_with_nobody_tried(self):
        counts = nt.select(self.doc, set())["counts"]
        self.assertEqual(counts["users"],
                         counts["untold_users"] + counts["already_tried_users"] + counts["never_automated_users"])

    def test_the_header_identity_holds_with_some_tried(self):
        tried(self.db, 20, "apply", "sent")
        tried(self.db, 90, "apply", "error")
        counts = nt.select(self.doc, nt.already_told(self.db))["counts"]
        self.assertEqual(counts["users"],
                         counts["untold_users"] + counts["already_tried_users"] + counts["never_automated_users"])

    def test_the_header_identity_holds_with_the_never_automated_user_tried(self):
        doc = nt.build_list(replica(CLASS_ROWS + [row(15, 9, paid=True)]), NOW)
        tried(self.db, 15, "apply", "sent")
        tried(self.db, 20, "apply", "sent")
        counts = nt.select(doc, nt.already_told(self.db))["counts"]
        self.assertEqual(counts["users"],
                         counts["untold_users"] + counts["already_tried_users"] + counts["never_automated_users"])

    def test_the_never_automated_user_is_counted_once_as_never_automated(self):
        doc = nt.build_list(replica(CLASS_ROWS + [row(15, 9, paid=True)]), NOW)
        tried(self.db, 15, "apply", "sent")
        counts = nt.select(doc, nt.already_told(self.db))["counts"]
        self.assertEqual(counts["already_tried_users"], 0)

    def test_the_selected_list_with_the_never_automated_user_still_loads_through_decision_told(self):
        doc = nt.build_list(replica(CLASS_ROWS + [row(15, 9, paid=True)]), NOW)
        raw = json.dumps(nt.select(doc, set())).encode()
        _, users = dt.load_list(raw, dt.file_sha(raw))
        self.assertEqual(ids(users), [80, 90, 10, 20, 30])

    def test_the_class_user_count_survives_the_subtraction(self):
        tried(self.db, 20, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["users"], 5)

    def test_the_class_request_count_survives_the_subtraction(self):
        tried(self.db, 20, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["requests"], 8)

    def test_the_untold_user_count_is_what_is_left(self):
        tried(self.db, 20, "apply", "sent")
        tried(self.db, 90, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["untold_users"], 3)

    def test_the_untold_request_count_is_what_is_left(self):
        tried(self.db, 20, "apply", "sent")
        tried(self.db, 90, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["untold_requests"], 4)

    def test_the_untold_paid_count_is_what_is_left(self):
        tried(self.db, 90, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["untold_paid_users"], 1)

    def test_the_tried_count_names_only_users_in_the_class(self):
        tried(self.db, 20, "apply", "sent")
        tried(self.db, 777, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["already_tried_users"], 1)

    def test_everyone_tried_leaves_nobody(self):
        for user in (10, 20, 30, 80, 90):
            tried(self.db, user, "apply", "sent")
        self.assertEqual(self.left(), [])

    def test_everyone_tried_still_carries_no_untold_users(self):
        for user in (10, 20, 30, 80, 90):
            tried(self.db, user, "apply", "sent")
        self.assertEqual(nt.select(self.doc, nt.already_told(self.db))["counts"]["untold_users"], 0)

    def test_an_empty_selection_is_refused_by_the_loader(self):
        for user in (10, 20, 30, 80, 90):
            tried(self.db, user, "apply", "sent")
        raw = json.dumps(nt.select(self.doc, nt.already_told(self.db))).encode()
        with self.assertRaises(dt.DecisionToldError):
            dt.load_list(raw, dt.file_sha(raw))

    def test_the_subtraction_does_not_change_the_list_it_was_given(self):
        tried(self.db, 20, "apply", "sent")
        nt.select(self.doc, nt.already_told(self.db))
        self.assertEqual(ids(self.doc["users"]), [10, 20, 30, 80, 90])

    def test_a_ledger_with_no_table_is_not_nobody_told(self):
        with self.assertRaises(nt.NotifyTickError):
            nt.already_told(sqlite3.connect(":memory:"))

    def test_reading_who_was_tried_writes_nothing(self):
        tried(self.db, 20, "apply", "sent")
        before = self.db.total_changes
        nt.already_told(self.db)
        self.assertEqual(self.db.total_changes, before)


class PaidFirst(unittest.TestCase):
    def setUp(self):
        self.users = nt.select(nt.build_list(replica(CLASS_ROWS), NOW), set())["users"]

    def test_paid_users_come_before_unpaid_ones_with_lower_ids(self):
        self.assertEqual(ids(self.users), [80, 90, 10, 20, 30])

    def test_the_list_before_selection_is_in_id_order(self):
        self.assertEqual(ids(nt.build_list(replica(CLASS_ROWS), NOW)["users"]), [10, 20, 30, 80, 90])

    def test_every_paid_user_is_ahead_of_every_unpaid_user(self):
        flags = [u["paid"] for u in self.users]
        self.assertEqual(flags, sorted(flags, reverse=True))

    def test_one_paid_workspace_among_a_users_requests_makes_the_user_paid(self):
        self.assertTrue({u["user_id"]: u["paid"] for u in self.users}[90])

    def test_a_user_with_no_paid_workspace_is_not_paid(self):
        self.assertFalse({u["user_id"]: u["paid"] for u in self.users}[10])

    def test_the_paid_flag_is_a_real_boolean_in_the_list(self):
        self.assertIs(self.users[0]["paid"], True)

    def test_decision_told_keeps_the_paid_users_first(self):
        q = replica(CLASS_ROWS)
        raw = json.dumps(nt.select(nt.build_list(q, NOW), set())).encode()
        _, users = dt.load_list(raw, dt.file_sha(raw))
        plans = dt.plan(users, dt.core_rows(q, dt._ids(users)), dt.status_notes(notes_db(), dt._ids(users)), {}, NOW)
        self.assertEqual([(p.user_id, p.paid) for p in plans],
                         [(80, True), (90, True), (10, False), (20, False), (30, False)])


class DryRunSendsNothing(unittest.TestCase):
    """The list this module builds, taken through decision_told's own dry run: the route is only ever asked with
    apply false, and the ledger gains dry rows only."""

    def setUp(self):
        q = replica(CLASS_ROWS)
        self.db = ledger()
        raw = json.dumps(nt.select(nt.build_list(q, NOW), nt.already_told(self.db))).encode()
        _, users = dt.load_list(raw, dt.file_sha(raw))
        plans = dt.plan(users, dt.core_rows(q, dt._ids(users)), dt.status_notes(notes_db(), dt._ids(users)),
                        dt.attempts(self.db), NOW)
        self.route = Route()
        self.out = dt.run(self.db, plans, self.route, run_id="dry-1", now=NOW, channel="live", apply=False, limit=25,
                          kill_file="/nonexistent/kill")

    def count(self, where: str) -> int:
        return self.db.execute(f"SELECT count(*) FROM decision_told WHERE {where}").fetchone()[0]

    def test_the_run_reports_itself_dry(self):
        self.assertEqual(self.out["mode"], "dry")

    def test_every_user_was_asked_about(self):
        self.assertEqual(sorted(b["userId"] for b in self.route.calls), [10, 20, 30, 80, 90])

    def test_the_route_was_never_asked_to_send(self):
        self.assertEqual([b for b in self.route.calls if b["apply"] is not False], [])

    def test_the_ledger_has_no_live_row(self):
        self.assertEqual(self.count("mode = 'apply'"), 0)

    def test_the_ledger_has_no_sent_row(self):
        self.assertEqual(self.count("outcome = 'sent'"), 0)

    def test_the_ledger_has_no_reserved_attempt(self):
        self.assertEqual(self.count("outcome = 'attempt'"), 0)

    def test_the_ledger_has_one_dry_row_per_user(self):
        self.assertEqual(self.count("mode = 'dry' AND outcome = 'dry_ok'"), 5)

    def test_every_row_is_a_dry_row(self):
        self.assertEqual(self.count("mode <> 'dry'"), 0)

    def test_a_dry_run_leaves_everyone_untold(self):
        self.assertEqual(nt.already_told(self.db), set())

    def test_the_next_list_still_names_everyone(self):
        doc = nt.select(nt.build_list(replica(CLASS_ROWS), NOW), nt.already_told(self.db))
        self.assertEqual(doc["counts"]["untold_users"], 5)

    def test_the_dry_run_asked_paid_users_first(self):
        self.assertEqual([b["userId"] for b in self.route.calls][:2], [80, 90])


if __name__ == "__main__":
    unittest.main()
