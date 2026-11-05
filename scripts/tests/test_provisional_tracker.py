#!/usr/bin/env python3
"""credit_review/provisional_tracker.py: 7-day backup clock from the DELIVERED ask, day-N route,
backup_ask_undelivered. Trino faked; stdlib only."""
import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production
import csv
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import provisional_tracker as pt  # noqa: E402
from credit_review import verify_ledger  # noqa: E402

NOW = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)


def proof_doc(entries, gen="2026-10-30T11:30:00Z", parts=("cs-intercom", "cs-gmail"), stale=False):
    """A complete proof-on-file export (verify_notify's contract)."""
    full = [{"source": "intercom", "ref": "c1", "kind": "pending_doc", **e} for e in entries]
    return {"generated_at": gen,
            "sources": [{"name": "core", "generated_at": gen, "count": 0}]
            + [{"name": n, "generated_at": gen, "stale": stale, "count": 0} for n in parts],
            "users": len({str(e["user_id"]) for e in full}), "entries": full,
            "gmail_contacts_90d": {"generated_at": gen, "source": "test", "user_ids": []}}
R = {k: f"{k}0000000-0000-4000-8000-000000000000"[:36] for k in ("a", "b", "c", "d", "e")}


def approval(at="2026-10-23T12:00:00Z", due="2026-11-22T12:00:00Z", **kw):
    return {"provisional": True, "at": at, "proofDueAt": due, "anchor_kind": "none", **kw}


def fake(rows):
    def q(sql):
        buf = io.StringIO()
        buf.write("WARNING: dumb terminal\n")
        w = csv.writer(buf)
        for rid, uid, appr in rows:
            w.writerow([rid, str(uid), "p", "t", "Song", "20", json.dumps(appr)])
        return buf.getvalue()
    return q


class Tracker(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:", isolation_level=None)
        self.db.executescript(verify_ledger.SCHEMA)
        self.proof = Path(tempfile.mkdtemp()) / "pof.json"
        self.proof.write_text(json.dumps(proof_doc([{"user_id": 5, "request_id": R["a"]},
                                                    {"user_id": 6, "request_id": None}])))

    def sent(self, rids, at, campaign="backup-ask", status="sent", claimed=None):
        """A note claimed at `claimed` (default: same time) and finalized `status` at `at`, through the ledger."""
        cur = self.db.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type,"
                              " request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at)"
                              " VALUES (?, 'initial', 'u', ?, 'attempted', 'email', ?, ?, 'x', 'x', ?, ?)",
                              (campaign, at[:10], json.dumps(rids), len(rids), claimed or at, claimed or at))
        verify_ledger.finalize(self.db, message_row=cur.lastrowid, status=status,
                               now=datetime.fromisoformat(at.replace("Z", "+00:00")))

    def test_states_and_the_clock_starts_at_the_delivered_ask(self):
        self.sent([R["c"]], "2026-10-22T09:00:00Z")            # delivered 8 days before NOW -> due
        self.sent([R["d"]], "2026-10-28T09:00:00Z")            # delivered 2 days before NOW -> running
        self.sent([R["e"]], "2026-10-20T09:00:00Z", status="rejected")   # not delivered
        rows = [(R["a"], 5, approval()), (R["b"], 6, approval()), (R["c"], 7, approval()),
                (R["d"], 8, approval()), (R["e"], 9, approval())]
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), paying={7}, now=NOW)
        st = {r["request_id"]: r for r in t.rows}
        self.assertEqual(st[R["a"]]["state"], "backup_on_file")       # request-level document
        self.assertEqual(st[R["b"]]["state"], "user_documented")      # whole-user document: never asked, stage 2
        self.assertEqual(st[R["c"]]["state"], "due")
        self.assertEqual(st[R["c"]]["due_at"], "2026-10-29T09:00Z")
        self.assertEqual(st[R["c"]]["day_n_route"], "live_dsp_check_then_removal_gate")
        self.assertEqual((st[R["d"]]["state"], st[R["d"]]["days_left"]), ("clock_running", 4))
        self.assertEqual(st[R["e"]]["state"], "no_ask_yet")
        self.assertTrue(st[R["c"]]["core_due_mismatch"], "core stamped approval + 30 d")
        self.assertEqual(t.rows[0]["request_id"], R["c"], "paid + due first")

    def test_backup_ask_undelivered_after_48h(self):
        rows = [(R["a"] .replace("a", "f", 1), 9, approval(at="2026-10-28T11:00:00Z")),
                (R["b"].replace("b", "g", 1), 9, approval(at="2026-10-29T13:00:00Z"))]
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), now=NOW)
        self.assertEqual(len(t.undelivered()), 1)
        self.assertTrue(any("backup_ask_undelivered: 1" in f for f in t.findings()))

    def band_a(self, rid):
        """The decider recorded a trusted-anchor (band A) approval for `rid`."""
        self.db.execute("CREATE TABLE IF NOT EXISTS decisions (run_id TEXT, decided_at TEXT, request_id TEXT, "
                        "profile_id TEXT, user_id TEXT, track_id TEXT, big_track INTEGER, decision TEXT, "
                        "reason TEXT, mode TEXT, evidence_kind TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS decision_outcomes (run_id TEXT, at TEXT, request_id TEXT, "
                        "action TEXT, outcome TEXT)")
        self.db.execute("INSERT INTO decisions (run_id, request_id, profile_id, evidence_kind) VALUES "
                        "('run-1', ?, 'p', 'validator_low_risk_trusted')", (rid,))
        self.db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES "
                        "('run-1', '2026-10-23T12:00:00Z', ?, 'approve', 'approved')", (rid,))

    def test_a_band_a_approval_is_not_a_missed_ask(self):
        """firstmate 768: 107 of the 279 "no delivered ask" credits were band A (trusted anchor), which
        NEVER gets a verify note (Fable 10-22 09:30Z). Counting them as waits inflated the watchdog."""
        A, B = R["a"].replace("a", "h", 1), R["b"].replace("b", "i", 1)
        self.band_a(A)
        rows = [(A, 77, approval()), (B, 78, approval())]
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), now=NOW)
        st = {r["request_id"]: r["state"] for r in t.rows}
        self.assertEqual(st[A], "no_ask_needed", "band A: no note is ever sent, so this is expected")
        self.assertEqual(st[B], "no_ask_yet", "an ordinary provisional credit with no ask IS waiting")
        self.assertEqual([r["request_id"] for r in t.undelivered()], [B], "the watchdog counts only the real wait")
        self.assertTrue(any("band A 1" in f for f in t.findings()))

    def test_core_never_shortens_a_deadline_only_extends_it(self):
        """firstmate 768: NO user may be held to a date earlier than delivered + 7 d. Core stamps
        approval + 30 d, which is sometimes EARLIER than the ruled date; deadline_at must extend."""
        C, D = R["c"], R["d"]
        self.sent([C], "2026-10-28T12:00:00Z")   # delivered 2 days before NOW -> ruled due 2026-11-04
        self.sent([D], "2026-10-03T12:00:00Z")   # delivered 27 days ago -> due 2026-10-10, core says 11-22
        rows = [(C, 71, approval(at="2026-10-28T13:00:00Z", due="2026-10-29T00:00:00Z")),   # core EARLIER: reject
                (D, 72, approval(at="2026-10-01T00:00:00Z", due="2026-12-30T00:00:00Z"))]   # core LATER: keep core
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), now=NOW)
        st = {r["request_id"]: r for r in t.rows}
        self.assertTrue(st[C]["core_due_shortens"], "core's date is EARLIER: the case that must never be applied")
        self.assertEqual(st[C]["core_proof_due_at"], "2026-10-29T00:00Z")
        self.assertEqual(st[C]["due_at"], "2026-11-04T12:00Z", "the ruled date stands")
        self.assertEqual(st[C]["deadline_at"], "2026-11-04T12:00Z", "core's earlier date never shortens the user")
        self.assertEqual(st[D]["deadline_at"], "2026-12-30T00:00Z", "a later core date is kept: extension only")
        self.assertTrue(any("never a shortening" in f for f in t.findings()))

    def test_unreadable_inputs_are_an_error_never_clean(self):
        def boom(sql):
            raise RuntimeError("trino rc=1")
        t = pt.run(boom, ledger=self.db, proof_path=str(self.proof), now=NOW)
        self.assertIn("could not run", t.findings()[0])
        t = pt.run(fake([]), ledger=self.db, proof_path="/nonexistent.json", now=NOW)
        self.assertIsNotNone(t.error)

    def test_status_notes_do_not_start_the_clock(self):
        self.sent([R["c"]], "2026-10-22T09:00:00Z", campaign="status-team-review")
        t = pt.run(fake([(R["c"], 7, approval())]), ledger=self.db, proof_path=str(self.proof), now=NOW)
        self.assertEqual(t.rows[0]["state"], "no_ask_yet")

    def test_buckets_and_the_day_4_reminder(self):
        for rid, at in ((R["a"].replace("a", "h", 1), "2026-10-29T10:00:00Z"),    # due 11-05: due_in_7
                        (R["b"].replace("b", "i", 1), "2026-10-25T10:00:00Z"),    # due 11-01: due_in_3, reminder
                        (R["c"].replace("c", "j", 1), "2026-10-23T14:00:00Z"),    # due 10-30 14:00: due_today
                        (R["d"].replace("d", "k", 1), "2026-10-21T10:00:00Z")):   # due 10-28: overdue
            self.sent([rid], at)
        rows = [(R[k].replace(k, n, 1), 9, approval()) for k, n in (("a", "h"), ("b", "i"), ("c", "j"), ("d", "k"))]
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), now=NOW)
        got = {r["request_id"][0]: (r["bucket"], r["reminder_due"]) for r in t.rows}
        self.assertEqual(got, {"h": ("due_in_7", False), "i": ("due_in_3", True), "j": ("due_today", True),
                               "k": ("overdue", False)})

    def test_board_payload_contract(self):
        self.sent([R["c"]], "2026-10-22T09:00:00Z")
        self.sent([R["d"]], "2026-10-28T09:00:00Z")
        rows = [(R["a"], 5, approval()), (R["c"], 7, approval()), (R["d"], 7, approval()), (R["e"], 9, approval())]
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), paying={7}, now=NOW)
        p = pt.board_payload(t, NOW)
        self.assertEqual(set(p["buckets"]), set(pt.BOARD_BUCKETS))
        self.assertEqual(p["window_days"], 7)
        by = {u["user_id"]: u for u in p["users"]}
        self.assertEqual((by[7]["bucket"], by[7]["credits"], by[7]["paid"]), ("overdue", 2, True), "earliest due wins")
        self.assertEqual(by[9]["bucket"], "no_due")
        self.assertEqual(by[5]["documents"], "received")
        self.assertEqual(p["users"][0]["user_id"], 7, "paid first")
        self.assertEqual(sum(p["buckets"].values()), len(p["users"]))
        for u in p["users"]:
            self.assertEqual(set(u), {"user_id", "paid", "credits", "bucket", "earliest_due", "ask_delivered_at",
                                      "documents", "live_check", "reasons"})

    def test_board_payload_carries_every_field_the_board_requires(self):
        """The board refuses the WHOLE snapshot with 400 bad_snapshot when one required
        field is missing (lib/provisional.mjs validateProvisionalSnapshot), so an omitted
        key is a silent prod outage of the daily push, not a partial display. ``held_for_
        documents`` was missing from 2026-10-24 to 2026-10-26 for exactly that reason."""
        self.sent([R["c"]], "2026-10-22T09:00:00Z")
        p = pt.board_payload(pt.run(fake([(R["c"], 7, approval())]), ledger=self.db,
                                    proof_path=str(self.proof), now=NOW), NOW)
        for key in ("as_of", "source", "window_days", "buckets", "held_for_documents", "users"):
            self.assertIn(key, p, f"the board 400s without {key}")
        self.assertIsNone(p["held_for_documents"],
                          "core's held-for-documents class is not in this tracker's read: null (not reported), never 0")

    def test_post_board_reports_failures(self):
        import urllib.error

        def deny(req, timeout):
            self.assertEqual(req.get_header("X-credit-trust-ingest-token"), "tok")
            raise urllib.error.HTTPError(req.full_url, 401, "no", {}, None)
        self.assertEqual(pt.post_board({"x": 1}, "tok", opener=deny), (False, "HTTP 401"))
        self.assertIsNone(pt.board_token("/nonexistent.env"))

    def test_post_board_carries_the_board_s_refusal_line(self):
        """A bare "HTTP 400" hid a one-word schema fix for two days; surface the board's message."""
        import urllib.error

        body = json.dumps({"error": "bad_snapshot",
                           "message": "held_for_documents is required (a whole number, or null when not counted yet)"})

        def refuse(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 400, "bad request", {},
                                         io.BytesIO(body.encode()))
        ok, why = pt.post_board({"x": 1}, "tok", opener=refuse)
        self.assertFalse(ok)
        self.assertIn("HTTP 400", why)
        self.assertIn("held_for_documents is required", why)

    def test_a_non_authoritative_proof_export_is_an_error_never_a_due_list(self):
        """QA @1349: stale, a missing part, or a malformed entry must not read as 'no backup'."""
        self.sent([R["c"]], "2026-10-22T09:00:00Z")
        for doc in (proof_doc([{"user_id": 7, "request_id": R["c"]}], gen="2026-10-29T00:00:00Z"),   # 36 h old
                    proof_doc([{"user_id": 7, "request_id": R["c"]}], parts=("cs-intercom",)),      # gmail part missing
                    proof_doc([{"user_id": 7, "request_id": R["c"]}], stale=True),
                    dict(proof_doc([]), entries=[{"user_id": "x"}])):                               # malformed entry
            self.proof.write_text(json.dumps(doc))
            t = pt.run(fake([(R["c"], 7, approval())]), ledger=self.db, proof_path=str(self.proof), now=NOW)
            self.assertIsNotNone(t.error, doc.get("sources"))
            self.assertEqual(t.rows, [])
            self.assertIn("could not run", t.findings()[0])

    def test_board_never_makes_a_documented_user_overdue(self):
        """QA @1349: a resolved credit (backup on file) carries no due bucket, even if its ask is old."""
        self.sent([R["a"]], "2026-10-15T09:00:00Z")          # user 5's documented credit, ask 15 days ago
        self.sent([R["d"]], "2026-10-28T09:00:00Z")          # user 5 also has an outstanding credit
        rows = [(R["a"], 5, approval()), (R["d"], 5, approval())]
        t = pt.run(fake(rows), ledger=self.db, proof_path=str(self.proof), now=NOW)
        u = pt.board_payload(t, NOW)["users"][0]
        self.assertEqual((u["bucket"], u["earliest_due"]), ("d4_7", "2026-11-04T09:00Z"))
        self.assertEqual(u["documents"], "received")

    def test_the_clock_starts_at_the_send_not_the_claim(self):
        """QA @1349: claimed 10-21, delivered 10-24: due 10-31, not 10-28."""
        self.sent([R["c"]], "2026-10-24T09:00:00Z", claimed="2026-10-21T09:00:00Z")
        t = pt.run(fake([(R["c"], 7, approval())]), ledger=self.db, proof_path=str(self.proof), now=NOW)
        self.assertEqual((t.rows[0]["state"], t.rows[0]["due_at"]), ("clock_running", "2026-10-31T09:00Z"))
        self.db.execute("UPDATE verify_messages SET last_reply_at='x', updated_at='2026-10-29T00:00:00Z'")
        t = pt.run(fake([(R["c"], 7, approval())]), ledger=self.db, proof_path=str(self.proof), now=NOW)
        self.assertEqual(t.rows[0]["due_at"], "2026-10-31T09:00Z", "sent_at is immutable")

    def test_window_is_seven_days(self):
        self.assertEqual(pt.WINDOW_DAYS, 7)


if __name__ == "__main__":
    unittest.main()
