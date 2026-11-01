"""p1 565: an 'attempted' in-thread note that DID land is reconciled to 'sent' (read-only on Intercom, ledger only, never
a post); anything not proven is left as it is."""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import attempted_reconcile as ar, verify_ledger as vl  # noqa: E402

GATE = ROOT / "scripts" / "intercom-verify-request.sh"
SENT = '<p>Hi Jane, a quick update on your credit request for &quot;A&quot;: it&#39;s with our team &amp; us.</p><ul><li>One</li></ul>'
STORED = '<p>Hi Jane, a quick update on your credit request for "A": it\'s with our team &amp; us.</p>\n<ul>\n<li>One</li>\n</ul>'


def gate_ntext_sha(body: str) -> str:
    """The gate's own NTEXT_JQ + sha, lifted from the script (one implementation, cross-checked here)."""
    src = GATE.read_text()
    m = re.search(r"readonly NTEXT_JQ='(.*?)'\n", src.replace("'\"'\"'", "\x00"), re.S)
    jq = m.group(1).replace("\x00", "'")
    out = subprocess.run(["jq", "-r", jq + " .body | ntext"], input=json.dumps({"body": body}), capture_output=True,
                         text=True, check=True).stdout
    import hashlib
    return hashlib.sha256(out.rstrip("\n").encode()).hexdigest()


class AttemptedReconcileTest(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.db = vl.connect(str(self.d / "l.sqlite3"))
        self.posted = []

    def row(self, *, tsha: str | None, conv="777", admin="5763097", ts="2026-11-01T01:50:34Z"):
        rid = vl.claim(self.db, user_key="j@x.com", day="2026-11-01", request_ids=[f"r{len(self.posted)}x"],
                       message_type="comment", approved_by="U", approval_ref="ref", campaign="uvn-status",
                       user_id="42")["message_row"]
        log = self.d / f"log{rid}.json"
        log.write_text(json.dumps({"conversation": conv, "admin_id": admin, "timestamp": ts,
                                   **({"text_sha256": tsha} if tsha else {})}))
        vl.finalize(self.db, message_row=rid, status="attempted", reason="unverified reply", api_log=str(log))
        return rid

    def ic(self, parts):
        def call(method, path, body):
            self.assertEqual(method, "GET")                    # read-only: never a post
            self.posted.append(path)
            return {"id": "777", "conversation_parts": {"conversation_parts": parts}}
        return call

    def part(self, pid, body, *, kind="assignment", admin="5763097", at=1793497834):
        return {"id": pid, "part_type": kind, "author": {"type": "admin", "id": admin}, "body": body, "created_at": at}

    def status(self, rid):
        return tuple(self.db.execute("SELECT status, message_id FROM verify_messages WHERE id=?", (rid,)).fetchone())

    def test_the_python_and_gate_normalisations_agree_on_intercoms_reformatting(self):
        self.assertEqual(gate_ntext_sha(SENT), ar.text_sha(STORED))
        self.assertEqual(gate_ntext_sha(SENT), gate_ntext_sha(STORED))
        # QA #1607: Unicode whitespace hashes the same on both sides (U+00A0 in a reply body was the finding); the
        # separators U+001C-U+001F are not whitespace to jq, so not to the reconciler either
        for ch in ("\u00a0", "\u2003", "\u3000", "\u0085", "\u2028", "\u1680", "\x0b", "\u200b", "\x1c", "\x1f", "\ufeff"):
            body = f"<p>A{ch}B {ch}{ch}C</p>"
            self.assertEqual(gate_ntext_sha(body), ar.text_sha(body), repr(ch))

    def test_a_delivered_note_is_reconciled_only_with_proof_and_never_re_posted(self):
        tsha = gate_ntext_sha(SENT)
        rid = self.row(tsha=tsha)
        ic = self.ic([self.part("57427459916", STORED)])
        rep = ar.run(self.db, ic, apply=False)
        self.assertEqual((rep[0]["part"], rep[0]["applied"], self.status(rid)), ("57427459916", False, ("attempted", None)))
        rep = ar.run(self.db, ic, apply=True)
        self.assertEqual(self.status(rid), ("sent", "57427459916"))
        self.assertTrue(all(p.startswith("/conversations/") for p in self.posted))

    def test_anything_unproven_is_left_attempted(self):
        tsha = gate_ntext_sha(SENT)
        for parts in ([self.part("1", "<p>Hi Jane, something else.</p>")],          # another text
                      [self.part("1", STORED, admin="111")],                         # another admin
                      [self.part("1", STORED, at=1793490000)],                       # before the post
                      [self.part("1", STORED, kind="note")],                         # a note is not delivery
                      [self.part("1", STORED), self.part("2", STORED, kind="comment")]):   # two matches: ambiguous
            db_rid = self.row(tsha=tsha)
            ar.run(self.db, self.ic(parts), apply=True)
            self.assertEqual(self.status(db_rid)[0], "attempted", parts)
            self.db.execute("UPDATE verify_messages SET status='refused' WHERE id=?", (db_rid,)); self.db.commit()

    def test_the_human_path_on_a_hash_bearing_row_still_needs_the_logged_text(self):
        # QA #1607: row logged Message A; our admin later wrote Message B in the thread; naming B's part must not
        # close A's row as sent
        rid = self.row(tsha=gate_ntext_sha(SENT))
        ic = self.ic([self.part("111", "<p>Hi Jane, a different later note.</p>", kind="comment"), self.part("222", STORED)])
        rep = ar.run(self.db, ic, apply=True, row=rid, part="111", confirmed_by="t01b")
        self.assertIn("not the text this row logged", rep[0]["why"])
        self.assertEqual(self.status(rid)[0], "attempted")
        ar.run(self.db, ic, apply=True, row=rid, part="222", confirmed_by="t01b")
        self.assertEqual(self.status(rid), ("sent", "222"))

    def test_an_old_log_without_text_sha_needs_a_named_human_and_the_part_must_still_be_ours(self):
        rid = self.row(tsha=None, admin="")                    # the 6360 shape: no text_sha256, no admin_id in the log
        ic = self.ic([self.part("57427459916", STORED)])
        rep = ar.run(self.db, ic, apply=True)
        self.assertIn("no text_sha256", rep[0]["why"])
        self.assertEqual(self.status(rid)[0], "attempted")
        rep = ar.run(self.db, ic, apply=True, row=rid, part="999", confirmed_by="t01b")
        self.assertEqual(self.status(rid)[0], "attempted")                    # not our part
        ar.run(self.db, ic, apply=True, row=rid, part="57427459916", confirmed_by="t01b")
        self.assertEqual(self.status(rid), ("sent", "57427459916"))
        reason = self.db.execute("SELECT reason FROM verify_messages WHERE id=?", (rid,)).fetchone()[0]
        self.assertIn("confirmed by t01b", reason)
        self.assertEqual(ar._main(["--ledger", str(self.d / "l.sqlite3"), "--row", "1"]), 2)   # the human path is all-or-nothing


if __name__ == "__main__":
    unittest.main()
