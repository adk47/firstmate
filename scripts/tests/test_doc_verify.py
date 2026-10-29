#!/usr/bin/env python3
"""Tests for doc-verify (scripts/credit_verify/docverify): extraction,
forensics, independent cross-checks, the outcome gate and the runner.
Synthetic data only; the model, the network, DNS, Intercom, Trino and the
admin API are all faked.

    python3 scripts/tests/test_doc_verify.py
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time as _time
import unittest
import unittest.mock
import urllib.error
from datetime import date, datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_verify.docverify import VERSION, crosscheck as xc, forensics, gate, intel, runner  # noqa: E402
from credit_verify.docverify.extract import (Extraction, Extractor, claimant_elsewhere, fallback, norm_isrc,  # noqa: E402
                                             supports, validate)
from credit_verify.docverify.forensics import H3  # noqa: E402
from credit_verify.docverify.store import DocVerifyStore  # noqa: E402
from credit_verify.proof import FORENSICS_VERSION  # noqa: E402
from credit_verify.proof.store import ProofStore  # noqa: E402

RID = "11111111-2222-3333-4444-555555555555"
KEY = f"{RID}#Mixing"

GOOD_ANSWER = {
    "doc_type": "letter",
    "issuer": {"name": "Blue Fern Records", "type": "label", "confidence": 0.9},
    "signatory": {"name": "Dana Reyes", "title": "Label Manager", "confidence": 0.9},
    "sender": {"email": "dana@bluefern.com", "confidence": 0.9},
    "emails": ["info@bluefern.com", "not-an-email"],
    "is_email": False,
    "tracks": [{"title": "Night Drive", "isrc": "US-AB1-24-00001", "confidence": 0.9}],
    "credits": [{"person": "Ann Alpha", "role": "Mixing Engineer", "track": "Night Drive", "share_percent": None,
                 "confidence": 0.9}],
    "dates": [{"what": "signed", "date": "2025-03-01", "confidence": 0.9}, {"what": "sent", "date": "03/01/2025"}],
    "amounts": [{"what": "fee", "amount": 500, "currency": "USD", "confidence": 0.8}],
}


def or_response(obj, cost=0.0004):
    return {"model": "deepseek/deepseek-v4.1-flash-1017", "usage": {"prompt_tokens": 900, "completion_tokens": 300,
                                                                     "cost": cost},
            "choices": [{"message": {"content": json.dumps(obj)}}]}


class FakeNet(xc.Net):
    def __init__(self, *, mx="mx", mb=None, deezer=None, pages=None, txt=None, rdap=None):
        self._mx, self._mbmap, self._deezer, self._pages = mx, mb or {}, deezer or {}, pages or {}
        self._txt, self._rdap = txt or {}, rdap or {}
        self.calls: list[str] = []

    def txt(self, name):
        self.calls.append(f"txt:{name}")
        return self._txt.get(name, [])

    def mx(self, domain):
        self.calls.append(f"mx:{domain}")
        return self._mx if isinstance(self._mx, str) else self._mx.get(domain, "mx")

    def mb(self, path, params):
        self.calls.append(f"mb:{path}")
        if path in self._mbmap:
            return self._mbmap[path]
        raise urllib.error.HTTPError("u", 404, "nf", {}, None)

    def json(self, url):
        self.calls.append(url)
        if url.startswith("https://rdap.org/domain/"):
            reg = self._rdap.get(url.rsplit("/", 1)[1])
            if reg is None:
                raise urllib.error.HTTPError(url, 404, "nf", {}, None)
            return {"events": [{"eventAction": "registration", "eventDate": reg}]}
        if url in self._deezer:
            return self._deezer[url]
        return {"error": {"code": 800}}

    def text(self, url):
        self.calls.append(url)
        if url in self._pages:
            return self._pages[url]
        raise urllib.error.HTTPError(url, 404, "nf", {}, None)


def raw(name, role, source="tidal", at="2026-10-20T00:00:00Z"):
    return {"profile": {"name": name, "source": source, "id": name}, "credit": role, "updatedAt": at}


class ExtractTests(unittest.TestCase):
    def test_validate_retypes_and_bounds_every_field(self):
        ex = validate(GOOD_ANSWER)
        self.assertEqual(ex.issuer["name"], "Blue Fern Records")
        self.assertEqual(ex.sender["domain"], "bluefern.com")
        self.assertEqual(ex.emails, ["info@bluefern.com"])            # malformed address dropped
        self.assertEqual(ex.isrcs, ["USAB12400001"])                 # normalised
        self.assertEqual([d["date"] for d in ex.dates], ["2025-03-01"])  # non-ISO date dropped
        self.assertEqual(ex.issuer_name, "Blue Fern Records")

    def test_validate_rejects_junk(self):
        with self.assertRaises(ValueError):
            validate(["not", "an", "object"])
        ex = validate({"issuer": {"name": "null", "type": "hacker"}, "sender": {"email": "x@@y"}, "tracks": "x"})
        self.assertIsNone(ex.issuer_name)
        self.assertEqual(ex.issuer["type"], "none")
        self.assertIsNone(ex.sender["email"])

    def test_non_finite_or_non_numeric_confidence_is_zero(self):
        # QA #1380 06:36Z: max(0, min(1, nan)) == 1.0 let a NaN confidence pass every floor.
        for bad in ("NaN", float("nan"), float("inf"), float("-inf"), "Infinity", "0.9", True, None, [0.9]):
            ex = validate({**GOOD_ANSWER, "sender": {"email": "contact@mistyped.invalid", "confidence": bad},
                           "issuer": {"name": "Blue Fern", "type": "label", "confidence": bad}})
            self.assertEqual(ex.sender["confidence"], 0.0, repr(bad))
            self.assertIsNone(ex.issuer_name, repr(bad))
        # the model's raw JSON text: json.loads parses the NaN / Infinity literals
        raw = json.loads('{"credits": [{"person": "Ann Alpha", "role": "Mixing", "track": "Night Drive", '
                         '"share_percent": NaN, "confidence": NaN}], "amounts": [{"amount": Infinity}]}')
        ex = validate(raw)
        self.assertEqual((ex.credits[0]["confidence"], ex.credits[0]["share_percent"], ex.amounts),
                         (0.0, None, []))
        self.assertEqual(validate({**GOOD_ANSWER, "amounts": [{"amount": True}]}).amounts, [])
        # a floor never passes NaN even if a caller skipped validate
        self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), "mistyped.invalid", "Blue Fern", [], "x",
                                         float("nan")).status, xc.WEAK)

    def test_low_confidence_issuer_is_not_used(self):
        ex = validate({**GOOD_ANSWER, "issuer": {"name": "Blue Fern", "type": "label", "confidence": 0.3}})
        self.assertIsNone(ex.issuer_name)

    def test_supports_needs_name_role_family_and_track(self):
        ex = validate(GOOD_ANSWER)
        self.assertIsNotNone(supports(ex, ["Ann Alpha"], "Mixing", "Night Drive (feat. Bo)"))
        self.assertIsNone(supports(ex, ["Ann Alpha"], "Producer", "Night Drive"))     # other role family
        self.assertIsNone(supports(ex, ["Bob Beta"], "Mixing", "Night Drive"))        # other person
        self.assertIsNone(supports(ex, ["Ann Alpha"], "Mixing", "Day Walk"))          # other track
        low = validate({**GOOD_ANSWER, "credits": [{**GOOD_ANSWER["credits"][0], "confidence": 0.4}]})
        self.assertIsNone(supports(low, ["Ann Alpha"], "Mixing", "Night Drive"))
        no_track = validate({**GOOD_ANSWER, "credits": [{**GOOD_ANSWER["credits"][0], "track": None}]})
        self.assertIsNotNone(supports(no_track, ["Ann Alpha"], "Mixing", "Night Drive"))  # the one track listed
        two = validate({**GOOD_ANSWER, "tracks": [{"title": "A Song"}, {"title": "Night Drive"}],
                        "credits": [{**GOOD_ANSWER["credits"][0], "track": None}]})
        self.assertIsNone(supports(two, ["Ann Alpha"], "Mixing", "Night Drive"))

    def test_adjacent_title_never_supports_the_claim(self):
        # QA #1380: "Love Again" must not satisfy a claim on "Love".
        def doc(track, isrc=None):
            return validate({**GOOD_ANSWER, "tracks": [{"title": track, "isrc": isrc, "confidence": 0.9}],
                             "credits": [{**GOOD_ANSWER["credits"][0], "track": track}]})
        self.assertIsNone(supports(doc("Love Again"), ["Ann Alpha"], "Mixing", "Love"))
        self.assertIsNone(supports(doc("Love"), ["Ann Alpha"], "Mixing", "Love Again"))
        self.assertIsNone(supports(doc("Love (Remix)"), ["Ann Alpha"], "Mixing", "Love"))       # another recording
        self.assertIsNone(supports(doc("Love - Remastered"), ["Ann Alpha"], "Mixing", "Love"))
        self.assertIsNotNone(supports(doc("Love (feat. Bo)"), ["Ann Alpha"], "Mixing", "Love"))
        self.assertIsNotNone(supports(doc("LOVE"), ["Ann Alpha"], "Mixing", "love"))
        # the catalog ISRC on the document identifies the track even when the title differs
        self.assertIsNotNone(supports(doc("Love (Radio)", "USAB12400001"), ["Ann Alpha"], "Mixing", "Love",
                                      "USAB12400001"))
        self.assertIsNone(supports(doc("Love Again", "USAB12400009"), ["Ann Alpha"], "Mixing", "Love",
                                   "USAB12400001"))
        # end to end: H3 SUSPECT for coverage + DSP confirmation + an adjacent title is NOT verified
        ex = doc("Love Again")
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=ex, findings=[], checks=checks(xc_dsp=xc.POSITIVE),
                        account_held=False, extracted_support=supports(ex, ["Ann Alpha"], "Mixing", "Love"),
                        elsewhere=claimant_elsewhere(ex, ["Ann Alpha"], "Love"))
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)
        self.assertIn("Love Again", o.reason)

    def test_low_confidence_isrc_or_track_never_binds_support(self):
        # QA #1380 03:52Z: a 0.0-confidence ISRC bound a "Love Again" credit to "Love".
        ex = validate({**GOOD_ANSWER,
                       "tracks": [{"title": "Love Again", "isrc": "USAB12400001", "confidence": 0.0}],
                       "credits": [{**GOOD_ANSWER["credits"][0], "track": "Love Again"}]})
        self.assertIsNone(supports(ex, ["Ann Alpha"], "Mixing", "Love", "USAB12400001"))
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=ex, findings=[], checks=checks(xc_dsp=xc.POSITIVE),
                        account_held=False, extracted_support=supports(ex, ["Ann Alpha"], "Mixing", "Love",
                                                                       "USAB12400001"))
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)
        ok = validate({**GOOD_ANSWER,
                       "tracks": [{"title": "Love Again", "isrc": "USAB12400001", "confidence": 0.9}],
                       "credits": [{**GOOD_ANSWER["credits"][0], "track": "Love Again"}]})
        self.assertIsNotNone(supports(ok, ["Ann Alpha"], "Mixing", "Love", "USAB12400001"))
        # a credit with no track: the document's one track counts only when confidently read
        lone = validate({**GOOD_ANSWER, "tracks": [{"title": "Love", "confidence": 0.2}],
                         "credits": [{**GOOD_ANSWER["credits"][0], "track": None}]})
        self.assertIsNone(supports(lone, ["Ann Alpha"], "Mixing", "Love"))
        two = validate({**GOOD_ANSWER, "tracks": [{"title": "Love", "confidence": 0.9},
                                                  {"title": "Hate", "confidence": 0.2}],
                        "credits": [{**GOOD_ANSWER["credits"][0], "track": None}]})
        self.assertIsNone(supports(two, ["Ann Alpha"], "Mixing", "Love"))   # still two tracks on the page

    def test_claimant_credited_elsewhere_is_named(self):
        ex = validate(GOOD_ANSWER)
        self.assertEqual(claimant_elsewhere(ex, ["Ann Alpha"], "Day Walk"), ["Night Drive"])
        self.assertEqual(claimant_elsewhere(ex, ["Ann Alpha"], "Night Drive"), [])
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=ex, findings=[], checks=checks(xc_dsp=xc.POSITIVE),
                        account_held=False, elsewhere=["Night Drive"])
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)              # a real credit elsewhere is not proof here
        self.assertIn("other tracks (“Night Drive”)", o.reason)

    def test_norm_isrc(self):
        self.assertEqual(norm_isrc("gb-abc-23-12345"), "GBABC2312345")
        self.assertIsNone(norm_isrc("nope"))

    def test_extractor_records_every_call(self):
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            sent = []
            ext = Extractor(store, key="k", post=lambda body, key, t: (sent.append(body), or_response(GOOD_ANSWER))[1])
            ex = ext.extract("some text", {"mime": "application/pdf"}, "p1")
            self.assertTrue(ex.ok)
            body = sent[0]
            self.assertEqual(body["model"], "deepseek/deepseek-v4.1-flash-1017")
            self.assertEqual(body["provider"], {"data_collection": "deny"})
            self.assertNotIn("tools", body)
            self.assertIn("DATA", body["messages"][0]["content"])
            row = store.db.execute("SELECT outcome, prompt_sha256, cost_usd, input_tokens FROM dv_llm_calls").fetchone()
            self.assertEqual(row[0], "ok")
            self.assertEqual(len(row[1]), 64)
            self.assertAlmostEqual(row[2], 0.0004)

    def test_extractor_daily_cap_and_errors_fall_back_degraded(self):
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            store.llm_call({"outcome": "ok", "cost_usd": 6.0})
            ext = Extractor(store, key="k", post=lambda *a: self.fail("must not call over the cap"), daily_usd=5)
            ex = ext.extract("mail me at a@b.com ISRC USAB12400001", {}, "p1")
            self.assertFalse(ex.ok)
            self.assertTrue(ex.degraded)
            self.assertEqual(ex.emails, ["a@b.com"])
            self.assertEqual(ex.isrcs, ["USAB12400001"])

            def boom(*a):
                raise urllib.error.URLError("down")
            ex = Extractor(store, key="k", post=boom, daily_usd=100).extract("text", {}, "p2")
            self.assertTrue(ex.degraded)
            self.assertTrue(ex.error.startswith("transport:"))
            outcomes = [r[0] for r in store.db.execute("SELECT outcome FROM dv_llm_calls ORDER BY id")]
            self.assertEqual(outcomes, ["ok", "skipped", "error"])

    def test_unusable_answer_is_retried_once_then_degrades(self):
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            bad = {"choices": [{"message": {"content": "{not json"}, "finish_reason": "length"}],
                   "usage": {"cost": 0.001}}
            answers = [bad, or_response(GOOD_ANSWER)]
            ex = Extractor(store, key="k", post=lambda *a: answers.pop(0)).extract("text", {}, "p")
            self.assertTrue(ex.ok)
            rows = store.db.execute("SELECT outcome, reason, cost_usd FROM dv_llm_calls ORDER BY id").fetchall()
            self.assertEqual([r[0] for r in rows], ["error", "ok"])
            self.assertIn("finish=length", rows[0][1])
            self.assertAlmostEqual(sum(r[2] for r in rows), 0.0014)     # both attempts count against the cap
            calls = []
            # another document (the first one's answer is now cached for its exact prompt)
            ex = Extractor(store, key="k", post=lambda *a: (calls.append(1), bad)[1]).extract("other", {}, "q")
            self.assertEqual((ex.ok, ex.degraded, ex.error, len(calls)), (False, True, "unusable model answer", 2))

    def test_the_same_prompt_reuses_the_validated_answer_for_24h(self):
        # Proof-loop lead 079: 22% of good calls repeated a prompt answered < 1.3 h earlier.
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            calls = []
            post = lambda *a: (calls.append(1), or_response(GOOD_ANSWER))[1]     # noqa: E731
            first = Extractor(store, key="k", post=post).extract("doc text", {"mime": "application/pdf"}, "p1")
            again = Extractor(store, key="k", post=post).extract("doc text", {"mime": "application/pdf"}, "p1b")
            self.assertEqual(len(calls), 1)
            self.assertEqual(again.as_dict(), first.as_dict())
            rows = store.db.execute("SELECT outcome, cost_usd, prompt_sha256, reason FROM dv_llm_calls ORDER BY id").fetchall()
            self.assertEqual([r[0] for r in rows], ["ok", "cached"])
            self.assertEqual((rows[1][1], rows[1][2]), (0, rows[0][2]))
            self.assertIn("same prompt answered by call", rows[1][3])
            Extractor(store, key="k", post=post).extract("doc text", {"mime": "image/png"}, "p1")   # other facts
            Extractor(store, key="k", post=post).extract("doc text 2", {"mime": "application/pdf"}, "p1")
            self.assertEqual(len(calls), 3)                              # a different prompt is a new question
            store.llm_call({"outcome": "ok", "cost_usd": 99.0})          # over the daily cap: a cached answer
            ex = Extractor(store, key="k", post=lambda *a: self.fail("no call"), daily_usd=5).extract(
                "doc text", {"mime": "application/pdf"}, "p1")          # costs nothing and is still served
            self.assertTrue(ex.ok)
            with unittest.mock.patch("credit_verify.docverify.extract.time.time", return_value=_time.time() + 24 * 3600 + 1):
                Extractor(store, key="k", post=post, daily_usd=1000).extract("doc text", {"mime": "application/pdf"}, "p1")
            self.assertEqual(len(calls), 4)                              # past 24 h: asked again
            other = Extractor(store, key="k", model="another/model", post=post, daily_usd=1000)
            other.extract("doc text", {"mime": "application/pdf"}, "p1")
            self.assertEqual(len(calls), 5)                              # another model is never served this cache

    def test_the_cache_holds_only_the_validated_extraction_and_purges_expired_rows(self):
        # QA #1469: a model answer carrying an extra 50 KB `document_text` is cached WITHOUT it, bounded, and purged
        # after the TTL - the cache never keeps document contents.
        from credit_verify.docverify.extract import cache_payload
        secret = "PRIVATE CONTRACT " * 3000                                     # ~51 KB
        noisy = {**GOOD_ANSWER, "document_text": secret, "notes": {"raw": secret},
                 "issuer": {**GOOD_ANSWER["issuer"], "extra": secret, "name": "Blue Fern Records" + "x" * 500},
                 "credits": [{**GOOD_ANSWER["credits"][0], "comment": secret}]}
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            ex = Extractor(store, key="k", post=lambda *a: or_response(noisy)).extract("doc", {"mime": "x"}, "p1")
            (blob,) = store.db.execute("SELECT answer_json FROM dv_extract_cache").fetchone()
            self.assertNotIn("PRIVATE CONTRACT", blob)
            self.assertLess(len(blob), 4000)
            self.assertNotIn("document_text", json.loads(blob))
            self.assertEqual(set(json.loads(blob)), {"doc_type", "issuer", "signatory", "sender", "emails", "is_email",
                                                     "tracks", "credits", "dates", "amounts"})
            again = Extractor(store, key="k", post=lambda *a: self.fail("no call")).extract("doc", {"mime": "x"}, "p1")
            self.assertEqual(again.as_dict(), ex.as_dict())                       # served from the clean payload
            self.assertEqual({**validate(cache_payload(ex)).as_dict(), "model": None},
                             {**ex.as_dict(), "model": None})                        # the round trip is exact
            # a later write purges every row past the TTL
            store.cache_answer("other", "m", 1, cache_payload(ex), _time.time() + 24 * 3600 + 5)
            self.assertEqual([r[0] for r in store.db.execute("SELECT prompt_sha256 FROM dv_extract_cache")], ["other"])

    def test_an_answer_without_an_explicit_matching_model_is_never_cached(self):
        # QA #1469: the ledger row may fall back to the configured model when the provider omits `model`, but the
        # cache may only be filled on an explicit, exact report - an answer routed elsewhere (or unreported) must
        # not be replayed for 24 h as the configured model's.
        for label, resp in (("no model field", {k: v for k, v in or_response(GOOD_ANSWER).items() if k != "model"}),
                            ("another model", {**or_response(GOOD_ANSWER), "model": "someone/else-9b"}),
                            ("non-string model", {**or_response(GOOD_ANSWER), "model": {"id": "x"}})):
            with self.subTest(label), tempfile.TemporaryDirectory() as td:
                store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
                calls = []
                post = lambda *a: (calls.append(1), resp)[1]                  # noqa: E731
                first = Extractor(store, key="k", post=post).extract("doc text", {"mime": "application/pdf"}, "p1")
                self.assertTrue(first.ok)
                self.assertEqual(store.db.execute("SELECT count(*) FROM dv_extract_cache").fetchone()[0], 0, label)
                Extractor(store, key="k", post=post).extract("doc text", {"mime": "application/pdf"}, "p2")
                self.assertEqual(len(calls), 2, f"{label}: the second identical prompt must call the model again")
                # the ledger still records the audit label (configured model as fallback, or the reported one)
                models = [r[0] for r in store.db.execute("SELECT model FROM dv_llm_calls WHERE outcome = 'ok'")]
                self.assertEqual(len(models), 2)
                self.assertNotIn("_reported_model", json.dumps(models))
        # control: the explicit exact report IS cached (one network call for two identical prompts)
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            calls = []
            post = lambda *a: (calls.append(1), or_response(GOOD_ANSWER))[1]     # noqa: E731
            Extractor(store, key="k", post=post).extract("doc text", {"mime": "application/pdf"}, "p1")
            Extractor(store, key="k", post=post).extract("doc text", {"mime": "application/pdf"}, "p2")
            self.assertEqual(len(calls), 1)

    def test_a_failed_answer_is_never_cached(self):
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            bad = {"choices": [{"message": {"content": "{not json"}, "finish_reason": "length"}], "usage": {}}
            calls = []
            for _ in range(2):
                Extractor(store, key="k", post=lambda *a: (calls.append(1), bad)[1]).extract("t", {}, "p")
            self.assertEqual(len(calls), 4)                              # 2 runs x (call + one retry)
            self.assertEqual(store.db.execute("SELECT count(*) FROM dv_extract_cache").fetchone()[0], 0)
            store.db.execute("INSERT INTO dv_extract_cache VALUES (?, ?, ?, 1, '{\"doc_type\": 7')",
                             (store.db.execute("SELECT prompt_sha256 FROM dv_llm_calls LIMIT 1").fetchone()[0],
                              _time.time(), "deepseek/deepseek-v4.1-flash-1017"))
            store.db.commit()
            ok = Extractor(store, key="k", post=lambda *a: (calls.append(1), or_response(GOOD_ANSWER))[1]).extract("t", {}, "p")
            self.assertTrue(ok.ok)                                       # an unreadable cache row: asked live
            self.assertEqual(len(calls), 5)

    def test_retry_respects_the_daily_cap(self):
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            bad = {"choices": [{"message": {"content": "nope"}}], "usage": {"cost": 6.0}}
            calls = []
            ex = Extractor(store, key="k", post=lambda *a: (calls.append(1), bad)[1], daily_usd=5).extract("t", {}, "p")
            self.assertEqual((ex.degraded, len(calls)), (True, 1))
            self.assertEqual(store.db.execute("SELECT outcome FROM dv_llm_calls ORDER BY id DESC LIMIT 1").fetchone(),
                             ("skipped",))

    def test_unusable_answer_is_an_error_not_a_pass(self):
        with tempfile.TemporaryDirectory() as td:
            store = DocVerifyStore(os.path.join(td, "dv.sqlite"))
            bad = {"choices": [{"message": {"content": "I think it is fine"}}], "usage": {}}
            ex = Extractor(store, key="k", post=lambda *a: bad).extract("text", {}, "p")
            self.assertFalse(ex.ok)
            self.assertEqual(ex.error, "unusable model answer")


class ForensicsTests(unittest.TestCase):
    def ex(self, **kw):
        return Extraction(ok=True, **kw)

    def test_h3_forged_is_hard(self):
        f = forensics.check(H3("FORGED_LIKELY", ["edited"]), self.ex(), {}, "application/pdf")
        self.assertEqual(forensics.worst(f), forensics.HARD)

    def test_email_screenshot_is_weak(self):
        f = forensics.check(H3("GENUINE"), self.ex(is_email=True), {}, "image/png")
        self.assertIn("email_screenshot", [x.name for x in f])
        self.assertEqual(forensics.worst(f), forensics.WEAK)

    def test_file_older_than_the_date_it_claims(self):
        f = forensics.check(H3("GENUINE"), self.ex(dates=[{"what": "signed", "date": "2025-06-01", "confidence": 0.9}]),
                            {"created": "D:20240101120000+00'00'"}, "application/pdf", today=date(2026, 10, 26))
        names = {x.name: x.severity for x in f}
        self.assertEqual(names.get("file_predates_document"), forensics.SOFT)
        # a scan made after the signing date is normal
        f = forensics.check(H3("GENUINE"), self.ex(dates=[{"what": "signed", "date": "2023-06-01", "confidence": 0.9}]),
                            {"created": "D:20240101120000"}, "application/pdf", today=date(2026, 10, 26))
        self.assertIsNone(forensics.worst(f))

    def test_future_date_and_exif_date(self):
        f = forensics.check(H3("GENUINE"), self.ex(dates=[{"what": "issued", "date": "2027-01-01", "confidence": 0.9}]),
                            {"exif_datetime_original": "2026:01:02 10:00:00"}, "image/jpeg", today=date(2026, 10, 26))
        self.assertEqual({x.name for x in f}, {"document_date_future", "file_predates_document"})

    def test_h3_signals_mapped(self):
        h3 = H3("SUSPECT", signals=[{"name": "online_editor_producer", "severity": "soft"},
                                    {"name": "track_not_named", "severity": "soft"},
                                    {"name": "c2pa_ai_source", "severity": "soft"},
                                    {"name": "template_family", "severity": "info"}], kind="split_sheet")
        f = {x.name: x.severity for x in forensics.check(h3, self.ex(), {}, "application/pdf")}
        self.assertEqual(f["h3_online_editor_producer"], forensics.SOFT)
        self.assertNotIn("h3_track_not_named", f)                   # coverage, not doubt
        self.assertEqual(f["h3_c2pa_ai_source"], forensics.WEAK)
        self.assertEqual(f["template_reused"], forensics.SOFT)      # document of record

    @staticmethod
    def h3_store(verdict, signals, track_listed, at="2026-10-27T00:00:00Z", reasons=("r",)):
        ps = ProofStore(":memory:")
        ps.db.execute("INSERT INTO verdicts (proof_id, analyzer_version, contact_h, track_key, verdict, reasons_json, "
                      "context_json, created_at, request_id) VALUES ('p', ?, 'c', 't', ?, ?, '{}', ?, ?)",
                      (FORENSICS_VERSION, verdict, json.dumps(list(reasons)), at, KEY))
        for check, name, sev in signals:
            ps.db.execute("INSERT INTO forensics (proof_id, analyzer_version, check_id, name, severity, created_at, "
                          "request_id) VALUES ('p', ?, ?, ?, ?, ?, ?)", (FORENSICS_VERSION, check, name, sev, at, KEY))
        ps.db.execute("INSERT INTO fingerprints (proof_id, contact_h, kind, track_key, track_listed, created_at) "
                      "VALUES ('p', 'c', 'contract', 't', ?, ?)", (track_listed, at))
        return ps

    def test_read_h3_from_the_proof_store(self):
        ps = self.h3_store("GENUINE", [("F4a", "online_editor_producer", "soft")], 1)
        # a row from another write (an older run) is not this verdict's signal set
        ps.db.execute("INSERT INTO forensics (proof_id, analyzer_version, check_id, name, severity, created_at, "
                      "request_id) VALUES ('p', ?, 'F1', 'old_signal', 'soft', '2026-10-01T00:00:00Z', ?)",
                      (FORENSICS_VERSION, KEY))
        h3 = forensics.read_h3(ps.db, "p", KEY)
        self.assertEqual((h3.verdict, h3.names, h3.kind), ("GENUINE", {"online_editor_producer"}, "contract"))
        self.assertIsNone(forensics.read_h3(ps.db, "p", "other#Mixing").verdict)

    def test_forged_only_for_another_claim_reads_as_stage2_does(self):
        # Backfill 2026-10-27: an edit/paste + claimant_not_named on a document that does not list the
        # track is FORGED_LIKELY in raw H3 but a coverage gap in stage 2 (claim_verdict) -> SUSPECT.
        for edit in (("F4a", "after_creation_key_field_edit", "soft"), ("F3b", "copy_move_region", "soft")):
            ps = self.h3_store("FORGED_LIKELY", [edit, ("F5a", "track_not_named", "soft"),
                                                 ("F5b", "claimant_not_named", "mismatch")], 0)
            h3 = forensics.read_h3(ps.db, "p", KEY)
            self.assertEqual(h3.verdict, "SUSPECT", edit)
            self.assertNotIn("claimant_not_named", h3.names)
            f = forensics.check(h3, Extraction(ok=True), {}, "application/pdf")
            self.assertNotEqual(forensics.worst(f), forensics.HARD)
            o = gate.decide(h3_verdict=h3.verdict, kind=h3.kind, ex=validate(GOOD_ANSWER), findings=f,
                            checks=checks(xc_dsp=xc.UNKNOWN), account_held=False)
            self.assertEqual((o.outcome, o.account_hold), (gate.UNVERIFIABLE, False))

    def test_forged_that_lists_the_track_or_is_track_independent_stays_forged(self):
        listed = self.h3_store("FORGED_LIKELY", [("F4a", "after_creation_key_field_edit", "soft"),
                                                 ("F5b", "claimant_not_named", "mismatch")], 1)
        self.assertEqual(forensics.read_h3(listed.db, "p", KEY).verdict, "FORGED_LIKELY")
        hard = self.h3_store("FORGED_LIKELY", [("F3a", "ai_generator_software", "hard"),
                                               ("F5b", "claimant_not_named", "mismatch")], 0)
        self.assertEqual(forensics.read_h3(hard.db, "p", KEY).verdict, "FORGED_LIKELY")
        reuse = self.h3_store("FORGED_LIKELY", [("F2", "reused_on_another_track", "hard")], 0)
        h3 = forensics.read_h3(reuse.db, "p", KEY)
        self.assertEqual(h3.verdict, "FORGED_LIKELY")
        self.assertEqual(forensics.worst(forensics.check(h3, Extraction(ok=True), {}, None)), forensics.HARD)


class CrossCheckTests(unittest.TestCase):
    def test_dsp(self):
        self.assertEqual(xc.dsp([raw("Ann Alpha", "Mixing Engineer")], "Mixing", ["Ann Alpha"]).status, xc.POSITIVE)
        c = xc.dsp([raw("Bob Beta", "Mixer")], "Mixing", ["Ann Alpha"])
        # D5: a stored capture never contradicts; it is a possible conflict, never a hold
        self.assertEqual((c.status, c.detail.get("dsp_conflict")), (xc.UNKNOWN, True))
        self.assertEqual(xc.dsp([raw("Bob Beta", "Producer")], "Producer", ["Ann Alpha"]).status, xc.UNKNOWN)
        self.assertEqual(xc.dsp([raw("Ann Alpha", "Mixer", source="muso")], "Mixing", ["Ann Alpha"]).status,
                         xc.UNKNOWN)                                # Muso's own credits are not independent
        self.assertEqual(xc.dsp(None, "Mixing", ["Ann Alpha"], "boom").status, xc.ERROR)

    def test_contradiction_needs_a_fresh_capture_of_both_dsps_and_one_other_person(self):
        # Fable [key=doc-verify-go-live] Q3, 2026-10-27.
        from datetime import datetime, timedelta, timezone
        now = datetime.now(timezone.utc)
        since = (now - timedelta(minutes=40)).strftime("%Y-%m-%dT%H:%M:%SZ")
        fresh = (now - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        both = [raw("Bob Beta", "Mixer", "spotify", fresh), raw("Bob Beta", "Mixing Engineer", "tidal", fresh)]
        self.assertEqual(xc.dsp(both, "Mixing", ["Ann Alpha"], fresh_since=since).status, xc.CONTRADICTS)
        cases = {
            "no capture requested": (both, None),
            "stale rows only (79105: a 2025 capture)": ([raw("Bob Beta", "Mixer", "spotify", "2025-02-24T00:32:09Z"),
                                                         raw("Bob Beta", "Mixer", "tidal", "2025-02-24T00:32:09Z")],
                                                        since),
            "Tidal only": ([raw("Bob Beta", "Mixer", "tidal", fresh)], since),
            "Jaxsta alone": ([raw("Bob Beta", "Mixer", "jaxsta", fresh)], since),
            "two mixers (145842)": ([raw("Bizzo", "Mixing Engineer", "spotify", fresh),
                                     raw("Lucid", "Mixing Engineer", "spotify", fresh),
                                     raw("Bizzo", "Mixer", "tidal", fresh)], since),
            "different people per DSP": ([raw("Bob Beta", "Mixer", "spotify", fresh),
                                          raw("Cy Gamma", "Mixer", "tidal", fresh)], since),
        }
        for why, (rows, fs) in cases.items():
            c = xc.dsp(rows, "Mixing", ["Ann Alpha"], fresh_since=fs)
            self.assertEqual(c.status, xc.UNKNOWN, why)
            self.assertIn("possible conflict", c.detail["note"], why)
        # end to end through the gate: a possible conflict is unverifiable, never contradicted or held
        c = xc.dsp(cases["two mixers (145842)"][0], "Mixing", ["Ann Alpha"], fresh_since=since)
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=validate(GOOD_ANSWER), findings=[], checks=[c],
                        account_held=False)
        self.assertEqual((o.outcome, o.account_hold), (gate.UNVERIFIABLE, False))

    def test_domain(self):
        net = FakeNet()
        self.assertEqual(xc.domain_check(net, "gmail.com", "Blue Fern", [], "x").status, xc.WEAK)
        self.assertEqual(xc.domain_check(net, "bluefern.com", "Blue Fern", ["bluefern.com"], "x").status, xc.POSITIVE)
        self.assertEqual(xc.domain_check(net, "mail.bluefern.com", "Blue Fern", ["bluefern.com"], "x").status,
                         xc.POSITIVE)
        c = xc.domain_check(net, "bluefern-records.net", "Blue Fern", ["bluefern.com"], "x")
        self.assertEqual(c.status, xc.CONTRADICTS)
        self.assertIn("look-alike", c.detail["note"])
        self.assertEqual(xc.domain_check(net, "othermail.com", "Blue Fern", ["bluefern.com"], "x").status, xc.SOFT)
        self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), "bluefern-ghost.com", "Blue Fern", [], "x").status,
                         xc.CONTRADICTS)
        # Proof-loop lead 073: a TLD that does not exist is a misread address, never a fabricated one.
        nx = FakeNet(mx="nxdomain")
        c = xc.domain_check(nx, "michaelosbome.ora", "Michael Osborne", [], "x", 0.95)
        self.assertEqual((c.status, c.detail.get("unreadable")), (xc.WEAK, True))
        self.assertIn("'.ora' is not a top-level domain", c.detail["note"])
        self.assertEqual(nx.calls, [])                                   # no DNS lookup is evidence here
        for bad in ("bluefern.zz", "no-dot", "-bad-.com", "a..b.com"):
            self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), bad, "Blue Fern", [], "x").status, xc.WEAK, bad)
        for good in ("michaelosborne.org", "label.co.uk", "studio.music", "xn--80ak6aa92e.com"):
            self.assertIsNone(xc.readable_domain(good), good)
        self.assertEqual(xc.domain_check(net, "bluefern.com", "Blue Fern", [], "not found").status, xc.UNKNOWN)
        self.assertEqual(xc.domain_check(net, None, "Blue Fern", [], "x").status, xc.SKIPPED)

    def test_low_confidence_sender_never_forges_or_holds(self):
        # QA #1380 03:52Z: a 0.0-confidence misread sender forged the document and held the account.
        for c in (0.0, 0.59):
            self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), "mistyped.invalid", "Blue Fern", [], "x",
                                             c).status, xc.WEAK)
            self.assertEqual(xc.domain_check(FakeNet(), "bluefern-records.net", "Blue Fern", ["bluefern.com"],
                                             "x", c).status, xc.WEAK)
        net = FakeNet(mx="nxdomain")
        xc.domain_check(net, "mistyped.invalid", "Blue Fern", [], "x", 0.0)
        self.assertEqual(net.calls, [])                       # not even looked up
        self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), "mistyped-label.com", "Blue Fern", [], "x",
                                         0.6).status, xc.CONTRADICTS)

    def test_official_domains_never_from_the_document(self):
        net = FakeNet(mb={"label": {"labels": [{"id": "L1", "name": "Blue Fern Records", "score": 100}]},
                          "label/L1": {"relations": [{"type": "official homepage",
                                                      "url": {"resource": "https://www.bluefern.com/"}}]}})
        self.assertEqual(xc.official_domains(net, "Blue Fern Records"), (["bluefern.com"], "musicbrainz label L1"))
        doms, how = xc.official_domains(FakeNet(), "DistroKid")
        self.assertEqual(doms, ["distrokid.com"])
        self.assertIn("table", how)
        self.assertEqual(xc.official_domains(FakeNet(), "Unknown Shack")[0], [])

    def test_signatory(self):
        net = FakeNet(pages={"https://bluefern.com/team": "<h2>Team</h2><p>Dana Reyes - Label Manager</p>"})
        self.assertEqual(xc.signatory_check(net, "Dana Reyes", ["bluefern.com"]).status, xc.POSITIVE)
        self.assertEqual(xc.signatory_check(net, "Dan Reyesson", ["bluefern.com"]).status, xc.UNKNOWN)
        self.assertEqual(xc.signatory_check(net, "Dana Reyes", []).status, xc.UNKNOWN)

    def test_isrc_and_label(self):
        net = FakeNet(mb={"isrc/USAB12400001": {"recordings": [{"id": "R1"}]},
                          "recording/R1": {"relations": [{"type": "mix", "artist": {"name": "Ann Alpha"}}]}},
                      deezer={"https://api.deezer.com/track/isrc:USAB12400001": {"album": {"id": 9}, "contributors": []},
                              "https://api.deezer.com/album/9": {"label": "Blue Fern Records"}})
        rel = xc.release_facts(net, "USAB12400001")
        self.assertEqual(rel.label, "Blue Fern Records")
        self.assertEqual(xc.isrc_check(rel, "Mixing", ["Ann Alpha"]).status, xc.POSITIVE)
        self.assertEqual(xc.isrc_check(rel, "Mixing", ["Zed Zulu"]).status, xc.SOFT)   # community data: never contradicts
        self.assertEqual(xc.label_check("Blue Fern", "label", rel).status, xc.POSITIVE)
        self.assertEqual(xc.label_check("Red Rock Records", "label", rel).status, xc.SOFT)
        self.assertEqual(xc.label_check("DistroKid", "distributor", rel).status, xc.SKIPPED)
        self.assertEqual(xc.label_check("Recording Academy", "other", rel).status, xc.SKIPPED)
        self.assertEqual(xc.isrc_check(None, "Mixing", ["Ann Alpha"]).status, xc.SKIPPED)


def checks(**status):
    return [xc.Check(k, v, {"note": "n", "sender_domain": "d", "family": "mix", "for_others": [{"name": "Bob"}]})
            for k, v in status.items()]


class IntelTests(unittest.TestCase):
    """Captain 2026-10-27 21:5xZ: domain and person checks (shadow, nothing sent)."""

    def test_typosquat(self):
        off = ["bluefern.com"]
        self.assertEqual(intel.typosquat("bluefem.com", off), "bluefern.com")          # 1 edit
        self.assertEqual(intel.typosquat("bluefern-records.net", off), "bluefern.com")  # name embedded
        self.assertIsNone(intel.typosquat("bluefern.com", off))
        self.assertIsNone(intel.typosquat("mail.bluefern.com", off))                    # same site
        self.assertIsNone(intel.typosquat("redrock.com", off))
        self.assertIsNone(intel.typosquat("abc.com", ["abd.com"]))                      # too short to judge

    def test_domain_intel_flags_and_clears(self):
        now = datetime(2026, 10, 27, tzinfo=timezone.utc)
        net = FakeNet(rdap={"newlabel.com": "2026-09-01T00:00:00Z", "bluefern.com": "2012-01-01T00:00:00Z",
                            "bluefem.com": "2016-01-01T00:00:00Z"},
                      txt={"bluefern.com": ["v=spf1 include:x ~all"], "_dmarc.bluefern.com": ["v=DMARC1; p=quarantine"]})
        c = intel.domain_intel(net, "newlabel.com", [], "New Label", "label", [], now=now)
        self.assertEqual(c.status, xc.SOFT)
        self.assertIn("registered 56 days ago", c.detail["flags"][0])
        c = intel.domain_intel(net, "bluefem.com", [], "Blue Fern", "label", ["bluefern.com"], now=now)
        self.assertEqual(c.status, xc.SOFT)
        self.assertIn("look-alike", c.detail["flags"][0])
        c = intel.domain_intel(net, "gmail.com", [], "Blue Fern", "label", ["bluefern.com"], now=now)
        self.assertEqual(c.status, xc.SOFT)                                   # company issuer on free-mail
        self.assertEqual(intel.domain_intel(net, "gmail.com", [], "Ann Alpha", "artist", [], now=now).status,
                         xc.UNKNOWN)                                          # a person on gmail is normal
        c = intel.domain_intel(net, "bluefern.com", [], "Blue Fern", "label", ["bluefern.com"], now=now)
        self.assertEqual((c.status, c.detail["domains"][0]["spf"], c.detail["domains"][0]["dmarc"]),
                         (xc.POSITIVE, True, True))
        self.assertEqual(intel.domain_intel(net, None, [], None, None, []).status, xc.SKIPPED)
        c = intel.domain_intel(FakeNet(mx="nxdomain"), "ghost-label.io", [], "Ghost", "label", [], now=now)
        self.assertEqual(c.status, xc.SOFT)
        self.assertIn("does not exist", c.detail["flags"][0])

    def test_people_exist_somewhere_or_are_flagged(self):
        ex = validate({**GOOD_ANSWER, "credits": [
            {"person": "Ann Alpha", "role": "Mixing", "confidence": 0.9},      # on the track's Tidal credits
            {"person": "Bob Beta", "role": "Producer", "confidence": 0.9},     # in the Muso credits graph
            {"person": "Cy Gamma", "role": "Writer", "confidence": 0.9},       # MusicBrainz exact
            {"person": "Zed Nowhere", "role": "Writer", "confidence": 0.9},    # nowhere
            {"person": "Lo Conf", "role": "Writer", "confidence": 0.3}]})      # never evidence
        people = intel.people_of(ex)
        self.assertEqual([p["name"] for p in people], ["Dana Reyes", "Ann Alpha", "Bob Beta", "Cy Gamma", "Zed Nowhere"])
        net = FakeNet(mb={"artist": {"artists": [{"name": "Cy Gamma", "score": 100}]}},
                      pages={"https://bluefern.com/team": "Dana Reyes"})
        c = intel.people_check(net, people, graph=lambda names: {n for n in names if n == "bob beta"},
                               track_credits=[raw("Ann Alpha", "Mixer")], issuer_site_names=["Dana Reyes"])
        found = {r["name"]: r["found_in"] for r in c.detail["people"]}
        self.assertEqual(found["Dana Reyes"], ["issuer_site"])
        self.assertEqual(found["Ann Alpha"], ["track_spotify_tidal"])
        self.assertEqual(found["Bob Beta"], ["muso_credits_graph"])
        self.assertEqual(found["Cy Gamma"], ["musicbrainz"])
        self.assertEqual((c.status, c.detail["found_nowhere"]), (xc.WEAK, ["Zed Nowhere"]))

    def test_people_names_are_normalised_and_organisations_dropped(self):
        self.assertEqual(intel.person_name("Kumar, Kurran"), "Kurran Kumar")              # PRO style
        self.assertIsNone(intel.person_name("MEDIA SERVICES INTERNATIONAL"))
        self.assertIsNone(intel.person_name("Famous Production SRL"))
        self.assertIsNone(intel.person_name("Blue Fern Records"))
        self.assertEqual(intel.person_name("Ann  Alpha"), "Ann Alpha")
        self.assertIsNone(intel.person_name("Al"))                                         # too short to look up
        ex = validate({**GOOD_ANSWER, "signatory": {"name": "Reyes, Dana", "confidence": 0.9},
                       "credits": [{"person": "Dana Reyes", "role": "Writer", "confidence": 0.9},
                                   {"person": "Ethos Music SRL", "role": "Publisher", "confidence": 0.9}]})
        self.assertEqual([p["name"] for p in intel.people_of(ex)], ["Dana Reyes"])          # deduplicated

    def test_people_check_never_blocks_verification(self):
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=validate(GOOD_ANSWER), findings=[], extracted_support={"person": "Ann Alpha", "role": "mixing", "track": "Night Drive"},
                        checks=checks(xc_dsp=xc.POSITIVE, xc_people=xc.WEAK), account_held=False)
        self.assertEqual(o.outcome, gate.VERIFIED)
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=validate(GOOD_ANSWER), findings=[], extracted_support={"person": "Ann Alpha", "role": "mixing", "track": "Night Drive"},
                        checks=checks(xc_dsp=xc.POSITIVE, xc_domain_intel=xc.SOFT), account_held=False)
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)                       # domain doubt does block

    def test_a_bystander_address_never_makes_the_issuer_look_like_free_mail(self):
        # QA #1412: a label letter sent from bluefern.com that also shows the claimant's gmail.com.
        now = datetime(2026, 10, 27, tzinfo=timezone.utc)
        net = FakeNet(rdap={"bluefern.com": "2012-01-01T00:00:00Z"})
        c = intel.domain_intel(net, "bluefern.com", ["gmail.com", "bluefern.com"], "Blue Fern", "label",
                               ["bluefern.com"], now=now)
        self.assertEqual((c.status, c.detail["flags"]), (xc.POSITIVE, []))
        self.assertEqual({r["domain"]: r["role"] for r in c.detail["domains"]},
                         {"gmail.com": "other address", "bluefern.com": "sender"})
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=validate(GOOD_ANSWER), findings=[], extracted_support={"person": "Ann Alpha", "role": "mixing", "track": "Night Drive"},
                        checks=checks(xc_dsp=xc.POSITIVE, xc_domain_intel=c.status), account_held=False)
        self.assertEqual(o.outcome, gate.VERIFIED)                         # the bystander did not block it
        c = intel.domain_intel(net, "gmail.com", [], "Blue Fern", "label", ["bluefern.com"], now=now)
        self.assertEqual(c.status, xc.SOFT)                                  # the SENDER on free-mail still flags

    def test_a_low_confidence_sender_never_blocks_even_when_listed_on_the_page(self):
        # QA #1412 second pass: sender misread as bluefem.com at 0.5, the same address in ex.emails.
        now = datetime(2026, 10, 27, tzinfo=timezone.utc)
        c = intel.domain_intel(FakeNet(), None, ["bluefem.com"], "Blue Fern", "label", ["bluefern.com"], now=now,
                               uncertain=["bluefem.com"])
        self.assertEqual(c.detail["flags"], [])
        self.assertNotEqual(c.status, xc.SOFT)
        self.assertTrue(c.detail["domains"][0]["role"].startswith("uncertain sender"))
        self.assertEqual(c.detail["domains"][0]["imitates"], "bluefern.com")          # still recorded as evidence

    def test_runner_path_low_confidence_lookalike_sender_does_not_block_verified(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        data = b"%PDF-1.4 low-confidence sender"
        pid = hashlib.sha256(data).hexdigest()
        cache = os.path.join(td.name, "cache")
        os.makedirs(os.path.join(cache, "12345", "n"))
        Path(cache, "12345", "n", "0.pdf").write_bytes(data)
        proof_path = os.path.join(td.name, "proof.sqlite")
        ps = ProofStore(proof_path)
        ps.db.execute("INSERT INTO proofs (proof_id, first_seen, source, source_ref, contact_h, mime, bytes) VALUES "
                      "(?, '2026-10-27T00:00:00Z', 'intercom', '12345/n/0.pdf', 'c', 'application/pdf', 1)", (pid,))
        ps.db.execute("INSERT INTO verdicts (proof_id, analyzer_version, contact_h, track_key, verdict, reasons_json, "
                      "context_json, created_at, request_id) VALUES (?, ?, 'c', 'T1', 'GENUINE', '[]', '{}', "
                      "'2026-10-27T01:00:00Z', ?)", (pid, FORENSICS_VERSION, KEY))
        ps.db.commit()
        store = DocVerifyStore(os.path.join(td.name, "dv.sqlite"))
        answer = {**GOOD_ANSWER, "sender": {"email": "dana@bluefem.com", "confidence": 0.5},
                  "emails": ["dana@bluefem.com"]}
        net = FakeNet(mb={"label": {"labels": [{"id": "L1", "name": "Blue Fern Records", "score": 100}]},
                          "label/L1": {"relations": [{"type": "official homepage",
                                                      "url": {"resource": "https://bluefern.com"}}]}},
                      pages={"https://bluefern.com/about": "Dana Reyes, label manager"},
                      deezer={"https://api.deezer.com/track/isrc:USAB12400001": {"album": {"id": 9}},
                              "https://api.deezer.com/album/9": {"label": "Blue Fern Records"}})
        deps = runner.Deps(sandbox=lambda *a, **k: {"doc_text": "Blue Fern Records ... Ann Alpha mixed Night Drive",
                                                    "mime": "application/pdf", "kind": "contract", "facts": {}},
                           extractor=Extractor(store, key="k", post=lambda *a: or_response(answer)), net=net,
                           raw_credits=lambda tid: [raw("Ann Alpha", "Mixer")],
                           requests=lambda ids: {i: Req() for i in ids}, cache_root=cache)
        stats, rows = runner.run(store, deps, proof_store=proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(rows[0]["checks"]["xc_domain_intel"], xc.UNKNOWN)
        self.assertEqual(rows[0]["outcome"], gate.VERIFIED)

    def test_every_domain_is_checked_no_truncation(self):
        # QA #1412: a look-alike in seventh place was silently skipped.
        now = datetime(2026, 10, 27, tzinfo=timezone.utc)
        others = [f"innocent{i}.com" for i in range(6)] + ["bluefem.com"] + [f"more{i}.org" for i in range(10)]
        c = intel.domain_intel(FakeNet(), None, others, "Blue Fern", "label", ["bluefern.com"], now=now)
        self.assertEqual(c.status, xc.SOFT)
        self.assertTrue(any("bluefem.com: look-alike" in f for f in c.detail["flags"]))
        self.assertEqual(len(c.detail["domains"]), 17)

    def test_the_runner_passes_the_signatory_found_on_the_issuer_site(self):
        # QA #1412: the issuer-site source was never wired; it now comes from xc_signatory's fetch.
        c = intel.people_check(FakeNet(), [{"name": "Dana Reyes", "role": "signatory"}], graph=None,
                               track_credits=[], issuer_site_names=["Dana  Reyes"], musicbrainz=False)
        self.assertEqual((c.status, c.detail["people"][0]["found_in"]), (xc.POSITIVE, ["issuer_site"]))
        src = (Path(__file__).resolve().parents[1] / "credit_verify" / "docverify" / "runner.py").read_text()
        self.assertIn('issuer_site_names=[ex.signatory.get("name")] if sig.status == xc.POSITIVE else []', src)

    def test_the_sql_fold_matches_roles_fold(self):
        # QA #1412: lower(name) kept accents/punctuation, so the WHERE rejected 'José López' before Python saw it.
        import re
        import unicodedata
        from credit_review.roles import fold

        def sql_fold(name):          # SQL_FOLD step by step: NFKD, drop marks (\p{M}), lower, non-alnum -> ' ', trim
            t = "".join(ch for ch in unicodedata.normalize("NFKD", name) if not unicodedata.combining(ch))
            return re.sub(r"[^0-9a-z]+", " ", t.lower()).strip()
        self.assertIn("normalize(name, NFKD)", intel.SQL_FOLD)
        self.assertIn("\\p{M}", intel.SQL_FOLD)
        for n in ("José López", "O'Neil", "Beyoncé Knowles-Carter", "  Sinead O''Connor ", "Björk", "ﬁnn"):
            self.assertEqual(sql_fold(n), fold(n), n)

    def test_trino_name_index_reads_only_and_folds(self):
        seen = []

        def trino(sql):
            seen.append(sql)
            return '"bob beta"\n"ann  alpha"\n'
        idx = intel.trino_name_index(trino)
        self.assertEqual(idx(["bob beta", "ann alpha", "zed nowhere", "o'neil"]), {"bob beta", "ann alpha"})
        self.assertTrue(seen[0].startswith("SELECT DISTINCT name FROM postgresql_catalog.public.catalog_profile WHERE "
                                           + intel.SQL_FOLD + " IN ("))
        self.assertIn("'o''neil'", seen[0])                                  # quoted, never injected


class GateTests(unittest.TestCase):
    good_ex = validate(GOOD_ANSWER)

    def decide(self, h3="GENUINE", ex=None, findings=(), held=False, support=None, covers=True, **st):
        return gate.decide(h3_verdict=h3, kind="contract", ex=ex or self.good_ex, findings=list(findings),
                           checks=checks(**st), account_held=held, extracted_support=support, covers=covers)

    def test_the_labelled_dv2_verified_rows_never_verify_on_a_document_that_proves_nothing(self):
        # verifier-eval-v1 blind labels (2026-10-28 23:4xZ): every dv-2 `verified` row was on a document that proves
        # nothing (DSP/catalog panels, Muso UI, dashboards, chats) - passed on H3 PLAUSIBLE + the DSP cross-check.
        fx = json.loads((Path(__file__).resolve().parent / "fixtures" / "dv2-verified-labelled-1028.json").read_text())
        verified = {"real_not_proof": 0, "proves": 0}
        for r in fx["rows"]:
            ex = validate({**GOOD_ANSWER, "doc_type": r["doc_type"] or "other"})
            cks = [xc.Check(k, v, {"note": "n", "sender_domain": None, "family": "mix", "for_others": []})
                   for k, v in r["checks"].items()]
            fs = [forensics.Finding(n, sev) for n, sev in r["findings"]]
            o = gate.decide(h3_verdict=r["h3"], kind=r["kind"], ex=ex, findings=fs, checks=cks, account_held=False,
                            extracted_support={"person": "x"} if r["support"] else None)
            if o.outcome == gate.VERIFIED:
                verified[r["label"]] += 1
        self.assertGreaterEqual(len(fx["rows"]), 70)
        self.assertEqual(verified["real_not_proof"], 0)          # the regression: no false verified
        # Recall is knowingly lower (precision first): the labelled 'proves' rows are ASCAP registrations whose
        # role codes the extractor does not match yet, and an album booklet typed `credits_page`.
        self.assertEqual(verified["proves"], 0)

    def test_forged_positive_needs_two_independent_signal_families(self):
        # Captain 2026-10-28 21:3xZ FRAUD DENY (captain-1028-213x); Fable [key=fraud-deny-families].
        F = forensics.Finding
        on_name = {"check": "F4b", "value": {"field": "claimant_name"}, "page": 1, "region": [10, 10, 90, 20]}
        o = self.decide(h3="SUSPECT", findings=[F("h3_after_creation_key_field_edit", forensics.SOFT, on_name),
                                               F("template_reused", forensics.SOFT)], xc_dsp=xc.POSITIVE)
        self.assertEqual((o.outcome, o.account_hold), (gate.FORGED_POSITIVE, True))
        self.assertEqual([(e["family"], e.get("fields")) for e in o.detail["fraud_pair"]],
                         [("file_tamper", ["claimant_name"]), ("template", None)])
        self.assertIn("fields claimant_name", o.reason)
        # H3's hard signals behind h3_forged, with where they sit (two families, two regions)
        o = self.decide(h3="FORGED_LIKELY", findings=[
            F("h3_forged", forensics.HARD, ["F2 reused_on_another_track", "F3b copy_move_region"]),
            F("h3_reused_on_another_track", forensics.INFO, {"note": "hard H3 signal behind h3_forged"}),
            F("h3_copy_move_region", forensics.SOFT, {"page": 1, "region": [0, 0, 50, 50]})])
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)
        self.assertEqual(sorted(e["family"] for e in o.detail["fraud_pair"]), ["file_tamper", "reuse"])
        # a fabricated sender read >= 0.8 is a family of its own
        dom = xc.Check("xc_domain", xc.CONTRADICTS, {"sender_domain": "ghost-label.com", "confidence": 0.95,
                                                     "note": "the sender's domain does not exist"})
        o = gate.decide(h3_verdict="SUSPECT", kind="contract", ex=self.good_ex,
                        findings=[F("h3_copy_move_region", forensics.SOFT)], checks=[dom], account_held=False, covers=True)
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)

    def test_a_lookalike_cc_address_is_not_a_sender_signal(self):
        # QA #1470: domain-intel flags on another address on the document never make the `sender` family.
        F = forensics.Finding
        tamper = [F("h3_copy_move_region", forensics.SOFT, {"page": 1, "region": [0, 0, 9, 9]})]
        cc = xc.Check("xc_domain_intel", xc.SOFT, {"domains": [{"domain": "bluefern.com", "role": "sender"},
                                                              {"domain": "bluefem.com", "role": "other address"}],
                                                  "flags": ["bluefem.com: look-alike of the official bluefern.com "
                                                            "(an address on the document)"]})
        o = gate.decide(h3_verdict="SUSPECT", kind="contract", ex=self.good_ex, findings=tamper, checks=[cc],
                        account_held=False, covers=True)
        self.assertNotEqual(o.outcome, gate.FORGED_POSITIVE)
        snd = xc.Check("xc_domain_intel", xc.SOFT, {"domains": [{"domain": "bluefem.com", "role": "sender"}],
                                                   "flags": ["bluefem.com: look-alike of the official bluefern.com"]})
        o = gate.decide(h3_verdict="SUSPECT", kind="contract", ex=self.good_ex, findings=tamper, checks=[snd],
                        account_held=False, covers=True)
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)
        self.assertIn("bluefem.com: look-alike", next(e["id"] for e in o.detail["fraud_pair"] if e["family"] == "sender"))

    def test_short_of_positive_is_never_forged_positive(self):
        F = forensics.Finding
        loc = lambda field, region, page=1: {"value": {"field": field}, "page": page, "region": region}   # noqa: E731
        not_positive = [
            [F("h3_key_field_unique_font", forensics.SOFT, loc("claimant_name", [1, 1, 9, 9]))],    # one signal
            [F("template_reused", forensics.SOFT)],                                       # template alone (R-C5)
            [F("h3_copy_move_region", forensics.SOFT), F("h3_editor_software_on_screenshot", forensics.SOFT)],
            # co-writers send the same split sheet: soft reuse is not a fraud signal; neither is an embedded file
            [F("h3_reused_by_another_account", forensics.SOFT), F("h3_copy_move_region", forensics.SOFT)],
            [F("h3_reject_pdf_embedded_file", forensics.SOFT), F("h3_copy_move_region", forensics.SOFT)],
            [F("email_screenshot", forensics.WEAK), F("h3_undetermined", forensics.WEAK)],
            # Fable tightening (1): a font change on an amount / share / unknown field is not the second family
            [F("h3_key_field_unique_font", forensics.SOFT, loc("amount", [1, 1, 9, 9])), F("template_reused", forensics.SOFT)],
            [F("h3_key_field_unique_font", forensics.SOFT, loc("share_percent", [1, 1, 9, 9])),
             F("template_reused", forensics.SOFT)],
            [F("h3_key_field_unique_font", forensics.SOFT), F("template_reused", forensics.SOFT)],
            [F("template_reused", forensics.INFO), F("h3_reused_on_another_track", forensics.SOFT)],   # INFO template
        ]
        for fs in not_positive:
            o = self.decide(h3="SUSPECT", findings=fs, xc_dsp=xc.POSITIVE)
            self.assertNotEqual(o.outcome, gate.FORGED_POSITIVE, [(f.name, f.detail) for f in fs])
        # Fable tightening (2): two readings of the same edit (same page, overlapping regions) are one signal
        same_edit = [F("h3_key_field_unique_font", forensics.SOFT, loc("claimant_name", [10, 10, 90, 20])),
                     F("h3_after_creation_key_field_edit", forensics.SOFT, loc("claimant_name", [40, 12, 80, 18]))]
        self.assertNotEqual(self.decide(h3="SUSPECT", findings=same_edit).outcome, gate.FORGED_POSITIVE)
        # Fable addendum: the share is the claim on a split sheet; the amount on a royalty/distributor statement
        share = [F("h3_after_creation_key_field_edit", forensics.SOFT, loc("share_percent", [1, 1, 9, 9])),
                 F("template_reused", forensics.SOFT)]
        split = validate({**GOOD_ANSWER, "doc_type": "split_sheet"})
        o = gate.decide(h3_verdict="SUSPECT", kind="split_sheet", ex=split, findings=share, checks=[], account_held=False, covers=True)
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)
        self.assertIn("share_percent", o.detail["claim_fields"])
        amount = [F("h3_after_creation_key_field_edit", forensics.SOFT, loc("amount", [1, 1, 9, 9])),
                  F("template_reused", forensics.SOFT)]
        stmt = validate({**GOOD_ANSWER, "doc_type": "dashboard_screenshot"})
        self.assertEqual(gate.decide(h3_verdict="SUSPECT", kind="distributor_portal", ex=stmt,
                                     findings=amount, checks=[], account_held=False, covers=True).outcome, gate.FORGED_POSITIVE)
        self.assertNotEqual(gate.decide(h3_verdict="SUSPECT", kind="distributor_portal", ex=self.good_ex,
                                        findings=amount, checks=[], account_held=False, covers=True).outcome,
                            gate.FORGED_POSITIVE)                      # read as a letter: not a statement
        for kind, doc_type in (("contract", "contract"), ("split_sheet", "email"), (None, "email_screenshot")):
            ex = validate({**GOOD_ANSWER, "doc_type": doc_type})              # a licence/contract/email: no
            self.assertNotEqual(gate.decide(h3_verdict="SUSPECT", kind=kind, ex=ex, findings=amount, checks=[],
                                            account_held=False, covers=True).outcome, gate.FORGED_POSITIVE, (kind, doc_type))
        self.assertNotEqual(gate.decide(h3_verdict="SUSPECT", kind="contract", ex=self.good_ex, findings=share,
                                        checks=[], account_held=False, covers=True).outcome, gate.FORGED_POSITIVE)
        elsewhere = [F("h3_ela_outlier_on_key_field", forensics.SOFT, loc("isrc", [10, 10, 90, 20])),
                     F("h3_ai_generator_software", forensics.SOFT)]                # different families
        self.assertEqual(self.decide(h3="SUSPECT", findings=elsewhere).outcome, gate.FORGED_POSITIVE)
        low = xc.Check("xc_domain", xc.CONTRADICTS, {"sender_domain": "ghost-label.com", "confidence": 0.7})
        o = gate.decide(h3_verdict="SUSPECT", kind="contract", ex=self.good_ex,
                        findings=[F("h3_copy_move_region", forensics.SOFT)], checks=[low], account_held=False, covers=True)
        self.assertNotEqual(o.outcome, gate.FORGED_POSITIVE)                  # a sender read below 0.8 is no signal
        o = self.decide(h3="FORGED_LIKELY", findings=[F("h3_forged", forensics.HARD, ["F4b key_field_unique_font"])])
        self.assertEqual(o.outcome, gate.FORGED)                               # one hard signal: a hold, never a deny

    def test_a_tooling_failure_is_never_forged_positive(self):
        # QA #1470: the deny rule is positive-only - a pair read while our tooling failed is unknown (or a hold).
        F = forensics.Finding
        on_name = {"value": {"field": "claimant_name"}, "page": 1, "region": [10, 10, 90, 20]}
        pair = [F("h3_after_creation_key_field_edit", forensics.SOFT, on_name), F("template_reused", forensics.SOFT)]
        for kw in ({"ex": fallback("x", "transport: URLError")}, {"h3": None}, {"h3": "UNDETERMINED"},
                   {"xc_dsp": xc.ERROR}):
            st = {k: v for k, v in kw.items() if k.startswith("xc_")}
            o = self.decide(h3=kw.get("h3", "SUSPECT"), ex=kw.get("ex"), findings=pair, **st)
            self.assertEqual(o.outcome, gate.UNKNOWN, kw)
            self.assertFalse(o.account_hold)
            self.assertIn("tooling", o.detail["would_forge_positive"]["why_not"])
        # one hard H3 signal + a tooling failure elsewhere: a hold (forged), still never positive
        o = self.decide(h3="FORGED_LIKELY", findings=[F("h3_forged", forensics.HARD, ["F4b key_field_unique_font",
                                                                                     "F2b template_family"])],
                        xc_dsp=xc.ERROR)
        self.assertEqual(o.outcome, gate.FORGED)

    def test_a_positive_document_denies_only_the_requests_it_names(self):
        # Fable 110 (e9ec352a): a producer agreement for one track would have denied 4 other tracks.
        F = forensics.Finding
        on_name = {"value": {"field": "claimant_name"}, "page": 1, "region": [10, 10, 90, 20]}
        pair = [F("h3_after_creation_key_field_edit", forensics.SOFT, on_name), F("template_reused", forensics.SOFT)]
        o = self.decide(h3="SUSPECT", findings=pair, covers=False)
        self.assertEqual((o.outcome, o.account_hold), (gate.FORGED, True))          # a hold, never a deny
        self.assertTrue(o.detail["positive_document"])
        self.assertIn("does not name this request's track", o.reason)
        o = self.decide(h3="SUSPECT", findings=pair, covers=True)
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)
        self.assertTrue(o.detail["covers"])
        # behaviour, end to end: IntakeD2Tests.test_a_positive_document_in_a_small_filing_denies_only_its_track

    def test_a_font_change_never_pairs_with_a_template(self):
        # e47c9af3: the producer's name typed (Calibri) into a standard form's '*Name of Producer ... (Payee) -' blank.
        F = forensics.Finding
        on_name = {"value": {"field": "claimant_name"}, "page": 11, "region": [36.8, 334.8, 175.7, 347.1]}
        o = self.decide(h3="SUSPECT", findings=[F("h3_key_field_unique_font", forensics.SOFT, on_name),
                                                F("template_reused", forensics.SOFT)])
        self.assertNotEqual(o.outcome, gate.FORGED_POSITIVE)
        edit = {"value": {"fields": ["claimant_name"]}, "page": 11, "region": [36.8, 334.8, 175.7, 347.1]}
        o = self.decide(h3="SUSPECT", findings=[F("h3_after_creation_key_field_edit", forensics.SOFT, edit),
                                                F("template_reused", forensics.SOFT)])
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)              # a real edit of the name still pairs
        o = self.decide(h3="SUSPECT", findings=[F("h3_key_field_unique_font", forensics.SOFT, on_name),
                                                F("h3_reused_on_another_track", forensics.SOFT)])
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)              # a font change + reuse still pairs
        T = {"id": "template_reused", "family": "template"}
        for name, pairs in (("after_creation_key_field_edit", True), ("signature_not_intact", True),
                            ("copy_move_region", True), ("ela_outlier_on_key_field", True),
                            ("key_field_unique_font", False), ("online_editor_producer", False),
                            ("editor_software_on_screenshot", False), ("xmp_edit_history_on_screenshot", False),
                            ("reject_polyglot", False)):
            sig = {"id": f"h3_{name}@p1:[1, 1, 9, 9]", "family": "file_tamper", "fields": ["claimant_name"],
                   "page": 1, "region": [1, 1, 9, 9]}
            self.assertEqual(gate.positive_pair([sig, T]) is not None, pairs, name)
        for fam, sid in (("reuse", "h3_reused_by_another_account_same_claim"), ("ai_generated", "h3_c2pa_ai_source"),
                         ("sender", "xc_domain: lookalike (bluefern-records.co)"),
                         ("impossible_content", "h3_document_date_future")):
            self.assertIsNotNone(gate.positive_pair([{"id": sid, "family": fam}, T]), fam)

    def test_the_two_live_positives_ruled_not_are_not_positive(self):
        # Fable 1029: e9ec352a and e47c9af3, the only dv-3 forged_positive documents, were both ruled NOT forged.
        fx = json.loads((Path(__file__).parent / "fixtures" / "forged-positive-ruled-not-1029.json").read_text())
        self.assertEqual(sorted(r["proof_id"][:8] for r in fx), ["e47c9af3", "e9ec352a"])
        for r in fx:
            self.assertIsNotNone(r["fraud_pair"])                       # what dv-3 stored before the rule
            self.assertIsNone(gate.positive_pair(r["fraud_signals"], r["claim_fields"]), r["proof_id"][:8])

    def test_an_email_or_link_is_never_a_claim_field(self):
        from credit_verify.proof.pdf_forensics import key_field_class
        for t in ("leftofficial03@gmail.com", "mail: jane.doe@label.co.uk", "https://distrokid.com/jane", "www.janedoe.com"):
            self.assertEqual(key_field_class(t, ["Jane Doe", "Left", "jane"]), "contact", t)
        self.assertEqual(key_field_class("Jane Doe", ["Jane Doe"]), "claimant_name")
        # QA #1482: a contact token never masks a separate claim field in the same span
        self.assertEqual(key_field_class("Jane Doe jane@example.com", ["Jane Doe"]), "claimant_name")
        self.assertEqual(key_field_class("jane@example.com USAB12400001", ["Jane Doe"]), "isrc")
        self.assertEqual(key_field_class("https://janedoe.com 50%", ["Jane Doe"]), "share_percent")
        self.assertEqual(key_field_class("contact: janedoe@gmail.com", ["Jane Doe", "janedoe"]), "contact")
        F = forensics.Finding
        on_mail = {"value": {"field": "contact"}, "page": 15, "region": [216, 556, 333, 568]}
        o = self.decide(h3="SUSPECT", findings=[F("h3_key_field_unique_font", forensics.SOFT, on_mail),
                                                F("template_reused", forensics.SOFT)])
        self.assertNotEqual(o.outcome, gate.FORGED_POSITIVE)                    # e9ec352a's pair, now

    def test_h3_signals_keep_where_they_sit(self):
        from credit_verify.proof.pdf_forensics import key_field_class
        from credit_verify.proof.signals import Evidence, Signal
        self.assertEqual([key_field_class(t, ["Jane Doe"]) for t in ("Jane Doe", "USAB12400001", "50 %", "1,000", "x")],
                         ["claimant_name", "isrc", "share_percent", "amount", None])
        s = Signal("F4b", "key_field_unique_font", "soft", value={"font": "Arial", "field": "isrc"},
                   evidence=Evidence(file="/private/path.pdf", tool="pymupdf", page=2, region=[1, 2, 3, 4],
                                     excerpt="personal"))
        d = forensics.signal_dict(s)
        self.assertEqual(d, {"name": "key_field_unique_font", "severity": "soft", "check": "F4b",
                             "value": {"font": "Arial", "field": "isrc"}, "page": 2, "region": [1.0, 2.0, 3.0, 4.0]})
        fs = forensics.check(forensics.H3("SUSPECT", [], [d], "contract"), self.good_ex, {}, "application/pdf")
        f = next(x for x in fs if x.name == "h3_key_field_unique_font")
        self.assertEqual((f.detail["page"], f.detail["value"]["field"]), (2, "isrc"))

    def test_verified_needs_everything(self):
        o = self.decide(xc_dsp=xc.POSITIVE, xc_domain=xc.POSITIVE, xc_label=xc.POSITIVE, support={"person": "Ann Alpha", "role": "mixing", "track": "Night Drive"})
        self.assertEqual(o.outcome, gate.VERIFIED)
        # verifier-eval-v1 23:4xZ: the DSP crediting them is no substitute for the DOCUMENT naming them
        o = self.decide(xc_dsp=xc.POSITIVE, xc_domain=xc.POSITIVE, xc_label=xc.POSITIVE)
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)
        self.assertIn("the document itself does not name the claimant", o.reason)
        self.assertFalse(o.account_hold)

    def test_unknown_never_approves(self):
        for kw in ({"xc_dsp": xc.UNKNOWN, "xc_isrc": xc.UNKNOWN},             # nothing confirms the credit
                   {"xc_dsp": xc.POSITIVE, "xc_label": xc.SOFT},                # issuer is not the label
                   {"xc_dsp": xc.POSITIVE, "xc_domain": xc.SOFT}):
            self.assertEqual(self.decide(**kw).outcome, gate.UNVERIFIABLE, kw)
        self.assertEqual(self.decide(h3="SUSPECT", xc_dsp=xc.POSITIVE).outcome, gate.UNVERIFIABLE)
        # D3: our tooling failing is `unknown`: no ask (need None), no approval, no hold
        for o in (self.decide(xc_dsp=xc.ERROR), self.decide(h3=None, xc_dsp=xc.POSITIVE),
                  self.decide(h3="UNDETERMINED", xc_dsp=xc.POSITIVE),
                  self.decide(ex=fallback("x", "transport: URLError"), xc_dsp=xc.POSITIVE),
                  self.decide(ex=fallback("x", "daily model spend cap reached"), xc_dsp=xc.POSITIVE),
                  self.decide(ex=fallback("x", "unusable model answer"), xc_dsp=xc.POSITIVE),
                  self.decide(ex=fallback("", "sandbox failed: timeout"), xc_dsp=xc.POSITIVE),
                  self.decide(ex=fallback("", "document not located"), xc_dsp=xc.POSITIVE)):
            self.assertEqual((o.outcome, o.need, o.account_hold), (gate.UNKNOWN, None, False), o.reason)
        # a genuinely unreadable document is the user's to fix: unverifiable with an ask
        o = self.decide(ex=fallback("", "no readable text"), xc_dsp=xc.POSITIVE)
        self.assertEqual((o.outcome, o.need), (gate.UNVERIFIABLE, gate.NEED_READABLE))
        # tooling never masks real evidence: a forgery found is still forged
        o = self.decide(h3=None, findings=[forensics.Finding("h3_forged", forensics.HARD)], xc_dsp=xc.ERROR)
        self.assertEqual(o.outcome, gate.FORGED)
        soft = [forensics.Finding("file_predates_document", forensics.SOFT)]
        self.assertEqual(self.decide(findings=soft, xc_dsp=xc.POSITIVE).outcome, gate.UNVERIFIABLE)

    def test_suspect_for_coverage_needs_extracted_support(self):
        sup = {"person": "Ann Alpha", "role": "Mixing"}
        self.assertEqual(self.decide(h3="SUSPECT", xc_dsp=xc.POSITIVE).outcome, gate.UNVERIFIABLE)
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=self.good_ex, findings=[],
                        checks=checks(xc_dsp=xc.POSITIVE), account_held=False, extracted_support=sup)
        self.assertEqual(o.outcome, gate.VERIFIED)
        doubt = [forensics.Finding("h3_online_editor_producer", forensics.SOFT)]
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=self.good_ex, findings=doubt,
                        checks=checks(xc_dsp=xc.POSITIVE), account_held=False, extracted_support=sup)
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)                # forensic doubt is never overridden
        o = gate.decide(h3_verdict="SUSPECT", kind=None, ex=self.good_ex, findings=[],
                        checks=checks(xc_dsp=xc.UNKNOWN), account_held=False, extracted_support=sup)
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)                # the document alone is never enough

    def test_weak_alone_never_verifies_but_stands_next_to_confirmation(self):
        weak = [forensics.Finding("email_screenshot", forensics.WEAK)]
        o = self.decide(findings=weak, xc_dsp=xc.UNKNOWN, xc_domain=xc.WEAK)
        self.assertEqual(o.outcome, gate.UNVERIFIABLE)
        self.assertEqual(self.decide(findings=weak, xc_isrc=xc.POSITIVE, support={"person": "Ann Alpha", "role": "mixing", "track": "Night Drive"}).outcome, gate.VERIFIED)

    def test_forged_and_contradicted_hold_the_account(self):
        o = self.decide(findings=[forensics.Finding("h3_forged", forensics.HARD)], xc_dsp=xc.POSITIVE)
        self.assertEqual((o.outcome, o.account_hold), (gate.FORGED, True))
        # R-C6 (proof-loop lead 073): a fabricated sender forges only with confidence >= 0.8 + a second signal.
        def dom(conf):
            return xc.Check("xc_domain", xc.CONTRADICTS, {"sender_domain": "ghost-label.com", "confidence": conf,
                                                          "note": "the sender's domain does not exist"})
        base = [c for c in checks(xc_dsp=xc.POSITIVE) if c.step != "xc_domain"]
        o = gate.decide(h3_verdict="INCONSISTENT", kind="contract", ex=self.good_ex, findings=[],
                        checks=base + [dom(0.95)], account_held=False, covers=True)
        self.assertEqual((o.outcome, o.account_hold), (gate.FORGED, True))
        self.assertIn("fabricated sender", o.reason)
        self.assertIn("second signal: H3 INCONSISTENT", o.reason)
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=self.good_ex, findings=[],
                        checks=base + [dom(0.95)], account_held=False, covers=True)              # one signal only
        self.assertEqual((o.outcome, o.account_hold), (gate.UNVERIFIABLE, False))   # not forged, not verified
        self.assertEqual(o.detail["would_forge"]["why_not"], "no second signal (R-C6)")
        self.assertIn("sender doubt", o.reason)
        o = gate.decide(h3_verdict="INCONSISTENT", kind="contract", ex=self.good_ex, findings=[],
                        checks=base + [dom(0.7)], account_held=False, covers=True)               # below 0.8
        self.assertEqual((o.outcome, o.account_hold), (gate.UNVERIFIABLE, False))
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=self.good_ex,
                        findings=[forensics.Finding("editor_software_on_screenshot", forensics.SOFT)],
                        checks=base + [dom(0.9)], account_held=False, covers=True)               # forensic doubt = second signal
        self.assertEqual(o.outcome, gate.FORGED_POSITIVE)       # and two independent families: positive
        o = self.decide(xc_dsp=xc.CONTRADICTS)
        self.assertEqual((o.outcome, o.account_hold), (gate.CONTRADICTED, True))

    def test_an_unreadable_sender_address_asks_for_a_readable_copy(self):
        unreadable = xc.Check("xc_domain", xc.WEAK, {"sender_domain": "michaelosbome.ora", "unreadable": True,
                                                     "note": "sender address unreadable"})
        base = [c for c in checks() if c.step != "xc_domain"]
        o = gate.decide(h3_verdict="SUSPECT", kind="letter", ex=validate({**GOOD_ANSWER, "doc_type": "letter"}),
                        findings=[], checks=base + [unreadable], account_held=False)
        self.assertEqual((o.outcome, o.need, o.account_hold), (gate.UNVERIFIABLE, gate.NEED_READABLE, False))
        # QA #1452: an OTHERWISE verifiable document (H3 GENUINE, DSP positive) is not verified on a misread sender.
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=self.good_ex, findings=[],
                        checks=[c for c in checks(xc_dsp=xc.POSITIVE) if c.step != "xc_domain"] + [unreadable],
                        account_held=False)
        self.assertEqual((o.outcome, o.need), (gate.UNVERIFIABLE, gate.NEED_READABLE))
        self.assertIn("sender address unreadable", o.reason)

    def test_account_hold_blocks_verification(self):
        o = self.decide(held=True, xc_dsp=xc.POSITIVE)
        self.assertEqual((o.outcome, o.need), (gate.UNVERIFIABLE, gate.NEED_ACCOUNT))

    def test_need_codes(self):
        self.assertEqual(gate.need_for(validate({"doc_type": "email_screenshot"}), None), gate.NEED_ISSUER_DOMAIN)
        self.assertEqual(gate.need_for(validate({"doc_type": "dashboard_screenshot"}), None), gate.NEED_DASHBOARD)
        self.assertEqual(gate.need_for(validate({"doc_type": "split_sheet"}), None), gate.NEED_COUNTERPARTY)
        self.assertEqual(gate.need_for(fallback("", "no readable text"), None), gate.NEED_READABLE)


class Req:
    def __init__(self, uid=42, track="T1", isrc="USAB12400001", names=("Ann Alpha",), title="Night Drive"):
        self.user_id, self.track_id, self.isrc, self.names, self.title = uid, track, isrc, list(names), title


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        d = self.td.name
        self.cache = os.path.join(d, "cache")
        data = b"%PDF-1.4 fake bytes for the test"
        self.proof_id = hashlib.sha256(data).hexdigest()
        os.makedirs(os.path.join(self.cache, "12345", "notif_x"))
        Path(self.cache, "12345", "notif_x", "0.pdf").write_bytes(data)
        self.proof_path = os.path.join(d, "proof.sqlite")
        ps = ProofStore(self.proof_path)
        ps.db.execute("INSERT INTO proofs (proof_id, first_seen, source, source_ref, contact_h, mime, bytes) "
                      "VALUES (?, '2026-10-27T00:00:00Z', 'intercom', '12345/notif_x/0.pdf', 'c', 'application/pdf', 1)",
                      (self.proof_id,))
        ps.db.execute("INSERT INTO verdicts (proof_id, analyzer_version, contact_h, track_key, verdict, reasons_json, "
                      "context_json, created_at, request_id) VALUES (?, ?, 'c', 'T1', 'GENUINE', '[]', '{}', "
                      "'2026-10-27T01:00:00Z', ?)", (self.proof_id, FORENSICS_VERSION, KEY))
        ps.db.commit()
        self.store = DocVerifyStore(os.path.join(d, "dv.sqlite"))
        self.sandbox_calls = []

        def sandbox(path, declared, ctx, want_text=False):
            self.sandbox_calls.append((path, want_text))
            return {"doc_text": "Blue Fern Records ... Ann Alpha mixed Night Drive", "mime": "application/pdf",
                    "kind": "contract", "facts": {"created": "D:20250302"}}
        self.net = FakeNet(mb={"label": {"labels": [{"id": "L1", "name": "Blue Fern Records", "score": 100}]},
                               "label/L1": {"relations": [{"type": "official homepage",
                                                           "url": {"resource": "https://bluefern.com"}}]}},
                           pages={"https://bluefern.com/about": "Dana Reyes, label manager"},
                           deezer={"https://api.deezer.com/track/isrc:USAB12400001": {"album": {"id": 9}},
                                   "https://api.deezer.com/album/9": {"label": "Blue Fern Records"}})
        self.answer = GOOD_ANSWER
        self.deps = runner.Deps(
            sandbox=sandbox, extractor=Extractor(self.store, key="k", post=lambda *a: or_response(self.answer)),
            net=self.net, raw_credits=lambda tid: [raw("Ann Alpha", "Mixer")],
            requests=lambda ids: {i: Req() for i in ids}, cache_root=self.cache)

    def tearDown(self):
        self.td.cleanup()

    def test_end_to_end_verified_and_every_step_logged(self):
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(stats.outcomes, {"verified": 1})
        self.assertEqual(self.sandbox_calls[0][1], True)
        steps = [r[0] for r in self.store.db.execute("SELECT step FROM dv_steps ORDER BY id")]
        for s in ("locate", "text", "extract", "xc_domain", "xc_signatory", "xc_domain_intel", "forensics", "xc_dsp",
                  "xc_isrc", "xc_label", "gate", "xc_people"):
            self.assertIn(s, steps)
        o = self.store.db.execute("SELECT request_id, role, user_id, outcome, version FROM dv_outcomes").fetchone()
        self.assertEqual(o, (RID, "Mixing", 42, "verified", VERSION))
        self.assertEqual(rows[0]["checks"]["xc_signatory"], xc.POSITIVE)
        # done: the next run does nothing
        stats, _ = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(stats.documents, 0)

    def test_the_same_bytes_give_the_same_outcome_on_every_run(self):
        # Fable 127 (6d004ade): the outcome flapped forged_positive/unverifiable across 4 runs because each run
        # re-asked the model, and its self-reported date confidence moved 0.5 / 0.6 / 0.55 around a threshold.
        # With the extraction cache the same bytes + facts get the SAME answer, so the SAME outcome, every run.
        calls = []
        confidences = iter([0.95, 0.4, 0.95, 0.4, 0.95, 0.4])

        def post(*a):
            calls.append(1)
            c = next(confidences)
            return or_response({**GOOD_ANSWER, "credits": [{**GOOD_ANSWER["credits"][0], "confidence": c}],
                                "dates": [{"what": "signed", "date": "2027-11-18", "confidence": c}]})
        self.deps.extractor = Extractor(self.store, key="k", post=post)
        outcomes = []
        for _ in range(3):
            self.store.db.execute("DELETE FROM dv_outcomes")
            self.store.db.execute("DELETE FROM dv_steps WHERE step != 'extract'")
            self.store.db.commit()
            _, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
            outcomes.append([(r["request_id"], r["role"], r["outcome"]) for r in rows])
        self.assertEqual(len(calls), 1)                                          # one model call, two cache hits
        self.assertEqual(outcomes[0], outcomes[1])
        self.assertEqual(outcomes[1], outcomes[2])
        self.assertTrue(outcomes[0])

    def test_musicbrainz_lookups_are_cached_across_documents_and_runs(self):
        # Fable 149: MusicBrainz 1/s host-wide bounds reading; the issuer-domain, ISRC and artist lookups repeat.
        runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        mb_first = [c for c in self.net.calls if c.startswith("mb:")]
        self.assertTrue(any(c == "mb:label" for c in mb_first))                       # the issuer lookup ran once
        self.store.db.execute("DELETE FROM dv_outcomes")
        self.store.db.execute("DELETE FROM dv_steps")
        self.store.db.commit()
        self.net.calls.clear()
        runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual([c for c in self.net.calls if c.startswith("mb:")], [])        # second read: all cached
        self.assertEqual([c for c in self.net.calls if "deezer" in c], [])
        kinds = {k for (k,) in self.store.db.execute("SELECT DISTINCT kind FROM dv_lookup_cache")}
        self.assertTrue({"issuer_domains", "isrc_release"} <= kinds, kinds)

    def test_a_lookup_with_an_error_is_never_cached_and_expired_rows_are_purged(self):
        calls = []

        def fetch():
            calls.append(1)
            return ["x.com"], "musicbrainz error TimeoutError"
        for _ in range(2):
            self.store.cached_lookup("issuer_domains", "blue fern", lambda: list(fetch()),
                                     ok=lambda v: not str(v[1]).startswith("musicbrainz error"))
        self.assertEqual(len(calls), 2)                                                  # asked again: not cached
        rel = xc.Release("USAB12400001", errors=["musicbrainz http 503"])
        n = []
        for _ in range(2):
            self.store.cached_lookup("isrc_release", "USAB12400001", lambda: (n.append(1), rel.__dict__)[1],
                                     ok=lambda v: not v.get("errors"))
        self.assertEqual(len(n), 2)
        self.store.cached_lookup("mb_artist", "ann alpha", lambda: {"artists": []}, now=1000.0)
        self.store.cached_lookup("mb_artist", "bob beta", lambda: {"artists": []}, now=1000.0 + 24 * 3600 + 1)
        self.assertEqual([k for (k,) in self.store.db.execute("SELECT key FROM dv_lookup_cache")], ["bob beta"])
        with self.assertRaises(RuntimeError):                                            # a raise propagates
            self.store.cached_lookup("mb_artist", "carl", lambda: (_ for _ in ()).throw(RuntimeError("down")))
        self.assertIsNone(self.store.db.execute("SELECT 1 FROM dv_lookup_cache WHERE key='carl'").fetchone())

    def test_the_people_check_uses_the_cached_artist_search(self):
        from credit_verify.docverify import intel
        asked = []
        out = intel.people_check(self.net, [{"name": "Zed Nobody", "as": "signatory"}], graph=None, track_credits=[],
                                 artist_search=lambda name: (asked.append(name), {"artists": []})[1])
        self.assertEqual(asked, ["Zed Nobody"])
        self.assertFalse(any(c == "mb:artist" for c in self.net.calls))
        self.assertEqual(out.status, xc.WEAK)
        src = (Path(__file__).resolve().parents[1] / "credit_verify" / "docverify" / "runner.py").read_text()
        self.assertIn("artist_search=lambda name: cached_artist(store, deps.net, name)", src)

    def test_non_latin_names_never_share_a_cache_entry(self):
        # QA #1499: xc.fold drops non-ASCII letters, so 张伟 and 李娜 both folded to '' and shared one entry.
        self.assertEqual(xc.fold("张伟"), xc.fold("李娜"))                              # the old collision
        self.assertNotEqual(runner.lookup_key("张伟"), runner.lookup_key("李娜"))
        self.assertEqual(runner.lookup_key("  Blue  FERN Records "), runner.lookup_key("blue fern records"))
        self.assertEqual(runner.lookup_key("\uff22\uff4c\uff55\uff45"), runner.lookup_key("blue"))     # NFKC fullwidth
        asked = []
        net = self.net
        net.mb = lambda path, params: (asked.append(params["query"]), {"artists": [{"name": params["query"]}]})[1]
        a = runner.cached_artist(self.store, net, "张伟")
        b = runner.cached_artist(self.store, net, "李娜")
        self.assertEqual(len(asked), 2)                                                  # two lookups, two answers
        self.assertNotEqual(a, b)
        runner.cached_artist(self.store, net, "张伟")
        self.assertEqual(len(asked), 2)                                                  # the same name: cached
        runner.cached_artist(self.store, net, "   ")
        runner.cached_artist(self.store, net, "   ")
        self.assertEqual(len(asked), 4)                                                  # an empty key: never cached
        doms = []

        def official(n, issuer):
            doms.append(issuer)
            return [issuer + ".com"], "musicbrainz label x"
        with unittest.mock.patch.object(runner.xc, "official_domains", official):
            self.assertEqual(runner.cached_official(self.store, net, "张伟唱片")[0], ["张伟唱片.com"])
            self.assertEqual(runner.cached_official(self.store, net, "李娜唱片")[0], ["李娜唱片.com"])
        self.assertEqual(doms, ["张伟唱片", "李娜唱片"])

    def test_since_cutoff_is_recorded_once_and_respected(self):
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE verdicts SET created_at='2020-01-01T00:00:00Z'")
        db.commit()
        db.close()
        stats, _ = runner.run(self.store, self.deps, proof_store=self.proof_path)   # first run: cutoff = now
        self.assertEqual(stats.documents, 0)                                          # the verdict is older
        self.assertIsNotNone(self.store.get_state("since"))

    def test_forged_sender_holds_the_account(self):
        self.answer = {**GOOD_ANSWER, "sender": {"email": "dana@bluefern-records.co", "confidence": 0.9}}
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(rows[0]["outcome"], gate.FORGED)
        self.assertEqual(self.store.held_users(), {42})

    def test_low_confidence_sender_end_to_end_is_not_forged(self):
        self.answer = {**GOOD_ANSWER, "sender": {"email": "contact@mistyped.invalid", "confidence": 0.0}}
        self.net._mx = {"mistyped.invalid": "nxdomain"}
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertNotEqual(rows[0]["outcome"], gate.FORGED)
        self.assertFalse(rows[0]["account_hold"])
        self.assertEqual(rows[0]["checks"]["xc_domain"], xc.WEAK)
        self.assertEqual(self.store.held_users(), set())

    def test_nan_confidence_sender_end_to_end_is_not_forged(self):
        # QA #1380 06:36Z full path: model JSON -> validate -> domain_check -> gate.
        body = ('{"doc_type": "letter", "issuer": {"name": "Blue Fern Records", "type": "label", '
                '"confidence": NaN}, "sender": {"email": "contact@mistyped.invalid", "confidence": NaN}, '
                '"tracks": [{"title": "Night Drive", "isrc": "USAB12400001", "confidence": NaN}], '
                '"credits": [{"person": "Ann Alpha", "role": "Mixing", "track": "Night Drive", '
                '"confidence": NaN}]}')
        resp = {"usage": {}, "choices": [{"message": {"content": body}}]}
        self.deps.extractor = Extractor(self.store, key="k", post=lambda *a: resp)
        self.net._mx = {"mistyped.invalid": "nxdomain"}
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertNotEqual(rows[0]["outcome"], gate.FORGED)
        self.assertFalse(rows[0]["account_hold"])
        self.assertEqual(rows[0]["checks"]["xc_domain"], xc.WEAK)
        self.assertEqual(self.store.held_users(), set())
        self.assertNotIn("mx:mistyped.invalid", self.net.calls)

    def test_low_confidence_issuer_is_not_used_for_look_alikes(self):
        self.answer = {**GOOD_ANSWER, "issuer": {"name": "Blue Fern Records", "type": "label", "confidence": 0.3},
                       "sender": {"email": "dana@bluefern-records.co", "confidence": 0.9}}
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertNotEqual(rows[0]["outcome"], gate.FORGED)

    def _second_document(self, verdict_first: bool):
        """A second document of the SAME account (user 42) whose sender is a
        look-alike of the issuer: forged. `verdict_first` puts its H3 verdict
        before the good document's, so it is verified first."""
        data = b"%PDF-1.4 the forged one"
        pid = hashlib.sha256(data).hexdigest()
        os.makedirs(os.path.join(self.cache, "777", "notif_y"))
        Path(self.cache, "777", "notif_y", "0.pdf").write_bytes(data)
        db = sqlite3.connect(self.proof_path)
        db.execute("INSERT INTO proofs (proof_id, first_seen, source, source_ref, contact_h, mime, bytes) VALUES "
                   "(?, '2026-10-27T00:00:00Z', 'intercom', '777/notif_y/0.pdf', 'c', 'application/pdf', 1)", (pid,))
        rid2 = "99999999-2222-3333-4444-555555555555"
        if verdict_first:
            db.execute("UPDATE verdicts SET id = id + 100")
        db.execute("INSERT INTO verdicts (id, proof_id, analyzer_version, contact_h, track_key, verdict, reasons_json, "
                   "context_json, created_at, request_id) VALUES (?, ?, ?, 'c', 'T1', 'GENUINE', '[]', '{}', "
                   "'2026-10-27T01:00:00Z', ?)", (1 if verdict_first else 500, pid, FORENSICS_VERSION, f"{rid2}#Mixing"))
        db.commit()
        db.close()
        forged = {**GOOD_ANSWER, "sender": {"email": "dana@bluefern-records.co", "confidence": 0.9}}
        texts = {}

        def sandbox(path, declared, ctx, want_text=False):
            text = "FORGED-DOC" if "777" in path else "GOOD-DOC"
            texts[path] = text
            return {"doc_text": text, "mime": "application/pdf", "kind": "contract", "facts": {}}

        def post(body, key, timeout):
            return or_response(forged if "FORGED-DOC" in body["messages"][1]["content"] else GOOD_ANSWER)
        self.deps.sandbox = sandbox
        self.deps.extractor = Extractor(self.store, key="k", post=post)
        return pid

    def _standing(self):
        return {(r["proof_id"], r["outcome"]) for r in self.store.latest_outcomes()}

    def test_account_hold_invalidates_an_earlier_verified_outcome(self):
        # QA #1380: verified document first, forged one later in the SAME run.
        bad = self._second_document(verdict_first=False)
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual([r["outcome"] for r in rows], [gate.VERIFIED, gate.FORGED])       # the order processed
        self.assertEqual(self._standing(), {(self.proof_id, gate.UNVERIFIABLE), (bad, gate.FORGED)})
        self.assertEqual(stats.superseded, 1)
        latest = [r for r in self.store.latest_outcomes() if r["proof_id"] == self.proof_id][0]
        self.assertEqual(latest["need"], gate.NEED_ACCOUNT)
        self.assertIn("supersedes verified row", latest["reason"])

    def test_account_hold_first_blocks_a_later_verification(self):
        bad = self._second_document(verdict_first=True)
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual([r["outcome"] for r in rows], [gate.FORGED, gate.UNVERIFIABLE])
        self.assertEqual(self._standing(), {(self.proof_id, gate.UNVERIFIABLE), (bad, gate.FORGED)})

    def test_account_hold_in_a_later_run_invalidates_an_earlier_run(self):
        runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(self._standing(), {(self.proof_id, gate.VERIFIED)})
        bad = self._second_document(verdict_first=False)
        runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(self._standing(), {(self.proof_id, gate.UNVERIFIABLE), (bad, gate.FORGED)})
        self.assertNotIn(gate.VERIFIED, {r["outcome"] for r in self.store.latest_outcomes(42)})

    def test_bytes_must_match_the_proof_id(self):
        Path(self.cache, "12345", "notif_x", "0.pdf").write_bytes(b"changed after H3 judged it")
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual(self.sandbox_calls, [])
        self.assertEqual((rows[0]["outcome"], rows[0]["need"]), (gate.UNKNOWN, None))   # never an ask

    def test_cache_path_cannot_escape_the_root(self):
        path, _, _ = runner.locate(["../../etc/passwd", "/etc/passwd"], "x", self.td.name, fetch=None, dl=None,
                                   cache_root=self.cache)
        self.assertIsNone(path)

    def test_transient_model_failure_retries_then_finalises(self):
        def down(*a):
            raise urllib.error.URLError("down")
        self.deps.extractor = Extractor(self.store, key="k", post=down)
        for _ in range(runner.MAX_EXTRACT_ATTEMPTS - 1):
            stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
            self.assertEqual((stats.retry, rows), (1, []))
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual((rows[0]["outcome"], rows[0]["need"]), (gate.UNKNOWN, None))   # never verifies, never asks

    def test_unknown_is_retried_then_stands(self):
        from credit_verify.docverify.store import MAX_UNKNOWN
        Path(self.cache, "12345", "notif_x", "0.pdf").write_bytes(b"not the file H3 judged")
        for n in range(1, MAX_UNKNOWN + 1):
            stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
            self.assertEqual([r["outcome"] for r in rows], [gate.UNKNOWN], n)
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")
        self.assertEqual((stats.documents, rows), (0, []))                              # the last unknown stands

    def test_intercom_ref_by_attachment_index(self):
        data = b"another document"
        pid = hashlib.sha256(data).hexdigest()

        def dl(url, dest):
            Path(dest).write_bytes(data)
            return len(data)
        conv = {"source": {"author": {"type": "user"}, "attachments": [{"url": "https://x/a.png"}]}}
        path, ref, errs = runner.locate(["intercom:999:0"], pid, self.td.name, fetch=lambda c: conv, dl=dl,
                                        cache_root=self.cache)
        self.assertEqual((ref, Path(path).read_bytes()), ("intercom:999:0", data))


class IntakeReq:
    """A credit request as stage2.requests returns it, for D2."""
    def __init__(self, rid=RID, uid=42, status="unverified", roles=("Mixing",)):
        self.request_id, self.user_id, self.status, self.roles = rid, uid, status, list(roles)
        self.track_id, self.isrc, self.names, self.title = "T1", "USAB12400001", ["Ann Alpha"], "Night Drive"
        self.artists, self.release_date = ["Small Act"], None


class IntakeD2Tests(unittest.TestCase):
    """D2: the reader takes proof_intake filings directly (proof-loop lead 2026-10-27)."""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        d = self.td.name
        self.cache = os.path.join(d, "cache")
        self.data = b"%PDF-1.4 a reply to core's more-details email"
        self.sha = hashlib.sha256(self.data).hexdigest()
        self.proof_path = os.path.join(d, "proof.sqlite")
        ps = ProofStore(self.proof_path)
        self.intake_id = ps.file_document(file_sha256=self.sha, user_id=42, conversation_id="777",
                                          candidate_request_ids=[RID], received_at="2026-10-27T20:00:00Z",
                                          matched_by="professional_id")
        ps.close()
        self.store = DocVerifyStore(os.path.join(d, "dv.sqlite"))
        self.reqs = {RID: IntakeReq()}
        self.fetches = []

        def fetch(cid):
            self.fetches.append(cid)
            return {"source": {"author": {"type": "user"}},
                    "conversation_parts": {"conversation_parts": [
                        {"author": {"type": "user"}, "attachments": [
                            {"url": "https://files/other.png", "name": "other.png"},
                            {"url": "https://files/doc.pdf", "name": "doc.pdf"}]}]}}

        def dl(url, dest):
            Path(dest).write_bytes(self.data if url.endswith("doc.pdf") else b"another file")
            return 1

        def sandbox(path, declared, ctx, want_text=False):
            return {"doc_text": "Blue Fern Records ... Ann Alpha mixed Night Drive", "mime": "application/pdf",
                    "kind": "contract", "facts": {}}
        self.h3 = {KEY: H3(verdict="GENUINE")}
        self.h3_calls = []

        def fake_shadow_h3(shadow, path, doc, requests, runner=None):
            self.h3_calls.append((Path(path).read_bytes(), doc.intake_id, [r.request_id for r in requests]))
            return self.h3
        self._patch = unittest.mock.patch.object(runner.intake_read, "shadow_h3", fake_shadow_h3)
        self._patch.start()
        self.answer = GOOD_ANSWER
        net = FakeNet(mb={"label": {"labels": [{"id": "L1", "name": "Blue Fern Records", "score": 100}]},
                          "label/L1": {"relations": [{"type": "official homepage",
                                                      "url": {"resource": "https://bluefern.com"}}]}},
                      pages={"https://bluefern.com/about": "Dana Reyes, label manager"},
                      deezer={"https://api.deezer.com/track/isrc:USAB12400001": {"album": {"id": 9}},
                              "https://api.deezer.com/album/9": {"label": "Blue Fern Records"}})
        self.deps = runner.Deps(
            sandbox=sandbox, extractor=Extractor(self.store, key="k", post=lambda *a: or_response(self.answer)),
            net=net, raw_credits=lambda tid: [raw("Ann Alpha", "Mixer")],
            requests=lambda ids: {i: self.reqs[i] for i in ids if i in self.reqs}, cache_root=self.cache,
            fetch=fetch, dl=dl, shadow_store=object())

    def tearDown(self):
        self._patch.stop()
        self.td.cleanup()

    def _run(self):
        return runner.run(self.store, self.deps, proof_store=self.proof_path, since="2026-10-27T00:00:00Z")

    def test_a_filed_document_is_read_by_sha_and_judged_against_its_open_request(self):
        stats, rows = self._run()
        self.assertEqual((stats.intake, stats.outcomes), (1, {"verified": 1}))
        self.assertEqual(self.fetches, ["777"])
        self.assertEqual(self.h3_calls, [(self.data, self.intake_id, [RID])])    # the bytes with the filed sha256
        o = self.store.db.execute("SELECT intake_id, proof_id, request_id, role, user_id, h3_verdict, source_ref "
                                  "FROM dv_outcomes").fetchone()
        self.assertEqual(tuple(o), (self.intake_id, self.sha, RID, "Mixing", 42, "GENUINE", "intercom:777:1"))
        stats, _ = self._run()                                                    # decided: not read again
        self.assertEqual(stats.intake, 0)

    def test_the_intake_path_never_writes_a_hold(self):
        self.answer = {**GOOD_ANSWER, "sender": {"email": "dana@bluefern-records.co", "confidence": 0.9}}
        stats, rows = self._run()
        self.assertEqual(rows[0]["outcome"], gate.FORGED)
        self.assertFalse(rows[0]["account_hold"])
        self.assertEqual(self.store.held_users(), set())
        detail = json.loads(self.store.db.execute("SELECT detail_json FROM dv_outcomes").fetchone()[0])
        self.assertTrue(detail["would_hold"])

    def test_no_h3_verdict_never_verifies(self):
        self.h3 = {}
        stats, rows = self._run()
        self.assertNotEqual(rows[0]["outcome"], gate.VERIFIED)

    def test_closed_or_foreign_requests_are_not_judged(self):
        self.reqs = {RID: IntakeReq(status="approved")}
        stats, rows = self._run()
        self.assertEqual((stats.intake, rows, self.h3_calls), (1, [], []))
        stats, _ = self._run()                                                    # closed: not looked at again
        self.assertEqual(stats.intake, 0)
        self.store.db.execute("DELETE FROM dv_steps")
        self.reqs = {RID: IntakeReq(uid=99)}                                      # another account's request
        stats, rows = self._run()
        self.assertEqual(rows, [])

    def test_a_document_not_found_in_its_conversation_is_retried_then_unknown(self):
        self.deps.dl = lambda url, dest: Path(dest).write_bytes(b"not it") and 1
        stats, rows = self._run()
        self.assertEqual(rows[0]["outcome"], gate.UNKNOWN)
        self.assertFalse(rows[0]["account_hold"])

    def test_completion_is_per_claim_not_per_document(self):
        # QA #1417: a verified claim does not end the retries of an unknown sibling.
        self.reqs = {RID: IntakeReq(roles=("Mixing", "Producer"))}
        self.h3 = {KEY: H3(verdict="GENUINE")}                  # no H3 verdict for the Producer claim -> unknown
        stats, rows = self._run()
        self.assertEqual(sorted((r["role"], r["outcome"]) for r in rows),
                         [("Mixing", gate.VERIFIED), ("Producer", gate.UNKNOWN)])
        for n in (2, 3):                                        # only the unknown claim is retried, MAX_UNKNOWN times
            stats, rows = self._run()
            self.assertEqual([(r["role"], r["outcome"]) for r in rows], [("Producer", gate.UNKNOWN)], n)
        stats, rows = self._run()
        self.assertEqual((stats.intake, rows), (0, []))          # settled: not even looked up

    def test_more_than_sixty_claims_are_all_read_over_runs(self):
        rids = [f"11111111-2222-3333-4444-{i:012d}" for i in range(70)]
        self.reqs = {r: IntakeReq(rid=r) for r in rids}
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json=?", (json.dumps(rids),))
        db.commit()
        db.close()
        self.h3 = {f"{r}#Mixing": H3(verdict="GENUINE") for r in rids}
        _, rows1 = self._run()
        _, rows2 = self._run()
        self.assertEqual((len(rows1), len(rows2)), (runner.MAX_INTAKE_CLAIMS, 70 - runner.MAX_INTAKE_CLAIMS))
        self.assertEqual({r["request_id"] for r in rows1 + rows2}, set(rids))

    def test_a_candidate_added_after_a_run_is_read_next_run(self):
        self._run()
        rid2 = "11111111-2222-3333-4444-000000000002"
        self.reqs[rid2] = IntakeReq(rid=rid2)
        self.h3 = {**self.h3, f"{rid2}#Mixing": H3(verdict="GENUINE")}
        ps = ProofStore(self.proof_path)
        self.assertTrue(ps.add_candidates(42, self.sha, [RID, rid2]))
        ps.close()
        stats, rows = self._run()
        self.assertEqual([r["request_id"] for r in rows], [rid2])   # only the new claim

    def test_a_filing_with_hundreds_of_claims_is_recorded_whole_and_never_breaks_selection(self):
        # Prod 2026-10-28 07:40Z: a 40-request filing's key list overflowed dv_steps' 20,000-char detail
        # cap; the truncated JSON raised inside selection and stopped the whole shard.
        rids = [f"11111111-2222-3333-4444-{i:012d}" for i in range(300)]
        self.reqs = {r: IntakeReq(rid=r, roles=("Mixing", "Mastering")) for r in rids}
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json=?", (json.dumps(rids),))
        db.commit()
        db.close()
        self.h3 = {f"{r}#{role}": H3(verdict="GENUINE") for r in rids for role in ("Mixing", "Mastering")}
        self._run()
        rec = self.store.intake_keys_recorded(self.intake_id)
        self.assertEqual((len(rec["candidates"]), len(rec["keys"])), (300, 600))       # whole, not truncated
        # an old truncated step record alone is unreadable -> "not recorded", never an exception
        self.store.db.execute("DELETE FROM dv_intake_keys")
        self.store.db.execute("INSERT INTO dv_steps (run_id, at, proof_id, request_id, step, status, detail_json, version)"
                              " VALUES ('r', '2026-10-28T07:40:00Z', 'p', ?, 'intake_keys', 'ok', ?, ?)",
                              (f"intake:{self.intake_id}", '{"candidates": ["aaa", "bb', VERSION))
        self.store.db.commit()
        self.assertIsNone(self.store.intake_keys_recorded(self.intake_id))
        self.assertFalse(self.store.intake_settled(self.intake_id, rids))
        stats, _ = self._run()                                                         # selection runs on
        self.assertEqual(stats.errors, [])

    def test_an_emailed_document_is_read_from_gmail_by_sha(self):
        from email.message import EmailMessage
        m = EmailMessage()
        m["From"] = "ann@example.com"
        m.set_content("proof")
        m.add_attachment(b"not it", maintype="image", subtype="png", filename="x.png")
        m.add_attachment(self.data, maintype="application", subtype="pdf", filename="sheet.pdf")
        raw = m.as_bytes()
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET conversation_id='gmail:18f00aa', source='email'")
        db.commit()
        db.close()
        asked = []
        self.deps.gmail_raw = lambda mid: asked.append(mid) or raw
        stats, rows = self._run()
        self.assertEqual((asked, self.fetches), (["18f00aa"], []))       # Gmail, never Intercom
        self.assertEqual(self.h3_calls[0][0], self.data)
        o = self.store.db.execute("SELECT source_ref, outcome FROM dv_outcomes").fetchone()
        self.assertEqual(tuple(o), ("gmail:18f00aa", gate.VERIFIED))

    def test_a_document_that_only_gives_unknown_stops_after_three_runs_not_per_pair(self):
        # Proof-loop lead 070: a 180-pair document with a document-level failure burned 3 rounds x 3 chunks.
        rids = [f"11111111-2222-3333-4444-{i:012d}" for i in range(70)]
        self.reqs = {r: IntakeReq(rid=r) for r in rids}
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json=?", (json.dumps(rids),))
        db.commit()
        db.close()
        self.deps.dl = lambda url, dest: Path(dest).write_bytes(b"not it") and 1    # never the filed bytes
        runs = 0
        while runs < 10:
            stats, rows = self._run()
            if not rows:
                break
            runs += 1
            self.assertEqual({r["outcome"] for r in rows}, {gate.UNKNOWN})
        self.assertEqual(runs, 4)          # 3 all-unknown runs, then one try for the 10 never attempted; per pair: 6
        self.assertTrue(self.store.intake_settled(self.intake_id, rids))

    def test_a_candidate_added_after_the_document_cap_is_still_read(self):
        # QA #1448: three unknown runs, then a new candidate request - it must be read, not settled unseen.
        self.deps.dl = lambda url, dest: Path(dest).write_bytes(b"not it") and 1
        for _ in range(3):
            self._run()
        self.assertTrue(self.store.intake_settled(self.intake_id, [RID]))
        rid2 = "11111111-2222-3333-4444-000000000002"
        self.reqs[rid2] = IntakeReq(rid=rid2)
        ps = ProofStore(self.proof_path)
        ps.add_candidates(42, self.sha, [RID, rid2])
        ps.close()
        stats, rows = self._run()
        self.assertEqual([r["request_id"] for r in rows], [rid2])          # read once ...
        self.assertEqual(rows[0]["outcome"], gate.UNKNOWN)
        self.assertTrue(self.store.intake_settled(self.intake_id, [RID, rid2]))

    def test_a_large_account_is_read_only_against_the_tracks_the_document_names(self):
        # Proof-loop lead 070: a 217-candidate account fanned every document out to 217 x roles pairs.
        others = [f"11111111-2222-3333-4444-{i:012d}" for i in range(1, 61)]
        self.reqs = {RID: IntakeReq(), **{r: IntakeReq(rid=r) for r in others}}
        for r in others:
            self.reqs[r].title, self.reqs[r].isrc = f"Other Song {r[-3:]}", None
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json=?", (json.dumps([RID] + others),))
        db.commit()
        db.close()
        stats, rows = self._run()
        self.assertEqual([(r["request_id"], r["outcome"]) for r in rows], [(RID, gate.VERIFIED)])  # Night Drive only
        self.assertEqual(len(self.store.intake_unmatched(self.intake_id)), 60)
        fan = json.loads(self.store.db.execute("SELECT detail_json FROM dv_steps WHERE step='intake_fanout'").fetchone()[0])
        self.assertEqual((fan["candidates"], fan["matched_keys"], fan["not_matched_keys"]), (61, 1, 60))
        self.assertTrue(self.store.intake_settled(self.intake_id, [RID] + others))
        stats, rows = self._run()
        self.assertEqual((stats.intake, rows), (0, []))                              # settled, not re-read

    def test_a_small_account_is_still_read_against_every_candidate(self):
        others = [f"11111111-2222-3333-4444-{i:012d}" for i in range(1, 5)]
        self.reqs = {RID: IntakeReq(), **{r: IntakeReq(rid=r) for r in others}}
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json=?", (json.dumps([RID] + others),))
        db.commit()
        db.close()
        stats, rows = self._run()
        self.assertEqual(len(rows), 5)
        self.assertEqual(self.store.intake_unmatched(self.intake_id), [])

    def _carry_one(self, outcome="unverifiable", need="readable_document"):
        """What carry_forward leaves: a row of the current VERSION with an OLD run id and `at`, and no step of this
        VERSION for that run; the filing's keys recorded (the carry copies dv_intake_keys too)."""
        self.store.db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, outcome, reason, "
                              "need, account_hold, detail_json, version, intake_id) VALUES ('dv-old-run', "
                              "'2026-10-28T09:00:00Z', ?, ?, 'Mixing', 42, ?, 'carried', ?, 0, '{}', ?, ?)",
                              (self.sha, RID, outcome, need, VERSION, self.intake_id))
        self.store.db.commit()
        self.store.record_intake_keys(self.intake_id, [RID], [KEY])

    def test_reread_carried_reads_only_carried_claims_then_stops(self):
        # Fable 134: carried rows wait for a re-read under the current rule; nothing in the reader selected them.
        self._carry_one()
        self.assertEqual(self.store.intake_carried_keys(self.intake_id), {KEY})
        self.assertEqual(self.store.carried_remaining(), {"rows": 1, "filings": 1, "closed_rows": 0})
        stats, rows = self._run()                                                   # an ordinary run: settled
        self.assertEqual((stats.intake, rows), (0, []))
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, reread_carried=True)
        self.assertEqual([(r["request_id"], r["role"], r["outcome"]) for r in rows], [(RID, "Mixing", gate.VERIFIED)])
        steps = {s for (s,) in self.store.db.execute("SELECT step FROM dv_steps WHERE version=?", (VERSION,))}
        self.assertTrue({"extract", "forensics", "gate"} <= steps)                  # a real read, with its steps
        self.assertEqual(self.store.intake_carried_keys(self.intake_id), set())
        self.assertEqual(self.store.carried_remaining(), {"rows": 0, "filings": 0, "closed_rows": 0})
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, reread_carried=True)
        self.assertEqual((stats.intake, rows), (0, []))                             # done: never read twice
        self.assertEqual(len(self.h3_calls), 1)

    def test_reread_carried_never_starves_a_new_filing(self):
        # Fable 136: new documents first; carried re-reads only fill the idle room.
        self._carry_one()
        data2 = b"%PDF-1.4 a NEW filing that arrived after the carry"
        sha2 = hashlib.sha256(data2).hexdigest()
        rid2 = "11111111-2222-3333-4444-000000000009"
        ps = ProofStore(self.proof_path)
        ps.file_document(file_sha256=sha2, user_id=42, conversation_id="778", candidate_request_ids=[rid2],
                                received_at="2026-10-29T08:00:00Z", matched_by="professional_id")
        ps.close()
        self.reqs[rid2] = IntakeReq(rid=rid2)
        self.h3 = {**self.h3, f"{rid2}#Mixing": H3(verdict="GENUINE")}
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, reread_carried=True, max_docs=1)
        self.assertEqual(stats.intake, 1)
        self.assertEqual({r["request_id"] for r in rows}, {rid2})                   # the new filing, not the carry
        self.assertEqual(self.store.intake_carried_keys(self.intake_id), {KEY})     # the carry waits ...
        for _ in range(3):        # the new filing is retried (its file is not found here) and then settles
            stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, reread_carried=True, max_docs=1)
            if {r["request_id"] for r in rows} == {RID}:
                break
        self.assertEqual({r["request_id"] for r in rows}, {RID})                    # ... for the idle room
        self.assertEqual(self.store.intake_carried_keys(self.intake_id), set())

    def test_reread_carried_never_loops_on_a_request_closed_since(self):
        self._carry_one()
        self.reqs = {}                                                              # the request closed since
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, reread_carried=True)
        self.assertEqual(rows, [])
        self.assertEqual(self.store.intake_carried_keys(self.intake_id), set())     # recorded keys refreshed
        # QA #1493: a closed carried claim is not unfinished work - the metric reaches 0 and names it apart
        self.assertEqual(self.store.carried_remaining(), {"rows": 0, "filings": 0, "closed_rows": 1})
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, reread_carried=True)
        self.assertEqual(stats.intake, 0)

    def test_the_cli_passes_reread_carried_to_the_runner_and_the_workers(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("cdv", Path(__file__).resolve().parents[1] / "credit-doc-verify.py")
        cdv = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cdv)
        args = cdv.parser().parse_args(["run", "--reread-carried", "--max-docs", "2"])
        self.assertTrue(args.reread_carried)
        self.assertIn("--reread-carried", cdv.worker_argv(args, 0, 4, 1))
        self.assertNotIn("--reread-carried", cdv.worker_argv(cdv.parser().parse_args(["run"]), 0, 4, 1))
        src = (Path(__file__).resolve().parents[1] / "credit-doc-verify.py").read_text()
        self.assertIn("reread_carried=args.reread_carried", src)
        self.assertIn("if args.reread_carried and (shard is None or shard[0] == 0)", src)     # one shard reports it

    def test_a_low_confidence_title_never_ties_a_deny_to_a_request(self):
        # QA #1482 03:15Z: a 0.1-confidence (misread) title matching the request must not set `covers`.
        sigs = [{"name": "after_creation_key_field_edit", "severity": "soft", "check": "F4",
                 "value": {"fields": ["claimant_name"]}, "page": 1, "region": [10, 10, 90, 20]},
                {"name": "template_family", "severity": "info", "check": "F2b", "value": {"other_accounts": 2}}]
        self.h3 = {KEY: H3(verdict="SUSPECT", kind="contract", signals=sigs)}
        for conf, want in ((0.1, gate.FORGED), (0.9, gate.FORGED_POSITIVE)):
            self.store.db.execute("DELETE FROM dv_outcomes")
            self.store.db.execute("DELETE FROM dv_steps")
            self.store.db.execute("DELETE FROM dv_intake_keys")
            self.store.db.execute("DELETE FROM dv_extract_cache")      # the cache would (rightly) replay the 0.1 answer
            self.store.db.commit()
            self.answer = {**GOOD_ANSWER, "credits": [],
                           "tracks": [{"title": "Night Drive", "isrc": "USAB12400001", "confidence": conf}]}
            self.deps.extractor = Extractor(self.store, key=f"k{conf}", post=lambda *a: or_response(self.answer))
            stats, rows = self._run()
            self.assertEqual(rows[0]["outcome"], want, conf)
        ex = validate({**GOOD_ANSWER, "credits": [], "tracks": [{"title": "Night Drive", "isrc": "USAB12400001",
                                                                   "confidence": 0.1}]})
        self.assertTrue(runner.named_by(ex, IntakeReq()))                           # the fan-out cut: any read
        self.assertFalse(runner.named_by(ex, IntakeReq(), 0.6))                     # the deny tie: >= 0.6 only

    def test_a_positive_document_in_a_small_filing_denies_only_its_track(self):
        # Fable NO-GO #1482: the <= 5-candidate tie must not carry a deny. e9ec352a's shape: 5 requests on the
        # account, a positively forged document that names ONE of the tracks.
        from credit_verify.docverify import tray
        others = [f"11111111-2222-3333-4444-{i:012d}" for i in range(1, 5)]
        self.reqs = {RID: IntakeReq(), **{r: IntakeReq(rid=r) for r in others}}
        for r in others:
            self.reqs[r].title, self.reqs[r].isrc = f"Other Song {r[-1]}", None
        db = sqlite3.connect(self.proof_path)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json=?", (json.dumps([RID] + others),))
        db.commit()
        db.close()
        sigs = [{"name": "after_creation_key_field_edit", "severity": "soft", "check": "F4",
                 "value": {"fields": ["claimant_name"]}, "page": 1, "region": [10, 10, 90, 20]},
                {"name": "template_family", "severity": "info", "check": "F2b", "value": {"other_accounts": 2}}]
        self.h3 = {f"{r}#Mixing": H3(verdict="SUSPECT", kind="contract", signals=sigs) for r in [RID] + others}
        stats, rows = self._run()
        by = {r["request_id"]: r for r in rows}
        self.assertEqual(len(by), 5)
        self.assertEqual(by[RID]["outcome"], gate.FORGED_POSITIVE)                  # Night Drive: named
        got = {rid: json.loads(d) for rid, d in self.store.db.execute(
            "SELECT request_id, detail_json FROM dv_outcomes")}
        self.assertTrue(got[RID]["covers"])
        for r in others:                                                            # never named: a hold
            self.assertEqual(by[r]["outcome"], gate.FORGED, r)
            self.assertTrue(got[r]["positive_document"], r)
            self.assertNotIn("covers", got[r], r)
        rows_t, _ = tray.forged_tray(self.store, intake_of=lambda iid: {},
                                     rulings=tray.parse_rulings(f"ruling: forged-{self.sha[:8]} confirm"))
        row = next(t for t in rows_t if t["ruling_id"] == f"forged-{self.sha[:8]}")
        self.assertTrue(row["executable"], row.get("why_not"))
        self.assertEqual([q["request_id"] for q in row["requests"]], [RID])           # one request, the named one

    def test_pairs_eval_runs_never_pick_up_intake(self):
        stats, _ = runner.run(self.store, self.deps, proof_store=self.proof_path, pairs={})
        self.assertEqual(stats.intake, 0)

    def test_shadow_store_reads_h3_and_writes_nothing(self):
        from credit_verify.docverify.intake_read import ShadowProofStore
        sh = ShadowProofStore.open(self.proof_path)
        self.assertEqual(sh._prior(), [])
        sh.record(fp=None, verdict="GENUINE", request_id=KEY)
        self.assertEqual(sh.recorded, [{"verdict": "GENUINE", "request_id": KEY}])
        with self.assertRaises(sqlite3.OperationalError):
            sh.db.execute("INSERT INTO verdicts (proof_id) VALUES ('x')")


class ShadowH3RealTests(unittest.TestCase):
    """D2's shadow H3 on a real PDF: H3 judges the claim, proof.sqlite is byte-identical after."""

    def test_shadow_h3_judges_and_leaves_the_h3_store_untouched(self):
        from credit_verify.proof import analyze, pdf_forensics
        from credit_verify.proof.signals import ClaimContext
        if not pdf_forensics.available():
            self.skipTest("PyMuPDF required")
        from credit_verify.docverify import intake_read
        with tempfile.TemporaryDirectory() as d:
            doc = pdf_forensics.pymupdf.open()
            page = doc.new_page()
            for i, line in enumerate(["SPLIT SHEET", "Song Title: Night Drive", "ISRC: USAB12400001",
                                      "Artist: Small Act", "Mixing: Ann Alpha", "Signed 2024-03-01"]):
                page.insert_text((72, 72 + 16 * i), line, fontname="helv", fontsize=11)
            path = os.path.join(d, "sheet.pdf")
            Path(path).write_bytes(doc.tobytes())
            proof = os.path.join(d, "proof.sqlite")
            ProofStore(proof).close()
            before = hashlib.sha256(Path(proof).read_bytes()).hexdigest()
            shadow = intake_read.ShadowProofStore.open(proof)
            idoc = intake_read.IntakeDoc("42:x", 42, "x", "777", None, "c")

            def runner_(p, dcl, c, cs):
                return analyze.extract(p, dcl, ClaimContext.from_dict(c), [ClaimContext.from_dict(x) for x in cs])
            out = intake_read.shadow_h3(shadow, path, idoc, [IntakeReq()], runner=runner_)
            shadow.db.close()
            self.assertEqual(set(out), {KEY})
            self.assertIsNotNone(out[KEY].verdict)
            self.assertEqual(hashlib.sha256(Path(proof).read_bytes()).hexdigest(), before)
            self.assertEqual(len(shadow.recorded), 1)


class LiveAnchorTests(unittest.TestCase):
    def test_both_dsps_must_credit_the_claimant_on_a_fresh_capture(self):
        now = datetime(2026, 10, 28, tzinfo=timezone.utc)
        since = "2026-10-27T21:00:00Z"
        fam = xc.family_of("Mixer")
        fresh = [raw("Ann Alpha", "Mixer", "spotify", "2026-10-27T22:00:00Z"),
                 raw("Ann Alpha", "Mixer", "tidal", "2026-10-27T22:05:00Z")]
        self.assertEqual(xc.live_anchor(fresh, fam, ["Ann Alpha"], since, now), {"spotify": True, "tidal": True})
        self.assertEqual(xc.live_anchor(fresh, fam, ["Ann Alpha"], None, now), {"spotify": False, "tidal": False})
        stale = [raw("Ann Alpha", "Mixer", "spotify", "2026-10-01T00:00:00Z"), fresh[1]]       # captured before the run
        self.assertEqual(xc.live_anchor(stale, fam, ["Ann Alpha"], since, now), {"spotify": False, "tidal": True})
        other = [raw("Bob Beta", "Mixer", "spotify", "2026-10-27T22:00:00Z"), fresh[1]]        # credits someone else
        self.assertFalse(xc.live_anchor(other, fam, ["Ann Alpha"], since, now)["spotify"])
        mlc = [raw("Ann Alpha", "Mixer", "mlc", "2026-10-27T22:00:00Z"), fresh[1]]             # MLC never anchors
        self.assertFalse(xc.live_anchor(mlc, fam, ["Ann Alpha"], since, now)["spotify"])
        c = xc.dsp(fresh, "Mixing", ["Ann Alpha"], None, since)
        self.assertEqual(c.detail["fresh_anchor"], {"spotify": True, "tidal": True})


class ParallelReaderTests(unittest.TestCase):
    """run --workers N (proof-loop lead 2026-10-28): shards never overlap; pacing is cross-process."""

    def test_two_workers_never_take_the_same_document_and_together_take_all(self):
        from credit_verify.docverify import intake_read, pace
        with tempfile.TemporaryDirectory() as d:
            ps = ProofStore(os.path.join(d, "proof.sqlite"))
            shas = [hashlib.sha256(f"doc {i}".encode()).hexdigest() for i in range(40)]
            for i, sha in enumerate(shas):
                ps.file_document(file_sha256=sha, user_id=100 + i % 7, conversation_id=str(i),
                                 candidate_request_ids=[RID], received_at=f"2026-10-27T{i % 24:02d}:00:00Z")
            ps.file_document(file_sha256=shas[0], user_id=999, conversation_id="x", candidate_request_ids=[RID],
                             received_at="2026-10-27T00:00:00Z")       # same bytes, second account
            taken = []
            for i in range(2):
                docs = intake_read.intake_docs(ps.db, lambda *_: False, 1000,
                                               keep=lambda pid, i=i: pace.shard_of(pid, 2) == i)
                taken.append({x.sha for x in docs})
            self.assertEqual(taken[0] & taken[1], set())
            self.assertEqual(taken[0] | taken[1], set(shas))
            self.assertTrue(all(len(t) > 5 for t in taken))               # both workers get work

    def test_paid_accounts_come_first_then_oldest(self):
        from credit_verify.docverify import intake_read
        ps = ProofStore(":memory:")
        for uid, at in ((1, "2026-10-01T00:00:00Z"), (2, "2026-10-20T00:00:00Z"), (3, "2026-10-10T00:00:00Z")):
            ps.file_document(file_sha256=f"{uid:064x}", user_id=uid, conversation_id=str(uid),
                             candidate_request_ids=[RID], received_at=at)
        docs = intake_read.intake_docs(ps.db, lambda *_: False, 10, paying={2, 3})
        self.assertEqual([x.user_id for x in docs], [3, 2, 1])
        self.assertEqual([x.user_id for x in intake_read.intake_docs(ps.db, lambda *_: False, 10)], [1, 3, 2])

    def test_the_pacer_spaces_calls_across_processes(self):
        import subprocess
        import time
        with tempfile.TemporaryDirectory() as d:
            code = ("import sys,time; sys.path.insert(0,%r); from credit_verify.docverify.pace import Pacer; "
                    "p=Pacer('mbtest',0.3,directory=%r); "
                    "[ (p.wait(), print(repr(p._last))) for _ in range(3) ]") % (
                str(Path(__file__).resolve().parents[1]), d)
            t0 = time.time()
            procs = [subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True) for _ in range(2)]
            stamps = sorted(float(x) for p in procs for x in p.communicate()[0].split())
            self.assertEqual(len(stamps), 6)
            gaps = [b - a for a, b in zip(stamps, stamps[1:])]
            self.assertGreaterEqual(min(gaps), 0.28, gaps)                # never two calls inside the interval
            self.assertLess(time.time() - t0, 10)

    def test_a_strict_pacer_in_several_processes_never_calls_unpaced(self):
        # QA #1433: the fallback in N workers would be N calls/s; a parallel worker fails closed.
        import subprocess
        code = ("import sys; sys.path.insert(0,%r); from credit_verify.docverify.pace import Pacer, PaceError\n"
                "p=Pacer('mb',1.0,directory='/dev/null/nope',strict=True)\n"
                "try:\n p.wait(); print('CALLED')\nexcept PaceError: print('REFUSED')") % (
            str(Path(__file__).resolve().parents[1]),)
        procs = [subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True) for _ in range(3)]
        self.assertEqual([p.communicate()[0].strip() for p in procs], ["REFUSED"] * 3)

    def test_an_unusable_pace_dir_falls_back_to_in_process_pacing(self):
        from credit_verify.docverify.pace import Pacer
        said = []
        p = Pacer("x", 0.0, directory="/dev/null/nope", log=said.append)
        p.wait()
        p.wait()
        self.assertEqual(len(said), 1)

    @staticmethod
    def _cdv():
        import importlib.util
        spec = importlib.util.spec_from_file_location("cdv", Path(__file__).resolve().parents[1] / "credit-doc-verify.py")
        cdv = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cdv)
        return cdv

    def test_the_budget_is_split_exactly_never_above_max_docs(self):
        # QA #1433: ceil-per-worker let 4 workers read 8 documents on --max-docs 5.
        cdv = self._cdv()
        self.assertEqual(cdv.budgets(5, 4), [2, 1, 1, 1])
        self.assertEqual(cdv.budgets(30, 4), [8, 8, 7, 7])
        self.assertEqual(cdv.budgets(2, 4), [1, 1, 0, 0])
        self.assertEqual(cdv.budgets(0, 3), [0, 0, 0])
        for m in range(0, 40):
            for n in range(1, 9):
                self.assertEqual(sum(cdv.budgets(m, n)), m)

    def _run_workers(self, cdv, rcs, max_docs=5, workers=4):
        import argparse
        started = []

        class P:
            def __init__(self, argv):
                started.append(argv)
                self.rc = rcs[len(started) - 1]

            def wait(self):
                return self.rc
        a = argparse.Namespace(store=None, proof_store="/p.sqlite", max_docs=max_docs, since=None, workers=workers)
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {}):
            from credit_verify.docverify import pace
            with unittest.mock.patch.object(pace, "PACE_DIR", d):
                return cdv.run_workers(a, popen=P), started

    def test_zero_budget_workers_are_not_started_and_argv_carries_the_shard(self):
        cdv = self._cdv()
        rc, started = self._run_workers(cdv, [0, 0, 0, 0], max_docs=2)
        self.assertEqual(rc, 0)
        self.assertEqual([a[a.index("--shard") + 1] for a in started], ["0/4", "1/4"])
        self.assertEqual([a[a.index("--max-docs") + 1] for a in started], ["1", "1"])

    def test_any_nonzero_worker_exit_fails_the_run_including_a_signal(self):
        # QA #1433: max([0, 0, -9, 0]) == 0 reported a SIGKILLed shard as success.
        cdv = self._cdv()
        self.assertEqual(self._run_workers(cdv, [0, 0, -9, 0])[0], 1)
        self.assertEqual(self._run_workers(cdv, [0, 3, 0, 0])[0], 1)
        self.assertEqual(self._run_workers(cdv, [0, 0, 0, 0])[0], 0)

    def test_workers_refuse_to_start_without_a_usable_pace_directory(self):
        import argparse
        cdv = self._cdv()
        from credit_verify.docverify import pace
        a = argparse.Namespace(store=None, proof_store="/p", max_docs=4, since=None, workers=4)
        with unittest.mock.patch.object(pace, "PACE_DIR", "/dev/null/nope"):
            self.assertEqual(cdv.run_workers(a, popen=lambda argv: self.fail("a worker was started")), 2)


class RawCreditsCacheTests(unittest.TestCase):
    """One admin GET per track per TTL, shared by every reader process (2026-10-28: admin GETs at 1/s
    host-wide were 60% of reader time; an account's documents name the same tracks)."""

    def test_one_fetch_per_track_across_documents_and_processes(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "dv.sqlite")
            a, b = DocVerifyStore(path), DocVerifyStore(path)      # two reader processes, one store
            calls = []

            def fetch(tid):
                calls.append(tid)
                return [raw("Ann Alpha", "Mixer")]
            self.assertEqual(a.cached_raw_credits("T1", fetch, now=1000.0), [raw("Ann Alpha", "Mixer")])
            self.assertEqual(b.cached_raw_credits("T1", fetch, now=1500.0), [raw("Ann Alpha", "Mixer")])
            self.assertEqual(calls, ["T1"])
            b.cached_raw_credits("T1", fetch, ttl_s=600, now=1700.0)          # expired: asked again
            self.assertEqual(calls, ["T1", "T1"])

    def test_concurrent_readers_fetch_a_track_once(self):
        # QA #1440: two readers missing the cache at the same moment both fetched. Four real processes,
        # a slow fetch, one shared store: exactly one fetch.
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "dv.sqlite")
            DocVerifyStore(path).db.close()
            log = os.path.join(d, "fetches.log")
            code = ("import sys,time; sys.path.insert(0,%r); from credit_verify.docverify.store import DocVerifyStore\n"
                    "s=DocVerifyStore(%r)\n"
                    "def f(t):\n open(%r,'a').write('x'); time.sleep(0.5); return [{'n': 1}]\n"
                    "print(s.cached_raw_credits('T1', f))") % (str(Path(__file__).resolve().parents[1]), path, log)
            procs = [subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True) for _ in range(4)]
            outs = [p.communicate()[0].strip() for p in procs]
            self.assertEqual(outs, ["[{'n': 1}]"] * 4)
            self.assertEqual(Path(log).read_text(), "x")                      # one admin GET for four readers

    def test_an_unusable_lock_fails_closed_while_the_cache_still_works(self):
        # QA #1440: the lock path must not silently fall back to unlocked GETs.
        from credit_verify.docverify.store import RawCreditsLockError
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        s = DocVerifyStore(os.path.join(td.name, "dv.sqlite"))
        Path(td.name, "raw-credits-locks").write_text("not a directory")           # lock files cannot be made
        calls = []
        with self.assertRaises(RawCreditsLockError):
            s.cached_raw_credits("T1", lambda t: calls.append(t) or [])
        self.assertEqual(calls, [])                                                 # no unlocked admin GET
        s.db.execute("INSERT INTO dv_raw_credits (track_id, at, items_json) VALUES ('T2', ?, '[]')",
                     (f"{__import__('time').time():.3f}",))
        s.db.commit()
        self.assertEqual(s.cached_raw_credits("T2", lambda t: self.fail("hit")), [])   # cache hits need no lock

    def test_a_failed_fetch_is_never_cached(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        s = DocVerifyStore(os.path.join(td.name, "dv.sqlite"))

        def boom(tid):
            raise RuntimeError("admin 502")
        with self.assertRaises(RuntimeError):
            s.cached_raw_credits("T2", boom)
        self.assertIsNone(s.db.execute("SELECT 1 FROM dv_raw_credits WHERE track_id='T2'").fetchone())
        self.assertEqual(s.cached_raw_credits("T2", lambda t: []), [])          # an empty list is a real answer

    def test_a_cache_hit_records_when_the_credits_were_read_and_is_never_same_run(self):
        # Ruling 057: the evidence carries the read time; a cached read never counts as a same-run anchor.
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        s = DocVerifyStore(os.path.join(td.name, "dv.sqlite"))
        s.cached_raw_credits("T1", lambda t: [raw("Ann Alpha", "Mixer")], now=1793170000.0)
        self.assertEqual(s.raw_credits_read_at("T1"), "2026-10-28T06:46:40Z")
        self.assertIsNone(s.raw_credits_read_at("T9"))
        src = (Path(__file__).resolve().parents[1] / "credit_verify" / "docverify" / "runner.py").read_text()
        self.assertIn('checks[-1].detail["raw_credits_read_at"] = store.raw_credits_read_at(r.track_id)', src)
        c = xc.dsp(s.cached_raw_credits("T1", lambda t: self.fail("cached"), now=1793170001.0), "Mixing",
                   ["Ann Alpha"], None, None)
        self.assertEqual((c.status, c.detail["fresh_since"], c.detail["fresh_anchor"]),
                         (xc.POSITIVE, None, {"spotify": False, "tidal": False}))

    def test_the_cli_wires_the_cache_in_front_of_the_paced_admin_get(self):
        src = (Path(__file__).resolve().parents[1] / "credit-doc-verify.py").read_text()
        self.assertIn("raw_credits=lambda tid: store.cached_raw_credits(", src)
        self.assertIn("ad.paced(lambda t: admin_api.track_raw_credits(admin, t))", src)


class TrayTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.store = DocVerifyStore(os.path.join(self.td.name, "dv.sqlite"))

    def tearDown(self):
        self.td.cleanup()

    def _out(self, pid, rid, outcome, need=None, uid=42, fresh=True, dsp="positive", anchor=("spotify", "tidal")):
        self.store.outcome("r1", proof_id=pid, request_id=rid, role="Mixing", user_id=uid, source_ref="s",
                           h3_verdict="GENUINE", outcome=outcome, reason="why", need=need, account_hold=False,
                           detail={"issuer": {"name": "Blue Fern"}, "received_at": "2026-10-27T20:00:00Z"},
                           intake_id=f"{uid}:{pid}")
        self.store.step("r1", pid, "xc_dsp", dsp, {"fresh_since": "2026-10-27T21:00:00Z" if fresh else None,
                                                   "fresh_anchor": {d: d in anchor for d in ("spotify", "tidal")}},
                        f"{rid}#Mixing")

    def test_trays_sort_by_outcome_and_anchor(self):
        from credit_verify.docverify import tray
        self._out("p1", "r-ok", "verified")
        self._out("p2", "r-stale", "verified", fresh=False)
        self._out("p3", "r-gate", "verified", uid=7)
        self._out("p6", "r-tidal-only", "verified", anchor=("tidal",))          # QA #1417: one DSP is not enough
        self._out("p7", "r-no-fresh-row", "verified", anchor=())                # fresh_since alone is not an anchor
        for i in range(22):
            self._out(f"f{i}", f"r-f{i}", "forged")
        self._out("p4", "r-need", "unverifiable", need="distributor_dashboard_with_code")
        self._out("p5", "r-unk", "unknown")
        t = tray.build(self.store, gate=lambda uid: (uid == 42, f"account gate {'allow' if uid == 42 else 'hold'}"),
                       tracks=lambda ids: {i: "Night Drive" for i in ids})
        self.assertEqual([a["request_id"] for a in t.approve], ["r-ok"])
        self.assertEqual(sorted(a["request_id"] for a in t.not_approvable),
                         ["r-gate", "r-no-fresh-row", "r-stale", "r-tidal-only"])
        self.assertIn("spotify", next(a for a in t.not_approvable if a["request_id"] == "r-tidal-only")["why"])
        self.assertIn("same-run", next(a for a in t.not_approvable if a["request_id"] == "r-stale")["why"])
        self.assertEqual([a["first_20_human"] for a in t.decline["forged"]].count(True), 20)
        self.assertEqual(t.need, [{"user_id": 42, "request_id": "r-need", "need": "distributor_dashboard_with_code",
                                   "track": "Night Drive", "role": "Mixing", "issuer": "Blue Fern",
                                   "received_at": "2026-10-27T20:00:00Z"}])
        self.assertEqual(t.retry, 1)
        md = tray.markdown(t, 1, "2026-10-27T23:00:00Z")
        self.assertIn("APPROVE 1", md)
        self.assertIn("Nothing here has been written to core", md)
        self.assertIn("0 document(s) read under an older rule version", md)
        self.assertIn("`verified` before dv-3 is the real-not-proof class", md)          # Fable 106

    def test_a_version_bump_carries_documents_the_rule_cannot_change_and_rereads_the_rest(self):
        # Proof-loop lead 075: a rule change is a VERSION bump; the deployed reader re-reads, nobody hand-writes.
        from credit_verify.docverify import tray
        db = self.store.db

        def old(pid, outcome, iid=None, n=1, detail="{}"):
            for _ in range(n):
                db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, outcome, reason, "
                           "account_hold, detail_json, version, intake_id) VALUES ('r0', '2026-10-28T14:00:00Z', ?, "
                           "'rq', 'Mixing', 42, ?, 'x', 0, ?, 'dv-old', ?)", (pid, outcome, detail, iid))
        old("pa", "unverifiable", "42:aa")
        old("pb", "forged", "42:bb")                         # the misread-sender 'forged': re-read
        old("pc", "unknown", "42:cc", n=3)                   # exhausted retries carry as exhausted
        old("pd", "unverifiable", "42:dd")
        old("pd", "verified", "42:dd")                       # the standing row is verified: re-read
        old("pe", "unverifiable", "42:ee", detail="{not json")
        db.execute("INSERT INTO dv_intake_keys VALUES ('42:aa', 'dv-old', 't', '[\"rq\"]', '[\"rq#Mixing\"]')")
        db.execute("INSERT INTO dv_intake_keys VALUES ('42:bb', 'dv-old', 't', '[\"rq\"]', '[\"rq#Mixing\"]')")
        db.commit()
        # QA #1466: an unverifiable email whose sender check RAN (a low-confidence '.ora') is re-read, since
        # dv-2 changes its need to readable_document; a document whose sender check was skipped carries.
        old("pf", "unverifiable", "42:ff")
        for pid, status in (("pf", "weak"), ("pa", "skipped")):
            db.execute("INSERT INTO dv_steps (run_id, at, proof_id, request_id, step, status, detail_json, version) "
                       "VALUES ('r0', 't', ?, '', 'xc_domain', ?, '{\"sender_domain\": \"michaelosbome.ora\"}', "
                       "'dv-old')", (pid, status))
        db.commit()
        n = self.store.carry_forward("dv-old", VERSION, frozenset({"forged", "verified"}), ("xc_domain",))
        self.assertEqual(n, 5)                                            # pa 1 + pc 3 + pe 1 (pf re-read)
        cur = {(p, o) for p, o in db.execute("SELECT proof_id, outcome FROM dv_outcomes WHERE version=?",
                                             (VERSION,))}
        self.assertEqual(cur, {("pa", "unverifiable"), ("pc", "unknown"), ("pe", "unverifiable")})
        marked = json.loads(db.execute("SELECT detail_json FROM dv_outcomes WHERE version=? AND proof_id='pa'",
                                       (VERSION,)).fetchone()[0])
        self.assertEqual(marked["carried_from"]["version"], "dv-old")
        self.assertTrue(self.store.intake_settled("42:aa", ["rq"]))       # carried: no re-read, no Trino
        self.assertFalse(self.store.intake_settled("42:bb", ["rq"]))      # re-read by the deployed reader
        self.assertTrue(self.store.intake_settled("42:cc", ["rq"]) or self.store.intake_finished_keys("42:cc"))
        self.assertFalse(self.store.intake_settled("42:ff", ["rq"]))      # its sender check ran: re-read
        self.assertEqual(self.store.carry_forward("dv-old", VERSION, frozenset({"forged"})), 0)  # once
        self.assertEqual(self.store.awaiting_reread(), 3)                 # pb, pd, pf
        t = tray.build(self.store, gate=lambda uid: (True, "allow"), tracks=lambda ids: {})
        self.assertEqual((t.decline["forged"], t.not_approvable, t.approve), ([], [], []))   # old rows: no section
        self.assertIn("3 document(s) read under an older rule version", tray.markdown(t, 3, "now"))

    def test_the_dv2_carry_rereads_documents_with_any_fraud_signal(self):
        # A carried document could never become forged_positive: every one with a fraud-family signal is re-read.
        db = self.store.db
        for pid, det in (("px", '{"findings": [{"name": "h3_key_field_unique_font", "severity": "soft"}]}'),
                         ("py", '{"h3_reasons": ["F2 reused_by_another_account"], "findings": '
                                '[{"name": "h3_reused_by_another_account", "severity": "soft"}]}')):
            db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, outcome, reason, account_hold, "
                       "detail_json, version, intake_id) VALUES ('r', 't', ?, 'rq', 'Mixing', 'unverifiable', 'x', 0, "
                       "'{}', 'dv-old', ?)", (pid, f"42:{pid}"))
            db.execute("INSERT INTO dv_steps (run_id, at, proof_id, request_id, step, status, detail_json, version) "
                       "VALUES ('r', 't', ?, 'rq#Mixing', 'forensics', 'ok', ?, 'dv-old')", (pid, det))
        db.commit()
        from credit_verify.docverify import FRAUD_SIGNAL_FAMILY
        self.store.carry_forward("dv-old", VERSION, frozenset({"forged", "verified"}), ("xc_domain",),
                                 ("forensics", tuple(sorted(FRAUD_SIGNAL_FAMILY))))
        carried = {p for (p,) in db.execute("SELECT proof_id FROM dv_outcomes WHERE version=?", (VERSION,))}
        self.assertEqual(carried, {"py"})            # soft reuse alone is no signal: carries; the font edit: re-read

    def test_reports_open_the_store_read_only(self):
        # QA #1470: forged-tray never creates the store, alters it or runs the carry-forward.
        import sqlite3 as _sq
        missing = os.path.join(self.td.name, "absent.sqlite")
        with self.assertRaises(FileNotFoundError):
            DocVerifyStore.read_only(missing)
        self.assertFalse(os.path.exists(missing))
        ro = DocVerifyStore.read_only(os.path.join(self.td.name, "dv.sqlite"))
        self.assertEqual(ro.latest_outcomes(), [])
        with self.assertRaises(_sq.OperationalError):
            ro.db.execute("INSERT INTO dv_state (k, v) VALUES ('x', 'y')")
        src = (Path(__file__).resolve().parents[1] / "credit-doc-verify.py").read_text()
        body = src[src.index("def cmd_forged_tray("):src.index("def cmd_tray(")]
        self.assertIn("DocVerifyStore.read_only(", body)
        self.assertNotIn("DocVerifyStore(args.store)", body)

    def test_forged_tray_rows_are_executable_only_after_a_fable_confirm(self):
        from credit_verify.docverify import tray
        pair = [{"id": "h3_after_creation_key_field_edit@p1:[1, 1, 9, 9]", "family": "file_tamper",
                 "fields": ["claimant_name"], "page": 1, "region": [1, 1, 9, 9]}, {"id": "template_reused", "family": "template"}]
        det = {"fraud_signals": pair, "fraud_pair": pair, "covers": True}
        for rid in ("r1", "r2"):
            self.store.outcome("run", proof_id="e9ec352af3aa", request_id=rid, role="Mixing", user_id=244090,
                               source_ref="conv 9", h3_verdict="SUSPECT", outcome="forged_positive", reason="two",
                               need=None, account_hold=False, detail=det, intake_id="244090:e9ec")
        self.store.outcome("run", proof_id="0123456789ab", request_id="r3", role="Producer", user_id=7,
                           source_ref="conv 8", h3_verdict="SUSPECT", outcome="forged_positive", reason="two",
                           need=None, account_hold=False, detail=det, intake_id="7:0123")
        self.store.outcome("run", proof_id="ffffffffffff", request_id="r4", role="Mixing", user_id=8,
                           source_ref="c", h3_verdict="FORGED_LIKELY", outcome="forged", reason="one",
                           need=None, account_hold=False, detail={}, intake_id="8:ffff")
        stale = {"fraud_signals": pair[:1], "fraud_pair": pair, "covers": True}                 # a pair the rule no longer accepts
        self.store.outcome("run", proof_id="abcdef0123ff", request_id="r5", role="Mixing", user_id=9,
                           source_ref="c", h3_verdict="SUSPECT", outcome="forged_positive", reason="two",
                           need=None, account_hold=False, detail=stale, intake_id="9:abcd")
        backfill = DocVerifyStore(os.path.join(self.td.name, "backfill.sqlite"))
        backfill.outcome("run", proof_id="160aafa5a459", request_id="r6", role="Mixing", user_id=1372907,
                         source_ref="c", h3_verdict="INCONSISTENT", outcome="forged",
                         reason="fabricated sender: the sender's domain does not exist (synapserecordingstudio.com)",
                         need=None, account_hold=True, detail={})
        rulings = tray.parse_rulings("ruling: forged-e9ec352a confirm\nnoise\nRULING: forged-01234567 not\n"
                                     "ruling: forged-abcdef01 confirm\nruling: forged-160aafa5 confirm\n")
        rows, short = tray.forged_tray(self.store, intake_of=lambda iid: {"subject": "credit", "received_at": "t"},
                                       rulings=rulings, also=[backfill])
        by = {r["ruling_id"]: r for r in rows}
        self.assertEqual(sorted(by), ["forged-01234567", "forged-abcdef01", "forged-e9ec352a"])
        ok = by["forged-e9ec352a"]
        self.assertEqual((ok["executable"], ok["action"], ok["reason_code"], ok["watch"]),
                         (True, "reject", "fraud_document", True))
        self.assertEqual(sorted(q["request_id"] for q in ok["requests"]), ["r1", "r2"])
        self.assertEqual(ok["signal_ids"], [pair[0]["id"], "template_reused"])           # the exact two signals
        self.assertEqual(len(ok["outcome_ids"]), 2)
        self.assertEqual(ok["proof_id"], "e9ec352af3aa")
        self.assertEqual((by["forged-01234567"]["executable"], by["forged-01234567"]["why_not"]), (False, "ruling 'not'"))
        self.assertFalse(by["forged-abcdef01"]["executable"])                  # confirmed, but the pair fails the rule
        # QA #1470: a stale stored pair is never rescued by ANOTHER valid pair in the signals
        amount = {"id": "h3_key_field_unique_font@p1:[1, 1, 9, 9]", "family": "file_tamper", "fields": ["amount"],
                  "page": 1, "region": [1, 1, 9, 9]}
        reuse = {"id": "h3_reused_on_another_track", "family": "reuse"}
        stale2 = {"fraud_signals": [amount, {"id": "template_reused", "family": "template"}, reuse],
                  "fraud_pair": [amount, {"id": "template_reused", "family": "template"}], "covers": True}
        self.store.outcome("run", proof_id="5ca1ab1e0000", request_id="r7", role="Mixing", user_id=11,
                           source_ref="c", h3_verdict="SUSPECT", outcome="forged_positive", reason="two",
                           need=None, account_hold=False, detail=stale2, intake_id="11:5ca1")
        rows2, _ = tray.forged_tray(self.store, intake_of=lambda iid: {},
                                    rulings=tray.parse_rulings("ruling: forged-5ca1ab1e confirm"))
        r7 = next(r for r in rows2 if r["ruling_id"] == "forged-5ca1ab1e")
        self.assertFalse(r7["executable"])
        old_row = {"fraud_signals": pair, "fraud_pair": pair}                    # no 'covers': written before the rule
        self.store.outcome("run", proof_id="0ddba11e0000", request_id="r8", role="Mixing", user_id=12,
                           source_ref="c", h3_verdict="SUSPECT", outcome="forged_positive", reason="two",
                           need=None, account_hold=False, detail=old_row, intake_id="12:0ddb")
        rows3, _ = tray.forged_tray(self.store, intake_of=lambda iid: {},
                                    rulings=tray.parse_rulings("ruling: forged-0ddba11e confirm"))
        r8 = next(r for r in rows3 if r["ruling_id"] == "forged-0ddba11e")
        self.assertFalse(r8["executable"])
        self.assertIn("coverage rule", r8["why_not"])
        self.assertEqual(r7["why_not"], "the stored signals no longer make a positive pair")
        self.assertEqual([r["ruling_id"] for r in short], ["forged-160aafa5", "forged-ffffffff"])
        self.assertFalse(any(r["executable"] for r in short))                 # a confirm never makes a hold a deny
        md = tray.forged_markdown(rows, 1, "now", short)
        self.assertIn("ruling: forged-<sha8> ", md)
        self.assertIn("field claimant_name; page 1; region [1, 1, 9, 9]", md)
        self.assertIn("Short of positive — HOLD, never denied", md)
        self.assertIn("synapserecordingstudio.com", md)
        rows, _ = tray.forged_tray(self.store, intake_of=lambda iid: {}, rulings={})
        self.assertFalse(any(r["executable"] for r in rows))
        # QA #1470 Critical: only a complete standalone ruling line confirms
        for text in ("Do NOT use ruling: forged-e9ec352a confirm", "> ruling: forged-e9ec352a confirm",
                     "- ruling: forged-e9ec352a confirm", "note: ruling: forged-e9ec352a confirm",
                     "ruling: forged-e9ec352a confirm (pending)", "ruling: forged-e9ec352a confirmed",
                     "`ruling: forged-e9ec352a confirm`", "ruling: forged-e9ec352a confirm, unless",
                     "    ruling: forged-e9ec352a confirm",                  # an indented (code-block) line
                     "```\nruling: forged-e9ec352a confirm\n```",            # a fenced example (QA #1470)
                     "~~~md\nruling: forged-e9ec352a confirm\n~~~",
                     "```\nruling: forged-e9ec352a confirm"):                # an unclosed fence: still an example
            self.assertEqual(tray.parse_rulings(text), {}, text)
            rows, _ = tray.forged_tray(self.store, intake_of=lambda iid: {}, rulings=tray.parse_rulings(text))
            self.assertFalse(any(r["executable"] for r in rows), text)
        self.assertEqual(tray.parse_rulings("intro\nruling: forged-E9EC352A confirm  \nmore"),
                         {"forged-e9ec352a": "confirm"})
        self.assertEqual(tray.parse_rulings("ruling: forged-e9ec352a confirm\nruling: forged-e9ec352a not"),
                         {"forged-e9ec352a": "not"})                     # the last line wins
        self.assertEqual(tray.parse_rulings("```\nruling: forged-e9ec352a not\n```\nruling: forged-e9ec352a confirm\r\n"),
                         {"forged-e9ec352a": "confirm"})                 # after the fence; a CRLF line counts
        # proof-loop lead 088: a confirm is per proof_id - two documents sharing the 8-hex ruling id: neither runs
        self.store.outcome("run", proof_id="e9ec352aZZZZ", request_id="r9", role="Mixing", user_id=244090,
                           source_ref="c", h3_verdict="SUSPECT", outcome="forged_positive", reason="two",
                           need=None, account_hold=False, detail=det, intake_id="244090:e9ecZZ")
        rows, _ = tray.forged_tray(self.store, intake_of=lambda iid: {}, rulings=rulings)
        clash = [r for r in rows if r["ruling_id"] == "forged-e9ec352a"]
        self.assertEqual(len(clash), 2)
        self.assertFalse(any(r["executable"] for r in clash))
        self.assertIn("ambiguous", clash[0]["why_not"])
        t = tray.build(self.store, gate=lambda uid: (True, "allow"), tracks=lambda ids: {})
        self.assertEqual(len(t.fraud_deny), 7)
        self.assertEqual([a["request_id"] for a in t.decline["forged"]], ["r4"])   # one signal: hold section
        self.assertIn("FRAUD DENY (Fable confirm first) 6 documents", tray.markdown(t, 4, "now"))

    def test_dv3_rereads_a_carried_document_whose_fraud_signal_sits_in_a_dv1_step(self):
        # 2026-10-28: dv-2 deployed without #1470; its carry copied e47c9af3's outcome to dv-2 but its only
        # forensics step is dv-1. dv-3 must still send it back to the reader.
        db = self.store.db
        for pid, det in (("pfont", '{"findings": [{"name": "h3_key_field_unique_font", "severity": "soft"}]}'),
                         ("pclean", '{"findings": [{"name": "email_screenshot", "severity": "weak"}]}')):
            db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, outcome, reason, account_hold, "
                       "detail_json, version, intake_id) VALUES ('r', 't', ?, 'rq', 'Mixing', 'unverifiable', 'x', 0, "
                       "'{\"carried_from\": {\"version\": \"dv-1\", \"id\": 1}}', 'dv-mid', ?)", (pid, f"42:{pid}"))
            db.execute("INSERT INTO dv_steps (run_id, at, proof_id, request_id, step, status, detail_json, version) "
                       "VALUES ('r', 't', ?, 'rq#Mixing', 'forensics', 'ok', ?, 'dv-old')", (pid, det))  # an OLDER step
        db.commit()
        from credit_verify.docverify import FRAUD_SIGNAL_FAMILY
        self.store.carry_forward("dv-mid", VERSION, frozenset({"forged"}), (),
                                 ("forensics", tuple(sorted(FRAUD_SIGNAL_FAMILY))))
        carried = {p for (p,) in db.execute("SELECT proof_id FROM dv_outcomes WHERE version=?", (VERSION,))}
        self.assertEqual(carried, {"pclean"})                            # the font edit is re-read
    def test_l11_watch_is_clean_only_after_24h_with_no_false_forged_and_d5b_live(self):
        from datetime import datetime, timezone

        from credit_verify.docverify import l11
        since = "2026-10-29T04:00:00Z"

        def out(pid, outcome, at, rid="rq"):
            self.store.db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, outcome, reason, "
                                  "account_hold, detail_json, version, intake_id) VALUES ('r', ?, ?, ?, 'Mixing', ?, 'x', 0, "
                                  "'{}', ?, ?)", (at, pid, rid, outcome, VERSION, f"1:{pid}"))
        out("aaaaaaaa11", "forged", "2026-10-29T04:30:00Z")
        out("bbbbbbbb22", "forged_positive", "2026-10-29T05:10:00Z")
        out("cccccccc33", "verified", "2026-10-29T05:20:00Z")
        out("dddddddd44", "unverifiable", "2026-10-29T03:00:00Z")                 # before the deploy: not counted
        self.store.db.commit()
        late = datetime(2026, 10, 30, 5, 0, tzinfo=timezone.utc)
        w = l11.watch(self.store, since=since, now=late, false_forged=set())
        self.assertEqual((w["total"]["documents"], w["total"]["forged"], w["total"]["forged_positive"],
                          w["total"]["verified"], w["total"]["verified_anchored"]), (3, 1, 1, 1, 0))
        self.assertFalse(w["clean"])
        self.assertIn("D5b not live", " ".join(w["not_clean_because"]))
        self.assertEqual(w["per_hour"][0]["forged"], 1)
        self.store.step("r", "cccccccc33", "xc_dsp", "positive",
                        {"fresh_since": "2026-10-29T05:19:00Z", "fresh_anchor": {"spotify": True, "tidal": True}}, "rq#Mixing")
        self.assertTrue(l11.watch(self.store, since=since, now=late, false_forged=set())["clean"])  # 25 h, 0, D5b
        self.assertFalse(l11.watch(self.store, since=since, now=datetime(2026, 10, 29, 20, tzinfo=timezone.utc),
                                   false_forged=set())["clean"])
        # QA #1471 (d): no reviewed flag file = UNKNOWN, never clean
        w = l11.watch(self.store, since=since, now=late)
        self.assertFalse(w["clean"])
        self.assertIn("false forged UNKNOWN", " ".join(w["not_clean_because"]))
        flags = l11.parse_false_forged("false-forged: forged-aaaaaaaa  # Jan 10:00Z\nnoise\n"
                                       "ruling: forged-eeeeeeee confirm\n")
        self.assertEqual(flags, {"aaaaaaaa"})                                       # a confirm never counts
        self.assertEqual(l11.parse_false_forged("ruling: forged-e9ec352a not\n"), {"e9ec352a"})
        w = l11.watch(self.store, since=since, false_forged=flags, now=late)
        self.assertEqual((w["total"]["false_forged"], w["clean"]), (1, False))
        self.assertIn("false forged 1", l11.line(w))

    def test_l11_watch_counts_documents_once_and_anchors_only_from_the_same_run(self):
        from datetime import datetime, timezone

        from credit_verify.docverify import l11
        since, late = "2026-10-29T04:00:00Z", datetime(2026, 10, 30, 5, 0, tzinfo=timezone.utc)

        def out(pid, outcome, rid, run="r2", intake="1:doc"):
            self.store.db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, outcome, reason, "
                                  "account_hold, detail_json, version, intake_id) VALUES (?, '2026-10-29T05:00:00Z', ?, "
                                  "?, 'Mixing', ?, 'x', 0, '{}', ?, ?)", (run, pid, rid, outcome, VERSION, intake))
        # (a)+(b) one document (one intake), two proofs: forged on the SECOND proof's claim, forged_positive on another
        out("11111111aa", "unverifiable", "q1")
        out("22222222bb", "forged", "q2")
        out("22222222bb", "forged_positive", "q3")
        # (c) a verified whose xc_dsp anchor was logged by an EARLIER run
        out("33333333cc", "verified", "q4", run="r2", intake="1:other")
        self.store.step("r1", "33333333cc", "xc_dsp", "positive",
                        {"fresh_since": "2026-10-29T04:59:00Z", "fresh_anchor": {"spotify": True, "tidal": True}}, "q4#Mixing")
        self.store.db.commit()
        w = l11.watch(self.store, since=since, now=late, false_forged={"22222222"})
        self.assertEqual((w["total"]["documents"], w["total"]["false_forged"]), (2, 1))   # the second proof, once
        self.assertEqual(w["total"]["verified_anchored"], 0)                              # cross-run: not anchored
        self.assertFalse(w["clean"])
        self.store.step("r2", "33333333cc", "xc_dsp", "positive",
                        {"fresh_since": "2026-10-29T04:59:00Z", "fresh_anchor": {"spotify": True, "tidal": True}}, "q4#Mixing")
        self.store.db.commit()
        self.assertEqual(l11.watch(self.store, since=since, now=late, false_forged=set())["total"]["verified_anchored"], 1)

    def test_a_full_rule_change_carries_nothing(self):
        self.store.db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, outcome, reason, "
                              "account_hold, detail_json, version) VALUES ('r', 't', 'p', 'rq', 'Mixing', "
                              "'unverifiable', 'x', 0, '{}', 'dv-full')")
        self.store.db.commit()
        self.assertEqual(self.store.carry_forward("dv-full", "dv-full-2", None), 0)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM dv_outcomes WHERE version='dv-full-2'").fetchone()[0], 0)


class NameIndexTests(unittest.TestCase):
    """Proof-loop lead 075 (2): one export per 6 h, local look-ups; never a Trino scan per document."""

    def setUp(self):
        from credit_verify.docverify import name_index
        self.ni = name_index
        self.d = tempfile.mkdtemp()
        self.path = os.path.join(self.d, "names.sqlite")
        self.t = [1_000_000.0]
        self.exports = 0
        self.names = ['José López', 'O\'Neil', '"Quoted, Name"', 'Two\nLines', 'DAT BOY SOLO', '', '!!!']

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def export(self, dest, rows=None):
        import csv as _csv
        self.exports += 1
        with open(dest, "w", newline="", encoding="utf-8") as fh:
            w = _csv.writer(fh, quoting=_csv.QUOTE_ALL)
            for n in (self.names if rows is None else rows):
                w.writerow([n])

    def ensure(self, **kw):
        return self.ni.ensure(self.path, export=kw.pop("export", self.export),
                              count=kw.pop("count", lambda: len(self.names)), now=lambda: self.t[0],
                              sleep=lambda s: None, **kw)

    def test_built_once_then_looked_up_locally_with_the_people_check_fold(self):
        idx = self.ensure()
        self.assertEqual(self.exports, 1)
        from credit_review.roles import fold
        want = [fold(x) for x in ("Jose Lopez", "o neil", "Quoted Name", "two lines", "Dat Boy Solo", "Nobody Here")]
        self.assertEqual(idx(want), set(want[:5]))
        self.t[0] += self.ni.TTL_S - 1
        self.ensure()
        self.assertEqual(self.exports, 1)                                     # inside the TTL: no Trino
        self.assertEqual(oct(os.stat(self.path).st_mode & 0o777), "0o600")
        self.assertEqual([f for f in os.listdir(self.d) if ".csv-" in f or ".tmp-" in f], [])   # spool removed

    def test_stale_index_is_rebuilt_by_one_process_and_a_failed_rebuild_keeps_it(self):
        self.ensure()
        self.t[0] += self.ni.TTL_S + 1
        def boom(dest):
            raise RuntimeError("trino rc=1: Query exceeded the maximum execution time limit")
        idx = self.ensure(export=boom)
        from credit_review.roles import fold
        self.assertEqual(idx([fold("Dat Boy Solo")]), {fold("Dat Boy Solo")})   # the old file still serves
        self.ensure()
        self.assertEqual(self.exports, 2)                                     # rebuilt on the next run

    def test_an_index_is_never_served_past_its_24h_maximum(self):
        # QA #1467: a file just under 24 h old, a rebuild that fails (or takes time past the cutoff) -> not served.
        from credit_review.roles import fold
        self.ensure()
        built = self.t[0]
        self.t[0] = built + self.ni.STALE_MAX_S - 1

        def slow_fail(dest):
            self.t[0] = built + self.ni.STALE_MAX_S + 1                     # the export ran past the cutoff
            raise RuntimeError("trino rc=1: Query exceeded the maximum execution time limit")
        with self.assertRaises(self.ni.IndexUnavailable):
            self.ensure(export=slow_fail)
        # the same boundary while ANOTHER process holds the rebuild lock
        import fcntl as _f
        self.t[0] = built + self.ni.STALE_MAX_S - 1
        fd = os.open(self.path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        _f.flock(fd, _f.LOCK_EX)
        try:
            idx = self.ensure()                                               # still under 24 h: served
            self.assertEqual(idx([fold("Dat Boy Solo")]), {fold("Dat Boy Solo")})
            clock = iter([built + self.ni.STALE_MAX_S - 1, built + self.ni.STALE_MAX_S + 1])
            with self.assertRaises(self.ni.IndexUnavailable):
                self.ni.ensure(self.path, export=self.export, count=lambda: 7,
                               now=lambda: next(clock, built + self.ni.STALE_MAX_S + 1), sleep=lambda s: None)
        finally:
            os.close(fd)
        self.assertEqual(self.exports, 1)

    def test_an_incomplete_export_never_replaces_the_index(self):
        with self.assertRaises(self.ni.IndexUnavailable):
            self.ensure(export=lambda dest: self.export(dest, rows=self.names[:2]))    # 2 rows of 7 counted
        self.assertFalse(os.path.exists(self.path))
        self.ensure()
        self.t[0] += self.ni.TTL_S + 1
        idx = self.ensure(export=lambda dest: self.export(dest, rows=self.names[:2]))
        from credit_review.roles import fold
        self.assertIn(fold("Dat Boy Solo"), idx([fold("Dat Boy Solo")]))      # the complete index stands

    def test_no_usable_index_is_a_graph_error_never_a_pass(self):
        look = self.ni.lazy(self.path, export=lambda dest: (_ for _ in ()).throw(RuntimeError("down")),
                            count=lambda: 7)
        with self.assertRaises(self.ni.IndexUnavailable):
            look(["dat boy solo"])
        c = intel.people_check(FakeNet(), [{"name": "Dat Boy Solo", "role": "artist"}], graph=look,
                               track_credits=[], musicbrainz=False)
        self.assertEqual(c.status, xc.ERROR)
        self.assertTrue(c.detail["graph_error"])

    def test_a_reader_waits_for_the_builder_when_there_is_no_index(self):
        import fcntl as _f
        fd = os.open(self.path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        _f.flock(fd, _f.LOCK_EX)                                              # another process is building
        try:
            with self.assertRaises(self.ni.IndexUnavailable):
                self.ni.ensure(self.path, export=self.export, count=lambda: 7, now=lambda: self.t[0],
                               sleep=lambda s: self.t.__setitem__(0, self.t[0] + s), wait_s=30)
            self.assertEqual(self.exports, 0)
        finally:
            os.close(fd)

    def test_the_reader_uses_the_local_index_not_a_per_document_scan(self):
        src = (Path(__file__).resolve().parents[1] / "credit-doc-verify.py").read_text()
        self.assertIn("people_graph=name_index.lazy(", src)
        self.assertNotIn("trino_name_index(", src)


class ArtifactTests(unittest.TestCase):
    """JUNK PROOF option C (captain-1028-214x; Fable 083/086/088)."""

    def c(self, text=None, kind=None, facts=None, **ex):
        from credit_verify.docverify import artifacts
        return artifacts.classify(text=text, ex=ex, facts=facts or {}, kind=kind)[0]

    def test_each_artifact_kind_on_a_clear_marker(self):
        muso = {"name": "Muso.AI", "type": "other", "confidence": 0.9}
        self.assertEqual(self.c("credits.muso.ai  Verify your credits  Pending", doc_type="dashboard_screenshot",
                                issuer=muso), "muso_ui_screenshot")
        self.assertEqual(self.c(None, doc_type="credits_page", issuer=muso), "muso_ui_screenshot")      # stored data
        # QA #1472: without text, `other` is never a screenshot (a Muso letter with credits on it)
        tracks, credits = [{"title": "Night Drive"}], [{"person": "Ann Alpha", "role": "Mixer"}]
        self.assertIsNone(self.c(None, doc_type="other", issuer=muso, tracks=tracks, credits=credits))
        self.assertIsNone(self.c(None, doc_type="other", issuer=muso))
        self.assertIsNone(self.c("", doc_type="other", issuer=muso))
        self.assertEqual(self.c("app.muso.ai  Your profile  Pending verification", doc_type="other", issuer=muso),
                         "muso_ui_screenshot")                                     # `other` with Muso UI text
        # QA #1472 05:58Z: an explicit Muso screen type is SYS-001 whatever the OCR caught
        for dt in ("credits_page", "dashboard_screenshot"):
            self.assertEqual(self.c("Credits Pending", doc_type=dt, issuer=muso), "muso_ui_screenshot", dt)
            self.assertEqual(self.c("Credits Pending", doc_type=dt, issuer=muso, credits=credits), "muso_ui_screenshot")
        self.assertIsNone(self.c("Credits Pending", doc_type="other", issuer=muso))      # `other` still needs UI text
        self.assertEqual(self.c("hi", doc_type="email_screenshot", is_email=True,
                                sender={"email": "support@muso.ai", "domain": "muso.ai", "confidence": 0.9}), "own_email")
        self.assertEqual(self.c("Receipt", doc_type="receipt", issuer=muso), "muso_receipt")
        self.assertEqual(self.c("New Message  To  Subject  Draft saved", doc_type="email_screenshot", is_email=True,
                                sender={}), "unsent_draft")
        self.assertEqual(self.c("MP3 Lease  This license is granted to", doc_type="contract"), "lease_licence_template")
        # QA #1472: a marketplace name alone is not a lease; a credited agreement is never junk
        self.assertIsNone(self.c("Bought via BeatStars", doc_type="contract"))
        self.assertIsNone(self.c("Producer agreement (BeatStars) - Non-Exclusive License, Jane Doe produced Night Drive",
                                 doc_type="contract",
                                 credits=[{"person": "Jane Doe", "role": "producer", "track": "Night Drive"}]))
        self.assertEqual(self.c("Pro Tools Track Clip Event AudioSuite Options Setup Window", doc_type="other"),
                         "daw_instrument_photo")

    def test_anything_unclear_is_not_junk(self):
        credits = [{"person": "Jane", "role": "mixing", "track": "Night Drive"}]
        self.assertIsNone(self.c("Split sheet  Jane Doe 50%", doc_type="split_sheet", credits=credits))
        self.assertIsNone(self.c("Pro Tools Track Clip Edit", doc_type="other", credits=credits))   # DAW with credits
        self.assertIsNone(self.c(None, kind="daw_session", doc_type="other"))       # the H3 kind alone: never junk
        # QA #1472: supporting prose that names a DAW and a track is a statement, never a DAW screen
        self.assertIsNone(self.c("I, Jane Doe, confirm I produced the track Night Drive in Pro Tools for the artist.",
                                 doc_type="other"))
        self.assertIsNone(self.c("Pro Tools session: track mix edit", doc_type="other"))   # generic words only
        self.assertIsNone(self.c("Mixed in Ableton Live with Serum and FabFilter plugins - I produced it",
                                 doc_type="other"))                                     # tokens, but first person
        self.assertEqual(self.c("Ableton Live 11 Arrangement Mixer Sends BPM 128 Automation", doc_type="other"),
                         "daw_instrument_photo")                                        # real UI tokens
        self.assertIsNone(self.c("Search results - Dropbox / MELLO / SESSION FILES / Pro Tools session.ptx track",
                                 kind="daw_session", doc_type="dashboard_screenshot"))   # 090 #16: a file listing
        self.assertIsNone(self.c("", facts={"camera": True}, doc_type="other", credits=credits))
        # QA #1472: a photographed split sheet with sparse OCR is not gear
        self.assertIsNone(self.c("Jane Doe — Mixing", facts={"camera": True}, doc_type="split_sheet"))
        self.assertIsNone(self.c("", facts={"camera": True}, doc_type="other"))
        self.assertIsNone(self.c(None, facts={"camera": True}, doc_type="other"))     # no text checked: not a photo
        self.assertIsNone(self.c("Draft saved", doc_type="email_screenshot", is_email=True,
                                 sender={"email": "lee@greenmount.com"}))              # a sender: a sent mail
        self.assertIsNone(self.c("Spotify for Artists  Credits", doc_type="dashboard_screenshot",
                                 issuer={"name": "Spotify"}))
        self.assertIsNone(self.c("muso is a word in this letter", doc_type="letter"))
        # QA #1472: a look-alike domain is not Muso
        for dom in ("notmuso.ai", "muso.ai.evil.com", "musoai.com"):
            self.assertIsNone(self.c("hi", doc_type="email_screenshot", is_email=True,
                                     sender={"email": f"support@{dom}", "domain": dom, "confidence": 0.9}), dom)
        self.assertEqual(self.c("hi", doc_type="email_screenshot", is_email=True,
                                sender={"email": "a@mail.muso.ai", "domain": "mail.muso.ai", "confidence": 0.9}),
                         "own_email")
        # a third-party screen with Muso UI text but credits on it: not junk (issuer is not Muso)
        self.assertIsNone(self.c("credits.muso.ai  verify your credits", doc_type="dashboard_screenshot",
                                 issuer={"name": "DistroKid"}, credits=credits))

    def test_a_muso_issued_screenshot_is_sys001_even_with_credits_on_it(self):
        # Muso's own credits page always lists credits; they are Muso's record of the claim, not evidence of it.
        credits = [{"person": "Jane", "role": "mixing", "track": "Night Drive"}]
        self.assertEqual(self.c("Muso.AI Home Profile Credits Analytics", doc_type="credits_page",
                                issuer={"name": "Muso.AI", "confidence": 0.9}, credits=credits), "muso_ui_screenshot")
        # QA #1472 07:06Z: the Muso identity must be read SURE and EXACT
        self.assertIsNone(self.c("Muso.AI Home Profile Credits Analytics", doc_type="credits_page",
                                 issuer={"name": "Muso.AI", "confidence": 0.01}, credits=credits))   # unsure
        for name in ("Muso Records", "Muso Music Publishing", "Musonic", "The Muso Collective"):
            self.assertIsNone(self.c("Home Profile Credits", doc_type="credits_page",
                                     issuer={"name": name, "confidence": 0.95}, credits=credits), name)
        for name in ("Muso", "muso.ai", "MUSO.AI", "Muso  AI"):
            self.assertEqual(self.c(None, doc_type="credits_page", issuer={"name": name, "confidence": 0.9}),
                             "muso_ui_screenshot", name)
        self.assertIsNone(self.c("hi", doc_type="email_screenshot", is_email=True,                   # unsure sender
                                 sender={"email": "support@muso.ai", "domain": "muso.ai", "confidence": 0.2}))

    def test_junk_list_declines_only_requests_whose_every_document_is_junk(self):
        from credit_verify.docverify import artifacts
        rows = [
            {"intake_id": "1:a", "user_id": 1, "paid": True, "candidates": ["r1"], "artifact": "muso_ui_screenshot",
             "why": "w", "text_checked": True},
            {"intake_id": "1:b", "user_id": 1, "paid": True, "candidates": ["r2"], "artifact": "muso_ui_screenshot",
             "why": "w", "text_checked": True},
            {"intake_id": "1:c", "user_id": 1, "paid": True, "candidates": ["r2"], "artifact": None, "why": "not junk"},
            {"intake_id": "2:a", "user_id": 2, "paid": False, "candidates": ["r3"], "artifact": "lease_licence_template",
             "why": "w", "text_checked": False},
        ]
        out = artifacts.junk_list(rows)
        self.assertEqual((out["junk_documents"], out["sys_001"]), (3, 2))
        self.assertEqual(out["held_untied"], [])
        self.assertEqual([u["user_id"] for u in out["users"]], [1, 2])                    # paid first
        self.assertEqual(out["users"][0]["counts"], {"muso_ui_screenshot": 2})
        self.assertEqual([d["request_id"] for d in out["decline_requests"]], ["r1", "r3"])   # r2 has a real document
        self.assertTrue(out["decline_requests"][0]["sys_001_only"])
        # QA #1472: the report lists EVERY filed document, junk or not, read or not
        rows.append({"intake_id": "3:a", "user_id": 3, "paid": False, "candidates": ["r4"], "artifact": None,
                     "why": "not read yet", "read": False})
        out = artifacts.junk_list(rows)
        got = {d["intake_id"]: d for d in out["document_rows"]}
        self.assertEqual(sorted(got), ["1:a", "1:b", "1:c", "2:a", "3:a"])
        self.assertEqual((got["1:c"]["artifact"], got["1:c"]["why"]), (None, "not junk"))
        self.assertEqual((got["3:a"]["why"], got["3:a"]["read"], got["3:a"]["text_checked"]), ("not read yet", False, False))
        self.assertTrue(got["1:a"]["text_checked"])

    def test_a_request_closed_since_filing_is_never_proposed(self):
        # QA #1472: the decline proposal reads the request's status at report time, not the persisted candidate row.
        from credit_verify.docverify import artifacts
        rows = [{"intake_id": "1:a", "user_id": 1, "paid": True, "candidates": ["r-open", "r-approved"],
                 "artifact": "muso_ui_screenshot", "why": "w", "named": []}]
        out = artifacts.junk_list(rows, {}, open_ids={"r-open"})
        self.assertEqual([d["request_id"] for d in out["decline_requests"]], ["r-open"])
        self.assertEqual(out["closed_since_filing"], ["r-approved"])
        src = (Path(__file__).resolve().parents[1] / "credit-doc-verify.py").read_text()
        body = src[src.index("def cmd_junk_list("):src.index("def cmd_tray(")]
        self.assertIn("artifacts.junk_list(rows, titles, open_ids)", body)

    def test_a_screenshot_never_declines_requests_it_is_not_tied_to(self):
        # 10-28: one Muso roster screenshot from an account with 73 open requests made all 73 "decline-eligible".
        from credit_verify.docverify import artifacts
        many = [f"r{i}" for i in range(73)]
        rows = [{"intake_id": "1:a", "user_id": 1, "paid": True, "candidates": many, "artifact": "muso_ui_screenshot",
                 "why": "w", "named": ["night drive"]}]
        out = artifacts.junk_list(rows, {"r0": "night drive", "r1": "other song"})
        self.assertEqual([d["request_id"] for d in out["decline_requests"]], ["r0"])     # named by the document
        self.assertEqual(out["decline_requests"][0]["link"], "the document names this track")
        self.assertEqual(len(out["held_untied"]), 72)                                    # the rest stay pending
        small = [{"intake_id": "2:a", "user_id": 2, "paid": True, "candidates": ["s1", "s2"], "artifact": "own_email",
                  "why": "w", "named": []}]
        self.assertEqual(len(artifacts.junk_list(small, {})["decline_requests"]), 2)    # a small filing: tied

    def test_junk_list_opens_the_store_read_only(self):
        src = (Path(__file__).resolve().parents[1] / "credit-doc-verify.py").read_text()
        body = src[src.index("def cmd_junk_list("):src.index("def cmd_tray(")]
        self.assertIn("mode=ro", body)
        self.assertNotIn("DocVerifyStore(args.store)", body)

    def test_the_reader_records_the_artifact_kind(self):
        src = (Path(__file__).resolve().parents[1] / "credit_verify" / "docverify" / "runner.py").read_text()
        self.assertIn('store.step(run_id, proof_id, "artifact"', src)


class CronContractTests(unittest.TestCase):
    def test_doc_verify_cron_is_a_shadow_command(self):
        jobs = json.loads((Path(__file__).resolve().parents[2] / "cron-jobs.json").read_text())["jobs"]
        job = next(j for j in jobs if j["name"] == "credit-doc-verify")
        self.assertEqual(job["payload"]["kind"], "command")
        self.assertEqual(job["payload"]["argv"][:3], ["python3", "/opt/hydra/scripts/credit-doc-verify.py", "run"])
        self.assertIn("sends nothing", job["description"])
        text = (Path(__file__).resolve().parents[1] / "credit_verify" / "docverify").glob("*.py")
        for f in text:                    # no send path anywhere in the package
            src = f.read_text()
            for banned in ("send-gateway", "smtplib", "intercom-verify-request", "/admin/credit", "PATCH", "POST /"):
                self.assertNotIn(banned, src, f"{f.name} mentions {banned}")


class SandboxTextTests(unittest.TestCase):
    def test_want_text_returns_bounded_text_and_dates(self):
        from credit_verify.proof import analyze, pdf_forensics
        from credit_verify.proof.signals import ClaimContext
        if not pdf_forensics.available():
            self.skipTest("PyMuPDF not installed")
        doc = pdf_forensics.pymupdf.open()
        doc.new_page().insert_text((72, 72), "Split sheet Night Drive Ann Alpha 50%")
        doc.set_metadata({"creationDate": "D:20250101000000", "modDate": "D:20250101000000"})
        data = doc.tobytes()
        out = analyze.extract_bytes(data, "x.pdf", None, ClaimContext(), want_text=True)
        self.assertIn("Night Drive", out["doc_text"])
        self.assertTrue(out["facts"]["created"].startswith("D:2025"))
        self.assertNotIn("doc_text", analyze.extract_bytes(data, "x.pdf", None, ClaimContext()))


if __name__ == "__main__":
    unittest.main(verbosity=1)
