"""credit_review/comm_state.py: the send-time communication-state check (captain 2026-10-28 18:2xZ). One test per
rule: (1) the "wait for our message" lines never go to a user with any document or reply on file; (2) R1 never
after a decision was told; (3) nothing within 7 days of another note; (4) the state is read at send time, so a reply
injected between the list cut and the send cancels it; never step backwards; unreadable = unknown."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import json
import os
import sqlite3
import time
import sys
import tempfile
import unittest
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
        v.execute("CREATE TABLE dv_outcomes (user_id INTEGER, request_id TEXT)")
        v.commit(); v.close()
        cs.PROOF_ON_FILE = str(d / "pof.json")
        Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": []}))
        self.core = []          # [rid, status, approvedNotice, proofRequest]
        self.ic = FakeIntercom()

    def note(self, campaign, at=OLD, reply=None, kind="initial", status="sent", ids=("r1",)):
        db = sqlite3.connect(cs.LEDGER)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at, last_reply_at) "
                   "VALUES (?,?,?,?,?,?,'email',?,1,'U','ref',?,?,?,?)",
                   (campaign, kind, "j@x.com", str(UID), at[:10], status, json.dumps(list(ids)), at, at, at, reply))
        db.commit(); db.close()

    def run_(self, campaign="credit-hold-status", copy="credithold", keys=("r1",), conversation="", fraud=()):
        return cs.check(campaign, copy, UID, list(keys), "c1", conversation=conversation,
                        query=lambda sql: [list(r) for r in self.core] if "credit_requests" in sql else [],
                        ic=self.ic, fraud=lambda uid, q: list(fraud))

    def test_a_never_told_user_with_nothing_on_file_gets_the_wait_line(self):
        self.core = [["r1", "user_verification_needed", "", ""]]
        res = self.run_()
        self.assertEqual((res["hold"], res["state"]), (False, "none"))

    def test_rule1_any_document_or_reply_on_file_holds_the_wait_lines(self):
        cases = {
            "proof_intake": lambda: sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake (user_id, file_sha256) VALUES ({UID}, 's');"),
            "dv_outcomes": lambda: sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes VALUES ({UID}, 'r1');"),
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
        dv = lambda rid: (lambda: sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes VALUES ({UID}, '{rid}');"))
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
        sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes VALUES ({UID}, 'other');")
        self.assertFalse(self.run_("uvn-status", "uvnstatus")["hold"])
        sqlite3.connect(cs.DV_STORE).executescript(f"INSERT INTO dv_outcomes VALUES ({UID}, 'r1');")
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
        self.assertIn("R7_thread_resolved", self.r1("7")["reasons"])
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
        q = lambda sql: [list(r) for r in rows] if "credit_requests" in sql else []
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
        self.now = time.time()
        self.thread("215473681300330", title="Credit Verification", last_user_age_h=78)

    def thread(self, cid, *, title="Credit Verification", last_user_age_h=78, contact="c1", after=None):
        parts = [{"id": "1", "part_type": "comment", "author": {"type": "admin"}, "body": "status update",
                  "created_at": self.now - 10 * 86400},
                 {"id": "57000000001", "part_type": "comment", "author": {"type": "user"},
                  "body": "This track has been under review for months now.", "created_at": self.now - last_user_age_h * 3600}]
        parts += after or []
        self.ic.convs[cid] = {"id": cid, "title": title, "state": "open", "source": {"id": "0", "author": {"type": "user"}},
                              "contacts": {"contacts": [{"id": contact}]}, "conversation_parts": {"conversation_parts": parts}}

    def run_due(self, part="57000000001", campaign="uvn-status", copy="uvnstatus"):
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        return cs.check(campaign, copy, UID, ["r1"], "c1", conversation="215473681300330", reply_due_part=part,
                        query=lambda sql: [list(r) for r in self.core] if "credit_requests" in sql else [],
                        ic=self.ic, fraud=lambda uid, q: [])

    def test_lamberto_an_unanswered_question_is_answered_despite_a_note_inside_7_days(self):
        CommStateTest.note(self, "status-team-review", at=(datetime.now(timezone.utc) - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        plain = cs.check("uvn-status", "uvnstatus", UID, ["r1"], "c1", conversation="215473681300330",
                         query=lambda sql: [list(r) for r in self.core] if "credit_requests" in sql else [],
                         ic=self.ic, fraud=lambda uid, q: [])
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
            # QA #1509: the nominated part is 78 h old but the customer wrote AGAIN 1 h ago: the 24 h run from the latest
            "reply_due:not_24h_yet ": dict(after=[{"id": "57000000002", "part_type": "comment", "author": {"type": "user"},
                                                   "body": "any news?", "created_at": self.now - 3600}]),
        }
        for want, kw in cases.items():
            with self.subTest(want):
                self.thread("215473681300330", **({"title": "refund"} if want.startswith("reply_due:R9") else {}) | kw)
                if want.startswith("reply_due:R9"):
                    self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][1]["body"] = "refund please"
                    self.ic.convs["215473681300330"]["conversation_parts"]["conversation_parts"][0]["body"] = "passed on"
                res = self.run_due()
                self.assertTrue(res["hold"], (want, res))
                self.assertIn(want.strip(), res["reasons"])
        self.thread("215473681300330")
        self.assertIn("reply_due:not_a_customer_part", self.run_due(part="1")["reasons"])
        self.assertIn("reply_due:part_not_in_thread", self.run_due(part="123")["reasons"])
        self.assertIn("reply_due:campaign_not_allowed", self.run_due(campaign="credit-hold-status", copy="credithold")["reasons"])

    def test_the_other_rules_still_hold_a_reply_due_answer(self):
        self.core = [["r1", "user_verification_needed", "", "", "2026-10-15 07:21:38 UTC"]]
        sqlite3.connect(cs.PROOF_STORE).executescript(f"INSERT INTO proof_intake VALUES ({UID}, 's', '2026-10-20T00:00:00Z');")
        res = self.run_due()
        self.assertTrue(res["hold"])
        self.assertTrue(any(r.startswith("proof_on_file") for r in res["reasons"]), res)


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


if __name__ == "__main__":
    unittest.main()
