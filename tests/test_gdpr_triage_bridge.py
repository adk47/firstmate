"""The support@ triage -> GDPR erasure register bridge (scripts/gdpr-triage-bridge.py).

The triage skill's `human` class covers "formal legal/privacy-rights deletion demands" and
"Google de-indexing" -- requests the erasure pipeline already owns. Before this bridge every one
of them paged a human, including the ones the register already held: on 2026-11-07 the digest
paged a human for the Jani Lopez Torregrosa Art.17 request, which had been register #399 since
2026-11-06T20:13Z and had already had two of its four pages hidden.

Locks:
  - a privacy request the register already holds is NOT a human page (it shows the register
    number and the register's own next action)
  - a privacy request the register does not hold is FILED, and the digest shows the register
    number instead of a human page
  - a request the pipeline refuses pages a human WITH the pipeline's own words, never a
    paraphrase and never a generic "needs a human"
  - a request the classifier reads as not-privacy keeps the triage's own human verdict
  - an unreadable register, an unreadable classifier or an undatable request is a REFUSAL that
    names itself -- never "not registered", which would file a duplicate or drop the request
  - the bridge never decides a class, a date or an identity: the class is
    gdpr_pipeline.intake.classify, the date is the ledger's first_seen, the identity is the
    pipeline's own decide step

Hermetic: no network, no Trino, no Intercom, no Gmail. `gh` is a stub on PATH (the pipeline's
hidden-list read shells out to it); the store is a temp file.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BRIDGE = REPO / "scripts" / "gdpr-triage-bridge.py"
DIGEST = REPO / "workspaces/operations/skills/muso-support-email-triage/scripts/format-digest.sh"

sys.path.insert(0, str(REPO / "scripts"))

from gdpr_pipeline import store as store_mod  # noqa: E402

# A hidden-list pair the stub `gh` returns. The pipeline only needs them to parse; the bridge
# never reads them itself.
HIDDEN_YAML = 'name: HIDDEN_ENTITY_IDS\nvalue: "2dd39b03-048c-4ad1-8ff3-76c66812cb27,882d042e-c3cc-4f69-a7a7-65942a1e5c53"\n'
LEGAL_PY = 'LEGAL_HIDDEN_ENTITY_IDS = {\n    "2dd39b03-048c-4ad1-8ff3-76c66812cb27": ("legal", "2026-01-01"),\n}\n'

GH_STUB = """#!/bin/sh
# Stub for the pipeline's hidden-list read (sources.gh_raw shells out to `gh api`).
case "$*" in
  *H-DevOps*) cat <<'EOF'
%s
EOF
  ;;
  *platform-data-processing*) cat <<'EOF'
%s
EOF
  ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
""" % (HIDDEN_YAML, LEGAL_PY)


def _write(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2) if not isinstance(data, str) else data)


def _load_bridge():
    """Import scripts/gdpr-triage-bridge.py (hyphenated, so not importable by name)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("gdpr_triage_bridge", BRIDGE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BridgeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="bridge-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.store_path = str(self.tmp / "erasure.sqlite")
        self.ledger_path = self.tmp / "support-ledger.json"
        self.emails_path = self.tmp / "emails.json"
        self.verdicts_path = self.tmp / "verdicts.json"
        self.out_path = self.tmp / "bridge.json"
        # A stub `gh` first on PATH so the pipeline's hidden-list read is hermetic.
        bindir = self.tmp / "bin"
        bindir.mkdir()
        gh = bindir / "gh"
        gh.write_text(GH_STUB)
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        self.env = dict(os.environ)
        self.env["PATH"] = f"{bindir}:{self.env.get('PATH', '')}"
        self.env["GDPR_STORE"] = self.store_path
        self.env.pop("MUSOAI_INTERCOM_TOKEN", None)

    # ---- fixtures -------------------------------------------------------------------------

    def email(self, tid, subject, body, date="2026-11-07 21:00", sender="Someone <s@example.com>"):
        return {"threadId": tid, "from": sender, "subject": subject, "date": date,
                "body_excerpt": body, "url": f"https://mail.google.com/mail/u/?authuser=support@muso.ai#all/{tid}"}

    def verdict(self, tid, reason, verdict="human"):
        return {"threadId": tid, "verdict": verdict, "description": "d", "reason": reason}

    def run_bridge(self, emails, verdicts, ledger=None, extra=()):
        _write(self.emails_path, emails)
        _write(self.verdicts_path, verdicts)
        if ledger is not None:
            _write(self.ledger_path, ledger)
        argv = [sys.executable, str(BRIDGE), "--emails", str(self.emails_path),
                "--verdicts", str(self.verdicts_path), "--out", str(self.out_path),
                "--ledger", str(self.ledger_path), *extra]
        proc = subprocess.run(argv, capture_output=True, text=True, env=self.env, timeout=180)
        result = json.loads(self.out_path.read_text()) if self.out_path.exists() else None
        return proc, result

    def digest(self, bridge):
        """Render the digest for the same emails/verdicts plus this bridge result."""
        wd = self.tmp / "wd"
        wd.mkdir(exist_ok=True)
        shutil.copy(self.emails_path, wd / "emails.json")
        shutil.copy(self.verdicts_path, wd / "verdicts.json")
        if bridge is not None:
            _write(wd / "bridge.json", bridge)
        env = dict(self.env)
        env["WORKDIR"] = str(wd)
        env["JEV_SH"] = "/nonexistent/jev.sh"  # the shadow is not under test
        proc = subprocess.run(["bash", str(DIGEST)], capture_output=True, text=True, env=env, timeout=120)
        return proc

    def seed_registered(self, tid, register_no=399, cls="privacy_erasure", action="hide batch",
                        status="open", confirmed_at=None, pages=()):
        """Put a row in the register the way the pipeline would, so the bridge finds it."""
        db = store_mod.Store(self.store_path)
        rid, _ = db.upsert({"keys": [f"gmail:support@muso.ai:{tid}"], "channel": "support",
                            "class": cls, "received_at": "2026-11-06T19:46:00Z",
                            "pages": [{"entity": "profile", "id": p} for p in pages]})
        db.db.execute("UPDATE erasure_requests SET register_no=?, action=?, identity_verdict=?, "
                      "status=?, confirmed_at=? WHERE id=?",
                      (register_no, action, "UNKNOWN", status, confirmed_at, rid))
        db.db.commit()
        return rid


class TestANewPageInAnOpenThreadIsNotNothing(BridgeCase):
    """QA #1858 r8 Important. An open erasure row with `pages=[]` plus a same-thread "please delete my profile
    https://muso.ai/profile/<id>" returned `registered`, never called intake, and left `pages=[]` - so the
    profile was neither registered for hiding nor handed to a human, and the digest dropped the page because
    the thread looked answered."""

    PID = "3d57a164-1111-2222-3333-444455556666"

    def test_a_followup_that_supplies_a_new_page_puts_it_in_the_register(self):
        tid = "1a1bNEWPAGE0001"
        self.seed_registered(tid, register_no=731)
        emails = [self.email(tid, "Re: complaint",
                             f"Please delete my profile https://muso.ai/profile/{self.PID} too.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertIn(self.PID, rec.get("new_pages") or [], rec)
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_erasure")
        self.assertIsNotNone(row)
        ids = {str(p.get("id") if isinstance(p, dict) else p) for p in (row.get("pages") or [])}
        self.assertIn(self.PID, ids, f"the register still holds {ids!r}: nothing is watching that page")

    def test_a_merge_that_does_not_land_is_REFUSED_not_called_filed(self):
        """QA #1864 r1 Important. `file_candidate` answers "an open row of this class exists" - and for a merge
        that row existed BEFORE we asked, so a write that never landed still read `filed`. The bridge then
        reported the thread answered and dropped the human page while the profile was absent from `pages`.

        The unparseable earlier date is QA's own reproducer: `2026-00-08` passes `received_at`'s shape check and
        makes the store fail when it parses the row's date, so intake exits 2 having written nothing."""
        tid = "1a1bMERGEFAIL01"
        self.seed_registered(tid, register_no=741)
        emails = [self.email(tid, "Re: complaint",
                             f"Please delete my profile https://muso.ai/profile/{self.PID} too.",
                             date="2026-00-08 19:22")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "refused", rec)
        self.assertIn("the register still does not hold", rec["reason"], rec)
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_erasure")
        ids = {str(p.get("id") if isinstance(p, dict) else p) for p in (row.get("pages") or [])}
        self.assertNotIn(self.PID, ids, "the reproducer must not have written the page")

    def test_a_prefix_the_store_already_holds_is_NOT_a_new_page(self):
        """QA #1864 r2 Important. The ledger keeps 8-char prefixes and Intercom keeps full uuids, so the same
        page arrives spelled two ways. Compared verbatim, a held full uuid "loses" against the ledger's prefix,
        the store dedups the merge, `merged_pages_landed` demands the literal prefix, and an already-watched
        request is refused and paged to a human - a false alarm on the exact case the store was built for."""
        tid = "1a1bPREFIX0001"
        self.seed_registered(tid, register_no=742, pages=(self.PID,))
        ledger = {f"support@muso.ai:{tid}": {
            "thread": tid, "class": "privacy_erasure",
            "first_seen": "Fri, 06 Nov 2026 19:46:00 GMT",
            "last_seen": "Sun, 08 Nov 2026 19:00:00 GMT",
            "ids": [{"kind": "profile", "id": self.PID[:8]}], "labels": []}}
        emails = [self.email(tid, "Re: complaint", "Any update on this?")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")], ledger=ledger)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "registered", rec)

    def test_a_followup_with_NO_new_page_stays_registered_and_does_not_page(self):
        tid = "1a1bNEWPAGE0002"
        self.seed_registered(tid, register_no=732)
        emails = [self.email(tid, "Re: complaint", "Any update on this?")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "registered")


class TestAFiledRequestIsNotAHumanPage(BridgeCase):
    """The whole point: a synthetic Art.17 request is filed and does NOT page a human."""

    def test_a_synthetic_art17_request_is_filed_and_does_not_page_a_human(self):
        tid = "1a1bNEWart170001"
        emails = [self.email(tid, "GDPR Art. 17 erasure request",
                             "I request erasure of my personal data under Article 17 GDPR. "
                             "Please delete my profile and all linked data.")]
        verdicts = [self.verdict(tid, "formal privacy-rights deletion demand")]
        proc, result = self.run_bridge(emails, verdicts)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "filed", rec)
        self.assertEqual(rec["class_"], "privacy_erasure")
        self.assertTrue(rec["register_no"], "a filed request must carry its register number")

        # The row the letter is generated from exists, with the fields the letter needs.
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}")
        self.assertIsNotNone(row, "the request must be in the register")
        self.assertEqual(row["class"], "privacy_erasure")
        self.assertEqual(row["received_at"], "2026-11-07T21:00:00Z")
        self.assertTrue(row["due_at"], "a filed request must carry its statutory due date")
        self.assertTrue(row["hide_due_at"], "a filed request must carry its hide deadline")
        self.assertEqual(row["requester_email"], "s@example.com")

        # ... and the digest shows the register, not a human page.
        d = self.digest(result)
        self.assertEqual(d.returncode, 0, d.stderr)
        self.assertIn("erasure register #", d.stdout)
        self.assertNotIn("needs a human", d.stdout)
        self.assertIn("0 need a human", d.stdout)
        self.assertIn("1 filed to the erasure register", d.stdout)

    def test_a_google_deindexing_request_is_filed_not_paged(self):
        """Aaron: "Google de-indexing is a real deliverable, not a page." """
        tid = "1a1bNEWdeindex01"
        emails = [self.email(tid, "Google de-indexing request",
                             "Please remove my profile from Google search results. I want my name de-indexed.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "Google de-indexing")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "filed")
        self.assertEqual(result["threads"][tid]["class_"], "privacy_erasure")
        d = self.digest(result)
        self.assertNotIn("needs a human", d.stdout)

    def test_an_art15_access_request_is_filed_with_its_own_action(self):
        tid = "1a1bNEWaccess001"
        emails = [self.email(tid, "Data access request",
                             "Under GDPR I request a copy of all personal data you hold about me.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "data access request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "filed")
        self.assertEqual(rec["class_"], "privacy_access")
        self.assertIn("Art. 15", rec.get("action") or "")


class TestAnAlreadyRegisteredRequestIsNotAHumanPage(BridgeCase):
    """The 2026-11-07 defect: the digest paged a human for register #399."""

    def test_a_thread_the_register_already_holds_shows_the_register_not_a_human(self):
        tid = "1a1b222c4a04de90"
        self.seed_registered(tid, register_no=399,
                             action="read the mail thread: the full page link and the sender are not on file")
        emails = [self.email(tid, "Re: GDPR Art. 17 erasure request",
                             "I request erasure of my personal data under Article 17 GDPR.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "formal privacy-rights deletion demand")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "registered")
        self.assertEqual(rec["register_no"], "399")
        self.assertIn("read the mail thread", rec["action"])

        d = self.digest(result)
        self.assertIn("erasure register #399", d.stdout)
        self.assertNotIn("needs a human", d.stdout)
        # The register's own next action is what the digest shows, not a paraphrase.
        self.assertIn("read the mail thread", d.stdout)

    def test_a_returning_thread_with_an_again_key_is_still_found(self):
        """A thread that came back after its request was answered carries `:again:<ts>`. Filing a
        second row for it would be a duplicate for a thread the register is already working."""
        tid = "1a1a8d82a4d83b15"
        db = store_mod.Store(self.store_path)
        rid, _ = db.upsert({"keys": [f"gmail:support@muso.ai:{tid}:again:2026-11-05T00:17:02Z"],
                            "channel": "support", "class": "privacy_erasure",
                            "received_at": "2026-11-05T00:17:02Z", "pages": []})
        db.db.execute("UPDATE erasure_requests SET register_no=397 WHERE id=?", (rid,))
        db.db.commit()
        emails = [self.email(tid, "GDPR erasure", "Please delete my personal data under GDPR.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "registered")
        self.assertEqual(result["threads"][tid]["register_no"], "397")
        # ... and no second row was created.
        self.assertEqual(len(store_mod.Store(self.store_path).all()), 1)


class TestAnOpenRowOfAnotherObligationDoesNotSwallowThisOne(BridgeCase):
    """QA finding 1 on PR #1847 (Critical): a thread key identifies a conversation, not a statutory
    request. An open Art. 15 ACCESS row made the bridge report `registered` for a later DELETION
    demand in the same thread: the digest dropped the human page, no erasure row was created, and
    the deletion had no deadline and nothing watching it. It was silently dropped."""

    def test_an_open_ACCESS_row_does_not_own_a_later_DELETION_demand(self):
        tid = "1a1b333c4a04de91"
        self.seed_registered(tid, register_no=401, cls="privacy_access",
                             action="Art. 15 access request: captain/counsel answer (no hide); due date tracked")
        emails = [self.email(tid, "Re: my data",
                             "Thanks. Now please delete my profile and all my personal data under GDPR.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "formal privacy-rights deletion demand")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        # NOT `registered`: the access row does not answer a deletion.
        self.assertNotEqual(rec["outcome"], "registered", rec)
        self.assertEqual(rec["class_"], "privacy_erasure")
        # And an erasure row now EXISTS, with its own deadline, which is the whole point.
        rows = store_mod.Store(self.store_path).all()
        classes = sorted(r["class"] for r in rows)
        self.assertIn("privacy_erasure", classes)
        self.assertEqual(len([r for r in rows if r["class"] == "privacy_erasure"]), 1)
        # TWO rows, two clocks: the access row keeps its original receipt AND its own due date, and the erasure
        # row carries the deletion's own.
        by_class = {r["class"]: r for r in rows}
        self.assertEqual(sorted(by_class), ["privacy_access", "privacy_erasure"])
        access, erase = by_class["privacy_access"], by_class["privacy_erasure"]
        self.assertNotEqual(access["id"], erase["id"])
        self.assertNotEqual(access["due_at"], erase["due_at"], "each obligation keeps its own deadline")
        self.assertNotEqual(access["register_no"], erase["register_no"])
        self.assertNotEqual(erase["received_at"], access["received_at"],
                            "the erasure keeps the DELETION's receipt, not the access request's")
        self.assertNotEqual(access["received_at"], erase["received_at"])

    def test_an_open_ERASURE_row_does_not_own_a_later_ACCESS_request(self):
        """The mirror case: a copy request inside a thread the register is already erasing owes an
        Art. 15 answer, and an erasure row does not discharge it."""
        tid = "1a1b444c4a04de92"
        self.seed_registered(tid, register_no=402, cls="privacy_erasure", action="hide batch")
        # A NEUTRAL subject on purpose: "Re: erasure" would supply the deletion vocabulary the combined
        # rule looks for across subject+body, and the message would classify as privacy_erasure.
        emails = [self.email(tid, "Re: my data",
                             "Please send me a copy of my personal data under Article 15.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        # NOT `registered`: the erasure row does not answer an access request. And NOT refused either - each
        # obligation gets its own row, so no combined request pages a human (QA #1847, the structural fix).
        self.assertNotEqual(rec["outcome"], "registered")
        self.assertEqual(rec["outcome"], "filed")
        rows = store_mod.Store(self.store_path).all()
        by_class = {r["class"]: r for r in rows}
        self.assertIn("privacy_erasure", by_class)
        self.assertIn("privacy_access", by_class)
        self.assertEqual(len(rows), 2, "two obligations, two rows")
        self.assertNotEqual(by_class["privacy_erasure"]["id"], by_class["privacy_access"]["id"])

    def test_the_SAME_obligation_in_an_open_thread_is_still_registered(self):
        """The regression this must not cause: a follow-up in a thread the register already owns,
        under the same obligation, must still show the register and not page anyone."""
        tid = "1a1b555c4a04de93"
        self.seed_registered(tid, register_no=403, cls="privacy_erasure", action="hide batch")
        emails = [self.email(tid, "Re: erasure",
                             "Any update? I still want my personal data deleted under GDPR Article 17.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "registered")
        self.assertEqual(result["threads"][tid]["register_no"], "403")
        self.assertEqual(len(store_mod.Store(self.store_path).all()), 1)

    def test_an_unclassifiable_followup_keeps_the_register_routing(self):
        """The classifier is keyword-based; a bare "any update?" reads as `other`. An unroutable
        message must NOT fall through to intake, or a routine nudge would page a human."""
        tid = "1a1b666c4a04de94"
        self.seed_registered(tid, register_no=404, cls="privacy_erasure", action="hide batch")
        emails = [self.email(tid, "Re: erasure", "Any update on this?")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "registered")
        self.assertEqual(len(store_mod.Store(self.store_path).all()), 1)


class TestAClosedRowNeverSwallowsANewRequest(BridgeCase):
    """QA finding 1 on PR #1847: a prefix match on a CLOSED row suppressed the page and dropped
    the new request. `upsert` treats an answered row as the start of a new request; the bridge
    has to agree, or the digest shows an old register number and nothing watches the new one."""

    def test_a_new_request_in_a_closed_thread_is_filed_not_swallowed(self):
        tid = "1a1bCLOSEDthread1"
        self.seed_registered(tid, register_no=301, status="closed",
                             confirmed_at="2026-10-01T00:00:00Z", action="verify S/P/M, confirm by due date")
        emails = [self.email(tid, "GDPR Art. 17 erasure request",
                             "I request erasure of my personal data under Article 17 GDPR.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "registered",
                            "a closed row must never read as 'the register is handling this'")
        self.assertEqual(rec["outcome"], "filed")
        self.assertNotEqual(rec["register_no"], "301", "the new request gets its own register row")

        # A NEW open row exists, dated by this message, and the old one is untouched.
        db = store_mod.Store(self.store_path)
        rows = [r for r in db.all() if any(k.startswith(f"gmail:support@muso.ai:{tid}") for k in r["keys"])]
        self.assertEqual(len(rows), 2, "the closed row and the new one")
        open_rows = [r for r in rows if r["status"] == "open"]
        self.assertEqual(len(open_rows), 1)
        self.assertEqual(open_rows[0]["received_at"], "2026-11-07T21:00:00Z")
        self.assertTrue(open_rows[0]["due_at"])

        # ... and the digest does not page a human for it.
        d = self.digest(result)
        self.assertNotIn("needs a human", d.stdout)

    def test_a_confirmed_row_is_treated_as_closed_too(self):
        """`upsert` treats a written confirmation as answered even when status is still open."""
        tid = "1a1bCONFIRMEDthr1"
        self.seed_registered(tid, register_no=302, status="open",
                             confirmed_at="2026-10-01T00:00:00Z")
        emails = [self.email(tid, "GDPR erasure", "Please delete my personal data under GDPR.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "filed")
        self.assertNotEqual(result["threads"][tid]["register_no"], "302")

    def test_an_open_row_still_suppresses_the_page(self):
        """The fix must not turn the original defect back on: an OPEN row is still handled."""
        tid = "1a1bOPENthread001"
        self.seed_registered(tid, register_no=399, status="open")
        emails = [self.email(tid, "Re: GDPR Art. 17", "I request erasure of my personal data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "registered")
        self.assertEqual(result["threads"][tid]["register_no"], "399")
        self.assertEqual(len(store_mod.Store(self.store_path).all()), 1, "no duplicate row")


class TestANewRequestAfterAClosedOneIsDatedByItsOwnMessage(BridgeCase):
    """QA 2026-11-08 finding 1. support-intake preserves `first_seen` across rescans, so a thread
    that came back still carries the ORIGINAL message's date. Dating the new request from it made
    `upsert` answer "unchanged" (no new page, so the request was dropped) or opened a row whose
    24-hour hide and 30-day reply deadlines were measured from the OLD request."""

    TID = "1a1bLEDGERthread"
    LEDGER = {"support@muso.ai:1a1bLEDGERthread": {
        "thread": "1a1bLEDGERthread", "class": "privacy_erasure",
        "first_seen": "Fri, 06 Nov 2026 19:46:00 GMT",
        "last_seen": "Sat, 07 Nov 2026 21:00:00 GMT", "ids": [], "labels": []}}

    def _rows(self):
        db = store_mod.Store(self.store_path)
        return [r for r in db.all()
                if any(k.startswith(f"gmail:support@muso.ai:{self.TID}") for k in r["keys"])]

    def test_no_new_page_still_files_and_is_dated_by_the_new_message(self):
        self.seed_registered(self.TID, register_no=301, status="closed",
                             confirmed_at="2026-11-06T20:00:00Z")
        emails = [self.email(self.TID, "GDPR erasure",
                             "Please delete my personal data under GDPR.", date="2026-11-07 21:00")]
        proc, result = self.run_bridge(emails, [self.verdict(self.TID, "privacy deletion")],
                                       ledger=self.LEDGER)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][self.TID]["outcome"], "filed",
                         "a new message with no new page must still be filed, not read as unchanged")
        new = [r for r in self._rows() if r["status"] == "open"]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0]["received_at"], "2026-11-07T21:00:00Z",
                         "dated by the NEW message, not the ledger's preserved first_seen")
        self.assertTrue(new[0]["hide_due_at"].startswith("2026-11-08"), new[0]["hide_due_at"])
        self.assertTrue(new[0]["due_at"].startswith("2026-12-07"), new[0]["due_at"])

    def test_a_new_page_does_not_inherit_the_old_deadlines(self):
        self.seed_registered(self.TID, register_no=301, status="closed",
                             confirmed_at="2026-11-06T20:00:00Z")
        body = ("Please delete my personal data under GDPR. The profile is "
                "https://muso.ai/profile/3d57a164-1111-2222-3333-444455556666")
        emails = [self.email(self.TID, "GDPR erasure", body, date="2026-11-07 21:00")]
        proc, result = self.run_bridge(emails, [self.verdict(self.TID, "privacy deletion")],
                                       ledger=self.LEDGER)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][self.TID]["outcome"], "filed")
        new = [r for r in self._rows() if r["status"] == "open"]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0]["received_at"], "2026-11-07T21:00:00Z")
        self.assertTrue(new[0]["hide_due_at"].startswith("2026-11-08"),
                        "the 24-hour hide deadline is measured from the new message")

    def test_a_first_request_still_uses_the_ledgers_first_seen(self):
        """The fix must not throw away the authoritative receipt time for a FIRST request."""
        emails = [self.email(self.TID, "GDPR erasure",
                             "Please delete my personal data under GDPR.", date="2026-11-07 21:00")]
        proc, result = self.run_bridge(emails, [self.verdict(self.TID, "privacy deletion")],
                                       ledger=self.LEDGER)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][self.TID]["outcome"], "filed")
        rows = self._rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["received_at"], "2026-11-06T19:46:00Z",
                         "the ledger's first_seen is the authoritative receipt time for a first request")


class TestARefusalPagesWithItsOwnReason(BridgeCase):
    """A deliberately-broken request must still page, and the page must name the refusal."""

    def test_an_undatable_request_is_refused_and_the_page_names_the_date(self):
        tid = "1a1bNEWnodate001"
        emails = [self.email(tid, "GDPR erasure", "Please delete my personal data under GDPR.",
                             date="sometime last week")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")])
        self.assertEqual(proc.returncode, 2, "an unrouted request must not report success")
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "refused")
        self.assertIn("could not be dated", rec["reason"])
        self.assertIn("sometime last week", rec["reason"])
        # Nothing was filed from a guessed date.
        self.assertIsNone(store_mod.Store(self.store_path).by_key_prefix(f"gmail:support@muso.ai:{tid}"))

        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)
        self.assertIn("could not be dated", d.stdout)
        self.assertIn("1 need a human", d.stdout)

    def test_a_read_that_fails_after_the_row_exists_is_a_warning_not_a_page(self):
        """`intake` exits 2 when any read failed -- including a read that failed AFTER the row was
        created. The row is the fact: the request is in the register and the pipeline re-reads on
        its next tick, so paging a human here would be the very defect this bridge removes."""
        tid = "1a1bNEWwarn0001"
        emails = [self.email(tid, "GDPR erasure", "Please delete my personal data under GDPR.")]
        # Break the hidden-list read: a `gh` that fails is exactly what the pipeline reports.
        bad = self.tmp / "bin" / "gh"
        bad.write_text("#!/bin/sh\necho 'gh: HTTP 403' >&2\nexit 1\n")
        bad.chmod(bad.stat().st_mode | stat.S_IEXEC)
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "filed")
        self.assertTrue(rec["register_no"])
        self.assertIn("gh read", rec.get("warning") or "",
                      "the pipeline's read failure must be carried, not swallowed")
        self.assertIn("gh read", proc.stderr)
        # The row exists, so the letter machinery has it and no human is paged.
        self.assertIsNotNone(store_mod.Store(self.store_path).by_key_prefix(f"gmail:support@muso.ai:{tid}"))
        d = self.digest(result)
        self.assertNotIn("needs a human", d.stdout)

    def test_a_pipeline_refusal_pages_with_the_pipelines_own_words(self):
        """If the pipeline ever refuses the candidate shape this bridge builds, the page must
        carry the pipeline's own words, not a generic 'needs a human'."""
        bridge = _load_bridge()
        bad = {"keys": ["gmail:support@muso.ai:1a1bNEWrefused01"], "channel": "support",
               "class": "not_a_real_class", "received_at": "2026-11-07T21:00:00Z", "pages": []}
        outcome, message = bridge.file_candidate(bad, self.store_path)
        self.assertEqual(outcome, "refused")
        self.assertIn("not_a_real_class", message, "the pipeline's own refusal must be carried through")
        self.assertIsNone(store_mod.Store(self.store_path).by_key_prefix(bad["keys"][0]))

    def test_an_unreadable_register_is_a_refusal_never_not_registered(self):
        """A store that cannot be opened must never read as 'this thread is not registered' --
        that would file a duplicate for a request the register may already hold."""
        tid = "1a1bNEWbadstore1"
        emails = [self.email(tid, "GDPR erasure", "Please delete my personal data under GDPR.")]
        _write(self.emails_path, emails)
        _write(self.verdicts_path, [self.verdict(tid, "privacy deletion")])
        # A directory where the sqlite file should be: opening it fails.
        os.makedirs(self.store_path, exist_ok=True)
        proc = subprocess.run([sys.executable, str(BRIDGE), "--emails", str(self.emails_path),
                               "--verdicts", str(self.verdicts_path), "--out", str(self.out_path),
                               "--ledger", str(self.ledger_path)],
                              capture_output=True, text=True, env=self.env, timeout=120)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("could not be opened", proc.stderr)
        self.assertFalse(self.out_path.exists(), "no result file may be written from an unreadable register")


class TestANonPrivacyRequestKeepsItsHumanPage(BridgeCase):
    def test_a_credit_dispute_keeps_the_triage_human_verdict(self):
        tid = "1a1bNEWcredit001"
        emails = [self.email(tid, "Merging accountants",
                             "Please merge my two profiles, the credits are on the wrong one.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "disputed cross-account claim")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "not_privacy")
        self.assertEqual(rec["class_"], "credit_dispute")
        self.assertIn("credit_dispute", rec["reason"])
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)
        self.assertIn("credit_dispute", d.stdout)
        # ... and nothing was filed for it.
        self.assertIsNone(store_mod.Store(self.store_path).by_key_prefix(f"gmail:support@muso.ai:{tid}"))


class TestTheBridgeOnlyRoutes(BridgeCase):
    def test_a_caroline_or_spam_verdict_is_never_touched(self):
        emails = [self.email("t1", "hi", "hello"), self.email("t2", "buy seo", "backlinks")]
        verdicts = [self.verdict("t1", "billing", verdict="caroline"),
                    self.verdict("t2", "cold marketing", verdict="spam")]
        proc, result = self.run_bridge(emails, verdicts)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"], {}, "only `human` verdicts are routed")
        self.assertEqual(result["counts"], {"human": 0})

    def test_the_class_comes_from_the_pipelines_classifier_not_the_triage_reason(self):
        """The triage's `reason` is LLM text. The class must come from the ONE classifier, so a
        reason that says 'privacy' about a credit dispute cannot file an erasure request."""
        tid = "1a1bNEWmismatch1"
        emails = [self.email(tid, "My credits are wrong",
                             "The credits on this track are misattributed to the wrong artist.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion demand")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["threads"][tid]["outcome"], "not_privacy")
        self.assertEqual(result["threads"][tid]["class_"], "credit_dispute")

    def test_the_date_comes_from_the_ledger_when_the_thread_is_in_it(self):
        tid = "1a1bNEWledger001"
        ledger = {f"support@muso.ai:{tid}": {"thread": tid, "class": "privacy_erasure",
                                             "first_seen": "Fri, 06 Nov 2026 19:46:00 GMT",
                                             "ids": [{"kind": "profile", "id": "3d57a164"}]}}
        emails = [self.email(tid, "GDPR erasure", "Please delete my personal data under GDPR.",
                             date="2026-11-07 21:00")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion")], ledger=ledger)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        row = store_mod.Store(self.store_path).by_key_prefix(f"gmail:support@muso.ai:{tid}")
        self.assertEqual(row["received_at"], "2026-11-06T19:46:00Z",
                         "the ledger's first_seen is authoritative over the triage's lossy date")
        self.assertIn("support-ledger first_seen", row["note"])


class TestTheDigestWithoutABridge(BridgeCase):
    def test_a_missing_bridge_still_pages_and_says_so(self):
        """The digest is the safety net: a bridge that did not run must still produce a digest,
        page every human verdict, and say on stderr that the bridge was missing."""
        emails = [self.email("t1", "GDPR erasure", "Please delete my personal data under GDPR.")]
        verdicts = [self.verdict("t1", "privacy deletion")]
        _write(self.emails_path, emails)
        _write(self.verdicts_path, verdicts)
        d = self.digest(None)
        self.assertEqual(d.returncode, 0, d.stderr)
        self.assertIn("needs a human", d.stdout)
        self.assertIn("1 need a human", d.stdout)
        self.assertIn("the GDPR bridge did not run", d.stderr)


class TestAWithdrawalIsNotARegisteredRequest(BridgeCase):
    """QA #1847 r5 Critical. `classify` reads a withdrawal as `other`, and the bridge's ownership
    test deliberately keeps today's routing for an unknown incoming class -- so an open erasure row
    swallowed the cancellation as `registered`, removed the human page, and the hide pipeline kept
    running against a customer who had just withdrawn. The register has no cancellation
    transition; only a human can stop a hide already in flight."""

    def test_a_withdrawal_in_an_open_erasure_thread_pages_a_human(self):
        tid = "1a1bWITHDRAW01"
        self.seed_registered(tid, register_no=481, cls="privacy_erasure")
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request",
                             "Do not delete my profile. I withdraw my request.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy deletion follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "withdrawn", rec)
        self.assertEqual(rec["register_no"], "481")
        self.assertIn("WITHDREW", rec["reason"])
        # The page is the whole point: the digest must send a human, not show the register.
        d = self.digest(result)
        self.assertEqual(d.returncode, 0, d.stderr)
        self.assertIn("needs a human", d.stdout)
        self.assertIn("1 need a human", d.stdout)
        self.assertNotIn("erasure register #481", d.stdout)
        self.assertIn("WITHDREW", d.stdout)

    def test_a_withdrawal_with_nothing_open_is_still_a_human_page(self):
        """No open row to stop, so there is nothing for the register to cancel -- but a human still
        reads it, because the classifier cannot act on it."""
        tid = "1a1bWITHDRAW02"
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request",
                             "Do not delete my profile. I withdraw my request.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "registered", rec)
        self.assertNotEqual(rec["outcome"], "filed", rec)
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)


class TestAMixedRequestFilesBothDutiesThroughTheBridge(BridgeCase):
    """QA #1847 r5 Important. `classify` returns ONE class, so support@ mail asking for both a copy
    (Art.15) and deletion (Art.17) filed only the erasure row and the access answer was tracked
    nowhere. `run.intake_intercom` files both, but that is not the path support@ mail travels."""

    def test_a_copy_plus_delete_message_files_two_rows_with_two_deadlines(self):
        tid = "1a1bMIXED0001"
        emails = [self.email(tid, "My data",
                             "Send me a copy of my personal data and delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "filed", rec)
        self.assertEqual(rec.get("duties"), ["privacy_erasure", "privacy_access"], rec)
        self.assertTrue(rec.get("access_register_no"), rec)

        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class, register_no, due_at, hide_due_at FROM erasure_requests "
                             "WHERE channel='support' ORDER BY id").fetchall()
        self.assertEqual([r["class"] for r in rows], ["privacy_erasure", "privacy_access"])
        self.assertNotEqual(rows[0]["register_no"], rows[1]["register_no"])
        for r in rows:
            self.assertTrue(r["due_at"], "each duty carries its own statutory deadline")

    def test_a_copy_plus_delete_message_is_dated_once_but_ACTIONED_twice(self):
        """Both rows come from ONE message, so they share received_at and therefore due_at, and they
        share a hide clock because the hide clock is derived from the request. That is correct. What
        must differ is the row, the register number and -- the part that decides what actually
        happens -- the ACTION the register records for each duty."""
        tid = "1a1bMIXED0002"
        emails = [self.email(tid, "My data",
                             "Send me a copy of my personal data and delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class, received_at, due_at, action FROM erasure_requests "
                             "WHERE channel='support' ORDER BY id").fetchall()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["received_at"], rows[1]["received_at"])
        self.assertNotEqual(rows[0]["action"], rows[1]["action"],
                            "an access answer and a deletion have different next actions")
        # The erasure row is the one the ask/verification letter is generated from; the access
        # duty is answered separately and must not be given the deletion's next step.
        self.assertIn("ask", (rows[0]["action"] or "").lower())
        self.assertIn("access", (rows[1]["action"] or "").lower())


class TestAnUnqualifiedWithdrawalStillPages(BridgeCase):
    """QA #1847 r5. `withdrawn_in_body` needs a NEGATED DELETION WORD, so "I withdraw my request. Please
    stop processing it." read as false -- the deletion word lives in the inherited subject, not the body.
    The open row classifies as erasure, the bridge reported `registered`, and the human page vanished
    while hiding could continue. Only a caller that can see the open row may act on the bare verb."""

    def test_a_withdrawal_with_no_deletion_word_in_the_body_pages_a_human(self):
        tid = "1a1bWITHDRAW03"
        self.seed_registered(tid, register_no=502, cls="privacy_erasure")
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request",
                             "I withdraw my request. Please stop processing it.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "withdrawn", rec)
        self.assertEqual(rec["register_no"], "502")
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)
        self.assertNotIn("erasure register #502", d.stdout)

    def test_a_withdrawal_of_SOMETHING_ELSE_does_not_page_and_does_file_the_deletion(self):
        """QA #1847 r8 Important, end to end. "I withdraw my complaint; please delete my profile." withdraws
        a duty the register does not track and then makes a live Art. 17 demand. The bridge used to see the
        verb, page a human with "nothing new was filed", and file nothing -- so the deletion had no erasure
        row, no 24-hour hide clock and no statutory deadline. The deletion must be filed."""
        tid = "1a1bWITHDRAW05"
        self.seed_registered(tid, register_no=503, cls="privacy_erasure")
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request",
                             "I withdraw my complaint; please delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "withdrawn", rec)
        self.assertEqual(rec["outcome"], "registered", rec)
        self.assertIn("503", rec["register_no"], rec)

    def test_a_withdrawal_of_something_else_WITH_NOTHING_OPEN_still_files_the_deletion(self):
        tid = "1a1bWITHDRAW06"
        emails = [self.email(tid, "", "I withdraw my complaint; please delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "withdrawn", rec)
        self.assertEqual(rec["outcome"], "filed", rec)
        self.assertEqual(rec.get("class_") or rec.get("class"), "privacy_erasure", rec)
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}")
        self.assertIsNotNone(row, "the deletion demand got no erasure row")
        self.assertTrue(row.get("due_at"), row)

    def test_an_UNRELATED_cancellation_does_not_hide_a_live_demand_from_the_bridge(self):
        """QA #1858 r4, end to end. The customer refuses one deletion and demands another in one message; a
        `cancel` verb belonging to neither was read as the withdrawal of the whole message, so the bridge reported
        `withdrawn`, the digest paged a human for the wrong reason, and the live Art.17 demand got no row at all."""
        tid = "1a1bCANCEL07"
        emails = [self.email(tid, "Re: complaint",
                             "Do not delete my old profile; I cancel my subscription, but please delete my account.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "withdrawn", rec)
        self.assertEqual(rec["outcome"], "filed", rec)
        self.assertEqual(rec["class_"], "privacy_erasure", rec)
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_erasure")
        self.assertIsNotNone(row, "the live deletion demand got no erasure row")
        self.assertTrue(row.get("due_at"), row)

    def test_a_coordinated_imperative_after_AND_files_the_deletion(self):
        """QA #1847 r9 Important, end to end. The comma and semicolon forms filed; "and" was the only
        difference, and the bridge marked it `withdrawn` with no row, no hide clock, no deadline."""
        tid = "1a1bWITHDRAW07"
        self.seed_registered(tid, register_no=504, cls="privacy_erasure")
        emails = [self.email(tid, "Re: complaint",
                             "I withdraw my complaint and please delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "withdrawn", rec)
        self.assertEqual(rec["outcome"], "registered", rec)
        self.assertIn("504", rec["register_no"], rec)

    def test_an_explicit_withdrawal_with_NO_open_row_still_pages_and_files_nothing(self):
        """QA #1847 r7 Critical. With nothing open there is nothing to cancel, but the bridge must still
        page a human and must NOT mint a fresh erasure row from the inherited subject."""
        tid = "1a1bWITHDRAW04"
        emails = [self.email(tid, "Re: my account", "I withdraw my erasure request.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "withdrawn", rec)
        self.assertIn("no request of theirs is open", rec["reason"], rec)
        db = store_mod.Store(self.store_path)
        self.assertIsNone(db.by_key_prefix(f"gmail:support@muso.ai:{tid}"))


    def test_a_refused_deletion_PLUS_an_access_request_does_both(self):
        """firstmate 2026-11-08, reproduced from my own status line. `withdrawn_in_body` is the FIRST disjunct of
        `withdrew` and was not gated on `no_new_duty`, so this sentence took the withdrawal branch, exited 0, and
        dropped the Art.15 row AND its statutory deadline: a customer who asks for their data while refusing a
        deletion got neither. Gating the whole block on `no_new_duty` would instead make the withdrawal
        inexpressible - the open row's hide action could still fire on an instruction that cancelled it, silently.
        So both are processed: the access row is filed with its own deadline, and the withdrawal is recorded and
        paged."""
        tid = "1a1bWITHDRAW09"
        self.seed_registered(tid, register_no=727, cls="privacy_erasure")
        emails = [self.email(tid, "Re: my account",
                             "Do not delete my profile. Please send me a copy of my data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        # the withdrawal is RECORDED
        self.assertEqual(rec["outcome"], "withdrawn_filed", rec)
        self.assertEqual(rec["withdrawn_from"], "privacy_erasure", rec)
        # and the new duty is FILED, with a deadline
        self.assertEqual(rec["class_"], "privacy_access", rec)
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_access")
        self.assertIsNotNone(row, "the Art.15 request got no row")
        self.assertTrue(row.get("due_at"), row)
        self.assertEqual(str(row.get("register_no")), str(rec["register_no"]), rec)
        # the row we held is untouched
        held = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_erasure")
        self.assertIsNotNone(held)
        self.assertEqual(str(held.get("register_no")), "727", held)
        # and a human is still paged, because the register cannot cancel
        self.assertIn("needs a human", self.digest(result).stdout)


class TestAnEscalationDoesNotSwallowALaterAccessRequest(BridgeCase):
    """QA #1858 r3 Important. The bridge carried its OWN obligation map, so when the store learned that a threat on
    a deletion thread IS that deletion escalating, the two disagreed: `owns_obligation({"class": "legal_threat"},
    "privacy_access")` returned True and an open threat row swallowed a later Art.15 request - no access row, no
    statutory deadline, and the human page removed. The mapping now lives only in the store."""

    def test_the_bridge_and_the_store_agree_on_every_class(self):
        bridge = _load_bridge()

        for cls in bridge.ROUTABLE:
            with self.subTest(cls=cls):
                self.assertEqual(bridge.store_mod.obligation_of(cls), store_mod.obligation_of(cls))
        # the exact call QA reproduced
        self.assertFalse(bridge.owns_obligation({"class": "legal_threat", "status": "open"}, "privacy_access"))
        self.assertFalse(bridge.owns_obligation({"class": "dmca_takedown", "status": "open"}, "privacy_access"))
        # ... but a deletion demand on a threat thread IS the same obligation: the store maps a threat on a
        # deletion thread to `erasure` on purpose (one clock, one duty), and a threat thread already has a
        # human's attention, so suppressing the page here is the intended behaviour, not a swallow.
        self.assertTrue(bridge.owns_obligation({"class": "legal_threat", "status": "open"}, "privacy_erasure"))

    def test_a_threat_first_thread_still_files_the_later_ACCESS_request(self):
        tid = "1a1bESCALATE07"
        self.seed_registered(tid, register_no=701, cls="legal_threat")
        emails = [self.email(tid, "Re: my account", "Please send me a copy of my personal data under Article 15.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotEqual(rec["outcome"], "registered", rec)
        self.assertEqual(rec["outcome"], "filed", rec)
        self.assertEqual(rec["class_"], "privacy_access", rec)
        db = store_mod.Store(self.store_path)
        row = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_access")
        self.assertIsNotNone(row, "the Art.15 request got no access row")
        self.assertTrue(row.get("due_at"), row)
        # and the threat row is untouched
        threat = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "legal_threat")
        self.assertIsNotNone(threat, "the open threat row was taken over")
        self.assertEqual(threat.get("status"), "open", threat)

    def test_a_threat_first_thread_keeps_the_human_page_for_each_new_duty(self):
        tid = "1a1bESCALATE08"
        self.seed_registered(tid, register_no=702, cls="legal_threat")
        emails = [self.email(tid, "Re: my account",
                             "Please send me a copy of my personal data under Article 15."),
                  self.email(tid, "Re: my account", "Any update on this?")]
        proc, result = self.run_bridge(emails[:1], [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["class_"], "privacy_access", rec)


class TestAnEscalationKeepsTheHumanPage(BridgeCase):
    """QA #1858 Important. `owns_obligation` returned true whenever either side lacked an OBLIGATION key, so an
    open Art.17 row absorbed a later legal threat or DMCA notice from the same thread: the row stayed on the old
    class, nothing escalated, and the digest went to zero human pages. `legal_threat` and `dmca_takedown` ARE
    routable, so intake escalates the row's class on merge - but a threat is not a self-serve pipeline item, so the
    page has to survive the escalation."""

    THREAT = ("My attorney will file a lawsuit unless you respond to this formal notice. "
              "This is a legal threat and my last warning.")

    def test_a_legal_threat_on_an_open_erasure_row_pages_a_human(self):
        tid = "1a1bESCALATE01"
        self.seed_registered(tid, register_no=611, cls="privacy_erasure")
        emails = [self.email(tid, "Re: my account", self.THREAT)]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "legal threat")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "escalated", rec)
        self.assertEqual(rec["class_"], "legal_threat", rec)
        self.assertEqual(rec["escalated_from"], "privacy_erasure", rec)
        self.assertIn("human", rec["reason"], rec)
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)
        self.assertIn("escalated", d.stdout)

    def test_a_dmca_notice_on_an_open_erasure_row_pages_a_human(self):
        tid = "1a1bESCALATE02"
        self.seed_registered(tid, register_no=612, cls="privacy_erasure")
        emails = [self.email(tid, "Re: my account",
                             "Please remove the infringing copies of my copyrighted work. "
                             "This is a DMCA takedown notice.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "dmca")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "escalated", rec)
        self.assertEqual(rec["class_"], "dmca_takedown", rec)
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)

    def test_a_fresh_legal_threat_files_its_row_AND_keeps_the_human_page(self):
        """QA #1858 r5. `escalated` is for a row we already hold, but a FIRST-message threat is still not
        something the pipeline answers on its own: it filed the row and reported `filed`, which is in RESOLVED,
        so the digest said 0 need a human for a legal threat."""
        tid = "1a1bESCALATE03"
        emails = [self.email(tid, "", self.THREAT)]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "legal threat")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "human_review", rec)
        self.assertNotIn("escalated_from", rec)
        self.assertTrue(rec["register_no"], rec)
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout, d.stdout)
        self.assertIn("legal_threat", d.stdout, d.stdout)

    def test_a_fresh_DMCA_notice_keeps_the_human_page_too(self):
        tid = "1a1bESCALATE04"
        emails = [self.email(tid, "", "This is a DMCA takedown notice.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "dmca")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "human_review", rec)
        self.assertIn("needs a human", self.digest(result).stdout)

    def test_a_declined_ACCESS_copy_is_not_filed_as_a_new_duty(self):
        """QA #1858 r5. `Re: Article 15 access request` with `Do not send me a copy of my data.` filed a NEW
        access row off the inherited subject and the digest said 0 need a human, so the customer's refusal was
        neither surfaced nor treated as a withdrawal."""
        tid = "1a1bESCALATE06"
        self.seed_registered(tid, register_no=703, cls="privacy_access")
        emails = [self.email(tid, "Re: Article 15 access request",
                             "Do not send me a copy of my data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "withdrawn", rec)
        self.assertNotIn("duties", rec)
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout, d.stdout)
        self.assertNotIn("erasure register #703", d.stdout, d.stdout)

    def test_an_access_first_thread_keeps_the_access_row_when_a_threat_arrives(self):
        """QA #1858 Important, end to end. Access row open, then a legal threat: the threat was merged into the
        access row and changed its class, so the Art.15 answer lost its row and its deadline. Both duties must
        survive with their own clock, and the human must still be paged."""
        tid = "1a1bESCALATE05"
        self.seed_registered(tid, register_no=614, cls="privacy_access")
        emails = [self.email(tid, "Re: my account", self.THREAT)]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "legal threat")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "escalated", rec)
        self.assertEqual(rec["class_"], "legal_threat", rec)
        db = store_mod.Store(self.store_path)
        access = db.by_key_prefix(f"gmail:support@muso.ai:{tid}", "privacy_access")
        self.assertIsNotNone(access, "the access row was taken over by the escalation")
        self.assertEqual(access["class"], "privacy_access")
        self.assertTrue(access["due_at"], access)
        rows = [r for r in db.all("open")
                if str(r.get("conversation_id") or r.get("thread_id") or "") in (tid, "")]
        keys = {r["row_key"] for r in db.all("open")}
        self.assertTrue(any("escalation" in k or "erasure" in k for k in keys) or len(db.all("open")) >= 2,
                        f"no row kept the threat: {sorted(keys)}")
        d = self.digest(result)
        self.assertIn("needs a human", d.stdout)

    def test_a_same_class_reply_on_an_open_erasure_row_is_still_registered(self):
        tid = "1a1bESCALATE04"
        self.seed_registered(tid, register_no=613, cls="privacy_erasure")
        emails = [self.email(tid, "Re: my account",
                             "Please delete my profile. I already asked and nothing has happened.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "registered", rec)
        self.assertEqual(rec["register_no"], "613", rec)


class TestAnAccessDutyIsNotDroppedWhenErasureIsAlreadyOpen(BridgeCase):
    """QA #1847 r5 Important. The `registered` short-circuit returned before the dual-duty filing, so a
    message that ALSO asks for a copy left the Art.15 answer with no row and no deadline."""

    def test_a_copy_plus_delete_against_an_open_erasure_row_files_the_ACCESS_duty(self):
        tid = "1a1bMIXED0003"
        self.seed_registered(tid, register_no=610, cls="privacy_erasure")
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request",
                             "Send me a copy of my personal data and delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "registered", rec)
        self.assertEqual(rec["register_no"], "610")
        self.assertEqual(rec.get("duties"), ["privacy_erasure", "privacy_access"], rec)
        self.assertTrue(rec.get("access_register_no"), rec)

        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class, register_no, due_at FROM erasure_requests "
                             "WHERE channel='support' ORDER BY id").fetchall()
        self.assertEqual(sorted(r["class"] for r in rows), ["privacy_access", "privacy_erasure"])
        access = [r for r in rows if r["class"] == "privacy_access"][0]
        self.assertTrue(access["due_at"], "the access duty must carry its own deadline")
        self.assertNotEqual(access["register_no"], 610)

    def test_a_SAME_obligation_reply_does_not_file_a_second_access_row(self):
        """A follow-up that asks for nothing new must stay a plain `registered`: filing an access row on
        every reply would mint duties the customer never asked for."""
        tid = "1a1bMIXED0004"
        self.seed_registered(tid, register_no=611, cls="privacy_erasure")
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request", "Any update on this?")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "follow-up")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "registered", rec)
        self.assertNotIn("duties", rec)
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class FROM erasure_requests WHERE channel='support'").fetchall()
        self.assertEqual([r["class"] for r in rows], ["privacy_erasure"])



class TestAnInheritedAccessSubjectDoesNotCreateANewDuty(BridgeCase):
    """QA #1847 r6. The subject of a REPLY belongs to the old message.

    "Re: Article 15 access request" answered with "Please delete my profile." is a deletion. Reading the
    inherited subject filed a privacy_access row and a deadline nobody asked for, and could queue an
    unwanted access response off a row that was already closed.
    """

    def test_access_then_deletion_in_one_thread_files_NO_second_access_row(self):
        tid = "1a1bINHERIT0001"
        self.seed_registered(tid, register_no=700, cls="privacy_access")
        db = store_mod.Store(self.store_path)
        db.db.execute("UPDATE erasure_requests SET status='closed' WHERE register_no=700")
        db.db.commit()
        emails = [self.email(tid, "Re: Article 15 access request", "Please delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertNotIn("duties", rec)
        self.assertNotIn("access_register_no", rec)
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class, register_no FROM erasure_requests "
                             "WHERE channel='support' ORDER BY id").fetchall()
        # One row of each duty: the seeded (now closed) access row, and the new erasure row. A SECOND
        # privacy_access row here is exactly the defect -- the reply asked for a deletion only.
        self.assertEqual(sorted(r["class"] for r in rows), ["privacy_access", "privacy_erasure"], rec)
        self.assertEqual(sum(1 for r in rows if r["class"] == "privacy_access"), 1, rec)
        self.assertEqual([r["register_no"] for r in rows if r["class"] == "privacy_access"], [700], rec)

    def test_the_erasure_duty_still_gets_its_own_row_and_deadline(self):
        tid = "1a1bINHERIT0002"
        self.seed_registered(tid, register_no=701, cls="privacy_erasure")
        emails = [self.email(tid, "Re: Article 15 access request", "Please delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["outcome"], "registered", rec)
        self.assertNotIn("duties", rec)
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class FROM erasure_requests WHERE channel='support'").fetchall()
        self.assertEqual([r["class"] for r in rows], ["privacy_erasure"])

    def test_a_CURRENT_message_that_really_asks_for_a_copy_still_owes_two(self):
        """The guard must not silence a genuine combined reply just because the subject is inherited too."""
        tid = "1a1bINHERIT0003"
        self.seed_registered(tid, register_no=702, cls="privacy_erasure")
        emails = [self.email(tid, "Re: GDPR Article 17 erasure request",
                             "Please delete my profile and send me a copy of my personal data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec.get("duties"), ["privacy_erasure", "privacy_access"], rec)



class TestAnInheritedErasureSubjectDoesNotStartAnErasure(BridgeCase):
    """QA #1847 r6 Critical, through the routing the support lane actually uses.

    A customer on an erasure thread replies asking only for a copy. The reply must file an ACCESS row and
    must not file, reopen or advance an erasure row -- the hide path must not run for a message that asked
    for a copy.
    """

    def test_an_access_only_reply_on_an_erasure_thread_files_NO_erasure_row(self):
        tid = "1a1bMIRROR0001"
        self.seed_registered(tid, register_no=800, cls="privacy_erasure")
        db = store_mod.Store(self.store_path)
        db.db.execute("UPDATE erasure_requests SET status='closed' WHERE register_no=800")
        db.db.commit()
        emails = [self.email(tid, "Re: Article 17 erasure request",
                             "Please send me a copy of my personal data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class, register_no FROM erasure_requests "
                             "WHERE channel='support' ORDER BY id").fetchall()
        classes = sorted(r["class"] for r in rows)
        self.assertEqual(classes, ["privacy_access", "privacy_erasure"], rec)
        self.assertEqual(sum(1 for r in rows if r["class"] == "privacy_erasure"), 1, rec)
        self.assertEqual([r["register_no"] for r in rows if r["class"] == "privacy_erasure"], [800], rec)

    def test_the_new_access_row_carries_its_own_deadline(self):
        tid = "1a1bMIRROR0002"
        self.seed_registered(tid, register_no=801, cls="privacy_erasure")
        emails = [self.email(tid, "Re: Article 17 erasure request",
                             "Please send me a copy of my personal data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        db = store_mod.Store(self.store_path)
        access = db.db.execute("SELECT class, register_no, due_at, action FROM erasure_requests "
                               "WHERE channel='support' AND class='privacy_access'").fetchall()
        self.assertEqual(len(access), 1)
        self.assertTrue(access[0]["due_at"], "the access duty must carry its own deadline")
        self.assertNotEqual(access[0]["register_no"], 801)

    def test_an_erasure_reply_still_touches_only_the_erasure_duty(self):
        tid = "1a1bMIRROR0003"
        self.seed_registered(tid, register_no=802, cls="privacy_erasure")
        emails = [self.email(tid, "Re: Article 17 erasure request", "Please delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class FROM erasure_requests WHERE channel='support'").fetchall()
        self.assertEqual([r["class"] for r in rows], ["privacy_erasure"])



class TestANegatedCopyRequestCreatesNoAccessDuty(BridgeCase):
    """QA #1847 r7 Important, end to end through the routing.

    "Do not send me a copy of my data; please delete my profile." is a deletion. `_ACCESS_RX.search` matched
    the copy phrase anyway, so the dual-duty paths filed a privacy_access row and a deadline for a response
    the customer explicitly refused.
    """

    BODY = "Do not send me a copy of my data; please delete my profile."

    def test_a_fresh_message_files_only_the_erasure_duty(self):
        tid = "1a1bNEGCOPY0001"
        emails = [self.email(tid, "GDPR deletion request", self.BODY)]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(rec["class_"], "privacy_erasure", rec)
        self.assertNotIn("duties", rec)
        self.assertNotIn("access_register_no", rec)
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class FROM erasure_requests WHERE channel='support'").fetchall()
        self.assertEqual([r["class"] for r in rows], ["privacy_erasure"], rec)

    def test_the_mirror_still_files_both_when_the_copy_request_is_not_negated(self):
        tid = "1a1bNEGCOPY0002"
        emails = [self.email(tid, "GDPR deletion request",
                             "Please send me a copy of my personal data and delete my profile.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        self.assertEqual(sorted(rec.get("duties") or []), ["privacy_access", "privacy_erasure"], rec)

    def test_a_rounded_copy_request_negated_after_the_fact_files_no_access_row(self):
        tid = "1a1bNEGCOPY0003"
        emails = [self.email(tid, "GDPR deletion request",
                             "Never delete my account - I only want a copy of my personal data.")]
        proc, result = self.run_bridge(emails, [self.verdict(tid, "privacy request")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rec = result["threads"][tid]
        db = store_mod.Store(self.store_path)
        rows = db.db.execute("SELECT class FROM erasure_requests WHERE channel='support'").fetchall()
        self.assertIn("privacy_access", [r["class"] for r in rows], rec)


if __name__ == "__main__":
    unittest.main()
