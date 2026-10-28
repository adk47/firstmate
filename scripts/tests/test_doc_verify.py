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
import sqlite3
import sys
import tempfile
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
            ex = Extractor(store, key="k", post=lambda *a: (calls.append(1), bad)[1]).extract("text", {}, "q")
            self.assertEqual((ex.ok, ex.degraded, ex.error, len(calls)), (False, True, "unusable model answer", 2))

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
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=validate(GOOD_ANSWER), findings=[],
                        checks=checks(xc_dsp=xc.POSITIVE, xc_people=xc.WEAK), account_held=False)
        self.assertEqual(o.outcome, gate.VERIFIED)
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=validate(GOOD_ANSWER), findings=[],
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
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=validate(GOOD_ANSWER), findings=[],
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

    def decide(self, h3="GENUINE", ex=None, findings=(), held=False, **st):
        return gate.decide(h3_verdict=h3, kind="contract", ex=ex or self.good_ex, findings=list(findings),
                           checks=checks(**st), account_held=held)

    def test_verified_needs_everything(self):
        o = self.decide(xc_dsp=xc.POSITIVE, xc_domain=xc.POSITIVE, xc_label=xc.POSITIVE)
        self.assertEqual(o.outcome, gate.VERIFIED)
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
        self.assertEqual(self.decide(findings=weak, xc_isrc=xc.POSITIVE).outcome, gate.VERIFIED)

    def test_forged_and_contradicted_hold_the_account(self):
        o = self.decide(findings=[forensics.Finding("h3_forged", forensics.HARD)], xc_dsp=xc.POSITIVE)
        self.assertEqual((o.outcome, o.account_hold), (gate.FORGED, True))
        # R-C6 (proof-loop lead 073): a fabricated sender forges only with confidence >= 0.8 + a second signal.
        def dom(conf):
            return xc.Check("xc_domain", xc.CONTRADICTS, {"sender_domain": "ghost-label.com", "confidence": conf,
                                                          "note": "the sender's domain does not exist"})
        base = [c for c in checks(xc_dsp=xc.POSITIVE) if c.step != "xc_domain"]
        o = gate.decide(h3_verdict="INCONSISTENT", kind="contract", ex=self.good_ex, findings=[],
                        checks=base + [dom(0.95)], account_held=False)
        self.assertEqual((o.outcome, o.account_hold), (gate.FORGED, True))
        self.assertIn("fabricated sender", o.reason)
        self.assertIn("second signal: H3 INCONSISTENT", o.reason)
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=self.good_ex, findings=[],
                        checks=base + [dom(0.95)], account_held=False)              # one signal only
        self.assertEqual((o.outcome, o.account_hold), (gate.UNVERIFIABLE, False))   # not forged, not verified
        self.assertEqual(o.detail["would_forge"]["why_not"], "no second signal (R-C6)")
        self.assertIn("sender doubt", o.reason)
        o = gate.decide(h3_verdict="INCONSISTENT", kind="contract", ex=self.good_ex, findings=[],
                        checks=base + [dom(0.7)], account_held=False)               # below 0.8
        self.assertEqual((o.outcome, o.account_hold), (gate.UNVERIFIABLE, False))
        o = gate.decide(h3_verdict="GENUINE", kind="contract", ex=self.good_ex,
                        findings=[forensics.Finding("editor_software_on_screenshot", forensics.SOFT)],
                        checks=base + [dom(0.9)], account_held=False)               # forensic doubt = second signal
        self.assertEqual(o.outcome, gate.FORGED)
        o = self.decide(xc_dsp=xc.CONTRADICTS)
        self.assertEqual((o.outcome, o.account_hold), (gate.CONTRADICTED, True))

    def test_an_unreadable_sender_address_asks_for_a_readable_copy(self):
        unreadable = xc.Check("xc_domain", xc.WEAK, {"sender_domain": "michaelosbome.ora", "unreadable": True,
                                                     "note": "sender address unreadable"})
        base = [c for c in checks() if c.step != "xc_domain"]
        o = gate.decide(h3_verdict="SUSPECT", kind="letter", ex=validate({**GOOD_ANSWER, "doc_type": "letter"}),
                        findings=[], checks=base + [unreadable], account_held=False)
        self.assertEqual((o.outcome, o.need, o.account_hold), (gate.UNVERIFIABLE, gate.NEED_READABLE, False))

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
