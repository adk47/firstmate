#!/usr/bin/env python3
"""Tests for link replies (r5 COPY RULING fable-copy-1101-r5/r1-link): scripts/credit_verify/proof/links.py,
the proof_link_intake table and intake.run(link_policy=...).

What this pins:
  - a link is NEVER a proof_intake row (every proof_intake reader treats a row as a document on file);
  - the host class comes from the ONE policy file; subdomains match, suffix tricks do not; shorteners, IP
    literals, muso.ai and everything else are never outside_source;
  - only outside_source links are fetched; plain http, a non-public address and a redirect off the link's own
    allowlist entry are refused before or instead of a connection; a fetch never raises;
  - links of an unresolved thread are counted, never filed; staff links and Intercom file hosts are not links;
  - a dry run fetches nothing and writes nothing; re-filing is idempotent; the fetch budget defers, never drops.

    python3 scripts/tests/test_proof_links.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_verify.proof import intake
from credit_verify.proof import links as L
from credit_verify.proof.store import ProofStore

POL = L.load_policy()


def conv(cid: str, user_bodies: list[str], *, staff_bodies: list[str] = (), attachments: list[dict] = ()) -> dict:
    parts = [{"id": f"s{i}", "created_at": 10 + i, "author": {"type": "admin", "id": "1"}, "body": b}
             for i, b in enumerate(staff_bodies)]
    parts += [{"id": f"u{i}", "created_at": 100 + i, "author": {"type": "user", "id": "9"}, "body": b,
               "attachments": list(attachments) if i == 0 else []} for i, b in enumerate(user_bodies)]
    return {"id": cid, "created_at": 0,
            "source": {"id": "src", "author": {"type": "admin", "id": "1"}, "body": "<p>please send proof</p>"},
            "contacts": {"contacts": [{"id": f"c-{cid}", "external_id": "pro-a"}]},
            "conversation_parts": {"conversation_parts": parts}}


class PolicyAndClassTest(unittest.TestCase):
    def test_policy_holds_exactly_the_ruled_outside_sources(self) -> None:
        self.assertEqual(set(POL.outside_source), {"tidal.com", "genius.com", "discogs.com", "allmusic.com",
                                                   "ascap.com", "bmi.com"})
        self.assertIn("muso.ai", POL.muso)

    def test_empty_or_missing_policy_raises(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"outside_source": [], "muso": ["muso.ai"]}, fh)
        try:
            with self.assertRaises(ValueError):
                L.load_policy(fh.name)
        finally:
            os.unlink(fh.name)
        with self.assertRaises(OSError):
            L.load_policy("/nonexistent/proof-link-hosts.json")

    def test_classes(self) -> None:
        cases = {
            "https://tidal.com/browse/track/123": ("outside_source", "allowlist:tidal.com"),
            "https://listen.tidal.com/album/9": ("outside_source", "allowlist:tidal.com"),
            "https://GENIUS.com/Artist-song-lyrics#credits": ("outside_source", "allowlist:genius.com"),
            "https://repertoire.bmi.com/x?y=1": ("outside_source", "allowlist:bmi.com"),
            "https://eviltidal.com/track/1": ("unknown", "other"),                 # suffix trick
            "https://tidal.com.evil.io/track/1": ("unknown", "other"),
            "https://muso.ai/profile/1": ("muso", "muso:muso.ai"),
            "https://app.muso.ai/x": ("muso", "muso:muso.ai"),
            "https://bit.ly/abc": ("unknown", "shortener"),
            "https://lnk.to/song": ("unknown", "shortener"),
            "https://93.184.216.34/x": ("unknown", "ip_literal"),
            "https://open.spotify.com/track/1": ("unknown", "other"),             # not named by the ruling
            "ftp://tidal.com/x": ("unknown", "unparseable"),
            "notaurl": ("unknown", "unparseable"),
        }
        for url, want in cases.items():
            self.assertEqual(L.classify(url, POL), want, url)

    def test_normalise(self) -> None:
        self.assertEqual(L.normalise("HTTPS://Tidal.COM:443/track/1#x)."), "https://tidal.com/track/1")
        self.assertEqual(L.normalise("https://tidal.com"), "https://tidal.com/")
        self.assertIsNone(L.normalise("javascript:alert(1)"))
        self.assertIsNone(L.normalise("https://tidal.com:99999/x"))


class CustomerLinksTest(unittest.TestCase):
    def test_only_customer_parts_and_no_intercom_file_hosts(self) -> None:
        d = conv("1", [('<p>see <a href="https://tidal.com/track/1">https://tidal.com/track/1</a> and '
                        'https://www.discogs.com/release/5.</p>'),
                       '<p>https://musoai.intercom-attachments-3.com/i/o/1/split.pdf</p>'],
                 staff_bodies=['<p>our page https://genius.com/staff-link</p>'])
        got = [x["url"] for x in L.customer_links(d, POL)]
        self.assertEqual(got, ["https://tidal.com/track/1", "https://www.discogs.com/release/5"])

    def test_html_entities_and_duplicates(self) -> None:
        d = conv("1", ['<a href="https://tidal.com/a?x=1&amp;y=2">t</a>', "https://tidal.com/a?x=1&y=2"])
        self.assertEqual([x["url"] for x in L.customer_links(d, POL)], ["https://tidal.com/a?x=1&y=2"])


class FetchTest(unittest.TestCase):
    def test_never_fetches_a_non_allowlisted_host(self) -> None:
        calls = []
        for url in ("https://muso.ai/x", "https://bit.ly/x", "https://example.com/x", "https://10.0.0.1/x"):
            r = L.fetch(url, POL, resolver=lambda h: calls.append(h) or ["93.184.216.34"],
                        getter=lambda u, ip: calls.append(u) or (200, None, b"", False))
            self.assertEqual(r["fetch_status"], "refused:not_allowlisted", url)
        self.assertEqual(calls, [])

    def test_plain_http_is_refused_without_a_connection(self) -> None:
        calls = []
        r = L.fetch("http://tidal.com/x", POL, resolver=lambda h: calls.append(h) or ["1.1.1.1"],
                    getter=lambda u, ip: calls.append(u) or (200, None, b"", False))
        self.assertEqual((r["fetch_status"], calls), ("refused:not_https", []))

    def test_a_private_address_is_refused(self) -> None:
        def resolver(h):
            raise PermissionError("non-public")
        r = L.fetch("https://tidal.com/x", POL, resolver=resolver, getter=lambda u, ip: self.fail("connected"))
        self.assertEqual(r["fetch_status"], "refused:non_public_address")

    def test_resolve_public_rejects_loopback(self) -> None:
        with self.assertRaises(PermissionError):
            L.resolve_public("localhost")

    def test_redirect_inside_the_entry_is_followed_off_the_entry_is_refused(self) -> None:
        seen = []
        def getter(u, ip):
            seen.append(u)
            if u == "https://tidal.com/t/1":
                return 301, "https://listen.tidal.com/t/1", b"", False
            if u == "https://listen.tidal.com/t/1":
                return 302, "https://evil.example/steal", b"", False
            self.fail(f"fetched {u}")
        r = L.fetch("https://tidal.com/t/1", POL, resolver=lambda h: ["93.184.216.34"], getter=getter)
        self.assertEqual((r["fetch_status"], r["final_host"]), ("refused:redirect_off_entry", "evil.example"))
        self.assertEqual(seen, ["https://tidal.com/t/1", "https://listen.tidal.com/t/1"])

    def test_ok_records_status_sha_title_and_never_the_body(self) -> None:
        body = b"<html><head><title> Song &amp; Credits </title></head><body>secret</body></html>"
        r = L.fetch("https://genius.com/x", POL, resolver=lambda h: ["93.184.216.34"],
                    getter=lambda u, ip: (200, None, body, False))
        self.assertEqual((r["fetch_status"], r["http_status"], r["title"], r["bytes"]), ("ok", 200, "Song & Credits", len(body)))
        self.assertNotIn("secret", json.dumps(r))
        r = L.fetch("https://genius.com/x", POL, resolver=lambda h: ["93.184.216.34"],
                    getter=lambda u, ip: (404, None, b"", False))
        self.assertEqual(r["fetch_status"], "http_404")

    def test_errors_and_redirect_loops_never_raise(self) -> None:
        def boom(u, ip):
            raise TimeoutError("slow")
        self.assertEqual(L.fetch("https://genius.com/x", POL, resolver=lambda h: ["1.1.1.1"], getter=boom)["fetch_status"],
                         "error:TimeoutError")
        r = L.fetch("https://genius.com/a", POL, resolver=lambda h: ["1.1.1.1"],
                    getter=lambda u, ip: (302, "/a" if u.endswith("/b") else "/b", b"", False))
        self.assertEqual(r["fetch_status"], "refused:too_many_redirects")


class IntakeLinksTest(unittest.TestCase):
    NOW = 2_000_000_000.0

    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="cvlinks-test-")
        self.cache = os.path.join(self.tmp, "cache")
        os.makedirs(self.cache)
        self.export = os.path.join(self.tmp, "proof-on-file.json")
        Path(self.export).write_text(json.dumps({"sources": [], "users": 0, "entries": []}))
        self.store = ProofStore(":memory:")
        self.docs = {"111": conv("111", ["<p>here: https://tidal.com/track/1 https://muso.ai/p/1 https://bit.ly/z</p>"])}
        self.ok = True
        self.fetched = []

    def _identity(self, cid, doc):
        return (11, "external_id+email") if self.ok else (None, "unresolved: 2 user contacts")

    def _fetch(self, url, policy):
        self.fetched.append(url)
        return {"fetch_status": "ok", "http_status": 200}

    def _run(self, *, apply=True, budget=30, policy=POL):
        return intake.run(self.store, conversations=list(self.docs), fetch=lambda c: self.docs.get(c),
                          lookup=lambda ids: {}, open_rows={11: [{"request_id": "r1", "status": "unverified"}]},
                          held={}, export_path=self.export, cache_root=self.cache, dl=lambda u, d: self.fail("download"),
                          apply=apply, identity=self._identity, filed_by="intake-cron", link_policy=policy,
                          link_fetch=self._fetch, max_link_fetches=budget)

    def test_links_go_to_proof_link_intake_never_proof_intake(self) -> None:
        st = self._run()
        self.assertEqual((st["links_seen"], st["links_filed"], st["files_filed"]), (3, 3, 0))
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM proof_intake").fetchone()[0], 0)
        rows = {r["url"]: dict(r) for r in self.store.db.execute("SELECT * FROM proof_link_intake")}
        self.assertEqual({u: (r["host_class"], r["doc_kind"]) for u, r in rows.items()},
                         {"https://tidal.com/track/1": ("outside_source", "link"), "https://muso.ai/p/1": ("muso", "link"),
                          "https://bit.ly/z": ("unknown", "link")})
        self.assertEqual(self.fetched, ["https://tidal.com/track/1"])            # only the outside source
        self.assertIsNone(rows["https://muso.ai/p/1"]["fetch_json"])
        self.assertEqual(json.loads(rows["https://tidal.com/track/1"]["candidate_request_ids_json"]), ["r1"])
        self.assertEqual(rows["https://tidal.com/track/1"]["user_id"], 11)

    def test_refile_is_idempotent_and_does_not_refetch(self) -> None:
        self._run()
        st = self._run()
        self.assertEqual((st["links_filed"], st["links_duplicate"]), (0, 3))
        self.assertEqual(len(self.fetched), 1)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM proof_link_intake").fetchone()[0], 3)

    def test_unresolved_thread_links_are_counted_never_filed(self) -> None:
        self.ok = False
        st = self._run()
        self.assertEqual((st["links_unresolved"], st["links_filed"]), (3, 0))
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM proof_link_intake").fetchone()[0], 0)
        self.assertEqual(self.fetched, [])

    def test_dry_run_fetches_and_writes_nothing(self) -> None:
        path = os.path.join(self.tmp, "p.sqlite")
        ProofStore(path).db.close()
        self.store = ProofStore.for_run(path, False)
        st = self._run(apply=False)
        self.assertEqual((st["links_filed"], st["link_fetch"]), (3, {"dry_run": 1}))
        self.assertEqual(self.fetched, [])
        self.assertEqual(ProofStore(path).db.execute("SELECT count(*) FROM proof_link_intake").fetchone()[0], 0)

    def test_budget_defers_never_drops(self) -> None:
        st = self._run(budget=0)
        self.assertEqual((st["links_filed"], st["link_fetch_deferred"], self.fetched), (3, 1, []))
        row = self.store.db.execute("SELECT fetch_json FROM proof_link_intake WHERE host_class='outside_source'").fetchone()
        self.assertEqual(json.loads(row[0])["fetch_status"], "deferred:budget")

    def test_off_by_default(self) -> None:
        st = intake.run(self.store, conversations=list(self.docs), fetch=lambda c: self.docs.get(c),
                        lookup=lambda ids: {}, open_rows={}, held={}, export_path=self.export, cache_root=self.cache,
                        apply=True, identity=self._identity, filed_by="intake-cron")
        self.assertEqual(st["links_seen"], 0)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM proof_link_intake").fetchone()[0], 0)

    def test_cron_does_not_pass_links_yet(self) -> None:
        jobs = json.loads((Path(__file__).resolve().parents[2] / "cron-jobs.json").read_text())
        jobs = jobs.get("jobs", jobs) if isinstance(jobs, dict) else jobs
        argv = next(j for j in jobs if j.get("name") == "credit-verify-proof-file")["payload"]["argv"]
        self.assertNotIn("--links", argv)      # turning it on is its own reviewed change


if __name__ == "__main__":
    unittest.main()
