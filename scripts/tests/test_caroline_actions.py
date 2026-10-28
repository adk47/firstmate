"""scripts/caroline_actions: Caroline's real, safe actions (caroline-operator-c1, 2026-10-27).

Every refusal has a test. Stdlib only; Trino, the verify ledger, proof-on-file, the account gate, the IDP
list and the admin API are faked. Nothing under /var/lib or /etc is read or written.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(SCRIPTS))
import credit_test_env  # noqa: E402,F401  (test logs never reach /var/lib)

_TMP = tempfile.mkdtemp(prefix="caroline-actions-test-")
os.environ["CAROLINE_ACTIONS_LINES_ENABLED_FILE"] = os.path.join(_TMP, "lines.enabled")
os.environ["CAROLINE_ACTIONS_KILL_SWITCH"] = os.path.join(_TMP, "disabled")

from caroline_actions import actions, copy as approved, facts as F, ledger, policy  # noqa: E402

NOW = datetime(2026, 10, 27, 17, 0, tzinfo=timezone.utc)
OLD = NOW - timedelta(days=20)
RECENT = NOW - timedelta(days=2)
TODAY = NOW - timedelta(hours=1)
NN = "Nothing else is needed"


class Gate:
    def __init__(self, decision):
        self.decision = decision


def req(rid="r1", status="unverified", title="Song A", updated=OLD, **kw):
    return F.Request(rid, status, title, updated, **kw)


def facts(**kw) -> F.Facts:
    base = dict(user_id=42, full_name="Ann Example", identity="resolved", gate="allow", idp_hold=False,
                doc_pending=False, requests=[req()])
    base.update(kw)
    return F.Facts(**base)


# ------------------------------------------------------------------------------------------- copy

class CopyParityTest(unittest.TestCase):
    """The templates are the approved campaign text in intercom-verify-request.sh, verbatim."""

    def jq_line(self, jq_def: str) -> str:
        sh = (SCRIPTS / "intercom-verify-request.sh").read_text(encoding="utf-8")
        m = re.search(r"^def " + re.escape(jq_def) + r"\(.*?\{p: \"(.*?)\"\}", sh, re.S | re.M)
        self.assertIsNotNone(m, jq_def)
        s = m.group(1)
        s = s.replace("\\($fn)", "{fn}").replace("\\(req_s($c|length))", "{req_s}")
        s = s.replace("\\(titles($c; $maxl))", "{titles}").replace("\\($c.profile_name)", "{profile_name}")
        return s

    def test_every_template_is_the_approved_text(self):
        for line_id, jq_def in approved.JQ_DEFS.items():
            self.assertEqual(approved.TEMPLATES[line_id], self.jq_line(jq_def), line_id)

    def test_render_matches_the_gate_rules(self):
        self.assertEqual(approved.titles(["A"]), '"A"')
        self.assertEqual(approved.titles(["A", "B"]), '"A" and "B"')
        self.assertEqual(approved.titles(["A", "B", "C", "D", "E"]), '"A", "B" and "C" and 2 more')
        self.assertEqual(approved.titles(["“Q”"]), "“Q”")
        self.assertEqual(approved.first_name("Ann Example"), "Ann")
        for bad in ("", None, "dj_k1d", "4ever Young", "@ann"):
            self.assertEqual(approved.first_name(bad), "there", bad)
        line = approved.render("status-team-review", full_name="Ann Example", track_titles=["A", "B"])
        self.assertEqual(line, 'Hi Ann, a quick update on your credit requests for "A" and "B": they\'re with our team '
                               'for review. Nothing else is needed from you right now.')

    def test_no_half_lines(self):
        with self.assertRaises(ValueError):
            approved.render("status-team-review", full_name="Ann", track_titles=[])
        with self.assertRaises(ValueError):
            approved.render("claim-status", full_name="Ann", profile_name=" ")
        with self.assertRaises(ValueError):
            approved.render("merge-pending", full_name="Ann")


# ------------------------------------------------------------------------------------------- policy

class StatusPolicyTest(unittest.TestCase):
    def refusals(self, f, topic="credit"):
        return policy.decide_status(f, NOW, topic=topic).refusals

    def test_waiting_on_us_gets_team_review(self):
        d = policy.decide_status(facts(), NOW)
        self.assertEqual((d.refusals, d.line_id), ([], "status-team-review"))
        self.assertIn('"Song A"', d.reply_line)
        self.assertEqual(d.request_ids, ["r1"])

    def test_a_document_awaiting_review_gets_doc_received(self):
        d = policy.decide_status(facts(doc_pending=True), NOW)
        self.assertEqual(d.line_id, "status-doc-received")

    def test_identity_unverified(self):
        for ident in ("no_account", "ambiguous", "unconfirmed", "bad_email", "unresolved"):
            self.assertEqual(self.refusals(facts(identity=ident)), ["identity_unverified"], ident)

    def test_facts_unknown(self):
        for kw in ({"unknown": ["core: FactsError"]}, {"gate": "unknown"}, {"idp_hold": None}, {"doc_pending": None}):
            self.assertIn("facts_unknown", self.refusals(facts(**kw)), kw)

    def test_owes_proof_uvn_row(self):
        f = facts(requests=[req("a"), req("b", "user_verification_needed")])
        self.assertIn("owes_proof", self.refusals(f))

    def test_owes_proof_idp_review_row(self):
        self.assertIn("owes_proof", self.refusals(facts(requests=[req(review_hold=True)])))

    def test_owes_proof_idp_review_row_on_every_open_status_through_both_line_paths(self):
        for st in ("pending", "processing", "unverified"):
            f = facts(requests=[req(status=st, review_hold=True)], doc_pending=True)
            d = policy.decide_status(f, NOW)
            self.assertIn("owes_proof", d.refusals, st)
            self.assertIsNone(d.reply_line, st)
            dd = policy.decide_doc_reply(f, NOW, subject="credit")
            self.assertIn("owes_proof", dd.refusals, st)
            self.assertIsNone(dd.reply_line, st)
        closed = facts(requests=[req(), req("x", "approved", review_hold=True)])
        self.assertNotIn("owes_proof", self.refusals(closed))   # a decided row owes nothing

    def test_owes_proof_idp_list_hold(self):
        self.assertIn("owes_proof", self.refusals(facts(idp_hold=True)))

    def test_account_hold(self):
        self.assertIn("account_hold", self.refusals(facts(gate="hold")))

    def test_status_note_hold(self):
        self.assertIn("status_note_hold", self.refusals(facts(status_note_hold=True)))

    def test_support_contact_held(self):
        self.assertIn("support_contact_held", self.refusals(facts(support_contact=True)))

    def test_core_notice_within_7d_each_marker(self):
        for kw in ({"proof_notice_at": RECENT}, {"info_request_at": RECENT}, {"approved_notice_at": RECENT}):
            f = facts(requests=[req(), req("x", "approved", **kw)])
            self.assertIn("core_notice_within_7d", self.refusals(f), kw)
        f = facts(claims=[F.Claim("c1", "rejected", "p", RECENT)])
        self.assertIn("core_notice_within_7d", self.refusals(f))

    def test_markers_older_than_7d_do_not_refuse(self):
        f = facts(requests=[req(proof_notice_at=OLD, approved_notice_at=OLD)])
        self.assertEqual(self.refusals(f), [])

    def test_status_changed_today(self):
        self.assertIn("status_changed_today", self.refusals(facts(requests=[req(updated=TODAY)])))

    def test_hydra_note_within_7d(self):
        self.assertIn("hydra_note_within_7d", self.refusals(facts(last_hydra_note_at=RECENT)))
        self.assertEqual(self.refusals(facts(last_hydra_note_at=OLD)), [])

    def test_caroline_line_within_7d(self):
        self.assertIn("caroline_line_within_7d", self.refusals(facts(last_caroline_line_at=RECENT)))

    def test_decided_not_closed(self):
        self.assertIn("decided_not_closed", self.refusals(facts(requests=[req(reject_rule=True)])))

    def test_nothing_pending(self):
        self.assertIn("nothing_pending", self.refusals(facts(requests=[req(status="approved")])))

    def test_no_titles(self):
        self.assertIn("no_titles", self.refusals(facts(requests=[req(title=" ")])))

    def test_unsupported_topic(self):
        self.assertEqual(self.refusals(facts(), topic="merge"), ["unsupported_topic"])

    def test_never_nothing_else_is_needed_to_anyone_who_owes_proof(self):
        """Exhaustive over the owe-proof causes x every other flag: no line, ever."""
        owe = [{"requests": [req("u", "user_verification_needed")]}, {"requests": [req(review_hold=True)]},
               {"idp_hold": True}, {"gate": "hold"}]
        others = [{}, {"doc_pending": True}, {"claims": [F.Claim("c", "pending", "p", OLD, True)],
                                               "profile_names": {"p": "Prof"}}]
        for o in owe:
            for x in others:
                f = facts(**{**x, **o})
                for topic in ("credit", "claim"):
                    d = policy.decide_status(f, NOW, topic=topic)
                    self.assertIsNone(d.reply_line, (o, x, topic))
                    for subject in ("credit", "claim"):
                        dd = policy.decide_doc_reply(f, NOW, subject=subject)
                        self.assertIsNone(dd.reply_line, (o, x, subject))


class ClaimPolicyTest(unittest.TestCase):
    def claim_facts(self, **kw):
        base = dict(requests=[], claims=[F.Claim("c1", "pending", "p1", OLD, True)], profile_names={"p1": "DJ Ann"})
        base.update(kw)
        return facts(**base)

    def test_pending_claim_with_links_gets_claim_status(self):
        d = policy.decide_status(self.claim_facts(), NOW, topic="claim")
        self.assertEqual(d.line_id, "claim-status")
        self.assertIn("your claim on DJ Ann", d.reply_line)

    def test_claim_without_links_owes_proof(self):
        f = self.claim_facts(claims=[F.Claim("c1", "pending", "p1", OLD, False)])
        self.assertIn("owes_proof", policy.decide_status(f, NOW, topic="claim").refusals)

    def test_a_filed_document_never_clears_owes_proof(self):
        """Fable #1402: a filed document is not an accepted one. Filing never earns the line."""
        f = self.claim_facts(claims=[F.Claim("c1", "pending", "p1", OLD, False)])
        d = policy.decide_doc_reply(f, NOW, subject="claim")
        self.assertIsNone(d.reply_line)
        self.assertIn("owes_proof", d.refusals)
        for owe in ({"requests": [req("u", "user_verification_needed")]}, {"requests": [req(review_hold=True)]},
                    {"idp_hold": True}):
            dd = policy.decide_doc_reply(facts(**owe), NOW, subject="credit")
            self.assertIsNone(dd.reply_line, owe)
            self.assertIn("owes_proof", dd.refusals, owe)

    def test_no_profile_name(self):
        self.assertIn("no_profile_name", policy.decide_status(self.claim_facts(profile_names={}), NOW, topic="claim").refusals)

    def test_multiple_pending_claims(self):
        f = self.claim_facts(claims=[F.Claim("c1", "pending", "p1", OLD, True), F.Claim("c2", "pending", "p2", OLD, True)])
        self.assertIn("multiple_pending_claims", policy.decide_status(f, NOW, topic="claim").refusals)

    def test_no_pending_claim(self):
        self.assertIn("nothing_pending", policy.decide_status(self.claim_facts(claims=[]), NOW, topic="claim").refusals)


# ------------------------------------------------------------------------------------------- actions

class ActionsBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = ledger.connect(os.path.join(self.tmp.name, "ledger.sqlite3"))
        self.f = facts()
        lines = os.environ["CAROLINE_ACTIONS_LINES_ENABLED_FILE"]
        if os.path.exists(lines):
            os.remove(lines)

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def load(self, email):
        self.f.last_caroline_line_at = ledger.last_line_at(self.db, self.f.user_id) if self.f.user_id else None
        return self.f

    def unlock(self):
        Path(os.environ["CAROLINE_ACTIONS_LINES_ENABLED_FILE"]).write_text("")

    def rows(self, table="actions"):
        return self.db.execute(f"SELECT * FROM {table} ORDER BY id").fetchall()


class StatusActionTest(ActionsBase):
    def test_locked_lines_are_withheld_and_ledgered(self):
        out = actions.status(self.db, email="ann@example.com", conv="215476000000001", topic="credit", load=self.load,
                             now=NOW)
        self.assertEqual((out["outcome"], out["reply_line"], out["lines_locked"]), ("line_withheld_locked", None, True))
        self.assertEqual(out["line_id"], "status-team-review")
        [r] = self.rows()
        self.assertEqual((r["verb"], r["outcome"], r["user_id"]), ("status", "line_withheld_locked", 42))
        self.assertNotIn("ann@example.com", json.dumps(dict(r)))

    def test_unlocked_line_is_offered_once_then_the_7_day_rule_holds(self):
        self.unlock()
        first = actions.status(self.db, email="ann@example.com", conv="215476000000001", topic="credit", load=self.load,
                               now=NOW)
        self.assertEqual(first["outcome"], "line_offered")
        self.assertTrue(first["reply_line"].startswith("Hi Ann, a quick update"))
        second = actions.status(self.db, email="ann@example.com", conv="215476000000002", topic="credit",
                                load=self.load, now=NOW + timedelta(minutes=5))
        self.assertEqual((second["outcome"], second["reply_line"]), ("refused", None))
        self.assertIn("caroline_line_within_7d", second["refusals"])
        self.assertEqual(len(self.rows()), 2)

    def test_a_refusal_never_carries_a_line(self):
        self.unlock()
        self.f = facts(requests=[req(status="user_verification_needed")])
        out = actions.status(self.db, email="ann@example.com", conv="215476000000001", topic="credit", load=self.load,
                             now=NOW)
        self.assertEqual((out["outcome"], out["reply_line"], out["line_id"]), ("refused", None, None))


class DocIntakeTest(ActionsBase):
    def setUp(self):
        super().setUp()
        self.root = os.path.join(self.tmp.name, "intercom")
        self.conv = "215476577497353"
        d = os.path.join(self.root, self.conv, "notif_x")
        os.makedirs(d)
        Path(d, "0.png").write_bytes(b"\x89PNG-proof")
        Path(d, "1.pdf").write_bytes(b"%PDF-invoice")
        Path(d, "1-p-1.png").write_bytes(b"render")      # a PDF page render: never an original
        Path(d, "notes.txt").write_bytes(b"x")

    def intake(self, subject="credit", conv=None, now=NOW):
        return actions.doc_intake(self.db, email="ann@example.com", conv=conv or self.conv, subject=subject,
                                  load=self.load, root=self.root, now=now)

    def test_files_every_original_with_user_and_request_ids_and_sha256(self):
        out = self.intake()
        self.assertEqual((out["filed"], out["already_filed"]), (2, 0))
        rows = self.rows("doc_intake")
        self.assertEqual(sorted(os.path.basename(r["path"]) for r in rows), ["0.png", "1.pdf"])
        for r in rows:
            self.assertEqual((r["user_id"], json.loads(r["request_ids_json"]), r["subject"]), (42, ["r1"], "credit"))
            self.assertRegex(r["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(out["line_id"], "status-doc-received")   # computed; withheld while locked
        self.assertIsNone(out["reply_line"])
        self.assertEqual(ledger.queued_docs(os.path.join(self.tmp.name, "ledger.sqlite3"), now=NOW),
                         {self.conv: sorted(r["path"] for r in rows)})

    def test_refiling_the_same_file_is_idempotent(self):
        self.intake()
        out = self.intake(now=NOW + timedelta(minutes=1))
        self.assertEqual((out["filed"], out["already_filed"]), (0, 2))
        self.assertEqual(len(self.rows("doc_intake")), 2)

    def test_owes_proof_still_files_but_gives_no_line(self):
        self.unlock()
        self.f = facts(requests=[req(status="user_verification_needed")])
        out = self.intake()
        self.assertEqual(out["filed"], 2)
        self.assertIsNone(out["reply_line"])
        self.assertIn("owes_proof", out["refusals"])

    def test_claim_subject_carries_the_claim_ids(self):
        self.f = facts(requests=[], claims=[F.Claim("c9", "pending", "p1", OLD, False)], profile_names={"p1": "P"})
        self.intake(subject="claim")
        self.assertEqual({json.loads(r["claim_ids_json"])[0] for r in self.rows("doc_intake")}, {"c9"})

    def test_refusals(self):
        self.assertEqual(self.intake(subject="merge")["refusals"], ["unsupported_subject"])
        self.assertIn("no_conversation", self.intake(conv="../etc")["refusals"])
        self.assertIn("no_cached_attachment", self.intake(conv="215476000000999")["refusals"])
        self.f = facts(identity="no_account", user_id=None)
        self.assertIn("identity_unverified", self.intake()["refusals"])
        self.assertEqual(self.rows("doc_intake"), [])

    def test_a_symlink_out_of_the_conversation_is_never_filed(self):
        secret = Path(self.tmp.name, "secret.png")
        secret.write_bytes(b"\x89PNG-secret")
        os.symlink(secret, os.path.join(self.root, self.conv, "notif_x", "5.png"))
        self.intake()
        self.assertNotIn("5.png", [os.path.basename(r["path"]) for r in self.rows("doc_intake")])


class MergeIntakeTest(ActionsBase):
    KEEP = "c3c4d0d9-9f4f-4e69-a4a2-4751ca57d6b2"
    DUP = "cb464ea4-0317-484b-b672-775ba67c4aaa"

    def intake(self, **kw):
        args = dict(email="ann@example.com", conv="215476575071794", kind="profile-merge", keep=self.KEEP,
                    others=[self.DUP], load=self.load, now=NOW)
        args.update(kw)
        return actions.merge_intake(self.db, **args)

    def test_files_then_records_the_ticket_and_never_executes(self):
        out = self.intake()
        self.assertEqual((out["refusals"], out["next"], out["reply_line"]), ([], "file_ticket", None))
        rec = actions.merge_record(self.db, email="ann@example.com", conv="215476575071794", row=out["merge_row"],
                                   ticket_id="86abc", ok=True, now=NOW)
        self.assertTrue(rec["recorded"])
        again = self.intake(now=NOW + timedelta(days=1))
        self.assertIn("already_filed_within_7d", again["refusals"])
        self.assertEqual(again["ticket_id"], "86abc")
        later = self.intake(now=NOW + timedelta(days=8))
        self.assertEqual(later["refusals"], [])

    def test_refusals(self):
        self.assertIn("unsupported_kind", self.intake(kind="profile-delete")["refusals"])
        self.assertIn("missing_profiles", self.intake(others=[])["refusals"])
        self.assertIn("keep_in_others", self.intake(others=[self.KEEP])["refusals"])
        self.assertIn("not_profile_ids", self.intake(others=["https://muso.ai/x"])["refusals"])
        self.assertIn("too_many_profiles", self.intake(others=[self.DUP[:-3] + f"{i:03d}" for i in range(6)])["refusals"])
        self.f = facts(identity="ambiguous", user_id=None)
        self.assertIn("identity_unverified", self.intake()["refusals"])
        self.assertEqual(self.rows("merge_intake"), [])

    def test_a_request_in_flight_blocks_a_second_filing_until_the_7_days_end(self):
        """Fable #1402: a to_file row may already have a ticket (record step failed). It never expires early."""
        first = self.intake()
        self.assertEqual(first["refusals"], [])
        for later in (timedelta(minutes=2), timedelta(hours=1), timedelta(days=6)):
            self.assertEqual(self.intake(now=NOW + later)["refusals"], ["merge_in_flight"], later)
        self.assertEqual(len(self.rows("merge_intake")), 1)
        self.assertEqual(self.intake(now=NOW + timedelta(days=8))["refusals"], [])

    def test_ticket_filed_record_failed_second_call_does_not_file_again(self):
        first = self.intake()              # row opened; the plugin files the ticket; the record step dies
        again = self.intake(now=NOW + timedelta(hours=3))
        self.assertEqual(again["refusals"], ["merge_in_flight"])
        self.assertNotIn("merge_row", again)

    def test_the_record_step_is_retry_safe_and_never_downgrades_a_filed_row(self):
        row = self.intake()["merge_row"]
        rec = lambda **kw: actions.merge_record(self.db, email="a@b.co", conv="215476575071794", row=row, now=NOW, **kw)  # noqa: E731
        self.assertTrue(rec(ticket_id="86abc", ok=True)["recorded"])
        self.assertTrue(rec(ticket_id="86abc", ok=True)["recorded"])          # a lost answer, retried
        self.assertFalse(rec(ticket_id="86zzz", ok=True)["recorded"])         # another id never overwrites
        self.assertFalse(rec(ticket_id=None, ok=False)["recorded"])           # never downgraded to failed
        [r] = self.rows("merge_intake")
        self.assertEqual((r["status"], r["ticket_id"]), ("filed", "86abc"))

    def test_a_failed_filing_can_be_retried(self):
        row = self.intake()["merge_row"]
        actions.merge_record(self.db, email="a@b.co", conv="215476575071794", row=row, ticket_id=None, ok=False, now=NOW)
        self.assertEqual(self.intake(now=NOW + timedelta(minutes=1))["refusals"], [])

    def test_recording_an_unknown_or_closed_row_is_refused(self):
        rec = actions.merge_record(self.db, email="a@b.co", conv="215476575071794", row=999, ticket_id="x", ok=True,
                                   now=NOW)
        self.assertEqual(rec["refusals"], ["unknown_or_closed_row"])


class RaceTest(unittest.TestCase):
    """Each dedupe is a check-and-write under ONE write lock: N concurrent callers on N connections
    to the same ledger produce exactly one winner (Fable #1402, the ledger dedupe race)."""

    N = 8

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "ledger.sqlite3")
        ledger.connect(self.path).close()

    def tearDown(self):
        self.tmp.cleanup()

    def race(self, fn):
        import threading
        barrier = threading.Barrier(self.N)
        results, errors = [], []

        def worker():
            db = ledger.connect(self.path)
            try:
                barrier.wait()
                results.append(fn(db))
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)
            finally:
                db.close()
        ts = [threading.Thread(target=worker) for _ in range(self.N)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(errors, [])
        return results

    def test_one_merge_filing_wins(self):
        res = self.race(lambda db: ledger.merge_claim(db, conv_id="1", user_id=42, kind="profile-merge", keep="k",
                                                      others=["o"], now=NOW))
        self.assertEqual(sum(1 for row, _ in res if row is not None), 1)
        self.assertEqual({e for row, e in res if row is None}, {"in_flight"})

    def test_one_handoff_wins(self):
        res = self.race(lambda db: ledger.handoff_claim(db, conv_id="1", user_id=42, reason="dispute", request_ids=[],
                                                        claim_ids=[], summary="", now=NOW))
        self.assertEqual(sum(1 for r in res if r is not None), 1)

    def test_one_line_offer_wins(self):
        res = self.race(lambda db: ledger.offer_line(db, user_id=42, now=NOW, verb="status", conv_id="1",
                                                     email="a@b.co", line_id="status-team-review"))
        self.assertEqual(sum(1 for r in res if r is not None), 1)
        db = ledger.connect(self.path)
        self.assertEqual(db.execute("SELECT count(*) FROM actions WHERE outcome='line_offered'").fetchone()[0], 1)
        db.close()


class HandoffTest(ActionsBase):
    def test_hands_off_once_per_reason_and_redacts_emails(self):
        out = actions.handoff(self.db, email="ann@example.com", conv="215476395844364", reason="dispute",
                              summary="user ann@example.com says the credit is not hers", load=self.load, now=NOW)
        self.assertEqual((out["outcome"], out["refusals"]), ("handed_off", []))
        [h] = self.rows("handoffs")
        self.assertNotIn("@", h["summary"])
        again = actions.handoff(self.db, email="ann@example.com", conv="215476395844364", reason="dispute", summary="",
                                load=self.load, now=NOW + timedelta(hours=1))
        self.assertEqual(again["refusals"], ["already_handed_off_within_7d"])
        snap = ledger.board_snapshot(self.db, now=NOW)
        self.assertEqual((snap["counts"], snap["handoffs"][0]["request_ids"]), ({"dispute": 1}, ["r1"]))

    def test_refusals(self):
        out = actions.handoff(self.db, email="a@b.co", conv="215476395844364", reason="approve_it", summary="",
                              load=self.load, now=NOW)
        self.assertEqual(out["refusals"], ["unsupported_reason"])
        out = actions.handoff(self.db, email="a@b.co", conv="", reason="dispute", summary="", load=self.load, now=NOW)
        self.assertIn("no_conversation", out["refusals"])

    def test_works_without_a_resolved_identity(self):
        self.f = facts(identity="no_account", user_id=None, requests=[])
        out = actions.handoff(self.db, email="a@b.co", conv="215476395844364", reason="facts_unknown", summary="",
                              load=self.load, now=NOW)
        self.assertEqual(out["refusals"], [])


# ------------------------------------------------------------------------------------------- facts

class FakeTrino:
    def __init__(self, users, requests=(), claims=(), merges=(), fail=False):
        self.users, self.requests, self.claims, self.merges, self.fail = users, requests, claims, merges, fail
        self.sql: list[str] = []

    def __call__(self, sql):
        self.sql.append(sql)
        if self.fail:
            raise F.FactsError("down")
        if "public.users" in sql:
            return [list(u) for u in self.users]
        if "credit_requests" in sql:
            return [list(r) for r in self.requests]
        if "profile_merges" in sql:
            return [list(m) for m in self.merges]
        return [list(c) for c in self.claims]


class POF(dict):
    support_contacts = frozenset()


class FactsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vl = os.path.join(self.tmp.name, "ledger.sqlite3")
        db = sqlite3.connect(self.vl)
        db.executescript("CREATE TABLE verify_messages (campaign TEXT, user_key TEXT, account_id TEXT, status TEXT, "
                         "sent_at TEXT, created_at TEXT);"
                         "CREATE TABLE verify_refusal_holds (campaign TEXT, user_key TEXT, user_id TEXT, flagged_at TEXT);")
        db.execute("INSERT INTO verify_messages VALUES ('claim-status', 'ann@example.com', '42', 'sent', ?, ?)",
                   ("2026-10-25T01:00:00Z", "2026-10-25T01:00:00Z"))
        db.execute("INSERT INTO verify_refusal_holds VALUES ('status-team-review', 'user:42', '42', '2026-10-27T09:00:00Z')")
        db.commit()
        db.close()

    def tearDown(self):
        self.tmp.cleanup()

    def load(self, trino, **kw):
        args = dict(run=trino, verify_ledger=self.vl, proof_loader=lambda: POF({"42": [(None, "pending_doc")]}),
                    gate=lambda uid: Gate("allow"), idp_ids=lambda: {"7"})
        args.update(kw)
        return F.load("Ann@Example.com", **args)

    def test_reads_every_source(self):
        t = FakeTrino([("42", "Ann Example", "true")],
                      [("r1", "unverified", "Song A", "2026-10-20T10:00:00.000Z", "2026-10-26T10:00:00Z", "", "",
                        "true", "false")],
                      [("9", "pending", "p1", "2026-10-01T00:00:00Z", "true")],
                      [("m1", "callback_received", "p1", "p2", "2026-10-26T00:00:00Z")])
        f = self.load(t)
        self.assertEqual((f.identity, f.user_id, f.unknown), ("resolved", 42, []))
        self.assertTrue(f.requests[0].review_hold and f.requests[0].proof_notice_at)
        self.assertEqual((f.claims[0].has_links, f.merges[0].status), (True, "callback_received"))
        self.assertTrue(f.status_note_hold)
        self.assertEqual(f.last_hydra_note_at, datetime(2026, 10, 25, 1, tzinfo=timezone.utc))
        self.assertEqual((f.doc_pending, f.gate, f.idp_hold), (True, "allow", False))
        self.assertIn("lower(email) = 'ann@example.com'", t.sql[0])

    def test_identity_outcomes(self):
        self.assertEqual(self.load(FakeTrino([])).identity, "no_account")
        self.assertEqual(self.load(FakeTrino([("1", "a", "true"), ("2", "b", "true")])).identity, "ambiguous")
        self.assertEqual(self.load(FakeTrino([("1", "a", "false")])).identity, "unconfirmed")
        f = F.load("x' OR '1'='1@a.com", run=FakeTrino([("1", "a", "true")]))
        self.assertEqual(f.identity, "bad_email")

    def test_quotes_in_an_email_are_escaped(self):
        self.assertIn("o''neil@example.com", F.q_user("O'Neil@example.com"))

    def test_any_source_failure_is_unknown_never_empty(self):
        f = self.load(FakeTrino([], fail=True))
        self.assertEqual(f.unknown, ["core: FactsError"])
        self.assertIn("facts_unknown", policy.common_refusals(f, NOW) + ["facts_unknown"])

        def boom(*_a, **_k):
            raise OSError("x")
        t = FakeTrino([("42", "Ann", "true")])
        f = self.load(t, proof_loader=boom, gate=boom, idp_ids=boom, verify_ledger="/nonexistent/x.sqlite3")
        self.assertEqual(sorted(u.split(":")[0] for u in f.unknown), ["account_holds", "idp_hold", "proof_on_file",
                                                                      "verify_ledger"])
        self.assertIsNone(f.doc_pending)
        self.assertIsNone(f.idp_hold)
        self.assertIn("facts_unknown", policy.common_refusals(f, NOW))

    def test_the_idp_hold_list_marks_the_account(self):
        f = self.load(FakeTrino([("42", "Ann", "true")]), idp_ids=lambda: {"42", "7"})
        self.assertTrue(f.idp_hold)


# ------------------------------------------------------------------------------------------- invariants

class HoldSetTest(unittest.TestCase):
    def test_the_published_hold_set_is_read_never_the_gate_run(self):
        import time as _t
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "account_holds.jsonl")
            Path(p).write_text('{"user_id": "42", "kind": "approval_hold"}\n{"user_id": "7"}\n')
            self.assertEqual((F.account_hold_state(42, p), F.account_hold_state(43, p)), ("hold", "allow"))
            old = _t.time() - 80 * 3600
            os.utime(p, (old, old))
            with self.assertRaises(F.FactsError):
                F.account_hold_state(43, p)                  # stale -> unknown, never "allow"
        src = (SCRIPTS / "caroline_actions" / "facts.py").read_text(encoding="utf-8")
        self.assertNotIn("from credit_review import account_gate", src)


class NoWritePathTest(unittest.TestCase):
    """Never approve, reject, delete or hide: the package has no write path to core and runs nothing."""

    def test_no_core_write_and_no_shell(self):
        pkg = SCRIPTS / "caroline_actions"
        for p in pkg.glob("*.py"):
            src = p.read_text(encoding="utf-8")
            for bad in ("muso-admin-api", "credits verify", "profiles merge", "profiles consolidate", "claim-self",
                        "method=\"PUT\"", "method=\"DELETE\"", "method=\"POST\"", "/approve"):
                self.assertNotIn(bad, src, f"{p.name}: {bad}")
            if p.name != "facts.py":
                self.assertNotIn("subprocess", src, p.name)

    def test_the_cli_verbs_are_exactly_these(self):
        src = (SCRIPTS / "caroline-actions.py").read_text(encoding="utf-8")
        verbs = set(re.findall(r'sub\.add_parser\("([a-z-]+)"', src))
        self.assertEqual(verbs, {"status", "doc-intake", "merge-intake", "merge-record", "handoff", "board-export"})

    def test_kill_switch(self):
        import subprocess
        ks = os.environ["CAROLINE_ACTIONS_KILL_SWITCH"]
        Path(ks).write_text("")
        try:
            p = subprocess.run([sys.executable, str(SCRIPTS / "caroline-actions.py"), "--ledger",
                                os.path.join(_TMP, "never.sqlite3"), "status", "--email", "a@b.co", "--conv", "1"],
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(json.loads(p.stdout)["disabled"], True)
            self.assertFalse(os.path.exists(os.path.join(_TMP, "never.sqlite3")))
        finally:
            os.remove(ks)


if __name__ == "__main__":
    unittest.main()
