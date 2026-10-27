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
import urllib.error
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_verify.docverify import VERSION, crosscheck as xc, forensics, gate, runner  # noqa: E402
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
    def __init__(self, *, mx="mx", mb=None, deezer=None, pages=None):
        self._mx, self._mbmap, self._deezer, self._pages = mx, mb or {}, deezer or {}, pages or {}
        self.calls: list[str] = []

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
        self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), "bluefern.zz", "Blue Fern", [], "x").status,
                         xc.CONTRADICTS)
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
        self.assertEqual(xc.domain_check(FakeNet(mx="nxdomain"), "mistyped.invalid", "Blue Fern", [], "x",
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
        o = self.decide(xc_dsp=xc.POSITIVE, xc_domain=xc.CONTRADICTS)
        self.assertEqual(o.outcome, gate.FORGED)
        self.assertIn("fabricated sender", o.reason)
        o = self.decide(xc_dsp=xc.CONTRADICTS)
        self.assertEqual((o.outcome, o.account_hold), (gate.CONTRADICTED, True))

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
        for s in ("locate", "text", "extract", "xc_domain", "xc_signatory", "forensics", "xc_dsp", "xc_isrc",
                  "xc_label", "gate"):
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
