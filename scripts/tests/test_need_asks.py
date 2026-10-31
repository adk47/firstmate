"""credit_review/need_asks.py: the L11c audience (p1 rulings 096/098) and its sender path (the gate decides the rest)."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import need_asks as na  # noqa: E402

SHA_A, SHA_B, SHA_C = "a" * 64, "b" * 64, "c" * 64


class FakeGate:
    def __init__(self):
        self.calls = []

    def __call__(self, argv):
        payload = json.load(open(argv[argv.index("--credits-file") + 1]))
        self.calls.append((argv, payload))
        return type("R", (), {"returncode": 0, "stdout": "DRY-RUN proof-need-ask initial comment credits=1\n", "stderr": ""})()


class NeedAsksTest(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.dv = str(self.d / "dv.sqlite")
        db = sqlite3.connect(self.dv)
        db.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, proof_id TEXT, request_id TEXT, "
                   "user_id INTEGER, outcome TEXT, need TEXT)")
        rows = [  # (at, sha, request, user, outcome, need)
            ("2026-10-20T00:00:00Z", SHA_A, "R1", 1, "unverifiable", "readable_document"),        # listed
            ("2026-10-21T00:00:00Z", SHA_B, "r2", 1, "unverifiable", "counterparty_signed_or_registered"),
            ("2026-10-20T00:00:00Z", SHA_A, "r3", 2, "unverifiable", "distributor_dashboard_with_code"),  # no issuer
            ("2026-10-20T00:00:00Z", SHA_A, "r4", 3, "unverifiable", "issuer_email_from_official_domain"),  # verify@
            ("2026-10-20T00:00:00Z", SHA_A, "r5", 4, "unverifiable", "readable_document"),
            ("2026-10-22T00:00:00Z", SHA_B, "r5", 4, "verified", ""),           # ANOTHER document verified (QA #1418)
            ("2026-10-20T00:00:00Z", SHA_C, "r6", 5, "unverifiable", "readable_document"),         # no intake row
            ("2026-10-20T00:00:00Z", SHA_A, "r7", 6, "unverifiable", "readable_document"),         # not pending now
            ("2026-10-20T00:00:00Z", SHA_A, "r8", 7, "contradicted", "readable_document"),         # not unverifiable
            ("2026-10-20T00:00:00Z", SHA_A, "r9", 8, "unverifiable", "readable_document"),         # email intake
        ]
        db.executemany("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)", rows)
        db.commit(); db.close()
        self.proof = str(self.d / "proof.sqlite")
        db = sqlite3.connect(self.proof)
        db.execute("CREATE TABLE proof_intake (user_id INTEGER, file_sha256 TEXT, received_at TEXT, mime TEXT, conversation_id TEXT, "
                   "intake_id TEXT, matched_by TEXT DEFAULT 'professional_id')")
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) VALUES (8,?,?,?,?,?)", (SHA_A, "2026-10-18T09:30:00Z", "image/jpeg", "email:9f2c", "8:a"))
        for u in (1, 2, 3, 4, 6, 7):
            db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) VALUES (?,?,?,?,?,?)", (u, SHA_A, "2026-10-18T09:30:00Z", "image/jpeg", "777", f"{u}:a"))
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) VALUES (1,?,?,?,?,?)", (SHA_B, "2026-10-19T10:00:00Z", "application/pdf", "778", "1:b"))
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) VALUES (4,?,?,?,?,?)", (SHA_B, "2026-10-21T10:00:00Z", "image/png", "779", "4:b"))
        db.commit(); db.close()
        self.paying = self.d / "paying.json"
        self.paying.write_text(json.dumps({"ids": [1]}))
        self.pending = {1: ["r1", "r2"], 2: ["r3"], 3: ["r4"], 4: ["r5"], 5: ["r6"], 6: [], 7: ["r8"], 8: ["r9"]}

    def q(self, sql):
        if "FROM postgresql_core.public.users" in sql:
            return [[str(u), f"u{u}@x.com", "Jane", "", ""] for u in self.pending]
        out = []
        for u, rids in self.pending.items():
            for r in rids:
                out.append([r, str(u), "p1", "t1", f"Song {r}", '[{"name": "Big Star"}]', "{Mixing}", "40", "{}", "{}"])
        return out

    def build(self):
        return na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q)

    def test_core_proof_request_is_recorded_not_counted_as_an_l11c_ask(self):
        # p1 178: core's generic proofRequest on a named request is recorded as ask_class=core_proof_request (audit);
        # it never blocks the L11c follow-up (the 7-day core_notice gate is separate)
        a, b = "11111111-2222-3333-4444-555555555555", "AAAAAAAA-2222-3333-4444-555555555555"
        seen = []

        def q(sql):
            seen.append(sql)
            return [[a, "true"], [b.lower(), "false"]]
        self.assertEqual(na.core_proof_requested([a, b, "x'); DROP TABLE t; --"], q), {a})
        self.assertNotIn("DROP", " ".join(seen))                 # only well-formed ids reach the SQL
        self.assertEqual(na.core_proof_requested(["r1"], q), set())
        self.pending[1] = ["r1"]
        db = sqlite3.connect(self.proof)          # only document A on file, so its ask is not held by a newer intake
        db.execute("DELETE FROM proof_intake WHERE user_id=1 AND file_sha256=?", (SHA_B,)); db.commit(); db.close()
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        _rep, gate = self.send_(lst)
        self.assertEqual({c["ask_class"] for c in gate.calls[0][1]["credits"]}, {"asked"})

    def test_the_audience(self):
        res = self.build()
        first = res
        by = {u["user_id"]: u for u in res["users"]}
        # user 1; user 4 (QA #1418: its document A still needs a readable copy - document B's verified read does not
        # hide it); email-filed user 8 (free)
        self.assertEqual(sorted(by), ["1", "4", "8"])
        self.assertEqual([(a["request_id"], a["doc_sha"]) for a in by["4"]["asks"]], [("r5", SHA_A)])
        self.assertEqual((by["8"]["paid"], by["8"]["asks"][0]["filing_conversation"]), (False, "email"))
        # l1 [key=l11c-email-filed]: an email filing matched by a weak identity is never asked (tray)
        db = sqlite3.connect(self.proof)
        db.execute("UPDATE proof_intake SET matched_by='proof_on_file' WHERE user_id=8"); db.commit(); db.close()
        res = self.build()
        self.assertNotIn("8", {u["user_id"] for u in res["users"]})
        self.assertEqual(res["counts"]["skip_email_filed_weak_identity"], 1)
        db = sqlite3.connect(self.proof)
        db.execute("UPDATE proof_intake SET matched_by='authenticated_email' WHERE user_id=8"); db.commit(); db.close()
        self.assertEqual([a["request_id"] for a in by["1"]["asks"]], ["r1", "r2"])
        a1, a2 = by["1"]["asks"]
        self.assertEqual((a1["need"], a1["doc_sha"], a1["doc_kind"], a1["filing_conversation"], a1["doc_received_at"]),
                         ("readable_document", SHA_A, "image", "777", "2026-10-18T09:30:00Z"))
        self.assertEqual((a2["need"], a2["doc_kind"], a2["filing_conversation"]), ("counterparty_signed_or_registered", "PDF", "778"))
        c = first["counts"]
        self.assertEqual((c["skip_no_code_issuer"], c["skip_verify_at_off"], c["skip_no_intake_row"],
                          c["skip_not_pending"], c["list_paid"], c["email_filed_rows"]), (1, 1, 1, 1, 1, 1))
        # the SAME document re-read as verified: no longer askable
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-10-23T00:00:00Z", SHA_A, "r5", 4, "verified", ""))
        db.commit(); db.close()
        self.assertNotIn("4", {u["user_id"] for u in self.build()["users"]})


    def send_(self, lst, **kw):
        gate = FakeGate()
        rep = na.send(list_path=str(lst), segment=kw.pop("segment", "paid"), query=self.q, runner=gate, preview_dir=str(self.d),
                      ledger_path=str(self.d / "ledger.sqlite3"), **kw)
        return rep, gate

    def test_one_message_per_user_per_need_counterparty_first_naming_every_request_newest_document(self):
        # [key=l11c-plural]: user 1 has a readable request (r1, doc A, conv 777) and counterparty ones
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-10-22T00:00:00Z", SHA_C, "r10", 1, "unverifiable", "counterparty_signed_or_registered"))
        db.commit(); db.close()
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) VALUES (1,?,?,?,?,?)", (SHA_C, "2026-10-25T10:00:00Z", "image/png", "780", "1:c"))
        db.commit(); db.close()
        self.pending[1] = ["r1", "r2", "r10"]
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        rep, gate = self.send_(lst)
        self.assertEqual(len(gate.calls), 1)                                   # ONE message for this user
        argv, p = gate.calls[0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "proof-need-ask")
        self.assertIn("--dry-run", argv)
        # p1 156: the unit is (user, DOCUMENT) - the newest counterparty document (C) and only ITS requests
        self.assertEqual(sorted(c["request_id"] for c in p["credits"]), ["r10"])
        self.assertEqual(p["need"], {"code": "counterparty_signed_or_registered", "doc_sha": SHA_C,
                                     "doc_received_at": "2026-10-25T10:00:00Z", "doc_kind": "image", "doc_count": 1, "doc_shas": [SHA_C],
                                     "doc_map": {"r10": SHA_C}, "doc_intakes": {SHA_C: "1:c"}})   # the newest doc + its intake
        self.assertEqual(p["user"]["filing_conversation"], "780")
        self.assertEqual(rep.validated, 1)
        # QA #1418 (04:52Z): the OLDER documents (r2 on B 10-19, r1 on A 10-18) arrived before C (10-25): the send would
        # hold them ('anything newer', comm_state.newer_intake), so the builder applies the SAME rule - listed as held,
        # never selected and retried every run
        from credit_review import verify_ledger
        vdb = verify_ledger.connect(str(self.d / "ledger.sqlite3"))
        vdb.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                    "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                    "VALUES ('proof-need-ask','initial','u1@x.com','1','2026-10-19','sent','comment','[\"r10\"]',1,'U','r',"
                    "'2026-10-19','2026-10-19','2026-10-19')")
        vdb.execute("INSERT INTO verify_requests (campaign, request_id, message_row, status, attempts, updated_at) "
                    "VALUES ('proof-need-ask', 'r10', 1, 'sent', 1, '2026-10-19')")
        vdb.commit(); vdb.close()
        rep, gate = self.send_(lst)
        self.assertEqual(gate.calls, [])
        self.assertEqual(sorted(rep.held_newer), ["user 1: counterparty_signed_or_registered (an intake newer than its newest document)",
                                                  "user 1: readable_document (an intake newer than its newest document)"])
        # the free side: user 4's readable document A (10-18) is older than its B intake (10-21): held, not sent;
        # the email-filed user 8 is asked by Intercom email (p1 152)
        rep, gate = self.send_(lst, segment="free")
        convs = {c[1]["user"]["id"]: c[1]["user"]["filing_conversation"] for c in gate.calls}
        self.assertEqual(convs, {"8": "email"})
        self.assertEqual(rep.held_newer, ["user 4: readable_document (an intake newer than its newest document)"])

    def test_qa_1418_a_held_old_need_never_blocks_a_readable_new_one(self):
        # QA #1418 04:52Z repro: day-1 counterparty need, day-2 readable need. Counterparty is FIRST in NEED_ORDER, but
        # its newest document is older than the day-2 intake -> the send would hold it; the readable need goes instead
        u = {"user_id": "1", "paid": True, "arrivals": ["2026-10-18T09:30:00Z", "2026-10-19T10:00:00Z"], "asks": [
            {"request_id": "r1", "need": "counterparty_signed_or_registered", "doc_sha": SHA_A,
             "doc_received_at": "2026-10-18T09:30:00Z", "doc_kind": "image", "filing_conversation": "777", "matched_by": ""},
            {"request_id": "r2", "need": "readable_document", "doc_sha": SHA_B, "doc_received_at": "2026-10-19T10:00:00Z",
             "doc_kind": "PDF", "filing_conversation": "778", "matched_by": ""}]}
        self.pending[1] = ["r1", "r2"]
        held = []
        ps = na.payloads([u], self.q, None, held)
        self.assertEqual([(p["need"]["code"], [c["request_id"] for c in p["credits"]]) for p in ps], [("readable_document", ["r2"])])
        self.assertEqual(held, ["user 1: counterparty_signed_or_registered (an intake newer than its newest document)"])
        # and comm_state, at send, agrees on both (one predicate)
        from credit_review import comm_state as cs
        self.assertTrue(cs.newer_intake("2026-10-18T09:30:00Z", u["arrivals"]))
        self.assertFalse(cs.newer_intake("2026-10-19T10:00:00Z", u["arrivals"]))

    def test_qa_repro_one_request_two_documents_both_survive_the_audience(self):
        # QA #1418 (need_asks.py:64 and :94): outcomes keyed (user, request) let one document overwrite another
        tray = self.d / "tray2.json"
        tray.write_text(json.dumps({"rows": {
            "readable_document": {"paid": [{"request_id": "r5", "user_id": 4, "outcome": "unverifiable", "intake_id": "4:a"}]},
            "counterparty_signed_or_registered": {"paid": [
                {"request_id": "r5", "user_id": 4, "outcome": "unverifiable", "intake_id": "4:b"}]}}}))
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q, tray=str(tray))
        asks = {(a["need"], a["doc_sha"]) for u in res["users"] if u["user_id"] == "4" for a in u["asks"]}
        self.assertEqual(asks, {("readable_document", SHA_A), ("counterparty_signed_or_registered", SHA_B)})

    def test_qa_round7_repro_a_same_file_reupload_never_replaces_the_read_and_holds_at_send(self):
        # QA #1418 round 7: user 1 sent file A on 10-18 (read 10-20: unreadable), then the IDENTICAL file again on 10-26
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) "
                   "VALUES (1,?,?,?,?,?)", (SHA_A, "2026-10-26T08:00:00Z", "image/jpeg", "790", "1:a2"))
        db.commit(); db.close()
        self.pending[1] = ["r1"]
        users = [u for u in self.build()["users"] if u["user_id"] == "1"]
        # the read is the 10-18 arrival (thread 777); the later same-file intake is 'anything newer' - the builder and the
        # send now agree (QA 04:52Z): it is listed held, never selected
        self.assertEqual(users[0]["asks"][0]["doc_received_at"], "2026-10-18T09:30:00Z")
        held = []
        self.assertEqual(na.payloads(users, self.q, None, held), [])
        self.assertEqual(held, ["user 1: readable_document (an intake newer than its newest document)"])
        from credit_review import comm_state as cs
        cs.DV_STORE, cs.PROOF_STORE = self.dv, self.proof
        facts = cs.need_facts(1, ["r1"], SHA_A, "2026-10-18T09:30:00Z", "readable_document", {"r1": SHA_A})
        self.assertIn("newer_document:proof_intake", facts["newer"])
        # with dv_outcomes.intake_id (the doc-verify runner writes it) the read names its intake exactly
        db = sqlite3.connect(self.dv)
        db.execute("ALTER TABLE dv_outcomes ADD COLUMN intake_id TEXT")
        db.execute("UPDATE dv_outcomes SET intake_id='1:a2' WHERE user_id=1 AND lower(request_id)='r1'")
        db.commit(); db.close()
        p = na.payloads([u for u in self.build()["users"] if u["user_id"] == "1"], self.q)[0]
        self.assertEqual((p["need"]["doc_received_at"], p["user"]["filing_conversation"]), ("2026-10-26T08:00:00Z", "790"))

    def test_only_the_newest_days_documents_in_one_thread(self):
        # Fable 166: same need, same thread, two days -> the message names only the newest day's document's requests
        u = {"user_id": "1", "paid": True, "asks": [
            {"request_id": "r1", "need": "readable_document", "doc_sha": SHA_A, "doc_received_at": "2026-10-18T09:30:00Z",
             "doc_kind": "image", "filing_conversation": "777", "matched_by": ""},
            {"request_id": "r2", "need": "readable_document", "doc_sha": SHA_C, "doc_received_at": "2026-10-25T10:00:00Z",
             "doc_kind": "PDF", "filing_conversation": "777", "matched_by": ""}]}
        self.pending[1] = ["r1", "r2"]
        p = na.payloads([u], self.q)[0]
        self.assertEqual(([c["request_id"] for c in p["credits"]], p["need"]["doc_map"]), (["r2"], {"r2": SHA_C}))

    def test_qa_1418_two_same_day_documents_for_one_request_are_both_in_the_ask(self):
        # QA #1418 (need_asks.py:234): two same-day, same-need, same-thread documents for ONE request - the note says two
        # documents, both shas (and intakes) ride the ask (so the once-per-request lock covers both); the request is
        # named once, on its newest document
        u = {"user_id": "1", "paid": True, "asks": [
            {"request_id": "r1", "need": "readable_document", "doc_sha": SHA_A, "doc_received_at": "2026-10-25T09:00:00Z",
             "doc_kind": "image", "filing_conversation": "777", "matched_by": "", "intake_id": "1:a"},
            {"request_id": "r1", "need": "readable_document", "doc_sha": SHA_C, "doc_received_at": "2026-10-25T10:00:00Z",
             "doc_kind": "image", "filing_conversation": "777", "matched_by": "", "intake_id": "1:c"}]}
        self.pending[1] = ["r1"]
        p = na.payloads([u], self.q)[0]
        self.assertEqual([c["request_id"] for c in p["credits"]], ["r1"])
        self.assertEqual((p["need"]["doc_count"], p["need"]["doc_shas"]), (2, sorted([SHA_A, SHA_C])))
        self.assertEqual(p["need"]["doc_map"], {"r1": SHA_C})
        self.assertEqual(p["need"]["doc_intakes"], {SHA_A: "1:a", SHA_C: "1:c"})

    def test_qa_1418_same_second_documents_in_two_conversations_hold_in_the_builder_as_at_send(self):
        # QA #1418 (03:1xZ): A (conv 777) and B (conv 778) of the same need arrive in the SAME second. The group names
        # one conversation's document only; the other same-second intake is newer at send - the builder must agree
        # (held here, never a selected-but-unsendable user eating a batch slot)
        at = "2026-10-25T10:00:00Z"
        u = {"user_id": "1", "paid": True,
             "arrivals": [[at, "1:a"], [at, "1:b"]],
             "asks": [
                 {"request_id": "r1", "need": "readable_document", "doc_sha": SHA_A, "doc_received_at": at,
                  "doc_kind": "image", "filing_conversation": "777", "matched_by": "", "intake_id": "1:a"},
                 {"request_id": "r2", "need": "readable_document", "doc_sha": SHA_C, "doc_received_at": at,
                  "doc_kind": "image", "filing_conversation": "778", "matched_by": "", "intake_id": "1:b"}]}
        self.pending[1] = ["r1", "r2"]
        held = []
        self.assertEqual(na.payloads([u], self.q, None, held), [])
        self.assertEqual(held, ["user 1: readable_document (an intake newer than its newest document)"])
        # ... and comm_state at send agrees: with only the named group's intake, the other one is newer
        from credit_review import comm_state as cs
        newest = max(u["asks"], key=lambda a: (a["doc_received_at"], a["doc_sha"]))      # the group the send names
        self.assertTrue(cs.newer_intake(at, u["arrivals"], {newest["intake_id"]}))

    def test_qa_1418_a_group_of_more_than_20_documents_is_held_and_listed_never_a_payload(self):
        # QA #1418 (08:36Z): the gate refuses a named group larger than MAX_DOC_GROUP; the builder lists it as held
        at = "2026-10-25T10:00:00Z"
        import hashlib
        shas = [hashlib.sha256(str(i).encode()).hexdigest() for i in range(na.MAX_DOC_GROUP + 1)]
        u = {"user_id": "1", "paid": True, "arrivals": [[at, "1:a"]],
             "asks": [{"request_id": "r1", "need": "readable_document", "doc_sha": s, "doc_received_at": at,
                       "doc_kind": "image", "filing_conversation": "777", "matched_by": "", "intake_id": "1:a"}
                      for s in shas]}
        self.pending[1] = ["r1"]
        held = []
        self.assertEqual(na.payloads([u], self.q, None, held), [])
        self.assertEqual(held, [f"user 1: readable_document (21 documents in one group > 20: for a person)"])
        u["asks"] = u["asks"][:na.MAX_DOC_GROUP]                                     # 20: one ask, all 20 named
        out = na.payloads([u], self.q, None, [])
        self.assertEqual((len(out), out[0]["need"]["doc_count"], len(out[0]["need"]["doc_shas"])), (1, 20, 20))

    def test_the_gate_and_the_builder_agree_on_the_group_cap(self):
        gate = (Path(__file__).resolve().parents[1] / "intercom-verify-request.sh").read_text()
        self.assertIn(f"readonly MAX_DOC_GROUP={na.MAX_DOC_GROUP} ", gate)

    def test_the_tray_is_the_source_of_truth_for_who_and_paid(self):
        tray = self.d / "tray.json"
        tray.write_text(json.dumps({"t0": "x", "rows": {
            "readable_document": {"paid": [], "free": [
                {"request_id": "R1", "user_id": 1, "outcome": "unverifiable", "proof": "aaaa", "intake_id": "1:a"}]},
            "counterparty_signed_or_registered": {"paid": [
                {"request_id": "r5", "user_id": 4, "outcome": "unverifiable", "proof": "bbbb", "intake_id": "4:b"},
                {"request_id": "r9", "user_id": 6, "outcome": "unverifiable", "proof": "aaaa", "intake_id": "6:a",
                 "pre_t0_carried": True}], "free": []}}}))
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q, tray=str(tray))
        by = {u["user_id"]: u for u in res["users"]}
        self.assertEqual(sorted(by), ["1", "4"])            # user 4's dv row says verified, but the tray rules
        # p1 160 / b1 161: a carried pre-T0 row is askable (user 6 only lacks an intake row here), counted, not filtered
        self.assertEqual(res["counts"]["listed_pre_t0_carried"], 1)
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) "
                   "VALUES (6, ?, '2026-10-18T09:30:00Z', 'image/jpeg', '781', '6:a')", (SHA_A,)); db.commit(); db.close()
        self.pending[6] = ["r9"]
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q, tray=str(tray))
        self.assertIn("6", {u["user_id"] for u in res["users"]})
        self.assertFalse(by["1"]["paid"])                   # paid comes from the tray's segment, not paying-users.json
        self.assertTrue(by["4"]["paid"])
        self.assertEqual((by["4"]["asks"][0]["doc_sha"], by["4"]["asks"][0]["filing_conversation"]), (SHA_B, "779"))
        with self.assertRaises(na.NeedError):
            na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q,
                     tray=str(self.d / "nope.json"))

    def test_a_real_run_halts_while_the_gate_lock_is_0(self):
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        locked = self.d / "gate.sh"
        locked.write_text("readonly PROOF_NEED_ASK_COPY_APPROVED=0\n")
        gate = FakeGate()
        rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=self.q, runner=gate, wrapper=str(locked))
        self.assertIn("PROOF_NEED_ASK_COPY_APPROVED=0", rep.halted)
        self.assertEqual(gate.calls, [])
        # the committed gate is UNLOCKED (Fable [key=l11c-asks]); an unlocked stub lets the real run reach the gate
        self.assertTrue(na.uvn_status.campaign_lock_open(str(ROOT / "scripts" / "intercom-verify-request.sh"), na.LOCK))
        unlocked = self.d / "gate-open.sh"
        unlocked.write_text("readonly PROOF_NEED_ASK_COPY_APPROVED=1\n")
        rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=self.q, runner=FakeGate(), wrapper=str(unlocked),
                      ledger_path=str(self.d / "ledger.sqlite3"))
        self.assertEqual(rep.halted, "")

    def test_unreadable_inputs_list_nothing(self):
        with self.assertRaises(na.NeedError):
            na.build(dv_store=str(self.d / "nope.sqlite"), proof_store=self.proof, paying_path=str(self.paying), query=self.q)
        with self.assertRaises(na.NeedError):
            na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.d / "nope.json"), query=self.q)

    def test_doc_kind(self):
        self.assertEqual([na.doc_kind(m) for m in ("image/heic", "application/pdf", "text/plain", "")],
                         ["image", "PDF", "document", "document"])


class BoundAfterLedgerTest(unittest.TestCase):
    """QA #1418: --max-users bounds the users still askable, so a second bounded run reaches the next users."""

    def test_two_bounded_batches_reach_every_user(self):
        from unittest import mock
        from credit_review import verify_ledger
        d = Path(tempfile.mkdtemp())
        lst = d / "list.json"
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]}
                                             for u in (1, 2, 3)]}))
        ledger = str(d / "ledger.sqlite3")
        seen = []

        def payloads(users, query, asked, held=None):
            seen.append([u["user_id"] for u in users])
            return []
        with mock.patch.object(na, "payloads", payloads):
            na.send(list_path=str(lst), segment="paid", max_users=2, query=lambda sql: [], runner=FakeGate(), ledger_path=ledger)
            db = verify_ledger.connect(ledger)               # batch 1 was sent: users 1 and 2 are in the ledger
            for u in (1, 2):
                g = verify_ledger.claim(db, user_key=f"u{u}@x.com", day="2026-10-29", request_ids=[f"r{u}"],
                                        message_type="comment", approved_by="U", approval_ref="ref", campaign=na.CAMPAIGN,
                                        user_id=str(u))
                verify_ledger.finalize(db, message_row=int(g["message_row"]), status="sent", message_id="1")
            db.close()
            na.send(list_path=str(lst), segment="paid", max_users=2, query=lambda sql: [], runner=FakeGate(), ledger_path=ledger)
        self.assertEqual([x[:2] for x in seen][0], ["1", "2"])
        self.assertEqual(seen[1], ["3"])

    def test_a_stale_first_page_never_consumes_the_batch(self):
        # QA #1418: users 1 and 2 no longer have a live pending request (payloads drops them); --max-users 2 reaches 3
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "list.json"
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]}
                                             for u in (1, 2, 3, 4)]}))
        sent = []

        def payloads(users, query, asked, held=None):
            return [{"user": {"id": u["user_id"]}, "credits": []} for u in users if u["user_id"] not in ("1", "2")]

        def send_all(ps, report, **kw):
            sent.extend(p["user"]["id"] for p in ps)
        with mock.patch.object(na, "payloads", payloads), mock.patch.object(na.verify_notify, "send_all", send_all):
            rep = na.send(list_path=str(lst), segment="paid", max_users=1, query=lambda sql: [], runner=FakeGate(),
                          ledger_path=str(d / "ledger.sqlite3"))
        self.assertEqual(sent, ["3"])
        self.assertEqual((rep.candidates, rep.not_found), (1, 2))


class SameSecondIntakeBuilderTest(unittest.TestCase):
    """QA #1513: the builder applies the SAME predicate - another intake in the named document's second holds it."""

    def test_builder_and_send_share_the_rule(self):
        import inspect
        src = inspect.getsource(na.payloads)
        self.assertIn("comm_state.newer_intake(newest[\"doc_received_at\"], u.get(\"arrivals\") or [],", src)
        named = {"42:i1"}
        self.assertTrue(na.comm_state.newer_intake("2026-10-18T09:30:00Z", [["2026-10-18T09:30:00Z", "42:i2"]], named))
        self.assertFalse(na.comm_state.newer_intake("2026-10-18T09:30:00Z", [["2026-10-18T09:30:00Z", "42:i1"]], named))


if __name__ == "__main__":
    unittest.main()
