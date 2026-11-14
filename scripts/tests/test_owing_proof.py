"""credit_review/owing_proof.py: the audience for the send-locked S1 line credit-hold-status (card L14a). Users who
owe proof (U / H2 / H1, the steward's CLASS_SQL) AND were never told (no ledger note, no proofRequest marker); the
rows they owe on; at-risk paid first, then paid, then free, oldest first; inputs fail closed."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import owing_proof as op  # noqa: E402

#        user, request, status, created, paid, review_fired, proofRequest, proof_required
ROWS = [["1", "u1", "user_verification_needed", "2026-09-01", "0", "0", "0", "0"],   # free U, never told
        ["2", "h2", "unverified", "2026-08-01", "1", "1", "0", "0"],                  # paid H2, never told
        ["2", "ok", "processing", "2026-08-02", "1", "0", "0", "0"],                  #   (not owed: not named)
        ["3", "a3", "unverified", "2026-10-01", "1", "0", "0", "0"],                  # paid held account (H1)
        ["4", "t4", "user_verification_needed", "2026-07-01", "1", "0", "0", "0"],    # paid U but told by the ledger
        ["5", "m5", "user_verification_needed", "2026-07-01", "0", "0", "1", "0"],    # proofRequest marker: told
        ["6", "n6", "unverified", "2026-07-01", "1", "0", "0", "0"],                  # owes nothing: not listed
        ["7", "r7", "user_verification_needed", "2026-10-02", "1", "0", "0", "0"]]    # paid U, at-risk


def q(rows, statuses=None, seen=None):
    """A replica fake: the status guard is answered with the statuses in the table (default: the ones in `rows`), every
    other statement with `rows`. `seen` collects the SQL in the order it ran."""
    def run(sql):
        if seen is not None:
            seen.append(sql)
        if sql == op.STATUS_GUARD_SQL:
            return [[st] for st in (sorted({r[2] for r in rows}) if statuses is None else statuses)]
        return [list(r) for r in rows]
    return run


class OwingProofTest(unittest.TestCase):
    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE verify_messages (account_id TEXT, status TEXT, campaign TEXT DEFAULT 'uvn-status', "
                   "request_ids_json TEXT DEFAULT '[]')")
        db.execute("CREATE TABLE verify_refusal_holds (user_id TEXT, reason TEXT, flagged_at TEXT)")
        db.execute("INSERT INTO verify_messages (account_id, status, request_ids_json) VALUES ('4', 'sent', '[\"t4\"]'), ('1', 'refused', '[\"u1\"]')")   # a refusal is not "told"
        db.execute("INSERT INTO verify_refusal_holds VALUES ('3', 'account-hold', 'x')")
        db.commit()
        self.holds = str(d / "holds.jsonl"); Path(self.holds).write_text("")
        self.risk = str(d / "risk.csv")
        Path(self.risk).write_text("userid,teamid,churn_signal\n7,t,past_due\n2,t,\n")
        self.d = d

    def build(self, **kw):
        return op.build(**{"query": q(ROWS), "ledger_path": self.ledger,
                           "holds_path": self.holds, "at_risk_path": self.risk, **kw})

    def test_audience_classes_never_told_and_order(self):
        res = self.build()
        got = [(u["user_id"], u["class"], u["request_ids"], u["paid"], u["at_risk"]) for u in res["users"]]
        self.assertEqual(got, [("7", "uvn", ["r7"], True, True),             # paid at-risk first
                               ("2", "review_hold", ["h2"], True, False),    # then paid, oldest first
                               ("3", "account_hold", ["a3"], True, False),
                               ("1", "uvn", ["u1"], False, False)])          # then free
        c = res["counts"]
        self.assertEqual((c["skip_already_told_uvn"], c["list_paid_at_risk"], c["at_risk_source"]), (2, 1, "read"))
        self.assertTrue(all(u["skip"] is None for u in res["users"]))

    def test_without_the_at_risk_file_paid_still_lead(self):
        res = self.build(at_risk_path=str(self.d / "none.csv"))
        self.assertEqual([u["user_id"] for u in res["users"]], ["2", "3", "7", "1"])
        self.assertEqual(res["counts"]["at_risk_source"], "missing")

    def test_inputs_fail_closed(self):
        for kw in ({"query": q([["1", "x", "unverified", "d", "1", "maybe", "0", "0"]])},
                   {"query": q([["1", "x", "unverified", "d", "1", "0", "0", "yes"]])},
                   {"ledger_path": str(self.d / "nodir" / "l.sqlite3")}, {"holds_path": str(self.d / "nope.jsonl")}):
            with self.assertRaises(op.OwingProofError, msg=str(kw)):
                self.build(**kw)


class ProofRequiredAudienceTest(OwingProofTest):
    """v1 / r5 / p1 [key=k-proof-required]: an open unverified/processing row with core proof_required = true is OWED
    (the ask class), and only an earlier uvn-status ASK - never a status line - keeps a user off the list."""

    def test_proof_required_rows_are_asked_and_a_status_line_does_not_block(self):
        rows = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "1"],      # the 21's shape
                ["8", "q8", "processing", "2026-09-06", "1", "0", "0", "0"],      # not owed: not named
                ["9", "p9", "unverified", "2026-09-07", "1", "0", "0", "1"],      # told by a status line only
                ["10", "p10", "unverified", "2026-09-08", "1", "0", "0", "1"]]    # already ASKED
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_messages VALUES ('9', 'sent', 'status-team-review', '[]'), ('10', 'sent', 'uvn-status', '[\"p10\"]')")
        db.commit(); db.close()
        res = self.build(query=q(rows))
        got = {u["user_id"]: (u["class"], u["request_ids"], u["facts"]) for u in res["users"]}
        self.assertEqual(got, {"8": ("uvn", ["p8"], [["p8", "unverified", True]]),
                               "9": ("uvn", ["p9"], [["p9", "unverified", True]])})
        self.assertEqual(len(res["replica_facts"]["sha256"]), 64)
        self.assertIn("proof_required", res["replica_facts"]["query"])
        # r5: the header's query is the EXACT runnable SQL the build ran (and verify_facts re-runs), with its sha256
        seen = []
        res = self.build(query=q(rows, seen=seen))
        self.assertIn(res["replica_facts"]["query"], seen)
        self.assertTrue(res["replica_facts"]["query"].startswith("SELECT "))
        import hashlib
        self.assertEqual(res["replica_facts"]["query_sha256"], hashlib.sha256(res["replica_facts"]["query"].encode()).hexdigest())

    def vf(self, lst, query):
        return op.verify_facts(lst, query, holds_path=self.holds, ledger_path=self.ledger)

    def test_verify_facts_flags_a_user_whose_rows_changed(self):
        rows = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "1"]]
        lst = self.build(query=q(rows))
        self.assertEqual(self.vf(lst, q(rows)), [])
        moved = [["8", "p8", "approved", "2026-09-05", "1", "0", "0", "1"]]            # decided since the build
        self.assertEqual(len(self.vf(lst, q(moved))), 1)
        cleared = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "0"]]        # proof no longer required
        self.assertEqual(len(self.vf(lst, q(cleared))), 1)
    def test_verify_facts_sees_a_request_owed_after_the_build_and_an_edited_list(self):
        # QA #1565: the owed set is RECOMPUTED - a second proof_required row that appeared after the build is a change
        rows = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "1"]]
        lst = self.build(query=q(rows))
        self.assertEqual(self.vf(lst, q(rows)), [])
        more = rows + [["8", "p9", "processing", "2026-10-30", "1", "0", "0", "1"]]
        self.assertEqual(len(self.vf(lst, q(more))), 1)
        import copy
        edited = copy.deepcopy(lst)
        u8 = next(u for u in edited["users"] if u["user_id"] == "8")
        u8["request_ids"] = []                                                    # ids no longer what is owed
        self.assertTrue(any(d.startswith("8:") for d in self.vf(edited, q(rows))))
        tampered = copy.deepcopy(lst)
        next(u for u in tampered["users"] if u["user_id"] == "8")["facts"] = [["p8", "unverified", False]]
        self.assertTrue(any(d.startswith("header:") for d in self.vf(tampered, q(rows))))


    def test_verify_facts_re_reads_ONLY_this_pages_users_never_the_whole_table(self):
        # [key=facts-scope] (Fable 2026-11-11): the re-read exists to compare ONE page's facts with the replica, and it
        # used to re-run the whole-table query to do it. On 2026-11-11 that query stopped finishing (900 s timeout) and
        # every family behind it sent nothing for a day. The re-read must ask about the listed users and nobody else.
        lst = self.build()
        seen = []
        def fake(sql):
            seen.append(sql)
            if sql == op.STATUS_GUARD_SQL:                              # the guard, unchanged, still runs first
                return [[s] for s in ("approved", "rejected") + op.OPEN_STATUSES]
            return [list(r) for r in ROWS]
        self.assertEqual(self.vf(lst, fake), [])
        self.assertEqual(seen[0], op.STATUS_GUARD_SQL)
        seen = [q for q in seen if q != op.STATUS_GUARD_SQL]
        self.assertTrue(seen)
        for sql in seen:
            self.assertIn("cr.userid IN (", sql)                       # the SAME query, restricted to the page
            self.assertIn("FROM postgresql_core.public.credit_requests cr", sql)
            self.assertNotEqual(sql, op.REPLICA_SQL)                    # never the whole table again
        listed = sorted(u["user_id"] for u in lst["users"])
        self.assertEqual(seen[0].rsplit("cr.userid IN (", 1)[1].rstrip(")"), ",".join(listed))
        # an empty page asks the replica NOTHING at all (the whole-table read was the timeout)
        asked = []
        self.assertEqual(self.vf({"users": [], "replica_facts": op.facts_header([])},
                                 lambda sql: asked.append(sql) or []), [])
        self.assertEqual(asked, [])

    def test_the_builders_class_list_verifies_and_a_rewrite_carrying_the_parent_header_does_not(self):
        # r5 776: the 08:00Z dry tick's split kept the full list's facts sha -> the uvn check refused it (rightly)
        replica = q(ROWS)
        res = self.build()
        uvn = op.class_list(res, "uvn")
        self.assertEqual([u["user_id"] for u in uvn["users"]], ["7", "1"])
        self.assertEqual(uvn["split_of"], {"class": "uvn", "users": 4, "sha256": res["replica_facts"]["sha256"]})
        self.assertEqual(self.vf(uvn, replica), [])                             # the split list verifies
        old_way = {**res, "users": uvn["users"]}                                # the tick's old rewrite
        self.assertTrue(any(d.startswith("header:") for d in self.vf(old_way, replica)))
        # the CLI writes it with signed_on, from the same build
        import json, unittest.mock
        out, cls = self.d / "owing.json", self.d / "owing-uvn.json"
        with unittest.mock.patch.object(op, "build", lambda **kw: res):
            self.assertEqual(op._main(["--out", str(out), "--class-out", f"uvn={cls}"]), 0)
        doc = json.loads(cls.read_text())
        self.assertEqual((doc["replica_facts"], doc["users"]), (uvn["replica_facts"], uvn["users"]))
        self.assertIn("signed_on", doc)
        with self.assertRaises(SystemExit):
            op._main(["--out", str(out), "--class-out", "bogus=x"])

    def test_told_users_owing_rows_no_ask_named_are_the_follow_up_class_with_only_those_rows(self):
        # Fable 590 (b): user 4 was asked about t4; a NEW owed row t4b appeared since -> listed uvn_new_rows [t4b];
        # user 9's other row carries a core proofRequest marker (core asked it) -> only its unmarked row is listed
        db = sqlite3.connect(self.ledger)
        db.execute("UPDATE verify_messages SET request_ids_json = '[\"t4\"]' WHERE account_id = '4'")
        db.commit()
        rows = [list(r) for r in ROWS] + [
            ["4", "t4b", "user_verification_needed", "2026-10-20", "1", "0", "0", "0"],
            ["9", "m9", "user_verification_needed", "2026-09-01", "0", "0", "1", "0"],
            ["9", "n9", "user_verification_needed", "2026-10-21", "0", "0", "0", "0"],
            ["5", "m5b", "user_verification_needed", "2026-07-02", "0", "0", "1", "0"]]   # every owed row marked: none
        res = self.build(query=q(rows))
        got = {u["user_id"]: (u["class"], u["request_ids"]) for u in res["users"] if u["class"] == op.NEW_ROWS}
        self.assertEqual(got, {"4": (op.NEW_ROWS, ["t4b"]), "9": (op.NEW_ROWS, ["n9"])})
        self.assertEqual((res["counts"]["list_uvn_new_rows_paid"], res["counts"]["list_uvn_new_rows_free"]), (1, 1))
        # the class list verifies against the replica + the ledger (its owed set = only the un-asked rows)
        lst = op.class_list(res, op.NEW_ROWS)
        self.assertEqual(self.vf(lst, q(rows)), [])
        db.execute("UPDATE verify_messages SET request_ids_json = '[\"t4\", \"t4b\"]' WHERE account_id = '4'")
        db.commit()                                              # asked since the build: user 4's set changed
        self.assertTrue(any(d.startswith("4:") for d in self.vf(lst, q(rows))))
        # never in the uvn-status family's list
        self.assertNotIn("4", [u["user_id"] for u in op.class_list(res, "uvn")["users"]])


class OpenStatusPushdownTest(OwingProofTest):
    """2026-11-12: `status NOT IN ('approved', 'rejected')` is not pushed to Postgres by the Trino connector, so the
    owing read pulled all 5.65M rows (76 GB of JSON) and died on the statement timeout - census UNMEASURED, the
    uvn-status family skipped. The open statuses are listed positively (pushed down, core's status index, ~10 s), and
    a guard refuses the read whenever the table holds a status this module does not know."""

    def test_the_query_lists_the_open_statuses_positively(self):
        self.assertNotIn("NOT IN", op.REPLICA_SQL)                                # the unpushable form must not return
        self.assertIn("AND cr.status IN ('unverified', 'processing', 'user_verification_needed')", op.REPLICA_SQL)
        self.assertEqual(set(op.OPEN_STATUSES) & set(op.CLOSED_STATUSES), set())

    def test_every_status_the_owed_rule_acts_on_is_read(self):
        # owed() names rows by status; a status it acts on that the query never returns would be owed and never asked
        for st in ("user_verification_needed", "unverified", "processing"):
            owe, _ = op.owed([["1", "x", st, "d", "0", "1", "0", "1"]], held=True)
            self.assertEqual(sorted(owe), ["x"], st)
            self.assertIn(st, op.OPEN_STATUSES)

    def test_the_guard_runs_first_and_the_header_names_it(self):
        import hashlib
        seen = []
        res = self.build(query=q(ROWS, seen=seen))
        self.assertEqual(seen, [op.STATUS_GUARD_SQL, op.REPLICA_SQL])
        head = res["replica_facts"]
        self.assertEqual(head["guard_query"], op.STATUS_GUARD_SQL)
        self.assertEqual(head["guard_query_sha256"], hashlib.sha256(op.STATUS_GUARD_SQL.encode()).hexdigest())
        self.assertEqual(head["query_sha256"], hashlib.sha256(op.REPLICA_SQL.encode()).hexdigest())

    def test_closed_statuses_in_the_table_are_fine(self):
        res = self.build(query=q(ROWS, statuses=["approved", "rejected", "unverified", "processing",
                                                 "user_verification_needed"]))
        self.assertEqual(len(res["users"]), 4)

    def test_an_unknown_status_refuses_the_build_and_the_signing_read(self):
        lst = self.build()
        for where in ("build", "verify_facts"):
            seen = []
            fake = q(ROWS, statuses=["approved", "on_hold", "unverified"], seen=seen)
            with self.assertRaises(op.OwingProofError, msg=where) as cm:
                if where == "build":
                    self.build(query=fake)
                else:
                    op.verify_facts(lst, fake, holds_path=self.holds, ledger_path=self.ledger)
            self.assertIn("on_hold", str(cm.exception))
            self.assertEqual(seen, [op.STATUS_GUARD_SQL], where)                 # refused BEFORE the audience read

    def test_an_unreadable_guard_is_a_refusal_never_a_pass(self):
        for statuses in ([], [""], ["   "]):                                      # nothing read / an empty status
            with self.assertRaises(op.OwingProofError, msg=repr(statuses)):
                self.build(query=q(ROWS, statuses=statuses))
        with self.assertRaises(op.OwingProofError):                               # the wrong shape: audience rows
            self.build(query=lambda sql: [list(r) for r in ROWS])

    def test_a_guard_that_raises_stops_the_read(self):
        def down(sql):
            raise RuntimeError("trino failed: connection refused")
        with self.assertRaises(RuntimeError):
            self.build(query=down)


class UvnReminder14ClassTest(unittest.TestCase):
    """uvn-reminder-14 (captain 2026-11-13 15:08Z): the builder's own class for the one reminder of a sent uvn-status
    ask. Listed: a told user whose ASKED rows are still owed and whom the ledger rule (verify_ledger.reminder14_why)
    says is due. Every user the rule leaves out is counted by reason, so each build logs its own funnel."""

    def setUp(self):
        from datetime import datetime, timedelta, timezone
        from credit_review import verify_ledger
        self.vl, self.now, self.td = verify_ledger, datetime.now(timezone.utc).replace(microsecond=0), timedelta
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        self.holds = str(d / "holds.jsonl"); Path(self.holds).write_text("")
        self.risk = str(d / "risk.csv"); Path(self.risk).write_text("userid,teamid,churn_signal\n")
        self.rows = []

    def ask(self, uid, rids, days, *, paid=True, owed=True, campaign="uvn-status", sent=True, **cols):
        """A ledger ask `days` ago naming `rids`, and (owed) those rows still waiting on the user in the replica."""
        db = self.vl.connect(self.ledger)
        try:
            when = self.now - self.td(days=days)
            c = self.vl.claim(db, campaign=campaign, user_key=f"u{uid}@x.com", day=when.strftime("%Y-%m-%d"),
                              request_ids=list(rids), message_type="email", approved_by="U", approval_ref="r", now=when,
                              user_id=str(uid), enforce_cap=False)
            if sent:
                self.vl.finalize(db, message_row=c["message_row"], status="sent", message_id=f"m{uid}-{campaign}")
            for col, val in cols.items():
                db.execute(f"UPDATE verify_messages SET {col} = ? WHERE id = ?", (val, c["message_row"]))
            db.commit()
        finally:
            db.close()
        if owed:
            self.rows += [[str(uid), r, "user_verification_needed", "2026-09-01", "1" if paid else "0", "0", "0", "0"]
                          for r in rids]

    def build(self, rows=None):
        return op.build(query=q(self.rows if rows is None else rows), ledger_path=self.ledger, holds_path=self.holds,
                        at_risk_path=self.risk, now=self.now)

    def reminders(self, res):
        return {u["user_id"]: u["request_ids"] for u in res["users"] if u["class"] == op.REMINDER}

    def test_a_told_user_due_a_reminder_is_listed_with_the_rows_the_ask_named_and_nothing_else(self):
        self.ask(4, ["t4", "t4x"], 20)
        self.ask(5, ["t5"], 14, paid=False)
        self.rows.append(["4", "t4b", "user_verification_needed", "2026-11-01", "1", "0", "0", "0"])   # opened since
        res = self.build()
        self.assertEqual(self.reminders(res), {"4": ["t4", "t4x"], "5": ["t5"]})
        c = res["counts"]
        self.assertEqual((c["list_uvn_reminder_14_paid"], c["list_uvn_reminder_14_free"]), (1, 1))
        # the row no ask named is the follow-up class's, in its own entry; the first-ask list never carries either user
        self.assertEqual({u["user_id"]: u["request_ids"] for u in res["users"] if u["class"] == op.NEW_ROWS},
                         {"4": ["t4b"]})
        self.assertEqual([u["user_id"] for u in op.class_list(res, "uvn")["users"]], [])
        self.assertTrue(all(u["skip"] is None and u["paid"] == (u["user_id"] == "4")
                            for u in res["users"] if u["class"] == op.REMINDER))

    def test_everyone_the_ledger_rule_leaves_out_is_counted_by_reason_and_never_listed(self):
        self.ask(1, ["a1"], 13)                                              # the ask is 13 days old
        self.ask(2, ["a2"], 20, last_reply_at="2026-11-01T00:00:00Z")        # replied
        self.ask(3, ["a3"], 20, proof_tagged_at="2026-11-01T00:00:00Z")      # sent a document
        self.ask(4, ["a4"], 20, sent=False)                                  # the ask never confirmed sent
        self.ask(5, ["a5"], 20)
        self.ask(5, ["a5"], 2, campaign="uvn-reminder-14", owed=False)       # already reminded
        self.ask(6, ["a6"], 20)
        self.ask(6, ["z6"], 3, campaign="claim-status", owed=False)          # a claim note from us this week
        self.ask(9, ["a9"], 20)
        self.ask(9, ["z9"], 10, campaign="status-team-review", owed=False)   # another credit note followed the ask
        self.ask(7, ["a7"], 20, owed=False)                                  # decided since: nothing named is owed
        self.ask(8, ["a8"], 20)                                              # ... and the one who is due
        res = self.build()
        self.assertEqual(self.reminders(res), {"8": ["a8"]})
        c = res["counts"]
        self.assertEqual({k: v for k, v in c.items() if k.startswith("reminder_skip_")},
                         {"reminder_skip_not_due": 1, "reminder_skip_replied": 1, "reminder_skip_proof_received": 1,
                          "reminder_skip_already_sent": 1, "reminder_skip_messaged_7d": 1,
                          "reminder_skip_noted_since_ask": 1})
        # user 4 was never TOLD (no sent ask), so they are still the first ask's - never the reminder's
        self.assertIn("4", [u["user_id"] for u in res["users"] if u["class"] == "uvn"])

    def test_a_reminder_from_another_sender_keyed_by_email_only_counts(self):
        # the 2026-11-09 `reminder-1` rows carry the account email and no account id
        self.ask(9, ["a9"], 20)
        db = self.vl.connect(self.ledger)
        day = (self.now - self.td(days=4)).strftime("%Y-%m-%d")
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                   "n_credits, approved_by, approval_ref, created_at, updated_at) VALUES ('reminder-1', 'reminder-14', "
                   "'u9@x.com', ?, 'sent', 'email', '[]', 1, 'system:reminder-driver', 'auto:reminder-1', ?, ?)",
                   (day, day + "T00:00:00Z", day + "T00:00:00Z"))
        db.commit(); db.close()
        res = self.build()
        self.assertEqual(self.reminders(res), {})
        self.assertEqual(res["counts"]["reminder_skip_already_reminded"], 1)

    def test_the_class_list_verifies_and_a_row_decided_since_the_build_is_a_change(self):
        self.ask(4, ["t4", "t4x"], 20)
        res = self.build()
        lst = op.class_list(res, op.REMINDER)
        self.assertEqual(lst["split_of"]["class"], "uvn_reminder_14")
        vf = lambda rows: op.verify_facts(lst, q(rows), holds_path=self.holds, ledger_path=self.ledger)   # noqa: E731
        # "an ask was sent" is this class's premise, never a change since the build
        self.assertEqual(vf(self.rows), [])
        # a NEW row since the build is the follow-up class's: the reminder's owed set (the asked rows) did not change
        self.assertEqual(vf(self.rows + [["4", "new", "user_verification_needed", "2026-11-12", "1", "0", "0", "0"]]), [])
        decided = [r for r in self.rows if r[1] != "t4x"]                    # one asked row was decided since
        self.assertTrue(any(d.startswith("4:") for d in vf(decided)))

    def test_a_ledger_that_cannot_say_who_replied_lists_nobody(self):
        # an old-shape ledger (no reply / proof columns): the rule cannot be read, so the class is empty - never guessed
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE verify_messages (account_id TEXT, status TEXT, campaign TEXT DEFAULT 'uvn-status', "
                   "request_ids_json TEXT DEFAULT '[]')")
        db.execute("CREATE TABLE verify_refusal_holds (user_id TEXT, reason TEXT, flagged_at TEXT)")
        db.execute("INSERT INTO verify_messages (account_id, status, request_ids_json) VALUES ('4', 'sent', '[\"t4\"]')")
        db.commit(); db.close()
        res = self.build([["4", "t4", "user_verification_needed", "2026-07-01", "1", "0", "0", "0"]])
        self.assertEqual(self.reminders(res), {})
        self.assertEqual(res["counts"]["reminder_skip_no_prior_ask"], 1)


if __name__ == "__main__":
    unittest.main()
