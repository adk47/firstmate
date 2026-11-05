"""The approval stamp: WHO authorized a customer note, stamped in the ledger.

Captain, 2026-11-03: "users aren't in the dark ... no human reviews is the goal". The gate
(scripts/intercom-verify-request.sh) stops requiring a live human Slack id for template classes
a Fable ruling pre-approved (policies/fable-rulings.json), so the ledger has to answer "who
authorized this send?" by itself: every claim now carries approver_kind + approval_id + the
template identity hash, and scripts/audit-approval-stamps.sh pages when a send does not.

These tests pin, in both directions where it matters:
  - a captain stamp and a ruling stamp are both written, and each is only legal in its own shape;
  - a ruling id is NOT a free pass: the copy has to be the one that ruling lists for that campaign;
  - an unreadable or malformed registry raises rather than approving everything;
  - the audit names every way a stamp can be wrong (missing kind, unknown kind, no id, id not
    matching approved_by, unknown ruling, wrong class, no template hash);
  - the registry and the picker's allow-list cannot drift apart, and the picker posts under the
    ruling id instead of an agent identity (2026-08-31 self-approval incident).
"""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import verify_ledger as vl  # noqa: E402

REGISTRY = ROOT / "policies" / "fable-rulings.json"
REPLY_REFS = ROOT / "policies" / "reply-refs.json"
CAPTAIN = "U7RP6HKUZ"
RULING = "fable-ruling-1103-103"
RULING_REFUND = "fable-ruling-1103-d2/refund-confirm"   # the driver's own id, inbox 109


def ledger() -> sqlite3.Connection:
    db = sqlite3.connect(":memory:")
    db.executescript(vl.SCHEMA)
    return db


def claim(db: sqlite3.Connection, **kw) -> dict:
    base = dict(user_key="fan@example.com", user_id="228568", day="2026-11-04", request_ids=["req-1"],
                message_type="comment", approved_by=CAPTAIN, approval_ref="test ref", campaign="reply-ref",
                copy_ref="refv", conversation="900", reply_due="901", enforce_cap=False)
    base.update(kw)
    if base["campaign"] == "reply-ref":
        # QA #1615: a reply-ref claim must name the pick the gate matched, and it must still be the latest
        vl.record_pick(db, conversation=base["conversation"], part=base["reply_due"],
                       ref="fable-copy-1031-r5/v", reason="mapped", llm_call_id="call-1")
        base["pick_id"] = str(vl.pick_for(db, conversation=base["conversation"], part=base["reply_due"])["id"])
    return vl.claim(db, **base)


class ApprovalStampShapeTests(unittest.TestCase):
    def test_absent_stamp_is_allowed_for_old_callers_but_a_half_stamp_is_not(self):
        self.assertEqual(vl.approval_stamp(), (None, None, None))
        with self.assertRaises(ValueError):
            vl.approval_stamp("", CAPTAIN)
        with self.assertRaises(ValueError):
            vl.approval_stamp("", "", "a" * 64)

    def test_captain_stamp_needs_a_human_slack_id(self):
        self.assertEqual(vl.approval_stamp(vl.APPROVER_CAPTAIN, CAPTAIN), (vl.APPROVER_CAPTAIN, CAPTAIN, None))
        for bad in ("caroline-ref-picker", "caroline", RULING, "U12", ""):
            with self.assertRaises(ValueError, msg=bad):
                vl.approval_stamp(vl.APPROVER_CAPTAIN, bad)

    def test_ruling_stamp_needs_a_ruling_id(self):
        self.assertEqual(vl.approval_stamp(vl.APPROVER_RULING, RULING)[:2], (vl.APPROVER_RULING, RULING))
        for bad in (CAPTAIN, "caroline-ref-picker", "fable-ruling-1103", "ruling-103", ""):
            with self.assertRaises(ValueError, msg=bad):
                vl.approval_stamp(vl.APPROVER_RULING, bad)

    def test_unknown_kind_and_malformed_template_hash_are_refused(self):
        with self.assertRaises(ValueError):
            vl.approval_stamp("agent", "anything")
        with self.assertRaises(ValueError):
            vl.approval_stamp(vl.APPROVER_RULING, RULING, "ABCDEF")

    def test_template_hash_is_stable_and_binds_the_rendered_template(self):
        a = vl.template_identity_sha256(campaign="reply-ref", kind="initial", copy_ref="refv", variant="")
        b = vl.template_identity_sha256(campaign="reply-ref", kind="initial", copy_ref="refv", variant="")
        self.assertEqual(a, b)
        self.assertRegex(a, r"^[0-9a-f]{64}$")
        for other in (dict(campaign="reply-ref", kind="initial", copy_ref="refw", variant=""),
                      dict(campaign="reply-ref", kind="initial", copy_ref="refv", variant="reply_due_correction"),
                      dict(campaign="status-doc-received", kind="initial", copy_ref="refv", variant="")):
            self.assertNotEqual(a, vl.template_identity_sha256(**other), other)


class ClaimStampsTheLedgerTests(unittest.TestCase):
    def row(self, db, row_id):
        return db.execute("SELECT approver_kind, approval_id, template_sha256, approved_by, copy_ref "
                          "FROM verify_messages WHERE id = ?", (row_id,)).fetchone()

    def test_a_captain_send_records_the_captain_and_the_template(self):
        db = ledger()
        sha = vl.template_identity_sha256(campaign="reply-ref", kind="initial", copy_ref="refv")
        out = claim(db, approver_kind=vl.APPROVER_CAPTAIN, approval_id=CAPTAIN, template_sha256=sha)
        self.assertEqual(out["result"], "claimed")
        self.assertEqual(self.row(db, out["message_row"]), (vl.APPROVER_CAPTAIN, CAPTAIN, sha, CAPTAIN, "refv"))

    def test_a_ruled_send_records_the_ruling_id_as_the_approver(self):
        db = ledger()
        sha = vl.template_identity_sha256(campaign="reply-ref", kind="initial", copy_ref="refv")
        out = claim(db, approved_by=RULING, approver_kind=vl.APPROVER_RULING, approval_id=RULING, template_sha256=sha)
        self.assertEqual(out["result"], "claimed")
        self.assertEqual(self.row(db, out["message_row"]), (vl.APPROVER_RULING, RULING, sha, RULING, "refv"))

    def test_a_bad_stamp_never_reaches_the_ledger(self):
        db = ledger()
        with self.assertRaises(ValueError):
            claim(db, approved_by=RULING, approver_kind=vl.APPROVER_RULING, approval_id="caroline-ref-picker")
        with self.assertRaises(ValueError):
            claim(db, approver_kind=vl.APPROVER_RULING, approval_id=RULING)  # approved_by still the captain
        self.assertEqual(db.execute("SELECT COUNT(*) FROM verify_messages").fetchone()[0], 0)


class AuditFindsEveryWayAStampCanBeWrongTests(unittest.TestCase):
    def seed(self, db, **kw) -> int:
        """A claim written by hand, so the audit — not the writer — is the thing under test."""
        base = dict(campaign="reply-ref", kind="initial", user_key="fan@example.com", day="2026-11-04",
                    status="sent", message_type="comment", request_ids_json=json.dumps(["req-1"]), n_credits=1,
                    approved_by=CAPTAIN, approval_ref="ref", created_at="2026-11-04T10:00:00Z",
                    updated_at="2026-11-04T10:00:00Z", copy_ref="refv",
                    approver_kind=vl.APPROVER_CAPTAIN, approval_id=CAPTAIN,
                    template_sha256=vl.template_identity_sha256(campaign="reply-ref", kind="initial", copy_ref="refv",
                                                                variant=""))
        base.update(kw)
        cols = ", ".join(base)
        marks = ",".join("?" * len(base))
        return int(db.execute(f"INSERT INTO verify_messages ({cols}) VALUES ({marks})",
                              tuple(base.values())).lastrowid)

    def audit(self, db) -> dict:
        return vl.audit_stamps(db, since_day="2026-11-04", registry=REGISTRY)

    def why(self, db) -> list[str]:
        return [p["why"] for p in self.audit(db)["problems"]]

    def test_the_real_registry_accepts_a_captain_send_and_a_ruled_reply_ref(self):
        db = ledger()
        self.seed(db)
        self.seed(db, approved_by=RULING, approver_kind=vl.APPROVER_RULING, approval_id=RULING)
        out = self.audit(db)
        self.assertEqual((out["checked"], out["problems"], out["ok"]), (2, [], True))

    def test_a_well_shaped_but_wrong_template_hash_is_a_finding(self):
        """QA 2026-11-04 finding 2: the digest is RECOMPUTED, so a fabricated-but-valid-looking stamp is caught. A
        missing stamp fails loud and gets fixed; a plausible wrong one makes the audit vouch for a template that never
        rendered the note."""
        db = ledger()
        self.seed(db, template_sha256="a" * 64)
        out = self.audit(db)
        self.assertEqual(len(out["problems"]), 1)
        self.assertIn("does not match the row's own identity", out["problems"][0]["why"])
        # ... and the hash of a DIFFERENT template for the same campaign does not pass either (a copy swap)
        db2 = ledger()
        self.seed(db2, template_sha256=vl.template_identity_sha256(campaign="reply-ref", kind="initial", copy_ref="refq"))
        self.assertIn("does not match the row's own identity", self.why(db2)[0])
        # a non-digest is named as such, not as a mismatch
        db3 = ledger()
        self.seed(db3, template_sha256="ff93ea31")
        self.assertIn("is not a sha256 digest", self.why(db3)[0])
        # the row's own variant is part of the identity: a note that carried an opener cannot pass as the bare template
        db4 = ledger()
        self.seed(db4, variant="c2")
        self.assertIn("does not match the row's own identity", self.why(db4)[0])

    def test_a_send_with_no_stamp_is_a_finding(self):
        # A row with no stamp whose approved_by is NOT the captain: nothing authorised it, so it is a finding.
        db = ledger()
        self.seed(db, approver_kind=None, approval_id=None, template_sha256=None, approved_by="U0SOMEONEELSE")
        self.assertEqual(len(self.audit(db)["problems"]), 1)
        self.assertIn("no approver stamp", self.why(db)[0])

    def test_a_pre_stamp_row_authorised_by_the_captain_is_history_not_a_finding(self):
        # QA 2026-11-05 / Fable r6: the stamp columns did not exist before this audit shipped, so every row written
        # before it has a NULL approver_kind. Those rows were authorised by the OLD gate, which accepted exactly one
        # approver - the captain's Slack user id. Reporting them forever made the audit page 677 false findings and
        # left hydra-approval-stamps-audit.service in systemd 'failed' every 15 minutes.
        db = ledger()
        self.seed(db, approver_kind=None, approval_id=None, template_sha256=None, approved_by=CAPTAIN,
                  created_at="2026-11-04T10:00:00Z")          # genuinely BEFORE the stamped gate went live
        self.assertEqual(self.audit(db)["problems"], [])
        # ... and it is the CAPTAIN id that makes it history, not the absence of a stamp: a pre-stamp row naming
        # anyone else is still a finding, and so is a row that names the captain but carries a WRONG stamp.
        db2 = ledger()
        self.seed(db2, approver_kind=None, approval_id=None, template_sha256=None, approved_by="U0SOMEONEELSE",
                  created_at="2026-11-04T10:00:00Z")
        self.assertIn("no approver stamp", self.why(db2)[0])
        db3 = ledger()
        self.seed(db3, approver_kind=vl.APPROVER_CAPTAIN, approval_id="U0SOMEONEELSE", approved_by=CAPTAIN)
        self.assertIn("the stamp names U0SOMEONEELSE but approved_by is", self.why(db3)[0])

    def test_an_unstamped_row_AFTER_the_cutover_is_a_finding_even_for_the_captain(self):
        # QA 2026-11-05 round 6 finding 2: the absence of a stamp is not the evidence. The stamped gate always writes
        # one, so an unstamped captain-attributed row appearing AFTER the cutover is exactly what this audit exists to
        # catch - accepting it on approved_by alone was a false green.
        db = ledger()
        self.seed(db, approver_kind=None, approval_id=None, template_sha256=None, approved_by=CAPTAIN,
                  created_at="2026-11-05T13:00:00Z")          # AFTER the stamped gate went live
        self.assertEqual(len(self.audit(db)["problems"]), 1)
        self.assertIn("not before the stamped gate went live", self.why(db)[0])
        # the boundary itself is a finding: the cutover instant is the deploy START, and a row written while the
        # deploy was still running is ambiguous, so the fail-closed answer is "finding"
        db2 = ledger()
        self.seed(db2, approver_kind=None, approval_id=None, template_sha256=None, approved_by=CAPTAIN,
                  created_at=vl.STAMP_CUTOVER)
        self.assertEqual(len(self.audit(db2)["problems"]), 1)
        # ... and a row with NO created_at at all cannot prove its provenance, so it is a finding too
        db3 = ledger()
        self.seed(db3, approver_kind=None, approval_id=None, template_sha256=None, approved_by=CAPTAIN,
                  created_at="")
        self.assertEqual(len(self.audit(db3)["problems"]), 1)

    def test_an_UNREADABLE_created_at_fails_closed(self):
        # QA 2026-11-05 round 7 follow-up: the provenance check compared created_at to the cutover as STRINGS, which is
        # a format predicate, not a time predicate. Every value below sorts BEFORE "2026-11-05T11:48:49Z"
        # lexicographically, so each was silently exempted - an unreadable value read as a pass.
        for bad in ("1793843252",                      # an epoch integer: "1" < "2"
                    "2026-11-05 11:00:00",             # space instead of T: " " < "T"
                    "2026-11-05",                      # a bare day: shorter, so it sorts first
                    "2026-11-05T11:00:00+00:00",       # an offset form the writer never emits
                    "not a date at all",
                    "2026-13-45T99:99:99Z",           # right shape, impossible values
                    # QA 2026-11-05 round 8: strptime TOLERATES a non-zero-padded value under this format, so these
                    # parsed and were exempted even after the strict parse - a value read as the writer's own when it
                    # is only something the parser accepts. The round-trip check is what makes it a finding.
                    "2026-1-5T1:2:3Z",
                    "2026-11-5T11:00:00Z",
                    "2026-11-05T1:00:00Z"):
            db = ledger()
            self.seed(db, approver_kind=None, approval_id=None, template_sha256=None, approved_by=CAPTAIN,
                      created_at=bad)
            self.assertEqual(len(self.audit(db)["problems"]), 1, f"{bad!r} was exempted")
            self.assertIn("cannot be read as", self.why(db)[0], f"{bad!r} was not named as unreadable")
        # the well-formed pre-cutover value is still history - the strict parse must not refuse the real rows
        db = ledger()
        self.seed(db, approver_kind=None, approval_id=None, template_sha256=None, approved_by=CAPTAIN,
                  created_at="2026-11-05T03:44:05Z")
        self.assertEqual(self.audit(db)["problems"], [])

    def test_a_send_before_the_cutover_day_is_history_not_a_finding(self):
        db = ledger()
        self.seed(db, day="2026-11-02", approver_kind=None, approval_id=None, template_sha256=None)
        self.assertEqual(self.audit(db)["problems"], [])

    def test_attempted_rows_count_too_so_a_held_send_cannot_hide(self):
        db = ledger()
        self.seed(db, status="attempted", approver_kind=None, approval_id=None, template_sha256=None,
                  approved_by="U0SOMEONEELSE")
        self.assertEqual(len(self.audit(db)["problems"]), 1)

    def test_refused_and_deferred_rows_are_not_sends(self):
        db = ledger()
        for status in ("refused", "deferred", "skipped"):
            self.seed(db, status=status, approver_kind=None, approval_id=None, template_sha256=None)
        self.assertEqual(self.audit(db)["problems"], [])

    def test_an_unknown_approver_kind_is_a_finding(self):
        db = ledger()
        self.seed(db, approver_kind="agent", approval_id="caroline")
        self.assertIn("unknown approver kind", self.why(db)[0])

    def test_an_agent_identity_in_the_captain_slot_is_a_finding(self):
        db = ledger()
        self.seed(db, approved_by="caroline-ref-picker", approval_id="caroline-ref-picker")
        self.assertIn("is not a Slack user id", self.why(db)[0])

    def test_a_stamp_that_disagrees_with_approved_by_is_a_finding(self):
        db = ledger()
        self.seed(db, approver_kind=vl.APPROVER_RULING, approval_id=RULING)  # approved_by still the captain
        self.assertIn("but approved_by is", self.why(db)[0])

    def test_a_ruling_that_is_not_in_the_registry_is_a_finding(self):
        db = ledger()
        self.seed(db, approved_by="fable-ruling-1103-999", approver_kind=vl.APPROVER_RULING,
                  approval_id="fable-ruling-1103-999")
        self.assertIn("is not in the registry", self.why(db)[0])

    def test_a_ruling_does_not_cover_a_copy_it_does_not_list(self):
        db = ledger()
        # ruling 103 pre-approves reply-ref refq..refy only: the /i status line is not in it
        self.seed(db, campaign="status-doc-received", copy_ref="docrecvn", approved_by=RULING,
                  approver_kind=vl.APPROVER_RULING, approval_id=RULING)
        self.assertIn("does not pre-approve copy", self.why(db)[0])

    def test_no_template_hash_is_a_finding(self):
        db = ledger()
        self.seed(db, template_sha256=None)
        self.assertIn("no template hash", self.why(db)[0])

    def test_an_unreadable_or_malformed_registry_raises_instead_of_approving(self):
        db = ledger()
        self.seed(db, approved_by=RULING, approver_kind=vl.APPROVER_RULING, approval_id=RULING)
        empty = Path(tempfile.mkdtemp(prefix="rulings-"))
        with self.assertRaises(OSError):
            vl.audit_stamps(db, since_day="2026-11-04", registry=empty / "missing.json")
        for bad in ({"rulings": []},
                    {"rulings": {"not-a-ruling": {"classes": {}}}},
                    {"rulings": {RULING: {"classes": {"no-such-campaign": ["refq"]}}}},
                    {"rulings": {RULING: {"classes": {"reply-ref": "refq"}}}}):
            path = empty / "bad.json"
            path.write_text(json.dumps(bad))
            with self.assertRaises(ValueError, msg=bad):
                vl.audit_stamps(db, since_day="2026-11-04", registry=path)


class TheRegistryCannotDriftFromTheAllowListTests(unittest.TestCase):
    def setUp(self):
        self.rulings = vl.load_rulings(REGISTRY)
        self.refs = json.loads(REPLY_REFS.read_text())["refs"]

    def test_the_shipped_registry_lists_exactly_the_approved_reply_ref_copies(self):
        listed = set(self.rulings[RULING]["classes"]["reply-ref"])
        allowed = {f"ref{v['gate_copy']}" for v in self.refs.values()
                   if v["campaign"] == "reply-ref" and v["gate_copy"] != "z"}
        self.assertEqual(listed, allowed,
                         "the ruling's class list and policies/reply-refs.json must name the same gate copies")

    def test_the_ruling_entry_names_its_source_and_sentence(self):
        entry = self.rulings[RULING]
        for key in ("date", "issued_by", "source", "sentence"):
            self.assertTrue(str(entry.get(key) or "").strip(), key)
        self.assertIn("no dates, no promises, no money", entry["sentence"])

    def test_every_class_entry_is_an_explicit_list_for_a_real_campaign(self):
        for rid, entry in self.rulings.items():
            for campaign, copies in entry["classes"].items():
                self.assertIn(campaign, vl.CAMPAIGNS, rid)
                self.assertTrue(copies, f"{rid}: {campaign} lists nothing — remove the class instead")
                self.assertNotIn("*", copies)



class RefundUnconfirmedTests(unittest.TestCase):
    """'refund issued with no confirmation > N h' (captain 2026-11-03 20:04Z; Fable d2 ruling refund-confirm-1103).
    The check reads processor facts, so the tests pin what it must refuse to guess: an unreadable feed is an outage,
    a stuck ledger claim is not a tell, and an untold refund past the threshold is always a finding."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.db = vl.connect(self.dir / "ledger.sqlite3")
        self.feed = self.dir / "refunds.jsonl"

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def _feed(self, *rows):
        self.feed.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def _told(self, refund_id, status="sent"):
        vl.claim(self.db, campaign="refund-confirm", user_key="fan@example.com", day="2026-11-03",
                 request_ids=[refund_id], message_type="email", approved_by=RULING_REFUND,
                 approval_ref="ref", copy_ref="refundconfirm", approver_kind=vl.APPROVER_RULING,
                 approval_id=RULING_REFUND, template_sha256="a" * 64)
        row = self.db.execute("SELECT id FROM verify_messages WHERE campaign='refund-confirm'").fetchone()
        if status != "attempted":
            self.db.execute("UPDATE verify_messages SET status=? WHERE id=?", (status, row[0]))
            self.db.commit()

    def test_a_refund_past_the_threshold_with_no_sent_note_is_a_finding(self):
        self._feed({"refund_id": "re_3UXkW8LsjTo3Ar3l0cunpPeE", "user_key": "a@b.c",
                    "issued_at": "2026-11-03T16:25:02Z"})
        out = vl.refund_unconfirmed(self.db, feed=self.feed, hours=24, now="2026-11-05T00:00:00Z")
        self.assertFalse(out["ok"])
        self.assertEqual([r["refund_id"] for r in out["unconfirmed"]], ["re_3UXkW8LsjTo3Ar3l0cunpPeE"])
        self.assertGreater(out["unconfirmed"][0]["age_hours"], 24)

    def test_a_sent_note_clears_it_and_a_stuck_attempt_does_not(self):
        self._feed({"refund_id": "re_3UXkW8LsjTo3Ar3l0cunpPeE", "user_key": "a@b.c",
                    "issued_at": "2026-11-03T16:25:02Z"})
        self._told("re_3UXkW8LsjTo3Ar3l0cunpPeE", status="attempted")
        self.assertFalse(vl.refund_unconfirmed(self.db, feed=self.feed, hours=24,
                                               now="2026-11-05T00:00:00Z")["ok"])
        self.db.execute("UPDATE verify_messages SET status='sent' WHERE campaign='refund-confirm'")
        self.db.commit()
        self.assertTrue(vl.refund_unconfirmed(self.db, feed=self.feed, hours=24,
                                              now="2026-11-05T00:00:00Z")["ok"])

    def test_an_unreadable_feed_raises_rather_than_reporting_clean(self):
        with self.assertRaises(OSError):
            vl.refund_unconfirmed(self.db, feed=self.dir / "absent.jsonl", hours=24)
        self.feed.write_text("nonsense\n")
        with self.assertRaises(ValueError):
            vl.refund_unconfirmed(self.db, feed=self.feed, hours=24)

    def test_a_refund_with_an_unreadable_time_is_a_finding_not_silence(self):
        self._feed({"refund_id": "re_3UXkW8LsjTo3Ar3l0cunpPeE", "user_key": "a@b.c", "issued_at": "someday"})
        out = vl.refund_unconfirmed(self.db, feed=self.feed, hours=24, now="2026-11-05T00:00:00Z")
        self.assertFalse(out["ok"])
        self.assertIn("age cannot be measured", out["unconfirmed"][0]["why"])


if __name__ == "__main__":
    unittest.main()
