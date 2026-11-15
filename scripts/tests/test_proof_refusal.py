"""credit_review/proof_refusal.py: who is told why their document did not verify a credit, and the send path.

The copy is the gate's (scripts/tests/intercom-verify-request.bats renders it byte for byte); this file pins the
words a customer reads to proof_reviewer.ASK_LINES, the audience rule, the send-time re-read and the CLI's rails."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import contextlib
import io
import json
import re
import sqlite3
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import proof_refusal as pr  # noqa: E402
from credit_review import proof_reviewer, verify_ledger  # noqa: E402

GATE = ROOT / "scripts" / "intercom-verify-request.sh"
CP, RD, DIST = (proof_reviewer.NEED_COUNTERPARTY, proof_reviewer.NEED_READABLE, proof_reviewer.NEED_DASHBOARD)


def rid(n: int) -> str:
    return f"00000000-0000-4000-8000-{n:012d}"


class FakeGate:
    def __init__(self, line="DRY-RUN proof-refusal initial email credits=1\n", rc=0):
        self.calls, self.line, self.rc = [], line, rc

    def __call__(self, argv):
        with open(argv[argv.index("--credits-file") + 1], encoding="utf-8") as fh:
            self.calls.append((argv, json.load(fh)))
        return type("R", (), {"returncode": self.rc, "stdout": self.line, "stderr": ""})()


class CopyPinTest(unittest.TestCase):
    """Fable's second condition: {evidence} is ASK_LINES verbatim per need code. An edit to ASK_LINES that the gate
    does not follow, or the other way round, fails here before a customer reads two different sentences."""

    def gate_evidence(self) -> dict[str, str]:
        text = GATE.read_text(encoding="utf-8")
        block = re.search(r"^def refusal_evidence: \{\n(.*?)\}\[\.\];$", text, re.M | re.S)
        self.assertIsNotNone(block, "the gate's refusal_evidence table was not found")
        return dict(re.findall(r'^\s*([a-z_]+): "([^"]*)",?$', block.group(1), re.M))

    def test_the_gate_evidence_words_are_ask_lines_verbatim_per_need_code(self):
        got = self.gate_evidence()
        self.assertEqual(sorted(got), sorted(pr.EVIDENCE))
        for need, words in got.items():
            self.assertEqual(words, proof_reviewer.ASK_LINES[need], need)

    def test_this_module_reads_the_evidence_from_ask_lines_and_retypes_nothing(self):
        for need, words in pr.EVIDENCE.items():
            self.assertIs(words, proof_reviewer.ASK_LINES[need])

    def test_the_gate_holds_exactly_the_pairs_this_module_lists(self):
        text = GATE.read_text(encoding="utf-8")
        body = text[text.index("def refusal_note($c):"):text.index("def gap_label:")]
        got = set(re.findall(r'\.reason == "([a-z_]+)" and \.need == "([a-z_]+)" then', body))
        self.assertEqual(got, set(pr.PAIRS))

    def test_the_upload_instruction_is_a_reply_and_no_address(self):
        text = GATE.read_text(encoding="utf-8")
        body = text[text.index("def refusal_note($c):"):text.index("def gap_label:")]
        self.assertIn('"Reply to this conversation with it and the check runs again automatically. '
                      'Without it, the result stands." as $close', body)
        self.assertNotIn("@", body)

    def test_the_gate_lock_is_the_one_this_module_reads(self):
        self.assertTrue(pr.uvn_status.campaign_lock_open(str(GATE), pr.LOCK))


class Fixture(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.ledger = str(self.d / "ledger.sqlite3")
        verify_ledger.connect(self.ledger).close()
        db = sqlite3.connect(self.ledger)
        db.executescript(proof_reviewer.DECISIONS)
        db.commit(); db.close()
        self.paying = str(self.d / "paying.json")
        Path(self.paying).write_text(json.dumps({"ids": [9]}))
        self.n = 0
        # the CLI sets these process-wide (as the tick's one process per run expects); a test never inherits them
        for reset in (lambda: pr.verify_notify.set_apply_budget(None),
                      lambda: setattr(pr.verify_notify, "APPLY_ONLY", None),
                      lambda: setattr(pr.verify_notify, "APPLY_PAGE", False)):
            reset()
            self.addCleanup(reset)

    def note(self, account: str | None) -> int:
        db = sqlite3.connect(self.ledger)
        self.n += 1
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
            "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
            "VALUES ('uvn-status','initial',?,?,'2026-11-01','sent','email','[]',1,'U','ref','t','t')",
            (f"u{self.n}@example.com", account))
        db.commit(); fam = cur.lastrowid; db.close()
        return fam

    def reject(self, n: int, account: str | None, reason: str, need: str, *, route: str = "proof-need-ask",
               decision: bool = True, decision_reason: str | None = None, reverted: bool = False,
               run: str = "pr-1") -> int:
        fam = self.note(account)
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_proof_reviews (family, request_id, outcome, reason, document, reviewed_at, "
                   "reviewed_by) VALUES (?,?,'rejected',?,1,?,'proof-reviewer/pr-1')",
                   (fam, rid(n), reason, f"2026-11-15T12:{n % 60:02d}:00Z"))
        if decision:
            db.execute("INSERT INTO proof_review_decisions (run_id, rule, decided_at, message_row, family, request_id, "
                       "account_id, outcome, reason, ask_need, ask_route, basis_json, reviewer, result, reverted_at) "
                       "VALUES (?,?,?,?,?,?,?,'rejected',?,?,?,'[]','ai','ok',?)",
                       (run, "pr-1", "t", fam, fam, rid(n), account, decision_reason or reason, need or None, route,
                        "2026-11-15T13:00:00Z" if reverted else None))
        db.commit(); db.close()
        return fam

    def build(self):
        return pr.build(ledger=self.ledger, paying_path=self.paying)

    def listed(self):
        path = self.d / "list.json"
        path.write_text(json.dumps(self.build()))
        return str(path)

    def live(self, rows: dict[int, list[dict]], accounts: dict[int, dict] | None = None):
        """The send-time re-read: the account and the requests still pending in core."""
        acct = accounts if accounts is not None else {
            u: {"email": f"u{u}@example.com", "professional_id": "9b2f6c1e-4d3a-4e8b-a1c7-5f0e2d8b3a64",
                "auth_id": f"auth0|{u}", "first_name": "Jane"} for u in rows}
        for name, val in (("accounts_of", lambda uids, _q: {u: acct[u] for u in uids if u in acct}),
                          ("uvn_requests", lambda uids, _q, _st: {u: rows[u] for u in uids if u in rows})):
            p = unittest.mock.patch.object(pr.uvn_status, name, val)
            p.start(); self.addCleanup(p.stop)

    @staticmethod
    def pending(n: int, **over) -> dict:
        return {"request_id": rid(n), "profile_id": "p", "track_id": f"t{n}", "track_title": f"Song {n}",
                "artist_name": "Big Star", "role": "Mixing", "_incomplete": False, "_no_ask": "",
                "_never_ask": False, **over}


class BuildTest(Fixture):
    def test_a_row_is_listed_only_where_an_approved_body_says_what_the_reader_recorded(self):
        self.reject(1, "7", "doesnt_name_you", CP)
        self.reject(2, "7", "other_track", CP)
        self.reject(3, "8", "unreadable", RD)
        res = self.build()
        self.assertEqual(res["counts"]["listed_rows"], 3)
        self.assertEqual(res["counts"]["listed_users"], 2)
        self.assertEqual(res["held"], {})

    def test_the_readers_distributor_need_is_held_and_never_given_the_counterparty_body(self):
        self.reject(1, "7", "doesnt_name_you", DIST)
        res = self.build()
        self.assertEqual(res["users"], [])
        self.assertEqual(res["held"][f"reader_need:{DIST}"]["rows"], 1)

    def test_a_reason_paired_with_the_other_bodys_need_is_held(self):
        self.reject(1, "7", "unreadable", CP)
        self.reject(2, "7", "doesnt_name_you", RD)
        res = self.build()
        self.assertEqual(res["users"], [])
        self.assertEqual(res["counts"]["held_rows"], 2)

    def test_a_row_the_reader_named_no_need_for_is_held(self):
        self.reject(1, "7", "other_track", "", route="blocked:no_unverifiable_read")
        self.assertEqual(self.build()["held"]["reader_named_no_need"]["rows"], 1)

    def test_a_reason_with_no_approved_body_is_held(self):
        self.reject(1, "7", "not_a_document", CP)
        self.reject(2, "7", "other_role", CP)
        self.assertEqual(self.build()["held"]["no_body_for_reason"]["rows"], 2)

    def test_a_row_with_no_account_is_held(self):
        self.reject(1, None, "unreadable", RD)
        res = self.build()
        self.assertEqual(res["users"], [])
        self.assertEqual(res["held"]["no_account"]["rows"], 1)

    def test_a_review_with_no_decision_or_a_reverted_one_is_held(self):
        self.reject(1, "7", "unreadable", RD, decision=False)
        self.reject(2, "7", "unreadable", RD, reverted=True)
        self.assertEqual(self.build()["held"]["no_matching_decision"]["rows"], 2)

    def test_a_decision_that_names_another_reason_than_the_review_row_is_held(self):
        self.reject(1, "7", "unreadable", RD, decision_reason="other_track")
        self.assertEqual(self.build()["held"]["no_matching_decision"]["rows"], 1)

    def test_a_person_with_held_and_listed_rows_is_listed_for_the_listed_rows_only(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "7", "not_a_document", CP)
        res = self.build()
        self.assertEqual([r["request_id"] for r in res["users"][0]["rows"]], [rid(1)])
        self.assertEqual(res["held"]["no_body_for_reason"]["users_also_listed"], 1)

    def test_every_rejected_row_is_listed_or_held(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "7", "doesnt_name_you", DIST)
        self.reject(3, None, "unreadable", RD)
        c = self.build()["counts"]
        self.assertEqual(c["listed_rows"] + c["held_rows"], c["rejected_rows"])

    def test_paying_users_are_listed_first(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "9", "unreadable", RD)
        self.reject(3, "8", "unreadable", RD)
        res = self.build()
        self.assertEqual([u["user_id"] for u in res["users"]], [9, 7, 8])
        self.assertEqual(res["counts"]["listed_paid"], 1)

    def test_each_row_carries_the_review_row_it_answers(self):
        fam = self.reject(1, "7", "other_track", CP)
        row = self.build()["users"][0]["rows"][0]
        self.assertEqual((row["family"], row["reason"], row["need"]), (fam, "other_track", CP))

    def test_the_list_records_the_reviewer_runs_and_the_row_count_it_was_built_from(self):
        self.reject(1, "7", "unreadable", RD, run="pr-A")
        self.reject(2, "8", "unreadable", RD, run="pr-B")
        src = self.build()["source"]
        self.assertEqual(src["reviewer_runs"], ["pr-A", "pr-B"])
        self.assertEqual(src["rejected_rows"], 2)

    def test_an_unreadable_paying_file_lists_nothing(self):
        self.reject(1, "7", "unreadable", RD)
        with self.assertRaises(pr.RefusalError):
            pr.build(ledger=self.ledger, paying_path=str(self.d / "absent.json"))

    def test_an_unreadable_ledger_lists_nothing(self):
        with self.assertRaises(pr.RefusalError):
            pr.build(ledger=str(self.d / "no" / "ledger.sqlite3"), paying_path=self.paying)


class SendTest(Fixture):
    def send(self, gate, **kw):
        return pr.send(list_path=self.listed(), segment=kw.pop("segment", "free"), query=lambda _s: [], runner=gate,
                       ledger_path=self.ledger, **kw)

    def test_one_payload_per_person_carries_every_listed_request_with_its_own_reason(self):
        f1 = self.reject(1, "7", "doesnt_name_you", CP)
        f2 = self.reject(2, "7", "unreadable", RD)
        self.live({7: [self.pending(1), self.pending(2)]})
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(rep.halted, "")
        self.assertEqual(len(gate.calls), 1)
        argv, payload = gate.calls[0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "proof-refusal")
        self.assertNotIn("--copy", argv)
        self.assertEqual(payload["user"]["id"], "7")
        self.assertEqual([(c["request_id"], c["reason"], c["need"], c["review_family"]) for c in payload["credits"]],
                         [(rid(1), "doesnt_name_you", CP, f1), (rid(2), "unreadable", RD, f2)])
        self.assertEqual(sorted(payload), ["credits", "user"])

    def test_the_title_and_role_come_from_the_live_read(self):
        self.reject(1, "7", "doesnt_name_you", CP)
        self.live({7: [self.pending(1, track_title="Night Drive", role="Mastering")]})
        gate = FakeGate()
        self.send(gate)
        c = gate.calls[0][1]["credits"][0]
        self.assertEqual((c["track_title"], c["role"]), ("Night Drive", "Mastering"))

    def test_a_dry_run_never_asks_the_gate_to_send(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        self.send(gate)
        self.assertIn("--validate", gate.calls[0][0])
        self.assertNotIn("--live", gate.calls[0][0])

    def test_a_request_no_longer_pending_is_dropped_and_the_rest_still_go(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "7", "unreadable", RD)
        self.live({7: [self.pending(2)]})
        gate = FakeGate()
        self.send(gate)
        self.assertEqual([c["request_id"] for c in gate.calls[0][1]["credits"]], [rid(2)])

    def test_a_person_with_no_pending_request_left_is_filtered_with_the_reason(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: []})
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("not_pending_now", rep.filtered[0]["reason"])

    def test_a_request_held_for_a_cause_no_document_clears_is_never_named(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "8", "unreadable", RD)
        self.live({7: [self.pending(1, _never_ask=True)],
                   8: [self.pending(2, _no_ask=pr.uvn_status.NEVER_ASKED)]})
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(gate.calls, [])
        self.assertEqual([f["user"] for f in rep.filtered], ["7", "8"])
        self.assertIn("never_ask", rep.filtered[0]["reason"])
        self.assertIn("never_ask", rep.filtered[1]["reason"])

    def test_a_request_another_class_holds_is_not_named(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1, _no_ask="approval_path")]})
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("no_ask:approval_path", rep.filtered[0]["reason"])

    def test_a_request_a_proof_need_ask_already_named_is_not_refused_on_top_of_it(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_requests (request_id, campaign, message_row, status, updated_at) "
                   "VALUES (?, 'proof-need-ask', 1, 'sent', 't')", (rid(1),))
        db.commit(); db.close()
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("told_by_need_ask", rep.filtered[0]["reason"])

    def test_a_request_this_campaign_already_wrote_about_is_not_sent_again(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_requests (request_id, campaign, message_row, status, updated_at) "
                   "VALUES (?, 'proof-refusal', 1, 'sent', 't')", (rid(1),))
        db.commit(); db.close()
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("already_told", rep.filtered[0]["reason"])

    def test_a_person_with_no_deliverable_account_is_filtered(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]}, accounts={})
        gate = FakeGate()
        rep = self.send(gate)
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.filtered[0]["reason"], "no_deliverable_account")

    def test_the_segment_selects_paid_or_free_never_both(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "9", "unreadable", RD)
        self.live({7: [self.pending(1)], 9: [self.pending(2)]})
        gate = FakeGate()
        self.send(gate, segment="paid")
        self.assertEqual([p["user"]["id"] for _a, p in gate.calls], ["9"])

    def test_max_users_bounds_the_run_and_names_the_rest_as_a_later_batch(self):
        for n, u in enumerate(("5", "6", "7"), start=1):
            self.reject(n, u, "unreadable", RD)
        self.live({5: [self.pending(1)], 6: [self.pending(2)], 7: [self.pending(3)]})
        gate = FakeGate()
        rep = self.send(gate, max_users=2)
        self.assertEqual(len(gate.calls), 2)
        self.assertEqual([f["user"] for f in rep.filtered], ["7"])
        self.assertIn("a later batch", rep.filtered[0]["reason"])

    def test_a_list_built_for_another_campaign_is_refused(self):
        path = self.d / "other.json"
        path.write_text(json.dumps({"campaign": "proof-need-ask", "users": []}))
        with self.assertRaises(pr.RefusalError):
            pr.send(list_path=str(path), segment="free", query=lambda _s: [], runner=FakeGate(),
                    ledger_path=self.ledger)

    def test_an_apply_on_a_send_locked_gate_sends_nothing(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        locked = self.d / "locked.sh"
        locked.write_text("readonly PROOF_REFUSAL_COPY_APPROVED=0\n")
        gate = FakeGate()
        rep = self.send(gate, mode="apply", wrapper=str(locked))
        self.assertEqual(gate.calls, [])
        self.assertIn("send-locked", rep.halted)

    def test_an_apply_with_an_unreadable_policy_sends_nothing(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        with unittest.mock.patch.object(pr.uvn_status, "POLICY_OK", False):
            rep = self.send(gate, mode="apply", wrapper=str(GATE))
        self.assertEqual(gate.calls, [])
        self.assertIn("cap_policy_unreadable", rep.halted)

    def test_an_apply_outside_the_policy_credit_group_sends_nothing(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        with unittest.mock.patch.object(pr.uvn_status, "POLICY_OK", True), \
                unittest.mock.patch.object(pr.uvn_status, "CREDIT_GROUP", ("uvn-status",)):
            rep = self.send(gate, mode="apply", wrapper=str(GATE))
        self.assertEqual(gate.calls, [])
        self.assertIn("no place in the policy's credit group", rep.halted)

    def test_an_apply_with_the_shared_daily_budget_spent_defers_everyone(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        with unittest.mock.patch.object(pr.uvn_status, "POLICY_OK", True), \
                unittest.mock.patch.object(pr.uvn_status, "CREDIT_GROUP", ("uvn-status", "proof-refusal")), \
                unittest.mock.patch.object(pr.uvn_status, "credit_group_left", lambda _l, _d: 0):
            rep = self.send(gate, mode="apply", wrapper=str(GATE))
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.candidates, 0)
        self.assertIn("daily_cap", rep.outcomes[0]["reason"])


class ReadbackTest(Fixture):
    """Between runs: sent = claimed, 0 bounces, 0 complaints. Anything else, or anything unread, runs no batch."""

    def sent(self, contact: str | None, status: str = "sent", day: str = "2026-11-15", campaign: str = "proof-refusal"):
        db = sqlite3.connect(self.ledger)
        self.n += 1
        db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, contact_id, "
            "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
            "VALUES (?,'initial',?,'7',?,?,'email',?,'[]',1,'U','ref','t','t')",
            (campaign, f"r{self.n}@example.com", day, status, contact))
        db.commit(); db.close()

    def read(self, contacts: dict[str, dict | None]):
        return pr.readback(ledger=self.ledger, fetch=lambda cid: contacts.get(cid))

    def test_nothing_sent_yet_is_ok(self):
        res = self.read({})
        self.assertEqual((res["verdict"], res["claimed"], res["sent"]), ("ok", 0, 0))

    def test_every_claimed_note_sent_with_no_bounce_and_no_complaint_is_ok(self):
        self.sent("c1"); self.sent("c2")
        res = self.read({"c1": {}, "c2": {"has_hard_bounced": False, "marked_email_as_spam": False}})
        self.assertEqual(res["verdict"], "ok")
        self.assertEqual((res["claimed"], res["sent"], res["contacts_read"]), (2, 2, 2))

    def test_a_claim_no_post_confirmed_stops(self):
        self.sent("c1"); self.sent(None, status="attempted")
        res = self.read({"c1": {}})
        self.assertEqual(res["verdict"], "stop")
        self.assertIn("sent 1 != claimed 2", res["why"])

    def test_one_hard_bounce_stops(self):
        self.sent("c1"); self.sent("c2")
        res = self.read({"c1": {}, "c2": {"has_hard_bounced": True}})
        self.assertEqual(res["verdict"], "stop")
        self.assertEqual(res["hard_bounced"], 1)

    def test_one_spam_complaint_stops(self):
        self.sent("c1")
        res = self.read({"c1": {"marked_email_as_spam": True}})
        self.assertEqual(res["verdict"], "stop")
        self.assertEqual(res["spam_complaints"], 1)

    def test_a_contact_that_cannot_be_read_is_unmeasured_never_ok(self):
        self.sent("c1"); self.sent("c2")
        res = self.read({"c1": {}, "c2": None})
        self.assertEqual(res["verdict"], "unmeasured")

    def test_a_sent_row_that_names_no_contact_is_unmeasured(self):
        self.sent(None)
        self.assertEqual(self.read({})["verdict"], "unmeasured")

    def test_a_measured_bounce_is_a_stop_even_when_another_contact_went_unread(self):
        self.sent("c1"); self.sent("c2")
        res = self.read({"c1": {"has_hard_bounced": True}, "c2": None})
        self.assertEqual(res["verdict"], "stop")

    def test_another_campaigns_rows_are_not_read(self):
        self.sent("c9", campaign="uvn-status")
        res = self.read({"c9": {"has_hard_bounced": True}})
        self.assertEqual((res["verdict"], res["claimed"]), ("ok", 0))

    def test_the_counts_are_kept_per_day(self):
        self.sent("c1", day="2026-11-15"); self.sent("c2", day="2026-11-16")
        res = self.read({"c1": {}, "c2": {}})
        self.assertEqual(res["by_day"], {"2026-11-15": {"claimed": 1, "sent": 1}, "2026-11-16": {"claimed": 1, "sent": 1}})

    def test_an_unreadable_ledger_is_unmeasured(self):
        res = pr.readback(ledger=str(self.d / "no" / "l.sqlite3"), fetch=lambda _c: {})
        self.assertEqual(res["verdict"], "unmeasured")

    def test_with_no_token_a_contact_is_unread_never_clean(self):
        with unittest.mock.patch.dict(pr.os.environ, {"MUSOAI_INTERCOM_TOKEN": ""}):
            self.assertIsNone(pr._contact("c1"))

    def test_the_cli_exit_code_is_0_ok_3_stop_2_unmeasured(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc_ok = pr._main(["readback", "--ledger", self.ledger])
        self.sent(None, status="attempted")
        with contextlib.redirect_stdout(buf):
            rc_stop = pr._main(["readback", "--ledger", self.ledger])
            rc_unm = pr._main(["readback", "--ledger", str(self.d / "no" / "l.sqlite3")])
        self.assertEqual((rc_ok, rc_stop, rc_unm), (0, 3, 2))


class DecisionMovedTest(Fixture):
    """The list is built once per tick and the reviewer runs beside it. What the ledger says about a row is read
    again when the page is read and again immediately before each person's own gate call on an apply."""

    def sql(self, statement: str, args: tuple = ()) -> None:
        db = sqlite3.connect(self.ledger)
        db.execute(statement, args)
        db.commit(); db.close()

    def revert(self, fam: int) -> None:
        self.sql("UPDATE proof_review_decisions SET reverted_at='2026-11-15T15:00:00Z' WHERE family=?", (fam,))

    def redecide(self, fam: int, n: int, account: str, reason: str, need: str, outcome: str = "rejected") -> None:
        self.sql("INSERT INTO proof_review_decisions (run_id, rule, decided_at, message_row, family, request_id, "
                 "account_id, outcome, reason, ask_need, ask_route, basis_json, reviewer, result) "
                 "VALUES ('pr-2','pr-1','t2',?,?,?,?,?,?,?,'proof-need-ask','[]','ai','ok')",
                 (fam, fam, rid(n), account, outcome, reason, need or None))

    def dry(self, list_path: str, gate):
        return pr.send(list_path=list_path, segment="free", query=lambda _s: [], runner=gate,
                       ledger_path=self.ledger)

    def apply(self, list_path: str, gate, **patches):
        with contextlib.ExitStack() as st:
            for name, val in {"POLICY_OK": True, "CREDIT_GROUP": ("uvn-status", "proof-refusal"),
                              "credit_group_left": lambda _l, _d: 100}.items():
                st.enter_context(unittest.mock.patch.object(pr.uvn_status, name, val))
            for name, val in patches.items():
                st.enter_context(unittest.mock.patch.object(pr, name, val))
            return pr.send(list_path=list_path, segment="free", mode="apply", query=lambda _s: [], runner=gate,
                           wrapper=str(GATE), ledger_path=self.ledger)

    def test_a_row_stands_while_the_ledger_says_what_the_list_said(self):
        fam = self.reject(1, "7", "unreadable", RD)
        self.assertEqual(pr.moved(self.ledger, [(7, fam, rid(1), "unreadable", RD)]), {})

    def test_a_rejection_reverted_after_the_build_is_not_sent(self):
        fam = self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.revert(fam)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("decision_changed", rep.filtered[0]["reason"])
        self.assertIn("no unreverted rejection decision stands", rep.filtered[0]["reason"])

    def test_a_need_the_reviewer_changed_after_the_build_is_not_sent_under_the_old_evidence(self):
        fam = self.reject(1, "7", "doesnt_name_you", CP)
        lst = self.listed()
        self.redecide(fam, 1, "7", "doesnt_name_you", DIST)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("the decision names another need", rep.filtered[0]["reason"])

    def test_a_reason_the_reviewer_changed_after_the_build_is_not_sent_under_the_old_reason(self):
        fam = self.reject(1, "7", "doesnt_name_you", CP)
        lst = self.listed()
        self.redecide(fam, 1, "7", "other_track", CP)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("the decision names another reason", rep.filtered[0]["reason"])

    def test_a_review_row_that_became_an_acceptance_is_not_sent(self):
        fam = self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.sql("UPDATE verify_proof_reviews SET outcome='accepted', reason=NULL WHERE family=?", (fam,))
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("the review row is no longer a rejection", rep.filtered[0]["reason"])

    def test_a_review_row_that_is_gone_is_not_sent(self):
        fam = self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.sql("DELETE FROM verify_proof_reviews WHERE family=?", (fam,))
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("decision_changed", rep.filtered[0]["reason"])

    def test_a_decision_moved_to_another_account_is_not_sent(self):
        fam = self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.redecide(fam, 1, "8", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("the decision is on another account", rep.filtered[0]["reason"])

    def test_at_the_page_read_only_the_moved_row_is_dropped(self):
        fam = self.reject(1, "7", "unreadable", RD)
        self.reject(2, "7", "unreadable", RD)
        lst = self.listed()
        self.revert(fam)
        self.live({7: [self.pending(1), self.pending(2)]})
        gate = FakeGate()
        self.dry(lst, gate)
        self.assertEqual([c["request_id"] for c in gate.calls[0][1]["credits"]], [rid(2)])

    def test_an_unreadable_ledger_at_the_page_read_sends_nothing(self):
        self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.live({7: [self.pending(1)]})
        gate = FakeGate()
        with unittest.mock.patch.object(pr, "moved", unittest.mock.Mock(side_effect=pr.RefusalError("gone"))):
            rep = self.dry(lst, gate)
        self.assertEqual(gate.calls, [])
        self.assertIn("unreadable", rep.halted)

    def test_an_apply_sends_a_row_that_still_stands(self):
        self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.live({7: [self.pending(1)]})
        gate = FakeGate("POSTED email message=1001 credits=1\n")
        rep = self.apply(lst, gate)
        self.assertEqual(rep.halted, "")
        self.assertEqual(len(gate.calls), 1)
        self.assertEqual([f for f in pr.verify_notify._READ_ONLY_FLAGS if f in gate.calls[0][0]], [])
        self.assertEqual(rep.sent_notes, 1)

    def test_a_decision_that_moves_between_the_page_read_and_the_gate_call_holds_the_whole_person(self):
        fam = self.reject(1, "7", "doesnt_name_you", CP)
        self.reject(2, "7", "unreadable", RD)
        self.reject(3, "8", "unreadable", RD)
        lst = self.listed()
        self.live({7: [self.pending(1), self.pending(2)], 8: [self.pending(3)]})
        real, calls = pr.moved, []

        def moved(ledger, rows):
            calls.append(len(rows))
            if len(calls) == 2:                   # after the page's read, before the first person's gate call
                self.redecide(fam, 1, "7", "doesnt_name_you", DIST)
            return real(ledger, rows)

        gate = FakeGate("POSTED email message=1001 credits=1\n")
        rep = self.apply(lst, gate, moved=moved)
        self.assertEqual([p["user"]["id"] for _a, p in gate.calls], ["8"])
        held = [o for o in rep.outcomes if o["user"] == "7"]
        self.assertEqual(len(held), 1)
        self.assertEqual(held[0]["result"], "deferred")
        self.assertIn("decision_changed: 1 of 2 row(s)", held[0]["reason"])
        self.assertEqual(rep.sent_notes, 1)
        self.assertEqual(rep.halted, "")

    def test_a_person_held_at_the_gate_call_keeps_no_ledger_row_and_is_listed_again(self):
        fam = self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.live({7: [self.pending(1)]})
        real, calls = pr.moved, []

        def moved(ledger, rows):
            calls.append(1)
            if len(calls) == 2:
                self.revert(fam)
            return real(ledger, rows)

        gate = FakeGate("POSTED email message=1001 credits=1\n")
        self.apply(lst, gate, moved=moved)
        self.assertEqual(gate.calls, [])
        db = sqlite3.connect(self.ledger)
        n = db.execute("SELECT count(*) FROM verify_messages WHERE campaign='proof-refusal'").fetchone()[0]
        db.close()
        self.assertEqual(n, 0)
        self.assertEqual(self.build()["held"]["no_matching_decision"]["rows"], 1)
        self.sql("UPDATE proof_review_decisions SET reverted_at=NULL WHERE family=?", (fam,))
        self.assertEqual(self.build()["counts"]["listed_users"], 1)

    def test_decisions_that_cannot_be_re_read_at_the_gate_call_stop_the_apply(self):
        self.reject(1, "7", "unreadable", RD)
        lst = self.listed()
        self.live({7: [self.pending(1)]})
        real, calls = pr.moved, []

        def moved(ledger, rows):
            calls.append(1)
            if len(calls) == 2:
                raise pr.RefusalError("the ledger is unreadable (disk I/O error)")
            return real(ledger, rows)

        gate = FakeGate("POSTED email message=1001 credits=1\n")
        rep = self.apply(lst, gate, moved=moved)
        self.assertEqual(gate.calls, [])
        self.assertIn("nobody further started", rep.halted)

    def test_an_unreadable_ledger_never_reads_as_nothing_moved(self):
        with self.assertRaises(pr.RefusalError):
            pr.moved(str(self.d / "no" / "ledger.sqlite3"), [(7, 1, rid(1), "unreadable", RD)])


class CliTest(Fixture):
    def run_cli(self, *argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = pr._main(list(argv))
        return rc, buf.getvalue()

    def test_build_writes_the_list_and_prints_the_counts_and_the_held_classes(self):
        self.reject(1, "7", "unreadable", RD)
        self.reject(2, "7", "doesnt_name_you", DIST)
        out = self.d / "list.json"
        rc, text = self.run_cli("build", "--out", str(out), "--ledger", self.ledger, "--paying", self.paying)
        self.assertEqual(rc, 0)
        line = json.loads(text)
        self.assertEqual(line["counts"]["listed_users"], 1)
        self.assertEqual(line["held"][f"reader_need:{DIST}"], {"rows": 1, "users": 1})
        self.assertEqual(json.loads(out.read_text())["campaign"], "proof-refusal")

    def test_build_with_an_unreadable_ledger_exits_2_and_writes_no_list(self):
        out = self.d / "list.json"
        rc, text = self.run_cli("build", "--out", str(out), "--ledger", str(self.d / "no" / "l.sqlite3"),
                                "--paying", self.paying)
        self.assertEqual(rc, 2)
        self.assertIn("nothing listed", text)
        self.assertFalse(out.exists())

    def test_an_apply_without_the_signed_check_is_refused_before_any_gate_call(self):
        self.reject(1, "7", "unreadable", RD)
        gate = FakeGate()
        with unittest.mock.patch.object(pr, "send", lambda **kw: self.fail("send was reached")):
            rc, text = self.run_cli("send", "--list", self.listed(), "--segment", "free", "--mode", "apply")
        self.assertEqual(rc, 2)
        self.assertIn("--signed-accepted", text)
        self.assertEqual(gate.calls, [])

    def test_the_cli_accepts_every_argument_the_tick_passes(self):
        self.reject(1, "7", "unreadable", RD)
        self.live({7: [self.pending(1)]})
        gate = FakeGate("RECIPIENT OK proof-refusal initial copy=refusal credits=1\n")
        real = pr.send
        out = self.d / "check.json"
        with unittest.mock.patch.object(pr, "send", lambda **kw: real(**{**kw, "query": lambda _s: [],
                                                                         "runner": gate, "ledger_path": self.ledger})):
            rc, text = self.run_cli("send", "--list", self.listed(), "--segment", "free", "--max-entries", "100",
                                    "--start-entry", "0", "--mode", "dry-run", "--max-users", "100",
                                    "--check-recipients", "--outcomes-json", str(out), "--apply-budget-s", "60")
        self.assertEqual(rc, 0, text)
        doc = json.loads(out.read_text())
        self.assertTrue(doc["balanced"])
        self.assertEqual(doc["would_send_users"], ["7"])
        self.assertEqual(doc["page"]["listed"], 1)

    def test_an_unreadable_list_exits_2(self):
        rc, text = self.run_cli("send", "--list", str(self.d / "absent.json"), "--segment", "free")
        self.assertEqual(rc, 2)
        self.assertIn("nothing listed or sent", text)


if __name__ == "__main__":
    unittest.main()
