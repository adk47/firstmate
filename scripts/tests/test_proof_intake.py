#!/usr/bin/env python3
"""Tests for scripts/credit_verify/proof/intake.py - the FILE-ONLY document intake.

The contract this pins (doc-intake-backfill-d2):
  - a document the customer sent is filed with the ACCOUNT it belongs to, the
    conversation, the sha256 and the account's candidate credit requests;
  - NEVER a name: an ambiguous handle is skipped, not guessed;
  - NEVER a judgement: filing writes no forensics row and no verdict row, so no
    reader can mistake a filed document for an analysed one;
  - a dry run writes nothing to the store;
  - the same bytes are filed once (duplicate), however many conversations carry them;
  - a conversation with no cached file and no attachment files nothing.

    python3 scripts/tests/test_proof_intake.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_verify.proof import intake  # noqa: E402
from credit_verify.proof.store import ProofStore  # noqa: E402


def conv(cid: str, ext: str, attachments: list[dict], *, ask: bool = False) -> dict:
    """One Intercom conversation document. `ask` adds an in-thread admin request for
    documentation, which this intake does NOT require (that is the point)."""
    parts = []
    if ask:
        parts.append({"created_at": 1, "author": {"type": "admin", "id": "1"},
                      "body": "<p>Please send documentation for this credit</p>"})
    parts.append({"created_at": 2, "author": {"type": "user", "id": "9"}, "body": "<p>here</p>",
                  "attachments": attachments})
    return {"id": cid, "created_at": 0,
            "source": {"created_at": 0, "author": {"type": "user", "id": "9"},
                       "delivered_as": "customer_initiated", "body": "<p>my proof</p>"},
            "contacts": {"contacts": [{"id": f"c-{cid}", "external_id": ext}]},
            "conversation_parts": {"conversation_parts": parts}}


class IntakeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="cvdocintake-test-")
        self.cache = os.path.join(self.tmp, "cache")
        os.makedirs(self.cache)
        self.store = ProofStore(":memory:")
        self.export = os.path.join(self.tmp, "proof-on-file.json")
        Path(self.export).write_text(json.dumps({"sources": [], "users": 0, "entries": []}))
        self.docs = {
            "111": conv("111", "pro-a", [{"url": "https://files/x.pdf", "name": "split.pdf",
                                          "content_type": "application/pdf"}]),
            "222": conv("222", "pro-ambiguous", [{"url": "https://files/y.pdf", "name": "l.pdf",
                                                  "content_type": "application/pdf"}]),
            "333": conv("333", "pro-nobody", [{"url": "https://files/z.pdf", "name": "c.pdf",
                                               "content_type": "application/pdf"}]),
            "444": conv("444", "pro-b", [{"url": "https://files/x.pdf", "name": "split.pdf",
                                          "content_type": "application/pdf"}]),
            "555": conv("555", "pro-c", []),
        }
        self.payload = {"https://files/x.pdf": b"%PDF-1.4 split sheet",
                        "https://files/y.pdf": b"%PDF-1.4 other",
                        "https://files/z.pdf": b"%PDF-1.4 third"}
        for d in self.docs.values():           # Intercom lists each attachment's byte size
            for part in d["conversation_parts"]["conversation_parts"]:
                for a in part.get("attachments") or []:
                    a["filesize"] = len(self.payload[a["url"]])

    def tearDown(self) -> None:
        self.store.close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _dl(self, url: str, dest: str) -> int:
        data = self.payload[url]
        Path(dest).write_bytes(data)
        return len(data)

    def _fetch(self, cid: str):
        return self.docs.get(cid)

    def _lookup(self, ids: list[str]) -> dict[str, list[int]]:
        return {"pro-a": [11], "pro-ambiguous": [12, 13], "pro-b": [11], "pro-c": [14]}

    def _run(self, apply: bool, convs=None, open_rows=None, held=None):
        return intake.run(self.store, conversations=convs or ["111", "222", "333", "444", "555"],
                          fetch=self._fetch, lookup=self._lookup,
                          open_rows=open_rows or {}, held=held or {},
                          export_path=self.export, cache_root=self.cache, dl=self._dl, apply=apply)

    def _rows(self):
        return self.store.db.execute("SELECT * FROM proof_intake ORDER BY conversation_id").fetchall()

    def test_dry_run_writes_nothing(self) -> None:
        stats = self._run(apply=False)
        self.assertEqual(self._rows(), [])
        self.assertEqual(stats["files_filed"], 1)          # 111 would be filed; 444 carries the same bytes
        self.assertEqual(stats["files_duplicate"], 1)      # counted in the same run, written in neither

    def test_files_account_conversation_sha_and_candidates(self) -> None:
        open_rows = {11: [{"request_id": "aaaaaaaa-0000-0000-0000-000000000001", "status": "unverified"}]}
        held = {11: [{"request_id": "aaaaaaaa-0000-0000-0000-000000000002"}]}
        stats = self._run(apply=True, open_rows=open_rows, held=held)
        rows = self._rows()
        self.assertEqual(len(rows), 1, rows)
        r = rows[0]
        self.assertEqual(r["user_id"], 11)
        self.assertEqual(r["conversation_id"], "111")
        self.assertEqual(r["matched_by"], "professional_id")
        self.assertEqual(len(r["file_sha256"]), 64)
        self.assertEqual(r["subject"], "credit")
        self.assertEqual(json.loads(r["candidate_request_ids_json"]),
                         ["aaaaaaaa-0000-0000-0000-000000000001", "aaaaaaaa-0000-0000-0000-000000000002"])
        self.assertEqual(r["source"], "intercom")
        self.assertEqual(r["filed_by"], "credit-proof.py file")
        self.assertTrue(r["received_at"].endswith("Z"))
        self.assertTrue(r["intake_id"].startswith("11:"))
        self.assertEqual(stats["files_duplicate"], 1)      # 444's identical bytes, filed once

    def test_never_files_against_an_ambiguous_or_unknown_account(self) -> None:
        stats = self._run(apply=True)
        self.assertEqual(stats["ambiguous_conversations"], ["222"])
        self.assertEqual(stats["unmatched_conversations"], ["333"])
        self.assertEqual([r["conversation_id"] for r in self._rows()], ["111"])

    def test_writes_no_judgement(self) -> None:
        self._run(apply=True)
        for table in ("forensics", "verdicts", "fingerprints"):
            n = self.store.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            self.assertEqual(n, 0, f"{table} must stay empty: filing is not judgement")

    def test_export_decides_only_when_the_professional_id_resolves_nothing(self) -> None:
        Path(self.export).write_text(json.dumps({"entries": [
            {"user_id": 21, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "333"}]}))
        stats = self._run(apply=True)
        self.assertEqual(stats["unmatched_conversations"], [])
        self.assertEqual({(r["conversation_id"], r["user_id"], r["matched_by"]) for r in self._rows()},
                         {("111", 11, "professional_id"), ("333", 21, "proof_on_file")})

    def test_professional_id_and_export_disagree_is_skipped(self) -> None:
        Path(self.export).write_text(json.dumps({"entries": [
            {"user_id": 99, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "111"}]}))
        stats = self._run(apply=True)
        # 111 disagrees with the export; 222's professional id maps to two accounts: both skipped
        self.assertEqual(stats["ambiguous_conversations"], ["111", "222"])
        self.assertEqual([r["conversation_id"] for r in self._rows()], ["444"])

    def test_no_attachments_and_no_cache_files_nothing(self) -> None:
        stats = self._run(apply=True, convs=["555"])
        self.assertEqual(stats["no_document_conversations"], ["555"])
        self.assertEqual(self._rows(), [])

    def test_cache_answers_without_downloading(self) -> None:
        cdir = os.path.join(self.cache, "222", "notif_1")
        os.makedirs(cdir)
        Path(os.path.join(cdir, "0.pdf")).write_bytes(self.payload["https://files/y.pdf"])   # the attachment, cached
        seen = []

        def dl(url, dest):                      # a cached conversation must not hit the network
            seen.append(url)
            return self._dl(url, dest)

        stats = intake.run(self.store, conversations=["222"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=dl, apply=True,
                           open_rows={12: [{"request_id": "x"}]})
        self.assertEqual(seen, [])                                    # the cache answered
        self.assertEqual(stats["ambiguous_conversations"], ["222"])   # ambiguity still refuses to file
        self.assertEqual(stats["files_filed"], 0)
        self.assertEqual(self._rows(), [])

    def test_idempotent_on_user_and_sha(self) -> None:
        Path(self.export).write_text(json.dumps({"entries": [
            {"user_id": 11, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "444"}]}))
        self._run(apply=True)                       # 111 (user 11) files the bytes
        n = len(self._rows())
        again = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True)
        self.assertEqual(len(self._rows()), n)      # the same (user, document) is one row
        self.assertEqual(again["files_filed"], 0)
        self.assertEqual(again["files_duplicate"], 1)

    def test_a_document_h3_already_analysed_is_still_filed_for_the_account(self) -> None:
        # proof-loop lead 2026-10-27: H3's intercom rows carry no request link, so the reader can
        # only judge them once they are filed; idempotency is (user, document), not "seen anywhere".
        import hashlib
        sha = hashlib.sha256(self.payload["https://files/x.pdf"]).hexdigest()
        self.store.db.execute("INSERT INTO proofs (proof_id, first_seen, source, source_ref, contact_h, mime, bytes)"
                              " VALUES (?, '2026-10-20T00:00:00Z', 'intercom', 'x', 'c', 'application/pdf', 1)", (sha,))
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True)
        self.assertEqual((stats["files_filed"], [r["file_sha256"] for r in self._rows()]), (1, [sha]))

    def test_max_fetches_defers_whole_conversations_never_drops_them(self) -> None:
        stats = intake.run(self.store, conversations=["111", "444"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True, max_fetches=1)
        self.assertEqual((stats["fetches_used"], stats["deferred_conversations"]), (1, ["444"]))
        self.assertEqual(len(self._rows()), 1)
        stats = intake.run(self.store, conversations=["111", "444"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True, max_fetches=0)
        self.assertEqual((stats["fetches_used"], stats["deferred_conversations"]), (0, ["111", "444"]))
        # a cached conversation needs no fetch at all
        os.makedirs(os.path.join(self.cache, "111", "notif_x"))
        Path(self.cache, "111", "notif_x", "0.pdf").write_bytes(self.payload["https://files/x.pdf"])
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True, max_fetches=0)
        self.assertEqual((stats["fetches_used"], stats["deferred_conversations"]), (0, []))

    def test_a_dry_run_leaves_the_store_file_byte_identical(self) -> None:
        # QA #1417 @94ece3a0: a count-only run must not create schema, indexes or drop tables.
        import hashlib
        import sqlite3
        path = os.path.join(self.tmp, "prod-like.sqlite")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE proofs (proof_id TEXT PRIMARY KEY)")
        db.execute("CREATE TABLE filed_documents (proof_id TEXT PRIMARY KEY)")      # empty: --apply would drop it
        db.commit()
        db.close()
        before = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        store = ProofStore.for_run(path, apply=False)
        stats = intake.run(store, conversations=["111", "444"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=False,
                           open_rows={11: [{"request_id": "x"}]})
        store.close()
        self.assertEqual(stats["files_filed"], 1)                          # counted ...
        self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(), before)   # ... nothing written
        self.assertEqual(sorted(os.listdir(self.tmp)).count("prod-like.sqlite-journal"), 0)
        with self.assertRaises(RuntimeError):
            ProofStore.for_run(path, apply=False).file_document(file_sha256="a" * 64, user_id=1, conversation_id="c")
        missing = os.path.join(self.tmp, "absent.sqlite")
        ProofStore.for_run(missing, apply=False).close()
        self.assertFalse(os.path.exists(missing))                          # no file created by a dry run

    def test_the_draft_filed_documents_table_is_dropped_only_while_empty(self) -> None:
        path = os.path.join(self.tmp, "p.sqlite")
        import sqlite3
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE filed_documents (proof_id TEXT PRIMARY KEY)")
        db.commit()
        db.close()
        ProofStore(path).close()
        db = sqlite3.connect(path)
        self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='filed_documents'").fetchone())
        db.execute("CREATE TABLE filed_documents (proof_id TEXT PRIMARY KEY)")
        db.execute("INSERT INTO filed_documents VALUES ('keep-me')")
        db.commit()
        db.close()
        ProofStore(path).close()
        db = sqlite3.connect(path)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM filed_documents").fetchone()[0], 1)   # never lose a row
        db.close()

    def test_open_rows_come_from_one_select_for_the_resolved_accounts(self) -> None:
        asked = []

        def fn(uids):
            asked.append(sorted(uids))
            return {11: [{"request_id": "aaaaaaaa-0000-0000-0000-000000000009", "status": "unverified"}]}
        intake.run(self.store, conversations=["111", "222", "333"], fetch=self._fetch, lookup=self._lookup,
                   export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True, open_rows_fn=fn)
        self.assertEqual(asked, [[11]])                     # only the account that resolved; never a guess
        self.assertEqual(json.loads(self._rows()[0]["candidate_request_ids_json"]),
                         ["aaaaaaaa-0000-0000-0000-000000000009"])

    def test_open_rows_trino_parses_csv_and_keeps_only_open_rows(self) -> None:
        seen = []

        def trino(sql):
            seen.append(sql)
            return ('"warn"\n"aaaaaaaa-0000-0000-0000-000000000001","unverified","11"\n'
                    '"aaaaaaaa-0000-0000-0000-000000000002","approved","11"\n')
        self.assertEqual(intake.open_rows_trino([11, 11], trino=trino),
                         {11: [{"request_id": "aaaaaaaa-0000-0000-0000-000000000001", "status": "unverified"}]})
        self.assertTrue(seen[0].startswith("SELECT") and "userid IN (11)" in seen[0])

    def test_a_partly_cached_conversation_files_its_uncached_documents_too(self) -> None:
        # QA #1417: one cached original must not hide a second, uncached attachment.
        self.payload["https://files/w.pdf"] = b"%PDF-1.4 second document"
        self.docs["111"]["conversation_parts"]["conversation_parts"][-1]["attachments"].append(
            {"url": "https://files/w.pdf", "name": "w.pdf", "content_type": "application/pdf",
             "filesize": len(self.payload["https://files/w.pdf"])})
        os.makedirs(os.path.join(self.cache, "111", "notif_x"))
        Path(self.cache, "111", "notif_x", "0.pdf").write_bytes(self.payload["https://files/x.pdf"])
        seen = []

        def dl(url, dest):
            seen.append(url)
            return self._dl(url, dest)
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=dl, apply=True)
        self.assertEqual(seen, ["https://files/w.pdf"])          # only the uncached one is fetched
        self.assertEqual((stats["files_filed"], len(self._rows())), (2, 2))
        # an attachment Intercom lists without a size is fetched; identical bytes are not filed twice
        del self.docs["111"]["conversation_parts"]["conversation_parts"][-1]["attachments"][0]["filesize"]
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=dl, apply=True)
        self.assertEqual((stats["files_filed"], len(self._rows())), (0, 2))

    def test_two_equal_size_attachments_are_both_filed_whichever_is_cached(self) -> None:
        # QA #1417 @60fe0b61: A then B, same byte size, only B cached -> A must not be lost.
        a, b = b"AAAA", b"BBBB"
        self.payload.update({"https://files/a.bin": a, "https://files/b.bin": b})
        part = self.docs["111"]["conversation_parts"]["conversation_parts"][-1]
        part["attachments"] = [{"url": "https://files/a.bin", "name": "a.pdf", "filesize": 4},
                               {"url": "https://files/b.bin", "name": "b.pdf", "filesize": 4}]
        os.makedirs(os.path.join(self.cache, "111", "notif_x"))
        Path(self.cache, "111", "notif_x", "0.pdf").write_bytes(b)
        seen = []

        def dl(url, dest):
            seen.append(url)
            return self._dl(url, dest)
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=dl, apply=True)
        import hashlib
        self.assertEqual(sorted(r["file_sha256"] for r in self._rows()),
                         sorted(hashlib.sha256(x).hexdigest() for x in (a, b)))
        self.assertEqual(sorted(seen), ["https://files/a.bin", "https://files/b.bin"])   # shared size: both fetched
        self.assertEqual((stats["files_filed"], stats["files_error"]), (2, 0))

    def test_a_cached_admin_file_of_the_same_size_never_stands_in_for_a_customer_document(self) -> None:
        cust = b"CUST"
        self.payload["https://files/c.bin"] = cust
        parts = self.docs["111"]["conversation_parts"]["conversation_parts"]
        parts[-1]["attachments"] = [{"url": "https://files/c.bin", "name": "c.pdf", "filesize": 4}]
        parts.insert(0, {"author": {"type": "admin"}, "attachments": [{"url": "https://files/adm", "filesize": 4}]})
        os.makedirs(os.path.join(self.cache, "111", "notif_x"))
        Path(self.cache, "111", "notif_x", "0.pdf").write_bytes(b"ADMN")           # the admin's file is cached
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=self._dl, apply=True)
        import hashlib
        self.assertEqual([r["file_sha256"] for r in self._rows()], [hashlib.sha256(cust).hexdigest()])  # exact set
        self.assertEqual(stats["cache_not_customer"], 1)

    def test_a_cached_staff_file_is_never_filed_as_the_customers(self) -> None:
        # QA #1417 @94ece3a0: an admin attachment (distinct size) cached next to a customer's.
        cust, staff = b"%PDF-1.4 the customer's", b"%PDF-1.4 our own template, sent by staff"
        self.payload["https://files/c.bin"] = cust
        parts = self.docs["111"]["conversation_parts"]["conversation_parts"]
        parts[-1]["attachments"] = [{"url": "https://files/c.bin", "name": "c.pdf", "filesize": len(cust)}]
        parts.insert(0, {"author": {"type": "admin"},
                         "attachments": [{"url": "https://files/s", "name": "s.pdf", "filesize": len(staff)}]})
        os.makedirs(os.path.join(self.cache, "111", "notif_x"))
        Path(self.cache, "111", "notif_x", "0.pdf").write_bytes(staff)
        Path(self.cache, "111", "notif_x", "1.pdf").write_bytes(cust)
        seen = []

        def dl(url, dest):
            seen.append(url)
            return self._dl(url, dest)
        stats = intake.run(self.store, conversations=["111"], fetch=self._fetch, lookup=self._lookup,
                           export_path=self.export, cache_root=self.cache, dl=dl, apply=True)
        import hashlib
        self.assertEqual([r["file_sha256"] for r in self._rows()], [hashlib.sha256(cust).hexdigest()])
        self.assertEqual((seen, stats["cache_not_customer"]), ([], 1))        # the customer's file came from cache

    def test_a_request_that_opens_later_becomes_a_candidate_on_the_existing_filing(self) -> None:
        # QA #1417: run 1 files with no open request; run 2 sees one open and merges it in.
        self._run(apply=True, convs=["111"])
        self.assertEqual(json.loads(self._rows()[0]["candidate_request_ids_json"]), [])
        rid = "aaaaaaaa-0000-0000-0000-000000000007"
        dry = self._run(apply=False, convs=["111"], open_rows={11: [{"request_id": rid, "status": "unverified"}]})
        self.assertEqual((dry["candidates_refreshed"], json.loads(self._rows()[0]["candidate_request_ids_json"])),
                         (1, []))                                  # a dry run writes nothing
        stats = self._run(apply=True, convs=["111"], open_rows={11: [{"request_id": rid, "status": "unverified"}]})
        self.assertEqual(stats["candidates_refreshed"], 1)
        self.assertEqual(json.loads(self._rows()[0]["candidate_request_ids_json"]), [rid])
        self.assertEqual(len(self._rows()), 1)                    # still one row
        stats = self._run(apply=True, convs=["111"], open_rows={})  # a closed request is never erased
        self.assertEqual((stats["candidates_refreshed"], json.loads(self._rows()[0]["candidate_request_ids_json"])),
                         (0, [rid]))

    def test_downloads_only_from_intercom_attachment_hosts(self) -> None:
        ok = intake.attachment_url_ok
        self.assertTrue(ok("https://musoai.intercom-attachments-5.com/i/o/123/abc/file.png"))
        self.assertTrue(ok("https://downloads.intercomcdn.com/i/o/1/x.pdf"))
        for bad in ("http://musoai.intercom-attachments-5.com/x", "https://evil.com/musoai.intercom-attachments-5.com",
                    "https://musoai.intercom-attachments-5.com.evil.com/x", "https://169.254.169.254/latest",
                    "https://musoai.intercom-attachments-5.com:8443/x", "file:///etc/passwd"):
            self.assertFalse(ok(bad), bad)
        with self.assertRaises(ValueError):
            intake._download("https://evil.com/x.pdf", os.path.join(self.tmp, "x"))

    def test_the_same_document_for_two_accounts_is_two_rows(self) -> None:
        Path(self.export).write_text(json.dumps({"entries": [
            {"user_id": 11, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "444"}]}))
        self._run(apply=True)
        rows = self._rows()
        sha = {r["file_sha256"] for r in rows}
        self.assertEqual(len(sha), 1)               # one document...
        self.assertEqual(sorted(r["user_id"] for r in rows), [11])   # ...filed once, for the matched account
        # a second account presenting the same bytes is a separate row (the reader needs both)
        wrote = self.store.file_document(file_sha256=rows[0]["file_sha256"], user_id=77, conversation_id="999",
                                         candidate_request_ids=[], matched_by="professional_id")
        self.assertIsNotNone(wrote)
        self.assertEqual(len(self._rows()), 2)

    def test_conversation_list_parsing(self) -> None:
        p = os.path.join(self.tmp, "convs.txt")
        Path(p).write_text("# comment\n111 222\n\n333 # trailing\n111\n")
        self.assertEqual(intake.read_conversations(p), ["111", "222", "333"])



def gmail_raw(*, sender="ann@example.com", auth="mx.google.com; dkim=pass header.i=@example.com header.d=example.com",
              files=((b"%PDF-1.4 emailed split sheet", "application/pdf", "split.pdf"),),
              date="Tue, 14 Oct 2026 12:31:00 +0200") -> bytes:
    from email.message import EmailMessage
    m = EmailMessage()
    m["From"] = f"Ann <{sender}>"
    m["To"] = "support@muso.ai"
    m["Date"] = date
    m["Subject"] = "my credit"
    if auth:
        m["Authentication-Results"] = auth
    m.set_content("here is my proof")
    for data, ctype, name in files:
        main, sub = ctype.split("/")
        m.add_attachment(data, maintype=main, subtype=sub, filename=name)
    return m.as_bytes()


class StrictIdentityTest(IntakeTest):
    """The hourly intake's fail-closed identity (Fable [key=intake-reenable], 2026-10-29)."""
    NOW = 2_000_000_000.0

    def setUp(self) -> None:
        super().setUp()
        old = self.NOW - 3 * 86400
        self.contacts = {"c-111": {"role": "user", "external_id": "pro-a", "email": "Ann@Example.com", "created_at": old},
                         "c-333": {"role": "user", "external_id": "pro-nobody", "email": "x@y.z", "created_at": old}}
        self.acct = {11: intake.email_hash("ann@example.com")}

    def _strict(self, convs, apply=True):
        ident = intake.strict_identity(contact_fetch=lambda cid: self.contacts.get(cid), lookup=self._lookup,
                                       email_of_account=lambda uid: self.acct.get(uid, ""), now=lambda: self.NOW)
        return intake.run(self.store, conversations=convs, fetch=self._fetch, lookup=self._lookup, open_rows={},
                          held={}, export_path=self.export, cache_root=self.cache, dl=self._dl, apply=apply,
                          identity=ident, filed_by="intake-cron")

    def test_one_user_contact_with_external_id_and_matching_email_is_filed(self) -> None:
        stats = self._strict(["111"])
        self.assertEqual((stats["files_filed"], stats["unresolved"]), (1, []))
        row = self.store.db.execute("SELECT user_id, filed_by, matched_by FROM proof_intake").fetchone()
        # [key=receipt-match-label] (l1 ruling-external-id-receipts-1102.md): the contact-handle match is a
        # professional-id+email match; it is written under the label the receipts allowlist already understands,
        # so a receipt is not skipped for a spelling difference. The identity work is unchanged: external_id must
        # map to exactly one account AND the contact's email must equal that account's email.
        self.assertEqual(tuple(row), (11, "intake-cron", "professional_id+email"))

    def test_every_identity_doubt_is_unresolved_never_filed(self) -> None:
        cases = {
            "a lead, not a user": {"role": "lead"},
            "no external_id": {"external_id": ""},
            "younger than 24 h": {"created_at": self.NOW - 3600},
            "no email": {"email": ""},
            "email of another person": {"email": "someone@else.com"},
        }
        for why, patch in cases.items():
            self.store.db.execute("DELETE FROM proof_intake")
            self.contacts["c-111"] = {"role": "user", "external_id": "pro-a", "email": "ann@example.com",
                                      "created_at": self.NOW - 3 * 86400, **patch}
            stats = self._strict(["111"])
            self.assertEqual(stats["files_filed"], 0, why)
            self.assertEqual(len(stats["unresolved"]), 1, why)
            self.assertTrue(stats["unresolved"][0]["why"].startswith("unresolved:"), why)
            self.assertEqual(self.store.db.execute("SELECT count(*) FROM proof_intake").fetchone()[0], 0, why)

    def test_a_thread_with_two_user_contacts_or_an_unknown_account_is_unresolved(self) -> None:
        self.docs["111"]["contacts"]["contacts"].append({"id": "c-other", "external_id": "pro-b"})
        self.contacts["c-other"] = {"role": "user", "external_id": "pro-b", "email": "b@b.com",
                                    "created_at": self.NOW - 9 * 86400}
        stats = self._strict(["111", "333", "222"])
        whys = sorted(u["why"] for u in stats["unresolved"])
        self.assertEqual(stats["files_filed"], 0)
        self.assertTrue(any("2 user contacts" in w for w in whys), whys)
        self.assertTrue(any("not a Muso account" in w for w in whys), whys)        # 333: pro-nobody
        self.assertTrue(any("is unreadable" in w for w in whys), whys)              # 222: contact not readable

    def test_one_user_plus_an_unreadable_contact_is_unresolved(self) -> None:
        # QA #1481: the unreadable one could be a second user; never file to the readable one's account.
        for ref in ({"id": "c-gone", "external_id": "pro-b"}, {"external_id": "pro-b"}):
            self.store.db.execute("DELETE FROM proof_intake")
            self.docs["111"]["contacts"]["contacts"] = [{"id": "c-111", "external_id": "pro-a"}, ref]
            stats = self._strict(["111"])
            self.assertEqual(stats["files_filed"], 0, ref)
            self.assertEqual([u["why"] for u in stats["unresolved"]], ["unresolved: a contact on the thread is unreadable"])
        self.docs["111"]["contacts"]["contacts"] = []
        self.assertIn("0 user contacts", self._strict(["111"])["unresolved"][0]["why"])

    def test_the_bytes_must_be_a_pdf_or_an_image(self) -> None:
        self.payload["https://files/x.pdf"] = b"MZ\x90\x00 not a pdf at all"
        for d in self.docs.values():
            for part in d["conversation_parts"]["conversation_parts"]:
                for a in part.get("attachments") or []:
                    a["filesize"] = len(self.payload[a["url"]])
        stats = self._strict(["111"])
        self.assertEqual((stats["files_filed"], stats["files_rejected_type"]), (0, 1))
        for head, mime in ((b"%PDF-1.7", "application/pdf"), (b"\x89PNG\r\n\x1a\n", "image/png"),
                           (b"\xff\xd8\xff\xe0", "image/jpeg"), (b"RIFF\x00\x00\x00\x00WEBPVP8 ", "image/webp"),
                           (b"\x00\x00\x00\x18ftypheic", "image/heic"), (b"PK\x03\x04", None)):
            f = os.path.join(self.tmp, "sniff")
            Path(f).write_bytes(head + b"x" * 8)
            self.assertEqual(intake.sniff(f), mime, head)

    def test_the_cron_files_only_and_honours_its_own_kill_file(self) -> None:
        src = (Path(__file__).resolve().parents[1] / "credit-proof.py").read_text()
        body = src[src.index("def cmd_file_recent("):src.index("def cmd_email(")]
        for need in ("INTAKE_KILL", "identity=intake.strict_identity(", 'filed_by="intake-cron"', "UNRESOLVED"):
            self.assertIn(need, body, need)
        for banned in ("send-gateway", "intercom-verify-request", "/admin/credit", "PATCH", "set_status"):
            self.assertNotIn(banned, body, banned)
        self.assertIn('"/etc/hydra/credit-doc-intake.disabled"', src)


class GmailIntakeTest(unittest.TestCase):
    """`credit-proof.py file --source gmail`: support@ documents, same proof_intake contract,
    email_in's authenticated-sender + confirmed-account rules (proof-loop lead 032)."""

    def setUp(self) -> None:
        from credit_verify.proof import gmail_intake
        self.g = gmail_intake
        self.store = ProofStore(":memory:")
        self.msgs = {"m1": gmail_raw(),
                     "m2": gmail_raw(auth="evil.example; dkim=pass header.d=example.com"),          # untrusted hop
                     "m3": gmail_raw(sender="bob@example.com"),
                     "m4": gmail_raw(files=())}
        self.accounts = {"ann@example.com": [{"id": 11, "email": "ann@example.com", "emailConfirmed": True}],
                         "bob@example.com": [{"id": 12, "email": "bob@example.com", "emailConfirmed": False}]}
        self.rows = {11: [{"request_id": "aaaaaaaa-0000-0000-0000-000000000001", "status": "unverified"}]}

    def tearDown(self) -> None:
        self.store.close()

    def _fetch(self, mid):
        if mid not in self.msgs:
            raise RuntimeError("gog rc=1")
        return self.msgs[mid]

    def _run(self, ids, apply=True):
        return self.g.run(self.store, message_ids=ids, fetch=self._fetch, lookup=lambda a: self.accounts.get(a, []),
                          open_rows=lambda uids: {u: self.rows.get(u, []) for u in uids}, apply=apply)

    def _rows(self):
        return self.store.db.execute("SELECT * FROM proof_intake").fetchall()

    def test_an_authenticated_confirmed_sender_is_filed_under_the_contract(self) -> None:
        import hashlib
        stats = self._run(["m1"])
        (r,) = self._rows()
        self.assertEqual((r["user_id"], r["source"], r["conversation_id"], r["file_path"], r["subject"]),
                         (11, "email", "gmail:m1", None, "credit"))
        self.assertEqual(r["file_sha256"], hashlib.sha256(b"%PDF-1.4 emailed split sheet").hexdigest())
        self.assertEqual(json.loads(r["candidate_request_ids_json"]), ["aaaaaaaa-0000-0000-0000-000000000001"])
        self.assertEqual(r["received_at"], "2026-10-14T10:31:00Z")                  # UTC, from the Date header
        self.assertEqual(r["matched_by"], "authenticated_email")
        self.assertEqual((stats["files_filed"], stats["with_candidate_requests"]), (1, 1))
        for t in ("forensics", "verdicts", "fingerprints"):
            self.assertEqual(self.store.db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0], 0, t)

    def test_the_filer_stores_the_bytes_it_holds_so_the_reader_never_pulls_gmail(self) -> None:
        # Fable 10-31: the blob is stored at filing time (and on a duplicate re-scan); a dry run stores nothing;
        # a failing blob store never blocks the filing (counted; blob-backfill restores the bytes).
        import hashlib
        kept: dict[str, bytes] = {}
        sha = hashlib.sha256(b"%PDF-1.4 emailed split sheet").hexdigest()
        run = lambda apply, blobs: self.g.run(self.store, message_ids=["m1"], fetch=self._fetch,  # noqa: E731
                                              lookup=lambda a: self.accounts.get(a, []),
                                              open_rows=lambda uids: {u: self.rows.get(u, []) for u in uids},
                                              apply=apply, blobs=blobs)
        self.assertEqual(run(False, kept.__setitem__)["blobs_stored"], 0)
        self.assertEqual(kept, {})
        st = run(True, kept.__setitem__)
        self.assertEqual((st["files_filed"], st["blobs_stored"], list(kept)), (1, 1, [sha]))
        kept.clear()
        self.assertEqual(run(True, kept.__setitem__)["blobs_stored"], 1)            # duplicate scan: stored too
        self.assertEqual(list(kept), [sha])
        kept.clear()
        self.assertEqual(run(False, kept.__setitem__)["blobs_stored"], 0)           # a dry re-scan stores nothing
        self.assertEqual(kept, {})

        def broken(s, d):
            raise OSError("disk full")
        self.store.db.execute("DELETE FROM proof_intake")
        st = run(True, broken)
        self.assertEqual((st["files_filed"], st["blob_errors"], len(self._rows())), (1, 1, 1))

    def test_spoofable_unconfirmed_unknown_and_unreadable_messages_are_counted_never_filed(self) -> None:
        stats = self._run(["m2", "m3", "m9"])
        self.assertEqual(self._rows(), [])
        self.assertEqual(stats["refused"], {"no_trusted_authentication_results": 1, "account_email_not_confirmed": 1})
        self.assertEqual(stats["fetch_errors"], ["m9: RuntimeError"])

    def test_dry_run_writes_nothing_and_rerun_is_idempotent_with_candidate_merge(self) -> None:
        self.assertEqual(self._run(["m1"], apply=False)["files_filed"], 1)
        self.assertEqual(self._rows(), [])
        self._run(["m1"])
        self.rows[11].append({"request_id": "aaaaaaaa-0000-0000-0000-000000000002", "status": "unverified"})
        again = self._run(["m1"])
        self.assertEqual((again["files_filed"], again["files_duplicate"], again["candidates_refreshed"]), (0, 1, 1))
        self.assertEqual(len(json.loads(self._rows()[0]["candidate_request_ids_json"])), 2)

    def test_a_dry_run_counts_an_attachment_sent_twice_once(self) -> None:
        # Prod 2026-10-28: the dry run said 1,521, --apply filed 1,174 - re-sent attachments were counted twice.
        self.msgs["m6"] = gmail_raw()                                   # the same attachment as m1, sent again
        dry = self._run(["m1", "m6"], apply=False)
        self.assertEqual((dry["files_filed"], dry["files_duplicate"]), (1, 1))
        real = self._run(["m1", "m6"], apply=True)
        self.assertEqual((real["files_filed"], real["files_duplicate"]), (1, 1))      # dry run == apply

    def test_no_attachment_and_oversized_attachments_are_counted(self) -> None:
        big = b"%PDF-1.4" + b"0" * (self.g.MAX_ATTACHMENT_BYTES + 1)
        self.msgs["m5"] = gmail_raw(files=((big, "application/pdf", "huge.pdf"),))
        stats = self._run(["m4", "m5"])
        self.assertEqual((stats["no_document_messages"], stats["files_too_large"]), (["m4", "m5"], 1))

    def test_the_reader_finds_the_filed_attachment_by_sha(self) -> None:
        import hashlib
        sha = hashlib.sha256(b"%PDF-1.4 emailed split sheet").hexdigest()
        self.assertEqual(self.g.message_attachment(self.msgs["m1"], sha)[2], b"%PDF-1.4 emailed split sheet")
        self.assertIsNone(self.g.message_attachment(self.msgs["m1"], "0" * 64))

    def test_a_gmail_dry_run_on_a_read_only_store_writes_nothing(self) -> None:
        import hashlib
        path = os.path.join(tempfile.mkdtemp(), "p.sqlite")
        ProofStore(path).close()
        before = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        ro = ProofStore.for_run(path, apply=False)
        stats = self.g.run(ro, message_ids=["m1"], fetch=self._fetch, lookup=lambda a: self.accounts.get(a, []),
                           open_rows=lambda uids: {u: self.rows.get(u, []) for u in uids}, apply=False)
        ro.close()
        self.assertEqual(stats["files_filed"], 1)
        self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(), before)

    # --- forged headers (captain 2026-10-28 12:18Z item 2: filing stays OFF unless these pass) ---------
    def _raw_headers(self, headers: list[tuple[str, str]], files=((b"%PDF-1.4 x", "application/pdf", "x.pdf"),)):
        """A message with EXACTLY these headers in this order (top = stamped last, as Gmail prepends)."""
        from email.message import EmailMessage
        m = EmailMessage()
        for k, v in headers:
            m[k] = v
        m.set_content("proof")
        for data, ctype, name in files:
            main, sub = ctype.split("/")
            m.add_attachment(data, maintype=main, subtype=sub, filename=name)
        return m.as_bytes()

    def _filed(self, raw: bytes):
        self.msgs["mf"] = raw
        stats = self._run(["mf"])
        return stats, self._rows()

    def test_forged_pass_header_injected_by_the_sender_is_ignored(self) -> None:
        # Google prepends its own verdict; a sender-written 'mx.google.com; dkim=pass' sits BELOW it.
        stats, rows = self._filed(self._raw_headers([
            ("Authentication-Results", "mx.google.com; dkim=fail header.d=example.com; spf=fail; dmarc=fail"),
            ("From", "Ann <ann@example.com>"),
            ("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com; dmarc=pass")]))
        self.assertEqual((rows, stats["refused"]), ([], {"authentication_failed": 1}))

    def test_arc_pass_alone_never_authenticates(self) -> None:
        stats, rows = self._filed(self._raw_headers([
            ("ARC-Authentication-Results", "i=1; mx.google.com; dkim=pass header.d=example.com; dmarc=pass"),
            ("From", "ann@example.com")]))
        self.assertEqual((rows, stats["refused"]), ([], {"no_trusted_authentication_results": 1}))

    def test_forged_received_headers_are_never_read(self) -> None:
        stats, rows = self._filed(self._raw_headers([
            ("Received", "from mx.google.com (mx.google.com [209.85.220.41]) by bluefern.com"),
            ("Received", "from trusted.bluefern.com by mail.bluefern.com; dkim=pass dmarc=pass"),
            ("From", "ann@example.com")]))
        self.assertEqual((rows, stats["refused"]), ([], {"no_trusted_authentication_results": 1}))

    def test_two_from_addresses_are_refused(self) -> None:
        # Raw bytes: Python's EmailMessage will not BUILD two From headers, but a sender can send them.
        one = self._raw_headers([("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com; dmarc=pass"),
                                 ("From", "ann@example.com")])
        two = one.replace(b"From: ann@example.com", b"From: ann@example.com\nFrom: victim@example.com", 1)
        self.assertIn(b"From: victim@example.com", two)
        stats, rows = self._filed(two)
        self.assertEqual((rows, stats["refused"]), ([], {"missing_or_multiple_from": 1}))

    def test_dkim_for_another_domain_does_not_authenticate_the_from(self) -> None:
        # Signed by the attacker's own domain (pass), From claims the victim's: not aligned, no DMARC pass.
        stats, rows = self._filed(self._raw_headers([
            ("Authentication-Results", "mx.google.com; dkim=pass header.d=attacker.net; dmarc=fail"),
            ("From", "ann@example.com")]))
        self.assertEqual((rows, stats["refused"]), ([], {"authentication_failed": 1}))

    def test_a_display_name_never_picks_the_account(self) -> None:
        # The display name says Ann; the authenticated address is Bob's (unconfirmed account) -> refused.
        stats, rows = self._filed(self._raw_headers([
            ("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com; dmarc=pass"),
            ("From", '"ann@example.com" <bob@example.com>')]))
        self.assertEqual((rows, stats["refused"]), ([], {"account_email_not_confirmed": 1}))

    def test_a_lookalike_authserv_is_not_google(self) -> None:
        stats, rows = self._filed(self._raw_headers([
            ("Authentication-Results", "mx.google.com.attacker.net; dkim=pass header.d=example.com; dmarc=pass"),
            ("From", "ann@example.com")]))
        self.assertEqual((rows, stats["refused"]), ([], {"no_trusted_authentication_results": 1}))

    def test_the_message_id_list_keeps_hex_ids_and_reports_the_rest(self) -> None:
        p = os.path.join(tempfile.mkdtemp(), "ids.txt")
        Path(p).write_text("199496a0433c8861\n19949c81b9b45d6b 199496a0433c8861 # dup\n../etc\n1995ec564cc9f87e\n")
        self.assertEqual(self.g.read_message_ids(p),
                         (["199496a0433c8861", "19949c81b9b45d6b", "1995ec564cc9f87e"], ["../etc"]))

    def test_gog_ids_are_validated_before_any_subprocess(self) -> None:
        for bad in ("", "../x", "a b", "m1;rm"):
            with self.assertRaises(ValueError):
                self.g.gog_raw(bad)


class RecentIntakeTest(unittest.TestCase):
    """credit-proof.py file-recent: the hourly intake (proof-loop lead 068)."""

    def setUp(self) -> None:
        from credit_verify.proof import recent
        self.r = recent
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state.json")
        self.searches: list[dict] = []
        self.filed: list[list[str]] = []
        self.msgs_filed: list[list[str]] = []
        self.pages = [{"conversations": [{"id": "c1"}, {"id": "c2"}], "pages": {"next": {"starting_after": "x"}}},
                      {"conversations": [{"id": "c3"}], "pages": {}}]
        self.deferred: list[str] = []

    def _search(self, body):
        self.searches.append(body)
        return self.pages[len(self.searches) - 1] if len(self.searches) <= len(self.pages) else {"conversations": []}

    def _run(self, apply=True, now=10_000.0, gmail=None, file_messages=None):
        def fc(ids):
            self.filed.append(ids)
            return {"deferred_conversations": list(self.deferred)}

        def fm(ids):
            self.msgs_filed.append(ids)
            return {"fetch_errors": []}
        return self.r.run(state_path=self.state, hours=2, apply=apply, now=now, conv_search=self._search,
                          gmail_search=gmail, file_conversations=fc, file_messages=file_messages or fm)

    def test_support_messages_over_the_cap_are_carried_never_dropped(self) -> None:
        ids = [f"m{i}" for i in range(7)]
        gm = lambda q, page: {"messages": [{"id": i} for i in ids]}             # noqa: E731
        run = lambda now: self.r.run(state_path=self.state, hours=2, apply=True, now=now,  # noqa: E731
                                     conv_search=self._search, gmail_search=gm, max_messages=3,
                                     file_conversations=lambda c: {"deferred_conversations": []},
                                     file_messages=lambda m: self.msgs_filed.append(m) or {"fetch_errors": []})
        out = run(10_000.0)
        self.assertEqual((self.msgs_filed[-1], out["messages_carried_out"]), (["m0", "m1", "m2"], 4))
        self.assertTrue(out["window_advanced"])                                  # carried, so the window moves
        ids[:] = ["m9"]                                                          # the next window finds one new
        out = run(13_600.0)
        self.assertEqual(self.msgs_filed[-1], ["m3", "m4", "m5"])                # carried ones first
        self.assertEqual(out["messages_carried_out"], 2)
        run(17_200.0)
        self.assertEqual(self.msgs_filed[-1], ["m6", "m9"])
        self.assertEqual(sorted(sum(self.msgs_filed, [])), sorted([f"m{i}" for i in range(7)] + ["m9"]))
        self.assertEqual(json.loads(Path(self.state).read_text())["carry_messages"], [])

    def test_no_gmail_keeps_queued_messages_for_a_later_enabled_run(self) -> None:
        # QA #1488: --no-gmail (gmail_search=None) must not fetch or file carried support@ ids, nor drop them.
        Path(self.state).write_text(json.dumps({"since": 9_000.0, "carry": [], "carry_messages": ["queued1"]}))
        filed: list[list[str]] = []

        def run(now, gm):
            return self.r.run(state_path=self.state, hours=2, apply=True, now=now, conv_search=self._search,
                              gmail_search=gm, max_messages=60, file_conversations=lambda c: {"deferred_conversations": []},
                              file_messages=lambda ids: filed.append(list(ids)) or {"fetch_errors": []})
        out = run(10_000.0, None)                                                   # Intercom only
        self.assertEqual((filed, out["messages"]), ([], 0))
        self.assertEqual(json.loads(Path(self.state).read_text())["carry_messages"], ["queued1"])
        run(13_600.0, None)                                                          # still disabled: still kept
        self.assertEqual(json.loads(Path(self.state).read_text())["carry_messages"], ["queued1"])
        run(17_200.0, lambda q, page: {"messages": [{"id": "new1"}]})               # enabled again
        self.assertEqual(filed, [["queued1", "new1"]])
        self.assertEqual(json.loads(Path(self.state).read_text())["carry_messages"], [])

    def test_a_carried_message_whose_fetch_fails_stays_carried(self) -> None:
        # QA #1488: an aged carried id (older than the 7-day search clamp) is never re-found by the search; a
        # failed fetch must keep it in carry_messages, ahead of new work, and run 2 retries it.
        Path(self.state).write_text(json.dumps({"since": 9_000.0, "carry": [], "carry_messages": ["old1"]}))
        seen = []
        fail = {"old1": True}
        gm = lambda q, page: {"messages": [{"id": "new1"}]}                                   # noqa: E731

        def fm(ids):
            seen.append(list(ids))
            return {"fetch_errors": [f"{m}: OSError" for m in ids if fail.get(m)]}
        run = lambda now: self.r.run(state_path=self.state, hours=2, apply=True, now=now,  # noqa: E731
                                     conv_search=self._search, gmail_search=gm, max_messages=60,
                                     file_conversations=lambda c: {"deferred_conversations": []}, file_messages=fm)
        out = run(10_000.0 + 8 * 86400)
        self.assertEqual(seen[-1], ["old1", "new1"])
        self.assertFalse(out["window_advanced"])                                   # a failed fetch holds the window
        self.assertEqual(json.loads(Path(self.state).read_text())["carry_messages"], ["old1"])
        fail["old1"] = False
        run(10_000.0 + 8 * 86400 + 3600)
        self.assertEqual(seen[-1][0], "old1")                                        # retried, first
        self.assertEqual(json.loads(Path(self.state).read_text())["carry_messages"], [])

    def test_an_unwritable_unresolved_tray_holds_the_window(self) -> None:
        # QA #1481: the tray append happens inside the pass, before save_state; a failure leaves the cursor.
        u = {"conversation_id": "c2", "why": "unresolved: the contact is younger than 24 h", "files": ["ab"]}

        def fc(ids):
            self.filed.append(ids)
            return {"deferred_conversations": [], "unresolved": [u]}
        bad = os.path.join(self.state + ".notadir", "x", "tray.jsonl")
        Path(self.state + ".notadir").write_text("a file, so its child directory cannot exist")
        with self.assertRaises(OSError):
            self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                       gmail_search=None, file_conversations=self.r.with_unresolved_tray(fc, bad, True),
                       file_messages=lambda ids: {})
        # the pass did not finish, and nothing it found is lost: every conversation is still carried by id
        self.assertEqual(json.loads(Path(self.state).read_text())["carry"], ["c1", "c2", "c3"])
        self.assertNotIn("last_run", {k for k, v in json.loads(Path(self.state).read_text()).items() if v})
        good = os.path.join(os.path.dirname(self.state), "tray.jsonl")
        self.searches.clear()                                                   # the same window again
        out = self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                         gmail_search=None, file_conversations=self.r.with_unresolved_tray(fc, good, True),
                         file_messages=lambda ids: {})
        self.assertTrue(out["window_advanced"])
        line = json.loads(Path(good).read_text().splitlines()[0])
        self.assertEqual((line["conversation_id"], line["source"]), ("c2", "intercom"))
        self.assertEqual(os.stat(good).st_mode & 0o777, 0o600)
        dry = os.path.join(os.path.dirname(self.state), "dry.jsonl")             # a dry run writes no tray
        self.r.with_unresolved_tray(fc, dry, False)(["c2"])
        self.assertFalse(os.path.exists(dry))
        src = (Path(__file__).resolve().parents[1] / "credit-proof.py").read_text()
        body = src[src.index("def cmd_file_recent("):src.index("def cmd_email(")]
        self.assertIn("recent.with_unresolved_tray(", body)
        self.assertNotIn('open(UNRESOLVED, "a"', body)                           # no append after the pass

    def _many(self, n: int) -> list[str]:
        ids = [f"k{i:03d}" for i in range(n)]
        self.pages = [{"conversations": [{"id": i} for i in ids], "pages": {}}]
        return ids

    def test_a_run_out_of_time_carries_the_rest_and_the_window_moves(self) -> None:
        # 2026-11-13: one run could not read a 24 h window inside the cron's kill, saved nothing, and the next
        # run started over on a longer one - 36 failed runs in 41 h. A run now stops at its own limit.
        ids = self._many(60)
        ticks = iter([0.0, 1.0, 2.0, 99.0, 99.0, 99.0])                 # the limit is passed after two chunks
        out = self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                         gmail_search=None, max_seconds=50.0, chunk=20, clock=lambda: next(ticks),
                         file_conversations=lambda c: self.filed.append(c) or {"deferred_conversations": []},
                         file_messages=lambda m: {})
        self.assertEqual(self.filed, [ids[:20], ids[20:40]])
        self.assertEqual((out["out_of_time"], out["carried_out"], out["window_advanced"]), (20, 20, True))
        st = json.loads(Path(self.state).read_text())
        self.assertEqual((st["carry"], st["since"]), (ids[40:], 10_000.0))
        self.searches.clear()
        self.pages = [{"conversations": [{"id": "new1"}], "pages": {}}]
        self._run(apply=True, now=13_600.0)                                # the next run: the carried ones first
        self.assertEqual(self.filed[-1], ids[40:] + ["new1"])
        self.assertEqual(json.loads(Path(self.state).read_text())["carry"], [])

    def test_a_run_out_of_time_on_intercom_still_files_its_support_messages(self) -> None:
        # 2026-11-13: 2,888 conversations carried and 118 emailed documents waiting behind them. Messages are
        # capped by count, so a conversation backlog never holds them.
        ids = self._many(60)
        ticks = iter([0.0, 1.0, 99.0, 99.0])                               # the limit is passed after one chunk
        got: list[list[str]] = []
        out = self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                         gmail_search=lambda q, page: {"messages": [{"id": f"m{i}"} for i in range(5)]},
                         max_messages=3, max_seconds=50.0, chunk=20, clock=lambda: next(ticks),
                         file_conversations=lambda c: {"deferred_conversations": []},
                         file_messages=lambda m: got.append(list(m)) or {})
        self.assertEqual((out["out_of_time"], got), (40, [["m0", "m1", "m2"]]))
        st = json.loads(Path(self.state).read_text())
        self.assertEqual((st["carry"], st["carry_messages"]), (ids[20:], ["m3", "m4"]))

    def test_a_killed_run_loses_nothing_and_redoes_at_most_one_chunk(self) -> None:
        ids = self._many(60)

        class Killed(BaseException):                                       # the cron's kill: no handler runs
            pass

        def fc(part):
            if part[0] == ids[40]:
                raise Killed()
            self.filed.append(part)
            return {"deferred_conversations": [ids[3]] if ids[3] in part else []}
        with self.assertRaises(Killed):
            self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                       gmail_search=None, chunk=20, file_conversations=fc, file_messages=lambda m: {})
        st = json.loads(Path(self.state).read_text())
        # the two chunks that finished are not redone; the one the kill interrupted and the deferred one are
        self.assertEqual(st["carry"], [ids[3]] + ids[40:])
        self.assertEqual(st["since"], 10_000.0)                             # the search itself is not repeated
        self.assertIsNone(st["last_run"])                                   # and the run is not called finished
        self.searches.clear()
        self.pages = [{"conversations": [], "pages": {}}]
        self.filed.clear()
        self._run(apply=True, now=13_600.0)
        self.assertEqual(self.filed, [[ids[3]] + ids[40:]])
        self.assertEqual(self.searches[0]["query"]["value"], int(10_000 - 600))

    def test_a_killed_run_whose_search_was_cut_short_keeps_its_window(self) -> None:
        self._many(3)
        self.r.MAX_PAGES, old = 0, self.r.MAX_PAGES                         # the search is never complete
        Path(self.state).write_text(json.dumps({"since": 9_000.0, "carry": ["old1"], "carry_messages": []}))
        try:
            with self.assertRaises(RuntimeError):
                self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                           gmail_search=None, file_messages=lambda m: {},
                           file_conversations=lambda c: (_ for _ in ()).throw(RuntimeError("killed")))
        finally:
            self.r.MAX_PAGES = old
        st = json.loads(Path(self.state).read_text())
        self.assertEqual((st["since"], st["carry"]), (9_000.0, ["old1"]))

    def test_a_chunk_with_a_transient_error_is_carried_whole(self) -> None:
        ids = self._many(4)

        def fc(part):
            self.filed.append(part)
            return {"deferred_conversations": [], "errors": ["…00002: HTTPError"] if ids[2] in part else [],
                    "files_filed": 1, "links_by_class": {"dsp": 1}}
        out = self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                         gmail_search=None, chunk=2, file_conversations=fc, file_messages=lambda m: {})
        self.assertEqual(json.loads(Path(self.state).read_text())["carry"], ids[2:])
        self.assertFalse(out["window_advanced"])
        # the chunks' counts are one run's counts
        self.assertEqual((out["intercom"]["files_filed"], out["intercom"]["links_by_class"]), (2, {"dsp": 2}))

    def test_the_log_line_counts_the_unresolved_and_keeps_the_support_stats(self) -> None:
        # the unresolved list is long (a conversation id and every file hash each) and the line is cut at 2000
        # characters: listed in full it cut off the support@ stats, so a run's email result could not be read
        lines: list[str] = []
        many = [{"conversation_id": str(10**14 + i), "why": "unresolved: the external_id is not a Muso account",
                 "files": ["a" * 64], "received_at": ["2026-11-06T00:42:19Z"]} for i in range(60)]
        self._many(1)
        out = self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                         gmail_search=lambda q, page: {"messages": [{"id": "m1"}]},
                         file_conversations=lambda ids: {"deferred_conversations": [], "unresolved": many},
                         file_messages=lambda ids: {"filed": 1, "fetch_errors": []}, log=lines.append)
        self.assertEqual(len(out["unresolved"]), 60)                   # the caller still gets the list
        line = [x for x in lines if x.startswith("file-recent ")][-1]
        got = json.loads(line[len("file-recent "):])                   # whole, not cut
        self.assertEqual((got["unresolved"], got["gmail"]), (60, {"filed": 1, "fetch_errors": 0}))

    def test_a_dry_run_saves_no_checkpoint(self) -> None:
        self._many(60)
        self.r.run(state_path=self.state, hours=2, apply=False, now=10_000.0, conv_search=self._search,
                   gmail_search=None, chunk=20, file_conversations=lambda c: {"deferred_conversations": []},
                   file_messages=lambda m: {})
        self.assertFalse(os.path.exists(self.state))

    def test_the_cron_stops_itself_before_the_gateway_kills_it(self) -> None:
        jobs = json.loads((Path(__file__).resolve().parents[2] / "cron-jobs.json").read_text())["jobs"]
        job = next(j for j in jobs if j["name"] == "credit-verify-proof-file")
        self.assertGreaterEqual(job["payload"]["timeoutSeconds"] - self.r.MAX_SECONDS, 600)
        self.assertEqual(self.r.MAX_SECONDS, 2400.0)

    def test_first_run_files_the_last_hours_paged_and_advances_only_on_apply(self) -> None:
        out = self._run(apply=False)
        self.assertEqual(self.filed, [["c1", "c2", "c3"]])
        self.assertEqual(self.searches[0]["query"], {"field": "updated_at", "operator": ">",
                                                     "value": int(10_000 - 7200 - 600)})
        self.assertEqual(self.searches[1]["pagination"]["starting_after"], "x")
        self.assertFalse(os.path.exists(self.state))                       # a dry run never moves the window
        self.assertFalse(out.get("window_advanced"))
        self.searches.clear()
        out = self._run(apply=True)
        self.assertTrue(out["window_advanced"])
        self.assertEqual(json.loads(Path(self.state).read_text())["since"], 10_000.0)

    def test_the_next_run_starts_at_the_last_run_with_overlap(self) -> None:
        self._run(apply=True, now=10_000.0)
        self.searches.clear()
        self.pages = [{"conversations": [], "pages": {}}]
        self._run(apply=True, now=13_600.0)
        self.assertEqual(self.searches[0]["query"]["value"], int(10_000 - 600))

    def test_deferred_conversations_are_carried_never_dropped(self) -> None:
        self.deferred = ["c3"]
        self._run(apply=True, now=10_000.0)
        self.assertEqual(json.loads(Path(self.state).read_text())["carry"], ["c3"])
        self.deferred = []
        self.searches.clear()
        self.pages = [{"conversations": [{"id": "c9"}], "pages": {}}]
        self._run(apply=True, now=13_600.0)
        self.assertEqual(self.filed[-1], ["c3", "c9"])                       # the carried one first

    def test_a_page_cap_or_a_failed_message_holds_the_window(self) -> None:
        self.r.MAX_PAGES, old = 1, self.r.MAX_PAGES
        try:
            out = self._run(apply=True)
        finally:
            self.r.MAX_PAGES = old
        self.assertEqual((out["complete"], out["window_advanced"]), (False, False))
        self.searches.clear()
        out = self._run(apply=True, gmail=lambda q, page: {"messages": [{"id": "m1"}]},
                        file_messages=lambda ids: {"fetch_errors": ["m1: RuntimeError"]})
        self.assertEqual((out["retry_messages"], out["window_advanced"]), (["m1"], False))

    def test_a_failed_first_run_keeps_its_window_start(self) -> None:
        # QA #1447: an incomplete FIRST run saved since=null; a run hours later then skipped the gap.
        out = self._run(apply=True, now=10_000.0, gmail=lambda q, page: {"messages": [{"id": "m1"}]},
                        file_messages=lambda ids: {"fetch_errors": ["m1: RuntimeError"]})
        self.assertFalse(out["window_advanced"])
        self.assertEqual(json.loads(Path(self.state).read_text())["since"], 10_000.0 - 7200)
        self.searches.clear()
        self.pages = [{"conversations": [], "pages": {}}]
        self._run(apply=True, now=50_000.0)                                      # 11 h later
        self.assertEqual(self.searches[0]["query"]["value"], int(10_000 - 7200 - 600))   # not 50_000 - 7200

    def test_a_transient_intercom_error_holds_the_window_a_permanent_one_does_not(self) -> None:
        def run_with(errors):
            def fc(ids):
                self.filed.append(ids)
                return {"deferred_conversations": [], "errors": errors}
            return self.r.run(state_path=self.state, hours=2, apply=True, now=10_000.0, conv_search=self._search,
                              gmail_search=None, file_conversations=fc, file_messages=lambda ids: {})
        out = run_with(["…12345#0: HTTPError"])                               # download failed: retry the range
        self.assertEqual((out["window_advanced"], out["intercom_transient_errors"]), (False, ["…12345#0: HTTPError"]))
        os.remove(self.state)
        self.searches.clear()
        out = run_with(["…12345#0: ValueError"])                              # over 25 MB: never retriable
        self.assertTrue(out["window_advanced"])

    def test_gmail_search_asks_for_attachments_since_the_window(self) -> None:
        asked = []
        self._run(apply=False, gmail=lambda q, page: asked.append(q) or {"messages": [{"id": "m1"}, {"id": "m2"}]})
        self.assertEqual(asked, [f"has:attachment after:{int(10_000 - 7200 - 600)}"])
        self.assertEqual(self.msgs_filed, [["m1", "m2"]])

    def test_one_run_at_a_time(self) -> None:
        fd = self.r.locked(self.state)
        try:
            with self.assertRaises(self.r.Busy):
                self._run()
        finally:
            os.close(fd)

    def test_paid_accounts_first(self) -> None:
        self.assertEqual(self.r.paid_first(["a", "b", "c"], {"b": {7}, "c": {9}}, {7}), ["b", "a", "c"])

    def test_the_cron_is_committed_file_only_and_on(self) -> None:
        jobs = json.loads((Path(__file__).resolve().parents[2] / "cron-jobs.json").read_text())["jobs"]
        job = next(j for j in jobs if j["name"] == "credit-verify-proof-file")
        self.assertEqual(job["enabled"], True)                               # Fable [key=intake-reenable] 01:0xZ
        self.assertIn("--apply", job["payload"]["argv"])
        # captain 12:18Z item 2: support@ filing needs the forged-header tests (#1446, merged) - now ON (Fable
        # 2026-10-29 05:04Z, after a read-only gog run on the cron identity), under the same 60 per-run cap
        self.assertNotIn("--no-gmail", job["payload"]["argv"])
        self.assertEqual(job["payload"]["argv"][job["payload"]["argv"].index("--max-fetches") + 1], "60")
        src = (Path(__file__).resolve().parents[1] / "credit-proof.py").read_text()
        body = src[src.index("def cmd_file_recent("):src.index("def cmd_email(")]
        self.assertIn("max_messages=args.max_fetches", body)
        email = next(j for j in jobs if j["name"] == "credit-verify-proof-email")
        self.assertEqual(email["enabled"], False)                            # the support@ email cron stays dark
        self.assertEqual(job["payload"]["argv"][:3], ["python3", "/opt/hydra/scripts/credit-proof.py", "file-recent"])
        self.assertEqual(job["sessionTarget"], "isolated")
        src = (Path(__file__).resolve().parents[1] / "credit_verify" / "proof" / "recent.py").read_text()
        for banned in ("send-gateway", "intercom-verify-request", "/admin/credit", "PUT", "PATCH", "/reply"):
            self.assertNotIn(banned, src)

if __name__ == "__main__":
    unittest.main()
