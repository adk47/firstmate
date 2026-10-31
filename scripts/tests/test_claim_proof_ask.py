"""claim-proof-ask runner (steers-1830 #5, firstmate 125/126). The gate is faked; its own
behaviour (copy, locks, the close day, the day-7 reminder) is in intercom-verify-request.bats.
Replica rows use the shapes Trino really returns (every column a string). No network."""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import claim_proof_ask, verify_ledger  # noqa: E402
from credit_review import verify_notify as _vn_r5  # noqa: E402
_vn_r5.PRESENTED_LOOKUP = lambda ids: {}  # r5: presented profile ids never come from the replica in tests
from credit_retro import waves  # noqa: E402

NOW = datetime(2026, 10, 24, 9, 0, tzinfo=timezone.utc)
PRO = "9b2f6c1e-4d3a-4e8b-a1c7-5f0e2d8b3a64"


def iso(h: float) -> str:
    return (NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")


def claim(cid: int, uid: int, **kw):
    return {"claim_id": cid, "user_id": uid, "paid": True, "band": "B", "profile_name": "Big Star",
            "profile_url": "https://credits.muso.ai/profile/abc", "code": "MUSO-7K2Q", "platform": "spotify", "profile_id": "abc",
            "code_found": False, **kw}


class FakeGate:
    def __init__(self, out="POSTED email message=1 credits=1"):
        self.calls, self.out = [], out

    def __call__(self, argv):
        self.calls.append((argv, json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())))
        return subprocess.CompletedProcess(argv, 0, self.out, "")


class LedgerGate(FakeGate):
    """A gate that records each first note in the ledger as sent, as the real gate does."""
    def __init__(self, ledger: str, day: str):
        super().__init__()
        self.ledger, self.day, self.n = ledger, day, 0

    def __call__(self, argv):
        res = super().__call__(argv)
        p = self.calls[-1][1]
        db = verify_ledger.connect(self.ledger)
        c = verify_ledger.claim(db, campaign="claim-proof-ask", user_key=p["user"]["email"], day=self.day,
                                request_ids=[p["credits"][0]["request_id"]], message_type="email",
                                approved_by="U7RP6HKUZ", approval_ref="ref", user_id=p["user"]["id"])
        self.n += 1
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"80{self.n}")
        db.close()
        return res


def replica(states: dict[int, tuple[str, int]], users: dict[int, str] | None = None):
    """Trino rows as strings: claiming(id, status, userid) and users(id, email, firstname, pro, auth0).
    q.user_reads counts the account lookups."""
    def q(sql):
        if "public.claiming" in sql:
            return [[str(c), s, str(u)] for c, (s, u) in states.items()]
        q.user_reads += 1
        return [[str(u), e, "Jane", PRO if e else "", ""] for u, e in (users or {}).items()]
    q.user_reads = 0
    return q


class ClaimProofAskTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = str(Path(self.tmp.name) / "l.sqlite3")
        self.export = str(Path(self.tmp.name) / "asked.jsonl")

    def tearDown(self):
        self.tmp.cleanup()

    def lst(self, claims, *, gen=1, check_owner="claim-flow-fix-fable-c1", check_age=2):
        p = Path(self.tmp.name) / "list.json"
        doc = {"generated_at": iso(gen), "claims": claims}
        if check_owner is not None:
            doc["daily_check"] = {"owner": check_owner, "last_run_at": iso(check_age)}
        p.write_text(json.dumps(doc))
        return str(p)

    def go(self, path, q, **kw):
        gate = kw.pop("gate", FakeGate())
        rep = claim_proof_ask.run(list_path=path, segment=kw.pop("segment", "paid"), mode=kw.pop("mode", "apply"),
                                  max_users=kw.pop("max_users", 20), query=q, wrapper="/gate", runner=gate,
                                  ledger_path=self.ledger, support_contacts=kw.pop("support", frozenset()),
                                  now=kw.pop("now", NOW), export_path=self.export, **kw)
        return rep, gate

    def test_nothing_sends_without_a_named_recent_daily_code_check(self):
        """firstmate 126: 'we check for it every day' must be true."""
        q = replica({1: ("pending", 7)}, {7: "a@x.com"})
        for kw in ({"check_owner": None}, {"check_owner": ""}, {"check_age": 31}):
            rep, gate = self.go(self.lst([claim(1, 7)], **kw), q)
            self.assertTrue(rep.halted, kw)
            self.assertEqual(gate.calls, [])
        rep, gate = self.go(self.lst([claim(1, 7)], gen=31), q)
        self.assertIn("old", rep.halted)
        self.assertEqual(gate.calls, [])

    def test_one_claim_per_user_paid_first_bands_b_c_only_never_a_found_code(self):
        claims = [claim(1, 7), claim(2, 7), claim(3, 8, band="A"), claim(4, 9, code_found=True),
                  claim(5, 10, paid=False), claim(6, 11, band="c")]
        q = replica({c: ("pending", u) for c, u in ((1, 7), (2, 7), (3, 8), (4, 9), (5, 10), (6, 11))},
                    {7: "a@x.com", 8: "b@x.com", 9: "c@x.com", 10: "d@x.com", 11: "e@x.com"})
        rep, gate = self.go(self.lst(claims), q)
        sent = [p["credits"][0]["request_id"] for _, p in gate.calls]
        self.assertEqual(sent, ["claim-1", "claim-6"])
        self.assertEqual((rep.second_claim, rep.not_band, rep.code_found), (1, 1, 1))
        argv, p = gate.calls[0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "claim-proof-ask")
        self.assertEqual(p["claim"], {"profile_name": "Big Star", "profile_url": "https://credits.muso.ai/profile/abc",
                                      "code": "MUSO-7K2Q", "platform": "spotify"})
        self.assertEqual(p["credits"], [{"request_id": "claim-1", "profile_id": "abc"}])
        self.assertEqual(p["user"]["professional_id"], PRO)

    def test_only_surfaces_the_daily_check_can_read(self):
        """c1 2026-10-22: Instagram is behind a login wall, X/TikTok need a post link: never named."""
        claims = [claim(1, 7, platform="instagram"), claim(2, 8, platform="tiktok"), claim(3, 9, platform=""),
                  claim(4, 10, platform="website"), claim(5, 11, platform="youtube")]
        q = replica({c: ("pending", u) for c, u in ((1, 7), (2, 8), (3, 9), (4, 10), (5, 11))},
                    {u: f"u{u}@x.com" for u in (7, 8, 9, 10, 11)})
        rep, gate = self.go(self.lst(claims), q)
        self.assertEqual([p["claim"]["platform"] for _, p in gate.calls], ["website", "youtube"])
        self.assertEqual(rep.no_readable_surface, 3)

    def test_apply_rewrites_the_send_log_the_daily_check_reads(self):
        self._sent_note(1, 7, "a@x.com", "2026-10-24")
        db = verify_ledger.connect(self.ledger)
        asked = db.execute("SELECT created_at FROM verify_messages WHERE campaign='claim-proof-ask'").fetchone()[0]
        q = replica({}, {})
        self.go(self.lst([]), q)
        got = [json.loads(line) for line in Path(self.export).read_text().splitlines()]
        self.assertEqual(got, [{"id": 1, "profileId": "abc", "userId": "7", "askedAt": asked, "dateClose": "2026-11-07"}])
        rep, _ = self.go(self.lst([]), q, mode="dry-run")
        self.assertEqual(len(Path(self.export).read_text().splitlines()), 1)   # a dry run never rewrites it

    def test_send_log_askedat_is_the_send_time_not_a_later_tag(self):
        """The proof sweep tags a reply days later (updated_at moves): askedAt must not."""
        self._sent_note(1, 7, "a@x.com", "2026-10-24")
        db = verify_ledger.connect(self.ledger)
        asked = db.execute("SELECT created_at FROM verify_messages WHERE campaign='claim-proof-ask'").fetchone()[0]
        verify_ledger.mark_tagged(db, message_id="901", conversation_id="5", attachments=1, now=NOW + timedelta(days=3))
        self.go(self.lst([]), replica({}, {}))
        got = json.loads(Path(self.export).read_text())
        self.assertEqual(got["askedAt"], asked)

    def test_a_claim_without_a_well_formed_profile_id_is_held_never_sent(self):
        claims = [claim(1, 7, profile_id=""), claim(2, 8, profile_id="a b"), claim(3, 9)]
        claims[0].pop("profile_id")
        q = replica({c: ("pending", u) for c, u in ((1, 7), (2, 8), (3, 9))}, {u: f"u{u}@x.com" for u in (7, 8, 9)})
        rep, gate = self.go(self.lst(claims), q)
        self.assertEqual([p["credits"] for _, p in gate.calls], [[{"request_id": "claim-3", "profile_id": "abc"}]])
        self.assertEqual(rep.no_profile_id, 2)

    def test_the_replica_decides_a_claim_no_longer_pending_or_of_another_owner_is_not_sent(self):
        q = replica({1: ("processed", 7), 2: ("pending", 99)}, {7: "a@x.com", 8: "b@x.com"})
        rep, gate = self.go(self.lst([claim(1, 7), claim(2, 8), claim(3, 8)]), q)
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.not_pending, 3)   # 3 is missing from the replica (deleted): not sent

    def test_support_contacts_held_and_no_professional_id_held(self):
        q = replica({1: ("pending", 7), 2: ("pending", 8)}, {7: "a@x.com", 8: ""})
        rep, gate = self.go(self.lst([claim(1, 7), claim(2, 8)]), q, support=frozenset({"7"}))
        self.assertEqual(gate.calls, [])
        self.assertEqual((rep.support_hold, rep.no_email), (1, 1))

    def test_daily_cap_and_run_size(self):
        q = replica({c: ("pending", 100 + c) for c in range(1, 6)}, {100 + c: f"u{c}@x.com" for c in range(1, 6)})
        rep, gate = self.go(self.lst([claim(c, 100 + c) for c in range(1, 6)]), q, max_users=3)
        self.assertEqual(len(gate.calls), 3)
        self.assertEqual(rep.over_daily_max, 2)

    def test_a_later_run_reaches_new_claims_not_the_ones_already_asked(self):
        """Canary of 3, then the next day's run: the already-asked claims never take its budget."""
        claims = [claim(1, 7), claim(2, 7), claim(3, 8), claim(4, 9), claim(5, 10), claim(6, 11)]
        q = replica({c["claim_id"]: ("pending", c["user_id"]) for c in claims},
                    {u: f"u{u}@x.com" for u in (7, 8, 9, 10, 11)})
        rep, gate = self.go(self.lst(claims), q, max_users=3, gate=LedgerGate(self.ledger, "2026-10-24"))
        self.assertEqual([p["credits"][0]["request_id"] for _, p in gate.calls], ["claim-1", "claim-3", "claim-4"])
        rep, gate = self.go(self.lst(claims, gen=1 - 24, check_age=2 - 24), q, max_users=3,
                            gate=LedgerGate(self.ledger, "2026-10-25"), now=NOW + timedelta(days=1))
        self.assertEqual([p["credits"][0]["request_id"] for _, p in gate.calls], ["claim-2", "claim-5", "claim-6"])
        self.assertEqual((rep.already_asked, rep.second_claim, rep.over_daily_max), (3, 0, 0))

    def test_reminders_honour_the_segment(self):
        self._sent_note(1, 7, "u7@x.com", "2026-10-17")
        self._sent_note(2, 8, "u8@x.com", "2026-10-17")
        q = replica({1: ("pending", 7), 2: ("pending", 8)}, {7: "u7@x.com", 8: "u8@x.com"})
        claims = [claim(1, 7), claim(2, 8, paid=False)]
        for segment, want in (("paid", "claim-1"), ("free", "claim-2")):
            rep, gate = self.go(self.lst(claims), q, reminders=True, segment=segment, mode="dry-run")
            self.assertEqual([p["credits"][0]["request_id"] for _, p in gate.calls], [want], segment)

    def test_a_claimant_who_replied_is_never_reminded_and_the_reminder_is_closed(self):
        self._sent_note(1, 7, "u7@x.com", "2026-10-17")
        self._sent_note(2, 8, "u8@x.com", "2026-10-17")
        self._sent_note(3, 9, "u9@x.com", "2026-10-17")
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.mark_replied(db, message_id="901", replied_at="2026-10-18T10:00:00Z"), "recorded")
        verify_ledger.mark_tagged(db, message_id="902", conversation_id="5", attachments=1)
        for mid in ("901", "902"):
            st = verify_ledger.reminder_state(db, parent_message_id=mid, kind="reminder-7", day="2026-10-24")
            self.assertEqual(st["result"], "proof_received", mid)
        self.assertEqual(verify_ledger.reminder_state(db, parent_message_id="903", kind="reminder-7",
                                                      day="2026-10-24")["result"], "due")
        q = replica({c: ("pending", u) for c, u in ((1, 7), (2, 8), (3, 9))}, {u: f"u{u}@x.com" for u in (7, 8, 9)})
        rep, gate = self.go(self.lst([claim(1, 7), claim(2, 8), claim(3, 9)]), q, reminders=True)
        self.assertEqual([p["credits"][0]["request_id"] for _, p in gate.calls], ["claim-3"])
        self.assertEqual(rep.closed_reminders, 2)
        closed = db.execute("SELECT reason FROM verify_messages WHERE kind='reminder-7' AND status='skipped'").fetchall()
        self.assertEqual([r[0] for r in closed], ["claimant replied", "claimant replied"])
        self.assertEqual(verify_ledger.reminder_state(db, parent_message_id="901", kind="reminder-7",
                                                      day="2026-10-25")["result"], "done")

    def _sent_note(self, cid: int, uid: int, email: str, day: str) -> None:
        db = verify_ledger.connect(self.ledger)
        c = verify_ledger.claim(db, campaign="claim-proof-ask", user_key=email, day=day, request_ids=[f"claim-{cid}"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", user_id=str(uid),
                                refs=[{"request_id": f"claim-{cid}", "profile_id": "abc"}])
        self.assertEqual(c["result"], "claimed")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"90{cid}")

    def test_reminders_send_only_while_pending_and_close_when_decided_or_code_found(self):
        for cid, uid in ((1, 7), (2, 8), (3, 9), (4, 10)):
            self._sent_note(cid, uid, f"u{uid}@x.com", "2026-10-17")
        q = replica({1: ("pending", 7), 2: ("processed", 8), 3: ("pending", 9), 4: ("pending", 10)},
                    {7: "u7@x.com", 9: "u9@x.com", 10: "u10@x.com"})
        claims = [claim(1, 7), claim(3, 9, code_found=True)]   # claim 4 is not on today's list
        rep, gate = self.go(self.lst(claims), q, reminders=True)
        self.assertEqual(len(gate.calls), 1)
        argv, p = gate.calls[0]
        self.assertEqual(argv[argv.index("--kind") + 1], "reminder-7")
        self.assertEqual(argv[argv.index("--parent-message-id") + 1], "901")
        self.assertEqual(p["credits"][0]["request_id"], "claim-1")
        self.assertEqual((rep.closed_reminders, rep.not_in_list), (2, 1))
        db = verify_ledger.connect(self.ledger)
        closed = db.execute("SELECT reason FROM verify_messages WHERE kind='reminder-7' AND status='skipped' "
                            "ORDER BY reason").fetchall()
        self.assertEqual([r[0] for r in closed], ["claim processed", "code found"])

    def test_a_claim_reclassified_out_of_b_c_gets_no_reminder_and_the_reminder_is_closed(self):
        """QA on #1330: asked while B, the claim is band A (approval path) or D (a person) by day 7."""
        for cid, uid in ((1, 7), (2, 8), (3, 9)):
            self._sent_note(cid, uid, f"u{uid}@x.com", "2026-10-17")
        q = replica({1: ("pending", 7), 2: ("pending", 8), 3: ("pending", 9)},
                    {7: "u7@x.com", 8: "u8@x.com", 9: "u9@x.com"})
        claims = [claim(1, 7, band="A"), claim(2, 8, band="D"), claim(3, 9, band="C")]
        rep, gate = self.go(self.lst(claims), q, reminders=True)
        self.assertEqual([c[1]["credits"][0]["request_id"] for c in gate.calls], ["claim-3"])
        self.assertEqual(rep.closed_reminders, 2)
        db = verify_ledger.connect(self.ledger)
        closed = db.execute("SELECT reason FROM verify_messages WHERE kind='reminder-7' AND status='skipped' "
                            "ORDER BY reason").fetchall()
        self.assertEqual([r[0] for r in closed], ["band A (not B/C)", "band D (not B/C)"])

    def test_a_claim_rerouted_to_the_status_note_gets_no_proof_reminder(self):
        """QA on #1366: asked while B (readable), today's list routes it audience 'status' (still B, readable)."""
        self._sent_note(1, 7, "u7@x.com", "2026-10-17")
        q = replica({1: ("pending", 7)}, {7: "u7@x.com"})
        rep, gate = self.go(self.lst([claim(1, 7, band="B", audience="status")]), q, reminders=True)
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.closed_reminders, 1)
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(db.execute("SELECT reason FROM verify_messages WHERE kind='reminder-7' AND status='skipped'").fetchone()[0],
                         "routed to the claim-status note")

    def test_reminders_share_the_daily_max_and_read_accounts_in_one_batch(self):
        for cid, uid in ((1, 7), (2, 8), (3, 9)):
            self._sent_note(cid, uid, f"u{uid}@x.com", "2026-10-17")
        self._sent_note(4, 10, "u10@x.com", "2026-10-24")      # already one claim-proof-ask message today
        q = replica({1: ("pending", 7), 2: ("pending", 8), 3: ("pending", 9)},
                    {7: "u7@x.com", 8: "u8@x.com", 9: "u9@x.com"})
        with mock.patch.object(claim_proof_ask, "CLAIM_DAILY_MAX", 3):
            rep, gate = self.go(self.lst([claim(1, 7), claim(2, 8), claim(3, 9)]), q, reminders=True)
        self.assertEqual([p["credits"][0]["request_id"] for _, p in gate.calls], ["claim-1", "claim-2"])
        self.assertEqual(rep.over_daily_max, 1)
        self.assertEqual(q.user_reads, 1)

    def test_ledger_close_day_is_always_14_days_after_the_note(self):
        db = verify_ledger.connect(self.ledger)
        c = verify_ledger.claim(db, campaign="claim-proof-ask", user_key="a@x.com", day="2026-10-24",
                                request_ids=["claim-1"], message_type="email", approved_by="U7RP6HKUZ",
                                approval_ref="r", user_id="7")
        self.assertEqual(c["due_day"], "2026-11-07")
        self.assertEqual(db.execute("SELECT due_day FROM verify_messages WHERE id=?", (c["message_row"],)).fetchone()[0],
                         "2026-11-07")

    def test_a_tagged_claim_reply_is_never_credit_proof(self):
        """claim-proof is its own queue: it never closes or skips a retro-past or uvn-status ask."""
        self._sent_note(1, 7, "a@x.com", "2026-10-10")
        db = verify_ledger.connect(self.ledger)
        verify_ledger.mark_tagged(db, message_id="901", conversation_id="5", attachments=1)
        self.assertEqual(verify_ledger.past_user_done(db, "a@x.com", "7"), "")
        self.assertEqual(verify_ledger.uvn_user_done(db, "a@x.com", now=NOW, user_id="7"), "")
        self.assertEqual(waves.already_engaged(self.ledger)[:2], (set(), set()))
        c = verify_ledger.claim(db, campaign="status-team-review", user_key="b@x.com", day="2026-10-10", request_ids=["u1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="r", user_id="8")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="902")
        verify_ledger.mark_tagged(db, message_id="902", conversation_id="6", attachments=1)
        self.assertEqual(verify_ledger.past_user_done(db, "b@x.com", "8"), "proof_received")

    def test_a_claim_ask_is_not_an_ask_for_credits(self):
        """Its rows block only itself: a claim note never counts as a credit ask (90-day lock)."""
        self._sent_note(1, 7, "a@x.com", "2026-10-17")
        db = verify_ledger.connect(self.ledger)
        self.assertFalse(verify_ledger.asked_within(db, user_key="a@x.com", day="2026-10-24", user_id="7"))



class ClaimStatusTests(unittest.TestCase):
    """claim-status (Fable claims-documentation-readiness-1023 ruling 3): the no-ask note to every pending
    claimant who gets no proof ask. Shares the ask tests' fixtures (not their tests)."""
    setUp = ClaimProofAskTests.setUp
    tearDown = ClaimProofAskTests.tearDown
    lst = ClaimProofAskTests.lst
    go = ClaimProofAskTests.go
    _sent_note = ClaimProofAskTests._sent_note

    def status(self, path, q, **kw):
        gate = kw.pop("gate", FakeGate())
        rep = claim_proof_ask.run_status(list_path=path, segment=kw.pop("segment", "paid"), mode=kw.pop("mode", "apply"),
                                         max_users=kw.pop("max_users", 50), query=q, wrapper="/gate", runner=gate,
                                         ledger_path=self.ledger, support_contacts=kw.pop("support", frozenset()),
                                         now=kw.pop("now", NOW), **kw)
        return rep, gate

    def test_audience_holds_orgs_unreadable_and_explicit_status_rows_only(self):
        claims = [claim(1, 1, band="D"),                        # hold -> status
                  claim(2, 2, band="B", platform="instagram"),  # no readable surface -> status
                  claim(3, 3, band="B"),                        # proof ask, not status
                  claim(4, 4, band="A"),                        # approval path, neither
                  claim(5, 5, band="B", audience="status"),     # A-48h routed explicitly
                  claim(6, 6, band="D", code_found=True)]       # code found: neither
        q = replica({i: ("pending", i) for i in range(1, 7)}, {i: f"u{i}@x.com" for i in range(1, 7)})
        rep, gate = self.status(self.lst(claims), q)
        sent = sorted(c[1]["credits"][0]["request_id"] for c in gate.calls)
        self.assertEqual(sent, ["claim-1", "claim-2", "claim-5"])
        self.assertTrue(all(c[0][c[0].index("--campaign") + 1] == "claim-status" for c in gate.calls))
        self.assertEqual(gate.calls[0][1]["claim"], {"profile_name": "Big Star"})
        self.assertEqual((rep.ask_audience, rep.code_found), (2, 1))

    def test_the_ask_run_never_sends_the_proof_ask_to_a_status_row(self):
        q = replica({1: ("pending", 1), 2: ("pending", 2)}, {1: "a@x.com", 2: "b@x.com"})
        rep, gate = self.go(self.lst([claim(1, 1, audience="status"), claim(2, 2)]), q)
        self.assertEqual([c[1]["credits"][0]["request_id"] for c in gate.calls], ["claim-2"])
        self.assertEqual(rep.status_audience, 1)

    def test_status_run_needs_a_fresh_list_but_not_the_daily_code_check(self):
        q = replica({1: ("pending", 1)}, {1: "a@x.com"})
        rep, gate = self.status(self.lst([claim(1, 1, band="D")], check_owner=None), q)
        self.assertEqual(len(gate.calls), 1)
        rep, gate = self.status(self.lst([claim(1, 1, band="D")], gen=40), q)
        self.assertIn("old", rep.halted)
        self.assertEqual(len(gate.calls), 0)

    def test_a_claim_with_a_proof_ask_is_never_sent_the_status_note(self):
        self._sent_note(1, 1, "a@x.com", "2026-10-20")      # claim-1 has a claim-proof-ask note
        q = replica({1: ("pending", 1)}, {1: "a@x.com"})
        rep, gate = self.status(self.lst([claim(1, 1, band="D")]), q)
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.ask_audience, 1)

    def test_replica_support_one_per_user_and_segment(self):
        claims = [claim(1, 1, band="D"), claim(2, 1, band="D"), claim(3, 3, band="D"), claim(4, 4, band="D"),
                  claim(5, 5, band="D", paid=False)]
        q = replica({1: ("pending", 1), 2: ("pending", 1), 3: ("processed", 3), 4: ("pending", 4), 5: ("pending", 5)},
                    {1: "a@x.com", 4: "d@x.com", 5: "e@x.com"})
        rep, gate = self.status(self.lst(claims), q, support=frozenset({"4"}))
        self.assertEqual([c[1]["credits"][0]["request_id"] for c in gate.calls], ["claim-1"])
        self.assertEqual((rep.second_claim, rep.not_pending, rep.support_hold), (1, 1, 1))


class ClaimStatusCheckRecipientsTest(unittest.TestCase):
    """firstmate 103: claim-status gets the C11 send-time checks (--check-recipients / --outcomes-json), like the ask,
    and an interpolated profile name loses its markup ('lauriam<3' was refused G5)."""
    setUp = ClaimProofAskTests.setUp
    tearDown = ClaimProofAskTests.tearDown
    lst = ClaimProofAskTests.lst
    status = ClaimStatusTests.status

    def test_status_dry_run_with_check_recipients_uses_the_recipient_check(self):
        seen = []
        orig = claim_proof_ask.verify_notify.send_all

        def spy(payloads, report, **kw):
            seen.append(kw.get("check_recipients"))
        claim_proof_ask.verify_notify.send_all = spy
        try:
            q = replica({1: ("pending", 1)}, {1: "a@x.com"})
            self.status(self.lst([claim(1, 1, band="D")]), q, mode="dry-run", check_recipients=True)
            self.status(self.lst([claim(1, 1, band="D")]), q, mode="dry-run")
            self.status(self.lst([claim(1, 1, band="D")]), q, mode="apply", check_recipients=True)
        finally:
            claim_proof_ask.verify_notify.send_all = orig
        self.assertEqual(seen, [True, False, False])          # never on apply: the send itself runs the checks

    def test_status_cli_takes_the_flags_and_refuses_check_recipients_on_apply(self):
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit-review.py"), "claim-status", "--list", "/nonexistent",
                            "--segment", "paid", "--mode", "apply", "--check-recipients"], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("dry-run only", r.stdout)

    def test_status_outcomes_path_is_preflighted_before_any_send(self):
        import argparse
        import importlib.util
        spec = importlib.util.spec_from_file_location("credit_review_cli3", str(ROOT / "scripts" / "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        sent = []
        args = argparse.Namespace(outcomes_json=str(Path(tempfile.mkdtemp()) / "missing" / "o.json"), mode="apply",
                                  segment="paid", list="x", max_users=1, preview=None, check_recipients=False)
        with mock.patch.object(cli.claim_proof_ask, "run_status", lambda **kw: sent.append(kw) or None), \
                mock.patch.object(cli, "CREDIT_OPS_NOTES_KILL_SWITCH", Path("/nonexistent-kill")):
            rc = cli.cmd_claim_status(args)
        self.assertEqual((rc, sent), (2, []))

    def test_checked_dry_run_renders_the_accepted_recipients(self):
        # QA #1534: under --check-recipients the gate's accepts land in recipient_ok; the summary must count them
        for status in (True, False):
            rep = claim_proof_ask.ClaimReport(listed=3)
            rep.recipient_ok = 2
            out = claim_proof_ask.render(rep, "dry-run", "paid", status=status)
            self.assertIn("would send (recipient checked) 2", out)
            rep = claim_proof_ask.ClaimReport(listed=3)
            rep.validated = 1
            self.assertIn("would send (validated) 1", claim_proof_ask.render(rep, "dry-run", "paid", status=status))

    def test_a_checked_status_run_end_to_end_counts_the_accepted_user(self):
        from credit_review import verify_notify

        def gate(argv):
            return subprocess.CompletedProcess(argv, 0, "RECIPIENT OK credits=1\n", "")
        q = replica({1: ("pending", 1)}, {1: "a@x.com"})
        with mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, None)):
            rep, _ = self.status(self.lst([claim(1, 1, band="D")]), q, mode="dry-run", check_recipients=True, gate=gate)
        self.assertEqual(rep.recipient_ok + rep.validated, 1, vars(rep))
        self.assertIn("would send (recipient checked) 1", claim_proof_ask.render(rep, "dry-run", "paid", status=True))

    def test_display_name_strips_markup_and_hearts(self):
        d = claim_proof_ask.display_name
        self.assertEqual([d("lauriam<3"), d("A <b>bold</b> name"), d("x </3 y"), d("Tom & Jerry"), d("<3")],
                         ["lauriam", "A bold name", "x y", "Tom & Jerry", ""])

    def test_the_interpolated_name_is_the_clean_one_and_an_empty_one_is_skipped(self):
        q = replica({1: ("pending", 1), 2: ("pending", 2)}, {1: "a@x.com", 2: "b@x.com"})
        rep, gate = self.status(self.lst([claim(1, 1, band="D", profile_name="lauriam<3"),
                                          claim(2, 2, band="D", profile_name="<3")]), q)
        self.assertEqual([c[1]["claim"] for c in gate.calls], [{"profile_name": "lauriam"}])
        self.assertEqual(rep.no_profile_id, 1)
        rep, gate = ClaimProofAskTests.go(self, self.lst([claim(1, 1, profile_name="lauriam<3"),
                                                          claim(2, 2, profile_name="<3")]), q)
        self.assertEqual([c[1]["claim"]["profile_name"] for c in gate.calls], ["lauriam"])
        self.assertEqual(rep.no_profile_id, 1)


class CheckRecipientDryRunTest(unittest.TestCase):
    """C11 (p1 223): a dry run with check_recipients runs the gate's --check-recipient (every send-time check, read
    only) - also when a preview was asked for - so the dry run reports the deferrals the send would."""

    def test_the_dry_run_uses_the_recipient_check(self):
        from credit_review import verify_notify
        seen = []

        def gate(argv):
            seen.append(argv[-1])
            return type("R", (), {"returncode": 3, "stdout": "DEFERRED core_notice_within_7d credits=1 (x)\n", "stderr": ""})()
        rep = verify_notify.Report()
        p = {"user": {"id": "1382623"}, "credits": [{"request_id": "r"}]}
        with mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, None)):
            verify_notify.send_all([p], rep, mode="dry-run", runner=gate, check_recipients=True,
                                   preview_dir=tempfile.mkdtemp())
            verify_notify.send_all([p], rep, mode="dry-run", runner=gate)
        self.assertEqual(seen, ["--check-recipient", "--validate"])
        self.assertEqual(rep.deferred_users, 2)

    def test_reminders_with_check_recipients_are_refused_never_validated_offline(self):
        # QA #1516: the reminder claim path has no recipient check; the combination is rejected, in code and on the CLI
        from credit_review import claim_proof_ask
        with self.assertRaises(ValueError):
            claim_proof_ask.run(list_path="/nonexistent", segment="paid", reminders=True, check_recipients=True)
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit-review.py"), "claim-proof-ask", "--list", "/nonexistent",
                            "--segment", "paid", "--reminders", "--check-recipients"], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("first notes only", r.stdout)


class GateReasonRecordTest(unittest.TestCase):
    """C11 (p1 223): every per-user gate answer that is not a send is recorded with the user and the gate's own reason,
    and the claim report shows it (claim 1621425 was 'deferred by the gate 1' with no reason, 10-30 00:16Z)."""

    def gate(self, rc, out="", err=""):
        return lambda argv: type("R", (), {"returncode": rc, "stdout": out, "stderr": err})()

    def test_deferral_refusal_skip_and_a_silent_gate_are_all_recorded(self):
        from credit_review import claim_proof_ask, verify_notify
        rep = claim_proof_ask.ClaimReport()
        p = lambda uid: {"user": {"id": uid}, "credits": [{"request_id": "r"}]}
        cases = [(p("1382623"), self.gate(3, "DEFERRED messaged_7d credits=1 (we started a conversation with them in the last 7 days)\n")),
                 (p("2"), self.gate(1, "", "REFUSED: G5: 1 interpolated field(s) carry a link\n")),
                 (p("3"), self.gate(0, "SKIPPED already-notified credits=1\n")),
                 (p("4"), self.gate(3))]
        for payload, runner in cases:
            with mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, None)):
                verify_notify.send_all([payload], rep, mode="apply", runner=runner)
        self.assertEqual([(o["user"], o["result"]) for o in rep.outcomes],
                         [("1382623", "deferred"), ("2", "refused"), ("3", "skipped"), ("4", "deferred")])
        self.assertIn("messaged_7d", rep.outcomes[0]["reason"])
        self.assertEqual(rep.outcomes[3]["reason"], "(the gate printed no reason)")
        text = claim_proof_ask.render(rep, "apply", "paid")
        self.assertIn("user 1382623: messaged_7d credits=1 (we started a conversation with them in the last 7 days)", text)
        self.assertIn("user 4: (the gate printed no reason)", text)

    def test_the_refused_line_is_the_gates_own_and_a_pre_claim_refusal_is_named_unledgered(self):
        # r5 on #1515 (Lamberto, 10-30 01:52Z): the first stderr line was an info line; the real one came after it
        from credit_review import claim_proof_ask, verify_notify
        rep = claim_proof_ask.ClaimReport()
        p = lambda uid: {"user": {"id": uid}, "credits": [{"request_id": "r"}]}
        err = ("reply_due 56871591200: core-notice cooldown not applied to this answer\n"
               "REFUSED: G2: conversation 215473681300330 was opened by us (an admin or bot), not the customer; nothing was sent or claimed.\n")
        cases = [(p("298376"), self.gate(1, "", err)),
                 (p("5"), self.gate(1, "", "REFUSED: the rendered note contains a link; not sent.\n")),
                 (p("6"), self.gate(1, "", "Traceback (most recent call last):\n  boom\n"))]
        for payload, runner in cases:
            with mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, None)):
                verify_notify.send_all([payload], rep, mode="apply", runner=runner)
        self.assertEqual([(o["user"], o["result"]) for o in rep.outcomes],
                         [("298376", "refused_unledgered"), ("5", "refused"), ("6", "failed")])
        self.assertTrue(rep.outcomes[0]["reason"].startswith("G2: conversation 215473681300330 was opened by us"))
        self.assertEqual((rep.refused_users, rep.failed_users), (2, 1))


class GateReasonSummaryTest(unittest.TestCase):
    """QA #1515: a run with only a gate deferral still shows the reason; the outcomes file is 0600 even if it existed."""

    def test_a_lone_gate_deferral_reaches_the_summary_with_its_reason(self):
        from credit_review import verify_notify
        rep = verify_notify.Report(deferred_users=1, deferrals=["user 1621425: messaged_7d credits=1 (we started a conversation)"])
        text = rep.render("apply")
        self.assertNotEqual(text, "NO_REPLY")
        self.assertIn("1 account(s) deferred by the gate: user 1621425: messaged_7d", text)
        self.assertNotIn("already had today's note", text)
        cap = verify_notify.Report(deferred_users=1, deferrals=["user 7: daily-cap credits=1 (already had a message)"])
        self.assertEqual(cap.render("apply"), "NO_REPLY")              # the daily cap alone recurs every run: not news

    def test_the_outcomes_file_is_0600_even_when_it_already_existed(self):
        import argparse, importlib.util, os, stat
        spec = importlib.util.spec_from_file_location("credit_review_cli", str(ROOT / "scripts" / "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        out = Path(tempfile.mkdtemp()) / "o.json"
        out.write_text("old"); os.chmod(out, 0o644)
        from credit_review import verify_notify
        cli.write_outcomes(argparse.Namespace(outcomes_json=str(out), mode="dry-run", segment="paid"),
                           verify_notify.Report(outcomes=[{"user": "1", "result": "deferred", "reason": "x"}]))
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)
        self.assertEqual(json.loads(out.read_text())["outcomes"][0]["user"], "1")
        self.assertEqual([f for f in os.listdir(out.parent) if f.startswith(".outcomes-")], [])   # no temp left behind

    def cli(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("credit_review_cli2", str(ROOT / "scripts" / "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        return cli

    def test_an_unwritable_outcomes_path_stops_BEFORE_any_send(self):
        import argparse
        cli = self.cli()
        sent = []
        base = Path(tempfile.mkdtemp())
        # QA #1515: a guaranteed-missing parent (a fresh temp dir's missing child), and an existing DIRECTORY target
        for target in (base / "missing-child" / "o.json", base):
            args = argparse.Namespace(outcomes_json=str(target), mode="apply", segment="paid", list="x", max_users=1,
                                      reminders=False, preview=None, check_recipients=False)
            with mock.patch.object(cli.claim_proof_ask, "run", lambda **kw: sent.append(kw) or None), \
                    mock.patch.object(cli, "CREDIT_OPS_NOTES_KILL_SWITCH", Path("/nonexistent-kill")):
                rc = cli.cmd_claim_proof_ask(args)
            self.assertEqual((rc, sent), (2, []), target)

    def test_a_write_failure_after_the_sends_keeps_the_summary(self):
        import argparse, io, contextlib
        cli = self.cli()
        from credit_review import claim_proof_ask
        d = Path(tempfile.mkdtemp())
        args = argparse.Namespace(outcomes_json=str(d / "o.json"), mode="apply", segment="paid", list="x", max_users=1,
                                  reminders=False, preview=None, check_recipients=False)
        rep = claim_proof_ask.ClaimReport(sent_notes=2)
        buf = io.StringIO()
        with mock.patch.object(cli.claim_proof_ask, "run", lambda **kw: rep), \
                mock.patch.object(cli, "CREDIT_OPS_NOTES_KILL_SWITCH", Path("/nonexistent-kill")), \
                mock.patch.object(cli.os, "replace", side_effect=OSError("disk full")), contextlib.redirect_stdout(buf):
            rc = cli.cmd_claim_proof_ask(args)
        out = buf.getvalue()
        self.assertEqual(rc, 1)
        self.assertIn("sent 2", out)                                   # the run summary is still printed
        self.assertIn("OUTCOMES NOT WRITTEN", out)




class ScopedProofOnFileTest(unittest.TestCase):
    """Fable p1 [key=claims-scoped-pof] (10-31): the claim notes run on fresh core + cs-intercom while ONLY cs-gmail
    is stale, and hold everyone the stale part could vouch for (stale_source:cs-gmail, in the outcomes)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.pof, self.store, self.ledger = str(d / "pof.json"), str(d / "proof.sqlite"), str(d / "l.sqlite3")
        self.export = str(d / "asked.jsonl")
        db = sqlite3.connect(self.store)
        db.execute("CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, source TEXT NOT NULL)")
        db.executemany("INSERT INTO proof_intake VALUES (?,?,?)", [("a", 71, "email"), ("b", 72, "intercom")])
        db.commit()
        db.close()
        led = verify_ledger.connect(self.ledger)
        c = verify_ledger.claim(led, campaign="claim-proof-ask", user_key="x@y.com", day="2026-10-20",
                                request_ids=["claim-999"], message_type="email", approved_by="U", approval_ref="r",
                                user_id="73")
        led.execute("UPDATE verify_messages SET reason='filed from support@muso.ai', account_id='73' WHERE id=?",
                    (c["message_row"],))
        led.commit()
        led.close()

    def tearDown(self):
        self.tmp.cleanup()

    def doc(self, *, gmail=10, gmail_stale=True, intercom=0.2, intercom_stale=False, core=0.1, snap=10, snapshot=True):
        d = {"generated_at": iso(0.1), "users": 3,
             "entries": [{"user_id": 9, "request_id": None, "kind": "approved_doc", "source": "intercom"},
                         # QA #1568: an OLD gmail proof (400-day scan), absent from the 90-day snapshot and from
                         # proof_intake / the ledger
                         {"user_id": 74, "request_id": None, "kind": "approved_doc", "source": "gmail"},
                         {"user_id": 75, "request_id": "r1", "kind": "pending_doc", "source": "core.verifications.upload"}],
             "sources": [{"name": "core", "generated_at": iso(core)},
                         {"name": "cs-intercom", "generated_at": iso(intercom), "stale": intercom_stale},
                         {"name": "cs-gmail", "generated_at": iso(gmail), "stale": gmail_stale}]}
        if snapshot:
            d["gmail_contacts_90d"] = {"generated_at": iso(snap), "source": "support@", "user_ids": [70]}
        Path(self.pof).write_text(json.dumps(d))

    def holds(self):
        return claim_proof_ask.claim_holds(self.pof, now=NOW, proof_store=self.store, ledger_path=self.ledger)

    def test_all_fresh_is_the_full_check_unchanged(self):
        self.doc(gmail=0.5, gmail_stale=False, snap=0.5)
        h = self.holds()
        self.assertFalse(h.scoped)
        self.assertEqual(h.held, frozenset({"70"}))

    def test_only_gmail_stale_admits_on_core_and_intercom_and_holds_who_gmail_could_vouch_for(self):
        self.doc()
        h = self.holds()
        self.assertTrue(h.scoped)
        # 70 on the support@ snapshot, 71 filed a document from email, 73 has a ledger note naming support@;
        # 74 has an old gmail-sourced proof entry outside the snapshot (QA #1568); 72 filed through Intercom only and 9 /
        # 75 hold intercom / core entries, which the fresh parts cover: admitted
        self.assertEqual(h.held, frozenset({"70", "71", "73", "74"}))

    def test_refuse_all_when_any_other_part_is_unusable(self):
        cases = {"intercom stale": {"intercom_stale": True}, "intercom old": {"intercom": 4},
                 "core old": {"core": 4}, "no snapshot": {"snapshot": False},
                 "both stale and gmail old": {"intercom_stale": True, "gmail": 30}}
        for name, kw in cases.items():
            self.doc(**kw)
            with self.assertRaises(claim_proof_ask.verify_notify.ProofFileError, msg=name):
                self.holds()

    def test_r5_bound_last_good_scan_over_24h_holds_everyone_listed(self):
        """r5 co-sign (iii): the last good Gmail scan must be <= 24 h old; older = every claimant HELD, not admitted."""
        for kw in ({"gmail": 24.5}, {"snap": 24.5}, {"gmail": 30, "snap": 30}):
            self.doc(**kw)
            h = self.holds()
            self.assertTrue(h.scoped, kw)
            for u in ("72", "1", "999999"):
                self.assertIn(u, h.held, kw)
        self.doc(gmail=23.5, snap=23.5)
        self.assertNotIn("72", self.holds().held)              # within 24 h: the Intercom-only filer is admitted

    def test_qa_1568_scoped_mode_needs_the_gmail_PART_unusable_not_only_its_snapshot(self):
        """cs-gmail part fresh, gmail_contacts_90d alone 10 h old: the full check refuses, and scoped mode must NOT
        rescue it (a claimant who wrote to support@ after the snapshot would be missed)."""
        self.doc(gmail=0.5, gmail_stale=False, snap=10)
        with self.assertRaises(claim_proof_ask.verify_notify.ProofFileError):
            self.holds()
        self.doc(gmail=0.5, gmail_stale=False, snap=0.5)
        self.assertFalse(self.holds().scoped)                    # all fresh: the full check, unchanged

    def test_unreadable_holds_stores_refuse_all(self):
        self.doc()
        for kw in ({"proof_store": self.store + ".missing"}, {"ledger_path": self.store}):
            args = {"proof_store": self.store, "ledger_path": self.ledger, **kw}
            with self.assertRaises(claim_proof_ask.verify_notify.ProofFileError, msg=str(kw)):
                claim_proof_ask.claim_holds(self.pof, now=NOW, **args)

    def test_runner_holds_the_gmail_filer_with_the_reason_in_the_outcomes_and_sends_the_rest(self):
        self.doc()
        lst = Path(self.tmp.name) / "list.json"
        lst.write_text(json.dumps({"generated_at": iso(1), "daily_check": {"owner": "c", "last_run_at": iso(2)},
                                   "claims": [claim(1, 71), claim(2, 72)]}))
        q = replica({1: ("pending", 71), 2: ("pending", 72)}, {71: "a@x.com", 72: "b@x.com"})
        gate = FakeGate()
        with mock.patch.object(claim_proof_ask.verify_notify, "PROOF_ON_FILE", self.pof), \
                mock.patch.object(claim_proof_ask, "PROOF_STORE", self.store):
            rep = claim_proof_ask.run(list_path=str(lst), segment="paid", mode="apply", max_users=20, query=q,
                                      wrapper="/gate", runner=gate, ledger_path=self.ledger, now=NOW,
                                      export_path=self.export)
        self.assertFalse(rep.halted)
        self.assertEqual(rep.stale_source_hold, 1)
        self.assertIn({"user": "71", "result": "held", "reason": "stale_source:cs-gmail"}, rep.outcomes)
        self.assertEqual([c[1]["user"]["id"] for c in gate.calls], ["72"])
        self.assertIn("stale_source:cs-gmail", claim_proof_ask.render(rep, "apply", "paid"))

    def test_runner_with_an_old_scan_sends_nobody_and_lists_everyone(self):
        self.doc(gmail=25)
        lst = Path(self.tmp.name) / "list.json"
        lst.write_text(json.dumps({"generated_at": iso(1), "daily_check": {"owner": "c", "last_run_at": iso(2)},
                                   "claims": [claim(1, 71), claim(2, 72)]}))
        q = replica({1: ("pending", 71), 2: ("pending", 72)}, {71: "a@x.com", 72: "b@x.com"})
        gate = FakeGate()
        with mock.patch.object(claim_proof_ask.verify_notify, "PROOF_ON_FILE", self.pof), \
                mock.patch.object(claim_proof_ask, "PROOF_STORE", self.store):
            rep = claim_proof_ask.run(list_path=str(lst), segment="paid", mode="apply", max_users=20, query=q,
                                      wrapper="/gate", runner=gate, ledger_path=self.ledger, now=NOW,
                                      export_path=self.export)
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.stale_source_hold, 2)
        self.assertEqual(sorted(o["user"] for o in rep.outcomes if o["reason"] == "stale_source:cs-gmail"), ["71", "72"])

    def test_red_mutants(self):
        """The two mutants Fable named must be caught: a gmail-filed claimant admitted; both parts stale admitting."""
        self.doc()
        real = claim_proof_ask._gmail_filers
        with mock.patch.object(claim_proof_ask, "_gmail_filers", lambda p: set()):
            self.assertNotIn("71", self.holds().held)            # the mutant admits 71 ...
        self.assertIn("71", self.holds().held)                   # ... the real reader holds it
        self.assertIs(claim_proof_ask._gmail_filers, real)
        self.assertIn("74", self.holds().held)                   # QA #1568: the old gmail entry is held
        self.doc(intercom_stale=True)
        with self.assertRaises(claim_proof_ask.verify_notify.ProofFileError):
            self.holds()                                         # both stale: refuse all, never admit


if __name__ == "__main__":
    unittest.main()
