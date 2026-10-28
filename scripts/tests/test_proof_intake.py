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


if __name__ == "__main__":
    unittest.main()
