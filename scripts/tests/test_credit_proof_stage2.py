#!/usr/bin/env python3
"""Tests for stage 2 SHADOW (scripts/credit_verify/proof/stage2.py): judge the
documents already on file for the decider's "proof on file" holds. Synthetic
data only; every input (decider ledger, Trino, Intercom, downloads) is faked.

    python3 scripts/tests/test_credit_proof_stage2.py
"""

from __future__ import annotations

import io
import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_verify.proof import FORENSICS_VERSION, analyze, ocr, pdf_forensics, stage2, verdict  # noqa: E402
from credit_verify.proof.pipeline import analyze_against, analyze_proof  # noqa: E402
from credit_verify.proof.pipeline import ProofResult  # noqa: E402
from credit_verify.proof.signals import MISMATCH, SOFT, ClaimContext, Signal  # noqa: E402
from credit_verify.proof.store import ProofStore  # noqa: E402
from test_credit_proof import COWRITE, FakeOcr, pdf_bytes, png_bytes, words_for  # noqa: E402

HAVE_PDF = pdf_forensics.available()


def ctx(title: str, track: str, rid: str, isrc: str | None = "USABC2400001", role: str = "Songwriter",
        names=("Ann Alpha",)) -> ClaimContext:
    return ClaimContext(request_ids=[f"{rid}#{role}"], claimed_roles=[role], track_title=title,
                        track_artists=["Small Act"], isrcs=[isrc] if isrc else [], claimant_names=list(names),
                        track_key=track)


def multi_runner(p, d, c, cs):
    return analyze.extract(p, d, ClaimContext.from_dict(c), [ClaimContext.from_dict(x) for x in cs])


def online_edited(text: str) -> bytes:
    """A sheet saved through an online PDF editor (F4a online_editor_producer)."""
    doc = pdf_forensics.pymupdf.open(stream=pdf_bytes(text), filetype="pdf")
    doc.set_metadata({"producer": "iLovePDF"})
    out = doc.tobytes()
    doc.close()
    return out


def ocr_by_size(texts: dict[str, str]):
    """OCR that shows `texts["image"]` on a screenshot and `texts["pdf"]` on
    a rendered PDF page (rendered at 200 dpi, so far wider)."""
    from PIL import Image

    def read(png, *, page=1, scale=1.0):
        with Image.open(io.BytesIO(png)) as im:
            return words_for(texts["image"] if im.width < 1000 else texts["pdf"], page)
    return read


def edited_screenshot() -> bytes:
    """A dashboard screenshot saved through an image editor
    (editor_software_on_screenshot)."""
    xmp = ('<x:xmpmeta><rdf:RDF><xmp:CreatorTool>Adobe Photoshop CS6</xmp:CreatorTool>'
           '</rdf:RDF></x:xmpmeta>')
    return png_bytes(extra_chunks=[(b"iTXt", b"XML:com.adobe.xmp\0\0\0\0\0" + xmp.encode())])


def affiliation(users, held=None, age=timedelta(0)):
    """An org-affiliation/v1 export."""
    return {"schema": "org-affiliation/v1",
            "generated_at": (datetime.now(timezone.utc) - age).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "users": {u: {"verdict": "none", "coverage": "full", "evidence": [], **v} for u, v in users.items()},
            "held": held or {}}


@unittest.skipUnless(HAVE_PDF, "PyMuPDF required")
class MultiContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = ProofStore(os.path.join(self.tmp.name, "proof.sqlite"))
        self.path = os.path.join(self.tmp.name, "sheet.pdf")
        Path(self.path).write_bytes(pdf_bytes(COWRITE))

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_one_run_judges_each_track_on_its_own_content_checks(self):
        ctxs = [ctx("Night Drive", "t-1", "11111111-1111-1111-1111-111111111111"),
                ctx("Other Song", "t-2", "22222222-2222-2222-2222-222222222222", isrc=None)]
        calls = []

        def runner(p, d, c, cs):
            calls.append(len(cs))
            return multi_runner(p, d, c, cs)
        with mock.patch.object(ocr, "ocr_image_bytes", FakeOcr([COWRITE])):
            [[night], [other]] = analyze_against(self.store, self.path, contact_h="ann", source="test",
                                                 source_ref="sheet", contexts=ctxs, runner=runner)
        self.assertEqual(calls, [2])                     # the file is parsed once for both tracks
        self.assertEqual(night.verdict, verdict.GENUINE)
        self.assertNotEqual(other.verdict, verdict.GENUINE)
        self.assertNotIn(other.verdict, (verdict.FORGED_LIKELY,))

    def test_later_contexts_of_one_document_see_what_earlier_ones_recorded(self):
        ctxs = [ctx("Night Drive", "t-1", "11111111-1111-1111-1111-111111111111"),
                ctx("Night Drive", "t-2", "22222222-2222-2222-2222-222222222222")]
        with mock.patch.object(ocr, "ocr_image_bytes", FakeOcr([COWRITE])):
            [[first], [second]] = analyze_against(self.store, self.path, contact_h="ann", source="test",
                                                  source_ref="sheet", contexts=ctxs, runner=multi_runner)
        self.assertNotIn("reupload_same_account", {s.name for s in first.signals})
        self.assertIn("reupload_same_account", {s.name for s in second.signals})

    def test_multi_context_verdict_equals_the_single_context_verdict(self):
        c = ctx("Night Drive", "t-1", "11111111-1111-1111-1111-111111111111")
        other = os.path.join(self.tmp.name, "single.sqlite")
        single_store = ProofStore(other)
        try:
            with mock.patch.object(ocr, "ocr_image_bytes", FakeOcr([COWRITE])):
                [single] = analyze_proof(single_store, self.path, contact_h="ann", source="test", source_ref="s",
                                         ctx=c, runner=lambda p, d, cc: analyze.extract(p, d,
                                                                                        ClaimContext.from_dict(cc)))
                [[multi]] = analyze_against(self.store, self.path, contact_h="ann", source="test", source_ref="s",
                                            contexts=[c], runner=multi_runner)
        finally:
            single_store.close()
        self.assertEqual((multi.verdict, sorted(s.name for s in multi.signals)),
                         (single.verdict, sorted(s.name for s in single.signals)))

    def test_an_answer_without_per_context_checks_is_never_a_pass(self):
        c = ctx("Night Drive", "t-1", "11111111-1111-1111-1111-111111111111")

        def stale(p, d, cc, cs):
            out = analyze.extract(p, d, ClaimContext.from_dict(cc))
            out.pop("per_context", None)
            return out
        with mock.patch.object(ocr, "ocr_image_bytes", FakeOcr([COWRITE])):
            [[res]] = analyze_against(self.store, self.path, contact_h="ann", source="test", source_ref="s",
                                      contexts=[c], runner=stale)
        self.assertEqual(res.verdict, verdict.UNDETERMINED)


def req(rid, title, pop, *, status="unverified", roles="{Songwriter}", user=7, track=None, isrc="USABC2400001"):
    return [rid, status, roles, title, json.dumps([{"id": "a1", "name": "Small Act"}]), str(pop),
            track or f"trk-{rid[:4]}", isrc or "", "2024-03-01", str(user), "2026-10-10 10:00:00.000 UTC",
            "Ann Alpha", "Ann", "Alpha", "Ann Alpha"]


RA, RB, RC, RD, RE = ("aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002",
                      "cccccccc-0000-0000-0000-000000000003", "dddddddd-0000-0000-0000-000000000004",
                      "eeeeeeee-0000-0000-0000-000000000005")


@unittest.skipUnless(HAVE_PDF, "PyMuPDF required")
class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.store = ProofStore(os.path.join(d, "proof.sqlite"))
        self.ledger = os.path.join(d, "ledger.sqlite3")
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, run_id TEXT, decided_at TEXT, request_id TEXT,"
                   " user_id INTEGER, paid_priority INTEGER, decision TEXT, reason TEXT, mode TEXT)")
        held = "proof on file: human review (a document is already on file; never ask again)"
        rows = [(RA, 7, 1), (RB, 7, 1), (RC, 8, 0), (RD, 9, 1), (RE, 7, 1)]
        for i, (rid, uid, paid) in enumerate(rows):
            db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, paid_priority, decision,"
                       " reason, mode) VALUES ('r', ?, ?, ?, ?, 'hold', ?, 'apply')",
                       (f"2026-10-19T0{i}:00:00Z", rid, uid, paid, held))
        # a later shadow row never counts, and an older apply row is superseded
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, paid_priority, decision, reason,"
                   " mode) VALUES ('s', '2026-10-19T09:00:00Z', ?, 7, 1, 'approve', 'x', 'shadow')", (RA,))
        db.commit()
        db.close()
        self.proof = os.path.join(d, "proof-on-file.json")
        Path(self.proof).write_text(json.dumps({"entries": [
            {"user_id": 7, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "2154001"},
            {"user_id": 8, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "2154002"},
            {"user_id": 9, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "1a14aeb7"}]}))
        self.org = os.path.join(d, "org.json")
        Path(self.org).write_text(json.dumps(affiliation({"7": {}, "8": {}, "9": {}})))
        self.trino_rows = {RA: req(RA, "Night Drive", 30), RB: req(RB, "Other Song", 30, isrc=None),
                           RC: req(RC, "Night Drive", 70, user=8, track="trk-big")[:11] + [
                               "Bob Beta", "Bob", "Beta", "Bob Beta"],
                           RD: req(RD, "Night Drive", 30, user=9), RE: req(RE, "Night Drive", 30, status="approved")}
        self.sql = []
        self.sheet = pdf_bytes(COWRITE)
        self.bob_sheet = pdf_bytes(COWRITE.replace("2024-03-01", "2024-03-02"))   # Bob's own copy
        self.files: dict[str, bytes] = {}                 # conversation id -> attachment, else the defaults
        self.exts: dict[str, str] = {}                    # conversation id -> attachment extension (pdf)
        self.down: set[str] = set()                       # conversation ids whose GET fails
        self.dl_down: set[str] = set()                    # conversation ids whose attachment download fails
        self.contact_of: dict[str, str] = {}              # conversation id -> Intercom contact (its own)
        self.ocr_text = COWRITE

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def trino(self, sql):
        self.sql.append(sql)
        import csv
        import io
        buf = io.StringIO()
        buf.write("Oct 19, 2026 2:44:16 PM org.jline.utils.Log logr WARNING: dumb terminal\n")
        w = csv.writer(buf)
        for rid, row in self.trino_rows.items():
            if rid in sql:
                w.writerow(row if "u.fullname" in sql else row[:2])
        return buf.getvalue()

    def fetch(self, conv_id):
        if conv_id in self.down:
            raise RuntimeError("intercom GET failed")
        ext = self.exts.get(conv_id, "pdf")
        return {"contacts": {"contacts": [{"id": self.contact_of.get(conv_id, f"contact-{conv_id}")}]},
                "source": {"author": {"type": "user"}, "attachments": [
                    {"url": f"https://downloads.example/{conv_id}.{ext}",
                     "name": "split sheet.pdf" if ext == "pdf" else f"dashboard.{ext}"}]},
                "conversation_parts": {"conversation_parts": [
                    {"author": {"type": "admin"}, "attachments": [{"url": "https://downloads.example/admin.png"}]}]}}

    def dl(self, url, dest):
        self.assertNotIn("admin", url)                   # only the customer's own attachments
        conv = url.rsplit("/", 1)[-1].split(".")[0]
        if conv in self.dl_down:
            raise OSError("HTTP 403")
        data = self.files.get(conv) or (self.bob_sheet if conv == "2154002" else self.sheet)
        Path(dest).write_bytes(data)
        return len(data)

    def go(self, **kw):
        kw.setdefault("runner", multi_runner)
        reader = ocr_by_size(self.ocr_text) if isinstance(self.ocr_text, dict) else FakeOcr([self.ocr_text])
        with mock.patch.object(ocr, "ocr_image_bytes", reader):
            return stage2.run(self.store, fetch=self.fetch, trino=self.trino, dl=self.dl,
                              ledger_path=self.ledger, proof_path=self.proof, org_path=self.org,
                              cache_root=os.path.join(self.tmp.name, "nocache"), **kw)

    def add_conversation(self, conv_id: str, user: int = 7):
        doc = json.loads(Path(self.proof).read_text())
        first = next(e["ref"] for e in doc["entries"] if e["user_id"] == user)
        self.contact_of[conv_id] = f"contact-{first}"            # the same Intercom contact as the user's others
        doc["entries"].append({"user_id": user, "request_id": None, "kind": "pending_doc", "source": "intercom",
                               "ref": conv_id})
        Path(self.proof).write_text(json.dumps(doc))

    def outcomes(self):
        return {(r[0], r[1]): r[2] for r in self.store.db.execute(
            "SELECT request_id, role, outcome FROM stage2_shadow")}

    def test_shadow_outcomes_follow_the_stage2_table(self):
        stats = self.go()
        got = self.outcomes()
        self.assertEqual(got[(RA, "Songwriter")], "approve")           # T0/T1, the sheet names Ann on the track
        self.assertEqual(got[(RB, "Songwriter")], "need_more")         # the sheet does not list this track
        self.assertEqual(got[(RC, "Songwriter")], "human")             # T2 needs a second anchor
        self.assertEqual(got[(RD, "Songwriter")], "no_document")       # Gmail-only: nothing readable here
        self.assertNotIn((RE, "Songwriter"), got)                      # no longer held: skipped
        self.assertEqual(stats["skipped_not_held"], 1)
        self.assertTrue(all(s.lstrip().upper().startswith("SELECT") for s in self.sql))

    def test_paid_users_first_and_a_second_run_rejudges_nothing(self):
        stats = self.go(max_users=1)
        self.assertEqual(stats["users"], 1)
        self.assertEqual({r[0] for r in self.store.db.execute("SELECT user_id FROM stage2_shadow")}, {7})
        self.go()
        n = self.store.db.execute("SELECT COUNT(*) FROM stage2_shadow").fetchone()[0]
        again = self.go()
        self.assertEqual((again["rows"], self.store.db.execute("SELECT COUNT(*) FROM stage2_shadow").fetchone()[0]),
                         (0, n))

    def test_an_org_affiliated_account_is_never_approved(self):
        Path(self.org).write_text(json.dumps(affiliation({"7": {"verdict": "contributor"}, "8": {}, "9": {}})))
        self.go()
        self.assertEqual(self.outcomes()[(RA, "Songwriter")], "human")

    def test_an_unknown_org_affiliation_is_a_human_never_an_approval(self):
        cases = {"missing file": None,
                 "stale file": affiliation({"7": {}}, age=timedelta(hours=3)),
                 "absent user": affiliation({"8": {}}),
                 "held user": affiliation({"7": {}}, held={"7": {"reason": "lookup failed"}}),
                 "partial coverage": affiliation({"7": {"coverage": "labels_only"}})}
        for name, export in cases.items():
            with self.subTest(name):
                self.store.close()
                self.store = ProofStore(os.path.join(self.tmp.name, f"proof-{name.replace(' ', '-')}.sqlite"))
                if export is None:
                    Path(self.org).unlink(missing_ok=True)
                else:
                    Path(self.org).write_text(json.dumps(export))
                self.go()
                outcome, reason = self.store.db.execute(
                    "SELECT outcome, reason FROM stage2_shadow WHERE request_id=?", (RA,)).fetchone()
                self.assertEqual(outcome, "human")
                self.assertIn("affiliation unknown", reason)

    def test_an_edited_sheet_for_one_track_is_not_called_forged_for_another(self):
        self.sheet = online_edited(COWRITE)
        self.trino_rows[RB] = req(RB, "Other Song", 30, isrc="USXYZ2400099")
        self.go()
        got = self.outcomes()
        self.assertNotEqual(got[(RB, "Songwriter")], "reject_hold")
        self.assertNotEqual(got[(RA, "Songwriter")], "reject_hold")
        [detail] = [json.loads(r[0]) for r in self.store.db.execute(
            "SELECT detail_json FROM stage2_shadow WHERE request_id=?", (RB,))]
        self.assertEqual([d["track_listed"] for d in detail], [False])
        self.assertNotIn("FORGED_LIKELY", [d["verdict"] for d in detail])

    def test_each_request_is_checked_against_its_own_profile_name(self):
        # one account (Zed Zulu) managing two profiles; the sheet credits only profile A (Ann Alpha)
        account = ["Zed Zulu", "Zed", "Zulu"]
        self.trino_rows[RA] = req(RA, "Night Drive", 30, track="trk-same")[:11] + account + ["Ann Alpha"]
        self.trino_rows[RB] = req(RB, "Night Drive", 30, track="trk-same")[:11] + account + ["Cara Gamma"]
        self.go()
        got = self.outcomes()
        self.assertEqual(got[(RA, "Songwriter")], "approve")
        self.assertNotEqual(got[(RB, "Songwriter")], "approve")

    def test_string_and_integer_user_ids_are_the_same_user(self):
        Path(self.proof).write_text(json.dumps({"entries": [
            {"user_id": "111", "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "2154001"},
            {"user_id": 111, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "2154009"},
            {"user_id": " 7 ", "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "2154001"}]}))
        self.assertEqual(stage2.proof_conversations(self.proof), {111: ["2154009", "2154001"], 7: ["2154001"]})
        self.go()
        self.assertEqual(self.outcomes()[(RA, "Songwriter")], "approve")

    def test_an_intercom_outage_writes_no_rows(self):
        self.down = {"2154001", "2154002"}
        stats = self.go()
        self.assertTrue(stats["intercom_unavailable"])
        self.assertEqual((stats["rows"], self.store.db.execute("SELECT COUNT(*) FROM stage2_shadow").fetchone()[0]),
                         (0, 0))

    def test_a_broken_download_among_gmail_only_users_is_not_an_outage(self):
        Path(self.proof).write_text(json.dumps({"entries": [
            {"user_id": 7, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "2154001"},
            {"user_id": 8, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "1a14aeb8"},
            {"user_id": 9, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "1a14aeb7"}]}))
        self.dl_down = {"2154001"}                                    # the GET answers, the download never works
        runs = [self.go() for _ in range(4)]
        self.assertEqual([r["intercom_unavailable"] for r in runs], [False] * 4)
        self.assertEqual([r["users"] for r in runs], [3, 1, 1, 0])
        got = self.outcomes()
        self.assertEqual((got[(RC, "Songwriter")], got[(RD, "Songwriter")]), ("no_document", "no_document"))
        rows = [r[0] for r in self.store.db.execute("SELECT outcome FROM stage2_shadow WHERE request_id=?", (RA,))]
        self.assertEqual(rows, ["undetermined"] * 3)

    def test_a_crash_keeps_the_rows_of_users_already_judged(self):
        def crash(p, d, c, cs):                                       # user 8, picked after users 7 and 9
            if "2154002" in p:
                raise RuntimeError("worker died")
            return multi_runner(p, d, c, cs)
        with self.assertRaises(RuntimeError):
            self.go(runner=crash)
        self.assertEqual({r[0] for r in self.store.db.execute("SELECT user_id FROM stage2_shadow")}, {7, 9})
        self.assertEqual(self.outcomes()[(RA, "Songwriter")], "approve")

    def test_documents_that_cannot_be_fetched_are_retried_up_to_three_runs(self):
        self.down = {"2154001"}                                       # user 7 only; user 8's GET works
        broken = lambda p, d, c, cs: ({"fatal": "tooling broke"} if "2154002" in p    # noqa: E731
                                      else multi_runner(p, d, c, cs))  # keeps user 8 re-picked, fetched fine
        runs = [self.go(runner=broken) for _ in range(4)]
        self.assertEqual([r["intercom_unavailable"] for r in runs], [False] * 4)
        self.assertEqual([r["retry_users"] for r in runs], [1, 1, 1, 0])
        self.assertEqual(runs[3]["users"], 0)
        rows = self.store.db.execute("SELECT outcome, reason FROM stage2_shadow WHERE request_id=?",
                                     (RA,)).fetchall()
        self.assertEqual([r[0] for r in rows], ["undetermined"] * 3)
        self.assertTrue(rows[0][1].startswith("documents could not be fetched (intercom"))

    def test_only_the_users_who_failed_to_fetch_are_undetermined(self):
        self.down = {"2154001"}
        stats = self.go()
        self.assertFalse(stats["intercom_unavailable"])
        got = self.outcomes()
        self.assertEqual((got[(RA, "Songwriter")], got[(RB, "Songwriter")]), ("undetermined", "undetermined"))
        self.assertEqual(got[(RC, "Songwriter")], "human")
        self.down = set()
        self.go()
        self.assertEqual(stage2.summary(self.store.db)["approve"], {"paid": 1, "free": 0})

    def test_a_partly_fetched_account_is_judged_again_with_every_document(self):
        self.add_conversation("2154003")
        self.down = {"2154003"}
        self.go()
        outcome, reason = self.store.db.execute("SELECT outcome, reason FROM stage2_shadow WHERE request_id=?",
                                                (RA,)).fetchone()
        self.assertEqual(outcome, "undetermined")                    # would be approve on what was read
        self.assertTrue(reason.startswith("some documents could not be fetched (intercom"))
        self.down = set()
        self.go()
        self.assertEqual(stage2.summary(self.store.db)["approve"], {"paid": 1, "free": 0})

    def test_a_forgery_among_partly_fetched_documents_stands_and_holds_the_account(self):
        self.two_sheets_for_ann(COWRITE.replace("USABC2400001", "USOTH2400077"))
        self.add_conversation("2154004")
        self.down = {"2154004"}
        self.go()
        got = self.outcomes()
        self.assertEqual((got[(RA, "Songwriter")], got[(RB, "Songwriter")]), ("reject_hold", "undetermined"))
        self.down = set()
        self.go()
        [(outcome, reason)] = self.store.db.execute(
            "SELECT outcome, reason FROM stage2_shadow WHERE request_id=? AND outcome != 'undetermined'",
            (RB,)).fetchall()
        self.assertEqual(outcome, "human")
        self.assertTrue(reason.startswith("account hold: a document on file for this account is likely forged"))

    def test_an_edited_dashboard_of_one_artist_is_not_forged_for_another(self):
        b = req(RB, "Other Song", 30, isrc="USXYZ2400099")
        b[4] = json.dumps([{"id": "a2", "name": "Other Act"}])
        self.trino_rows[RB] = b
        self.add_conversation("2154003")
        self.files["2154003"], self.exts["2154003"] = edited_screenshot(), "png"
        self.ocr_text = {"pdf": COWRITE,
                         "image": "Spotify for Artists Home Music Audience Small Act Streams 9,400 Listeners"}
        self.go()
        got = self.outcomes()
        self.assertNotEqual(got[(RB, "Songwriter")], "reject_hold")
        self.assertEqual(got[(RA, "Songwriter")], "approve")          # no account hold for A's genuine claim

    def test_a_sheet_naming_one_profile_is_not_forged_for_another_profiles_track(self):
        account = ["Zed Zulu", "Zed", "Zulu"]
        self.trino_rows[RA] = req(RA, "Night Drive", 30)[:11] + account + ["Ann Alpha"]
        self.trino_rows[RB] = req(RB, "Other Song", 30, isrc="USXYZ2400099")[:11] + account + ["Cara Gamma"]
        self.sheet = online_edited(COWRITE)
        self.go()
        rows = self.store.db.execute("SELECT outcome, reason FROM stage2_shadow WHERE user_id=7").fetchall()
        self.assertNotIn("reject_hold", [r[0] for r in rows])
        self.assertFalse(any(r[1].startswith("account hold") for r in rows))

    def test_a_title_edited_sheet_keeping_another_isrc_is_forged_for_the_claim(self):
        other = COWRITE.replace("USABC2400001", "USOTH2400077")      # another song's sheet, title edited
        self.sheet = online_edited(other)
        self.ocr_text = other
        self.go()
        self.assertEqual(self.outcomes()[(RA, "Songwriter")], "reject_hold")

    def two_sheets_for_ann(self, forged_for_a: str):
        """Ann's account sends `forged_for_a` (for Night Drive) and a clean
        named sheet for Other Song, in two conversations."""
        other_song = COWRITE.replace("Night Drive", "Other Song").replace("USABC2400001", "USXYZ2400099")
        self.trino_rows[RB] = req(RB, "Other Song", 30, isrc="USXYZ2400099")
        self.add_conversation("2154003")
        self.files = {"2154001": online_edited(forged_for_a), "2154003": pdf_bytes(other_song)}
        self.ocr_text = forged_for_a + "\n" + other_song

    def test_a_forged_document_holds_the_whole_account(self):
        self.two_sheets_for_ann(COWRITE.replace("USABC2400001", "USOTH2400077"))
        self.go()
        rows = {r[0]: (r[1], r[2]) for r in self.store.db.execute(
            "SELECT request_id, outcome, reason FROM stage2_shadow WHERE request_id IN (?, ?)", (RA, RB))}
        self.assertEqual(rows[RA][0], "reject_hold")
        self.assertEqual(rows[RB], ("human", "account hold: a document on file for this account is likely forged "
                                             "(intercom:2154001:0)"))

    def test_an_unnamed_edited_sheet_approves_nothing_on_the_account(self):
        self.two_sheets_for_ann(COWRITE.replace("Ann Alpha", "Cy Delta"))
        self.go()
        got = self.outcomes()
        self.assertEqual(got[(RA, "Songwriter")], "reject_hold")
        self.assertNotEqual(got[(RB, "Songwriter")], "approve")

    def test_an_earlier_reject_hold_holds_the_account_on_later_runs(self):
        stage2.ensure_schema(self.store.db)
        self.store.db.execute(
            "INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, outcome, reason, source_ref,"
            " documents, detail_json, analyzer_version) VALUES ('old', '2026-10-18T00:00:00Z',"
            " 'ffffffff-0000-0000-0000-000000000009', 'Songwriter', 7, 'reject_hold', 'forged',"
            " 'intercom:2150000:0', 1, '[]', ?)", (stage2.FORENSICS_VERSION,))
        self.store.db.commit()
        self.go()
        outcome, reason = self.store.db.execute("SELECT outcome, reason FROM stage2_shadow WHERE request_id=?",
                                                (RA,)).fetchone()
        self.assertEqual((outcome, reason), ("human", "account hold: a document on file for this account is "
                                                      "likely forged (intercom:2150000:0)"))

    def test_a_reject_hold_from_an_older_analyzer_neither_holds_the_account_nor_blocks_a_rejudge(self):
        stage2.ensure_schema(self.store.db)
        self.store.db.execute(
            "INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, outcome, reason, source_ref,"
            " documents, detail_json, analyzer_version) VALUES ('old', '2026-10-18T00:00:00Z', ?, 'Songwriter', 7,"
            " 'reject_hold', 'forged', 'intercom:2150000:0', 1, '[]', 'pf-1')", (RA,))
        self.store.db.commit()
        self.go()
        outcome = self.store.db.execute("SELECT outcome FROM stage2_shadow WHERE request_id=? AND analyzer_version=?",
                                        (RA, stage2.FORENSICS_VERSION)).fetchone()
        self.assertEqual(tuple(outcome), ("approve",))

    def test_undetermined_is_judged_again_up_to_three_runs(self):
        broken = lambda p, d, c, cs: {"fatal": "sandbox tooling broke"}   # noqa: E731
        for _ in range(4):
            with mock.patch.object(ocr, "ocr_image_bytes", FakeOcr([COWRITE])):
                stage2.run(self.store, fetch=self.fetch, trino=self.trino, runner=broken, dl=self.dl,
                           ledger_path=self.ledger, proof_path=self.proof, org_path=self.org,
                           cache_root=os.path.join(self.tmp.name, "nocache"))
        rows = [r[0] for r in self.store.db.execute("SELECT outcome FROM stage2_shadow WHERE request_id=?", (RA,))]
        self.assertEqual(rows, ["undetermined"] * 3)

    def test_undetermined_then_a_working_run_keeps_the_new_verdict(self):
        broken = lambda p, d, c, cs: {"fatal": "sandbox tooling broke"}   # noqa: E731
        stage2.run(self.store, fetch=self.fetch, trino=self.trino, runner=broken, dl=self.dl,
                   ledger_path=self.ledger, proof_path=self.proof, org_path=self.org,
                   cache_root=os.path.join(self.tmp.name, "nocache"))
        self.go()
        self.go()
        rows = [r[0] for r in self.store.db.execute(
            "SELECT outcome FROM stage2_shadow WHERE request_id=? ORDER BY id", (RA,))]
        self.assertEqual(rows, ["undetermined", "approve"])
        self.assertEqual(stage2.summary(self.store.db)["approve"], {"paid": 1, "free": 0})

    def test_rows_carry_the_analyzer_version_and_an_old_table_is_migrated(self):
        db = sqlite3.connect(":memory:")
        db.execute("CREATE TABLE stage2_shadow (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, "
                   "judged_at TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER, "
                   "paid INTEGER, popularity INTEGER, tier TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, "
                   "verdict TEXT, proof_id TEXT, source_ref TEXT, doc_kind TEXT, documents INTEGER NOT NULL, "
                   "detail_json TEXT NOT NULL)")
        self.assertNotIn("analyzer_version", {r[1] for r in db.execute("PRAGMA table_info(stage2_shadow)")})
        stage2.ensure_schema(db)
        self.assertIn("analyzer_version", {r[1] for r in db.execute("PRAGMA table_info(stage2_shadow)")})
        self.go()
        self.assertEqual({r[0] for r in self.store.db.execute("SELECT analyzer_version FROM stage2_shadow")},
                         {FORENSICS_VERSION})

    def test_a_document_another_account_already_used_is_not_approved_for_this_one(self):
        # the same sheet, sent first by an account it does not name, then by Ann
        other = ProofStore(self.store.path)
        with mock.patch.object(ocr, "ocr_image_bytes", FakeOcr([COWRITE])):
            p = os.path.join(self.tmp.name, "first.pdf")
            Path(p).write_bytes(self.sheet)
            analyze_against(other, p, contact_h="mallory", source="intercom", source_ref="x",
                            contexts=[ctx("Night Drive", "trk-aaaa", "ffffffff-0000-0000-0000-000000000009",
                                          names=("Mallory Fraud",))], runner=multi_runner)
        other.close()
        self.go()
        self.assertEqual(self.outcomes()[(RA, "Songwriter")], "approve")   # the named owner stays clean

    def test_sample_puts_approvals_first_and_respects_n(self):
        self.go()
        rows = stage2.sample(self.store.db, n=3)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]["outcome"], "approve")
        md = stage2.sample_markdown(rows)
        self.assertIn("| 1 | `" + RA + "`", md)
        self.assertEqual(stage2.summary(self.store.db)["approve"], {"paid": 1, "free": 0})


class ClaimVerdictTests(unittest.TestCase):
    def pr(self, *names):
        sev = {"online_editor_producer": SOFT}
        return ProofResult(proof_id="p", verdict=verdict.FORGED_LIKELY, reasons=["edited"], kind="split_sheet",
                           mime="application/pdf", track_listed=False,
                           signals=[Signal("F5", n, sev.get(n, MISMATCH)) for n in names])

    def test_only_claim_specific_mismatches_are_coverage_gaps_off_the_track(self):
        c = ClaimContext(request_ids=["r#Producer"], claimed_roles=["Producer"], track_title="Other Song")
        v, _, _ = stage2.claim_verdict(self.pr("online_editor_producer", "claimant_not_named",
                                               "isrc_other_recording"), c)
        self.assertNotEqual(v, verdict.FORGED_LIKELY)
        v, _, _ = stage2.claim_verdict(self.pr("online_editor_producer", "claimant_not_named",
                                               "split_shares_do_not_add_up"), c)
        self.assertEqual(v, verdict.FORGED_LIKELY)
        on_track = self.pr("online_editor_producer", "isrc_other_recording")
        on_track.track_listed = True
        self.assertEqual(stage2.claim_verdict(on_track, c)[0], verdict.FORGED_LIKELY)


class JudgeTests(unittest.TestCase):
    def r(self, pop):
        return stage2.Request(request_id=RA, user_id=7, status="unverified", roles=["Producer"], title="T",
                              artists=[], popularity=pop, track_id="t", isrc=None, release_date=None,
                              created_at="", names=["A"])

    def d(self, v, covers=True):
        return {"verdict": v, "proof_id": v.lower(), "source_ref": "intercom:1:0", "kind": "split_sheet",
                "reasons": [f"{v} because"], "track_listed": covers}

    def test_table(self):
        j = stage2.judge
        self.assertEqual(j(self.r(30), "Producer", [self.d("GENUINE"), self.d("FORGED_LIKELY")], org=None,
                           readable=2).outcome, "reject_hold")
        covering_doubt = {**self.d("SUSPECT"), "soft": ["copy_move_region"], "source_ref": "intercom:2:1"}
        o = j(self.r(30), "Producer", [self.d("GENUINE"), covering_doubt], org=None, readable=2)
        self.assertEqual(o.outcome, "human")
        self.assertIn("intercom:2:1", o.reason)
        self.assertEqual(j(self.r(30), "Producer", [self.d("GENUINE"), self.d("INCONSISTENT")], org=None,
                           readable=2).outcome, "human")
        self.assertEqual(j(self.r(30), "Producer", [self.d("GENUINE"), self.d("INCONSISTENT", covers=False)],
                           org=None, readable=2).outcome, "approve")
        self.assertIn("second independent anchor",
                      j(self.r(70), "Producer", [self.d("VERIFIED")], org=None, readable=1).reason)
        self.assertEqual(j(self.r(0), "Producer", [self.d("GENUINE")], org=None, readable=1).outcome, "human")
        self.assertEqual(j(self.r(None), "Producer", [self.d("VERIFIED")], org=None, readable=1).outcome, "human")
        self.assertEqual(j(self.r(85), "Producer", [self.d("GENUINE")], org=None, readable=1).outcome, "human")
        self.assertEqual(j(self.r(30), "Producer", [self.d("GENUINE")], org="the account is org-affiliated",
                           readable=1).outcome, "human")
        doubt = {**self.d("SUSPECT"), "soft": ["copy_move_region"]}
        self.assertEqual(j(self.r(30), "Producer", [doubt], org=None, readable=1).outcome, "review")
        self.assertEqual(j(self.r(30), "Producer", [self.d("PLAUSIBLE"), doubt], org=None, readable=2).outcome,
                         "review")
        untied = {**self.d("SUSPECT"), "soft": [], "reasons": ["nothing in the document ties it to this track"]}
        self.assertEqual(j(self.r(30), "Producer", [untied], org=None, readable=1).outcome, "need_more")
        video = {**self.d("SUSPECT"), "soft": ["reject_unaccepted_type"]}
        self.assertEqual(j(self.r(30), "Producer", [video, untied], org=None, readable=2).outcome, "need_more")
        polyglot = {**self.d("SUSPECT"), "soft": ["reject_polyglot"]}
        self.assertEqual(j(self.r(30), "Producer", [polyglot], org=None, readable=1).outcome, "review")
        gap = {**self.d("SUSPECT"), "soft": ["track_not_named"]}
        self.assertEqual(j(self.r(30), "Producer", [gap], org=None, readable=1).outcome, "need_more")
        mixed = {**self.d("SUSPECT"), "soft": ["track_not_named", "copy_move_region"]}
        self.assertEqual(j(self.r(30), "Producer", [mixed], org=None, readable=1).outcome, "review")
        self.assertEqual(j(self.r(30), "Producer", [self.d("PLAUSIBLE")], org=None, readable=1).outcome,
                         "need_more")
        self.assertEqual(j(self.r(30), "Producer", [self.d("UNDETERMINED")], org=None, readable=1).outcome,
                         "undetermined")
        self.assertEqual(j(self.r(30), "Producer", [], org=None, readable=0).outcome, "no_document")
        self.assertEqual(j(self.r(30), "Producer", [], org=None, readable=3).outcome, "undetermined")


class CliTests(unittest.TestCase):
    def test_an_intercom_outage_fails_the_cron(self):
        import importlib.util
        from contextlib import redirect_stdout
        spec = importlib.util.spec_from_file_location("credit_proof_cli_s2",
                                                      Path(__file__).resolve().parents[1] / "credit-proof.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        with tempfile.TemporaryDirectory() as d:
            cli.KILL_SWITCH = str(Path(d) / "absent")
            for down, rc in ((True, 1), (False, 0)):
                stats = {"run_id": "r", "held_unjudged": 1, "users": 1, "rows": 0 if down else 1, "documents": 0,
                         "skipped_not_held": 0, "retry_users": 1, "outcomes": {}, "errors": [],
                         "intercom_unavailable": down}
                with mock.patch("credit_verify.proof.intercom.intercom_token", return_value="tok"), \
                        mock.patch("credit_verify.proof.stage2.run", return_value=stats), \
                        redirect_stdout(io.StringIO()):
                    self.assertEqual(cli.main(["--store", str(Path(d) / "s.sqlite"), "stage2"]), rc)


class InputTests(unittest.TestCase):
    def test_trino_refuses_anything_but_a_select(self):
        with self.assertRaises(ValueError):
            stage2.trino_query("DELETE FROM postgresql_core.public.credit_requests")

    def test_trino_time_limit_is_retried_once_and_errors_keep_the_cause(self):
        # 2026-10-28: ~1 in 9 reader request look-ups hit the 60 s limit under the shared coordinator's load,
        # and the kept error tail was only kubectl/jline noise.
        import subprocess as sp
        noise = ("Oct 28, 2026 5:29:02 PM org.jline.utils.Log logr\nWARNING: Unable to create a system terminal, "
                 "creating a dumb terminal (enable debug logging for more information)\nSET SESSION\n")
        late = noise + "Query 2026_x failed: Query exceeded the maximum execution time limit of 60.00s\n\n" \
                       "command terminated with exit code 1\n"
        res = lambda rc, err="", out="": sp.CompletedProcess([], rc, out, err)   # noqa: E731
        calls, slept = [], []

        def run_seq(seq):
            it = iter(seq)

            def run(*a, **k):
                calls.append(k["input"])
                return next(it)
            return run
        out = stage2.trino_query("SELECT 1", sleep=slept.append, run=run_seq([res(1, late), res(0, out='"1"\n')]))
        self.assertEqual((out, len(calls), slept), ('"1"\n', 2, [stage2.TRINO_RETRY_WAIT_S]))
        calls.clear()
        with self.assertRaises(RuntimeError) as cm:                      # twice: raise, with the real cause
            stage2.trino_query("SELECT 1", sleep=slept.append, run=run_seq([res(1, late), res(1, late)]))
        self.assertEqual(len(calls), 2)
        self.assertIn("Query exceeded the maximum execution time limit of 60.00s", str(cm.exception))
        self.assertNotIn("jline", str(cm.exception))
        calls.clear()
        with self.assertRaises(RuntimeError) as cm:                      # any other failure: no retry
            stage2.trino_query("SELECT 1", sleep=slept.append,
                               run=run_seq([res(1, noise + "Query y failed: line 1:8: Column 'z' cannot be resolved\n")]))
        self.assertEqual(len(calls), 1)
        self.assertIn("cannot be resolved", str(cm.exception))

    def test_postgres_arrays_and_names(self):
        self.assertEqual(stage2._pg_array('{Producer,"Mixing Engineer",Mastering}'),
                         ["Producer", "Mixing Engineer", "Mastering"])
        self.assertEqual(stage2._pg_array(""), [])
        import csv
        import io
        buf = io.StringIO()
        buf.write("warning line\n")
        csv.writer(buf).writerow(req(RA, "Night Drive", 30))
        rows = stage2.requests([RA, "not-a-uuid"], trino=lambda sql: buf.getvalue())
        self.assertEqual(list(rows), [RA])
        self.assertEqual((rows[RA].roles, rows[RA].names, rows[RA].isrc), (["Songwriter"], ["Ann Alpha"],
                                                                           "USABC2400001"))

    def test_customer_attachments_skip_teammates(self):
        conv = {"source": {"author": {"type": "lead"}, "attachments": [{"url": "https://x/1"}]},
                "conversation_parts": {"conversation_parts": [
                    {"author": {"type": "admin"}, "attachments": [{"url": "https://x/2"}]},
                    {"author": {"type": "user"}, "attachments": [{"url": "https://x/3"}, {"name": "no url"}]}]}}
        self.assertEqual([a["url"] for a in stage2.customer_attachments(conv)], ["https://x/1", "https://x/3"])

    def test_download_refuses_plain_http(self):
        with self.assertRaises(ValueError):
            stage2.download("http://x/1", "/dev/null")


class FableSample1020Tests(unittest.TestCase):
    """Fable's stage-2 sample (2026-10-20): both FORGED calls and every
    copy-move doubt it opened were wrong on images that are not documents of
    record; need_more must name the gap."""

    def sig(self, name, sev):
        from credit_verify.proof.signals import Signal
        return Signal("F3a" if "ai" in name else "F3b", name, sev)

    def test_ai_source_is_soft_on_artwork_and_hard_on_a_document_of_record(self):
        from credit_verify.proof import content
        from credit_verify.proof.signals import HARD, SOFT
        for kind in ("unknown", "catalog_page", "daw_session", None):
            got = content.kind_adjusted([self.sig("c2pa_ai_source", HARD), self.sig("iptc_ai_source_type", HARD)], kind)
            self.assertEqual({s.severity for s in got}, {SOFT}, kind)
            self.assertNotEqual(verdict.decide(got, ctx("T", "t", RA))[0], verdict.FORGED_LIKELY)
        for kind in ("invoice", "contract", "split_sheet", "distributor_portal", "dsp_for_artists"):
            got = content.kind_adjusted([self.sig("c2pa_ai_source", HARD)], kind)
            self.assertEqual(got[0].severity, HARD, kind)
            self.assertEqual(verdict.decide(got, ctx("T", "t", RA))[0], verdict.FORGED_LIKELY)

    def test_a_liner_note_with_writer_affiliations_and_ai_metadata_is_not_forged(self):
        from credit_verify.proof import content
        from credit_verify.proof.signals import HARD, SOFT
        kind = content.classify_kind("Full House\nWritten by Ann Alpha (BMI), Bob Beta (ASCAP)\n"
                                     "Produced by Ann Alpha (BMI)")
        self.assertEqual(kind, "pro_portal")
        got = content.kind_adjusted([self.sig("c2pa_ai_source", HARD)], kind)
        self.assertEqual(got[0].severity, SOFT)
        self.assertNotEqual(verdict.decide(got, ctx("T", "t", RA))[0], verdict.FORGED_LIKELY)

    def test_a_content_mismatch_next_to_noise_copy_move_is_not_forged(self):
        from credit_verify.proof import content
        from credit_verify.proof.signals import INFO, MISMATCH, POSITIVE
        sig = [Signal("F5a", "title_matches_claim", POSITIVE), Signal("F5a", "isrc_other_recording", MISMATCH),
               self.sig("copy_move_region", SOFT)]
        got = content.kind_adjusted(sig, "catalog_page")
        self.assertEqual(got[2].severity, INFO)
        self.assertEqual(verdict.decide(got, ctx("T", "t", RA))[0], verdict.INCONSISTENT)
        on_record = content.kind_adjusted(sig, "invoice")
        self.assertEqual(verdict.decide(on_record, ctx("T", "t", RA))[0], verdict.FORGED_LIKELY)

    def test_copy_move_is_noise_on_a_screenshot_unless_text_was_edited(self):
        from credit_verify.proof import content
        from credit_verify.proof.signals import INFO, SOFT
        self.assertEqual(content.kind_adjusted([self.sig("copy_move_region", SOFT)], "unknown")[0].severity, INFO)
        edited = content.kind_adjusted([self.sig("copy_move_region", SOFT), self.sig("ela_outlier_on_key_field", SOFT)],
                                       "unknown")
        self.assertEqual(edited[0].severity, SOFT)
        self.assertEqual(content.kind_adjusted([self.sig("copy_move_region", SOFT)], "invoice")[0].severity, SOFT)

    def r(self, title="Full House", pop=30):
        return stage2.Request(request_id=RA, user_id=7, status="unverified", roles=["Producer"], title=title,
                              artists=[], popularity=pop, track_id="t", isrc=None, release_date=None,
                              created_at="", names=["A"])

    def doc(self, **kw):
        d = {"verdict": "SUSPECT", "proof_id": "p1", "source_ref": "intercom:215476447551214:2", "kind": "unknown",
             "reasons": ["nothing in the document ties it to this track"], "soft": [], "track_listed": False,
             "named": None, "signals": [], "lists": []}
        d.update(kw)
        return d

    def test_an_ai_image_that_otherwise_ties_goes_to_a_human_never_approve(self):
        d = self.doc(soft=["c2pa_ai_source"], track_listed=True, named=True,
                     signals=["c2pa_ai_source", "claimant_named", "title_matches_claim"])
        o = stage2.judge(self.r(), "Producer", [d], org=None, readable=1)
        self.assertEqual(o.outcome, "human")
        self.assertIn("never auto-approved", o.reason)
        # without the tie it is a named gap, not forensic doubt
        o = stage2.judge(self.r(), "Producer", [self.doc(soft=["c2pa_ai_source"], signals=["c2pa_ai_source"])],
                         org=None, readable=1)
        self.assertEqual(o.outcome, "need_more")

    def test_an_ai_made_cover_naming_the_track_and_claimant_follows_its_text_to_the_role_gap(self):
        from credit_verify.proof import content
        from credit_verify.proof.signals import HARD, INFO, POSITIVE
        raw = [self.sig("c2pa_ai_source", HARD), Signal("F5a", "title_matches_claim", POSITIVE),
               Signal("F5b", "claimant_named", POSITIVE), Signal("F5b", "claimed_role_not_expressible", INFO,
                                                                 reason="The document can't show the role you claimed.")]
        for kind in ("unknown", "catalog_page"):
            sig = content.kind_adjusted(raw, kind)
            v, reasons = verdict.decide(sig, ctx("Full House", "t", RA, role="Producer"))
            d = self.doc(kind=kind, verdict=v, reasons=reasons, track_listed=True, named=True,
                         soft=sorted(s.name for s in sig if s.severity == SOFT),
                         signals=sorted(s.name for s in sig))
            o = stage2.judge(self.r(), "Producer", [d], org=None, readable=1)
            self.assertEqual(o.outcome, "need_more", kind)
            self.assertIn("can't show the role you claimed (Producer)", o.reason)
        unverified = self.doc(soft=["c2pa_ai_source"], track_listed=True, named=True,
                              signals=["c2pa_ai_source", "claimant_named_unverified", "title_matches_claim"])
        self.assertEqual(stage2.judge(self.r(), "Producer", [unverified], org=None, readable=1).outcome, "need_more")
        inconsistent = self.doc(verdict="INCONSISTENT", soft=["c2pa_ai_source"], track_listed=True, named=True,
                                signals=["c2pa_ai_source", "claimant_named", "split_shares_do_not_add_up"])
        self.assertEqual(stage2.judge(self.r(), "Producer", [inconsistent], org=None, readable=1).outcome,
                         "need_more")

    def test_need_more_names_the_document_what_it_covers_and_the_gap(self):
        o = stage2.judge(self.r(), "Producer", [self.doc(kind="catalog_page", lists=["On The Way Up"])], org=None,
                         readable=1)
        self.assertEqual(o.outcome, "need_more")
        self.assertEqual(o.reason, "The credits page you sent (Intercom conversation …51214, file 3) covers "
                                   "“On The Way Up”, not “Full House”; for “Full House” we need a document that "
                                   "names “Full House” and your Producer credit.")
        o = stage2.judge(self.r(), "Producer", [self.doc(kind="invoice", verdict="INCONSISTENT", track_listed=True,
                                                         named=False, reasons=["Your name doesn't appear"])],
                         org=None, readable=1)
        self.assertIn("names “Full House” but does not show your name", o.reason)
        o = stage2.judge(self.r(), "Producer", [self.doc(soft=["reject_unaccepted_type"])], org=None, readable=1)
        self.assertIn("could not be read", o.reason)
        o = stage2.judge(self.r(), "Producer", [self.doc(verdict="INCONSISTENT", signals=["isrc_other_recording"],
                                                         reasons=["The ISRC in your document is for a different "
                                                                  "recording."])], org=None, readable=1)
        self.assertIn("ISRC of a different recording", o.reason)
        # a credits page naming the title and the claimant, but with another recording's ISRC: the ask
        # names the ISRC conflict, not the role
        o = stage2.judge(self.r(), "Producer", [self.doc(kind="catalog_page", verdict="INCONSISTENT",
                                                         track_listed=True, named=True,
                                                         signals=["claimant_named", "isrc_other_recording",
                                                                  "title_matches_claim"])], org=None, readable=1)
        self.assertEqual(o.outcome, "need_more")
        self.assertIn("carries the ISRC of a different recording than “Full House”", o.reason)
        self.assertNotIn("confirm your Producer credit", o.reason)
        o = stage2.judge(self.r(), "Producer", [self.doc()], org=None, readable=1)
        self.assertIn("does not name “Full House” or its ISRC", o.reason)
        o = stage2.judge(self.r(), "Producer", [self.doc(source_ref="intercom:215476447551214:3.png")], org=None,
                         readable=1)
        self.assertIn("file 3.png)", o.reason)

    def test_an_invoice_naming_the_claimant_and_track_but_not_the_role_names_the_role_gap(self):
        plausible = self.doc(kind="invoice", verdict="PLAUSIBLE", track_listed=True, named=True,
                             reasons=["The document can't show the role you claimed.", "title_matches_claim",
                                      "claimant_named"],
                             signals=["claimant_named", "claimed_role_not_expressible", "title_matches_claim"])
        o = stage2.judge(self.r(), "Producer", [plausible], org=None, readable=1)
        self.assertEqual(o.outcome, "need_more")
        self.assertIn("can't show the role you claimed (Producer)", o.reason)
        self.assertNotIn("your name", o.reason)
        listed = self.doc(kind="invoice", track_listed=True, named=True, soft=["claimed_role_not_listed"],
                          signals=["claimant_named", "claimed_role_not_listed", "title_matches_claim"])
        o = stage2.judge(self.r(), "Producer", [listed], org=None, readable=1)
        self.assertEqual(o.outcome, "need_more")
        self.assertIn("not the role you claimed (Producer)", o.reason)
        shares = self.doc(kind="split_sheet", verdict="INCONSISTENT", track_listed=True, named=True,
                          signals=["claimant_named", "split_shares_do_not_add_up", "title_matches_claim"])
        o = stage2.judge(self.r(), "Producer", [shares], org=None, readable=1)
        self.assertIn("split shares do not add up", o.reason)
        hidden = self.doc(kind="contract", verdict="PLAUSIBLE", track_listed=True, named=True,
                          signals=["claim_text_not_rendered", "claimant_named", "title_matches_claim"])
        o = stage2.judge(self.r(), "Producer", [hidden], org=None, readable=1)
        self.assertIn("rendered page does not show", o.reason)

    def test_forensic_doubt_counts_only_on_a_document_that_covers_the_track_or_of_record(self):
        edited = self.doc(soft=["editor_software_on_screenshot"])
        self.assertEqual(stage2.judge(self.r(), "Producer", [edited], org=None, readable=1).outcome, "need_more")
        covering = self.doc(soft=["editor_software_on_screenshot"], track_listed=True)
        self.assertEqual(stage2.judge(self.r(), "Producer", [covering], org=None, readable=1).outcome, "review")
        invoice = self.doc(kind="invoice", soft=["online_editor_producer"])
        self.assertEqual(stage2.judge(self.r(), "Producer", [invoice], org=None, readable=1).outcome, "review")

    def test_the_sample_and_summary_read_only_the_current_analyzer(self):
        db = sqlite3.connect(":memory:")
        stage2.ensure_schema(db)
        for i, (outcome, version) in enumerate((("reject_hold", "pf-1"), ("need_more", FORENSICS_VERSION))):
            db.execute("INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, outcome, reason,"
                       " documents, detail_json, analyzer_version) VALUES (?, '', ?, 'Producer', 7, ?, ?, 1, '[]', ?)",
                       (f"r{i}", f"req-{i}", outcome, "x" * 380, version))
        rows = stage2.sample(db)
        self.assertEqual([r["outcome"] for r in rows], ["need_more"])
        md = stage2.sample_markdown(rows)
        self.assertIn("x" * 380 + f" | {FORENSICS_VERSION} |", md)
        self.assertEqual(stage2.summary(db), {"need_more": {"paid": 0, "free": 1}})


if __name__ == "__main__":
    unittest.main(verbosity=1)
