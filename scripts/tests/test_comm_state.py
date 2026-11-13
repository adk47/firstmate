"""credit_review/comm_state.py: the send-time communication-state check (captain 2026-10-28 18:2xZ). One test per
rule: (1) the "wait for our message" lines never go to a user with any document or reply on file; (2) R1 never
after a decision was told; (3) nothing within 7 days of another note; (4) the state is read at send time, so a reply
injected between the list cut and the send cancels it; never step backwards; unreadable = unknown."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import contextlib
import io
import json
import os
import sqlite3
import threading
import time
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import comm_state as cs  # noqa: E402
from credit_review import verify_ledger as vl  # noqa: E402

UID = 42
OLD = (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
OLD_DAY = OLD[:10]


class FakeIntercom:
    def __init__(self):
        self.convs: dict[str, dict] = {}

    def __call__(self, method, path, body=None):
        if method == "POST":
            return {"conversations": [{"id": c} for c in self.convs], "total_count": len(self.convs)}
        return self.convs[path.split("/")[2].split("?")[0]]


class CommStateTest(unittest.TestCase):
    def setUp(self):
        d = Path(tempfile.mkdtemp())
        cs.LEDGER = str(d / "ledger.sqlite3")
        vl.connect(cs.LEDGER).close()
        cs.PROOF_STORE = str(d / "proof.sqlite")
        p = sqlite3.connect(cs.PROOF_STORE)
        p.execute("CREATE TABLE proof_intake (user_id INTEGER, file_sha256 TEXT, received_at TEXT DEFAULT '')")
        p.commit(); p.close()
        cs.DV_STORE = str(d / "dv.sqlite")
        v = sqlite3.connect(cs.DV_STORE)
        v.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, request_id TEXT, "
                  "proof_id TEXT, need TEXT, outcome TEXT, at TEXT DEFAULT '2026-10-20T00:00:00Z')")
        v.commit(); v.close()
        cs.PROOF_ON_FILE = str(d / "pof.json")
        Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": []}))
        self.core = []          # [rid, status, approvedNotice, proofRequest]
        self.ic = FakeIntercom()

    def note(self, campaign, at=OLD, reply=None, kind="initial", status="sent", ids=("r1",), msg_id=None,
             contact_id="c1"):
        db = sqlite3.connect(cs.LEDGER)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at, last_reply_at, "
                   "message_id, contact_id) VALUES (?,?,?,?,?,?,'email',?,1,'U','ref',?,?,?,?,?,?)",
                   (campaign, kind, "j@x.com", str(UID), at[:10], status, json.dumps(list(ids)), at, at, at, reply, msg_id,
                    contact_id))
        db.commit(); db.close()

    def run_(self, campaign="credit-hold-status", copy="credithold", keys=("r1",), conversation="", fraud=()):
        return cs.check(campaign, copy, UID, list(keys), "c1", conversation=conversation,
                        query=lambda sql: [["0", "0"]] if "proof_required_owed" in sql else ([list(r) for r in self.core] if "credit_requests" in sql else []),
                        ic=self.ic, fraud=lambda uid, q: list(fraud))

    def test_a_never_told_user_with_nothing_on_file_gets_the_wait_line(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        res = self.run_()
        self.assertEqual((res["hold"], res["state"]), (False, "none"))

    def test_rule1_any_document_or_reply_on_file_holds_the_wait_lines(self):
        cases = {
            "proof_intake": lambda: sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake (user_id, file_sha256) VALUES ({UID}, 's');"),
            "dv_outcomes": lambda: sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes (user_id, request_id) VALUES ({UID}, 'r1');"),
            "proof_on_file": lambda: Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": [{"user_id": UID, "source": "gmail"}]})),
            "ledger_reply": lambda: (self.note("uvn-status"), sqlite3.connect(cs.LEDGER).executescript(
                f"UPDATE verify_messages SET proof_tagged_at='{OLD}';")),   # a tagged proof (attachments), not text
            "intercom_attachment": lambda: self.ic.convs.update({"9": {"source": {"author": {"type": "user"}, "attachments": [{"name": "a.pdf"}]}}}),
        }
        for name, add in cases.items():
            with self.subTest(name):
                self.setUp()
                self.core = [["r1", "user_verification_needed", "", ""]]
                add()
                for camp, copy in (("credit-hold-status", "credithold"), ("claim-proof-pending", "claimpending")):
                    res = self.run_(camp, copy)
                    self.assertTrue(res["hold"], (name, camp, res))
                    self.assertTrue(any(r.startswith("proof_on_file:") for r in res["reasons"]), res)
                    self.assertIn(name.split("_")[0], json.dumps(res["reasons"]))
                # r5 fable-copy-1103-r5/mcf-proof-ack: merge-claim-first's copy ACKNOWLEDGES the documents on file, so
                # proof stops holding it - and the same fact becomes the render fact the gate refuses without.
                res = self.run_("merge-claim-first", "mergeclaimfirst")
                self.assertFalse(res["hold"], res)
                self.assertTrue(res["proof_on_file"], res)

    def test_rule1_a_text_reply_is_never_replied_an_attachment_is(self):
        # Fable 199 / p1 200 (rule change): a text message - even 'is there anything I have to provide?' after our
        # ask - is an ask trigger, never 'replied'; a document (attachment) is
        ask = (datetime.now(timezone.utc) - timedelta(days=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.core = [["r1", "user_verification_needed", "", ask]]
        epoch = datetime.fromisoformat(ask.replace("Z", "+00:00")).timestamp()
        self.ic.convs["9"] = {"source": {"author": {"type": "admin"}},
                              "conversation_parts": {"conversation_parts": [
                                  {"author": {"type": "user"}, "body": "is there any specific information I have to provide?",
                                   "created_at": epoch + 100}]}}
        self.assertFalse(self.run_()["hold"])
        self.note("uvn-status", reply=OLD)                       # a ledger text reply stamp: not 'replied' either
        self.assertFalse(self.run_()["hold"], self.run_())
        # ... but a LINK to a shared document is a document (b1 on #1508); a plain URL is not
        self.ic.convs["9"]["conversation_parts"]["conversation_parts"].append(
            {"author": {"type": "user"}, "body": "see https://www.tidal.com/track/1", "created_at": epoch + 150})
        self.assertFalse(self.run_()["hold"])
        self.ic.convs["9"]["conversation_parts"]["conversation_parts"].append(
            {"author": {"type": "user"}, "body": "here: https://drive.google.com/file/d/abc/view", "created_at": epoch + 160})
        self.assertIn("intercom_document_link", json.dumps(self.run_()["reasons"]))
        self.ic.convs["9"]["conversation_parts"]["conversation_parts"].pop()
        self.ic.convs["9"]["conversation_parts"]["conversation_parts"].append(
            {"author": {"type": "user"}, "body": "", "attachments": [{"name": "split.pdf"}], "created_at": epoch + 200})
        res = self.run_()
        self.assertTrue(res["hold"])
        self.assertIn("intercom_attachment", json.dumps(res["reasons"]))

    def test_b1_cases_per_source(self):
        # doc-verify b1 204: request R created 2026-10-15T07:21:38Z; ASK = no hold from documents, HOLD = held
        R, created = "r1", "2026-10-15 07:21:38 UTC"
        oct20 = datetime(2026, 10, 20, tzinfo=timezone.utc).timestamp()
        mar29 = datetime(2026, 3, 29, tzinfo=timezone.utc).timestamp()
        pof = lambda e: (lambda: Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": [dict({"user_id": UID, "source": "x"}, **e)]})))
        def intake(at, cands=None):
            def go():
                db = sqlite3.connect(cs.PROOF_STORE)
                db.execute("ALTER TABLE proof_intake ADD COLUMN candidate_request_ids_json TEXT")
                db.execute("INSERT INTO proof_intake VALUES (?,?,?,?)", (UID, "s", at, json.dumps(cands or ["other"])))
                db.commit(); db.close()
            return go
        dv = lambda rid: (lambda: sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes (user_id, request_id) VALUES ({UID}, '{rid}');"))
        att = lambda at: (lambda: self.ic.convs.update({"9": {"source": dict({"author": {"type": "user"},
                                                                              "attachments": [{"name": "a.png"}]},
                                                                             **({"created_at": at} if at else {}))}}))
        cases = {
            "P1": (pof({"proof_at": "2026-03-29T11:40:36Z"}), False),
            "P2": (pof({"request_id": R, "proof_at": "2026-03-01T00:00:00Z"}), True),
            "P3": (pof({"proof_at": "2026-10-20T00:00:00Z"}), True),
            "P4": (pof({}), True),
            "P5": (pof({"request_id": "another", "proof_at": "2026-03-01T00:00:00Z"}), False),
            "I1": (intake("2026-03-29T00:00:00Z"), False),
            "I2": (intake("2026-10-20T00:00:00Z"), True),
            "I3": (intake("2026-03-29T00:00:00Z", [R.upper()]), True),
            "I4": (intake(""), True),
            "D1": (dv(R), True),
            "D2": (dv("another"), False),
            "C1": (att(mar29), False),
            "C2": (att(oct20), True),
            "C3": (att(None), True),
            # QA #1508: the opening attachment's time on the CONVERSATION (source.created_at absent): a March one is old
            "C4": (lambda: self.ic.convs.update({"9": {"created_at": mar29, "source": {"author": {"type": "user"},
                                                                                     "attachments": [{"name": "a.png"}]}}}), False),
            "C5": (lambda: self.ic.convs.update({"9": {"created_at": oct20, "source": {"author": {"type": "user"},
                                                                                     "attachments": [{"name": "a.png"}]}}}), True),
            # QA #1508: source.created_at present but NULL, the conversation dated March -> old, not undated
            "C6": (lambda: self.ic.convs.update({"9": {"created_at": mar29, "source": {"author": {"type": "user"}, "created_at": None,
                                                                                     "attachments": [{"name": "a.png"}]}}}), False),
        }
        for name, (add, held) in cases.items():
            with self.subTest(name):
                self.setUp()
                self.core = [[R, "user_verification_needed", "", "", created]]
                add()
                self.assertEqual(self.run_("uvn-status", "uvnstatus")["hold"], held, name)
        # mixed: two named requests, the oldest (10-15) is the bar; a 10-20 entry postdates it -> HELD (per user)
        self.setUp()
        self.core = [["r1", "user_verification_needed", "", "", created],
                     ["r2", "user_verification_needed", "", "", "2026-10-28 00:00:00 UTC"]]
        pof({"proof_at": "2026-10-20T00:00:00Z"})()
        self.assertTrue(self.run_("uvn-status", "uvnstatus", keys=("r1", "r2"))["hold"])

    def test_rule1_only_a_document_that_postdates_the_named_request_counts(self):
        # p1 198 / Fable 199 (Lamberto 298376): March 2026 screenshots / approvals cannot prove a request filed 10-15
        created = "2026-10-15 07:21:38.896000 UTC"
        march = datetime(2026, 3, 29, 11, 40, tzinfo=timezone.utc)
        older = {
            "proof_intake": lambda: sqlite3.connect(cs.PROOF_STORE).executescript(
                f"INSERT INTO proof_intake VALUES ({UID}, 's', '2026-03-29T11:40:36Z');"),
            "proof_on_file": lambda: Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": [
                {"user_id": UID, "source": "intercom", "kind": "human_approved_after_doc", "request_id": None,
                 "proof_at": "2026-03-29T11:40:36Z"}]})),
            "intercom_attachment": lambda: self.ic.convs.update({"9": {"source": {
                "author": {"type": "user"}, "attachments": [{"name": "Captura.png"}], "created_at": march.timestamp()}}}),
        }
        for name, add in older.items():
            with self.subTest(name):
                self.setUp()
                self.core = [["r1", "user_verification_needed", "", "", created]]
                add()
                self.assertFalse(self.run_("uvn-status", "uvnstatus")["hold"], name)
                # ... unknown request date (old 4-column row): every document counts (fail closed)
                self.core = [["r1", "user_verification_needed", "", ""]]
                self.assertTrue(self.run_("uvn-status", "uvnstatus")["hold"], name)
        # an older intake FILED AGAINST the named request (candidate_request_ids) still holds (p1 203)
        self.setUp()
        self.core = [["r1", "user_verification_needed", "", "", created]]
        db = sqlite3.connect(cs.PROOF_STORE)
        db.execute("ALTER TABLE proof_intake ADD COLUMN candidate_request_ids_json TEXT")
        db.execute("INSERT INTO proof_intake VALUES (?, 's', '2026-03-29T11:40:36Z', '[\"R1\"]')", (UID,))
        db.commit(); db.close()
        self.assertTrue(self.run_("uvn-status", "uvnstatus")["hold"])
        # a dv read of ANOTHER request does not count; one of the named request does
        self.setUp()
        self.core = [["r1", "user_verification_needed", "", "", created]]
        sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes (user_id, request_id) VALUES ({UID}, 'other');")
        self.assertFalse(self.run_("uvn-status", "uvnstatus")["hold"])
        sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes (user_id, request_id) VALUES ({UID}, 'r1');")
        self.assertTrue(self.run_("uvn-status", "uvnstatus")["hold"])
        # a document AFTER the request, or one naming it, still holds
        self.setUp()
        self.core = [["r1", "user_verification_needed", "", "", created]]
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, 's', '2026-10-20T00:00:00Z');")
        self.assertTrue(self.run_("uvn-status", "uvnstatus")["hold"])
        self.setUp()
        self.core = [["r1", "user_verification_needed", "", "", created]]
        Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": [{"user_id": UID, "source": "gmail", "request_id": "r1",
                                                                   "proof_at": "2026-03-01T00:00:00Z"}]}))
        self.assertTrue(self.run_("uvn-status", "uvnstatus")["hold"])

    def test_rule1_never_after_a_receipt_or_a_decision(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.note("status-doc-received")
        self.assertIn("already_acknowledged", self.run_()["reasons"])
        self.setUp()
        self.core = [["r1", "approved", "", ""]]
        self.assertIn("decided_or_told", self.run_()["reasons"])

    def test_rule2_r1_never_after_a_decision_was_told(self):
        self.core = [["r1", "unverified", "", ""]]
        self.assertFalse(self.run_(RECEIPT := "status-doc-received", "docrecvr")["hold"])
        self.core = [["r1", "unverified", "2026-10-01T00:00:00Z", ""]]       # approval notice sent
        res = self.run_(RECEIPT, "docrecvr")
        self.assertTrue(res["hold"])
        self.assertEqual(res["state"], "told")
        self.core = [["r1", "rejected", "", ""]]
        self.assertTrue(self.run_(RECEIPT, "docrecvr")["hold"])
        # a document on file is exactly why R1 goes: it never holds R1
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake (user_id, file_sha256) VALUES ({UID}, 's');")
        self.core = [["r1", "unverified", "", ""]]
        self.assertFalse(self.run_(RECEIPT, "docrecvr")["hold"])

    def test_rule3_no_two_campaigns_within_7_days(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.note("status-team-review", at=(datetime.now(timezone.utc) - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        for camp, copy in (("credit-hold-status", "credithold"), ("status-doc-received", "docrecvr"),
                           ("merge-pending", "mergepending")):
            res = self.run_(camp, copy, ("merge-x",) if camp == "merge-pending" else ("r1",))
            self.assertTrue(any(r.startswith("messaged_7d") for r in res["reasons"]), (camp, res))
        # a refused or deferred row is not a message
        self.setUp()
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.note("status-team-review", status="deferred",
                  at=(datetime.now(timezone.utc) - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertFalse(self.run_()["hold"])

    def test_rule4_a_reply_landing_between_the_cut_and_the_send_cancels_it(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        cut = self.run_()                       # the list is cut: the user qualifies
        self.assertFalse(cut["hold"])
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake (user_id, file_sha256) VALUES ({UID}, 'new');")   # files now
        at_send = self.run_()                   # the gate re-reads right before the post
        self.assertTrue(at_send["hold"])
        self.assertEqual(at_send["state"], "replied")

    def test_unreadable_is_unknown_never_send(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        Path(cs.PROOF_ON_FILE).write_text("{")
        with self.assertRaises(cs.Unknown):
            self.run_()
        self.setUp()
        with self.assertRaises(cs.Unknown):
            cs.check("credit-hold-status", "credithold", UID, ["r1"], "c1", query=lambda sql: [["x"]], ic=self.ic,
                     fraud=lambda uid, q: [])
        self.ic.convs = {str(i): {} for i in range(cs.CONV_CAP + 1)}
        self.core = [["r1", "user_verification_needed", "", ""]]
        res = self.run_()
        self.assertTrue(res["hold"])           # more conversations than we can read: in doubt, hold


class ThreadAndFraudRulesTest(CommStateTest):
    """p1's R5-R8 after the batch-1 dry run (18:5xZ): 3 of 5 sampled R1 threads would have been wrong."""
    NOW = datetime.now(timezone.utc).timestamp()

    def conv(self, cid, parts, source_author="user"):
        self.ic.convs[cid] = {"id": cid, "source": {"author": {"type": source_author}, "created_at": 0},
                              "conversation_parts": {"conversation_parts": parts}}

    def r1(self, cid):
        self.core = [["r1", "unverified", "", ""]]
        return self.run_("status-doc-received", "docrecvr", conversation=cid)

    def test_r5_an_admin_comment_in_the_thread_within_7_days_holds(self):
        self.conv("7", [{"author": {"type": "user"}, "body": "doc", "created_at": self.NOW - 3 * 86400},
                        {"author": {"type": "admin"}, "part_type": "comment", "body": "status update", "created_at": self.NOW - 2 * 86400}])
        self.assertIn("messaged_7d:R5_admin_comment_in_thread", self.r1("7")["reasons"])
        # an internal note is not a message to the customer
        self.conv("8", [{"author": {"type": "user"}, "body": "doc", "created_at": self.NOW - 3 * 86400},
                        {"author": {"type": "admin"}, "part_type": "note", "body": "internal", "created_at": self.NOW - 86400}])
        self.assertFalse(self.r1("8")["hold"])

    def test_r6_a_thread_whose_last_customer_part_is_over_30_days_old_gets_no_r1(self):
        self.conv("7", [{"author": {"type": "user"}, "body": "streams dropped", "created_at": self.NOW - 173 * 86400}])
        self.assertIn("R6_stale_thread", self.r1("7")["reasons"])
        self.conv("8", [{"author": {"type": "user"}, "body": "doc", "created_at": self.NOW - 29 * 86400}])
        self.assertFalse(self.r1("8")["hold"])

    def test_r7_a_thread_we_closed_as_sorted_gets_no_r1(self):
        self.conv("7", [{"author": {"type": "user"}, "body": "doc", "created_at": self.NOW - 20 * 86400},
                        {"author": {"type": "admin"}, "part_type": "comment", "body": "Great news, it's all sorted now!",
                         "created_at": self.NOW - 19 * 86400}])
        self.assertIn("R7_thread_resolved", self.r1("7")["reasons"])
        # the customer wrote again after our "sorted": the matter is open again
        self.ic.convs["7"]["conversation_parts"]["conversation_parts"].append(
            {"author": {"type": "user"}, "body": "one more doc", "created_at": self.NOW - 10 * 86400})
        self.assertNotIn("R7_thread_resolved", self.r1("7")["reasons"])

    def test_r6_r7_apply_to_r1_only_and_r5_to_every_line(self):
        self.conv("7", [{"author": {"type": "user"}, "body": "x", "created_at": self.NOW - 90 * 86400}])
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.assertFalse(self.run_(conversation="7")["hold"])

    def test_r8_the_fraud_lens_holds_at_send_time(self):
        self.core = [["r1", "unverified", "", ""]]
        for f in (["R8_fraud_lens_held"], ["R8_watchlist"], ["R8_deny_list"]):
            res = self.run_("status-doc-received", "docrecvr", fraud=f)
            self.assertTrue(res["hold"])
            self.assertIn(f[0], res["reasons"])

    def test_r8_reads_the_repo_policies(self):
        cs.POLICIES = str(ROOT / "policies")
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl")
        Path(cs.ACCOUNT_HOLDS).write_text("")
        try:
            self.assertIn("R8_deny_list", cs.fraud_facts(128308, lambda sql: []))     # A1 pull / decider deny list
            self.assertEqual(cs.fraud_facts(424242424, lambda sql: []), [])
            Path(cs.ACCOUNT_HOLDS).write_text(json.dumps({"user_id": "424242424"}) + "\n")
            self.assertEqual(cs.fraud_facts(424242424, lambda sql: []), ["R8_account_hold"])
            cs.POLICIES = str(ROOT / "nope")
            with self.assertRaises(cs.Unknown):
                cs.fraud_facts(1, lambda sql: [])
        finally:
            cs.POLICIES = "/opt/hydra/policies"

    def test_r7_a_closed_thread_or_the_customer_saying_sorted_gets_no_r1(self):
        self.conv("7", [{"author": {"type": "user"}, "body": "doc", "created_at": self.NOW - 3 * 86400}])
        self.assertFalse(self.r1("7")["hold"])
        self.ic.convs["7"]["state"] = "closed"
        self.assertIn("R7_thread_closed", self.r1("7")["reasons"])            # R1: a closed thread gets nothing
        self.conv("8", [{"author": {"type": "user"}, "body": "thanks, all sorted now", "created_at": self.NOW - 3 * 86400}])
        self.assertIn("R7_thread_resolved", self.r1("8")["reasons"])

    def test_r8_an_account_hold_appearing_between_cut_and_send_holds(self):
        d = Path(tempfile.mkdtemp())
        cs.ACCOUNT_HOLDS = str(d / "holds.jsonl")
        Path(cs.ACCOUNT_HOLDS).write_text(json.dumps({"user_id": "7", "kind": "approval_hold"}) + "\n")
        try:
            self.assertEqual(cs.account_hold_facts(UID), [])                       # at the cut: not held
            with open(cs.ACCOUNT_HOLDS, "a") as fh:
                fh.write(json.dumps({"user_id": str(UID), "kind": "approval_hold"}) + "\n")
            self.assertEqual(cs.account_hold_facts(UID), ["R8_account_hold"])     # at send: held
            os.utime(cs.ACCOUNT_HOLDS, (time.time() - 73 * 3600,) * 2)
            with self.assertRaises(cs.Unknown):                                    # stale list: nothing
                cs.account_hold_facts(UID)
            os.utime(cs.ACCOUNT_HOLDS, (time.time() + 3600,) * 2)
            with self.assertRaises(cs.Unknown):                                    # future-dated: nothing
                cs.account_hold_facts(UID)
            os.remove(cs.ACCOUNT_HOLDS)
            with self.assertRaises(cs.Unknown):
                cs.account_hold_facts(UID)
        finally:
            cs.ACCOUNT_HOLDS = "/opt/firstmate/fraud-lens/out/account_holds.jsonl"

    def test_an_unreadable_thread_is_unknown(self):
        self.core = [["r1", "unverified", "", ""]]
        self.ic.convs["9"] = {"id": "other"}
        with self.assertRaises(cs.Unknown):
            self.r1("9")


class ToldScopeTest(CommStateTest):
    """QA #1460: a removal / take-back / withdrawal note told only the requests it named. An old note about credit A
    never holds a NEW request B forever."""

    def test_an_old_removal_note_about_another_credit_does_not_hold_a_new_request(self):
        self.core = [["r2", "user_verification_needed", "", ""]]
        for camp in ("removal-notice", "takeback-notice", "withdrawal-confirm"):
            with self.subTest(camp):
                self.setUp()
                self.core = [["r2", "user_verification_needed", "", ""]]
                self.note(camp, ids=("r1",))                     # 30 days ago, about credit r1
                for c, k in (("uvn-status", "uvnstatus"), ("credit-hold-status", "credithold")):
                    res = self.run_(c, k, keys=("r2",))
                    self.assertFalse(res["hold"], (camp, c, res))
                    self.assertNotEqual(res["state"], "told")
                # the same note naming THIS request does hold it
                self.note(camp, ids=("R2",))
                res = self.run_("uvn-status", "uvnstatus", keys=("r2",))
                self.assertTrue(res["hold"])
                self.assertEqual(res["state"], "told")


class OwesProofGuardTest(CommStateTest):
    """message-book-1029 (Fable [key=message-book-1029], captain 'just go'): the five 'nothing else is needed'
    campaigns (A2/A3/C3/C4/D3) can NEVER reach a user who owes proof: any UVN row, a review-hold row, an account hold,
    or an open ask. A user who owes nothing still gets them."""
    FIVE = [("status-doc-received", "docrecv"), ("status-doc-received", "docrecvq"), ("status-team-review", "teamreview"),
            ("status-team-review", "teamreviewcount"), ("claim-status", "claimstatus")]

    def guard(self, rows, *, held=False, asked=False):
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl")
        Path(cs.ACCOUNT_HOLDS).write_text(json.dumps({"user_id": str(UID)}) + "\n" if held else "")
        if asked:
            self.note("uvn-status")
        q = lambda sql: [["0", "0"]] if "proof_required_owed" in sql else ([list(r) for r in rows] if "credit_requests" in sql else [])
        try:
            return [cs.check(c, k, UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lambda u, q: []) for c, k in self.FIVE]
        finally:
            cs.ACCOUNT_HOLDS = "/opt/firstmate/fraud-lens/out/account_holds.jsonl"

    def test_a_user_who_owes_proof_never_gets_a_nothing_else_line(self):
        for name, rows, kw, want in (
                ("uvn row", [["user_verification_needed", "false"]], {}, "owes:uvn"),
                ("review hold", [["unverified", "true"]], {}, "owes:review_hold"),
                ("account hold", [], {"held": True}, "owes:account_hold"),
                ("open ask", [["unverified", "false"]], {"asked": True}, "owes:open_ask")):
            with self.subTest(name):
                self.setUp()
                for res in self.guard(rows, **kw):
                    self.assertTrue(res["hold"], (name, res))
                    self.assertIn(want, res["reasons"])
        # owes nothing (only an unverified row with no review rule fired, never asked, not held): they go
        self.setUp()
        for res in self.guard([["unverified", "false"]]):
            self.assertEqual((res["hold"], res["state"]), (False, "owes_nothing"))
        # an ask long answered by a decision (no request pending) is not an open ask
        self.setUp()
        self.assertFalse(any(r["hold"] for r in self.guard([], asked=True)))
        # unreadable replica = unknown, never "owes nothing"
        with self.assertRaises(cs.Unknown):
            cs.check("status-team-review", "teamreview", UID, ["r1"], "c1", query=lambda sql: [["x"]], ic=self.ic,
                     fraud=lambda u, q: [])


class DocLinkHostTest(unittest.TestCase):
    def test_document_links_match_the_parsed_host_only(self):
        yes = ["https://drive.google.com/file/d/x/view", "see https://www.dropbox.com/s/abc?dl=0", "https://we.tl/t-abc",
               "https://contoso.sharepoint.com/:b:/s/x", "https://app.box.com/s/x", "https://1drv.ms/b/s!x"]
        no = ["https://sandbox.com/help", "https://drive.google.com.evil.example/x", "https://evil.example/?u=drive.google.com",
              "https://notbox.com/x", "https://tidal.com/track/1", "drive.google.com/file (no scheme)"]
        for t in yes:
            self.assertTrue(cs.has_doc_link(t), t)
        for t in no:
            self.assertFalse(cs.has_doc_link(t), t)


class ReplyDueTest(unittest.TestCase):
    """Fable [key=reply-due] (l1 219, p1 200): a customer-last part in a credit thread unanswered > 24 h allows EXACTLY
    ONE gated answer despite the 7-day cooldowns; every other rule still applies."""

    def setUp(self):
        CommStateTest.setUp(self)
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl")   # owes_proof reads the hold set (fresh, empty)
        Path(cs.ACCOUNT_HOLDS).write_text("")
        self.now = time.time()
        self.thread("215473681300330", title="Credit Verification", last_user_age_h=78)
        self.link("215473681300330")

    def link(self, conversation, ids=("r1",)):
        """b1 270: the filed-request evidence - one of our sent notes in THIS thread named the request (ledger)"""
        db = sqlite3.connect(cs.LEDGER)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, conversation_id, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                   "VALUES ('verify-live','initial','j@x.com',?,'2026-09-01','sent','comment',?,?,1,'U','ref',"
                   "'2026-09-01T00:00:00Z','2026-09-01T00:00:00Z','2026-09-01T00:00:00Z')",
                   (str(UID), conversation, json.dumps(list(ids))))
        db.commit(); db.close()

    def ask_message(self, message_id, ids=("r1",), uid=UID):
        """An ask sent as an Intercom MESSAGE: a ledger row with a message id and NO conversation (the reply opens a
        new conversation whose source id is this message id)."""
        db = sqlite3.connect(cs.LEDGER)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, message_id, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                   "VALUES ('uvn-status','initial',?,?,'2026-11-01','sent','email',?,?,1,'U','ref',"
                   "'2026-11-01T00:00:00Z','2026-11-01T00:00:00Z','2026-11-01T00:00:00Z')",
                   (f"u{uid}@x.com", str(uid), str(message_id), json.dumps(list(ids))))
        db.commit(); db.close()

    def thread(self, cid, *, title="Credit Verification", last_user_age_h=78, contact="c1", after=None):
        parts = [{"id": "1", "part_type": "comment", "author": {"type": "admin"}, "body": "status update",
                  "created_at": self.now - 10 * 86400},
                 {"id": "57000000001", "part_type": "comment", "author": {"type": "user"},
                  "body": "This track has been under review for months now.", "created_at": self.now - last_user_age_h * 3600}]
        parts += after or []
        self.ic.convs[cid] = {"id": cid, "title": title, "state": "open", "source": {"id": "0", "author": {"type": "user"}},
                              "contacts": {"contacts": [{"id": contact}]}, "conversation_parts": {"conversation_parts": parts}}

    def q(self, sql):
        """the replica fake, by query shape: core rows, owes_proof (status, review-fired), open track titles"""
        if "proof_required_owed" in sql:
            return [["0", "0"]]
        if "spotifytracktitle" in sql:
            return [["Song A"]]
        if "regexp_like" in sql:
            return [["user_verification_needed", "false"]]
        return [list(r) for r in self.core] if "credit_requests" in sql else []

    def run_due(self, part="57000000001", campaign="uvn-status", copy="uvnstatus"):
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        return cs.check(campaign, copy, UID, ["r1"], "c1", conversation="215473681300330", reply_due_part=part,
                        query=self.q, ic=self.ic, fraud=lambda uid, q: [])

    def test_a_reply_in_an_o_thread_waits_on_gmail_never_on_us(self):
        # [key=gmail-o-forward] (r5): the conversation our /o ask started (its source id = the ledgered message id of a
        # sent /o note) - the customer's reply there is the coded outcome said_emailed, not due
        db = sqlite3.connect(cs.LEDGER)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, message_id, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                   "VALUES ('uvn-status','initial','j@x.com',?,'2026-10-31','sent','email','880001',?,1,'U',"
                   "'captain ...; gmail-fallback fable-copy-1030-r5/o','2026-10-31T22:00:00Z','2026-10-31T22:00:00Z','2026-10-31T22:00:00Z')",
                   (str(UID), json.dumps(["r1"])))
        db.commit(); db.close()
        self.ic.convs["215473681300330"]["source"] = {"id": "880001", "author": {"type": "admin"}}
        why = cs.reply_due("215473681300330", "c1", "57000000001", self.ic, now=self.now)
        trig = next(p for p in [self.ic.convs["215473681300330"]["source"]] + self.ic.convs["215473681300330"]
                    ["conversation_parts"]["conversation_parts"] if str(p.get("id")) == "57000000001")
        # QA #1594: provenance alone is NOT said_emailed - only an affirmative "sent it" (or an attachment) is
        O = "reply_due:gmail_o_reply (said_emailed; waiting_on third_party:gmail)"
        for body, want in (("I already emailed it to support@muso.ai", True), ("Yes, sent it yesterday, thanks!", True),
                           ("i've forwarded the documents", True), ("Done. Emailed them over to you this morning.", True),
                           ("I have not emailed it", False), ("how do I send it?", False), ("sent it?", False),
                           ("I didn't send it yet", False), ("sent it wrong, can I resend", False),
                           ("Which email address should I use", False), ("", False)):
            trig["body"], trig["attachments"] = body, []
            self.assertEqual(O in cs.reply_due("215473681300330", "c1", "57000000001", self.ic, now=self.now), want, body)
        # r5 + p1 23:3xZ: an attachment is never enough on its own - affirmative text is required with it
        for body, want in (("", False), ("is this the right one?", False), ("I already emailed it", True)):
            trig["body"], trig["attachments"] = body, [{"name": "split.pdf"}]
            self.assertEqual(O in cs.reply_due("215473681300330", "c1", "57000000001", self.ic, now=self.now), want,
                             f"attachment + {body!r}")
        # every customer part counts: an affirmative followed by a question is an answer owed
        conv = self.ic.convs["215473681300330"]
        trig["body"], trig["attachments"] = "I already emailed it", []
        later = {"id": "57000000009", "part_type": "comment", "author": {"type": "user", "id": "c1"},
                 "body": "how long will it take?", "created_at": trig.get("created_at") or 1}
        conv["conversation_parts"]["conversation_parts"].append(later)
        self.assertNotIn(O, cs.reply_due("215473681300330", "c1", "57000000001", self.ic, now=self.now))
        conv["conversation_parts"]["conversation_parts"].remove(later)
        self.ic.convs["215473681300330"]["source"] = {"id": "880002", "author": {"type": "admin"}}   # another note's thread
        self.assertNotIn("reply_due:gmail_o_reply (said_emailed; waiting_on third_party:gmail)",
                         cs.reply_due("215473681300330", "c1", "57000000001", self.ic, now=self.now))

    def test_reply_ref_never_answers_a_superseded_or_stale_part(self):
        # QA #1601 (1): trigger_class calls a superseded / stale part non_status; a ref must not answer it either
        for why in ("not the customer's latest part", "stale part (> 30 d, or undated)", "part not in thread"):
            with unittest.mock.patch.object(cs, "trigger_class", lambda *a, _w=why, **kw: {"class": "non_status", "why": _w,
                                                                                         "part_age_d": None}):
                res = cs.check("reply-ref", "refr", UID, ["r1"], "c1", conversation="215473681300330",
                               reply_due_part="57000000001", query=self.q, ic=self.ic, fraud=lambda uid, qq: [])
            self.assertTrue(any(r.startswith("reply_ref:part_not_answerable") for r in res["reasons"]), (why, res))

    def test_reply_ref_only_on_a_handed_off_part_and_only_when_its_fact_holds(self):
        # [key=product-dispute-refs]: an approved ref answers a part the picker hands off - a STATUS part gets its coded
        # class instead; /q needs NO open request, /y a DECIDED named request (read live, fail closed)
        facts = {"open": 0, "status": "rejected"}
        def q(sql):
            if sql.startswith("SELECT count(*) FROM postgresql_core.public.credit_requests WHERE userid"):
                return [[str(facts["open"])]]
            if sql.startswith("SELECT status FROM postgresql_core.public.credit_requests WHERE lower"):
                return [[facts["status"]]] if facts["status"] else []
            return self.q(sql)
        def ref(copy, keys=("r1",)):
            self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
            return cs.check("reply-ref", copy, UID, list(keys), "c1", conversation="215473681300330",
                            reply_due_part="57000000001", query=q, ic=self.ic, fraud=lambda uid, qq: [])
        # the default part is a status question: the coded class applies, never a ref
        res = ref("refr")
        self.assertTrue(any(r.startswith("reply_due:coded_class_applies") for r in res["reasons"]), res)
        # a product part (streams): handed off -> the ref may go
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = \
            "my streams are not updating on the analytics page"
        res = ref("refr")
        self.assertFalse(res["hold"], res)
        self.assertEqual(ref("refq")["reasons"], [])                                 # no open request: /q fits
        facts["open"] = 2
        self.assertIn("reply_ref:q_open_request_exists", ref("refq")["reasons"])
        rid = "0b0e4c1e-1111-2222-3333-444455556666"
        self.assertEqual(ref("refy", keys=(rid,))["reasons"], [])                    # decided (rejected): /y fits
        facts["status"] = "user_verification_needed"
        self.assertIn("reply_ref:y_request_not_decided", ref("refy", keys=(rid,))["reasons"])
        self.assertIn("reply_ref:y_needs_the_request_id", ref("refy", keys=("reply-57000000001",))["reasons"])

    def test_lamberto_an_unanswered_question_is_answered_despite_a_note_inside_7_days(self):
        CommStateTest.note(self, "status-team-review", at=(datetime.now(timezone.utc) - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        plain = cs.check("uvn-status", "uvnstatus", UID, ["r1"], "c1", conversation="215473681300330",
                         query=self.q, ic=self.ic, fraud=lambda uid, q: [])
        self.assertTrue(any(r.startswith("messaged_7d") for r in plain["reasons"]), plain)     # unsolicited: held
        self.assertFalse(self.run_due()["hold"], self.run_due())                                 # the answer: goes

    def test_not_due_holds_with_the_reason(self):
        cases = {
            "reply_due:not_24h_yet": dict(last_user_age_h=3),
            "reply_due:already_answered": dict(after=[{"id": "9", "part_type": "comment", "author": {"type": "admin"},
                                                       "body": "we are on it", "created_at": self.now - 3600}]),
            # QA #1509: a TEAM-authored answer is an answer too
            "reply_due:already_answered ": dict(after=[{"id": "9", "part_type": "comment", "author": {"type": "team"},
                                                        "body": "we are on it", "created_at": self.now - 3600}]),
            "reply_due:R9_thread_not_about_credits": dict(title="Fwd: Your receipt from Muso.AI"),
            "reply_due:not_this_users_thread": dict(contact="someone-else"),
            "reply_due:thread_not_open": dict(),                     # state set per case below (QA #1517)
            # QA #1509: the nominated part is 78 h old but the customer wrote AGAIN 1 h ago: the 24 h run from the latest
            "reply_due:not_24h_yet ": dict(after=[{"id": "57000000002", "part_type": "comment", "author": {"type": "user"},
                                                   "body": "any news?", "created_at": self.now - 3600}]),
        }
        for want, kw in cases.items():
            with self.subTest(want):
                self.thread("215473681300330", **({"title": "refund"} if want.startswith("reply_due:R9") else {}) | kw)
                if want == "reply_due:thread_not_open":
                    self.ic.convs["215473681300330"]["state"] = "snoozed"
                if want.startswith("reply_due:R9"):
                    self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "refund please"
                    self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][0]["body"] = "passed on"
                res = self.run_due()
                self.assertTrue(res["hold"], (want, res))
                self.assertIn(want.strip(), res["reasons"])
        self.thread("215473681300330")
        del self.ic.convs["215473681300330"]["state"]                        # missing state: not verified open
        self.assertIn("reply_due:thread_not_open", self.run_due()["reasons"])
        self.thread("215473681300330")
        self.assertIn("reply_due:not_a_customer_part", self.run_due(part="1")["reasons"])
        self.assertIn("reply_due:part_not_in_thread", self.run_due(part="123")["reasons"])
        self.assertIn("reply_due:campaign_not_allowed", self.run_due(campaign="credit-hold-status", copy="credithold")["reasons"])

    def test_a_document_held_user_gets_the_status_class_not_the_ask(self):
        # [key=reply-due-classes] (a): a document on file -> the answer is status-doc-received (never receipted yet);
        # the ask is held with the class it should be, and the status campaign itself goes
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, 's', '2026-10-20T00:00:00Z');")
        res = self.run_due()
        self.assertIn("reply_due:class_is:status-doc-received", res["reasons"], res)
        ok = self.run_due(campaign="status-doc-received", copy="docrecvr")
        self.assertFalse(ok["hold"], ok)
        self.assertEqual(ok["reply_due"]["answer_class"]["campaign"], "status-doc-received")
        # already receipted: never a second receipt (r5 A). The user still owes proof (a uvn row) -> no coded class,
        # never 'nothing is needed' (the existing guard) - the handoff list
        CommStateTest.note(self, "status-doc-received", at="2026-10-21T00:00:00Z")
        self.assertTrue(any(r.startswith("reply_due:no_coded_class: owes proof")
                            for r in self.run_due(campaign="status-doc-received", copy="docrecvr")["reasons"]))
        # ... and owing nothing (the request moved to review) -> status-team-review
        base = self.q
        self.q = lambda sql: [] if "regexp_like" in sql else base(sql)
        self.assertIn("reply_due:class_is:status-team-review", self.run_due(campaign="status-doc-received", copy="docrecvr")["reasons"])

    def test_the_answer_class_order(self):
        st = {"told_notes": [], "acked": ""}
        core = {"told": [], "decided": []}
        self.assertEqual(cs.answer_class(st, core, [], ["owes:uvn"])[0], "uvn-status")            # owes proof: the ask
        self.assertEqual(cs.answer_class(st, core, [], [])[0], "status-team-review")              # QA #1517: owes nothing
        self.assertEqual(cs.answer_class(st, core, ["proof_intake"], ["owes:uvn"])[0], "status-doc-received")
        self.assertEqual(cs.answer_class({**st, "acked": "x"}, core, ["proof_intake"], [])[0], "status-team-review")
        self.assertEqual(cs.answer_class({**st, "acked": "x"}, core, ["proof_intake"], ["owes:uvn"])[0], "")   # owes proof
        self.assertEqual(cs.answer_class(st, {"told": ["r1"], "decided": []}, [], [])[0], "")              # decision told
        self.assertEqual(cs.answer_class(st, {"told": [], "decided": ["r1"]}, ["proof_intake"], [])[0], "")

    def test_the_status_part_classifier(self):
        # [key=reply-due-classes] (b), r5 B: 4438's Dolby Atmos question (stale AND not a status part) is refused
        now = time.time()
        tc = lambda *a, **k: cs.trigger_class(*a, **{"filed": ["r1"], **k})
        def conv(body, age_d, prev=None):
            ps = ([prev] if prev else []) + [{"id": "9", "part_type": "comment", "author": {"type": "user"}, "body": body,
                                             "created_at": now - age_d * 86400}]
            return {"source": {"author": {"type": "user"}, "body": "hi", "created_at": now - 300 * 86400},
                    "conversation_parts": {"conversation_parts": ps}}
        dolby = "Hello- just checking, is there a way to register Dolby Atmos credits into the system database? I haven't heard"
        # codify 2026-11-11: the answerable window is 365 days, not 30. 30 days sent 1,771 threads where the
        # customer wrote and got silence to a handoff bucket no one works; a late answer is not a wrong answer.
        self.assertEqual(tc(conv(dolby, 400), "9")["class"], "non_status")
        self.assertIn("stale", tc(conv(dolby, 400), "9")["why"])
        # a 190-day part is inside the window now: still a product question, but NOT refused for its age
        self.assertEqual(tc(conv(dolby, 190), "9")["class"], "non_status")
        self.assertNotIn("stale", tc(conv(dolby, 190), "9")["why"])
        self.assertIn("product cue", tc(conv(dolby, 190), "9")["why"])
        self.assertEqual(cs.STATUS_PART_DAYS, 365)
        self.assertEqual(tc(conv("where is my request?", 190), "9")["class"], "status")      # late, still answered
        self.assertIn("stale", tc(conv("where is my request?", 400), "9")["why"])
        # 'immersive' before a role word is no product cue (it names a credit role: see PRODUCT_RE); dolby / atmos /
        # spatial still are
        self.assertIsNone(cs.PRODUCT_RE.search("where is my immersive mix engineer request?"))
        for cue in ("dolby", "atmos", "spatial"):
            self.assertIsNotNone(cs.PRODUCT_RE.search(f"where is my {cue} request?"), cue)
        self.assertEqual(tc(conv("is there a way to register Dolby Atmos credits?", 2), "9")["class"], "non_status")
        self.assertEqual(tc(conv("my credits", 2), "9")["class"], "non_status")       # 'credits' alone
        # QA #1517: a product question that merely uses 'request' is not a status part
        self.assertEqual(tc(conv("Can I request Dolby Atmos credits?", 2), "9")["class"], "non_status")
        self.assertEqual(tc(conv("Is my request approved yet?", 2), "9")["class"], "status")
        # QA #1517: timing words alone are a product question; tied to their request they are status
        self.assertEqual(tc(conv("When will Dolby Atmos credits be supported?", 2), "9")["class"], "non_status")
        self.assertEqual(tc(conv("How long does a split sheet take in general?", 2), "9")["class"], "non_status")
        self.assertEqual(tc(conv("when will my request be approved", 2), "9")["class"], "status")      # 'my request' 
        # b1 270: timing words are never a status cue by themselves (no regex proximity); a status term still is
        self.assertEqual(tc(conv("how long until it is approved?", 2), "9")["class"], "non_status")
        self.assertEqual(tc(conv("how long until my request is approved?", 2), "9")["class"], "status")
        # QA #1517 / b1 270: the SINGULAR product question (and any product cue) is vetoed, whatever else it says
        r = tc(conv("When will my Dolby Atmos credit feature be supported?", 2), "9")
        self.assertEqual((r["class"], r["why"].startswith("product cue")), ("non_status", True))
        self.assertEqual(tc(conv("my request is pending - is the feature available in the app?", 2), "9")["class"], "non_status")
        self.assertEqual(tc(conv("When will my credit be supported on Spotify?", 2), "9")["class"], "non_status")
        # QA on #1920: 'immersive' is a product cue, so a product question mixed with a status one is handed off ...
        for mixed in ("Is immersive audio part of my credit request? Any update on my credit request?",
                      "Do you do immersive yet? Any update on my request?",
                      "Any update on my request? Also is immersive audio a thing on Muso"):
            r = tc(conv(mixed, 2), "9")
            self.assertEqual((r["class"], r["why"]), ("non_status", "product cue 'immersive'"), mixed)
        # ... and a customer NAMING their own role (roles.py: Immersive Mixing / Immersive Mastering) is still answered
        for role in ("Any update on my Immersive Mixing Engineer request?",
                     "Any update on my request? It is for Immersive Mastering.",
                     "any update on my immersive audio mix engineer request?"):
            self.assertEqual(tc(conv(role, 2), "9")["class"], "status", role)
        # the role carve-out excuses that one word only: a second cue in the same part still vetoes
        self.assertEqual(tc(conv("Any update on my Immersive Mixing request? Is Dolby Atmos next?", 2), "9")["class"],
                         "non_status")
        # b1 270: no filed request of theirs linked to this thread = never a status answer
        r = cs.trigger_class(conv("Is my request approved yet?", 2), "9", filed=[])
        self.assertEqual((r["class"], r["why"]), ("non_status", "no open request of theirs is linked to this thread"))
        # QA #1517 (b): a short title ("Can", "Home") never makes a product question status; a distinctive one does
        self.assertEqual(tc(conv("Can I request Dolby Atmos credits?", 2), "9", titles=["Can", "Home"])["class"], "non_status")
        self.assertEqual(tc(conv("La Flor de la Vida - nothing yet", 2), "9", titles=["La Flor de la Vida"])["class"], "status")
        self.assertEqual(tc(conv("Scandinavia is lovely", 2), "9", titles=["Scandi"])["class"], "non_status")  # not word-bounded
        # QA #1517 (a): a later customer part (a product question) means the status part is not the one to answer
        c2 = conv("where is my request?", 4)
        c2["conversation_parts"]["conversation_parts"].append({"id": "10", "part_type": "comment", "author": {"type": "user"},
                                                             "body": "also, can I add Dolby Atmos?", "created_at": now - 3 * 86400})
        r = tc(c2, "9")
        self.assertEqual((r["class"], r["why"]), ("non_status", "not the customer's latest part"))
        self.assertEqual(tc(conv("where is my request? any update?", 2), "9")["class"], "status")
        self.assertEqual(tc(conv("La Flor de la Vida - still nothing", 2), "9", titles=["La Flor de la Vida"])["class"], "status")
        ours = {"id": "8", "part_type": "comment", "author": {"type": "admin", "id": "5763097"}, "body": "Hi Jane, a quick status..."}
        # b1 19:05Z (allowlist): a reply to our note is no longer status by itself - 'ok thanks' goes to a person
        self.assertEqual(tc(conv("ok thanks, here you go", 2, prev=ours), "9")["class"], "non_status")
        r = tc(conv("where is my request?", 2), "9")
        self.assertEqual((r["part_age_d"] >= 1.9, r["part_age_d"] <= 2.1), (True, True))

    def test_send_path_singular_product_question_and_unlinked_thread_hold(self):
        # QA #1517 / b1 270, through cs.check (the send gate's call): the singular product question holds even on an
        # open, linked credit thread with nothing owed; a status question in a thread with no linked request holds too
        self.thread("215473681300330")
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = \
            "When will my Dolby Atmos credit feature be supported?"
        res = self.run_due(campaign="status-team-review", copy="teamreview")
        self.assertTrue(res["hold"], res)
        self.assertTrue(any(r.startswith("reply_due:non_status_part") and "product cue" in r for r in res["reasons"]), res)
        self.thread("215473681300331")
        self.ic.convs["215473681300331"]["conversation_parts"]["conversation_parts"][1]["body"] = "Is my request approved yet?"
        unlinked = "no open request of theirs is linked to this thread"
        # r2 is open, and no sent note of ours to this account names it: the thread has no linked request, so it holds
        self.core = [["r2", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        res = cs.check("uvn-status", "uvnstatus", UID, ["r2"], "c1", conversation="215473681300331",
                       reply_due_part="57000000001", query=self.q, ic=self.ic, fraud=lambda uid, q: [])
        self.assertTrue(any(unlinked in r for r in res["reasons"]), res)
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        # QA on #1920 (review 5884277203), the two-thread case: the account HAS a sent ask naming r1 (setUp linked it
        # in thread ...330) and has a second ask sent as a message, and this is another thread that neither opened.
        # A request named in an old ask is not filed HERE, so the status question is handed off, never answered.
        self.ask_message("880777")
        def due():
            return cs.check("uvn-status", "uvnstatus", UID, ["r1"], "c1", conversation="215473681300331",
                            reply_due_part="57000000001", query=self.q, ic=self.ic, fraud=lambda uid, q: [])
        unlinked = "no open request of theirs is linked to this thread"
        self.assertTrue(any(unlinked in r for r in due()["reasons"]))
        # the one link a message-only ask has: the customer's reply to it opens a conversation whose source id is
        # that message's id. Only then is the request it named filed in this thread.
        self.ic.convs["215473681300331"]["source"] = {"id": "880777", "author": {"type": "admin"}}
        self.assertFalse(any(unlinked in r for r in due()["reasons"]))
        # ...and only for the account that was sent it: another account's ask with that message id links nothing
        db = sqlite3.connect(cs.LEDGER)
        db.execute("UPDATE verify_messages SET account_id='4242' WHERE message_id='880777'")
        db.commit(); db.close()
        self.assertTrue(any(unlinked in r for r in due()["reasons"]))

    def test_status_team_review_reply_due_takes_the_full_path(self):
        # QA #1517 (critical): the nothing-is-needed fast path never short-circuits a reply_due answer - a closed thread,
        # a product question and a human assignee all hold status-team-review exactly as they hold the ask
        base = self.q
        self.q = lambda sql: [] if "regexp_like" in sql else base(sql)          # owes nothing (the fast path's case)
        self.ic.convs["215473681300330"]["state"] = "closed"
        self.assertIn("reply_due:thread_not_open", self.run_due(campaign="status-team-review", copy="teamreview")["reasons"])
        self.thread("215473681300330")
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "Can I request Dolby Atmos credits?"
        r = self.run_due(campaign="status-team-review", copy="teamreview")
        self.assertTrue(any(x.startswith("reply_due:non_status_part") for x in r["reasons"]), r)
        self.thread("215473681300330")
        ok = self.run_due(campaign="status-team-review", copy="teamreview")     # no document, owes nothing -> team review
        self.assertFalse(ok["hold"], ok)
        self.assertEqual(ok["reply_due"]["answer_class"]["campaign"], "status-team-review")

    def test_a_non_status_part_is_never_auto_answered(self):
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "is there a way to add Dolby Atmos?"
        res = self.run_due()
        self.assertTrue(any(r.startswith("reply_due:non_status_part") for r in res["reasons"]), res)


class ReplyDueLedgerTest(unittest.TestCase):
    """[key=reply-due] in the ledger: one answer per triggering part ever, one per thread per 48 h, and the 7-day
    status cooldown does not apply to answering."""

    def setUp(self):
        self.db = vl.connect(str(Path(tempfile.mkdtemp()) / "l.sqlite3"))

    def claim(self, rid, part="57000000001", conv="215473681300330", now=None):
        return vl.claim(self.db, user_key="l@x.com", day=(now or datetime.now(timezone.utc)).strftime("%Y-%m-%d"),
                        request_ids=[rid], message_type="comment", approved_by="U", approval_ref="ref",
                        campaign="uvn-status", user_id="298376", reply_due=part, conversation=conv, now=now)

    def sent(self, got):
        vl.finalize(self.db, message_row=int(got["message_row"]), status="sent", message_id="1", conversation_id="215473681300330")

    def test_one_answer_per_part_and_per_thread_per_48h(self):
        # a status note to this user 2 days ago: an unsolicited note would be 'recent'; the answer is not
        old = datetime.now(timezone.utc) - timedelta(days=2)
        self.sent(vl.claim(self.db, user_key="l@x.com", day=old.strftime("%Y-%m-%d"), request_ids=["x"], message_type="email",
                           approved_by="U", approval_ref="ref", campaign="status-team-review", user_id="298376", now=old))
        got = self.claim("r1")
        self.assertEqual(got["result"], "claimed", got)
        self.assertIn("reply_due:57000000001 thread:215473681300330",
                      self.db.execute("SELECT approval_ref FROM verify_messages WHERE id=?", (got["message_row"],)).fetchone()[0])
        self.sent(got)
        self.assertEqual(self.claim("r2")["result"], "already_notified")                    # same part: never again
        self.assertEqual(self.claim("r3", part="57000000009")["result"], "recent")           # same thread < 48 h
        # QA #1509: 49 h later a NEW part still meets one uvn-status note per user EVER - the answer lifts only the 7 days
        later = datetime.now(timezone.utc) + timedelta(hours=49)
        got = self.claim("r4", part="57000000009", now=later)
        self.assertEqual((got["result"], got["reason"]), ("user_done", "already_sent"), got)
        self.assertEqual(self.claim("r5", part="", conv="1")["result"] if False else
                         vl.claim(self.db, user_key="l@x.com", day="2026-10-29", request_ids=["r6"], message_type="comment",
                                  approved_by="U", approval_ref="ref", campaign="uvn-status", user_id="298376",
                                  reply_due="57000000010", conversation="")["result"], "refusal_hold")


class ReplyDueLedgerHoldsTest(unittest.TestCase):
    """QA #1509: inside claim()'s transaction a reply_due answer lifts ONLY the 7-day cooldown."""

    def test_the_90_day_ask_lock_and_proof_received_still_hold(self):
        for camp, mark, want in ((vl.GAP_ASK, None, "recently_asked"), ("status-team-review", "proof", "proof_received")):
            with self.subTest(want):
                db = vl.connect(str(Path(tempfile.mkdtemp()) / "l.sqlite3"))
                old = datetime.now(timezone.utc) - timedelta(days=2)
                g = vl.claim(db, user_key="l@x.com", day=old.strftime("%Y-%m-%d"), request_ids=["x"], message_type="email",
                             approved_by="U", approval_ref="ref", campaign=camp,
                             user_id="298376", now=old)
                vl.finalize(db, message_row=int(g["message_row"]), status="sent", message_id="1")
                if mark:
                    db.execute("UPDATE verify_messages SET proof_tagged_at=? WHERE id=?", (old.isoformat(), g["message_row"]))
                    db.commit()
                got = vl.claim(db, user_key="l@x.com", day=datetime.now(timezone.utc).strftime("%Y-%m-%d"), request_ids=["r1"],
                               message_type="comment", approved_by="U", approval_ref="ref", campaign="uvn-status",
                               user_id="298376", reply_due="57000000001", conversation="215473681300330")
                self.assertNotEqual(got["result"], "claimed", got)
                self.assertEqual(got.get("reason"), want, got)


class OnTopicTest(unittest.TestCase):
    """R9 / reply_due (QA #1509): billing and account threads are not credit threads."""

    def conv(self, title, body="hello"):
        return {"title": title, "source": {"author": {"type": "user"}, "body": body}, "conversation_parts": {"conversation_parts": []}}

    def test_billing_and_account_threads_are_off_topic(self):
        for t in ("Your payment is under review", "Account verification for billing", "Your account is in review",
                  "Credit card declined", "Refund request"):
            self.assertFalse(cs.on_topic(self.conv(t)), t)

    def test_credit_claim_merge_threads_are_on_topic(self):
        for t in ("Credit Verification", "My song credits are under review", "Profile claim", "Merge my two profiles",
                  "Split sheet attached"):
            self.assertTrue(cs.on_topic(self.conv(t)), t)

    def test_a_ticket_type_given_as_a_string_or_an_object_is_read_never_a_crash(self):
        # prod (10-30): some conversations carry ticket.ticket_type as a bare string; comm_state raised on them
        for tt, want in (("Credit verification", True), ({"name": "Credit verification"}, True), ("Billing", False), (None, False)):
            c = self.conv("hello")
            c["ticket"] = {"ticket_type": tt}
            self.assertEqual(cs.on_topic(c), want, tt)


    def test_claim_and_proof_of_need_a_credit_context_and_billing_vetoes_a_bare_credit(self):
        # QA #1418 (b1 16:00Z)
        for t in ("Refund claim for a credit card charge", "I was charged for credits", "Claim for my payment",
                  "proof of purchase", "Your subscription credits"):
            self.assertFalse(cs.on_topic(self.conv(t)), t)
        for t in ("Claim my artist profile", "proof of my role", "about my credits", "credit request for my song"):
            self.assertTrue(cs.on_topic(self.conv(t)), t)

    def test_merge_needs_a_profile_context_and_billing_vetoes_strong_terms(self):
        # QA #1418 (07:06Z, reproduced): bare 'merge' made a billing thread on-topic
        for t in ("Please merge my invoices", "merge the two payments", "My song credits - and I need a refund",
                  "merge my accounts and refund the charge"):
            self.assertFalse(cs.on_topic(self.conv(t)), t)
        for t in ("Can you merge my accounts?", "merge these two artist pages", "my profiles merged wrong",
                  "duplicate profile", "Merge my two profiles", "merging duplicates"):
            self.assertTrue(cs.on_topic(self.conv(t)), t)

    def test_the_gate_carries_the_same_patterns(self):
        import re as _re
        gate = (Path(__file__).resolve().parents[1] / "intercom-verify-request.sh").read_text()
        strong = _re.search(r"^TOPIC_STRONG='(.*)'$", gate, _re.M).group(1).replace("\\\\", "\\")
        billing = _re.search(r"^TOPIC_BILLING='(.*)'$", gate, _re.M).group(1).replace("\\\\", "\\")
        self.assertEqual(strong, cs.TOPIC_STRONG_RE.pattern)
        self.assertEqual(billing, cs.TOPIC_BILLING_RE.pattern)

    def test_billing_thread_is_never_reply_due(self):
        ic = FakeIntercom()
        ic.convs["5"] = {"id": "5", "title": "Your payment is under review", "state": "open",
                         "source": {"id": "0", "author": {"type": "user"}, "body": "why is my payment under review?"},
                         "contacts": {"contacts": [{"id": "c1"}]},
                         "conversation_parts": {"conversation_parts": [
                             {"id": "57000000001", "part_type": "comment", "author": {"type": "user"},
                              "body": "any update?", "created_at": time.time() - 3 * 86400}]}}
        self.assertIn("reply_due:R9_thread_not_about_credits", cs.reply_due("5", "c1", "57000000001", ic))


class TicketTypeShapeTest(unittest.TestCase):
    """R9 reads the ticket type in any shape Intercom returns; a string or missing one never crashes the check."""

    def test_object_string_and_missing_ticket_types(self):

        self.assertTrue(cs.on_topic({"ticket": {"ticket_type": {"name": "Credit verification"}}}))
        self.assertTrue(cs.on_topic({"ticket": {"ticket_type": "Credit claim"}}))
        self.assertFalse(cs.on_topic({"ticket": {"ticket_type": "Billing"}}))
        self.assertFalse(cs.on_topic({"ticket": "123", "title": "Hello"}))
        self.assertFalse(cs.on_topic({"ticket": None}))
        self.assertTrue(cs.on_topic({"ticket": {"ticket_type": None}, "title": "my credits"}))


class NothingNeededBodyTest(unittest.TestCase):
    """p1 / r5 rule gap: a nothing-needed line in the rendered body of ANY campaign holds a user who still owes proof."""

    def test_body_flag_holds_an_owes_proof_user_outside_the_family(self):
        CommStateTest.setUp(self)
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl"); Path(cs.ACCOUNT_HOLDS).write_text("")
        core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        def q(sql):
            if "proof_required_owed" in sql:
                return [["0", "0"]]
            if "regexp_like" in sql:
                return [["user_verification_needed", "false"]]
            return [list(r) for r in core] if "credit_requests" in sql else []
        plain = cs.check("withdrawal-confirm", "withdrawal", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lambda u, qq: [])
        self.assertFalse(any(r.startswith("nothing_needed_body") for r in plain["reasons"]), plain)
        res = cs.check("withdrawal-confirm", "withdrawal", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lambda u, qq: [],
                       nothing_needed_body=True)
        self.assertTrue(res["hold"], res)
        self.assertIn("nothing_needed_body:owes:uvn", res["reasons"])


class DvUnverifiableOwesTest(unittest.TestCase):
    """l1 [key=nm-batch2-unverifiable]: an 'unverifiable' latest filing on an open unverified/processing row = owes
    proof, so the owes-nothing gate HOLDS /k (and every nothing-needed body) for that user."""

    def setUp(self):
        CommStateTest.setUp(self)
        self.d = Path(tempfile.mkdtemp())
        cs.ACCOUNT_HOLDS = str(self.d / "h.jsonl"); Path(cs.ACCOUNT_HOLDS).write_text("")
        cs.DV_STORE = str(self.d / "dv.sqlite")
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY, at TEXT, user_id INTEGER, request_id TEXT, outcome TEXT)")
        db.executemany("INSERT INTO dv_outcomes (at, user_id, request_id, outcome) VALUES (?,?,?,?)", [
            ("2026-10-20", UID, "R1", "verified"), ("2026-10-25", UID, "R1", "unverifiable"),   # latest = unverifiable
            ("2026-10-25", UID, "r2", "unverifiable"), ("2026-10-26", UID, "r2", "verified")])  # latest = verified
        db.commit(); db.close()
        self.open_ids = ["r1"]

    def q(self, sql):
        if "proof_required_owed" in sql:
            return [["0", "0"]]
        if "regexp_like" in sql:
            return [["unverified", "false"]]                        # only an unverified row, no review rule fired
        if "lower(CAST(id AS varchar)) IN (" in sql:
            return [[r] for r in self.open_ids if f"'{r}'" in sql]
        return []

    def test_unverifiable_open_row_owes_and_k_is_held(self):
        self.assertEqual(cs.owes_proof(UID, self.q), ["owes:dv_unverifiable"])
        res = cs.check("status-team-review", "teamreview", UID, ["r1"], "c1", query=self.q, ic=self.ic, fraud=lambda u, qq: [])
        self.assertEqual((res["hold"], res["state"]), (True, "owes_proof"), res)

    def test_a_later_verified_read_or_a_closed_row_does_not_owe(self):
        self.open_ids = []                                          # r1 no longer open (decided): nothing owed
        self.assertEqual(cs.owes_proof(UID, self.q), [])
        Path(cs.DV_STORE).unlink()                                  # no reads yet: no dv facts
        self.open_ids = ["r1"]
        self.assertEqual(cs.owes_proof(UID, self.q), [])

    def test_an_unreadable_store_fails_closed(self):
        Path(cs.DV_STORE).write_text("not sqlite")
        with self.assertRaises(cs.Unknown):
            cs.owes_proof(UID, self.q)


class ApprovalPathOwesNothingTest(unittest.TestCase):
    """r5 / p1 [h2 452] (b): UVN rows the approval path admits (uvn_status.approval_path_admits - the same predicate)
    owe nothing, so /k reads true for that user; any admit condition failing, an open ask, a document on file, or an
    unjudgeable row keeps them owing (red)."""
    ADMIT = {"is_approved": True, "total_risk_percent": 12,
             "rule_risk_percent": {"review_role_credited_to_other_at_trusted_source": 0}}

    def setUp(self):
        CommStateTest.setUp(self)
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl"); Path(cs.ACCOUNT_HOLDS).write_text("")
        self.vd, self.pop, self.broken = dict(self.ADMIT), "5", False

    def q(self, sql):
        if "proof_required_owed" in sql:
            return [["0", "0"]]
        if "regexp_like" in sql:
            return [["user_verification_needed", "false"]]
        if "spotifytracktitle" in sql:
            if self.broken:
                raise cs.Unknown("replica down")
            return [["ra", str(UID), "p1", "t1", "Song", '[{"name":"Art"}]', "{Mixing}", self.pop,
                     json.dumps(self.vd), "{}", "2026-10-20 00:00:00"]]
        return []

    def k(self):
        return cs.check("status-team-review", "teamreview", UID, ["ra"], "c1", query=self.q, ic=self.ic, fraud=lambda u, qq: [])

    def test_an_admitting_uvn_row_owes_nothing_and_k_goes(self):
        self.assertEqual(cs.owes_proof(UID, self.q), [])
        res = self.k()
        self.assertEqual((res["hold"], res["state"], res["reasons"]), (False, "owes_nothing", ["owes_nothing:approval_path"]))

    def test_any_admit_condition_failing_still_owes(self):
        for name, vd, pop in (("risk 45", dict(self.ADMIT, total_risk_percent=45), "5"),
                              ("not validator-approved", dict(self.ADMIT, is_approved=False), "5"),
                              ("popularity 60", dict(self.ADMIT), "60")):
            with self.subTest(name):
                self.vd, self.pop = vd, pop
                self.assertEqual(cs.owes_proof(UID, self.q), ["owes:uvn"])
                self.assertTrue(self.k()["hold"])

    def test_an_open_ask_a_document_or_an_unjudgeable_row_still_owes(self):
        self.broken = True
        self.assertEqual(cs.owes_proof(UID, self.q), ["owes:uvn"])
        self.broken = False
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, 's', '2026-10-20T00:00:00Z');")
        self.assertEqual(cs.owes_proof(UID, self.q), ["owes:uvn"])
        sqlite3.connect(cs.PROOF_STORE).executescript(f"DELETE FROM proof_intake WHERE user_id = {UID};")
        db = vl.connect(cs.LEDGER)
        c = vl.claim(db, campaign="uvn-status", user_key="a@x.com", day="2026-10-25", request_ids=["ra"], message_type="email",
                     approved_by="U", approval_ref="r", user_id=str(UID))
        vl.finalize(db, message_row=c["message_row"], status="sent", message_id="1"); db.close()
        self.assertEqual(cs.owes_proof(UID, self.q), ["owes:open_ask", "owes:uvn"])

class NeedAskRulesTest(CommStateTest):
    """L11c (proof-need-ask), p1 ruling 096: only at 'checked' for the named document; anything newer holds."""
    SHA = "a" * 64
    DOC_AT = (datetime.now(timezone.utc) - timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
    DOC_EPOCH = datetime.fromisoformat(DOC_AT.replace("Z", "+00:00")).timestamp()

    def checked(self, sha=None, need="readable_document", outcome="unverifiable", rid="r1", at=None):
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome) VALUES (?,?,?,?,?)",
                   (UID, rid, sha or self.SHA, need, outcome))
        db.commit(); db.close()
        db = sqlite3.connect(cs.PROOF_STORE)
        # one intake per arrived file (a dv row per request does not mean another upload)
        if not db.execute("SELECT 1 FROM proof_intake WHERE user_id=? AND file_sha256=?", (UID, sha or self.SHA)).fetchone():
            db.execute("INSERT INTO proof_intake VALUES (?,?,?)", (UID, sha or self.SHA, at or self.DOC_AT))
        db.commit(); db.close()

    def ask(self, **kw):
        self.core = self.core or [["r1", "user_verification_needed", "", ""]]
        doc_sha, doc_at = kw.pop("doc_sha", self.SHA), kw.pop("doc_at", self.DOC_AT)
        if "doc_intakes" not in kw:
            # the builder's binding: each named document -> its FIRST arrival's intake (the one that was read)
            db = sqlite3.connect(cs.PROOF_STORE)
            kw["doc_intakes"] = {}
            for sha in doc_sha.split(","):
                r = db.execute("SELECT 'rowid:' || rowid FROM proof_intake WHERE user_id=? AND lower(file_sha256)=? "
                               "ORDER BY received_at, rowid LIMIT 1", (UID, sha.lower())).fetchone()
                if r:
                    kw["doc_intakes"][sha.lower()] = r[0]
            db.close()
        return self.run_("proof-need-ask", "proofneed", doc_sha=doc_sha, doc_at=doc_at,
                         need_code=kw.pop("need_code", "readable_document"), **kw)

    def run_(self, campaign="credit-hold-status", copy="credithold", keys=("r1",), conversation="", fraud=(), **kw):
        return cs.check(campaign, copy, UID, list(keys), "c1", conversation=conversation,
                        query=lambda sql: [list(r) for r in self.core] if "credit_requests" in sql else [],
                        ic=self.ic, fraud=lambda uid, q: list(fraud), **kw)

    def test_checked_document_with_a_need_sends_and_a_document_on_file_never_holds_it(self):
        self.checked()
        res = self.ask()
        self.assertEqual((res["hold"], res["state"]), (False, "checked"), res)

    def test_not_checked_holds(self):
        res = self.ask()                                   # no dv_outcomes row at all
        self.assertTrue(any(r.startswith("not_checked") for r in res["reasons"]))
        self.setUp(); self.checked(outcome="verified")     # verified, not a need
        self.assertTrue(self.ask()["hold"])
        self.setUp(); self.checked(need="")                # no need code
        self.assertTrue(self.ask()["hold"])
        self.setUp(); self.checked(rid="r2")               # another request
        self.assertTrue(self.ask()["hold"])
        # [key=l11c-plural]: one message names several requests; EVERY one needs its own need row
        self.setUp(); self.checked()
        self.core = [["r1", "user_verification_needed", "", ""], ["r2", "user_verification_needed", "", ""]]
        res = self.ask(keys=("r1", "r2"))
        self.assertTrue(res["hold"])
        self.assertIn("not_checked:r2", res["reasons"])
        self.checked(sha="b" * 64, rid="r2")              # r2 checked from another document
        self.assertIn("not_checked:r2", self.ask(keys=("r1", "r2"))["reasons"])   # ... that the message does not name
        self.assertFalse(self.ask(keys=("r1", "r2"), doc_sha=f"{self.SHA},{'b' * 64}",
                                  doc_map={"r1": self.SHA, "r2": "b" * 64})["hold"])   # both named, each its own: it goes

    def test_qa_round4_repro_named_document_rechecked_while_an_older_document_keeps_the_need(self):
        # QA #1418 round 4, exact case: the NAMED document is re-checked to verified; an OLDER document of the same
        # request still carries the same need -> the ask about the named document must hold
        old = "e" * 64
        older = (datetime.now(timezone.utc) - timedelta(days=12)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.checked(sha=old, at=older)                             # older document, same need, still unverifiable
        self.checked()                                              # the named document
        self.assertFalse(self.ask()["hold"])
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, at) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", self.SHA, "", "verified", "2026-10-28T00:00:00Z"))
        db.commit(); db.close()
        res = self.ask()
        self.assertTrue(res["hold"])
        self.assertIn("not_checked:r1", res["reasons"])

    def test_qa_1418_every_named_document_is_rechecked_not_only_the_newest(self):
        # QA #1418 (23:39Z): r1 has two same-day documents, A (older) and B (newest; doc_map r1 -> B). Both unverifiable:
        # the ask goes. A is then re-checked to verified: "the documents ... can't be checked" is false -> hold.
        a = "c" * 64
        earlier = (datetime.strptime(self.DOC_AT, "%Y-%m-%dT%H:%M:%SZ") - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.checked(sha=a, at=earlier)
        self.checked()
        both = {"doc_sha": f"{a},{self.SHA}", "doc_map": {"r1": self.SHA}}
        self.assertFalse(self.ask(**both)["hold"], self.ask(**both))
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, at) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", a, "", "verified", "2026-10-28T00:00:00Z"))
        db.commit(); db.close()
        res = self.ask(**both)
        self.assertTrue(res["hold"], res)
        self.assertIn("named_document_rechecked:cccccccc", json.dumps(res["reasons"]))

    def test_r5_repro_the_email_path_keeps_the_filing_part_evidence(self):
        # r5 / QA #1418 (L1990): R9 (or a closed thread) moves delivery to email and no thread is judged; the filing
        # part must still be recognised, else the document's own part reads as newer and the email path never sends
        self.checked()
        self.ic.convs["9"] = {"id": "9", "source": {"author": {"type": "user"}, "attachments": [{"name": "d.jpg"}],
                                                    "created_at": self.DOC_EPOCH}, "conversation_parts": {"conversation_parts": []}}
        self.assertIn("newer_after_document", json.dumps(self.ask(conversation="")["reasons"]))      # the bug
        self.assertFalse(self.ask(conversation="", filing_conversation="9")["hold"])                 # the fix
        # ... and a real later attachment still holds on the email path
        self.ic.convs["9"]["conversation_parts"]["conversation_parts"].append(
            {"author": {"type": "user"}, "attachments": [{"name": "y.pdf"}], "created_at": self.DOC_EPOCH + 60})
        self.assertIn("newer_after_document", json.dumps(self.ask(conversation="", filing_conversation="9")["reasons"]))

    def test_r5_repro_each_request_is_judged_on_its_own_document(self):
        # r5 / QA #1418 (L350): r1's own document is A, r2's is B; B carries the need for r1 too - that must not
        # satisfy r1 (A was re-checked and no longer has it)
        b = "b" * 64
        self.checked(); self.checked(sha=b, rid="r2"); self.checked(sha=b, rid="r1")
        self.core = [["r1", "user_verification_needed", "", ""], ["r2", "user_verification_needed", "", ""]]
        both = f"{self.SHA},{b}"
        own = {"r1": self.SHA, "r2": b}
        self.assertFalse(self.ask(keys=("r1", "r2"), doc_sha=both, doc_map=own)["hold"])
        db = sqlite3.connect(cs.DV_STORE)                      # r1's own document A re-checked: verified
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, at) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", self.SHA, "", "verified", "2026-10-28T00:00:00Z"))
        db.commit(); db.close()
        res = self.ask(keys=("r1", "r2"), doc_sha=both, doc_map=own)
        self.assertIn("not_checked:r1", res["reasons"])        # B's row does not stand in for r1
        self.assertIn("not_checked:r2", self.ask(keys=("r1", "r2"), doc_sha=both, doc_map={"r1": b})["reasons"])  # unmapped
        with self.assertRaises(cs.Unknown):                    # several named documents, no map: cannot judge
            self.ask(keys=("r1", "r2"), doc_sha=both)

    def test_qa_round4_repro_a_second_attachment_in_the_same_second_holds(self):
        # QA #1418 round 4, exact case: a correction attachment in the SAME second as the filing part, same thread.
        # No stable part id is stored (provenance = cache path / attachment index), so two such parts = ambiguous = hold
        self.checked()
        filing = {"author": {"type": "user"}, "attachments": [{"name": "d.jpg"}], "created_at": self.DOC_EPOCH}
        self.ic.convs["9"] = {"id": "9", "source": filing, "conversation_parts": {"conversation_parts": [
            {"author": {"type": "user"}, "attachments": [{"name": "fix.pdf"}], "created_at": self.DOC_EPOCH}]}}
        self.assertIn("newer_after_document", json.dumps(self.ask(conversation="9")["reasons"]))
        self.setUp(); self.checked()
        self.ic.convs["9"] = {"id": "9", "source": filing, "conversation_parts": {"conversation_parts": []}}
        self.assertFalse(self.ask(conversation="9")["hold"])           # the filing part alone is not news

    def test_the_latest_dv_row_per_request_decides(self):
        # the unit is (request, document): r5 (re-checked document) + p1 156 / b1 153 (other documents do not cancel)
        self.checked()
        self.assertFalse(self.ask()["hold"])
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, at) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", "c" * 64, "", "verified", "2026-10-28T00:00:00Z"))
        db.commit(); db.close()
        res = self.ask()
        self.assertFalse(res["hold"], res)        # another document's verified read does not cancel this one (p1 156)
        # the SAME document re-checked since the cut (its latest row verified): no longer askable (r5)
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, at) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", self.SHA, "", "verified", "2026-10-28T00:00:00Z"))
        db.commit(); db.close()
        res = self.ask()
        self.assertTrue(res["hold"])
        self.assertIn("not_checked:r1", res["reasons"])

    def test_anything_newer_than_the_document_holds(self):
        self.checked()
        later = (datetime.now(timezone.utc) - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, '{'c' * 64}', '{later}');")
        self.assertIn("newer_document", json.dumps(self.ask()["reasons"]))
        # the SAME file arriving again later (another intake of it) also holds: arrival, not content (QA #1418)
        self.setUp(); self.checked()
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, '{self.SHA}', '{later}');")
        self.assertIn("newer_document", json.dumps(self.ask()["reasons"]))
        # an Intercom customer message, or attachment, after the document
        for part in ({"author": {"type": "user"}, "body": "here is the split sheet", "created_at": self.DOC_EPOCH + 3600},
                     {"author": {"type": "user"}, "body": "", "attachments": [{"name": "x.pdf"}], "created_at": self.DOC_EPOCH + 3600}):
            self.setUp(); self.checked()
            self.ic.convs["9"] = {"id": "9", "source": {"author": {"type": "user"}, "created_at": self.DOC_EPOCH},
                                  "conversation_parts": {"conversation_parts": [part]}}
            self.assertIn("newer_after_document", json.dumps(self.ask()["reasons"]))
        # QA #1418 (no slack window): a correction or another file 1-5 s after the document holds
        for dt in (1, 3, 5):
            for part in ({"author": {"type": "user"}, "body": "sorry, wrong file", "created_at": self.DOC_EPOCH + dt},
                         {"author": {"type": "user"}, "body": "", "attachments": [{"name": "y.pdf"}],
                          "created_at": self.DOC_EPOCH + dt}):
                self.setUp(); self.checked()
                self.ic.convs["9"] = {"id": "9", "source": {"author": {"type": "user"}, "attachments": [{"name": "d.jpg"}],
                                                            "created_at": self.DOC_EPOCH},
                                      "conversation_parts": {"conversation_parts": [part]}}
                self.assertTrue(self.ask(conversation="9")["hold"], (dt, part))
        # QA #1418 06:34Z: a TEXT correction in the SAME second as the filing attachment (its own part, after or before
        # it by part id) holds the ask - same-second text counts (fail closed)
        for pid in ("2", "0"):
            self.setUp(); self.checked()
            self.ic.convs["9"] = {"id": "9", "source": {"id": "1", "author": {"type": "user"}, "attachments": [{"name": "d.jpg"}],
                                                        "created_at": self.DOC_EPOCH},
                                  "conversation_parts": {"conversation_parts": [
                                      {"id": pid, "part_type": "comment", "author": {"type": "user"}, "body": "sorry, wrong file",
                                       "created_at": self.DOC_EPOCH}]}}
            res = self.ask(conversation="9")
            self.assertTrue(res["hold"], (pid, res))
            self.assertIn("intercom_reply_after_ask", json.dumps(res["reasons"]))
        # another attachment in ANOTHER conversation at the same second is not the filing event: holds
        self.setUp(); self.checked()
        self.ic.convs["8"] = {"id": "8", "source": {"author": {"type": "user"}, "attachments": [{"name": "z.pdf"}],
                                                    "created_at": self.DOC_EPOCH}, "conversation_parts": {"conversation_parts": []}}
        self.ic.convs["9"] = {"id": "9", "source": {"author": {"type": "user"}, "attachments": [{"name": "d.jpg"}],
                                                    "created_at": self.DOC_EPOCH}, "conversation_parts": {"conversation_parts": []}}
        self.assertTrue(self.ask(conversation="9")["hold"])
        # the document's own part (its filing conversation, its second) and anything before it do not
        self.setUp(); self.checked()
        self.ic.convs["9"] = {"id": "9", "source": {"author": {"type": "user"}, "attachments": [{"name": "d.jpg"}],
                                                    "created_at": self.DOC_EPOCH},
                              "conversation_parts": {"conversation_parts": [
                                  {"author": {"type": "user"}, "body": "earlier", "created_at": self.DOC_EPOCH - 99}]}}
        self.assertFalse(self.ask(conversation="9")["hold"])

    def test_doc_at_must_be_an_arrival_of_the_named_document(self):
        # QA #1418: day-1 checked document, day-2 re-upload, payload claims day 3: the day-2 upload must not look older
        self.checked()
        day2 = (datetime.now(timezone.utc) - timedelta(days=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        day3 = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, '{self.SHA}', '{day2}');")
        res = self.ask(doc_at=day3)
        self.assertTrue(res["hold"], res)
        self.assertIn("doc_at_not_the_arrival_of_the_named_intake", json.dumps(res["reasons"]))
        # the true arrival of the named document passes this check
        self.setUp(); self.checked()
        self.assertFalse(self.ask(doc_at=self.DOC_AT)["hold"])

    def test_qa_repro_a_same_sha_reupload_never_borrows_the_earlier_intakes_read(self):
        # QA #1418 / b1 272, exact case, prod-shaped stores (intake ids on both sides): the 10-18 intake was read
        # (unverifiable, readable_document); the identical file is re-uploaded 10-26 and never read
        for path, table in ((cs.PROOF_STORE, "proof_intake"), (cs.DV_STORE, "dv_outcomes")):
            db = sqlite3.connect(path); db.execute(f"ALTER TABLE {table} ADD COLUMN intake_id TEXT"); db.commit(); db.close()
        d18, d26 = "2026-10-18T09:00:00Z", "2026-10-26T09:00:00Z"
        db = sqlite3.connect(cs.PROOF_STORE)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, intake_id) VALUES (?,?,?,?)", (UID, self.SHA, d18, "42:i18"))
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, intake_id) VALUES (?,?,?,?)", (UID, self.SHA, d26, "42:i26"))
        db.commit(); db.close()
        db = sqlite3.connect(cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, intake_id) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", self.SHA, "readable_document", "unverifiable", "42:i18"))
        db.commit(); db.close()
        # the payload names the 10-26 upload: that intake was never read -> not checked
        res = self.ask(doc_at=d26, doc_intakes={self.SHA: "42:i26"})
        self.assertTrue(res["hold"], res)
        self.assertIn("not_checked:r1", res["reasons"])
        # 10-26 arrival time but the 10-18 intake named: the time is not that intake's arrival -> holds
        res = self.ask(doc_at=d26, doc_intakes={self.SHA: "42:i18"})
        self.assertIn("doc_at_not_the_arrival_of_the_named_intake", json.dumps(res["reasons"]))
        # the 10-18 intake, honestly named: checked, but the 10-26 re-upload is newer -> the ask still waits
        res = self.ask(doc_at=d18, doc_intakes={self.SHA: "42:i18"})
        self.assertNotIn("not_checked:r1", res["reasons"])
        self.assertIn("newer_document:proof_intake", json.dumps(res["reasons"]))
        # no named intake at all: unbound, never checked (fail closed)
        self.assertIn("not_checked:r1", self.ask(doc_at=d18, doc_intakes={})["reasons"])

    def test_qa1513_a_different_intake_in_the_same_second_holds(self):
        # QA #1513: whole-second times cannot order two intakes; another intake in the SAME second as the named
        # document (e.g. an email-filed document then a second file at once) is 'anything newer' - the ask waits
        self.checked()
        self.assertFalse(self.ask()["hold"])
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, '{'d' * 64}', '{self.DOC_AT}');")
        res = self.ask()
        self.assertIn("newer_document:proof_intake", json.dumps(res["reasons"]))
        # the shared predicate itself: a named intake in the same second is not newer; another one is; later always is
        self.assertFalse(cs.newer_intake("2026-10-18T09:30:00Z", [("2026-10-18T09:30:00Z", "i1")], {"i1"}))
        self.assertTrue(cs.newer_intake("2026-10-18T09:30:00Z", [("2026-10-18T09:30:00Z", "i2")], {"i1"}))
        self.assertTrue(cs.newer_intake("2026-10-18T09:30:00Z", [("2026-10-18T09:30:01Z", "i1")], {"i1"}))
        self.assertFalse(cs.newer_intake("2026-10-18T09:30:00Z", ["2026-10-18T09:30:00Z"]))      # legacy bare time

    def test_the_need_must_match_the_documents_latest_row(self):
        # QA #1418: the latest row of the document must carry the need THIS message is about
        self.checked(need="readable_document")
        self.assertFalse(self.ask(need_code="readable_document")["hold"])
        self.assertIn("not_checked:r1", self.ask(need_code="counterparty_signed_or_registered")["reasons"])
        db = sqlite3.connect(cs.DV_STORE)     # the same document re-checked: its need changed
        db.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome, at) VALUES (?,?,?,?,?,?)",
                   (UID, "r1", self.SHA, "counterparty_signed_or_registered", "unverifiable", "2026-10-28T00:00:00Z"))
        db.commit(); db.close()
        self.assertIn("not_checked:r1", self.ask(need_code="readable_document")["reasons"])
        self.assertFalse(self.ask(need_code="counterparty_signed_or_registered")["hold"])
        with self.assertRaises(cs.Unknown):
            self.ask(need_code="")

    def test_decided_told_seven_days_and_the_filing_thread_rules_hold(self):
        self.checked(); self.core = [["r1", "rejected", "", ""]]
        self.assertIn("decided_or_told", self.ask()["reasons"])
        self.setUp(); self.checked()
        self.note("status-doc-received", at=(datetime.now(timezone.utc) - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertTrue(any(r.startswith("messaged_7d") for r in self.ask()["reasons"]))   # receipt 3 days ago
        self.setUp(); self.checked()
        self.note("status-doc-received", at=(datetime.now(timezone.utc) - timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertFalse(self.ask()["hold"])               # the >= 7-day 'checked' follow-up after a receipt
        self.setUp(); self.checked()
        now = datetime.now(timezone.utc).timestamp()
        self.ic.convs["7"] = {"id": "7", "state": "closed", "source": {"author": {"type": "user"}, "created_at": now - 86400},
                              "conversation_parts": {"conversation_parts": []}}
        # l1 [key=l11c-asks]: a CLOSED filing thread does not hold the per-need ask (the gate sends it by email)
        res = self.ask(conversation="7")
        self.assertFalse(res["hold"], res)
        # ... but a thread where the matter was closed as "sorted" still holds it
        self.ic.convs["7"]["conversation_parts"]["conversation_parts"] = [
            {"author": {"type": "user"}, "body": "doc", "created_at": now - 3600},
            {"author": {"type": "admin"}, "part_type": "comment", "body": "Great news, it's all sorted now!", "created_at": now - 1800}]
        self.ic.convs["7"]["state"] = "open"
        self.assertIn("R7_thread_resolved", self.ask(conversation="7")["reasons"])
        self.ic.convs["7"]["conversation_parts"]["conversation_parts"] = []
        self.ic.convs["7"]["source"]["created_at"] = now - 40 * 86400
        self.assertIn("R6_stale_thread", self.ask(conversation="7")["reasons"])

    def test_no_document_named_is_unknown(self):
        with self.assertRaises(cs.Unknown):
            self.ask(doc_sha="")


class ProofRequiredOwesTest(unittest.TestCase):
    """v1 STOP-CLASS (10-31 03:12Z): /k told 21 of 22 users 'with our team for review' while their unverified rows said
    proof_required=true - they OWE proof. Such a row owes (unless core marks a review stage), so /k and every
    nothing-needed body are held and the user goes to the ask class; a pending fresh DSP capture holds too."""

    def setUp(self):
        CommStateTest.setUp(self)
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl"); Path(cs.ACCOUNT_HOLDS).write_text("")
        self.pr = ["1", "0"]

    def q(self, sql):
        if "proof_required_owed" in sql:
            return [self.pr]
        if "regexp_like" in sql:
            return [["unverified", "false"]]                 # the 21's shape: unverified, no review rule fired
        return []

    def k(self):
        return cs.check("status-team-review", "teamreview", UID, ["r1"], "c1", query=self.q, ic=self.ic, fraud=lambda u, qq: [])

    def test_proof_required_owes_and_k_is_held(self):
        self.assertEqual(cs.owes_proof(UID, self.q), ["owes:proof_required"])
        res = self.k()
        self.assertEqual((res["hold"], res["state"]), (True, "owes_proof"), res)
        self.assertIn("owes:proof_required", res["reasons"])

    def test_a_pending_fresh_capture_holds_and_a_clean_user_goes(self):
        self.pr = ["0", "1"]
        self.assertEqual(cs.owes_proof(UID, self.q), ["owes:fresh_capture_pending"])
        self.pr = ["0", "0"]
        self.assertEqual(cs.owes_proof(UID, self.q), [])
        self.assertFalse(self.k()["hold"])

    def test_an_unreadable_answer_fails_closed(self):
        self.pr = ["x"]
        with self.assertRaises(cs.Unknown):
            cs.owes_proof(UID, self.q)


class ReplyDueThreadTest(CommStateTest):
    """Fable [key=lamberto-reply-due] 238/240 + r5: prior_note and the human-assignee states, read from the thread."""
    CONV = "215473681300330"

    def thread(self, *, assignee=None, parts=(), opener="admin"):
        now = time.time()
        self.ic.convs[self.CONV] = {
            "id": self.CONV, "created_at": now - 200 * 86400, "admin_assignee_id": assignee,
            "source": {"id": "0", "author": {"type": opener, "id": "5344997" if opener == "admin" else "c1"}},
            "contacts": {"contacts": [{"id": "c1"}]}, "conversation_parts": {"conversation_parts": list(parts)}}

    def part(self, pid, typ, aid, body, age_h, ptype="comment"):
        return {"id": pid, "part_type": ptype, "author": {"type": typ, "id": aid}, "body": body,
                "created_at": time.time() - age_h * 3600}

    def facts(self, part="56871591200"):
        return cs.reply_due_thread(self.CONV, self.ic, part=part)

    def test_the_bot_set_is_caroline_only(self):
        self.assertEqual(cs.GATE_BOT_ADMINS, frozenset({"5763097"}))

    def test_prior_note_only_from_our_nothing_needed_line(self):
        line = "Hi Lamberto, a quick status update: we're reviewing your credit request. Nothing is needed from you right now."
        self.thread(parts=[self.part("56450261657", "admin", "5763097", line, 250)])
        pn = self.facts()["prior_note"]
        self.assertEqual((pn["part"], pn["campaign"]), ("56450261657", "unledgered (#1510 backfill class)"))
        # another wording, or a HUMAN admin saying it, or an internal note: no prior note
        for prt in (self.part("1", "admin", "5763097", "we're reviewing your request", 250),
                    self.part("1", "admin", "5465657", line, 250),
                    self.part("1", "admin", "5763097", line, 250, ptype="note")):
            self.thread(parts=[prt])
            self.assertIsNone(self.facts()["prior_note"], prt)
        # QA #1517: a ledgered note with NO matching comment in the thread is not evidence (no prior note); with the
        # comment present, the ledger labels its campaign
        db = vl.connect(cs.LEDGER)
        g = vl.claim(db, user_key="l@x.com", day="2026-10-19", request_ids=["r1"], message_type="comment",
                     approved_by="U", approval_ref="ref", campaign="status-team-review", user_id="298376")
        vl.finalize(db, message_row=int(g["message_row"]), status="sent", message_id="777", conversation_id=self.CONV)
        db.close()
        self.thread(parts=[])
        self.assertIsNone(self.facts()["prior_note"])
        self.thread(parts=[self.part("777", "admin", "5763097", line, 250)])
        self.assertEqual(self.facts()["prior_note"]["campaign"], "status-team-review")

    def handoff_row(self, age_h, kind="handoff"):
        db = vl.connect(cs.LEDGER)
        at = datetime.now(timezone.utc) - timedelta(hours=age_h)
        # the gate's shapes: a handoff is from = to = the assigned human; a reassign moves the thread to Caroline's admin
        vl.thread_event(db, kind=kind, conversation=self.CONV, from_admin="5465657",
                        to_admin="5465657" if kind == "handoff" else "5763097", note_part="900",
                        reply_due_part="56871591200", request_ids=["r1"], user_id="298376", approved_by="U",
                        approval_ref="ref", now=at)
        db.close()

    def test_a_handoff_of_part_a_never_stands_in_for_a_new_part_b(self):
        # QA #1517: part A (56871591200) was handed off 50 h ago; the customer now has a DIFFERENT unanswered part B.
        # A's note is not B's: B gets its own handoff note first, never a straight reassign+answer
        self.thread(assignee="5465657", parts=[self.part("1", "admin", "5465657", "looking into it", 200)])
        self.handoff_row(50)
        self.assertEqual(self.facts()["assignee"]["action"], "reassign+answer")              # A's own 48 h elapsed
        self.assertEqual(self.facts(part="57000000099")["assignee"]["action"], "handoff")    # B: its own note first

    def test_a_truncated_history_is_unknown_never_a_missing_prior_note(self):
        # QA #1517 (c): > 500 parts -> the earlier nothing-needed line may be out of view: fail closed
        self.thread(parts=[self.part(str(i), "admin", "5763097", "hi", 300) for i in range(500)])
        with self.assertRaises(cs.Unknown):
            self.facts()
        self.thread(parts=[self.part("1", "admin", "5763097", "hi", 300)])
        self.ic.convs[self.CONV]["conversation_parts"]["total_count"] = 812
        with self.assertRaises(cs.Unknown):
            self.facts()

    def test_human_assignee_states(self):
        cust = self.part("56871591200", "user", "c1", "This track has been under review for months now.", 100)
        tags = self.part("2", "admin", "5465657", "", 5, ptype="conversation_tags_updated")     # recent, but not the human writing
        self.thread(assignee=5465657, parts=[cust, tags])
        a = self.facts()["assignee"]
        self.assertEqual((a["id"], a["action"]), ("5465657", "handoff"))
        self.handoff_row(10)                                                     # note 10 h ago: the human has 48 h
        self.assertEqual(self.facts()["assignee"]["action"], "wait")
        self.setUp(); self.thread(assignee=5465657, parts=[cust]); self.handoff_row(50)
        a = self.facts()["assignee"]
        self.assertEqual((a["action"], a["handoff_part"], a["human_replied_after"]), ("reassign+answer", "900", False))
        # the human replied after the note (and > 48 h ago, so only the after-the-note rule can skip it); any human counts
        self.setUp(); self.handoff_row(100)
        self.thread(assignee=5465657, parts=[cust, self.part("3", "admin", "5000001", "Hi, looking at it", 60)])
        a = self.facts()["assignee"]
        self.assertEqual((a["action"], a["human_replied_after"]), ("skip", True))
        # the human wrote within 48 h (an own note counts too): skip
        self.setUp(); self.thread(assignee=5465657, parts=[cust, self.part("4", "admin", "5465657", "internal", 5, ptype="note")])
        self.assertEqual(self.facts()["assignee"]["action"], "skip")
        # reassigned within 7 days: never again
        self.setUp(); self.handoff_row(60); self.handoff_row(1, kind="reassign"); self.thread(assignee=5465657, parts=[cust])
        self.assertEqual(self.facts()["assignee"]["action"], "skip")
        # QA #1517: a note handed to A does not count once the thread is B's - B gets their own handoff
        self.setUp(); self.handoff_row(60); self.thread(assignee=5000002, parts=[cust])
        a = self.facts()["assignee"]
        self.assertEqual((a["id"], a["action"], a["handoff_part"]), ("5000002", "handoff", ""))
        # unassigned, or assigned to Caroline's admin: no assignee state
        for asg in (None, 0, 5763097):
            self.setUp(); self.thread(assignee=asg, parts=[cust])
            self.assertIsNone(self.facts()["assignee"], asg)

    def test_thread_events_never_count_as_a_message_to_the_user(self):
        self.handoff_row(1)
        db = vl.connect(cs.LEDGER)
        self.assertEqual(vl.uvn_user_done(db, "l@x.com", user_id="298376"), "")
        row = db.execute("SELECT user_key, account_id, status FROM verify_messages WHERE campaign='handoff'").fetchone()
        self.assertEqual(tuple(row), (f"thread:{self.CONV}", None, "handoff"))
        with self.assertRaises(ValueError):
            vl.thread_event(db, kind="other", conversation=self.CONV, from_admin="1", to_admin="2", note_part="3",
                            reply_due_part="4", request_ids=[], user_id="", approved_by="U", approval_ref="r")


class FiledRequestEvidenceTest(unittest.TestCase):
    """b1 270: a status answer needs a request that exists, is still open, and is linked to THIS conversation."""

    def setUp(self):
        CommStateTest.setUp(self)
        ReplyDueTest.link(self, "777", ids=("r1",))
        db = sqlite3.connect(cs.PROOF_STORE)
        cols = {r[1] for r in db.execute("PRAGMA table_info(proof_intake)")}
        if "candidate_request_ids_json" not in cols:
            db.execute("ALTER TABLE proof_intake ADD COLUMN candidate_request_ids_json TEXT")
        if "conversation_id" not in cols:
            db.execute("ALTER TABLE proof_intake ADD COLUMN conversation_id TEXT")
        db.commit(); db.close()

    def q(self, open_ids):
        return lambda sql: [[r] for r in open_ids if f"'{r}'" in sql]

    def test_open_and_linked_only(self):
        self.assertEqual(cs.filed_requests(UID, ["r1"], "777", self.q(["r1"])), ["r1"])
        # QA on #1920 (review 5884277203): the ask named r1 in thread 777; a NEW thread 888 is not linked by it
        self.assertEqual(cs.filed_requests(UID, ["r1"], "888", self.q(["r1"])), [])
        self.assertEqual(cs.filed_requests(UID, ["r1"], "777", self.q([])), [])          # decided / deleted / not theirs
        self.assertEqual(cs.filed_requests(UID, ["r2"], "777", self.q(["r2"])), [])      # open but never named in 777
        self.assertEqual(cs.filed_requests(UID, ["x'; drop"], "777", self.q(["r1"])), [])  # never reaches the SQL
        self.assertEqual(cs.filed_requests(UID, ["r1"], "", self.q(["r1"])), [])

    def test_a_message_only_ask_links_only_the_thread_it_opened(self):
        # an ask sent as an Intercom MESSAGE has no conversation of its own: the reply opens a new conversation whose
        # source id is that message's id, and that is the only thread it links
        ReplyDueTest.ask_message(self, "990001", ids=("r2",))
        ReplyDueTest.ask_message(self, "990002", ids=("r3",), uid=4242)              # another account's ask
        q = self.q(["r1", "r2", "r3"])
        self.assertEqual(cs.filed_requests(UID, ["r2"], "888", q, "990001"), ["r2"])   # the thread r2's ask opened
        self.assertEqual(cs.filed_requests(UID, ["r2"], "888", q), [])                 # a thread it did not open
        self.assertEqual(cs.filed_requests(UID, ["r2"], "888", q, "0"), [])            # a customer-opened thread
        self.assertEqual(cs.filed_requests(UID, ["r2"], "888", q, "990009"), [])       # opened by a message we never sent
        self.assertEqual(cs.filed_requests(UID, ["r3"], "888", q, "990002"), [])       # opened by ANOTHER account's ask
        self.assertEqual(cs.filed_requests(UID, ["r2"], "888", q, "990001' OR '1'='1"), [])  # never reaches the SQL
        # the thread's own notes still count beside the opening ask
        self.assertEqual(cs.filed_requests(UID, ["r1", "r2"], "777", q, "990001"), ["r1", "r2"])
        # a row that is not a SENT ask links nothing
        db = sqlite3.connect(cs.LEDGER)
        db.execute("UPDATE verify_messages SET status='failed' WHERE message_id='990001'")
        db.commit(); db.close()
        self.assertEqual(cs.filed_requests(UID, ["r2"], "888", q, "990001"), [])

    def test_the_opening_message_id_is_the_conversations_source_id(self):
        self.assertEqual(cs.opening_message_id({"source": {"id": "990001"}}), "990001")
        self.assertEqual(cs.opening_message_id({"source": {"id": 990001}}), "990001")
        for conv in ({}, {"source": None}, {"source": {}}, {"source": {"id": None}}, {"source": {"id": "abc"}}):
            self.assertEqual(cs.opening_message_id(conv), "", conv)

    def test_a_filing_in_the_thread_links_the_request(self):
        db = sqlite3.connect(cs.PROOF_STORE)
        cols = [r[1] for r in db.execute("PRAGMA table_info(proof_intake)")]
        row = {c: None for c in cols}
        row.update({"user_id": UID, "conversation_id": "999", "candidate_request_ids_json": '["r3"]'})
        for c in cols:   # fill NOT NULL text columns
            if row[c] is None:
                row[c] = "x" if c != "received_at" else "2026-10-01T00:00:00Z"
        db.execute(f"INSERT INTO proof_intake ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", [row[c] for c in cols])
        db.commit(); db.close()
        self.assertEqual(cs.filed_requests(UID, ["r3"], "999", self.q(["r3"])), ["r3"])


class OtherRequestTest(unittest.TestCase):
    """QA #1517: A is linked to this thread; 'Any update on Other Song?' names open request B -> never A's answer."""

    setUp = ReplyDueTest.setUp
    thread = ReplyDueTest.thread
    link = ReplyDueTest.link

    def test_through_check(self):
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "Any update on Other Song?"
        def q(sql):
            if "spotifytracktitle" in sql:
                return [["La Flor de la Vida"]] if "lower(CAST(id AS varchar)) IN (" in sql else [["La Flor de la Vida"], ["Other Song"]]
            return ReplyDueTest.q(self, sql)
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        res = cs.check("uvn-status", "uvnstatus", UID, ["r1"], "c1", conversation="215473681300330", reply_due_part="57000000001",
                       query=q, ic=self.ic, fraud=lambda uid, qq: [])
        self.assertTrue(res["hold"], res)
        self.assertTrue(any("names another open request 'Other Song'" in r for r in res["reasons"]), res)
        # the linked request's own title with a status cue still answers
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "Any update on La Flor de la Vida?"
        res = cs.check("uvn-status", "uvnstatus", UID, ["r1"], "c1", conversation="215473681300330", reply_due_part="57000000001",
                       query=q, ic=self.ic, fraud=lambda uid, qq: [])
        self.assertFalse(any("names another open request" in r for r in res["reasons"]), res)


class BillingStatusVetoTest(unittest.TestCase):
    """r5 (QA #1517): a billing word vetoes the status class (one pattern with #1418's R9 billing veto)."""

    def test_billing_part_is_handoff(self):
        now = time.time()
        conv = lambda body: {"source": {"author": {"type": "user"}, "body": "hi", "created_at": now - 9 * 86400},
                             "conversation_parts": {"conversation_parts": [
                                 {"id": "9", "part_type": "comment", "author": {"type": "user"}, "body": body,
                                  "created_at": now - 2 * 86400}]}}
        for body in ("my request is pending but I was charged twice", "any update on my refund?",
                     "is my credit request approved? also my subscription renewed"):
            r = cs.trigger_class(conv(body), "9", filed=["r1"])
            self.assertEqual(r["class"], "non_status", body)
            self.assertTrue(r["why"].startswith("billing cue"), r)
        self.assertEqual(cs.trigger_class(conv("Is my request approved yet?"), "9", filed=["r1"])["class"], "status")


class ActionRequestTest(unittest.TestCase):
    """QA #1517: 'Please cancel my credit request.' on a linked, open thread is an action for a person, never status."""
    setUp = ReplyDueTest.setUp
    thread = ReplyDueTest.thread
    link = ReplyDueTest.link
    q = ReplyDueTest.q

    def test_through_check(self):
        for body in ("Please cancel my credit request.", "Can you delete my request for this song", "I want to withdraw it",
                     "wrong role on my credit request", "this is not me, my request was a mistake",
                     # b1 (QA #1517): corrections to what they sent
                     "I uploaded the wrong document; can you replace it?", "please use this file instead",
                     "can I resend the proof", "I need to re-upload my split sheet", "swap the screenshot for this one"):
            with self.subTest(body):
                self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = body
                res = ReplyDueTest.run_due(self, campaign="status-team-review", copy="teamreview")
                self.assertTrue(res["hold"], res)
                self.assertTrue(any("action request" in r for r in res["reasons"]), res)
        # a plain status question still answers
        self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "Is my request approved yet?"
        res = ReplyDueTest.run_due(self, campaign="status-team-review", copy="teamreview")
        self.assertFalse(any("action request" in r for r in res["reasons"]), res)


class LinkedTitlesTest(unittest.TestCase):
    """b1 (QA 11:36): the title cue counts only for requests linked to THIS conversation (no A/B cross-reply)."""

    def test_only_the_linked_requests_titles(self):
        seen = []

        def q(sql):
            seen.append(sql)
            if "spotifytracktitle" in sql:
                if "lower(CAST(id AS varchar)) IN (" not in sql:
                    return [["La Flor de la Vida"], ["Other Song"]]
                return [["La Flor de la Vida"]] if "'ra'" in sql else [["Other Song"]]
            return []
        self.assertEqual(cs.open_titles(7, q, only=["ra"]), ["La Flor de la Vida"])
        self.assertEqual(cs.open_titles(7, q, only=[]), [])
        self.assertEqual(cs.open_titles(7, q, only=["x'; drop"]), [])
        self.assertEqual(cs.open_titles(7, q), ["La Flor de la Vida", "Other Song"])

    def test_status_trigger_scopes_titles_to_filed(self):
        from unittest import mock
        got = {}
        with mock.patch.object(cs, "filed_requests",
                               lambda uid, keys, conv, q, src="": got.setdefault("src", src) and ["rb"]), \
                mock.patch.object(cs, "open_titles", lambda uid, q, only=None: got.setdefault("only", only) and ["T"]), \
                mock.patch.object(cs, "trigger_class", lambda conv, part, titles=(), filed=(), other_titles=(): {"titles": titles, "filed": filed}):
            r = cs.status_trigger(7, ["ra", "rb"], "777", "9", lambda sql: [], None, conv={"source": {"id": "880777"}})
        self.assertEqual(got["src"], "880777")           # the thread's opening message id reaches the linkage read
        self.assertEqual(got["only"], ["rb"])
        self.assertEqual(r["filed"], ["rb"])


class StatusAllowlistTableTest(unittest.TestCase):
    """b1 19:05Z (QA #1517, 6th veto round): the classifier is INVERTED - status only for an allowlisted status question
    with no veto; every phrase QA has reported so far is a handoff."""
    STATUS = (
        "Where is my credit request?", "any update on my credit?", "Any news on my request?", "What's the status of my request?",
        "status of my claim please", "Has it been approved?", "Is my request approved yet?",
        "will my credit be verified soon", "This track has been under review for months now.",
        "still waiting to hear back about my credits", "La Flor de la Vida - nothing yet", "my credits are still pending",
        "have my credits been checked yet?", "how long until my request is approved?",
    )
    HANDOFF = (
        # every QA-reported phrase, rounds 1-6
        "Can I edit my credit request for this song?", "How do I upload my document?",
        "Can I request Dolby Atmos credits?", "When will Dolby Atmos credits be supported?",
        "When will my Dolby Atmos credit feature be supported?", "How long does a split sheet take in general?",
        "how long until it is approved?", "Please cancel my credit request.", "Can you delete my request for this song",
        "I want to withdraw it", "wrong role on my credit request", "I uploaded the wrong document; can you replace it?",
        "please use this file instead", "my request is pending but I was charged twice", "any update on my refund?",
        "is my credit request approved? also my subscription renewed", "my request is pending - is the feature available in the app?",
        "When will my credit be supported on Spotify?", "my credits", "ok thanks, here you go", "Scandinavia is lovely",
        "is there a way to add a new role?", "How can I change the role on my credit?", "Could I fix the title?",
        "I'd like to update my profile name", "thanks!", "hello?",
        # QA #1517 22:0xZ: status words that do not name the credit/request/claim/merge/track/title
        "Any update on my concert tickets?", "Any update on my concert tickets? I also have a credit request.", "any update?", "Any news on this?", "still waiting to hear back", "nothing yet", "have they been checked yet?",
    )

    def conv(self, body):
        now = time.time()
        return {"source": {"author": {"type": "user"}, "body": "hi", "created_at": now - 9 * 86400},
                "conversation_parts": {"conversation_parts": [
                    {"id": "9", "part_type": "comment", "author": {"type": "user"}, "body": body, "created_at": now - 2 * 86400}]}}

    def test_the_table(self):
        for body in self.STATUS:
            with self.subTest(status=body):
                r = cs.trigger_class(self.conv(body), "9", filed=["r1"], titles=["La Flor de la Vida"])
                self.assertEqual(r["class"], "status", (body, r))
        for body in self.HANDOFF:
            with self.subTest(handoff=body):
                r = cs.trigger_class(self.conv(body), "9", filed=["r1"], titles=["La Flor de la Vida", "Scandi"])
                self.assertEqual(r["class"], "non_status", (body, r))

    def test_the_two_reported_phrases_name_the_how_to_veto(self):
        for body in ("Can I edit my credit request for this song?", "How do I upload my document?"):
            r = cs.trigger_class(self.conv(body), "9", filed=["r1"])
            self.assertTrue(r["why"].startswith("how-to / change request"), r)


class HoldKindTest(unittest.TestCase):
    """[key=r8-hold-due] (r5/p1 10-31): asks ignore R8_approval_hold_volume and hold on R8_hard; a volume hold still
    holds every non-ask note and stays truthy for the approval-side readers; any doubt about the kind = hard."""

    def setUp(self):
        CommStateTest.setUp(self)
        d = Path(tempfile.mkdtemp())
        self.saved = (cs.ACCOUNT_HOLDS, cs.ACCOUNT_BANDS)
        cs.ACCOUNT_HOLDS, cs.ACCOUNT_BANDS = str(d / "holds.jsonl"), str(d / "bands.json")
        Path(cs.ACCOUNT_HOLDS).write_text(json.dumps({"user_id": str(UID), "kind": "approval_hold"}) + "\n")

    def tearDown(self):
        cs.ACCOUNT_HOLDS, cs.ACCOUNT_BANDS = self.saved

    def bands(self, kind, decision="hold", age_h=0.5):
        Path(cs.ACCOUNT_BANDS).write_text(json.dumps({"users": {str(UID): {"decision": decision, "hold_kind": kind}}}))
        os.utime(cs.ACCOUNT_BANDS, (time.time() - age_h * 3600,) * 2)

    def held_by_r8(self, campaign, copy):
        q = lambda sql: [["0", "0"]] if "proof_required_owed" in sql else [] if "regexp_like" in sql else (
            [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]] if "credit_requests" in sql else [])
        fr = lambda uid, qq: cs.account_hold_facts(uid)
        res = cs.check(campaign, copy, UID, ["r1"], "c1", query=q, ic=self.ic, fraud=fr)
        return [r for r in res["reasons"] if r.startswith("R8")]

    def test_a_volume_hold_does_not_hold_the_ask(self):
        self.bands("R8_approval_hold_volume")
        self.assertEqual(cs.account_hold_facts(UID), ["R8_approval_hold_volume"])     # truthy: approvals stay held
        self.assertEqual(self.held_by_r8("uvn-status", "uvn"), [])                     # the ask goes
        q = lambda sql: [["0", "0"]] if "proof_required_owed" in sql else []
        k = cs.check("status-team-review", "teamreview", UID, ["r1"], "c1", query=q, ic=self.ic,
                     fraud=lambda uid, qq: cs.account_hold_facts(uid))
        self.assertTrue(k["hold"], k)                                                  # never /k: owes the hold
        self.assertIn("owes:account_hold", k["reasons"])

    def test_a_hard_hold_holds_the_ask(self):
        self.bands("R8_hard")
        self.assertEqual(self.held_by_r8("uvn-status", "uvn"), ["R8_account_hold"])

    def test_any_doubt_about_the_kind_is_hard(self):
        for setup in (lambda: None,                                                    # no bands file
                      lambda: self.bands("R8_approval_hold_volume", age_h=4),          # stale (> 3 h)
                      lambda: self.bands("R8_approval_hold_volume", decision="allow"),  # the scan does not hold them
                      lambda: self.bands(None),                                        # no kind
                      lambda: Path(cs.ACCOUNT_BANDS).write_text("{not json")):
            Path(cs.ACCOUNT_BANDS).unlink(missing_ok=True)
            setup()
            self.assertEqual(cs.account_hold_facts(UID), ["R8_account_hold"])
            self.assertEqual(self.held_by_r8("uvn-status", "uvn"), ["R8_account_hold"])

    def mcf_r8(self):
        q = lambda sql: [["0", "0"]] if "proof_required_owed" in sql else []
        res = cs.check("merge-claim-first", "mergeclaimfirst", UID, [f"mcf-{UID}"], "c1", query=q, ic=self.ic,
                       fraud=lambda uid, qq: cs.account_hold_facts(uid))
        return [r for r in res["reasons"] if r.startswith("R8")]

    def test_merge_claim_first_passes_only_a_current_volume_hold(self):
        # QA #1566: the CURRENT scan's kind, through the real account_hold_facts / hold_kind - never historical reasons
        self.bands("R8_approval_hold_volume")
        self.assertEqual(self.mcf_r8(), [])
        self.bands("R8_hard")
        self.assertEqual(self.mcf_r8(), ["R8_account_hold"])
        for setup in (lambda: None,                                                    # no scan
                      lambda: self.bands("R8_approval_hold_volume", age_h=4),          # stale scan
                      lambda: self.bands("R8_approval_hold_volume", decision="allow"),
                      lambda: self.bands(None),
                      lambda: Path(cs.ACCOUNT_BANDS).write_text("{not json")):         # unreadable scan
            Path(cs.ACCOUNT_BANDS).unlink(missing_ok=True)
            setup()
            self.assertEqual(self.mcf_r8(), ["R8_account_hold"])
        # an old unanchored-volume REASON in the holds history never turns a hard/unknown current kind into a pass
        Path(cs.ACCOUNT_HOLDS).write_text(json.dumps({"user_id": str(UID), "kind": "approval_hold",
                                                      "reasons": ["unanchored count 30d 189 >= level 150"]}) + "\n")
        Path(cs.ACCOUNT_BANDS).unlink(missing_ok=True)
        self.assertEqual(self.mcf_r8(), ["R8_account_hold"])
        # it is not a credit ask: the ASKS-only ledger readers never count it
        self.assertNotIn("merge-claim-first", cs.ASKS)

    def test_no_hold_row_is_no_hold_whatever_the_band_says(self):
        Path(cs.ACCOUNT_HOLDS).write_text("")
        self.bands("R8_approval_hold_volume")
        self.assertEqual(cs.account_hold_facts(UID), [])


class MergeClaimFirstWaiverTest(CommStateTest):
    """r5 [key=mcf-wait-lines] (2), 2026-11-03: the 7-day recency hold is waived for merge-claim-first ONLY when the
    last customer-visible part in the conversation is OURS and its class is a status/receipt. Our own earlier ask (a
    merge-claim ask included) leaves the customer owing a reply, so the 7-day rule stands there."""

    # QA #1660 a: the waiver matches the part's ID to the ledger's message_id, so the fixtures carry real part ids
    # (verified against prod conversations: for a part we posted, part.id IS verify_messages.message_id).
    def conv(self, *, last_ours: bool, at: float, last_id: str = "p2"):
        """at = the epoch of the LAST customer-visible part; the other side's part is 300 s earlier."""
        cust = {"id": "c1", "author": {"type": "user"}, "body": "here you go",
                "created_at": at if not last_ours else at - 300}
        ours = {"id": last_id if last_ours else "p2", "author": {"type": "admin"}, "body": "a quick update",
                "created_at": at if last_ours else at - 300}
        self.ic.convs["9"] = {"id": "9", "source": {"id": "s0", "author": {"type": "admin"}, "created_at": at - 900},
                              "conversation_parts": {"conversation_parts": [cust, ours] if last_ours else [ours, cust]}}

    def run7(self, campaign="merge-claim-first", copy="mergeclaimfirst"):
        return cs.check(campaign, copy, UID, [f"mcf-{UID}"], "c1", conversation="9",
                        query=lambda sql: [["0", "0"]] if "proof_required_owed" in sql else ([list(r) for r in self.core]
                                                                                            if "credit_requests" in sql else []),
                        ic=self.ic, fraud=lambda uid, q: [])

    def recent(self, campaign, epoch, msg_id="p2"):
        self.note(campaign, at=datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  msg_id=msg_id)

    def test_a_status_note_of_ours_last_waives_the_7_days(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=True, at=now)
        self.recent("status-team-review", now)
        res = self.run7()
        self.assertFalse([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_our_own_earlier_ask_does_not_waive(self):
        # the merge-claim ask itself, and any other ask: the customer still owes an answer, so 7 days stand
        for camp in ("merge-claim-first", "verify-live", "uvn-status", "proof-need-ask"):
            with self.subTest(camp):
                self.setUp()
                self.core = [["r1", "user_verification_needed", "", ""]]
                now = time.time() - 86400
                self.conv(last_ours=True, at=now)
                self.recent(camp, now)
                res = self.run7()
                self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_the_customers_own_last_part_never_waives(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=False, at=now)
        self.recent("status-team-review", now)
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_an_internal_note_is_not_a_message_the_customer_got(self):
        # the last customer-visible part is theirs; our newer internal note does not turn that into "ours last"
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=False, at=now)
        self.ic.convs["9"]["conversation_parts"]["conversation_parts"].append(
            {"author": {"type": "admin"}, "part_type": "note", "body": "internal", "created_at": now + 60})
        self.recent("status-team-review", now)
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_a_ledger_row_that_does_not_match_the_part_never_waives(self):
        # the ledger's newest note is a DIFFERENT message (id p9) than the last visible part (p2): no waiver
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=True, at=now)
        self.recent("status-team-review", now, msg_id="p9")
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_an_unledgered_human_part_right_after_our_status_never_waives(self):
        # QA #1660 a, the adversarial case: our ledgered status is at T and a HUMAN admin comment lands at T+60 s. It
        # is the last customer-visible part and its author is support, so a `gap <= 300 s` rule waved both 7-day holds
        # through for it - the customer owes a reply to that human and could be messaged. Identity: part p3 is not the
        # ledger's p2, so the 7-days stand.
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=True, at=now + 60, last_id="p3")
        self.recent("status-team-review", now, msg_id="p2")
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_a_ledger_row_without_an_id_never_waives(self):
        # identity unavailable on OUR side (an older row written before message_id was recorded) = fail closed
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=True, at=now)
        self.recent("status-team-review", now, msg_id=None)
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_a_part_without_an_id_never_waives(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=True, at=now, last_id="")
        self.recent("status-team-review", now)
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_the_waiver_is_merge_claim_first_only(self):
        # the same "our status note was last" shape does NOT release any other campaign's 7-day hold
        for camp in ("credit-hold-status", "claim-proof-pending", "uvn-status", "claim-proof-ask"):
            with self.subTest(camp):
                self.setUp()
                self.core = [["r1", "user_verification_needed", "", ""]]
                now = time.time() - 86400
                self.conv(last_ours=True, at=now)
                self.recent("status-team-review", now)
                res = self.run7(camp, camp)
                self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], (camp, res))

    def test_no_last_part_or_no_ledger_means_no_waiver(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        now = time.time() - 86400
        self.conv(last_ours=True, at=now)          # a status note, but no ledger row at all
        res = self.run7()
        self.assertTrue([r for r in res["reasons"] if r.startswith("messaged_7d")], res)

    def test_proof_on_file_is_the_render_fact_not_a_hold(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.conv(last_ours=True, at=time.time() - 86400)
        res = self.run7()
        self.assertFalse(res["proof_on_file"], res)
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake (user_id, file_sha256) VALUES ({UID}, 's');")
        sqlite3.connect(cs.PROOF_STORE).commit()
        res = self.run7()
        self.assertTrue(res["proof_on_file"], res)
        self.assertFalse([r for r in res["reasons"] if r.startswith("proof_on_file")], res)

    def cli_proof(self):
        """The gate's render read, through the same CLI the shell runs."""
        out = io.StringIO()
        with unittest.mock.patch.object(cs, "trino", lambda sql: [list(r) for r in self.core] if "credit_requests" in sql else []), \
                unittest.mock.patch.object(cs, "intercom", self.ic), \
                contextlib.redirect_stdout(out):
            rc = cs._main(["proof-on-file", "--user-id", str(UID), "--request-ids", "r1"])
        return rc, json.loads(out.getvalue())

    def test_intercom_only_proof_is_the_same_fact_on_both_reads(self):
        # QA #1660 b: the customer's only evidence is an Intercom attachment. `check()` counted it and the render read
        # (`proof-on-file`) did not, so the gate's two reads of "the same" fact disagreed for EVERY such recipient and
        # the equality guard refused the send with a 'could not read' reason. Both now answer from ONE function.
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.conv(last_ours=True, at=time.time() - 86400)
        self.ic.convs["7"] = {"id": "7", "source": {"author": {"type": "user"}, "created_at": time.time() - 86400,
                              "attachments": [{"name": "contract.pdf"}]}}
        # (a) no note of ours names a contact, so the render read falls back to the RECORD (the copy then renders
        # without the acknowledgement - it asserts nothing) and says so; the shell refuses only the other direction
        rc, cli = self.cli_proof()
        self.assertEqual((rc, cli["proof_on_file"], cli["contact_unknown"]), (0, False, True), cli)
        # (b) the contact our ledger names -> both reads see the attachment; nothing is filed in intake yet
        self.note("claim-status", at=OLD, msg_id="p9", contact_id="c1")
        rc, cli = self.cli_proof()
        res = self.run7()
        self.assertEqual(rc, 0, cli)
        self.assertEqual((cli["proof_on_file"], res["proof_on_file"]), (True, True), (cli, res))
        self.assertEqual((cli["record_only"], cli["intercom_only"], cli["contact_unknown"]), (False, True, False), cli)
        self.assertEqual(res["proof_note"], ["intercom_only_proof"], res)      # named, never silent
        self.assertFalse([r for r in res["reasons"] if r.startswith("proof_on_file")], res)   # render fact, never a hold
        # (c) once the document is filed, the record answers on its own and the note is gone
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake (user_id, file_sha256) VALUES ({UID}, 's');")
        sqlite3.connect(cs.PROOF_STORE).commit()
        rc, cli = self.cli_proof()
        res = self.run7()
        self.assertEqual((cli["proof_on_file"], res["proof_on_file"]), (True, True))
        self.assertEqual((cli["record_only"], cli["intercom_only"]), (True, False), cli)
        self.assertEqual(res["proof_note"], [], res)


class MergeClaimFirstReleaseTest(CommStateTest):
    """r5 (3) [key=mcf-wait-lines] 2026-11-03 (Fable ruling 144 under Aaron's 18:35Z delegation): the receipt hold on the
    merge ask EXPIRES at day 14 - a customer we receipted is asked, not parked for good - while a decided/told request
    stays held and every other wait line keeps the receipt hold."""

    def receipted(self, days):
        at = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.note("status-doc-received", at=at)
        return at

    def reason_starts(self, res, prefix):
        return [r for r in res["reasons"] if r.startswith(prefix)]

    def test_a_receipt_14_days_old_releases_the_merge_ask(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.receipted(15)
        res = self.run_("merge-claim-first", "mergeclaimfirst")
        self.assertFalse(self.reason_starts(res, "already_acknowledged"), res)
        self.assertFalse(res["hold"], res)

    def test_a_fresh_receipt_still_holds_the_merge_ask(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.receipted(13)
        res = self.run_("merge-claim-first", "mergeclaimfirst")
        self.assertTrue(self.reason_starts(res, "already_acknowledged"), res)

    def test_the_boundary_is_day_14_not_day_15(self):
        at = self.receipted(0)
        st = {"acked": at}
        stamped = datetime.fromisoformat(at).timestamp()
        self.assertFalse(cs.wait_line_released("merge-claim-first", st, now=stamped + 14 * 86400 - 1))
        self.assertTrue(cs.wait_line_released("merge-claim-first", st, now=stamped + 14 * 86400))

    def test_a_receipt_without_a_readable_stamp_never_releases(self):
        # fail closed: no stamp is not an old stamp
        for acked in ("", "not-a-date", None):
            with self.subTest(acked=acked):
                self.assertFalse(cs.wait_line_released("merge-claim-first", {"acked": acked}))

    def test_a_decided_request_is_never_released(self):
        # nothing left to ask: the release touches the receipt hold only
        self.core = [["r1", "approved", "", ""]]
        self.receipted(100)
        res = self.run_("merge-claim-first", "mergeclaimfirst")
        self.assertTrue(res["hold"], res)
        self.assertTrue(self.reason_starts(res, "decided_or_told"), res)
        self.core = [["r1", "unverified", "2026-10-01T00:00:00Z", ""]]        # an approval notice was told
        res = self.run_("merge-claim-first", "mergeclaimfirst")
        self.assertTrue(self.reason_starts(res, "decided_or_told"), res)

    def test_the_release_is_merge_claim_first_only(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        self.receipted(100)
        for camp in ("credit-hold-status", "claim-proof-pending", "uvn-status", "claim-proof-ask"):
            with self.subTest(camp):
                res = self.run_(camp, camp)
                self.assertTrue(self.reason_starts(res, "already_acknowledged"), (camp, res))


class ReleaseRowTest(unittest.TestCase):
    """[key=r8-release-row] (r5 + p1 10-31): the latest row by `at` decides; a release clears the hold for asks AND
    approvals only when the lens's current scan agrees; anything doubtful = held. One reader for everyone."""

    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.saved = (cs.ACCOUNT_HOLDS, cs.ACCOUNT_BANDS)
        cs.ACCOUNT_HOLDS, cs.ACCOUNT_BANDS = str(d / "holds.jsonl"), str(d / "bands.json")
        self.bands({})

    def tearDown(self):
        cs.ACCOUNT_HOLDS, cs.ACCOUNT_BANDS = self.saved

    def rows(self, *rows):
        Path(cs.ACCOUNT_HOLDS).write_text("".join(json.dumps({"user_id": u, "kind": k, "at": at}) + "\n" for u, k, at in rows))

    def bands(self, users, age_h=0.5):
        Path(cs.ACCOUNT_BANDS).write_text(json.dumps({"users": users, "failed_chunks_users": []}))
        os.utime(cs.ACCOUNT_BANDS, (time.time() - age_h * 3600,) * 2)

    def test_a_confirmed_release_ends_the_hold_for_everyone(self):
        self.rows(("7", "approval_hold", "2026-10-29T10:00:00Z"), ("7", "release", "2026-10-30T10:00:00Z"))
        self.assertEqual(cs.held_user_ids(), set())
        self.assertEqual(cs.account_hold_facts(7), [])                                # asks + approval-side readers

    def test_a_later_hold_after_a_release_holds(self):
        self.rows(("7", "approval_hold", "2026-10-29T10:00:00Z"), ("7", "release", "2026-10-30T10:00:00Z"),
                  ("7", "approval_hold", "2026-10-31T01:00:00Z"))
        self.assertEqual(cs.held_user_ids(), {"7"})

    def test_latest_is_by_at_not_by_file_order(self):
        self.rows(("7", "release", "2026-10-30T10:00:00Z"), ("7", "approval_hold", "2026-10-29T10:00:00Z"))
        self.assertEqual(cs.held_user_ids(), set())                                   # the release is later
        self.rows(("7", "approval_hold", "2026-10-31T10:00:00.000Z"), ("7", "release", "2026-10-30T10:00:00Z"))
        self.assertEqual(cs.held_user_ids(), {"7"})                                   # the hold is later

    def test_a_release_without_the_lens_agreeing_holds(self):
        rel = (("7", "approval_hold", "2026-10-29T10:00:00Z"), ("7", "release", "2026-10-30T10:00:00Z"))
        for bands in (lambda: self.bands({"7": {"decision": "hold", "hold_kind": "R8_hard"}}),   # the scan disagrees
                      lambda: self.bands({}, age_h=4),                                        # stale scan
                      lambda: Path(cs.ACCOUNT_BANDS).unlink(),                                # no scan
                      lambda: Path(cs.ACCOUNT_BANDS).write_text("{broken")):                  # unreadable scan
            self.rows(*rel)
            self.bands({})
            bands()
            self.assertEqual(cs.held_user_ids(), {"7"})

    def test_only_a_valid_band_agreement_confirms_a_release(self):
        # QA #1570: a present but malformed entry, or an absence from a scan of unknown completeness, keeps them held
        rel = (("7", "approval_hold", "2026-10-29T10:00:00Z"), ("7", "release", "2026-10-30T10:00:00Z"))
        for users, failed, held in (({"7": None}, [], {"7"}),
                                    ({"7": {"decision": "unknown"}}, [], {"7"}),
                                    ({"7": "allow"}, [], {"7"}),
                                    ({}, None, {"7"}),                       # no failed_chunks_users: completeness unknown
                                    ({}, ["7"], {"7"}),                      # the scan could not read them
                                    ({}, [], set()),                         # absent from a complete scan: released
                                    ({"7": {"decision": "allow"}}, [], set())):
            self.rows(*rel)
            doc = {"users": users} if failed is None else {"users": users, "failed_chunks_users": failed}
            Path(cs.ACCOUNT_BANDS).write_text(json.dumps(doc))
            self.assertEqual(cs.held_user_ids(), held, (users, failed))

    def test_doubtful_rows_hold(self):
        self.rows(("7", "approval_hold", "2026-10-29T10:00:00Z"), ("7", "release", "not a time"),
                  ("8", "mystery", "2026-10-29T10:00:00Z"), ("8", "release", "2026-10-30T10:00:00Z"))
        self.assertEqual(cs.held_user_ids(), {"7", "8"})

    def test_the_ledger_itself_unreadable_or_stale_is_unknown(self):
        with self.assertRaises(cs.Unknown):
            cs.held_user_ids()                                                        # no file
        self.rows(("7", "approval_hold", "2026-10-29T10:00:00Z"))
        os.utime(cs.ACCOUNT_HOLDS, (time.time() - 73 * 3600,) * 2)
        with self.assertRaises(cs.Unknown):
            cs.held_user_ids()

    def test_owing_proof_and_receipts_read_through_the_one_reader(self):
        from credit_review import owing_proof, receipts
        import sqlite3
        led = str(Path(tempfile.mkdtemp()) / "l.sqlite3")
        db = sqlite3.connect(led)
        db.execute("CREATE TABLE verify_refusal_holds (user_id TEXT, flagged_at TEXT, reason TEXT)")
        db.commit(); db.close()
        self.rows(("7", "approval_hold", "2026-10-29T10:00:00Z"), ("7", "release", "2026-10-30T10:00:00Z"),
                  ("9", "approval_hold", "2026-10-29T10:00:00Z"))
        self.assertEqual(owing_proof.held_accounts(cs.ACCOUNT_HOLDS, led), {9})
        self.assertEqual(receipts.held_accounts(cs.ACCOUNT_HOLDS, led), {9})


class CorrectionCooldownTest(unittest.TestCase):
    """[key=k-proof-required] /c2: an ask that corrects OUR recent status line is not deferred by our own 7-day cooldown
    (that line); every other hold stays. Only for uvn-status."""

    def test_correction_lifts_only_our_messaged_7d(self):
        CommStateTest.setUp(self)
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl"); Path(cs.ACCOUNT_HOLDS).write_text("")
        db = vl.connect(cs.LEDGER)
        c = vl.claim(db, campaign="status-team-review", user_key="a@x.com", day=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                     request_ids=["r1"], message_type="email", approved_by="U", approval_ref="r", user_id=str(UID))
        vl.finalize(db, message_row=c["message_row"], status="sent", message_id="1"); db.close()
        q = lambda sql: [["0", "0"]] if "proof_required_owed" in sql else (
            [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]] if "credit_requests" in sql else [])
        plain = cs.check("uvn-status", "uvn", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lambda u, qq: [])
        self.assertTrue(any(r.startswith("messaged_7d") for r in plain["reasons"]), plain)
        fixed = cs.check("uvn-status", "uvn", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lambda u, qq: [], correction=True)
        self.assertFalse(any(r.startswith("messaged_7d") for r in fixed["reasons"]), fixed)
        other = cs.check("gap-ask", "gap", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lambda u, qq: [], correction=True)
        self.assertTrue(any(r.startswith("messaged_7d") for r in other["reasons"]), other)       # uvn-status only


class ReadsBesideTest(unittest.TestCase):
    """[key=gate-reads-beside]: the fraud lens is read BESIDE the request / store / Intercom reads, not after them. On
    node-8 a check() was 12.7 s serial and 7.0 s with the lens beside (user 98255, 2026-11-12), which is the difference
    between a gate call that fits the runner's one 20 s attempt and five gate_timeouts a tick. The verdict must not
    move: same reads, same holds, same errors, raised from the same call."""

    Q = staticmethod(lambda sql: [["0", "0"]] if "proof_required_owed" in sql else (
        [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]] if "credit_requests" in sql else []))

    def setUp(self):
        CommStateTest.setUp(self)
        cs.ACCOUNT_HOLDS = str(Path(tempfile.mkdtemp()) / "h.jsonl"); Path(cs.ACCOUNT_HOLDS).write_text("")

    def test_the_lens_and_the_request_read_are_in_flight_together(self):
        lens_started, core_started = threading.Event(), threading.Event()
        saw: dict[str, bool] = {}

        def q(sql):
            core_started.set()
            saw.setdefault("core_saw_lens", lens_started.wait(5))    # serial code: the lens has not started yet
            return self.Q(sql)

        def lens(uid, qq):
            lens_started.set()
            saw["lens_saw_core"] = core_started.wait(5)
            return []

        res = cs.check("uvn-status", "uvn", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=lens)
        self.assertEqual(saw, {"core_saw_lens": True, "lens_saw_core": True})
        self.assertFalse(res["hold"], res)

    def test_a_lens_hold_still_holds_and_a_lens_error_is_still_unknown(self):
        held = cs.check("uvn-status", "uvn", UID, ["r1"], "c1", query=self.Q, ic=self.ic,
                        fraud=lambda u, qq: ["R8_fraud_lens_held"])
        self.assertTrue(held["hold"], held)
        self.assertTrue(any("R8_fraud_lens_held" in r for r in held["reasons"]), held)

        def broken(uid, qq):
            raise cs.Unknown("fraud lens unreadable: no watchlist")
        with self.assertRaises(cs.Unknown) as cm:
            cs.check("uvn-status", "uvn", UID, ["r1"], "c1", query=self.Q, ic=self.ic, fraud=broken)
        self.assertIn("fraud lens unreadable", str(cm.exception))

    def test_a_failed_request_read_does_not_wait_for_the_lens(self):
        release = threading.Event()

        def q(sql):
            raise cs.Unknown("replica read failed: EOF")

        def slow_lens(uid, qq):
            release.wait(30)
            return []

        t0 = time.monotonic()
        try:
            with self.assertRaises(cs.Unknown) as cm:
                cs.check("uvn-status", "uvn", UID, ["r1"], "c1", query=q, ic=self.ic, fraud=slow_lens)
        finally:
            release.set()
        self.assertIn("replica read failed", str(cm.exception))
        self.assertLess(time.monotonic() - t0, 10)

    def test_beside_hands_back_the_value_or_the_error(self):
        self.assertEqual(cs.beside(lambda a, b: a + b, 2, 3)(), 5)
        with self.assertRaises(KeyError):
            cs.beside(lambda: {}["missing"])()


if __name__ == "__main__":
    unittest.main()
