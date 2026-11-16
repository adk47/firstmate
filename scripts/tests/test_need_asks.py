"""credit_review/need_asks.py: the L11c audience (p1 rulings 096/098) and its sender path (the gate decides the rest)."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import json
import sqlite3
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
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
        # the fixture documents are dated 2026-10; the 180-day wait rule has its own test (no wall-clock time bomb)
        p = unittest.mock.patch.object(na, "STALE_FILING_DAYS", 10 ** 6)
        p.start(); self.addCleanup(p.stop)
        self.d = Path(tempfile.mkdtemp())
        # the intake states (comm_state.intake_states) are NOT measured in this class: its stores are absent, so every
        # test here runs the unmeasured rule (anything newer holds) and never reads a host's real stores.
        # NewerIntakeStatesTest measures them.
        for name in ("PROOF_STORE", "DV_STORE", "LEDGER"):
            p = unittest.mock.patch.object(na.comm_state, name, str(self.d / f"absent-{name}.sqlite"))
            p.start(); self.addCleanup(p.stop)
        self.dv = str(self.d / "dv.sqlite")
        db = sqlite3.connect(self.dv)
        db.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, proof_id TEXT, request_id TEXT, "
                   "user_id INTEGER, outcome TEXT, need TEXT)")
        rows = [  # (at, sha, request, user, outcome, need)
            ("2026-10-20T00:00:00Z", SHA_A, "R1", 1, "unverifiable", "readable_document"),        # listed
            ("2026-10-21T00:00:00Z", SHA_B, "r2", 1, "unverifiable", "counterparty_signed_or_registered"),
            ("2026-10-20T00:00:00Z", SHA_A, "r3", 2, "unverifiable", "distributor_dashboard_with_code"),  # F9 code ask
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
        if sql == na.owing_proof.STATUS_GUARD_SQL:                # every status in the table, read before the facts
            return [[s] for s in getattr(self, "table_statuses",
                                         ("approved", "rejected", "unverified", "user_verification_needed"))]
        if sql.startswith(na.FACTS_SQL):                          # r5 #1582 (c): the signing header's facts read
            # [key=facts-scope]: the re-read is the SAME query restricted to this page's users, so match the prefix
            st = getattr(self, "facts_status", {})
            return [[str(u), r.lower(), st.get(r, "user_verification_needed"), "false"]
                    for u, rids in self.pending.items() for r in rids]
        out = []
        for u, rids in self.pending.items():
            for r in rids:
                out.append([r, str(u), "p1", "t1", f"Song {r}", '[{"name": "Big Star"}]', "{Mixing}", "40",
                            json.dumps(getattr(self, "verdicts", {}).get(r, {})), "{}"])
        return out

    def build(self):
        return na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q)

    def test_a_document_older_than_180_days_waits_for_a_human_with_a_due_at(self):
        # fable-copy-1030-r5/l2 (1) / p1 552: the row is not asked about; it is LISTED as wait:stale_filing, due a day out
        now = datetime(2027, 4, 17, 12, 0, tzinfo=timezone.utc)      # the 10-18 documents are 181 days back, 10-19 180
        with unittest.mock.patch.object(na, "STALE_FILING_DAYS", 180):
            res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q, now=now)
        asked = {a["request_id"] for u in res["users"] for a in u["asks"]}
        waits = {w["request_id"]: w for w in res["waits"]}
        self.assertEqual(sorted(waits), ["r1", "r3", "r5", "r9"])     # the 10-18 documents wait ...
        self.assertIn("r2", asked)                                    # ... the 10-19 one (exactly 180 days) is asked
        self.assertFalse(set(waits) & asked)
        self.assertTrue(all(w["reason"] == "wait:stale_filing" and w["due_at"] == "2027-04-18T12:00:00+00:00" for w in waits.values()))
        self.assertEqual(res["counts"]["wait_stale_filing"], len(waits))
        with unittest.mock.patch.object(na, "STALE_FILING_DAYS", 180):
            self.assertTrue(na.stale_filing("2026-10-18T23:59:00Z", now))
            self.assertFalse(na.stale_filing("2026-10-19T00:00:00Z", now))
            self.assertFalse(na.stale_filing("not a date", now))

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

    def test_core_proof_requested_is_one_pushed_down_read_for_every_payload(self):
        # throughput (firstmate 651, measured 11-02): lower(CAST(id)) IN (...) is a ~14 s full scan and it ran once PER
        # USER; the read is now a typed `id IN (UUID '...')` predicate (pushed down: ~2 s per <= 200 ids) run ONCE for all
        # payloads, and ask_class is unchanged
        ids = [f"{i:08x}-2222-3333-4444-555555555555" for i in range(450)]
        seen = []

        def q(sql):
            seen.append(sql)
            return [[ids[7], "true"], [ids[300], "true"]]
        bad = "1111111122223333-4444-5555555555555-"                     # 36 hex/dash chars, not a UUID (fails UUID '')
        got = na.core_proof_requested(ids + ["not-a-uuid", "11111111-2222-3333-4444-55555555555Z", bad], q)
        self.assertEqual(got, {ids[7], ids[300]})
        self.assertEqual(len(seen), 3)                                   # 200 + 200 + 50
        for sql in seen:
            self.assertNotIn("lower(CAST(id", sql.split("FROM")[1])     # the predicate, not the select list
            self.assertLessEqual(sql.count("UUID '"), 200)
            self.assertNotIn("not-a-uuid", sql)
            self.assertNotIn("5555555Z", sql)
            self.assertNotIn(bad, sql)
        self.assertIn(f"WHERE id IN (UUID '{ids[0]}'", seen[0])
        calls = []
        real = na.core_proof_requested

        def counting(rids, query):
            calls.append(list(rids))
            return {rids[0].lower()} if rids else set()
        users = self.build()["users"]
        with unittest.mock.patch.object(na, "core_proof_requested", counting):
            ps = na.payloads(users, self.q)
        self.assertGreater(len(ps), 1)
        self.assertEqual(len(calls), 1)                                  # one read for all payloads, never per user
        self.assertEqual(sorted(calls[0]), sorted(c["request_id"] for p in ps for c in p["credits"]))
        classes = [c["ask_class"] for p in ps for c in p["credits"]]
        self.assertEqual(classes.count("core_proof_request"), 1)
        self.assertEqual(classes[0], "core_proof_request")
        self.assertIs(na.core_proof_requested, real)

    def test_a_mixed_batch_lists_paying_users_first_whatever_order_the_source_rows_came_in(self):
        # every listed user's first document arrived in the same second, so only the paying flag and then the user id
        # decide the order (credit_review/audience_order.py). The paying users carry the LARGER ids on purpose: a list
        # that merely followed the user id, or the order of the replica's rows, would put 1 and 2 first.
        self.paying.write_text(json.dumps({"ids": [4, 8]}))
        want = [("4", True), ("8", True), ("1", False), ("2", False)]
        self.assertEqual([(u["user_id"], u["paid"]) for u in self.build()["users"]], want)
        self.pending = dict(reversed(list(self.pending.items())))        # the replica returns its rows the other way
        self.assertEqual([(u["user_id"], u["paid"]) for u in self.build()["users"]], want)

    def test_the_audience(self):
        res = self.build()
        first = res
        by = {u["user_id"]: u for u in res["users"]}
        # user 1; user 4 (QA #1418: its document A still needs a readable copy - document B's verified read does not
        # hide it); email-filed user 8 (free)
        # ... and user 2: the distributor-code ask is captain-approved (p1 208)
        self.assertEqual(sorted(by), ["1", "2", "4", "8"])
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
        self.assertNotIn("skip_no_code_issuer", c)                           # distributor asks are listed now
        self.assertEqual((c["skip_verify_at_off"], c["skip_no_intake_row"],
                          c["skip_not_pending"], c["list_paid"], c["email_filed_rows"]), (1, 1, 1, 1, 1))
        # the SAME document re-read as verified: no longer askable
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-10-23T00:00:00Z", SHA_A, "r5", 4, "verified", ""))
        db.commit(); db.close()
        self.assertNotIn("4", {u["user_id"] for u in self.build()["users"]})


    def test_a_read_that_failed_on_our_side_is_never_sent_to_the_customer(self):
        # an `unknown` read means doc-verify could not answer (provider down, cap, no key): our failure, and the
        # retry layer re-reads the same file. Asking would tell the user their document is hard to read - false,
        # and it asks them to redo work we are already doing - so no ask may leave on an `unknown` row.
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-10-20T00:00:00Z", SHA_A, "r10", 9, "unknown", ""))
        db.commit(); db.close()
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) "
                   "VALUES (9,?,?,?,?,?)", (SHA_A, "2026-10-18T09:30:00Z", "image/jpeg", "777", "9:a"))
        db.commit(); db.close()
        self.pending[9] = ["r10"]
        self.assertEqual(self.build()["counts"]["skip_reader_failed"], 1)
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        rep, gate = self.send_(lst, segment="free")
        sent = {c[1]["user"]["id"]: c[1]["need"] for c in gate.calls}
        self.assertNotIn("9", sent)

    def unlisted(self, outcome, need):
        # one more document, for user 9, whose latest doc-verify row is (outcome, need): the counts before it, and
        # the build with it
        before = self.build()["counts"]
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-10-20T00:00:00Z", SHA_A, "r10", 9, outcome, need))
        db.commit(); db.close()
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) "
                   "VALUES (9,?,?,?,?,?)", (SHA_A, "2026-10-18T09:30:00Z", "image/jpeg", "777", "9:a"))
        db.commit(); db.close()
        self.pending[9] = ["r10"]
        return before, self.build()

    def test_an_unverifiable_read_that_names_no_need_is_counted_under_its_own_name_and_not_asked(self):
        before, res = self.unlisted("unverifiable", "")
        self.assertEqual(res["counts"]["skip_unverifiable_no_need"], before.get("skip_unverifiable_no_need", 0) + 1)
        self.assertEqual(res["counts"].get("skip_reader_failed", 0), before.get("skip_reader_failed", 0))
        self.assertNotIn("9", {u["user_id"] for u in res["users"]})

    def test_a_read_with_another_outcome_is_counted_and_not_asked(self):
        before, res = self.unlisted("verified", "readable_document")
        self.assertEqual(res["counts"]["skip_not_unverifiable"], before.get("skip_not_unverifiable", 0) + 1)
        self.assertEqual(res["counts"].get("skip_reader_failed", 0), before.get("skip_reader_failed", 0))
        self.assertNotIn("9", {u["user_id"] for u in res["users"]})

    def test_the_send_never_asks_for_a_document_on_a_request_the_approved_elsewhere_line_went_out_for(self):
        # every entry point passes the send: a list built WITHOUT --blocked-stamps still cannot ask twice, because
        # the send reads the ledger row the approved-elsewhere send wrote
        from credit_review import verify_ledger
        self.pending[1] = ["r1"]
        db = sqlite3.connect(self.proof)          # only document A on file, so its ask is not held by a newer intake
        db.execute("DELETE FROM proof_intake WHERE user_id=1 AND file_sha256=?", (SHA_B,)); db.commit(); db.close()
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        _rep, gate = self.send_(lst)
        self.assertEqual([[c["request_id"] for c in call[1]["credits"]] for call in gate.calls], [["r1"]])
        vdb = verify_ledger.connect(str(self.d / "ledger.sqlite3"))
        c = verify_ledger.claim(vdb, campaign=na.ELSEWHERE_CAMPAIGN, user_key="u1@x.com", day="2026-10-20",
                                request_ids=["r1"], message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                user_id="1")
        self.assertEqual(c["result"], "claimed")
        verify_ledger.finalize(vdb, message_row=c["message_row"], status="sent", message_id="m1")
        vdb.close()
        rep, gate = self.send_(lst)
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.halted, "")
        self.assertEqual([f["user"] for f in rep.filtered], ["1"])

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
        # the free side: user 2 (distributor code, masked in a dry run) and the email-filed user 8 (Intercom email, p1 152);
        # user 4's readable document A (10-18) is older than its B intake (10-21): held, not sent
        rep, gate = self.send_(lst, segment="free")
        convs = {c[1]["user"]["id"]: c[1]["user"]["filing_conversation"] for c in gate.calls}
        self.assertEqual(convs, {"2": "777", "8": "email"})
        self.assertEqual(rep.held_newer, ["user 4: readable_document (an intake newer than its newest document)"])
        d = next(c[1] for c in gate.calls if c[1]["user"]["id"] == "2")
        self.assertEqual((d["need"]["code"], d["need"]["verify_code"], len(d["credits"])),
                         ("distributor_dashboard_with_code", na.CODE_PLACEHOLDER, 1))

    def test_qa_1513_same_second_intakes_in_two_threads_are_held_by_the_builder_like_the_send(self):
        # QA #1513 17:13Z repro: two documents of ONE need, the SAME second, filed in DIFFERENT conversations. The group
        # names one thread only; the send's newer_intake (over need.doc_intakes) sees the other intake as newer and holds.
        # The builder must hold it too (never selected, so a held user never takes a --max-users slot run after run).
        t = "2026-10-20T08:00:00Z"
        u = {"user_id": "1", "paid": True, "arrivals": [[t, "1:a"], [t, "1:b"]], "asks": [
            {"request_id": "r1", "need": "readable_document", "doc_sha": SHA_A, "doc_received_at": t, "doc_kind": "PDF",
             "filing_conversation": "777", "matched_by": "", "intake_id": "1:a"},
            {"request_id": "r2", "need": "readable_document", "doc_sha": SHA_B, "doc_received_at": t, "doc_kind": "PDF",
             "filing_conversation": "778", "matched_by": "", "intake_id": "1:b"}]}
        self.pending[1] = ["r1", "r2"]
        held = []
        self.assertEqual(na.payloads([u], self.q, None, held), [])
        self.assertEqual(held, ["user 1: readable_document (an intake newer than its newest document)"])
        # and the send-time predicate, given what the message WOULD have named, agrees
        newest = max(u["asks"], key=lambda a: (a["doc_received_at"], a["doc_sha"]))
        self.assertTrue(na.comm_state.newer_intake(t, u["arrivals"], {newest["intake_id"]}))
        # same second, SAME thread: both documents are in the group, both intakes named -> it goes (no false hold)
        for a in u["asks"]:
            a["filing_conversation"] = "777"
        held = []
        ps = na.payloads([u], self.q, None, held)
        self.assertEqual(held, [])
        self.assertEqual(sorted(c["request_id"] for c in ps[0]["credits"]), ["r1", "r2"])
        self.assertEqual(ps[0]["need"]["doc_intakes"], {SHA_A: "1:a", SHA_B: "1:b"})

    def test_qa_1418_a_held_old_need_never_blocks_a_readable_new_one(self):
        # QA #1418 04:52Z repro: day-1 counterparty need, day-2 readable need. Counterparty is FIRST in NEED_ORDER, but
        # its newest document is older than the day-2 intake -> the send would hold it; the readable need goes instead.
        # The need with the newest document is now taken FIRST, so the older need is never judged for this user: it is
        # no longer listed as held behind an ask that went.
        u = {"user_id": "1", "paid": True, "arrivals": ["2026-10-18T09:30:00Z", "2026-10-19T10:00:00Z"], "asks": [
            {"request_id": "r1", "need": "counterparty_signed_or_registered", "doc_sha": SHA_A,
             "doc_received_at": "2026-10-18T09:30:00Z", "doc_kind": "image", "filing_conversation": "777", "matched_by": ""},
            {"request_id": "r2", "need": "readable_document", "doc_sha": SHA_B, "doc_received_at": "2026-10-19T10:00:00Z",
             "doc_kind": "PDF", "filing_conversation": "778", "matched_by": ""}]}
        self.pending[1] = ["r1", "r2"]
        held = []
        ps = na.payloads([u], self.q, None, held)
        self.assertEqual([(p["need"]["code"], [c["request_id"] for c in p["credits"]]) for p in ps], [("readable_document", ["r2"])])
        self.assertEqual(held, [])
        # and comm_state, at send, agrees on both (one predicate)
        from credit_review import comm_state as cs
        self.assertTrue(cs.newer_intake("2026-10-18T09:30:00Z", u["arrivals"]))
        self.assertFalse(cs.newer_intake("2026-10-19T10:00:00Z", u["arrivals"]))

    def test_distributor_codes_are_issued_at_send_only_and_one_request_per_ask(self):
        # p1 208: the F9 code is issued when the ask is SENT (apply); a dry run issues nothing (masked placeholder);
        # a code that cannot be issued drops that ask; one code verifies one request
        base = {"user": {"id": "2"}, "credits": [{"request_id": "r3"}], "need": {"code": "distributor_dashboard_with_code"}}
        other = {"user": {"id": "1"}, "credits": [{"request_id": "r1"}], "need": {"code": "readable_document"}}
        calls = []
        rep = na.verify_notify.Report()
        out = na.with_codes([base, other], "dry-run", rep, issuer=lambda rid, uid: calls.append(rid) or "MUSO-AB12")
        self.assertEqual((calls, out[0]["need"]["verify_code"], out[1]), ([], na.CODE_PLACEHOLDER, other))
        out = na.with_codes([base, other], "apply", rep, issuer=lambda rid, uid: calls.append((rid, uid)) or "MUSO-AB12")
        self.assertEqual((calls, out[0]["need"]["verify_code"]), ([("r3", "2")], "MUSO-AB12"))
        out = na.with_codes([base, other], "apply", rep, issuer=lambda rid, uid: "")
        self.assertEqual((out, rep.refusals), ([other], ["distributor_code_not_issued:r3"]))
        # QA #1513: a re-used ACTIVE code with less than the promised 7 days left is never sent; a full one is
        from datetime import datetime, timedelta, timezone
        t0 = datetime(2026, 10, 30, 6, 0, tzinfo=timezone.utc)
        short = lambda rid, uid: {"code": "MUSO-AB12", "expires_at": (t0 + timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"), "new": True}
        full = lambda rid, uid: {"code": "MUSO-CD34", "expires_at": (t0 + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"), "new": True}
        # QA #1513: a REUSED active code with 6 d 23 h 31 m left is never sent (the copy promises 7 days)
        reused = lambda rid, uid: {"code": "MUSO-EF56", "new": False,
                                   "expires_at": (t0 + timedelta(days=6, hours=23, minutes=31)).strftime("%Y-%m-%dT%H:%M:%SZ")}
        rep3 = na.verify_notify.Report()
        self.assertEqual(na.with_codes([base], "apply", rep3, issuer=reused, now=t0), [])
        self.assertEqual(rep3.refusals, ["distributor_code_not_fresh:r3"])
        rep2 = na.verify_notify.Report()
        self.assertEqual(na.with_codes([base], "apply", rep2, issuer=short, now=t0), [])
        self.assertEqual(rep2.refusals, ["distributor_code_window_short:r3"])
        self.assertEqual(na.with_codes([base], "apply", rep2, issuer=full, now=t0)[0]["need"]["verify_code"], "MUSO-CD34")
        # one request per distributor ask, the newest document's
        u = {"user_id": "2", "paid": True, "asks": [
            {"request_id": r, "need": "distributor_dashboard_with_code", "doc_sha": SHA_A, "doc_received_at": "2026-10-18T09:30:00Z",
             "doc_kind": "image", "filing_conversation": "777", "matched_by": ""} for r in ("r3", "r7")]}
        self.pending[2] = ["r3", "r7"]
        p = na.payloads([u], self.q)[0]
        self.assertEqual(len(p["credits"]), 1)

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

    def test_an_apply_spends_the_shared_credit_budget_under_the_group_lock(self):
        # QA #1617 (Critical): proof-need-ask is in the policy's credit group - other credit campaigns' sends today use
        # its budget; a signed unpaged apply short of room refuses whole (CLI 3); a held group lock sends nothing
        import fcntl
        from credit_review import verify_ledger
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        ledger = str(self.d / "ledger.sqlite3")
        unlocked = self.d / "gate-open.sh"
        unlocked.write_text("readonly PROOF_NEED_ASK_COPY_APPROVED=1\n")
        day = datetime.now(timezone.utc)
        db = verify_ledger.connect(ledger)
        for k in range(2):
            c = verify_ledger.claim(db, campaign="uvn-status", user_key=f"o{k}@x.com", day=day.strftime("%Y-%m-%d"),
                                    request_ids=[f"o{k}"], message_type="email", approved_by="U", approval_ref="r",
                                    now=day, user_id=str(900 + k))
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"9{k}")
        db.close()
        run = lambda gate: na.send(list_path=str(lst), segment="paid", mode="apply", query=self.q, runner=gate,  # noqa: E731
                                   wrapper=str(unlocked), ledger_path=ledger)
        with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", 2):        # spent by the uvn-status sends
            gate = FakeGate(); rep = run(gate)
        self.assertEqual([a for a in gate.calls if "--check-recipient" not in a], [])
        self.assertTrue(rep.outcomes and all(o["reason"].startswith("daily_cap") for o in rep.outcomes))
        with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", 2), \
                unittest.mock.patch.object(na.verify_notify, "APPLY_ONLY", frozenset({"1"})), \
                unittest.mock.patch.object(na.verify_notify, "APPLY_PAGE", False):
            gate = FakeGate(); rep = run(gate)
        self.assertTrue(getattr(rep, "cap_short", False))
        self.assertEqual([o["reason"] for o in rep.outcomes], ["daily_cap_short"])
        self.assertEqual([a for a in gate.calls if "--check-recipient" not in a], [])
        with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", 2):
            # the family clamp the ask tick applies (its daily cap read) hands --max-users; the shared credit cap still
            # stops the users past today's room
            gate = FakeGate()
            rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=self.q, runner=gate,
                          wrapper=str(unlocked), ledger_path=ledger, max_users=50)
            self.assertTrue(rep.outcomes and all(o["reason"].startswith("daily_cap") for o in rep.outcomes))
            self.assertEqual([a for a in gate.calls if "--check-recipient" not in a], [])
        with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", 3):        # one slot left: the one user goes
            gate = FakeGate(); rep = run(gate)
        self.assertEqual(rep.halted, "")
        self.assertFalse([o for o in rep.outcomes if o["reason"].startswith("daily_cap")])
        with open(f"{ledger}.credit-group.run.lock", "a+") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            gate = FakeGate(); rep = run(gate)
        self.assertIn("credit-group apply run is in progress", rep.halted)
        self.assertEqual(gate.calls, [])
        with unittest.mock.patch.object(na.uvn_status, "POLICY_OK", False):
            gate = FakeGate(); rep = run(gate)
        self.assertTrue(rep.policy_error); self.assertEqual(gate.calls, [])

    def test_an_own_lock_apply_runs_beside_the_group_lock_and_leaves_the_reserve(self):
        # firstmate 031: the ask tick's apply takes its OWN run lock, so it sends while the outbound tick holds the
        # credit-group lock; with no lock between the two writers it leaves OWN_LOCK_RESERVE of the shared cap unspent
        import fcntl
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        ledger = str(self.d / "ledger.sqlite3")
        unlocked = self.d / "gate-open.sh"
        unlocked.write_text("readonly PROOF_NEED_ASK_COPY_APPROVED=1\n")
        run = lambda gate: na.send(list_path=str(lst), segment="paid", mode="apply", query=self.q, runner=gate,  # noqa: E731
                                   wrapper=str(unlocked), ledger_path=ledger, own_lock=True)
        sends = lambda gate: [a for a in gate.calls if "--check-recipient" not in a]  # noqa: E731
        with open(f"{ledger}.credit-group.run.lock", "a+") as group:
            fcntl.flock(group.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)      # the outbound tick is applying
            with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", na.OWN_LOCK_RESERVE):
                gate = FakeGate(); rep = run(gate)                          # room only inside the reserve: none
            self.assertEqual(sends(gate), [])
            self.assertTrue(rep.outcomes and all(o["reason"].startswith("daily_cap") for o in rep.outcomes))
            with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", na.OWN_LOCK_RESERVE + 1):
                gate = FakeGate(); rep = run(gate)                          # one past the reserve: the one user goes
            self.assertEqual(rep.halted, "")
            self.assertEqual(len(sends(gate)), 1)
            self.assertFalse([o for o in rep.outcomes if o["reason"].startswith("daily_cap")])
        with open(na.own_lock_path(ledger), "a+") as own:
            fcntl.flock(own.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)        # another ask-tick apply is running
            gate = FakeGate(); rep = run(gate)
        self.assertIn("another ask-tick apply run is in progress", rep.halted)
        self.assertEqual(gate.calls, [])
        self.assertEqual(na._GROUP_LOCKED, {})

    def test_an_own_lock_apply_re_reads_the_family_room_under_its_lock(self):
        # QA on #2111: the tick read the family's room before its long check; the outbound tick can spend it meanwhile.
        # Under the own lock the apply reads it again, so a room spent in between sends nobody.
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        ledger = str(self.d / "ledger.sqlite3")
        unlocked = self.d / "gate-open.sh"
        unlocked.write_text("readonly PROOF_NEED_ASK_COPY_APPROVED=1\n")
        from credit_review import verify_ledger
        cap = verify_ledger.family_day_cap(na.CAMPAIGN)
        self.assertGreater(cap, 0)
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        db = verify_ledger.connect(ledger)
        for i in range(cap):                                   # the outbound tick spent the family's whole day
            db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                       "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                       "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (na.CAMPAIGN, "initial", f"o{i}@x", f"9{i}", day, "sent", "email", "[]", 1, "t", "t",
                        verify_ledger.stamp(), verify_ledger.stamp(), verify_ledger.stamp()))
        db.commit(); db.close()
        gate = FakeGate()
        with unittest.mock.patch.object(na.uvn_status, "DAILY_MAX", 10**6):
            rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=self.q, runner=gate,
                          wrapper=str(unlocked), ledger_path=ledger, own_lock=True)
        self.assertEqual([a for a in gate.calls if "--check-recipient" not in a], [])
        self.assertTrue(rep.outcomes and all(o["reason"].startswith("daily_cap") for o in rep.outcomes))

    def test_the_claim_refuses_past_the_family_cap_whoever_sends(self):
        # QA on #2111, the race itself: two senders that each believe one send is left. The claim transaction is the
        # one place both pass in order, so exactly one of them gets the last send and the other a family_cap answer.
        from credit_review import verify_ledger
        ledger = str(self.d / "race.sqlite3")
        cap = verify_ledger.family_day_cap(na.CAMPAIGN)
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        db = verify_ledger.connect(ledger)
        for i in range(cap - 1):
            db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                       "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                       "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (na.CAMPAIGN, "initial", f"o{i}@x", f"9{i}", day, "sent", "email", "[]", 1, "t", "t",
                        verify_ledger.stamp(), verify_ledger.stamp(), verify_ledger.stamp()))
        db.commit()
        answers = [verify_ledger.claim(db, user_key=f"{who}@x", day=day, request_ids=[f"req-{who}"],
                                       message_type="email", approved_by="t", approval_ref="t",
                                       campaign=na.CAMPAIGN, user_id=who)["result"] for who in ("101", "102")]
        db.close()
        self.assertEqual(answers[1], "family_cap")
        self.assertNotEqual(answers[0], "family_cap")
        self.assertEqual(verify_ledger.family_day_cap(na.CAMPAIGN, path=str(self.d / "missing.json")), 0)

    def test_the_cli_takes_the_own_lock_only_for_a_paged_signed_apply(self):
        import contextlib, io
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        for argv in (["send", "--list", str(lst), "--segment", "paid", "--own-lock"],
                     ["send", "--list", str(lst), "--segment", "paid", "--mode", "apply", "--own-lock"]):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), unittest.mock.patch.object(na, "send") as sent:
                self.assertEqual(na._main(argv), 2)
            self.assertIn("--own-lock needs --mode apply --signed-accepted CHECK --page", out.getvalue())
            sent.assert_not_called()

    def test_a_run_walks_one_page_of_list_entries_and_records_where_it_stopped(self):
        # r5 639 / p1 638: [start_entry, start_entry + max_entries) of this segment's entries, before any read; page.end =
        # the first entry this run will not examine (past --max-users), so the tick's cursor resumes exactly there
        users = [{"user_id": str(i), "paid": True, "asks": [{"request_id": f"q{i}"}]} for i in range(1, 8)]
        lst = self.d / "paged.json"
        lst.write_text(json.dumps({"users": users}))
        seen = []
        def payloads(us, q, asked, held=None, filtered=None):
            seen.append([u["user_id"] for u in us])
            return [{"user": {"id": u["user_id"]}, "credits": [{"request_id": u["asks"][0]["request_id"]}],
                     "need": {"code": "x"}} for u in us]
        with unittest.mock.patch.object(na, "payloads", payloads), \
                unittest.mock.patch.object(na.verify_notify, "send_all", lambda *a, **k: None):
            rep = na.send(list_path=str(lst), segment="paid", mode="dry-run", max_users=2, query=lambda sql: [],
                          ledger_path=str(self.d / "ledger.sqlite3"), max_entries=4, start_entry=2)
        self.assertEqual(seen, [["3", "4", "5", "6"]])                      # entries 2..5 only
        self.assertEqual(rep.page, {"start": 2, "end": 4, "listed": 7, "page_end": 6})   # users 5, 6 not examined
        self.assertEqual(sorted(rep.listed_users), ["3", "4", "5", "6"])
        with unittest.mock.patch.object(na, "payloads", payloads), \
                unittest.mock.patch.object(na.verify_notify, "send_all", lambda *a, **k: None):
            rep = na.send(list_path=str(lst), segment="paid", mode="dry-run", max_users=9, query=lambda sql: [],
                          ledger_path=str(self.d / "ledger.sqlite3"), max_entries=4, start_entry=6)
        self.assertEqual(rep.page, {"start": 6, "end": 7, "listed": 7, "page_end": 7})    # the tail; the tick wraps to 0

    def test_the_cli_passes_the_page_through_and_records_it_for_the_tick_cursor(self):
        import contextlib, io
        lst = self.d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": "1", "paid": True, "asks": []}]}))
        out, got = self.d / "o.json", {}
        def send(**kw):
            got.update(kw)
            r = na.verify_notify.Report(); r.page = {"start": 200, "end": 260, "listed": 450}
            return r
        with unittest.mock.patch.object(na, "send", send), contextlib.redirect_stdout(io.StringIO()):
            na._main(["send", "--list", str(lst), "--segment", "paid", "--check-recipients", "--max-entries", "200",
                      "--start-entry", "200", "--outcomes-json", str(out)])
        self.assertEqual((got["max_entries"], got["start_entry"]), (200, 200))
        self.assertEqual(json.loads(out.read_text())["page"], {"start": 200, "end": 260, "listed": 450})

    def test_a_time_sized_check_records_the_first_entry_it_did_not_gate_so_the_tick_cursor_skips_nobody(self):
        """Fable on #2110 (3a37532a5): the ask tick hands its apply `--max-entries check_end - cursor`, so the tick is only
        honest if the CHECK's own page record ends at the first entry it did not gate. This runs the real CLI and the
        real `send`/`_send` (no fake of need_asks); only the replica read and the gate call are stubbed. A check sized
        to 3 users over a page of 8 must record end = the 4th live user's entry (a user the live re-read dropped counts
        as examined), and the next check from that end gates the rest: every live user is gated exactly once."""
        import contextlib, io
        from credit_review import verify_ledger  # noqa: PLC0415
        users = [{"user_id": str(i), "paid": True, "asks": [{"request_id": f"q{i}"}]} for i in range(1, 9)]
        lst = self.d / "time-sized.json"
        lst.write_text(json.dumps({"users": users}))
        gated: list[list[str]] = []

        def payloads(us, q, asked, held=None, filtered=None):      # the replica: user 2's request resolved
            return [{"user": {"id": u["user_id"]}, "credits": [{"request_id": u["asks"][0]["request_id"]}],
                     "need": {"code": "x"}} for u in us if u["user_id"] != "2"]

        def send_all(ps, rep, **kw):                                  # the gate: every user it is handed answers
            self.assertTrue(kw.get("check_recipients"))
            gated.append([str(p["user"]["id"]) for p in ps])

        def check(start, cap, out):
            with unittest.mock.patch.object(na, "payloads", payloads), \
                    unittest.mock.patch.object(na.verify_notify, "send_all", send_all), \
                    unittest.mock.patch.object(verify_ledger, "DEFAULT_PATH", str(self.d / "ledger.sqlite3")), \
                    contextlib.redirect_stdout(io.StringIO()):
                na._main(["send", "--list", str(lst), "--segment", "paid", "--check-recipients", "--max-users", str(cap),
                          "--max-entries", str(8 - start), "--start-entry", str(start), "--outcomes-json", str(out)])
            return json.loads(out.read_text())["page"]

        page = check(0, 3, self.d / "c1.json")
        self.assertEqual(gated, [["1", "3", "4"]])
        self.assertEqual((page["start"], page["end"], page["listed"]), (0, 4, 8))   # entry 4 = user 5, never gated
        page2 = check(page["end"], 3, self.d / "c2.json")
        self.assertEqual(gated[1], ["5", "6", "7"])
        page3 = check(page2["end"], 3, self.d / "c3.json")
        self.assertEqual((gated[2], page3["end"]), (["8"], 8))                  # the tail; the tick wraps to 0
        self.assertEqual(sorted(sum(gated, []), key=int), ["1", "3", "4", "5", "6", "7", "8"])

    def test_the_cursor_stops_at_the_user_the_apply_budget_deferred(self):
        """QA #1756 Important, the proof-need-ask half: `_send` computes page.end from the batch BEFORE the send loop
        runs, so a user the loop refused to START (no room left in the tick's share) still counted as examined and the
        cursor walked past them - they waited a whole rotation of the list instead of the next tick."""
        users = [{"user_id": u, "paid": True, "asks": [{"request_id": f"r{u}"}]} for u in range(1, 6)]
        lst = self.d / "lst.json"
        lst.write_text(json.dumps({"users": users}))
        clock = {"t": 0.0}
        def payloads(us, q, asked, held=None, filtered=None):
            return [{"user": {"id": u["user_id"]}, "credits": [{"request_id": u["asks"][0]["request_id"]}],
                     "need": {"code": "x"}} for u in us]
        real = na.verify_notify.send_all
        def slow_send(ps, rep, **kw):
            def gate(argv):
                clock["t"] += float(getattr(gate, "cost", 120.0))
                return type("R", (), {"returncode": 0, "stdout": "POSTED email message=1 credits=1\n", "stderr": ""})()
            with unittest.mock.patch.object(na.verify_notify.time, "monotonic", lambda: clock["t"]), \
                    unittest.mock.patch.object(na.verify_notify.time, "sleep", lambda s: None), \
                    unittest.mock.patch.object(na.verify_notify, "attach_identities", lambda ps_, r: (ps_, [])), \
                    unittest.mock.patch.object(na.verify_notify, "APPLY_WORKERS", 1):
                # APPLY_WORKERS=1 on purpose: this test is about the CURSOR (a user the budget refused to
                # start must not count as examined), and it pins "room for exactly ONE worst-case user".
                # The synthetic clock advances inside the gate, so with a real pool the admission verdict
                # would depend on how many workers happened to run before the next submit - a race, not a
                # property. The pool's own admission rule has its own test in test_credit_verify_notify.
                kw.pop("runner", None)
                return real(ps, rep, runner=gate, **kw)
        try:
            na.verify_notify.set_apply_budget(200)         # room for exactly ONE worst-case user
            na.verify_notify._SESSION_STARTED = 0.0        # apply_session's run clock (the CLI wraps the whole apply)
            with unittest.mock.patch.object(na, "payloads", payloads), \
                    unittest.mock.patch.object(na, "_GROUP_LOCKED", {str(self.d / "ledger.sqlite3"): True}), \
                    unittest.mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True), \
                    unittest.mock.patch.object(na.verify_notify, "send_all", slow_send):
                rep = na.send(list_path=str(lst), segment="paid", mode="apply", max_users=5, query=lambda sql: [],
                              ledger_path=str(self.d / "ledger.sqlite3"), max_entries=5)
        finally:
            na.verify_notify.set_apply_budget(None)
            na.verify_notify._SESSION_STARTED = None
        self.assertEqual((rep.halted, rep.sent_notes, rep.page["end"]), ("", 1, 1))
        deferred = [o["user"] for o in rep.outcomes if o["result"] == "deferred" and "apply_budget" in o["reason"]]
        self.assertEqual(deferred, ["2", "3", "4", "5"], "every user the share left owes a row")
        # the next tick, starting at that cursor, leads with the deferred user instead of skipping a rotation
        clock["t"] = 0.0
        try:
            na.verify_notify.set_apply_budget(200)
            na.verify_notify._SESSION_STARTED = 0.0
            with unittest.mock.patch.object(na, "payloads", payloads), \
                    unittest.mock.patch.object(na, "_GROUP_LOCKED", {str(self.d / "ledger.sqlite3"): True}), \
                    unittest.mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True), \
                    unittest.mock.patch.object(na.verify_notify, "send_all", slow_send):
                rep2 = na.send(list_path=str(lst), segment="paid", mode="apply", max_users=5, query=lambda sql: [],
                               ledger_path=str(self.d / "ledger.sqlite3"), max_entries=5,
                               start_entry=rep.page["end"])
        finally:
            na.verify_notify.set_apply_budget(None)
            na.verify_notify._SESSION_STARTED = None
        self.assertEqual(rep2.page["start"], 1)

    def test_the_cli_accepts_the_tick_apply_budget_and_hands_it_to_the_send_loop(self):
        """QA #1756 Critical: the outbound tick passes --apply-budget-s to EVERY family it applies
        (credit-verify-outbound.sh family()), and proof-need-ask runs this parser. Without the flag an armed need-ask
        apply died at argparse with rc=2 before writing its outcomes file, which the tick reads as UNMEASURED and
        answers with a kill - a family taken out by a flag, not by a refusal."""
        import contextlib, io
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        chk = self.d / "check.json"
        chk.write_text(json.dumps({"accepted": [], "max_users": 5}))
        seen = []
        def send(**kw):
            seen.append(na.verify_notify.APPLY_BUDGET_S)
            return na.verify_notify.Report()
        try:
            with unittest.mock.patch.object(na, "send", send), \
                    unittest.mock.patch.object(na.verify_notify, "APPLY_ONLY", None), \
                    unittest.mock.patch.object(na.verify_notify, "APPLY_PAGE", None), \
                    contextlib.redirect_stdout(io.StringIO()):
                rc = na._main(["send", "--list", str(lst), "--segment", "paid", "--mode", "apply",
                               "--signed-accepted", str(chk), "--page", "--apply-budget-s", "900"])
        finally:
            na.verify_notify.set_apply_budget(None)
        self.assertNotEqual(rc, 2, "the tick's own argv shape must parse (2 is argparse/policy, before any send)")
        self.assertEqual(seen, [900.0], "the share reaches the send loop, which is what enforces it")

    def test_the_cli_pages_a_signed_apply_only_with_page(self):
        # QA #1617: the tick's signed apply (--page) sends what fits today's room; a hand signed apply is whole-or-nothing
        import contextlib, io
        lst = self.d / "signed.json"
        lst.write_text(json.dumps({"users": [{"user_id": "1", "paid": True, "asks": []}]}))
        chk = self.d / "check.json"
        chk.write_text(json.dumps({"accepted": [{"user": "1"}], "max_users": 5}))
        seen = []
        def send(**kw):
            seen.append(na.verify_notify.APPLY_PAGE)
            return na.verify_notify.Report()
        for extra, want in ((["--page"], True), ([], False)):
            with unittest.mock.patch.object(na, "send", send), unittest.mock.patch.object(na.verify_notify, "APPLY_ONLY", None), \
                    unittest.mock.patch.object(na.verify_notify, "APPLY_PAGE", None), contextlib.redirect_stdout(io.StringIO()):
                na._main(["send", "--list", str(lst), "--segment", "paid", "--mode", "apply", "--signed-accepted", str(chk), *extra])
            self.assertIs(seen[-1], want, extra)

    def test_the_cli_exits_3_on_a_cap_short_apply_and_2_on_an_unreadable_policy(self):
        import contextlib, io
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        for attr, want in (("cap_short", 3), ("policy_error", 2)):
            def send(**kw):
                r = na.verify_notify.Report(); setattr(r, attr, True); r.halted = attr
                return r
            with unittest.mock.patch.object(na, "send", send), contextlib.redirect_stdout(io.StringIO()):
                rc = na._main(["send", "--list", str(lst), "--segment", "paid", "--mode", "apply"])
            self.assertEqual(rc, want, attr)

    def test_check_recipients_asks_the_live_gate_for_every_user_and_lists_the_deferred(self):
        # r5 RULE (10-31 14:2xZ): signable only on the live gates' answer - the gate's --check-recipient, never --validate
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        calls, answer = [], {"rc": 3, "out": "DEFERRED core_notice_within_7d credits=1 (approvedNotice within 7d)\n"}
        def gate(argv):
            calls.append((argv, json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]))
            return type("R", (), {"returncode": answer["rc"], "stdout": answer["out"], "stderr": ""})()
        def run(**kw):
            return na.send(list_path=str(lst), segment="paid", mode="dry-run", query=self.q, runner=gate,
                           ledger_path=str(self.d / "ledger.sqlite3"), **kw)
        rep = run(check_recipients=True)
        self.assertTrue(calls)
        self.assertTrue(all("--check-recipient" in a and "--validate" not in a and "--dry-run" not in a for a, _ in calls))
        self.assertEqual((rep.sent_notes, rep.recipient_ok), (0, 0))
        self.assertEqual([o["user"] for o in rep.outcomes], [u for _, u in calls])   # the deferred user is LISTED
        answer.update(rc=0, out="RECIPIENT OK proof-need-ask initial copy=proofneed credits=1\n")
        calls.clear()
        rep = run(check_recipients=True)
        self.assertEqual(rep.recipient_ok, len(calls))                             # the would-send set
        self.assertEqual([a["user"] for a in rep.accepted], [u for _, u in calls])  # ... named (QA #1582)
        self.assertTrue(all(a["campaign"] == "proof-need-ask" and a["request_ids"] and a["gate"].startswith("RECIPIENT OK")
                            for a in rep.accepted))
        calls.clear()
        run()                                                                       # a plain dry run only renders
        self.assertTrue(calls and all("--check-recipient" not in a for a, _ in calls))

    def test_cli_emits_the_would_send_ids_and_writes_the_outcomes_safely(self):
        # QA #1582: a mixed run (one deferred, one accepted) names the accepted user; the outcomes file is a fresh 0600
        # file even over an existing 0644 one; an unwritable outcomes location stops BEFORE any gate call
        import contextlib, io, os, stat
        from unittest import mock
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        seen = []
        def gate(argv):
            uid = json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]
            seen.append(uid)
            if len(seen) == 1:
                return type("R", (), {"returncode": 3, "stdout": "DEFERRED core_notice_within_7d credits=1 (x)\n", "stderr": ""})()
            return type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK proof-need-ask initial copy=x credits=1\n", "stderr": ""})()
        real = na.send
        def send(**kw):
            return real(**{**kw, "query": self.q, "runner": gate, "ledger_path": str(self.d / "ledger.sqlite3")})
        out = self.d / "out.json"
        out.write_text("old"); os.chmod(out, 0o644)
        buf = io.StringIO()
        with mock.patch.object(na, "send", send), contextlib.redirect_stdout(buf):
            na._main(["send", "--list", str(lst), "--segment", "free", "--check-recipients", "--outcomes-json", str(out)])
        doc = json.loads(out.read_text())
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)                # fresh 0600, not the old 0644
        self.assertGreaterEqual(len(seen), 2, "fixture needs two gate calls")
        # r5's A/B/C: A filtered before the gate (named, with why), B accepted, C deferred - and they add up to listed
        self.assertEqual(doc["counts"], {"accepted": 1, "gate_non_send": 1, "filtered": 1})
        self.assertEqual(doc["listed"], 3)
        self.assertTrue(doc["balanced"])
        self.assertEqual([f["user"] for f in doc["filtered"]], ["4"])
        self.assertIn("intake newer", doc["filtered"][0]["reason"])
        self.assertTrue(doc["accepted"][0]["gate"].startswith("RECIPIENT OK"))
        self.assertEqual(doc["would_send_users"], seen[1:])                        # the accepted, by id
        self.assertEqual([o["user"] for o in doc["outcomes"]], seen[:1])           # the deferred one, listed apart
        self.assertEqual(json.loads(buf.getvalue().strip().splitlines()[-1])["would_send_users"], seen[1:])
        seen.clear()
        with mock.patch.object(na, "send", send), contextlib.redirect_stdout(io.StringIO()) as b2:
            rc = na._main(["send", "--list", str(lst), "--segment", "paid", "--mode", "apply",
                           "--outcomes-json", str(self.d / "no" / "such" / "dir" / "o.json")])
        self.assertEqual((rc, seen), (2, []))
        self.assertIn("not writable", b2.getvalue())

    def test_the_built_list_carries_the_signing_header_and_verify_facts_names_changes(self):
        # r5 #1582 (c): exact runnable SQL + its sha256 + a facts sha256; verify-facts re-reads it at signing
        import copy, hashlib
        seen = []
        real = self.q
        lst = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                       query=lambda sql: seen.append(sql) or real(sql))
        head = lst["replica_facts"]
        # [key=facts-scope]: the header pins the base query; the build now runs it RESTRICTED to this page's users, so
        # the read that happened is the header's query plus the user predicate - never the whole table again.
        reads = [q for q in seen if q.startswith(head["query"])]
        self.assertTrue(reads)
        self.assertIn("cr.userid IN (", reads[0])
        self.assertTrue(head["query"].startswith("SELECT "))
        self.assertEqual(head["query_sha256"], hashlib.sha256(head["query"].encode()).hexdigest())
        self.assertEqual(head["sha256"], na.facts_header(lst["users"])["sha256"])
        self.assertTrue(all(u["facts"] for u in lst["users"]))
        self.assertEqual(na.verify_facts(lst, self.q), [])                          # unchanged: signable
        u0 = lst["users"][0]
        rid = sorted({a["request_id"] for a in u0["asks"]})[0]
        self.facts_status = {rid: "processing"}                                     # one request moved since the build
        self.assertEqual([d.split(":")[0] for d in na.verify_facts(lst, self.q)], [u0["user_id"]])
        self.facts_status = {}
        # QA #1582: the same request, same status, now owned by ANOTHER user - a change (never signable as built)
        real_q = self.q
        moved = lambda sql: [[("999" if r[1] == rid.lower() else r[0]), *r[1:]] for r in real_q(sql)] if sql.startswith(na.FACTS_SQL) else real_q(sql)
        self.assertEqual([d.split(":")[0] for d in na.verify_facts(lst, moved)], [u0["user_id"]])
        edited = copy.deepcopy(lst)
        edited["users"][0]["facts"] = [["x", "y", "z"]]
        self.assertTrue(any(d.startswith("header:") for d in na.verify_facts(edited, self.q)))

    def test_the_facts_read_lists_open_statuses_and_refuses_a_status_nobody_classified(self):
        # the NOT IN form is not pushed to Postgres (the whole table crossed the wire: 106.9 s vs 8.2 s live); the
        # positive list is only equal to it while every status is known, so an unknown one refuses build AND signing
        import hashlib
        self.assertNotIn("NOT IN", na.FACTS_SQL)
        self.assertIn("cr.status IN ('unverified', 'processing', 'user_verification_needed')", na.FACTS_SQL)
        seen = []
        real = self.q
        lst = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                       query=lambda sql: seen.append(sql) or real(sql))
        guard = na.owing_proof.STATUS_GUARD_SQL
        facts_at = next(i for i, q in enumerate(seen) if q.startswith(na.FACTS_SQL))  # [key=facts-scope]: scoped
        self.assertLess(seen.index(guard), facts_at)                                # the guard runs first
        head = lst["replica_facts"]
        self.assertEqual((head["guard_query"], head["guard_query_sha256"]),
                         (guard, hashlib.sha256(guard.encode()).hexdigest()))
        for bad in (("approved", "on_hold", "unverified"), (), ("",)):               # unknown, unreadable, blank
            self.table_statuses = bad
            seen.clear()
            with self.assertRaises(na.NeedError):
                na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                         query=lambda sql: seen.append(sql) or real(sql))
            # refused before the facts read
            self.assertFalse([q for q in seen if q.startswith(na.FACTS_SQL)], "no facts read")
            with self.assertRaises(na.NeedError):
                na.verify_facts(lst, self.q)
        del self.table_statuses
        self.assertEqual(na.verify_facts(lst, self.q), [])

    def test_an_identity_held_user_is_named_and_the_run_stays_balanced(self):
        # QA #1582: no professional id -> held before the gate -> named in filtered (never vanishes)
        from unittest import mock
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        with mock.patch.object(na.verify_notify, "attach_identities", lambda ps, rep: (rep.__setattr__("no_professional_id", len(ps)) or [], ps)):
            rep = na.send(list_path=str(lst), segment="paid", mode="dry-run", query=self.q, runner=FakeGate(),
                          ledger_path=str(self.d / "ledger.sqlite3"), check_recipients=True)
        acc = na.accounting(rep)
        self.assertTrue(acc["balanced"], acc)
        self.assertEqual(acc["counts"]["accepted"], 0)
        self.assertTrue(rep.filtered and all("professional id" in f["reason"] for f in rep.filtered
                                             if f["user"] in rep.listed_users and "already" not in f["reason"]))

    def test_an_unbalanced_recipient_check_exits_nonzero(self):
        # QA #1582: the gate answers VALID (not RECIPIENT OK) under --check-recipients - counted as validated, neither
        # accepted nor a non-send -> unbalanced -> exit 3 (never 0), and the JSON says balanced false
        import contextlib, io
        from unittest import mock
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        real = na.send
        drift = lambda argv: type("R", (), {"returncode": 0, "stdout": "VALID proof-need-ask initial copy=x credits=1\n", "stderr": ""})()
        def send(**kw):
            return real(**{**kw, "query": self.q, "runner": drift, "ledger_path": str(self.d / "ledger.sqlite3")})
        buf = io.StringIO()
        with mock.patch.object(na, "send", send), contextlib.redirect_stdout(buf):
            rc = na._main(["send", "--list", str(lst), "--segment", "paid", "--check-recipients"])
        self.assertEqual(rc, 3)
        self.assertFalse(json.loads(buf.getvalue().strip().splitlines()[-1])["balanced"])
        ok = lambda argv: type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK proof-need-ask initial copy=x credits=1\n", "stderr": ""})()
        def send_ok(**kw):
            return real(**{**kw, "query": self.q, "runner": ok, "ledger_path": str(self.d / "ledger2.sqlite3")})
        with mock.patch.object(na, "send", send_ok), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(na._main(["send", "--list", str(lst), "--segment", "paid", "--check-recipients"]), 0)

    def test_an_unaccounted_user_makes_the_run_unbalanced(self):
        # r5 #1582: accepted + gate non-sends + filtered must equal the listed users, else the list is not signable
        rep = na.verify_notify.Report()
        rep.listed_users = ["1", "2", "3"]
        rep.accepted = [{"user": "1", "campaign": "proof-need-ask", "request_ids": ["r1"], "gate": "RECIPIENT OK x"}]
        rep.outcomes = [{"user": "2", "result": "deferred", "reason": "x"}]
        self.assertFalse(na.accounting(rep)["balanced"])                           # user 3 is nowhere
        rep.filtered = [{"user": "3", "result": "filtered", "reason": "y"}]
        self.assertTrue(na.accounting(rep)["balanced"])

    def test_check_recipients_is_refused_with_apply(self):
        self.assertEqual(na._main(["send", "--list", "/nonexistent", "--segment", "paid", "--mode", "apply",
                                   "--check-recipients"]), 2)

    def test_unreadable_inputs_list_nothing(self):
        with self.assertRaises(na.NeedError):
            na.build(dv_store=str(self.d / "nope.sqlite"), proof_store=self.proof, paying_path=str(self.paying), query=self.q)
        with self.assertRaises(na.NeedError):
            na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.d / "nope.json"), query=self.q)

    def test_the_scoped_re_read_never_asks_the_replica_about_the_whole_table(self):
        # [key=facts-scope]: an empty page has nothing to verify, so it issues NO query at all; a populated page asks
        # only about its own users, in 500-id chunks, and never the whole-table FACTS_SQL.
        seen = []

        def fake(sql):
            seen.append(sql)
            if sql == na.owing_proof.STATUS_GUARD_SQL:        # the guard #1893 added runs first, then the scoped read
                return [[s] for s in na.owing_proof.OPEN_STATUSES]
            return []
        self.assertEqual(na.replica_facts(fake, []), {})
        self.assertEqual(seen, [])
        ids = list(range(1, 1202))
        na.replica_facts(fake, ids)
        seen = [q for q in seen if q != na.owing_proof.STATUS_GUARD_SQL]
        self.assertEqual(len(seen), 3, seen)
        for sql in seen:
            self.assertIn("cr.userid IN (", sql)
            self.assertNotEqual(sql, na.FACTS_SQL)
        self.assertEqual([len(sql.rsplit("IN (", 1)[1].rstrip(")").split(",")) for sql in seen], [500, 500, 201])
        self.assertEqual(na.facts_header([])["query"], na.FACTS_SQL)

    def test_doc_kind(self):
        self.assertEqual([na.doc_kind(m) for m in ("image/heic", "application/pdf", "text/plain", "")],
                         ["image", "PDF", "document", "document"])

    # --- never asked (owner 2026-11-14) ---
    # A request held for a cause no document clears is not in this sender's audience (owner 2026-11-14).
    #
    # The reading is policy.never_ask, the one every sender uses; these tests pin that THIS sender obeys it where it
    # builds the list, again on the fresh read at send time, and in the drain's wait list. Measured 2026-11-14: 3,266
    # requests of this audience carried such a cause (936 fraud, 509 impersonation, 1,821 another band C cause).
    #

    def asked(self, res):
        return sorted(a["request_id"] for u in res["users"] for a in u["asks"])

    def test_fraud_impersonation_and_any_other_band_c_cause_are_left_out_of_the_list(self):
        before = self.asked(self.build())
        self.assertEqual(before, ["r1", "r2", "r3", "r5", "r9"])            # the fixture's own audience
        self.verdicts = {"r1": FRAUD, "r3": IMPERSONATION, "r5": HELD_SUBMITTER, "r9": BAND_C}
        res = self.build()
        self.assertEqual(self.asked(res), ["r2"])                           # user 1 is still asked about r2 only
        self.assertEqual([u["user_id"] for u in res["users"]], ["1"])
        c = res["counts"]
        self.assertEqual((c["skip_never_asked"], c["skip_never_asked_fraud"], c["skip_never_asked_impersonation"],
                          c["skip_never_asked_band_c"]), (4, 2, 1, 1))
        self.assertEqual([w for w in res["waits"] if w["request_id"].lower() in ("r1", "r3", "r5", "r9")], [])

    def test_a_hold_a_document_can_answer_is_still_asked(self):
        self.verdicts = {r: DOCUMENT_ANSWERS_IT for r in ("r1", "r2", "r3", "r5", "r9")}
        res = self.build()
        self.assertEqual(self.asked(res), ["r1", "r2", "r3", "r5", "r9"])
        self.assertEqual(res["counts"].get("skip_never_asked", 0), 0)

    def test_a_band_c_cause_under_a_hold_a_document_answers_is_left_out(self):
        self.verdicts = {"r2": {"rule_risk_percent": {"review_big_track_without_trusted_credit": 100,
                                                      "reject_individual_org_credit": 100}}}
        self.assertEqual(self.asked(self.build()), ["r1", "r3", "r5", "r9"])

    def test_a_verdict_that_cannot_be_read_is_asked_as_before(self):
        self.verdicts = {"r1": "not a mapping", "r2": {"rule_risk_percent": "not a mapping"}}
        self.assertEqual(self.asked(self.build()), ["r1", "r2", "r3", "r5", "r9"])

    def test_a_request_held_after_the_list_was_built_is_not_named_by_the_send(self):
        self.pending[1] = ["r1"]
        db = sqlite3.connect(self.proof)          # only document A on file, so its ask is not held by a newer intake
        db.execute("DELETE FROM proof_intake WHERE user_id=1 AND file_sha256=?", (SHA_B,)); db.commit(); db.close()
        lst = self.d / "list.json"
        lst.write_text(json.dumps(self.build()))
        _rep, gate = self.send_(lst)
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _a, p in gate.calls], [["r1"]])   # control
        self.verdicts = {"r1": IMPERSONATION}                             # the hold lands between build and send
        _rep, gate = self.send_(lst)
        self.assertEqual(gate.calls, [])

    def test_a_drain_ask_this_run_read_as_held_is_neither_asked_nor_listed_as_waiting(self):
        self.verdicts = {"r1": FRAUD}
        d = Path(tempfile.mkdtemp())
        plan = d / "plan.jsonl"
        plan.write_text("\n".join(json.dumps(r) for r in (
            {"request_id": "r1", "rule": "ask", "outcome": "ask", "user_id": 1},
            {"request_id": "r2", "rule": "ask", "outcome": "ask", "user_id": 1})) + "\n")
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                       query=self.q, from_drain=str(plan))
        self.assertEqual(self.asked(res), ["r2"])
        self.assertEqual([w for w in res["waits"] if w["request_id"] == "r1"], [])
        self.assertEqual(res["counts"]["drain_asks_never_asked"], 1)


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

        def payloads(users, query, asked, held=None, filtered=None):
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

        def payloads(users, query, asked, held=None, filtered=None):
            return [{"user": {"id": u["user_id"]}, "credits": [], "need": {"code": "readable_document"}}
                    for u in users if u["user_id"] not in ("1", "2")]

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
        # QA #1513 (17:13Z): the builder's 'named' set is the FINAL group's intakes (what need.doc_intakes carries)
        self.assertIn("for a in docs if a.get(\"intake_id\")", src)
        self.assertNotIn("for a in cand if a.get(\"intake_id\")", src)
        named = {"42:i1"}
        self.assertTrue(na.comm_state.newer_intake("2026-10-18T09:30:00Z", [["2026-10-18T09:30:00Z", "42:i2"]], named))
        self.assertFalse(na.comm_state.newer_intake("2026-10-18T09:30:00Z", [["2026-10-18T09:30:00Z", "42:i1"]], named))


class DistributorIssueOrderTest(unittest.TestCase):
    def test_each_code_is_issued_right_before_its_own_gate_call(self):
        # QA #1513: never a batch of codes up front - issue, send, issue, send
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]} for u in (1, 2)]}))
        events = []
        ps = [{"user": {"id": str(u)}, "credits": [{"request_id": f"r{u}"}], "need": {"code": na.DISTRIBUTOR}} for u in (1, 2)]

        def send_all(batch, report, **kw):
            if kw.get("check_recipients"):
                events.extend(f"check:{p['user']['id']}" for p in batch)
                report.recipient_ok += len(batch)
                return
            events.extend(f"send:{p['user']['id']}" for p in batch)
        with mock.patch.object(na, "payloads", lambda users, q, asked, held=None, filtered=None: ps), \
                mock.patch.object(na.verify_notify, "send_all", send_all), \
                mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True):
            na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=FakeGate(),
                    ledger_path=str(d / "ledger.sqlite3"),
                    issuer=lambda rid, uid: events.append(f"issue:{uid}") or {"code": "MUSO-AB12", "expires_at": "2099-01-01T00:00:00Z"})
        self.assertEqual(events, ["check:1", "issue:1", "send:1", "check:2", "issue:2", "send:2"])

    def test_a_dry_run_check_reads_every_distributor_identity_once_and_issues_no_code(self):
        """A recipient check (dry run) mints no code, so its distributor asks go through ONE send_all: one identity read
        for the page and the gate calls on the check workers. One call per payload cost each user its own replica round
        trips and a gate call alone: 20 users took 277 s on node-8 (2026-11-16) and the ask tick's check was killed."""
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        users = (1, 2, 3, 4)
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]}
                                             for u in users]}))
        ps = [{"user": {"id": str(u)}, "credits": [{"request_id": f"r{u}"}], "need": {"code": na.DISTRIBUTOR}}
              for u in users]
        lookups, issued, checked = [], [], []

        def lookup(ids):
            lookups.append(sorted(str(i) for i in ids))
            return {str(i): {"professional_id": f"p{i}", "auth_id": ""} for i in ids}

        def gate(argv):
            body = json.load(open(argv[argv.index("--credits-file") + 1]))
            checked.append((body["user"]["id"], body["need"]["verify_code"], "--check-recipient" in argv))
            return type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK contact=c\n", "stderr": ""})()
        with mock.patch.object(na, "payloads", lambda users_, q, asked, held=None, filtered=None: ps), \
                mock.patch.object(na.verify_notify, "IDENTITY_LOOKUP", lookup), \
                mock.patch.object(na.verify_notify, "_with_presented", lambda ps_: ps_), \
                mock.patch.object(na.verify_notify.time, "sleep", lambda s: None):
            rep = na.send(list_path=str(lst), segment="paid", mode="dry-run", check_recipients=True,
                          query=lambda sql: [], runner=gate, ledger_path=str(d / "ledger.sqlite3"), max_users=4,
                          issuer=lambda rid, uid: issued.append(uid) or {"code": "MUSO-AB12"})
        self.assertEqual(lookups, [["1", "2", "3", "4"]])          # one identity read for the whole page
        self.assertEqual(issued, [])                                   # a check mints nothing
        self.assertEqual(sorted(c[0] for c in checked), ["1", "2", "3", "4"])
        self.assertTrue(all(c[2] and c[1] == na.CODE_PLACEHOLDER for c in checked))
        self.assertEqual(rep.recipient_ok, 4)                          # every one checked, none lost in the batch
        self.assertEqual(rep.page["end"], 4)

    def test_a_distributor_user_the_budget_deferred_gets_no_code_and_the_cursor_stops_at_them(self):
        """QA #1756 Important (carried): the budget clamp ran between the plain batch and the distributor phase, and
        with_codes() minted an F9 code BEFORE the send loop's budget guard. So a distributor user reaching the loop
        after the share was spent got a code issued for a note that was then deferred, and the cursor - clamped before
        the distributor phase - stepped PAST them, so they waited a whole rotation instead of the next tick."""
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]}
                                   for u in (1, 2, 3)]}))
        ps = [{"user": {"id": str(u)}, "credits": [{"request_id": f"r{u}"}], "need": {"code": na.DISTRIBUTOR}}
              for u in (1, 2, 3)]
        issued, sent = [], []
        clock = {"t": 0.0}

        def gate(argv):
            if "--check-recipient" in argv:
                return type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK contact=c\n", "stderr": ""})()
            sent.append(json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"])
            clock["t"] += na.verify_notify.WORST_USER_S      # one note costs its whole worst case
            return type("R", (), {"returncode": 0, "stdout": "POSTED email message=1 credits=1\n", "stderr": ""})()

        # the share fits exactly ONE worst-case note: user 1 sends, users 2 and 3 must be deferred WITHOUT a code
        try:
            na.verify_notify.set_apply_budget(na.verify_notify.WORST_USER_S + 1)
            na.verify_notify._SESSION_STARTED = 0.0
            with mock.patch.object(na, "payloads", lambda users, q, asked, held=None, filtered=None: ps), \
                    mock.patch.object(na.verify_notify, "attach_identities", lambda ps_, r: (ps_, None)), \
                    mock.patch.object(na.verify_notify, "head_mismatch", lambda: ""), \
                    mock.patch.object(na.verify_notify.time, "monotonic", lambda: clock["t"]), \
                    mock.patch.object(na.verify_notify.time, "sleep", lambda s: None), \
                    mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True):
                rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=gate,
                              ledger_path=str(d / "ledger.sqlite3"), max_users=3,
                              issuer=lambda rid, uid: issued.append(uid) or {
                                  "code": "MUSO-AB12", "expires_at": "2099-01-01T00:00:00Z", "new": True})
        finally:
            na.verify_notify.set_apply_budget(None)
            na.verify_notify._SESSION_STARTED = None
        self.assertEqual(sent, ["1"])
        self.assertEqual(issued, ["1"], "a deferred distributor user must never have a code minted for them")
        deferred = [o["user"] for o in rep.outcomes if o["result"] == "deferred" and "apply_budget" in o["reason"]]
        self.assertEqual(deferred, ["2", "3"], "every distributor user the share left owes a row")
        self.assertEqual(rep.page["end"], 1, "the cursor stops at the first deferred distributor user, not past them")

    def test_a_preflight_that_crosses_the_budget_boundary_mints_no_code(self):
        """QA #1756 Important 2 (r12): the budget guard ran BEFORE the preflight, and the preflight is a real gate call
        (up to ~20s). With 200-219s left the guard passed, the preflight ate the margin, and with_codes() minted an F9
        code for a note the send loop then deferred - a code issued for nothing, and if retiring it failed the next
        tick saw a non-fresh active code and held the owed user until it expired. The loop's own predicate is re-asked
        immediately before minting, so the preflight is the only work between the two reads."""
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]}
                                   for u in (1, 2)]}))
        ps = [{"user": {"id": str(u)}, "credits": [{"request_id": f"r{u}"}], "need": {"code": na.DISTRIBUTOR}}
              for u in (1, 2)]
        issued, sent = [], []
        clock = {"t": 0.0}

        def gate(argv):
            if "--check-recipient" in argv:
                clock["t"] += na.verify_notify.WORST_USER_S   # the preflight alone eats the whole margin
                return type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK contact=c\n", "stderr": ""})()
            sent.append(json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"])
            return type("R", (), {"returncode": 0, "stdout": "POSTED email message=1 credits=1\n", "stderr": ""})()

        try:
            na.verify_notify.set_apply_budget(na.verify_notify.WORST_USER_S + 1)
            na.verify_notify._SESSION_STARTED = 0.0
            with mock.patch.object(na, "payloads", lambda users, q, asked, held=None, filtered=None: ps), \
                    mock.patch.object(na.verify_notify, "attach_identities", lambda ps_, r: (ps_, None)), \
                    mock.patch.object(na.verify_notify, "head_mismatch", lambda: ""), \
                    mock.patch.object(na.verify_notify.time, "monotonic", lambda: clock["t"]), \
                    mock.patch.object(na.verify_notify.time, "sleep", lambda s: None), \
                    mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True):
                rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=gate,
                              ledger_path=str(d / "ledger.sqlite3"), max_users=2,
                              issuer=lambda rid, uid: issued.append(uid) or {
                                  "code": "MUSO-AB12", "expires_at": "2099-01-01T00:00:00Z", "new": True})
        finally:
            na.verify_notify.set_apply_budget(None)
            na.verify_notify._SESSION_STARTED = None
        self.assertEqual(issued, [], "a preflight that spent the margin must not mint a code")
        self.assertEqual(sent, [])
        deferred = [o["user"] for o in rep.outcomes if o["result"] == "deferred" and "apply_budget" in o["reason"]]
        self.assertEqual(deferred, ["1", "2"], "the user whose preflight crossed the boundary owes a row too")

    def test_a_signed_apply_drops_unsigned_users_before_the_slice_the_preflight_and_the_code(self):
        # QA #1611: (1) an unsigned F9 user gets NO preflight, NO code, NO void; (2) a paged apply (--max-users 1) after
        # a prefix of unsigned users still reaches the signed one
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": str(u), "paid": True, "asks": [{"request_id": f"r{u}"}]} for u in (1, 2, 3)]}))
        ps = [{"user": {"id": str(u)}, "credits": [{"request_id": f"r{u}"}], "need": {"code": na.DISTRIBUTOR}} for u in (1, 2, 3)]
        gate_users, issued, voided = [], [], []

        def gate(argv):
            gate_users.append(json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"])
            if "--check-recipient" in argv:
                return type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK contact=c\n", "stderr": ""})()
            return type("R", (), {"returncode": 0, "stdout": "POSTED email message=1 credits=1\n", "stderr": ""})()
        with mock.patch.object(na, "payloads", lambda users, q, asked, held=None, filtered=None: ps), \
                mock.patch.object(na.verify_notify, "attach_identities", lambda ps, r: (ps, None)), \
                mock.patch.object(na.verify_notify, "head_mismatch", lambda: ""), \
                mock.patch.object(na.verify_notify, "_apply_lock", lambda: open(__import__("os").devnull)), \
                mock.patch.object(na.verify_notify, "APPLY_ONLY", frozenset({"3"})), \
                mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True):
            rep = na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=gate,
                          ledger_path=str(d / "ledger.sqlite3"), max_users=1,
                          issuer=lambda rid, uid: issued.append(uid) or {"code": "MUSO-AB12", "expires_at": "2099-01-01T00:00:00Z", "new": True},
                          voider=lambda rid, code: voided.append(rid) or True)
        self.assertEqual((set(gate_users), issued, voided), ({"3"}, ["3"], []))   # 1 and 2: no gate, no code, no void
        self.assertEqual([s["user"] for s in rep.sent], ["3"])
        self.assertEqual(sorted(f["user"] for f in rep.filtered if "not_in_signed_accepted" in f["reason"]), ["1", "2"])

    def test_a_held_preflight_mints_nothing_and_the_next_run_retries_with_a_fresh_code(self):
        # QA #1513, through the REAL sender (verify_notify.send_all + the gate's answers): day 1 the gate would defer
        # (7-day cooldown) -> no code is minted, the deferral is in the report; day 2 it clears -> a fresh code, sent
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": "1", "paid": True, "asks": [{"request_id": "r1"}]}]}))
        ps = [{"user": {"id": "1"}, "credits": [{"request_id": "r1"}], "need": {"code": na.DISTRIBUTOR}}]
        state = {"day": 1, "argv": []}

        def gate(argv):
            state["argv"].append(argv)
            if "--check-recipient" in argv:
                ok = state["day"] == 2
                return type("R", (), {"returncode": 0 if ok else 3, "stderr": "",
                                      "stdout": "RECIPIENT OK contact=c\n" if ok else "DEFERRED messaged_7d credits=1 (x)\n"})()
            return type("R", (), {"returncode": 0, "stdout": "POSTED email message=1 credits=1\n", "stderr": ""})()
        issued = []
        def issuer(rid, uid):
            issued.append(rid)
            return {"code": "MUSO-AB12", "expires_at": "2099-01-01T00:00:00Z", "new": True}
        with mock.patch.object(na, "payloads", lambda users, q, asked, held=None, filtered=None: ps), \
                mock.patch.object(na.verify_notify, "attach_identities", lambda ps, r: (ps, None)), \
                mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True):
            rep1 = na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=gate,
                           ledger_path=str(d / "ledger.sqlite3"), issuer=issuer)
            self.assertEqual(issued, [])                                    # nothing minted while it would be held
            self.assertEqual((rep1.deferred_users, rep1.sent_notes), (1, 0))
            # the line names the gate's own answer: a deferral here, never a bare label that reads as a broken check
            self.assertEqual(rep1.refusals,
                             ["distributor_preflight_not_ok:r1 (deferred: messaged_7d credits=1 (x))"])
            self.assertEqual(rep1.refused_users, 0)
            self.assertTrue(all("--check-recipient" in a for a in state["argv"]))   # no live send attempted
            state["day"] = 2
            rep2 = na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=gate,
                           ledger_path=str(d / "ledger.sqlite3"), issuer=issuer)
        self.assertEqual(issued, ["r1"])
        self.assertEqual(rep2.sent_notes, 1)
        sent = [a for a in state["argv"] if "--check-recipient" not in a]
        self.assertEqual(len(sent), 1)


class DistributorVoidTest(unittest.TestCase):
    """b1 #1527: a code minted for a send the gate then held is voided, so the next run issues a fresh one."""

    def run_day(self, live_rc, voided, live_out=None):
        from unittest import mock
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": [{"user_id": "1", "paid": True, "asks": [{"request_id": "r1"}]}]}))
        ps = [{"user": {"id": "1"}, "credits": [{"request_id": "r1"}], "need": {"code": na.DISTRIBUTOR}}]

        def gate(argv):
            if "--check-recipient" in argv:
                return type("R", (), {"returncode": 0, "stdout": "RECIPIENT OK contact=c\n", "stderr": ""})()
            out = live_out or ("POSTED email message=1 credits=1\n" if live_rc == 0 else "DEFERRED messaged_7d credits=1 (x)\n")
            return type("R", (), {"returncode": live_rc, "stdout": out, "stderr": ""})()
        with mock.patch.object(na, "payloads", lambda users, q, asked, held=None, filtered=None: ps), \
                mock.patch.object(na.verify_notify, "attach_identities", lambda ps, r: (ps, None)), \
                mock.patch.object(na.uvn_status, "campaign_lock_open", lambda w, lk: True):
            return na.send(list_path=str(lst), segment="paid", mode="apply", query=lambda sql: [], runner=gate,
                           ledger_path=str(d / "ledger.sqlite3"),
                           issuer=lambda rid, uid: {"code": "MUSO-AB12", "expires_at": "2099-01-01T00:00:00Z", "new": True},
                           voider=lambda rid, code: voided.append((rid, code)) or True)

    def test_a_held_send_after_minting_voids_the_code(self):
        voided = []
        rep = self.run_day(3, voided)
        self.assertEqual(voided, [("r1", "MUSO-AB12")])
        self.assertIn("distributor_code_voided:r1", rep.refusals)

    def test_an_ambiguous_failure_never_voids(self):
        # r5 (QA #1513): rc 4 (e.g. POST rejected / unverified) may have reached the POST - the code is kept, reported
        voided = []
        rep = self.run_day(4, voided)
        self.assertEqual(voided, [])
        self.assertIn("distributor_code_kept_ambiguous:r1", rep.refusals)

    def test_r5_posted_then_nonzero_keeps_the_code_and_held_rc3_voids_it(self):
        # r5 @28145fb0, the exact pair: the gate printed POSTED but exited non-zero (ledger finalize failed after a
        # successful Intercom POST) -> the customer may hold the code: preserved; 'HELD ...' rc=3 -> voided
        voided = []
        rep = self.run_day(4, voided, live_out="POSTED comment conversation=777 message=88001 credits=1\n"
                                               "LEDGER FINALIZE FAILED\n")
        self.assertEqual(voided, [])
        self.assertIn("distributor_code_kept_ambiguous:r1", rep.refusals)
        voided = []
        rep = self.run_day(3, voided, live_out="HELD r1_filing_thread credits=1 (x); nothing was sent or claimed\n")
        self.assertEqual(voided, [("r1", "MUSO-AB12")])
        self.assertIn("distributor_code_voided:r1", rep.refusals)

    def test_a_sent_code_is_never_voided(self):
        voided = []
        rep = self.run_day(0, voided)
        self.assertEqual((voided, rep.sent_notes), ([], 1))


class BuildSubcommandBudgetTest(unittest.TestCase):
    """[key=note-step-budget] --apply-budget-s is declared on the SEND subparser only.

    The outbound tick runs `need_asks.py build`, which shares the same parser. Reading a.apply_budget_s
    unconditionally raised AttributeError on every tick's proof-need-ask build, so the tick aborted before
    the apply step and never wrote its outcome file. This pins the build path, which no test exercised.
    """

    def test_build_subcommand_does_not_require_apply_budget_s(self):
        d = Path(tempfile.mkdtemp())
        out = d / "need-asks.json"
        res = {"generated_at": "2026-11-07T14:00:00Z", "counts": {"listed": 0, "would_send_users": 0}}
        with unittest.mock.patch.object(na, "build", return_value=res), \
                unittest.mock.patch.object(na.verify_notify, "set_apply_budget") as budget:
            rc = na._main(["build", "--out", str(out)])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.read_text()), res)
        budget.assert_called_once_with(None)

    def test_verify_facts_subcommand_does_not_require_apply_budget_s(self):
        """The same parser is shared by every subcommand, so the same read must be safe on all of them."""
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": []}))
        with unittest.mock.patch.object(na, "verify_facts", return_value=0), \
                unittest.mock.patch.object(na.verify_notify, "set_apply_budget") as budget:
            rc = na._main(["verify-facts", "--list", str(lst)])
        self.assertEqual(rc, 0)
        budget.assert_called_once_with(None)

    def test_send_subcommand_still_hands_the_share_through(self):
        """The fix must not stop the flag reaching the send loop: a send that names a share still sets it.

        The send path is inline in _main, so this stops it at the first refusal (--check-recipients is a dry-run
        check) - the point is the value that reached set_apply_budget, not the send itself.
        """
        d = Path(tempfile.mkdtemp())
        lst = d / "l.json"
        lst.write_text(json.dumps({"users": []}))
        with unittest.mock.patch.object(na.verify_notify, "set_apply_budget") as budget:
            rc = na._main(["send", "--list", str(lst), "--segment", "paid", "--mode", "apply",
                           "--check-recipients", "--apply-budget-s", "900"])
        self.assertEqual(rc, 2, "--check-recipients with --mode apply is refused before anything is sent")
        budget.assert_called_once_with(900.0)


FRAUD = {"rule_risk_percent": {}, "fraud_hold": {"decision": "hold"}}
HELD_SUBMITTER = {"rule_risk_percent": {"review_held_submitter": 100}}
IMPERSONATION = {"rule_risk_percent": {"review_role_credited_to_other_at_trusted_source": 100}}
BAND_C = {"rule_risk_percent": {"reject_publisher_label_credit": 100}}
DOCUMENT_ANSWERS_IT = {"rule_risk_percent": {"review_big_track_without_trusted_credit": 100}}


class DrainReconciliationTest(NeedAsksTest):
    """The scale drain decides WHO is asked; this module still decides WHICH document and owns the send.

    verify-ask-wiring-h2 (PR #1845) and the scale drain touch the same domain from different files. The
    reconciliation is that there is exactly ONE reviewed ask/notify path - this one - and the drain feeds it an
    audience instead of growing a second sender. These tests pin that the drain's `ask` rows are the audience, that a
    non-ask row is never asked, and that a drain ask with no sendable document is listed as a wait, never dropped.
    """

    def _plan(self, rows):
        d = Path(tempfile.mkdtemp())
        path = d / "plan.jsonl"
        path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        return str(path)

    def test_only_the_drains_ask_rows_are_listed(self):
        plan = self._plan([
            {"request_id": "r1", "rule": "ask", "outcome": "ask", "user_id": 1},
            {"request_id": "r2", "rule": "precedent", "outcome": "approve", "user_id": 1},
            {"request_id": "r3", "rule": "duplicate", "outcome": "unmatched", "user_id": 2},
        ])
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                       query=self.q, from_drain=plan)
        asked = {a["request_id"] for u in res["users"] for a in u["asks"]}
        self.assertEqual(asked, {"r1"})
        self.assertEqual(res["counts"]["drain_asks"], 1)
        self.assertGreater(res["counts"]["skip_not_in_drain"], 0)

    def test_a_drain_ask_with_no_sendable_document_waits_and_is_never_dropped(self):
        plan = self._plan([{"request_id": "r6", "rule": "ask", "outcome": "ask", "user_id": 5}])   # r6 has no intake row
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                       query=self.q, from_drain=plan)
        self.assertEqual(res["users"], [])
        waits = [w for w in res["waits"] if w["reason"] == "wait:no_sendable_document"]
        self.assertEqual([(w["user_id"], w["request_id"]) for w in waits], [("5", "r6")])
        self.assertTrue(waits[0]["due_at"])

    def test_a_downgraded_approve_is_in_the_ask_audience(self):
        """An approve with no evidence anchor resolves to outcome=ask, not a dropped row."""
        plan = self._plan([
            {"request_id": "r4", "rule": "proof_verdict", "outcome": "ask",
             "reason_code": "no_evidence_anchor", "user_id": 5},
        ])
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                       query=self.q, from_drain=plan)
        self.assertEqual(res["counts"]["drain_asks"], 1)
        waits = [w for w in res["waits"] if w["reason"] == "wait:no_sendable_document"]
        self.assertEqual([(w["user_id"], w["request_id"]) for w in waits], [("5", "r4")])

    def test_a_drain_ask_without_a_user_id_is_refused_loudly(self):
        plan = self._plan([{"request_id": "r1", "rule": "ask", "outcome": "ask", "user_id": None}])
        with self.assertRaises(na.NeedError):
            na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                     query=self.q, from_drain=plan)

    def test_an_unreadable_plan_is_refused(self):
        with self.assertRaises(na.NeedError):
            na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying),
                     query=self.q, from_drain="/nonexistent/plan.jsonl")

    def test_without_a_plan_the_audience_is_unchanged(self):
        base = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=str(self.paying), query=self.q)
        self.assertNotIn("drain_asks", base["counts"])
        self.assertNotIn("skip_not_in_drain", base["counts"])

    def test_the_cli_flag_reaches_build(self):
        plan = self._plan([{"request_id": "r1", "rule": "ask", "outcome": "ask", "user_id": 1}])
        out = Path(tempfile.mkdtemp()) / "list.json"
        with unittest.mock.patch.object(na, "build", return_value={"generated_at": "x", "counts": {}}) as b:
            rc = na._main(["build", "--out", str(out), "--from-drain", plan])
        self.assertEqual(rc, 0)
        self.assertEqual(b.call_args.kwargs.get("from_drain"), plan)


class ApprovedForAnotherUserTest(unittest.TestCase):
    """The conflict rule's credit_approved_for_another_user decisions, read from the stamp on the core row
    (metadata.precedent_blocked): a stamped request reaches the `credit-approved-elsewhere` line or is a backlog row
    with a signal - never silence, and never an ask nothing delivers."""

    RID = "11111111-1111-4111-8111-111111111111"
    RID2 = "22222222-2222-4222-8222-222222222222"
    RID3 = "33333333-3333-4333-8333-333333333333"

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.dv = str(self.d / "dv.sqlite")
        db = sqlite3.connect(self.dv)
        db.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, proof_id TEXT, "
                   "request_id TEXT, user_id INTEGER, outcome TEXT, need TEXT)")
        db.commit(); db.close()
        self.proof = str(self.d / "proof.sqlite")
        db = sqlite3.connect(self.proof)
        db.execute("CREATE TABLE proof_intake (user_id INTEGER, file_sha256 TEXT, received_at TEXT, mime TEXT, "
                   "conversation_id TEXT, intake_id TEXT, matched_by TEXT)")
        db.commit(); db.close()
        self.paying = str(self.d / "paying.json")
        Path(self.paying).write_text(json.dumps({"ids": [7]}))
        self.asked = []

    def stamp(self, **over):
        base = {"reason": "credit_approved_for_another_user", "roles": ["Engineer", "Mixing"],
                "approved_request_ids": ["theirs-1", "theirs-2"], "line_sent": False}
        return {**base, **over}

    def core(self, *rows):
        """A replica that answers the stamp query with these (request id, user id, stamp) rows and nothing else."""
        def query(sql):
            self.asked.append(sql)
            if sql != na.STAMPS_SQL:
                raise AssertionError("a stamped row needs no other replica read at build")
            return [[rid, str(uid), st if isinstance(st, str) else json.dumps(st)] for rid, uid, st in rows]
        return query

    def build(self, *rows, **kw):
        return na.build(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=self.core(*rows),
                        now=datetime(2026, 11, 14, tzinfo=timezone.utc), stamps=True, ledger_path=self.ledger(), **kw)

    def tell(self, rid, how="sent", user="jane@example.com"):
        """The verify-ledger row the gate writes for the approved-elsewhere line on this request, through the
        ledger's own writers: claimed before the POST (`attempted`), then `sent`. `held` is a claim the copy gate
        gave back, which is not a send."""
        from credit_review import verify_ledger
        db = verify_ledger.connect(self.ledger())
        try:
            c = verify_ledger.claim(db, campaign=na.ELSEWHERE_CAMPAIGN, user_key=user, day="2026-11-13",
                                    request_ids=[rid], message_type="email", approved_by="U7RP6HKUZ",
                                    approval_ref="ref", user_id="7")
            self.assertEqual(c["result"], "claimed")
            if how == "sent":
                verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="m1")
            elif how == "held":
                verify_ledger.hold_copy_review(db, message_row=c["message_row"],
                                               reason="copy_review_hold: copy_review_pending")
        finally:
            db.close()

    def test_the_stamp_is_the_one_source_and_it_is_read_from_the_core_row(self):
        self.build((self.RID, 7, self.stamp()))
        self.assertEqual(self.asked, [na.STAMPS_SQL])

    def test_each_backlog_why_has_its_own_counter_and_the_total_is_one_number(self):
        rows = [{"id": self.RID, "uid": "7", "stamp": self.stamp(roles=None)},
                {"id": self.RID2, "uid": "x", "stamp": self.stamp()},
                {"id": self.RID3, "uid": "7", "stamp": self.stamp(reason="something_else")},
                {"id": "44444444-4444-4444-8444-444444444444", "uid": "7", "stamp": None}]
        elsewhere, backlog, counts = na.stamped(rows)
        self.assertEqual(elsewhere, [])
        self.assertEqual(len(backlog), 4)
        self.assertEqual(counts["backlog_no_send_route"], 4)
        self.assertEqual(counts["backlog_approved_for_another_user"], 2)
        self.assertEqual(counts["backlog_roles_unread"], 1)
        self.assertEqual(counts["backlog_no_user"], 1)
        self.assertEqual(counts["backlog_other_reason"], 1)
        self.assertEqual(counts["backlog_stamp_unread"], 1)

    def test_a_stamped_request_is_never_also_the_document_ask(self):
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-11-01T00:00:00Z", "a" * 64, self.RID, 7, "unverifiable", "readable_document"))
        db.commit(); db.close()
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id, matched_by) "
                   "VALUES (7,?,?,?,?,?,?)", ("a" * 64, "2026-11-01T00:00:00Z", "image/jpeg", "777", "7:a", "professional_id"))
        db.commit(); db.close()
        res = self.build((self.RID, 7, self.stamp()))
        self.assertEqual(res["users"], [])
        self.assertEqual([e["request_id"] for e in res["elsewhere"]], [self.RID])
        self.assertEqual(res["counts"]["skip_decided_by_conflict_rule"], 1)

    def document_on_file(self, rid):
        """An unverifiable document with a sendable need on this request: what the document ask is built from."""
        db = sqlite3.connect(self.dv)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need) VALUES (?,?,?,?,?,?)",
                   ("2026-11-01T00:00:00Z", "a" * 64, rid, 7, "unverifiable", "readable_document"))
        db.commit(); db.close()
        db = sqlite3.connect(self.proof)
        db.execute("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id, matched_by) "
                   "VALUES (7,?,?,?,?,?,?)", ("a" * 64, "2026-11-01T00:00:00Z", "image/jpeg", "777", "7:a", "professional_id"))
        db.commit(); db.close()

    def open_core(self, *rows):
        """A replica where self.RID is an open request of user 7, answering the stamp read with these rows and every
        other read the document ask makes: so a request the build fails to keep off the document ask IS listed."""
        def query(sql):
            if sql == na.STAMPS_SQL:
                return [[rid, str(uid), json.dumps(st)] for rid, uid, st in rows]
            if "FROM postgresql_core.public.users" in sql:
                return [["7", "u7@x.com", "Jane", "", ""]]
            if sql == na.owing_proof.STATUS_GUARD_SQL:
                return [[s] for s in ("approved", "rejected", "unverified", "user_verification_needed")]
            if sql.startswith(na.FACTS_SQL):
                return [["7", self.RID, "user_verification_needed", "false"]]
            return [[self.RID, "7", "p1", "t1", "Song A", '[{"name": "Big Star"}]', "{Mixing}", "40", "{}", "{}"]]
        return query

    def build_open(self, *rows, **kw):
        return na.build(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=self.open_core(*rows),
                        now=datetime(2026, 11, 14, tzinfo=timezone.utc), stamps=True, ledger_path=self.ledger(), **kw)

    def document_asks(self, res):
        return [a["request_id"] for u in res["users"] for a in u["asks"]]

    def test_with_no_stamp_that_document_is_the_document_ask(self):
        # the control for the three cases below: this fixture IS asked when the conflict rule has not decided it
        self.document_on_file(self.RID)
        res = self.build_open()
        self.assertEqual(self.document_asks(res), [self.RID])
        self.assertEqual(res["counts"].get("skip_decided_by_conflict_rule", 0), 0)

    def test_a_request_the_ledger_says_was_sent_the_line_is_absent_and_one_with_no_row_is_present(self):
        # QA review of hydra#1974: a told request was in neither list, and the document ask was suppressed only for
        # ids IN those lists. "Told" is the ledger's sent row for the request, the row the gate writes when it sends
        self.document_on_file(self.RID)
        self.tell(self.RID)
        res = self.build_open((self.RID, 7, self.stamp()), (self.RID2, 7, self.stamp()))
        self.assertEqual([e["request_id"] for e in res["elsewhere"]], [self.RID2])
        self.assertEqual(res["users"], [])
        self.assertEqual(res["backlog"], [])
        self.assertEqual(res["waits"], [])
        self.assertEqual(res["counts"]["stamp_line_already_sent"], 1)
        self.assertEqual(res["counts"]["skip_told_approved_elsewhere"], 1)

    def test_a_second_build_over_the_same_ledger_answers_the_same(self):
        self.document_on_file(self.RID)
        self.tell(self.RID)
        first = self.build_open((self.RID, 7, self.stamp()))
        second = self.build_open((self.RID, 7, self.stamp()))
        self.assertEqual(first["elsewhere"], [])
        self.assertEqual(second["elsewhere"], [])
        self.assertEqual(first["users"], [])
        self.assertEqual(second["users"], [])

    def test_a_claim_whose_post_may_have_landed_counts_as_told(self):
        # `attempted`: the gate claimed the request and the POST was never confirmed. It may have reached the customer
        self.document_on_file(self.RID)
        self.tell(self.RID, how="attempted")
        res = self.build_open((self.RID, 7, self.stamp()))
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["users"], [])
        self.assertEqual(res["counts"]["stamp_line_already_sent"], 1)

    def test_a_claim_the_copy_gate_gave_back_is_not_a_send_and_the_request_is_still_listed(self):
        self.tell(self.RID, how="held")
        res = self.build_open((self.RID, 7, self.stamp()))
        self.assertEqual([e["request_id"] for e in res["elsewhere"]], [self.RID])
        self.assertEqual(res["counts"].get("stamp_line_already_sent", 0), 0)

    def test_a_request_told_the_line_whose_stamp_is_gone_is_still_never_the_document_ask(self):
        # exclusive on the ledger row, not on the stamp still being there: no stamp at all, and the document is askable
        self.document_on_file(self.RID)
        self.tell(self.RID)
        res = self.build_open()
        self.assertEqual(res["users"], [])
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["counts"]["skip_told_approved_elsewhere"], 1)

    def test_a_stamp_that_says_told_with_no_ledger_row_is_backlog_and_never_either_message(self):
        # the stamp's own flag is not the answer. Two records disagree: no second line on a guess, no document ask,
        # and a backlog row that says why instead of silence
        self.document_on_file(self.RID)
        res = self.build_open((self.RID, 7, self.stamp(line_sent=True)))
        self.assertEqual(res["users"], [])
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual([(b["request_id"], b["why"]) for b in res["backlog"]], [(self.RID, "told_flag_no_ledger_row")])
        self.assertEqual(res["counts"].get("stamp_line_already_sent", 0), 0)
        self.assertEqual(res["counts"]["skip_decided_by_conflict_rule"], 1)

    def test_a_ledger_that_cannot_be_read_stops_the_build_instead_of_reading_as_nobody_told(self):
        Path(self.ledger()).write_text("not a sqlite file")
        with self.assertRaises(na.NeedError):
            self.build_open((self.RID, 7, self.stamp()))

    def test_a_build_without_the_stamp_flag_reads_no_ledger(self):
        Path(self.ledger()).write_text("not a sqlite file")
        self.document_on_file(self.RID)
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=self.open_core(),
                       now=datetime(2026, 11, 14, tzinfo=timezone.utc), ledger_path=self.ledger())
        self.assertEqual(self.document_asks(res), [self.RID])

    def test_a_request_not_yet_told_is_listed_for_the_line_and_never_the_document_ask(self):
        self.document_on_file(self.RID)
        res = self.build_open((self.RID, 7, self.stamp(line_sent=False)))
        self.assertEqual([e["request_id"] for e in res["elsewhere"]], [self.RID])
        self.assertEqual(res["users"], [])
        self.assertEqual(res["counts"]["skip_decided_by_conflict_rule"], 1)

    def test_a_stamp_the_line_cannot_carry_still_keeps_the_request_off_the_document_ask(self):
        self.document_on_file(self.RID)
        res = self.build_open((self.RID, 7, self.stamp(roles=None)))
        self.assertEqual([b["request_id"] for b in res["backlog"]], [self.RID])
        self.assertEqual(res["users"], [])

    def test_a_drain_ask_for_a_request_already_told_the_line_is_not_a_wait_row(self):
        plan = str(self.d / "plan.jsonl")
        Path(plan).write_text(json.dumps({"outcome": "ask", "user_id": 7, "request_id": self.RID}) + "\n")
        self.tell(self.RID)
        res = self.build_open((self.RID, 7, self.stamp()), from_drain=plan)
        self.assertEqual(res["waits"], [])
        self.assertEqual(res["users"], [])
        self.assertEqual(res["counts"]["drain_ask_told_approved_elsewhere"], 1)

    def test_the_send_re_read_asks_the_status_set_the_stamp_read_asked(self):
        seen = []

        def query(sql):
            seen.append(sql)
            if "FROM postgresql_core.public.users" in sql:
                return [[7, "u7@x.com", "Jane", "", ""]]
            if "FROM postgresql_core.public.credit_requests" not in sql:
                raise AssertionError(f"unexpected replica read: {sql}")
            if "'processing'" in sql:      # the replica answers the statuses the query asks for
                return [[self.RID, 7, "p1", "t1", "Song A", '[{"name": "Big Star"}]', "{Engineer}", "40",
                         "{}", "{}", "2026-11-01 00:00:00"]]
            return []
        got = na.elsewhere_payloads([{"user_id": "7", "request_id": self.RID, "roles": ["Engineer"]}], query)
        self.assertEqual(len(got), 1)
        self.assertEqual([c["request_id"] for c in got[0]["credits"]], [self.RID])
        self.assertEqual([c["role"] for c in got[0]["credits"]], ["Engineer"])
        self.assertEqual(len(seen), 2)

    def test_a_stamped_request_reaches_the_line_and_never_the_document_ask(self):
        res = self.build((self.RID, 7, self.stamp()))
        self.assertEqual(len(res["elsewhere"]), 1)
        got = res["elsewhere"][0]
        self.assertEqual(got["request_id"], self.RID)
        self.assertEqual(got["user_id"], "7")
        self.assertEqual(got["need"], "credit_approved_for_another_user")
        self.assertEqual(got["route"], "credit-approved-elsewhere")
        self.assertEqual(got["roles"], ["Engineer", "Mixing"])
        self.assertEqual(got["approved_request_ids"], ["theirs-1", "theirs-2"])
        self.assertIs(got["line_sent"], False)
        self.assertIs(got["paid"], True)
        self.assertEqual(res["backlog"], [])
        self.assertEqual(res["users"], [])
        self.assertEqual(res["waits"], [])
        self.assertEqual(res["counts"]["stamped"], 1)
        self.assertEqual(res["counts"]["elsewhere_listed"], 1)

    def test_the_line_has_its_own_campaign_and_the_document_ask_keeps_its_own(self):
        self.assertEqual(na.route_of("credit_approved_for_another_user"), "credit-approved-elsewhere")
        self.assertEqual(na.route_of("readable_document"), "proof-need-ask")
        self.assertIsNone(na.route_of("issuer_email_from_official_domain"))

    def test_no_stamp_is_a_measured_zero_and_nobody_is_listed(self):
        res = self.build()
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["backlog"], [])
        self.assertIs(res["blocked_stamps_read"], True)
        self.assertNotIn("stamped", res["counts"])

    def test_a_build_that_was_not_asked_reads_no_stamp_and_says_so(self):
        def no_query(_sql):
            raise AssertionError("no replica read without stamps=True")
        res = na.build(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=no_query,
                       now=datetime(2026, 11, 14, tzinfo=timezone.utc))
        self.assertEqual(res["elsewhere"], [])
        self.assertIs(res["blocked_stamps_read"], False)

    def test_unreadable_roles_are_null_and_backlog_never_a_guess(self):
        for bad in (None, [], "Mixing", ["Mixing", None], ["Mixing", " "], {"Mixing": 1}):
            with self.subTest(roles=bad):
                res = self.build((self.RID, 7, self.stamp(roles=bad)))
                self.assertEqual(res["elsewhere"], [])
                self.assertIsNone(res["backlog"][0]["roles"])
                self.assertEqual(res["backlog"][0]["reason"], "backlog:no_send_route")
                self.assertEqual(res["backlog"][0]["why"], "roles_unread")
                self.assertEqual(res["counts"]["backlog_roles_unread"], 1)

    def test_a_missing_roles_field_is_null(self):
        st = self.stamp()
        del st["roles"]
        res = self.build((self.RID, 7, st))
        self.assertIsNone(res["backlog"][0]["roles"])
        self.assertEqual(res["backlog"][0]["why"], "roles_unread")

    def test_a_stamp_that_is_not_an_object_is_backlog_with_null_roles(self):
        for bad in ("true", "[1]", "{not json", '"credit_approved_for_another_user"'):
            with self.subTest(stamp=bad):
                res = self.build((self.RID, 7, bad))
                self.assertEqual(res["elsewhere"], [])
                self.assertEqual(res["backlog"][0]["why"], "stamp_unread")
                self.assertIsNone(res["backlog"][0]["decision"])
                self.assertIsNone(res["backlog"][0]["roles"])

    def test_a_stamp_that_names_no_reason_is_eligible_when_its_roles_are_readable(self):
        st = self.stamp()
        del st["reason"]
        for reason_field in ({}, {"reason": None}, {"reason": " "}):
            with self.subTest(reason=reason_field):
                res = self.build((self.RID, 7, {**st, **reason_field}))
                self.assertEqual(res["backlog"], [])
                got = res["elsewhere"][0]
                self.assertEqual(got["roles"], ["Engineer", "Mixing"])
                self.assertEqual(got["approved_request_ids"], ["theirs-1", "theirs-2"])
                self.assertIs(got["reason_in_stamp"], False)

    def test_a_stamp_that_names_no_reason_and_no_readable_roles_is_backlog_roles_unread(self):
        res = self.build((self.RID, 7, {"approved_request_ids": ["theirs-1"]}))
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["backlog"][0]["why"], "roles_unread")
        self.assertEqual(res["backlog"][0]["approved_request_ids"], ["theirs-1"])

    def test_a_stamp_that_names_another_reason_is_backlog_never_this_line(self):
        res = self.build((self.RID, 7, self.stamp(reason="something_else")))
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["backlog"][0]["why"], "other_reason")
        self.assertEqual(res["backlog"][0]["decision"], "something_else")
        self.assertIsNone(res["backlog"][0]["roles"])

    def test_a_stamped_request_with_no_account_is_backlog(self):
        res = self.build((self.RID, "", self.stamp()))
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["backlog"][0]["why"], "no_user")
        self.assertIsNone(res["backlog"][0]["user_id"])

    def test_an_already_told_row_is_counted_not_listed(self):
        self.tell(self.RID2)
        res = self.build((self.RID2, 7, self.stamp()))
        self.assertEqual(res["elsewhere"], [])
        self.assertEqual(res["backlog"], [])
        self.assertEqual(res["counts"]["stamp_line_already_sent"], 1)

    def test_a_drain_ask_the_conflict_rule_decided_is_one_row_not_also_a_wait(self):
        plan = str(self.d / "plan.jsonl")
        Path(plan).write_text("".join(json.dumps({"outcome": "ask", "user_id": 7, "request_id": r}) + "\n"
                                      for r in (self.RID, self.RID2, self.RID3)))
        res = self.build((self.RID, 7, self.stamp()), (self.RID2, 7, self.stamp(roles=None)), from_drain=plan)
        self.assertEqual([e["request_id"] for e in res["elsewhere"]], [self.RID])
        self.assertEqual([b["request_id"] for b in res["backlog"]], [self.RID2])
        self.assertEqual([w["request_id"] for w in res["waits"]], [self.RID3])
        self.assertEqual(res["counts"]["drain_ask_decided_by_conflict_rule"], 2)

    def test_an_unreadable_stamp_read_stops_the_build_instead_of_reading_as_nobody_owed(self):
        def down(_sql):
            raise RuntimeError("replica down")
        with self.assertRaises(na.NeedError):
            na.build(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=down, stamps=True)
        for bad in ([["not-a-uuid", "7", "{}"]], [[self.RID, "7"]]):
            with self.subTest(rows=bad), self.assertRaises(na.NeedError):
                na.build(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=lambda _s: bad,
                         stamps=True)

    def run_cli(self, *rows):
        import contextlib
        import io
        out, err = io.StringIO(), io.StringIO()
        real, query = na.build, self.core(*rows)

        def build(**kw):
            return real(dv_store=self.dv, proof_store=self.proof, paying_path=self.paying, query=query,
                        ledger_path=self.ledger(), **kw)
        with unittest.mock.patch.object(na, "build", build), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            rc = na._main(["build", "--out", str(self.d / "list.json"), "--blocked-stamps"])
        return rc, out.getvalue(), err.getvalue()

    def test_the_cli_signals_on_stderr_and_keeps_stdout_one_json_line(self):
        rc, out, err = self.run_cli((self.RID, 7, self.stamp()), (self.RID2, 7, self.stamp(roles=None)),
                                    (self.RID3, 7, self.stamp(reason="something_else")))
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["counts"]["stamped"], 3)
        self.assertIn("NEED ASKS APPROVED_ELSEWHERE: 3 stamped (metadata.precedent_blocked), 1 listed for "
                      "credit-approved-elsewhere, 2 BACKLOG_NO_SEND_ROUTE (roles unread: 1), 0 told", err)
        lst = json.loads((self.d / "list.json").read_text())
        self.assertEqual(len(lst["elsewhere"]), 1)
        self.assertEqual(len(lst["backlog"]), 2)

    def test_the_cli_says_zero_when_nothing_is_stamped(self):
        rc, _out, err = self.run_cli()
        self.assertEqual(rc, 0)
        self.assertIn("0 stamped (metadata.precedent_blocked), 0 listed for credit-approved-elsewhere, "
                      "0 BACKLOG_NO_SEND_ROUTE (roles unread: 0), 0 told", err)

    def test_the_cli_reports_the_measured_told_count_never_a_hardcoded_zero(self):
        # QA review of hydra#1974: the line printed "0 told" whatever the ledger said, so a build that found the
        # line already sent on a request could not be told apart from one that found nothing.
        self.tell(self.RID2)
        rc, _out, err = self.run_cli((self.RID, 7, self.stamp()), (self.RID2, 7, self.stamp()))
        self.assertEqual(rc, 0)
        self.assertIn("2 stamped (metadata.precedent_blocked), 1 listed for credit-approved-elsewhere, "
                      "0 BACKLOG_NO_SEND_ROUTE (roles unread: 0), 1 told", err)

    # ---- the send path ------------------------------------------------------------------------------------------
    def listed(self, *rows):
        path = self.d / "list.json"
        path.write_text(json.dumps(self.build(*rows)))
        return str(path)

    def live(self, *pending, email="jane@example.com"):
        """The send-time re-read: the account, and the requests still pending in core (with the roles the CUSTOMER
        asked for, which are not the roles the line may name)."""
        acct = {7: {"email": email, "professional_id": "9b2f6c1e-4d3a-4e8b-a1c7-5f0e2d8b3a64", "auth_id": "auth0|7",
                    "first_name": "Jane"}}
        rows = {7: [{"request_id": rid, "profile_id": "", "track_id": "", "track_title": f"Song {i}",
                     "artist_name": "Big Star", "role": "Producer, Engineer, Mixing", "_incomplete": False, "_pop": 1}
                    for i, rid in enumerate(pending)]}
        for name, val in (("accounts_of", lambda uids, _q: {u: acct[u] for u in uids if u in acct}),
                          ("uvn_requests", lambda uids, _q, _st: {u: rows[u] for u in uids if u in rows})):
            p = unittest.mock.patch.object(na.uvn_status, name, val)
            p.start(); self.addCleanup(p.stop)

    def ledger(self):
        return str(self.d / "ledger.sqlite3")

    def test_the_payload_names_the_shared_roles_never_the_roles_the_customer_asked_for(self):
        self.live(self.RID)
        gate = FakeGate()
        rep = na.send_elsewhere(list_path=self.listed((self.RID, 7, self.stamp())), query=lambda _s: [], runner=gate,
                                ledger_path=self.ledger())
        self.assertEqual(rep.halted, "")
        self.assertEqual(len(gate.calls), 1)
        argv, payload = gate.calls[0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "credit-approved-elsewhere")
        self.assertNotIn("--copy", argv)
        self.assertEqual(payload["user"]["id"], "7")
        self.assertEqual([c["request_id"] for c in payload["credits"]], [self.RID])
        self.assertEqual(payload["credits"][0]["role"], "Engineer, Mixing")
        self.assertNotIn("need", payload)

    def test_a_dry_run_never_asks_the_gate_to_send(self):
        self.live(self.RID)
        gate = FakeGate()
        na.send_elsewhere(list_path=self.listed((self.RID, 7, self.stamp())), query=lambda _s: [], runner=gate,
                          ledger_path=self.ledger())
        argv = gate.calls[0][0]
        self.assertTrue({"--validate", "--dry-run"} & set(argv))

    def test_one_note_per_user_and_only_the_requests_still_pending(self):
        self.live(self.RID, self.RID3)            # RID2 was decided in core since the build
        gate = FakeGate()
        na.send_elsewhere(list_path=self.listed(*((r, 7, self.stamp()) for r in (self.RID, self.RID2, self.RID3))),
                          query=lambda _s: [], runner=gate, ledger_path=self.ledger())
        self.assertEqual(len(gate.calls), 1)
        self.assertEqual([c["request_id"] for c in gate.calls[0][1]["credits"]], [self.RID, self.RID3])

    def test_a_backlog_row_never_reaches_the_gate(self):
        self.live(self.RID)
        gate = FakeGate()
        rep = na.send_elsewhere(list_path=self.listed((self.RID, 7, self.stamp(roles=None))), query=lambda _s: [],
                                runner=gate, ledger_path=self.ledger())
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.candidates, 0)

    def test_a_user_with_nothing_left_or_no_account_is_named_not_dropped(self):
        gate = FakeGate()
        self.live()                               # nothing pending any more
        rep = na.send_elsewhere(list_path=self.listed((self.RID, 7, self.stamp())), query=lambda _s: [], runner=gate,
                                ledger_path=self.ledger())
        self.assertEqual(gate.calls, [])
        self.assertEqual([f["user"] for f in rep.filtered], ["7"])
        self.live(self.RID, email="")
        rep = na.send_elsewhere(list_path=self.listed((self.RID, 7, self.stamp())), query=lambda _s: [], runner=gate,
                                ledger_path=self.ledger())
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.filtered[0]["reason"], "no_deliverable_account")

    def test_a_real_run_halts_on_the_committed_gate_before_any_read(self):
        def no_read(*_a, **_k):
            raise AssertionError("a real run reads nothing")
        gate = FakeGate()
        committed = str(ROOT / "scripts" / "intercom-verify-request.sh")
        self.assertFalse(na.uvn_status.campaign_lock_open(committed, na.ELSEWHERE_LOCK))
        with unittest.mock.patch.object(na.uvn_status, "accounts_of", no_read):
            rep = na.send_elsewhere(list_path=str(self.d / "absent.json"), mode="apply", query=no_read, runner=gate,
                                    wrapper=committed, ledger_path=self.ledger())
        self.assertIn("send-locked in the gate (APPROVED_ELSEWHERE_COPY_APPROVED=0)", rep.halted)
        self.assertEqual(gate.calls, [])
        self.assertFalse(Path(self.ledger()).exists())

    def test_opening_the_lock_alone_sends_nothing_because_the_campaign_has_no_daily_cap(self):
        def no_read(*_a, **_k):
            raise AssertionError("a real run reads nothing")
        unlocked = self.d / "gate-open.sh"
        unlocked.write_text("readonly APPROVED_ELSEWHERE_COPY_APPROVED=1\n")
        gate = FakeGate()
        with unittest.mock.patch.object(na.uvn_status, "accounts_of", no_read):
            rep = na.send_elsewhere(list_path=str(self.d / "absent.json"), mode="apply", query=no_read, runner=gate,
                                    wrapper=str(unlocked), ledger_path=self.ledger())
        self.assertIn("no daily cap", rep.halted)
        self.assertEqual(gate.calls, [])
        self.assertFalse(Path(self.ledger()).exists())
        self.assertNotIn("credit-approved-elsewhere", na.uvn_status.CREDIT_GROUP)

    def test_the_cli_real_run_exits_1_and_sends_nothing(self):
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = na._main(["send-elsewhere", "--list", str(self.d / "absent.json"), "--mode", "apply"])
        self.assertEqual(rc, 1)
        self.assertEqual(json.loads(out.getvalue())["sent"], 0)

    def test_a_list_built_without_the_stamp_read_is_refused_not_read_as_nobody(self):
        path = self.d / "old.json"
        path.write_text(json.dumps({"users": [], "backlog": []}))
        with self.assertRaises(na.NeedError):
            na.send_elsewhere(list_path=str(path), query=lambda _s: [], runner=FakeGate(), ledger_path=self.ledger())


class NewerIntakeStatesTest(unittest.TestCase):
    """The ask is about the NEWEST intake, and a newer intake holds an older document's ask only while it is unread or
    while a document ask for it is inside the window. One user: document A (10-18, unreadable) then document B (10-19,
    needs a counterparty signature). Builder (need_asks.payloads) and send (comm_state.need_facts) are held to the
    same answer in every case."""

    T_A, T_B = "2026-10-18T09:30:00Z", "2026-10-19T10:00:00Z"

    def setUp(self):
        from credit_review import verify_ledger
        self.vl = verify_ledger
        self.cs = na.comm_state
        self.d = Path(tempfile.mkdtemp())
        for name in ("PROOF_STORE", "DV_STORE", "LEDGER"):
            p = unittest.mock.patch.object(self.cs, name, str(self.d / f"{name}.sqlite"))
            p.start(); self.addCleanup(p.stop)
        db = sqlite3.connect(self.cs.PROOF_STORE)
        db.execute("CREATE TABLE proof_intake (user_id INTEGER, file_sha256 TEXT, received_at TEXT, mime TEXT, "
                   "conversation_id TEXT, intake_id TEXT, matched_by TEXT DEFAULT 'professional_id')")
        db.executemany("INSERT INTO proof_intake (user_id, file_sha256, received_at, mime, conversation_id, intake_id) "
                       "VALUES (1,?,?,?,?,?)", [(SHA_A, self.T_A, "image/jpeg", "777", "1:a"),
                                                (SHA_B, self.T_B, "application/pdf", "778", "1:b")])
        db.commit(); db.close()
        db = sqlite3.connect(self.cs.DV_STORE)
        db.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, proof_id TEXT, request_id TEXT, "
                   "user_id INTEGER, outcome TEXT, need TEXT, intake_id TEXT)")
        db.commit(); db.close()
        self.read(SHA_A, "r1", "unverifiable", "readable_document", "1:a")
        self.vl.connect(self.cs.LEDGER).close()
        self.user = {"user_id": "1", "paid": True, "arrivals": [[self.T_A, "1:a"], [self.T_B, "1:b"]], "asks": [
            {"request_id": "r1", "need": "readable_document", "doc_sha": SHA_A, "doc_received_at": self.T_A,
             "doc_kind": "image", "filing_conversation": "777", "matched_by": "", "intake_id": "1:a"}]}

    def read(self, sha, rid, outcome, need, intake):
        db = sqlite3.connect(self.cs.DV_STORE)
        db.execute("INSERT INTO dv_outcomes (at, proof_id, request_id, user_id, outcome, need, intake_id) "
                   "VALUES ('2026-10-20T00:00:00Z',?,?,1,?,?,?)", (sha, rid, outcome, need, intake))
        db.commit(); db.close()

    def b_is_askable(self):
        self.read(SHA_B, "r2", "unverifiable", "counterparty_signed_or_registered", "1:b")
        self.user["asks"].append(
            {"request_id": "r2", "need": "counterparty_signed_or_registered", "doc_sha": SHA_B, "doc_received_at": self.T_B,
             "doc_kind": "PDF", "filing_conversation": "778", "matched_by": "", "intake_id": "1:b"})

    def ask_sent(self, rid, days_ago):
        day = (datetime.now(timezone.utc) - timedelta(days=days_ago)).strftime("%Y-%m-%d")
        db = self.vl.connect(self.cs.LEDGER)
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
            "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
            "VALUES ('proof-need-ask','initial','u1@x.com','1',?,'sent','comment',?,1,'U','r',?,?,?)",
            (day, json.dumps([rid]), day, day, day))
        db.execute("INSERT INTO verify_requests (campaign, request_id, message_row, status, attempts, updated_at) "
                   "VALUES ('proof-need-ask', ?, ?, 'sent', 1, ?)", (rid, cur.lastrowid, day))
        db.commit(); db.close()

    def q(self, sql):
        if "FROM postgresql_core.public.users" in sql:
            return [["1", "u1@x.com", "Jane", "", ""]]
        return [[r, "1", "p1", "t1", f"Song {r}", '[{"name": "Big Star"}]', "{Mixing}", "40", "{}", "{}"] for r in ("r1", "r2")]

    def built(self, asked=()):
        held = []
        ps = na.payloads([self.user], self.q, set(asked), held)
        return [(p["need"]["code"], [c["request_id"] for c in p["credits"]]) for p in ps], held

    def send_holds_a(self):
        """The send-time twin: would the gate hold an ask that names document A?"""
        return self.cs.need_facts(1, ["r1"], SHA_A, self.T_A, "readable_document", doc_intakes={SHA_A: "1:a"})["newer"]

    HELD_A = ["user 1: readable_document (an intake newer than its newest document)"]

    def test_an_unasked_newer_intake_is_the_one_asked_about(self):
        # readable_document comes AFTER counterparty in NEED_ORDER only by accident here: make the OLDER document the
        # counterparty one too, so the order of needs cannot be what picks B
        self.b_is_askable()
        self.assertEqual(self.built(), ([("counterparty_signed_or_registered", ["r2"])], []))
        self.user["asks"][0]["need"], self.user["asks"][1]["need"] = "counterparty_signed_or_registered", "readable_document"
        self.assertEqual(self.built(), ([("readable_document", ["r2"])], []))     # still B: the newest document

    def test_a_newer_intake_asked_about_inside_the_window_holds_the_older_document(self):
        self.b_is_askable()
        self.ask_sent("r2", days_ago=3)
        self.assertEqual(self.cs.intake_states(1), {"1:a": "read", "1:b": "asked"})
        self.assertEqual(self.built(asked={"r2"}), ([], self.HELD_A))
        self.assertEqual(self.send_holds_a(), ["newer_document:proof_intake"])

    def test_an_ask_older_than_the_window_no_longer_holds(self):
        self.b_is_askable()
        self.ask_sent("r2", days_ago=self.vl.REASK_LOCK_DAYS + 1)
        self.assertEqual(self.cs.intake_states(1)["1:b"], "read")
        self.assertEqual(self.built(asked={"r2"}), ([("readable_document", ["r1"])], []))
        self.assertEqual(self.send_holds_a(), [])

    def test_a_newer_intake_we_have_not_read_holds(self):
        # no doc-verify outcome for B at all, then one our reader could not answer: both are ours to read, both hold
        self.assertEqual(self.cs.intake_states(1)["1:b"], "unread")
        self.assertEqual(self.built(), ([], self.HELD_A))
        self.assertEqual(self.send_holds_a(), ["newer_document:proof_intake"])
        self.read(SHA_B, "r2", "unknown", "", "1:b")
        self.assertEqual(self.cs.intake_states(1)["1:b"], "unread")
        self.assertEqual(self.built(), ([], self.HELD_A))

    def test_a_newer_intake_read_with_nothing_to_ask_holds_nothing(self):
        # B was read and there is no ask to make about it (verified; the same goes for a need we do not send): it is
        # not on the list, nobody was asked about it, and it no longer keeps document A's ask back
        self.read(SHA_B, "r2", "verified", "", "1:b")
        self.assertEqual(self.cs.intake_states(1), {"1:a": "read", "1:b": "read"})
        self.assertEqual(self.built(), ([("readable_document", ["r1"])], []))
        self.assertEqual(self.send_holds_a(), [])

    def test_two_documents_of_one_second_in_two_threads_no_longer_hold_each_other(self):
        # the 50-user class: both read, neither asked about. Before, each held the other on every run.
        self.b_is_askable()
        sqlite3.connect(self.cs.PROOF_STORE).executescript(f"UPDATE proof_intake SET received_at='{self.T_A}';")
        self.user["arrivals"] = [[self.T_A, "1:a"], [self.T_A, "1:b"]]
        self.user["asks"][1]["doc_received_at"] = self.T_A
        self.assertEqual(self.built(), ([("counterparty_signed_or_registered", ["r2"])], []))
        self.assertTrue(self.cs.newer_intake(self.T_A, self.user["arrivals"], {"1:b"}))            # unmeasured: holds
        self.assertFalse(self.cs.newer_intake(self.T_A, self.user["arrivals"], {"1:b"}, self.cs.intake_states(1)))

    def test_states_that_cannot_be_read_are_the_old_rule(self):
        self.b_is_askable()
        self.read(SHA_B, "r3", "verified", "", "1:b")
        Path(self.cs.LEDGER).unlink()
        with self.assertRaises(self.cs.Unknown):
            self.cs.intake_states(1)
        self.assertEqual(self.send_holds_a(), ["newer_document:proof_intake"])
        self.user["asks"].pop()                                  # only document A is left to ask about
        self.assertEqual(self.built(), ([], self.HELD_A))


if __name__ == "__main__":
    unittest.main()
