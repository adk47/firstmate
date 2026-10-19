#!/usr/bin/env python3
"""Tests for scripts/credit_verify/proof (H3 supporting-document forensics).

Synthetic forgeries are built in the test itself (no customer documents):
an AI-generated "dashboard" PNG with a generator tag and a C2PA manifest, a
split sheet edited after creation, an overlay on a key field, a document
changed after it was signed, a document reused by another account, and the
clean counterparts of each. OCR is faked deterministically unless a test
says otherwise (CI on node-8 also runs the real tesseract path).
    python3 scripts/tests/test_credit_proof.py
"""

from __future__ import annotations

import base64
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_verify.proof import (analyze, content, fingerprint, image_forensics, image_meta, ocr,  # noqa: E402
                                 pdf_forensics, sandbox, verdict)
from credit_verify.proof.pipeline import analyze_proof  # noqa: E402
from credit_verify.proof.signals import ClaimContext, Extracted, Signal  # noqa: E402
from credit_verify.proof.sniff import sniff  # noqa: E402
from credit_verify.proof.store import ProofStore  # noqa: E402

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None
HAVE_PDF = pdf_forensics.available()

CTX = ClaimContext(request_ids=["r1"], track_title="Night Drive", track_artists=["Small Act"],
                   isrcs=["USABC2400001"], claimed_roles=["Producer"], claimant_names=["Real Producer"],
                   lifetime_streams=50_000, track_key="t-1")
SPLIT = ("SPLIT SHEET\nSong Title: Night Drive\nISRC: USABC2400001\nArtist: Small Act\n"
         "Writer: Real Producer  share 50%\nWriter: Jane Writer  share 50%\n"
         "Signed by all parties on 2024-03-01. This agreement records the composition ownership split.")


def words_for(text: str, page: int = 1) -> list[dict]:
    out = []
    for li, line in enumerate(text.splitlines()):
        for wi, w in enumerate(line.split()):
            out.append({"text": w, "page": page, "conf": 95.0, "box": [10 + 40 * wi, 10 + 14 * li, 48 + 40 * wi, 22 + 14 * li],
                        "line": ("1", "1", str(li))})
    return out


class FakeOcr:
    """Returns words for whatever text the test says each call shows."""

    def __init__(self, texts: list[str]):
        self.texts = list(texts)

    def __call__(self, png: bytes, *, page: int = 1, scale: float = 1.0):
        t = self.texts.pop(0) if len(self.texts) > 1 else (self.texts[0] if self.texts else "")
        return words_for(t, page)


def png_bytes(color=(240, 240, 240), size=(320, 640), text_chunks=None, extra_chunks=None, draw=None) -> bytes:
    im = Image.new("RGB", size, color)
    if draw:
        from PIL import ImageDraw
        d = ImageDraw.Draw(im)
        for (x, y, w, h, c) in draw:
            d.rectangle([x, y, x + w, y + h], fill=c)
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    data = buf.getvalue()
    chunks = []
    for k, v in (text_chunks or {}).items():
        chunks.append((b"tEXt", k.encode("latin-1") + b"\0" + v.encode("latin-1")))
    chunks += extra_chunks or []
    if not chunks:
        return data
    iend = data.rfind(b"IEND") - 4
    body = b"".join(struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xFFFFFFFF)
                    for t, c in chunks)
    return data[:iend] + body + data[iend:]


def page_shot(shade: int) -> bytes:
    """A screenshot of one fixed page layout; `shade` changes the bytes only."""
    return png_bytes(color=(shade, shade, shade), draw=[(10, 10, 300, 40, (30, 30, 30)), (10, 100, 120, 300, (200, 30, 30))])


def pdf_bytes(text: str, font: str = "helv", size: float = 11, step: float = 16) -> bytes:
    doc = pdf_forensics.pymupdf.open()
    page = doc.new_page()
    y = 72
    for line in text.splitlines():
        page.insert_text((72, y), line, fontname=font, fontsize=size)
        y += step
    out = doc.tobytes()
    doc.close()
    return out


def incremental(data: bytes, edit) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "x.pdf")
        Path(p).write_bytes(data)
        doc = pdf_forensics.pymupdf.open(p)
        edit(doc)
        doc.saveIncr()
        doc.close()
        return Path(p).read_bytes()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = ProofStore(os.path.join(self.tmp.name, "proof.sqlite"))

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def write(self, name: str, data: bytes) -> str:
        p = os.path.join(self.tmp.name, name)
        Path(p).write_bytes(data)
        return p

    def run_claims(self, name, data, *, contact="c1", ctx=CTX, ocr_texts=None):
        path = self.write(name, data)
        fake = FakeOcr(ocr_texts if ocr_texts is not None else [""])
        with mock.patch.object(ocr, "ocr_image_bytes", fake):
            return analyze_proof(self.store, path, contact_h=contact, source="test", source_ref=name, ctx=ctx,
                                 runner=lambda p, d, c: analyze.extract(p, d, ClaimContext.from_dict(c)))

    def run_proof(self, name, data, **kw):
        [res] = self.run_claims(name, data, **kw)
        return res

    def names(self, res):
        return {s.name for s in res.signals}


@unittest.skipUnless(Image, "Pillow required")
class ImageTests(Base):
    def test_ai_generated_dashboard_png_is_forged_likely(self):
        manifest = (b"\0\0\0\x40jumb\0\0\0\x18jumdc2pa\0" + b"c2pa.actions digitalSourceType "
                    b"http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia OpenAI gpt-image")
        data = png_bytes(text_chunks={"Software": "gpt-image 2.0"}, extra_chunks=[(b"caBX", manifest)])
        res = self.run_proof("dk.png", data, ocr_texts=["DistroKid Upload My Music Stats Splits Bank Night Drive"])
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY)
        self.assertTrue({"ai_generator_software", "c2pa_ai_source"} <= self.names(res))
        c2pa = next(s for s in res.signals if s.name == "c2pa_ai_source")
        self.assertTrue(c2pa.evidence.byte_range)                 # cited bytes

    def test_plain_screenshot_without_exif_is_never_flagged(self):
        res = self.run_proof("ss.png", png_bytes(), ctx=ClaimContext(),
                             ocr_texts=["Spotify for Artists Home Music Audience Night Drive Streams 12,000"])
        self.assertEqual(res.verdict, verdict.CLEAN_UNLINKED)
        self.assertIn("no_camera_exif", self.names(res))

    def test_photoshop_history_on_screenshot_is_suspect_not_forged(self):
        xmp = ('<x:xmpmeta><rdf:RDF><xmp:CreatorTool>Adobe Photoshop CS6</xmp:CreatorTool>'
               '<stEvt:action>saved</stEvt:action><stEvt:action>derived</stEvt:action></rdf:RDF></x:xmpmeta>')
        data = png_bytes(extra_chunks=[(b"iTXt", b"XML:com.adobe.xmp\0\0\0\0\0" + xmp.encode())])
        res = self.run_proof("ps.png", data, ctx=ClaimContext(), ocr_texts=["YouTube comments"])
        self.assertEqual(res.verdict, verdict.SUSPECT)
        self.assertTrue({"editor_software_on_screenshot", "xmp_edit_history_on_screenshot"} & self.names(res))

    def test_artist_level_dashboard_is_compared_with_the_artists_total(self):
        shot = "Spotify for Artists Home Music Audience Small Act Streams 9,400,000 Listeners"
        big_artist = ClaimContext(**{**CTX.as_dict(), "artist_lifetime_streams": 40_000_000})
        res = self.run_proof("s4a-ok.png", png_bytes(), ctx=big_artist, ocr_texts=[shot])
        self.assertNotIn("dsp_numbers_exceed_catalog", self.names(res))
        self.assertNotEqual(res.verdict, verdict.INCONSISTENT)
        small_artist = ClaimContext(**{**CTX.as_dict(), "artist_lifetime_streams": 1_000_000})
        res = self.run_proof("s4a-big.png", png_bytes(color=(250, 250, 250)), ctx=small_artist, ocr_texts=[shot])
        self.assertEqual(res.verdict, verdict.INCONSISTENT)
        sig = next(s for s in res.signals if s.name == "dsp_numbers_exceed_catalog")
        self.assertIn("this artist's total streams", sig.reason)
        self.assertEqual(sig.value["catalog_lifetime"], 1_000_000)

    def test_track_page_numbers_above_the_tracks_streams_are_inconsistent(self):
        res = self.run_proof("am4a.png", png_bytes(), ocr_texts=[
            "Apple Music for Artists Song Night Drive Small Act Plays 9,400,000 Listeners"])
        self.assertEqual(res.verdict, verdict.INCONSISTENT)
        sig = next(s for s in res.signals if s.name == "dsp_numbers_exceed_catalog")
        self.assertIn("this track's total streams", sig.reason)
        self.assertEqual(sig.evidence.page, 1)                    # cites the number on the screenshot
        self.assertEqual(sig.evidence.region, fake_box("Apple Music for Artists Song Night Drive Small Act Plays "
                                                       "9,400,000 Listeners", "9,400,000"))

    def test_dashboard_of_unknown_scope_is_not_compared(self):
        res = self.run_proof("mixed.png", png_bytes(), ocr_texts=[
            "Spotify for Artists Home Audience Song Night Drive Small Act Streams 9,400,000"])
        self.assertNotIn("dsp_numbers_exceed_catalog", self.names(res))
        self.assertIn("dsp_number_scope_unknown", self.names(res))
        self.assertNotEqual(res.verdict, verdict.INCONSISTENT)
        no_total = ClaimContext(**{**CTX.as_dict(), "lifetime_streams": None})
        res = self.run_proof("am4a2.png", png_bytes(color=(250, 250, 250)), ctx=no_total, ocr_texts=[
            "Apple Music for Artists Song Night Drive Small Act Plays 9,400,000 Listeners"])
        self.assertIn("dsp_number_scope_unknown", self.names(res))
        self.assertNotIn("dsp_numbers_exceed_catalog", self.names(res))

    def test_perceptual_hash_that_cannot_run_is_an_error(self):
        with mock.patch.object(fingerprint, "phash64", side_effect=ImportError("numpy missing")):
            res = self.run_proof("nohash.png", png_bytes(), ctx=ClaimContext(), ocr_texts=["hello"])
        self.assertIn("phash_unavailable", self.names(res))
        self.assertEqual(res.verdict, verdict.UNDETERMINED)

    def test_copy_move_that_cannot_run_is_an_error_not_a_pass(self):
        with mock.patch.dict(sys.modules, {"cv2": None}):
            sig = image_forensics.copy_move(png_bytes(), "photo.jpg")
        self.assertEqual([(s.name, s.severity) for s in sig], [("copy_move_unavailable", "error")])
        self.assertEqual(verdict.decide(sig + [Signal("F5a", "isrc_matches_claim", "positive")], CTX)[0],
                         verdict.UNDETERMINED)
        bad = image_forensics.copy_move(b"not an image", "photo.jpg")
        self.assertEqual([s.severity for s in bad], ["error"])

    def test_error_level_analysis_that_cannot_decode_is_an_error(self):
        sig = image_forensics.ela(b"\xff\xd8\xff broken", "x.jpg", words_for("50% share"))
        self.assertEqual([(s.name, s.severity) for s in sig], [("ela_failed", "error")])

    @unittest.skipUnless(shutil.which("exiftool"), "exiftool not installed")
    def test_exiftool_reads_the_bytes_it_is_given_not_the_host_path(self):
        im = Image.new("RGB", (64, 64), (200, 200, 200))
        exif = Image.Exif()
        exif[0x0131] = "Canva"
        buf = io.BytesIO()
        im.save(buf, format="JPEG", exif=exif)
        label = os.path.join(self.tmp.name, "hidden", "shot.jpg")   # never exists, like /root in the sandbox
        self.assertEqual(image_meta.exiftool_fields(buf.getvalue()).get("IFD0:Software"), "Canva")
        sig, facts = image_meta.analyze(buf.getvalue(), label, "image/jpeg")
        self.assertNotIn("exiftool_failed", {s.name for s in sig})
        self.assertTrue(facts["exiftool"])
        self.assertEqual([s.evidence.file for s in sig if s.name == "editor_software_on_screenshot"], [label])

    def test_exiftool_that_fails_is_an_error_not_a_pass(self):
        fake = self.write("exiftool", b"#!/bin/sh\nexit 2\n")
        os.chmod(fake, 0o755)
        with mock.patch.object(shutil, "which", lambda exe: fake if exe == "exiftool" else None):
            sig = image_meta.analyze(png_bytes(), "x.png", "image/png")[0]
        self.assertIn(("exiftool_failed", "error"), {(s.name, s.severity) for s in sig})
        self.assertEqual(verdict.decide(sig, CTX)[0], verdict.UNDETERMINED)

    def test_polyglot_png_is_rejected(self):
        data = png_bytes() + b"%PDF-1.7\n1 0 obj<</JavaScript (x)>>endobj"
        sn = sniff(data, "x.png")
        self.assertTrue(sn.rejected)


@unittest.skipUnless(HAVE_PDF, "PyMuPDF required")
class PdfTests(Base):
    def test_clean_split_sheet_linked_to_the_claim_is_genuine(self):
        res = self.run_proof("split.pdf", pdf_bytes(SPLIT), ocr_texts=[SPLIT])
        self.assertEqual(res.verdict, verdict.GENUINE, res.reasons)
        self.assertTrue({"isrc_matches_claim", "claimant_named", "title_matches_claim"} <= self.names(res))

    def test_presence_signals_cite_page_and_region_absence_signals_the_whole_document(self):
        data = pdf_bytes(SPLIT)
        res = self.run_proof("cited.pdf", data, ocr_texts=[SPLIT])
        doc = pdf_forensics.pymupdf.open(stream=data, filetype="pdf")
        try:
            for name, token in (("isrc_matches_claim", "USABC2400001"), ("claimant_named", "Real Producer"),
                                ("title_matches_claim", "Night Drive")):
                sig = next(s for s in res.signals if s.name == name)
                self.assertEqual(sig.evidence.page, 1, name)
                r = doc[0].search_for(token)[0]
                x0, y0, x1, y1 = sig.evidence.region
                self.assertTrue(x0 <= r.x0 + 1 and y0 <= r.y0 + 1 and x1 >= r.x1 - 1 and y1 >= r.y1 - 1,
                                (name, sig.evidence.region, r))
        finally:
            doc.close()
        stranger = ClaimContext(**{**CTX.as_dict(), "claimant_names": ["Some Stranger"]})
        res = self.run_proof("cited2.pdf", pdf_bytes(SPLIT + "\n."), ctx=stranger, ocr_texts=[SPLIT])
        miss = next(s for s in res.signals if s.name == "claimant_not_named")
        self.assertEqual(miss.evidence.excerpt, content.NO_MATCH)
        self.assertIsNone(miss.evidence.region)

    def test_split_sheet_edited_after_creation_in_another_font_is_forged_likely(self):
        base = pdf_bytes(SPLIT)

        def edit(doc):
            page = doc[0]
            for r in page.search_for("50%")[:1]:
                page.add_redact_annot(r)
            page.apply_redactions()
            page.insert_text((300, 136), "75%", fontname="cour", fontsize=11)
        data = incremental(base, edit)
        res = self.run_proof("edited.pdf", data, ocr_texts=[SPLIT.replace("50%", "75%", 1)])
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY, res.reasons)
        self.assertIn("after_creation_key_field_edit", self.names(res))
        edit_sig = next(s for s in res.signals if s.name == "after_creation_key_field_edit")
        self.assertEqual(edit_sig.evidence.page, 1)
        self.assertTrue(edit_sig.evidence.region)                 # cites where the change is

    def test_form_fill_after_creation_is_not_an_edit(self):
        doc = pdf_forensics.pymupdf.open()
        page = doc.new_page()
        y = 72
        for line in SPLIT.splitlines():
            page.insert_text((72, y), line, fontname="helv", fontsize=11)
            y += 16
        w = pdf_forensics.pymupdf.Widget()
        w.field_name, w.field_type = "notes", pdf_forensics.pymupdf.PDF_WIDGET_TYPE_TEXT
        w.rect = pdf_forensics.pymupdf.Rect(72, 400, 300, 420)
        page.add_widget(w)
        base = doc.tobytes()
        doc.close()

        def fill(d):
            for wd in d[0].widgets():
                wd.field_value = "thanks"
                wd.update()
        data = incremental(base, fill)
        res = self.run_proof("filled.pdf", data, ocr_texts=[SPLIT])
        self.assertNotIn("after_creation_key_field_edit", self.names(res))
        self.assertNotEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_overlay_on_key_field_is_forged_likely(self):
        def edit(doc):
            r = doc[0].search_for("50%")[0]
            a = doc[0].add_freetext_annot(r, "90%", fontsize=11)
            a.update()
        data = incremental(pdf_bytes(SPLIT), edit)
        res = self.run_proof("overlay.pdf", data, ocr_texts=[SPLIT])
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY)
        self.assertIn("overlay_freetext_on_key_field", self.names(res))

    def signed(self) -> bytes:
        doc = pdf_forensics.pymupdf.open()
        page = doc.new_page()
        y = 72
        for line in SPLIT.splitlines():
            page.insert_text((72, y), line, fontname="helv", fontsize=11)
            y += 16
        doc.set_metadata({"keywords": "/ByteRange [0 0000000000 0000000000 0000000000]", "producer": "DocuSign DMv10"})
        data = doc.tobytes()
        doc.close()
        # Fake signature /Contents "<00>" appended as a comment-free object
        # region: a ByteRange is only valid when it brackets a <hex> value.
        body, eof = data[:data.rfind(b"startxref")], data[data.rfind(b"startxref"):]
        sig_at = len(body)
        body += b"<00000000>\n"
        data = body + eof
        b, c = sig_at, sig_at + 10
        out = data.replace(b"0000000000 0000000000 0000000000",
                           b"%s %s %s" % (str(b).zfill(10).encode(), str(c).zfill(10).encode(),
                                          str(len(data) - c).zfill(10).encode()))
        return out

    def test_signature_with_nothing_after_it_is_not_flagged(self):
        res = self.run_proof("signed.pdf", self.signed(), ocr_texts=[SPLIT])
        self.assertIn("signature_present", self.names(res))
        self.assertNotIn("post_signature_key_field_edit", self.names(res))
        self.assertEqual(res.verdict, verdict.GENUINE)        # unvalidated signature is never an issuer
        self.assertIn("signature_unvalidated", self.names(res))

    def test_byte_range_from_another_file_is_not_trusted(self):
        doc = pdf_forensics.pymupdf.open()
        doc.new_page().insert_text((72, 72), "merged contract", fontname="helv")
        doc.set_metadata({"keywords": "/ByteRange [ 0 10618 25760 549801 ]"})
        data = doc.tobytes()
        doc.close()
        res = self.run_proof("merged.pdf", data, ctx=ClaimContext(), ocr_texts=["merged contract"])
        self.assertIn("signature_not_covering_this_file", self.names(res))
        self.assertNotIn("signature_present", self.names(res))
        self.assertNotEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_content_changed_after_signing_is_forged_likely(self):
        def edit(doc):
            page = doc[0]
            for r in page.search_for("Jane Writer"):
                page.add_redact_annot(r)
            page.apply_redactions()
            page.insert_text((140, 136), "Real Producer", fontname="helv", fontsize=11)
        data = incremental(self.signed(), edit)
        res = self.run_proof("resigned.pdf", data, ocr_texts=[SPLIT])
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY, res.reasons)
        self.assertIn("post_signature_key_field_edit", self.names(res))

    def test_wrong_recording_and_missing_claimant_are_inconsistent_with_reasons(self):
        other = SPLIT.replace("USABC2400001", "GBXYZ1900042").replace("Night Drive", "Other Song") \
                     .replace("Real Producer", "Some One")
        res = self.run_proof("other.pdf", pdf_bytes(other), ocr_texts=[other])
        self.assertEqual(res.verdict, verdict.INCONSISTENT)
        reasons = " ".join(res.reasons)
        self.assertIn("ISRC in your document is for a different recording", reasons)
        self.assertIn("Your name doesn't appear", reasons)

    def test_matching_title_does_not_excuse_the_isrc_of_another_recording(self):
        other = SPLIT.replace("USABC2400001", "USBBB2400002")
        res = self.run_proof("same-title.pdf", pdf_bytes(other), ocr_texts=[other])
        self.assertTrue({"title_matches_claim", "isrc_other_recording"} <= self.names(res))
        self.assertEqual(res.verdict, verdict.INCONSISTENT)

    def pages_pdf(self, texts: list[str]) -> bytes:
        doc = pdf_forensics.pymupdf.open()
        for text in texts:
            page = doc.new_page()
            for k, line in enumerate(text.splitlines()):
                page.insert_text((72, 72 + 16 * k), line, fontname="helv", fontsize=11)
        out = doc.tobytes()
        doc.close()
        return out

    def test_pages_past_the_cap_are_never_cleared(self):
        contradiction = "Writer: Someone Else  share 100%"
        long_pdf = self.pages_pdf([SPLIT] + [""] * (pdf_forensics.MAX_PAGES - 1) + [contradiction])
        res = self.run_proof("long.pdf", long_pdf, ocr_texts=[SPLIT])
        cut = next(s for s in res.signals if s.name == "pages_not_inspected")
        self.assertEqual(cut.severity, "error")
        self.assertEqual(cut.value, {"pages": pdf_forensics.MAX_PAGES + 1, "inspected": pdf_forensics.MAX_PAGES})
        self.assertEqual(res.verdict, verdict.UNDETERMINED)
        scan = self.pages_pdf([""] * (pdf_forensics.SCAN_OCR_PAGES + 1))
        res = self.run_proof("scan.pdf", scan, ocr_texts=[SPLIT])
        self.assertIn("pages_not_inspected", self.names(res))
        self.assertEqual(res.verdict, verdict.UNDETERMINED)
        res = self.run_proof("short.pdf", self.pages_pdf([SPLIT, ""]), ocr_texts=[SPLIT])
        self.assertNotIn("pages_not_inspected", self.names(res))
        self.assertEqual(res.verdict, verdict.GENUINE, res.reasons)

    def test_single_song_shares_that_cannot_add_up_but_multi_song_sheets_pass(self):
        bad = SPLIT.replace("Jane Writer  share 50%", "Jane Writer  share 30%")
        res = self.run_proof("bad.pdf", pdf_bytes(bad), ocr_texts=[bad])
        self.assertIn("split_shares_do_not_add_up", self.names(res))
        multi = SPLIT + "\nSong Title: Second Song\nWriter: Real Producer share 100%"
        res2 = self.run_proof("multi.pdf", pdf_bytes(multi), ocr_texts=[multi])
        self.assertNotIn("split_shares_do_not_add_up", self.names(res2))

    def test_launch_action_is_rejected_but_form_script_is_only_recorded(self):
        launch = pdf_bytes(SPLIT).replace(b"/Type/Catalog", b"/Type/Catalog/OpenAction<</S/Launch/F(x.exe)>>")
        self.assertTrue(sniff(launch, "x.pdf").rejected)
        js = pdf_bytes(SPLIT).replace(b"/Type/Catalog", b"/Type/Catalog/OpenAction<</S/JavaScript/JS(x)>>")
        sn = sniff(js, "x.pdf")
        self.assertFalse(sn.rejected)
        self.assertIn("pdf_javascript", {s.name for s in sn.signals})

    def test_text_layer_vs_ocr_differences_are_recorded_not_flagged(self):
        # Calibration (Intercom replay 2026-10-15): every inspected diff was OCR
        # noise (a struck-through price), so it is info until calibrated.
        res = self.run_proof("pasted.pdf", pdf_bytes(SPLIT), ocr_texts=[SPLIT.replace("50%", "80%", 1)])
        diff = [s for s in res.signals if s.name in ("rendered_key_text_not_in_layer", "key_text_not_rendered")]
        self.assertTrue(diff and all(s.severity == "info" for s in diff))
        self.assertTrue(all(s.evidence.page == 1 for s in diff))

    def test_claim_text_covered_on_the_rendered_page_is_never_genuine(self):
        doc = pdf_forensics.pymupdf.open()
        page = doc.new_page()
        for k, line in enumerate(SPLIT.splitlines()):
            page.insert_text((72, 72 + 16 * k), line, fontname="helv", fontsize=11)
        page.draw_rect(pdf_forensics.pymupdf.Rect(60, 50, 560, 220), color=(1, 1, 1), fill=(1, 1, 1))
        page.insert_text((72, 300), "UNRELATED BLANK DOCUMENT", fontname="helv", fontsize=11)
        data = doc.tobytes()
        doc.close()
        res = self.run_proof("covered.pdf", data, ocr_texts=["UNRELATED BLANK DOCUMENT"])
        hidden = next(s for s in res.signals if s.name == "claim_text_not_rendered")
        self.assertEqual(hidden.value, {"fields": ["isrc", "title", "claimant"]})
        self.assertEqual(res.verdict, verdict.PLAUSIBLE, res.reasons)
        # The same page with the claim visible stays GENUINE.
        res = self.run_proof("visible.pdf", pdf_bytes(SPLIT), ocr_texts=[SPLIT])
        self.assertNotIn("claim_text_not_rendered", self.names(res))
        self.assertEqual(res.verdict, verdict.GENUINE, res.reasons)

    def test_unreadable_annotations_are_an_error_not_a_pass(self):
        class Page:
            def annots(self):
                raise RuntimeError("broken /Annots")
        sig = pdf_forensics._annots(Page(), "x.pdf", 0)
        self.assertEqual([(s.name, s.severity, s.evidence.page) for s in sig], [("annotations_unreadable", "error", 1)])

    def test_bold_total_line_is_not_a_unique_font(self):
        self.assertEqual(pdf_forensics.font_family("ABCDEF+Arial-BoldMT"), pdf_forensics.font_family("ArialMT"))
        self.assertEqual(pdf_forensics.font_family("HelveticaNeue-Bold"), pdf_forensics.font_family("HelveticaNeue"))


COWRITE = ("SPLIT SHEET\nSong Title: Night Drive\nISRC: USABC2400001\nArtist: Small Act\n"
           "Songwriter: Ann Alpha  share 50%\nSongwriter: Bob Beta  share 50%\n"
           "Signed by all parties on 2024-03-01. This agreement records the composition ownership split.")


def writer_ctx(name: str, track_key: str = "t-1") -> ClaimContext:
    return ClaimContext(**{**CTX.as_dict(), "claimed_roles": ["Songwriter"], "claimant_names": [name],
                           "track_key": track_key})


@unittest.skipUnless(HAVE_PDF, "PyMuPDF required")
class ReuseTests(Base):
    def test_stolen_proof_for_the_same_track_by_an_account_it_does_not_name_is_forged_likely(self):
        data = pdf_bytes(COWRITE)
        first = self.run_proof("a.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[COWRITE])
        self.assertEqual(first.verdict, verdict.GENUINE)
        again = self.run_proof("a2.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha", "t-9"), ocr_texts=[COWRITE])
        self.assertIn("reupload_same_account", self.names(again))
        self.assertEqual(again.verdict, verdict.GENUINE)
        for who, roles in (("mallory", ["Producer"]), ("mal2", ["Songwriter"])):
            thief = ClaimContext(**{**writer_ctx("Mallory Thief").as_dict(), "claimed_roles": roles})
            res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=thief, ocr_texts=[COWRITE])
            self.assertIn("claimant_not_named", self.names(res))
            reuse = [(s.name, s.severity, s.value["tracks"]) for s in res.signals
                     if s.check == "F2" and s.value.get("tracks") == 2]
            self.assertEqual(reuse, [("reused_by_another_account_same_claim", "hard", 2)], who)
            self.assertEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_named_co_writer_claiming_an_unlisted_role_is_suspect_however_many_tracks_the_other_used(self):
        sheet = COWRITE + "\nSong Title: Second Song\nISRC: USABC2400002"
        data = pdf_bytes(sheet)
        self.run_proof("a1.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[sheet])
        second = ClaimContext(**{**writer_ctx("Ann Alpha", "t-2").as_dict(), "track_title": "Second Song",
                                 "isrcs": ["USABC2400002"]})
        self.run_proof("a2.pdf", data, contact="ann", ctx=second, ocr_texts=[sheet])
        mixer = ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "claimed_roles": ["Mixing Engineer"]})
        res = self.run_proof("bob.pdf", data, contact="bob", ctx=mixer, ocr_texts=[sheet])
        self.assertTrue({"claimant_named", "claimed_role_not_listed"} <= self.names(res))
        self.assertEqual([(s.name, s.severity, s.value["tracks"]) for s in res.signals if s.check == "F2"],
                         [("shared_document_role_undetermined", "info", 2)])
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_co_writers_sharing_a_pro_registration_get_the_same_verdicts_in_either_order(self):
        reg = ("ASCAP Songview Work Registration\nTitle: Night Drive\nISWC: T-034.524.680-1\n"
               "Songwriter: Ann Alpha 50%\nSongwriter: Bob Beta 50%\nBMI member IPI 00012345678")
        data = pdf_bytes(reg)
        for verified, want in ((False, verdict.PLAUSIBLE), (True, verdict.GENUINE)):
            ctxs = {who: ClaimContext(**{**writer_ctx(name).as_dict(), "verified_names": [name] if verified else []})
                    for who, name in (("ann", "Ann Alpha"), ("bob", "Bob Beta"))}
            outcomes = []
            for order in (("ann", "bob"), ("bob", "ann")):
                self.store.close()
                self.store = ProofStore(os.path.join(self.tmp.name, f"pro-{verified}-{order[0]}.sqlite"))
                got = {}
                for who in order:
                    res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=ctxs[who], ocr_texts=[reg])
                    self.assertIn("claimant_named" if verified else "claimant_named_unverified", self.names(res))
                    self.assertFalse([s for s in res.signals if s.check == "F2" and s.severity in ("soft", "hard")])
                    got[who] = res.verdict
                outcomes.append(got)
            self.assertEqual(outcomes, [{"ann": want, "bob": want}] * 2, verified)

    SONGVIEW = ("ASCAP Songview Work Registration\nTitle: Night Drive\nISWC: T-034.524.680-1\n"
                "Writers: Songwriter: {ann} 50% Songwriter: {bob} 50%\n"
                "Publishers: Alpha Music Publishing 50% Beta Tunes Publishing 50%\n"
                "Performing rights for this work are administered by the member societies listed above.")

    def screenshot_order(self, page: str, ctxs: dict, tag: str) -> list[dict]:
        shots = {"ann": page_shot(240), "bob": page_shot(241)}
        outcomes = []
        for order in (("ann", "bob"), ("bob", "ann")):
            self.store.close()
            self.store = ProofStore(os.path.join(self.tmp.name, f"{tag}-{order[0]}.sqlite"))
            got = {}
            for n, who in enumerate(order):
                res = self.run_proof(f"{who}.png", shots[who], contact=who, ctx=ctxs[who], ocr_texts=[page])
                f2 = [(s.name, s.severity) for s in res.signals if s.check == "F2"]
                self.assertEqual(f2, [] if n == 0 else [("shared_public_page", "info")], (tag, order, who))
                got[who] = res.verdict
            outcomes.append(got)
        return outcomes

    def test_co_writers_each_screenshotting_the_same_pro_page_get_the_same_verdicts_in_either_order(self):
        for layout, names in (("first-last", ("Ann Alpha", "Bob Beta")), ("surname-first", ("ALPHA ANN", "BETA BOB"))):
            page = self.SONGVIEW.format(ann=names[0], bob=names[1])
            for verified, want in ((False, verdict.PLAUSIBLE), (True, verdict.GENUINE)):
                ctxs = {who: ClaimContext(**{**writer_ctx(name).as_dict(), "verified_names": [name] if verified else []})
                        for who, name in (("ann", "Ann Alpha"), ("bob", "Bob Beta"))}
                outcomes = self.screenshot_order(page, ctxs, f"{layout}-{verified}")
                self.assertEqual(outcomes, [{"ann": want, "bob": want}] * 2, (layout, verified))

    def test_second_account_presenting_the_same_credited_name_is_held_for_review(self):
        genius = "Genius\nNight Drive\nCredits\nProduced By Mike Dean\nWritten By Ann Alpha\nRelease Date 2024"
        real = ClaimContext(**{**CTX.as_dict(), "claimant_names": ["Mike Dean"], "verified_names": ["Mike Dean"],
                               "isrcs": []})
        first = self.run_proof("real.png", page_shot(240), contact="mike", ctx=real,
                               ocr_texts=[genius])
        self.assertEqual(first.verdict, verdict.GENUINE)
        for n, aka in enumerate(("Mike Dean", "By Mike Dean", "Mike Dean Produced", "Dean")):
            fake = ClaimContext(**{**real.as_dict(), "claimant_names": [aka], "verified_names": []})
            res = self.run_proof(f"fake{n}.png", page_shot(241 + n), contact=f"fraud{n}", ctx=fake,
                                 ocr_texts=[genius])
            self.assertIn("claimant_named_unverified", self.names(res), aka)
            self.assertEqual(sorted({(s.name, s.severity) for s in res.signals if s.check == "F2"}),
                             [("impersonation_suspected", "soft"), ("reused_by_another_account", "soft")], aka)
            self.assertEqual(res.verdict, verdict.SUSPECT, aka)

    def test_an_earlier_upload_whose_matched_name_is_unknown_counts_as_the_same_name(self):
        page = self.SONGVIEW.format(ann="Ann Alpha", bob="Bob Beta")
        self.run_proof("ann.png", page_shot(240), contact="ann", ctx=writer_ctx("Ann Alpha"),
                       ocr_texts=[page])
        self.store.db.execute("UPDATE fingerprints SET matched_name_hash=NULL, name_verified=NULL")
        self.store.db.commit()
        res = self.run_proof("bob.png", page_shot(241), contact="bob", ctx=writer_ctx("Bob Beta"),
                             ocr_texts=[page])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("reused_by_another_account", "soft")])
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_public_credits_page_proves_only_a_verified_identity(self):
        genius = "Genius\nNight Drive\nCredits\nProduced By Mike Dean\nWritten By Ann Alpha\nRelease Date 2024"
        cases = (([], verdict.PLAUSIBLE, "claimant_named_unverified"),
                 (["Mike Dean"], verdict.GENUINE, "claimant_named"))
        for n, (verified_names, want, signal) in enumerate(cases):
            ctx = ClaimContext(**{**CTX.as_dict(), "claimant_names": ["Mike Dean"], "verified_names": verified_names,
                                  "isrcs": []})
            res = self.run_proof(f"mike{n}.png", png_bytes(color=(200 + n, 200, 200)), contact="mike", ctx=ctx,
                                 ocr_texts=[genius])
            self.assertIn(signal, self.names(res))
            self.assertEqual(res.verdict, want, res.reasons)
        deanna = "Genius\nNight Drive\nCredits\nProduced By Deanna Lee"
        ctx = ClaimContext(**{**CTX.as_dict(), "claimant_names": ["Dean"], "verified_names": ["Dean"], "isrcs": []})
        res = self.run_proof("deanna.png", png_bytes(color=(10, 10, 10)), contact="dean", ctx=ctx,
                             ocr_texts=[deanna])
        self.assertIn("claimant_not_found", self.names(res))
        self.assertEqual(res.verdict, verdict.PLAUSIBLE)
        self.assertIsNone(content.name_in(deanna, ["Dean"]))
        self.assertIsNotNone(content.name_in(deanna, ["Lee Deanna"]))
        self.assertEqual(content.name_hash("Lee, Deanna"), content.name_hash("Deanna Lee"))
        page = "Writers: Songwriter: ALPHA ANN 50% Songwriter: BETA BOB 50%\nProduced By Mike Dean"
        self.assertEqual(content.credited_name(page, "Ann Alpha"), "alpha ann")
        self.assertEqual(content.credited_name(page, "Bob Beta"), "beta bob")
        for aka in ("Mike Dean", "By Mike Dean", "Mike Dean Produced", "Dean"):
            self.assertEqual(content.credited_name(page, aka), "dean mike", aka)
        line = "Written By Kanye West, Mike Dean & Ty Dolla $ign"
        self.assertEqual(content.credited_name(line, "Mike Dean"), "dean mike")
        self.assertEqual(content.credited_name(line, "Mike West"), "")
        self.assertEqual(content.credited_name("Written By Mike Will, Mike Dean", "Mike"), "")
        sheet = "SPLIT SHEET\nSongwriter: Alpha, Ann share 50%\nSongwriter: Beta, Bob share 50%"
        self.assertEqual((content.credited_name(sheet, "Ann Alpha"), content.credited_name(sheet, "Bob Beta")),
                         ("alpha ann", "beta bob"))
        self.assertEqual(content.name_hash(content.credited_name(sheet, "Ann Alpha")), content.name_hash("Ann Alpha"))
        self.assertEqual(content.credited_name(sheet, "Ann Beta"), "")
        one_line = "Songwriters: Alpha, Ann, Beta, Bob"
        self.assertEqual([content.credited_name(one_line, n) for n in ("Ann Alpha", "Bob Beta", "Ann Beta")],
                         ["alpha ann", "beta bob", ""])
        self.assertEqual(content.credited_name("Songwriters: Alpha, Ann, Beta", "Ann Alpha"), "")
        self.assertEqual(content.credited_name("Songwriter: Alpha, Ann", "Ann Alpha"), "alpha ann")
        self.assertEqual(content.credited_name("Mike Dean Interlude\nProduced By Mike Dean", "Mike Dean"), "dean mike")
        for extra in ("Publisher: Bob Beta Music", "Signature Bob Beta", "Email bob.beta@gmail.com",
                      "Bob Beta (BMI) IPI 00123456789"):
            sheet = f"SPLIT SHEET\nSongwriter: Ann Alpha share 50%\nSongwriter: Bob Beta share 50%\n{extra}"
            self.assertEqual(content.name_hash(content.credited_name(sheet, "Bob Beta")), content.name_hash("beta bob"),
                             extra)
            self.assertEqual(content.credited_name(sheet, "Ann Alpha"), "alpha ann", extra)
        digits = "Produced By 6LACK & 2Pac\nIPI 00012345678"
        self.assertEqual((content.credited_name(digits, "6LACK"), content.credited_name(digits, "2Pac")),
                         ("6lack", "2pac"))
        self.assertNotEqual(content.name_hash(content.credited_name(digits, "6LACK")),
                            content.name_hash(content.credited_name(digits, "2Pac")))

    def test_claim_context_that_does_not_pair_roles_with_requests_gets_no_verdict_row(self):
        data = pdf_bytes(COWRITE)
        for n, (rids, roles) in enumerate(((["r1", "r2"], ["Songwriter"]), ([], ["Songwriter", "Vocals"]))):
            ctx = ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "request_ids": rids, "claimed_roles": roles})
            [res] = self.run_claims(f"bad{n}.pdf", data + b" " * (n + 1), contact="bob", ctx=ctx,
                                    ocr_texts=[COWRITE])
            self.assertEqual([(s.name, s.severity) for s in res.signals if s.name == "claim_context_mismatch"],
                             [("claim_context_mismatch", "error")])
            self.assertEqual(res.verdict, verdict.UNDETERMINED)
            db = self.store.db
            self.assertEqual(db.execute("SELECT COUNT(*) FROM verdicts WHERE proof_id=?", (res.proof_id,)).fetchone()[0], 0)
            self.assertGreater(db.execute("SELECT COUNT(*) FROM forensics WHERE proof_id=?",
                                          (res.proof_id,)).fetchone()[0], 0)

    def test_a_pro_registration_that_does_not_name_the_uploader_is_plausible_in_either_order(self):
        reg = ("ASCAP Songview Work Registration\nTitle: Night Drive\nISWC: T-034.524.680-1\n"
               "Songwriter: Ann Alpha 50%\nSongwriter: Bob Beta 50%\nBMI member IPI 00012345678")
        data = pdf_bytes(reg)
        ctxs = {"cat": writer_ctx("Cat Gamma"), "dee": writer_ctx("Dee Delta")}
        outcomes = []
        for order in (("cat", "dee"), ("dee", "cat")):
            self.store.close()
            self.store = ProofStore(os.path.join(self.tmp.name, f"pro2-{order[0]}.sqlite"))
            got = {}
            for who in order:
                res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=ctxs[who], ocr_texts=[reg])
                self.assertIn("claimant_not_found", self.names(res))
                got[who] = res.verdict
            outcomes.append(got)
        self.assertEqual(outcomes, [{"cat": verdict.PLAUSIBLE, "dee": verdict.PLAUSIBLE}] * 2)

    def test_public_credits_page_that_does_not_name_the_claimant_is_only_plausible(self):
        genius = "Genius\nNight Drive\nCredits\nWritten By Ann Alpha\nProduced By Cee Gamma\nRelease Date 2024"
        for role in ("Songwriter", "Producer"):
            ctx = ClaimContext(**{**CTX.as_dict(), "claimed_roles": [role], "claimant_names": ["Mallory Fraud"],
                                  "isrcs": []})
            res = self.run_proof(f"genius-{role}.png", png_bytes(), contact=f"mal-{role}", ctx=ctx,
                                 ocr_texts=[genius])
            self.assertIn("title_matches_claim", self.names(res))
            self.assertEqual(res.verdict, verdict.PLAUSIBLE, (role, res.reasons))

    def test_each_claimed_role_gets_its_own_verdict(self):
        data = pdf_bytes(COWRITE)
        for roles, want in ((["Songwriter", "Vocals"], verdict.PLAUSIBLE), (["Songwriter", "Producer"], verdict.SUSPECT)):
            ctx = ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "request_ids": ["r1", "r2"],
                                  "claimed_roles": roles})
            results = self.run_claims(f"bob-{roles[1]}.pdf", data, contact="bob", ctx=ctx, ocr_texts=[COWRITE])
            self.assertEqual([(r.request_id, r.verdict) for r in results], [("r1", verdict.GENUINE), ("r2", want)])
            self.assertNotIn("claimed_role_not_listed", self.names(results[0]))
        self.assertIn("claimed_role_not_listed", self.names(results[1]))
        rows = self.store.db.execute("SELECT request_id, verdict FROM verdicts WHERE contact_h='bob' "
                                     "ORDER BY id").fetchall()
        self.assertEqual([tuple(r) for r in rows][-2:], [("r1", verdict.GENUINE), ("r2", verdict.SUSPECT)])
        self.assertTrue(self.store.analyzed(results[1].proof_id, "bob", "t-1", "r2"))
        self.assertFalse(self.store.analyzed(results[1].proof_id, "bob", "t-1", "r3"))

    def test_co_writers_sharing_one_split_sheet_corroborate_in_either_order(self):
        ctxs = {"ann": writer_ctx("Ann Alpha"), "bob": writer_ctx("Bob Beta")}
        surname_first = COWRITE.replace("Ann Alpha", "Alpha, Ann").replace("Bob Beta", "Beta, Bob")
        for extra in ("", "\nPublisher: Bob Beta Music", "\nSignature Bob Beta", "\nEmail bob.beta@gmail.com",
                      "\nBob Beta (BMI) IPI 00123456789", surname_first):
            sheet = surname_first if extra == surname_first else COWRITE + extra
            data = pdf_bytes(sheet)
            for order in (("ann", "bob"), ("bob", "ann")):
                self.store.close()
                self.store = ProofStore(os.path.join(self.tmp.name, f"cowrite-{len(extra)}-{order[0]}.sqlite"))
                first = self.run_proof("first.pdf", data, contact=order[0], ctx=ctxs[order[0]], ocr_texts=[sheet])
                res = self.run_proof("second.pdf", data, contact=order[1], ctx=ctxs[order[1]], ocr_texts=[sheet])
                self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                                 [("shared_split_sheet", "positive")], (extra, order))
                self.assertEqual((first.verdict, res.verdict), (verdict.GENUINE, verdict.GENUINE), (extra, order))

    def test_a_one_line_surname_first_list_corroborates_co_writers_but_never_splices_a_name(self):
        sheet = COWRITE.replace("Songwriter: Ann Alpha  share 50%\nSongwriter: Bob Beta  share 50%",
                                "Songwriters: Alpha, Ann, Beta, Bob")
        data = pdf_bytes(sheet)
        ctxs = {"ann": writer_ctx("Ann Alpha"), "bob": writer_ctx("Bob Beta"), "splice": writer_ctx("Ann Beta")}
        for order in (("ann", "bob"), ("bob", "ann")):
            self.store.close()
            self.store = ProofStore(os.path.join(self.tmp.name, f"one-line-{order[0]}.sqlite"))
            first = self.run_proof("first.pdf", data, contact=order[0], ctx=ctxs[order[0]], ocr_texts=[sheet])
            res = self.run_proof("second.pdf", data, contact=order[1], ctx=ctxs[order[1]], ocr_texts=[sheet])
            self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                             [("shared_split_sheet", "positive")], order)
            self.assertEqual((first.verdict, res.verdict), (verdict.GENUINE, verdict.GENUINE), order)
        self.store.close()
        self.store = ProofStore(os.path.join(self.tmp.name, "one-line-splice-first.sqlite"))
        res = self.run_proof("splice.pdf", data, contact="splice", ctx=ctxs["splice"], ocr_texts=[sheet])
        self.assertNotIn("claimant_named", self.names(res))
        self.assertIn("claimant_named_unverified", self.names(res))
        self.assertEqual(res.verdict, verdict.PLAUSIBLE, res.reasons)
        self.store.close()
        self.store = ProofStore(os.path.join(self.tmp.name, "one-line-splice.sqlite"))
        self.assertEqual(self.run_proof("ann.pdf", data, contact="ann", ctx=ctxs["ann"],
                                        ocr_texts=[sheet]).verdict, verdict.GENUINE)
        res = self.run_proof("splice.pdf", data, contact="splice", ctx=ctxs["splice"], ocr_texts=[sheet])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("reused_by_another_account", "soft")])
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_a_role_word_or_number_item_never_shifts_the_surname_first_pairs(self):
        listed = "Writers, Alpha, Ann, Beta, Bob, Cole, Cat, 2024"
        self.assertEqual([content.credited_name(listed, n) for n in ("Ann Alpha", "Bob Beta", "Ann Beta")],
                         ["alpha ann", "beta bob", ""])
        sheet = COWRITE.replace("Songwriter: Ann Alpha  share 50%\nSongwriter: Bob Beta  share 50%",
                                listed + "\nSignature Ann Alpha")
        data = pdf_bytes(sheet)
        self.assertEqual(self.run_proof("ann.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"),
                                        ocr_texts=[sheet]).verdict, verdict.GENUINE)
        res = self.run_proof("splice.pdf", data, contact="splice", ctx=writer_ctx("Ann Beta"), ocr_texts=[sheet])
        self.assertNotIn("shared_split_sheet", self.names(res))
        self.assertNotEqual(res.verdict, verdict.GENUINE)

    def test_the_owner_of_a_stolen_sheet_is_clean_whoever_uploads_first(self):
        data = pdf_bytes(COWRITE)
        ctxs = {"ann": writer_ctx("Ann Alpha"), "mallory": writer_ctx("Mallory Thief")}
        outcomes = []
        for order in (("mallory", "ann"), ("ann", "mallory")):
            self.store.close()
            self.store = ProofStore(os.path.join(self.tmp.name, f"stolen-{order[0]}.sqlite"))
            got = {}
            for who in order:
                res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=ctxs[who], ocr_texts=[COWRITE])
                got[who] = res.verdict
                if who == "ann":
                    self.assertFalse([s for s in res.signals if s.severity in ("soft", "hard")], order)
            outcomes.append(got)
        self.assertEqual(outcomes, [{"ann": verdict.GENUINE, "mallory": verdict.INCONSISTENT},
                                    {"ann": verdict.GENUINE, "mallory": verdict.FORGED_LIKELY}])

    def test_a_shadow_upload_that_named_nobody_is_not_the_same_name(self):
        data = pdf_bytes(COWRITE)
        self.run_proof("bob-intercom.pdf", data, contact="bob", ctx=ClaimContext(), ocr_texts=[COWRITE])
        res = self.run_proof("ann.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[COWRITE])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("shared_split_sheet", "positive")])
        self.assertEqual(res.verdict, verdict.GENUINE)

    def test_a_thief_after_a_shadow_upload_is_not_told_it_is_another_track(self):
        data = pdf_bytes(COWRITE)
        self.run_proof("ann-intercom.pdf", data, contact="ann", ctx=ClaimContext(), ocr_texts=[COWRITE])
        res = self.run_proof("mal.pdf", data, contact="mallory", ctx=writer_ctx("Mallory Thief"), ocr_texts=[COWRITE])
        hard = [s for s in res.signals if s.check == "F2"]
        self.assertEqual([(s.name, s.severity, s.value["same_track"]) for s in hard],
                         [("reused_by_another_account_same_claim", "hard", None)])
        self.assertNotIn("different track", hard[0].reason)
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_an_aka_built_from_two_credited_people_is_still_the_same_name(self):
        genius = "Genius\nNight Drive\nCredits\nWritten By Kanye West, Mike Dean & Ty Dolla $ign\nRelease Date 2024"
        real = ClaimContext(**{**CTX.as_dict(), "claimed_roles": ["Songwriter"], "claimant_names": ["Mike Dean"],
                               "verified_names": ["Mike Dean"], "isrcs": []})
        self.run_proof("real.png", page_shot(240), contact="mike", ctx=real, ocr_texts=[genius])
        fake = ClaimContext(**{**real.as_dict(), "claimant_names": ["Mike West"], "verified_names": []})
        res = self.run_proof("fake.png", page_shot(241), contact="fraud", ctx=fake, ocr_texts=[genius])
        named = next(s for s in res.signals if s.name == "claimant_named_unverified")
        self.assertIsNone(named.value["name_h"])
        self.assertIn(("reused_by_another_account", "soft"), {(s.name, s.severity) for s in res.signals})
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_co_writer_claiming_a_role_the_sheet_does_not_list_is_not_corroboration(self):
        data = pdf_bytes(COWRITE)
        self.run_proof("ann.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[COWRITE])
        mixer = ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "claimed_roles": ["Mixing Engineer"]})
        res = self.run_proof("bob.pdf", data, contact="bob", ctx=mixer, ocr_texts=[COWRITE])
        self.assertNotIn("shared_split_sheet", self.names(res))
        self.assertTrue({"claimed_role_not_listed", "shared_document_role_undetermined"} <= self.names(res))
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_same_document_for_a_different_track_it_does_not_list_is_forged_likely(self):
        data = pdf_bytes(COWRITE)
        self.run_proof("a.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[COWRITE])
        elsewhere = ClaimContext(**{**writer_ctx("Mallory Thief", "t-2").as_dict(), "track_title": "Other Song",
                                    "isrcs": ["USABC2400099"]})
        res = self.run_proof("b.pdf", data, contact="mallory", ctx=elsewhere, ocr_texts=[COWRITE])
        hard = next(s for s in res.signals if s.name == "reused_on_another_track")
        self.assertEqual(hard.severity, "hard")
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_named_co_writer_using_the_sheet_for_a_song_it_does_not_cover_is_for_review_not_forgery(self):
        data = pdf_bytes(COWRITE)
        self.run_proof("a.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[COWRITE])
        elsewhere = ClaimContext(**{**writer_ctx("Bob Beta", "t-2").as_dict(), "track_title": "Other Song",
                                    "isrcs": ["USABC2400099"]})
        res = self.run_proof("b.pdf", data, contact="bob", ctx=elsewhere, ocr_texts=[COWRITE])
        self.assertIn("claimant_named", self.names(res))
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("reused_by_another_account", "soft")])
        self.assertNotEqual(res.verdict, verdict.FORGED_LIKELY)
        self.assertEqual(res.verdict, verdict.INCONSISTENT)       # isrc_other_recording, with a reason to act on

    def test_split_sheet_for_another_recording_with_a_shared_word_stays_inconsistent(self):
        other = ("SPLIT SHEET\nSong Title: Dance Tonight\nISRC: USBBB2400002\n"
                 "Songwriter: Ann Alpha  share 50%\nSongwriter: Bob Beta  share 50%")
        ctx = ClaimContext(**{**writer_ctx("Ann Alpha").as_dict(), "track_title": "Dance With Me feat. Cee",
                              "isrcs": ["USAAA2400001"]})
        res = self.run_proof("dance.pdf", pdf_bytes(other), ctx=ctx, ocr_texts=[other])
        self.assertNotIn("title_matches_claim", self.names(res))
        self.assertIn("isrc_other_recording", self.names(res))
        self.assertEqual(res.verdict, verdict.INCONSISTENT)

    def test_role_the_sheet_cannot_express_is_plausible_in_either_upload_order(self):
        data = pdf_bytes(COWRITE)
        ctxs = {"ann": writer_ctx("Ann Alpha"),
                "bob": ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "claimed_roles": ["Vocals"]})}
        outcomes = []
        for order in (("ann", "bob"), ("bob", "ann")):
            self.store.close()
            self.store = ProofStore(os.path.join(self.tmp.name, f"vocals-{order[0]}.sqlite"))
            got = {}
            for who in order:
                res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=ctxs[who], ocr_texts=[COWRITE])
                got[who] = res.verdict
                self.assertFalse([s for s in res.signals if s.check == "F2" and s.severity == "soft"], (order, who))
            outcomes.append(got)
        self.assertEqual(outcomes, [{"ann": verdict.GENUINE, "bob": verdict.PLAUSIBLE}] * 2)

    def test_pro_registration_cannot_prove_a_producer_claim(self):
        reg = ("ASCAP Songview Work Registration\nTitle: Night Drive\nISRC: USABC2400001\n"
               "Songwriter: Bob Beta 50%\nSongwriter: Ann Alpha 50%\nBMI member IPI 00012345678")
        ctx = ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "claimed_roles": ["Producer"]})
        res = self.run_proof("reg.pdf", pdf_bytes(reg), contact="bob", ctx=ctx, ocr_texts=[reg])
        self.assertTrue({"title_matches_claim", "isrc_matches_claim", "claimed_role_not_expressible"} <= self.names(res))
        self.assertEqual(res.verdict, verdict.PLAUSIBLE)

    def test_claimed_role_the_sheet_does_not_list_gives_the_same_verdicts_in_either_upload_order(self):
        data = pdf_bytes(COWRITE)
        ctxs = {"ann": writer_ctx("Ann Alpha"),
                "bob": ClaimContext(**{**writer_ctx("Bob Beta").as_dict(), "claimed_roles": ["Producer"]})}
        outcomes = []
        for order in (("ann", "bob"), ("bob", "ann")):
            self.store.close()
            self.store = ProofStore(os.path.join(self.tmp.name, f"roles-{order[0]}.sqlite"))
            got = {}
            for who in order:
                res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=ctxs[who], ocr_texts=[COWRITE])
                got[who] = res.verdict
                if who == "bob":
                    role = next(s for s in res.signals if s.name == "claimed_role_not_listed")
                    self.assertEqual((role.severity, role.evidence.excerpt), ("soft", content.NO_MATCH))
            outcomes.append(got)
        self.assertEqual(outcomes, [{"ann": verdict.GENUINE, "bob": verdict.SUSPECT}] * 2)

    def test_named_co_writers_get_the_same_verdicts_in_either_upload_order(self):
        sheet = COWRITE.replace("ISRC: USABC2400001\n", "")
        data = pdf_bytes(sheet)
        for catalog_title in ("Night Drive feat. Cee", "Midnight Drive"):
            outcomes = []
            for order in (("ann", "bob"), ("bob", "ann")):
                self.store.close()
                self.store = ProofStore(os.path.join(self.tmp.name, f"{catalog_title}-{order[0]}.sqlite"))
                got = {}
                for who in order:
                    ctx = ClaimContext(**{**writer_ctx({"ann": "Ann Alpha", "bob": "Bob Beta"}[who]).as_dict(),
                                          "track_title": catalog_title, "isrcs": []})
                    res = self.run_proof(f"{who}.pdf", data, contact=who, ctx=ctx, ocr_texts=[sheet])
                    self.assertFalse([s for s in res.signals if s.severity == "hard"], (catalog_title, order, who))
                    got[who] = res.verdict
                outcomes.append(got)
            self.assertEqual(outcomes[0], outcomes[1], catalog_title)
            self.assertNotIn(verdict.FORGED_LIKELY, outcomes[0].values())
        self.assertEqual(outcomes[0], {"ann": verdict.SUSPECT, "bob": verdict.SUSPECT})

    EP = ("PRODUCER AGREEMENT\nThis agreement is made between Small Act and the producers below.\n"
          "Producer: Pat Prod\nProducer: Quinn Beat\n"
          "Track 1: Blue Hour ISRC USEPA2400001\nTrack 2: Neon Rain ISRC USEPA2400002\n"
          "Track 3: Glass City ISRC USEPA2400003\nTrack 4: Late Train ISRC USEPA2400004\n"
          "In witness whereof the parties have signed this agreement on 2024-05-01.")
    EP_TRACKS = (("t-a", "Blue Hour", "USEPA2400001"), ("t-b", "Neon Rain", "USEPA2400002"),
                 ("t-c", "Glass City", "USEPA2400003"), ("t-d", "Late Train", "USEPA2400004"))

    def ep_ctx(self, name: str, key: str, title: str, isrc: str) -> ClaimContext:
        return ClaimContext(request_ids=[f"r-{key}"], track_title=title, track_artists=["Small Act"], isrcs=[isrc],
                            claimed_roles=["Producer"], claimant_names=[name], track_key=key)

    def test_ep_agreement_shared_by_named_co_producers_corroborates_every_listed_track(self):
        data = pdf_bytes(self.EP)
        results = []
        for who, name in (("pat", "Pat Prod"), ("quinn", "Quinn Beat")):
            for key, title, isrc in self.EP_TRACKS:
                res = self.run_proof(f"{who}-{key}.pdf", data, contact=who, ctx=self.ep_ctx(name, key, title, isrc),
                                     ocr_texts=[self.EP])
                results.append(res)
                self.assertFalse([s for s in res.signals if s.severity == "hard"], (who, key, res.reasons))
                self.assertNotEqual(res.verdict, verdict.FORGED_LIKELY)
        for res in results[4:]:
            self.assertEqual([(s.name, s.severity) for s in res.signals
                              if s.check == "F2" and s.name != "reupload_same_account"],
                             [("shared_split_sheet", "positive")])
            self.assertEqual(res.verdict, verdict.GENUINE, res.reasons)

    def test_ep_agreement_used_by_a_named_co_producer_for_another_listed_track_corroborates(self):
        data = pdf_bytes(self.EP)
        self.run_proof("pat.pdf", data, contact="pat", ctx=self.ep_ctx("Pat Prod", *self.EP_TRACKS[0]),
                       ocr_texts=[self.EP])
        res = self.run_proof("quinn.pdf", data, contact="quinn", ctx=self.ep_ctx("Quinn Beat", *self.EP_TRACKS[2]),
                             ocr_texts=[self.EP])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("shared_multi_track_document", "positive")])
        self.assertEqual(res.verdict, verdict.GENUINE, res.reasons)

    def test_ep_agreement_used_by_a_named_co_producer_for_a_track_it_does_not_list_is_for_review(self):
        data = pdf_bytes(self.EP)
        self.run_proof("pat.pdf", data, contact="pat", ctx=self.ep_ctx("Pat Prod", *self.EP_TRACKS[0]),
                       ocr_texts=[self.EP])
        res = self.run_proof("quinn5.pdf", data, contact="quinn",
                             ctx=self.ep_ctx("Quinn Beat", "t-e", "Fifth Song", "USEPA2400005"), ocr_texts=[self.EP])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("reused_by_another_account", "soft")])
        self.assertNotEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_ep_agreement_for_a_track_it_does_not_list_by_someone_it_does_not_name_is_forged_likely(self):
        data = pdf_bytes(self.EP)
        self.run_proof("pat.pdf", data, contact="pat", ctx=self.ep_ctx("Pat Prod", *self.EP_TRACKS[0]),
                       ocr_texts=[self.EP])
        res = self.run_proof("mal5.pdf", data, contact="mallory",
                             ctx=self.ep_ctx("Mallory Thief", "t-e", "Fifth Song", "USEPA2400005"), ocr_texts=[self.EP])
        self.assertEqual(next(s for s in res.signals if s.name == "reused_on_another_track").severity, "hard")
        self.assertEqual(res.verdict, verdict.FORGED_LIKELY)

    def test_edited_near_copy_is_never_corroboration(self):
        terms = "\n".join(f"Term {n}: the producer delivers the masters listed above and the fees in clause {n} "
                          f"are paid on delivery." for n in range(1, 31))
        original = self.EP + "\n" + terms
        self.run_proof("pat.pdf", pdf_bytes(original, size=6, step=8), contact="pat",
                       ctx=self.ep_ctx("Pat Prod", *self.EP_TRACKS[0]), ocr_texts=[original])
        edited = original.replace("Track 4: Late Train ISRC USEPA2400004", "Track 4: Fifth Song ISRC USEPA2400005")
        res = self.run_proof("quinn5.pdf", pdf_bytes(edited, size=6, step=8), contact="quinn",
                             ctx=self.ep_ctx("Quinn Beat", "t-e", "Fifth Song", "USEPA2400005"), ocr_texts=[edited])
        self.assertTrue({"title_matches_claim", "claimant_named"} <= self.names(res))
        self.assertEqual([(s.name, s.severity, s.value["how"]) for s in res.signals if s.check == "F2"],
                         [("reused_by_another_account", "soft", ["same_text_and_entities"])])
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_cross_track_reuse_whose_name_check_cannot_run_is_plausible(self):
        reg = ("DistroKid Upload My Music Stats Splits\nTitle: Night Drive\nTitle: Second Song\n"
               "Songwriter: Ann Alpha 50%\nSongwriter: Bob Beta 50%")
        data = pdf_bytes(reg)
        self.run_proof("ann.pdf", data, contact="ann", ctx=writer_ctx("Ann Alpha"), ocr_texts=[reg])
        second = ClaimContext(**{**writer_ctx("Bob Beta", "t-2").as_dict(), "track_title": "Second Song", "isrcs": []})
        res = self.run_proof("bob.pdf", data, contact="bob", ctx=second, ocr_texts=[reg])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("shared_document_claimant_undetermined", "info")])
        self.assertEqual(res.verdict, verdict.PLAUSIBLE, res.reasons)
        unlinked = ClaimContext(track_key="t-3", claimed_roles=["Songwriter"])
        res = self.run_proof("cat.pdf", data, contact="cat", ctx=unlinked, ocr_texts=[reg])
        self.assertEqual([(s.name, s.severity) for s in res.signals if s.check == "F2"],
                         [("reused_by_another_account", "soft")])
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_unlinked_reuse_by_another_account_is_suspect(self):
        data = pdf_bytes(COWRITE)
        self.run_proof("a.pdf", data, contact="ann", ctx=ClaimContext(), ocr_texts=[COWRITE])
        res = self.run_proof("b.pdf", data, contact="bob", ctx=ClaimContext(), ocr_texts=[COWRITE])
        self.assertIn("reused_by_another_account", self.names(res))
        self.assertEqual(res.verdict, verdict.SUSPECT)

    def test_long_form_template_headings_are_not_shared_names(self):
        clauses = "\n".join(f"Clause {n}: the parties agree that the shares listed on this sheet are final for "
                            f"purpose {n} and bind every successor." for n in range(1, 41))
        tmpl = ("SPLIT SHEET\nSong Title: {t}\nWriter Name: {w}\nPublisher Name: {p}\nRecord Label: Indie\n"
                "Effective Date: {d}\nPerforming Rights Organization: ASCAP\nShare: 100%\n" + clauses +
                "\nIn Witness Whereof\nSignature Date ____\nPrint Name ____")
        texts = [tmpl.format(t=t, w=w, p=p, d=d) for t, w, p, d in (
            ("Alpha Song", "Ann Alpha", "Alpha Music", "2024-01-01"),
            ("Beta Song", "Bob Beta", "Beta Tunes", "2024-02-02"),
            ("Gamma Song", "Cat Gamma", "Gamma Works", "2024-03-03"))]
        sh = [fingerprint.shingles(t) for t in texts]
        self.assertGreaterEqual(fingerprint.jaccard(fingerprint.minhash(sh[0]), fingerprint.minhash(sh[1])),
                                fingerprint.MINHASH_REUSE)
        for n, (t, who) in enumerate(zip(texts, ("ann", "bob", "cat"))):
            res = self.run_proof(f"lt{n}.pdf", pdf_bytes(t, size=6, step=8), contact=who, ctx=ClaimContext(),
                                 ocr_texts=[t])
            self.assertFalse([s for s in res.signals if s.name.startswith("reused_")], n)
        self.assertIn("template_family", self.names(res))

    def test_same_template_filled_by_different_people_is_a_family_not_reuse(self):
        tmpl = ("SPLIT SHEET template. Please list each writer and their share\nof the composition below and have all "
                "parties sign.\nSong Title: {t}\nISRC: {i}\nWriter: {w} share 100%\nSignature ____ Date ____\n"
                "This split sheet records the agreed ownership\nof the musical composition named above.")
        texts = [tmpl.format(t=t, i=i, w=w) for t, i, w in (("Alpha Song", "USAAA2400001", "Ann Alpha"),
                                                              ("Beta Song", "USBBB2400002", "Bob Beta"),
                                                              ("Gamma Song", "USCCC2400003", "Cat Gamma"))]
        for n, (t, who) in enumerate(zip(texts, ("ann", "bob", "cat"))):
            res = self.run_proof(f"t{n}.pdf", pdf_bytes(t), contact=who, ctx=ClaimContext(), ocr_texts=[t])
        self.assertNotIn("reused_by_another_account", self.names(res))
        self.assertIn("template_family", self.names(res))


class StoreMigrationTests(unittest.TestCase):
    def test_a_store_from_the_first_schema_gains_the_new_columns_and_keeps_its_rows(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "old.sqlite")
            db = sqlite3.connect(path)
            db.executescript("""
CREATE TABLE proofs (proof_id TEXT PRIMARY KEY, first_seen TEXT NOT NULL, source TEXT NOT NULL, source_ref TEXT,
  contact_h TEXT, mime TEXT, bytes INTEGER);
CREATE TABLE forensics (id INTEGER PRIMARY KEY AUTOINCREMENT, proof_id TEXT NOT NULL, analyzer_version TEXT NOT NULL,
  check_id TEXT NOT NULL, name TEXT NOT NULL, severity TEXT NOT NULL, value_json TEXT, reason TEXT,
  evidence_json TEXT, created_at TEXT NOT NULL);
CREATE TABLE fingerprints (proof_id TEXT NOT NULL, contact_h TEXT, kind TEXT, mime TEXT, phash TEXT,
  minhash_json TEXT, n_shingles INTEGER, entities_json TEXT, layout TEXT, producer TEXT, track_key TEXT,
  role_families TEXT, created_at TEXT NOT NULL, PRIMARY KEY (proof_id, contact_h, track_key));
CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT, proof_id TEXT NOT NULL, analyzer_version TEXT NOT NULL,
  verdict TEXT NOT NULL, reasons_json TEXT, context_json TEXT, created_at TEXT NOT NULL);
INSERT INTO fingerprints (proof_id, contact_h, kind, mime, track_key, created_at)
  VALUES ('p-old', 'old', 'pro_portal', 'image/png', 't-1', '2026-10-01T00:00:00Z');
""")
            db.commit()
            db.close()
            store = ProofStore(path)
            try:
                [old] = [f for f in store._prior() if f.proof_id == "p-old"]
                self.assertEqual((old.name_h, old.claimant_named, old.kind), (None, None, "pro_portal"))
                path_png = os.path.join(d, "x.png")
                Path(path_png).write_bytes(png_bytes() if Image else b"\x89PNG")
                [res] = analyze_proof(store, path_png, contact_h="c", source="test", source_ref="x",
                                      ctx=ClaimContext(), runner=fake_runner)
                self.assertTrue(store.analyzed(res.proof_id, "c", None))
            finally:
                store.close()


class FingerprintTests(unittest.TestCase):
    @unittest.skipUnless(Image, "Pillow required")
    def test_phash_tolerates_recompression_but_separates_layouts(self):
        a = png_bytes(draw=[(10, 10, 300, 40, (30, 30, 30)), (10, 100, 120, 300, (200, 30, 30))])
        im = Image.open(io.BytesIO(a))
        buf = io.BytesIO()
        im.convert("RGB").save(buf, format="JPEG", quality=85)
        b = buf.getvalue()
        c = png_bytes(draw=[(10, 400, 300, 40, (30, 30, 30)), (200, 10, 100, 300, (30, 30, 200))])
        ha, hb, hc = (fingerprint.phash64(x if x[:4] == b"\x89PNG" else _to_png(x)) for x in (a, b, c))
        self.assertLessEqual(fingerprint.hamming(ha, hb), fingerprint.PHASH_MAX_DISTANCE)
        self.assertGreater(fingerprint.hamming(ha, hc), fingerprint.PHASH_MAX_DISTANCE)

    def test_minhash_is_stable(self):
        s = fingerprint.shingles("one two three four five six seven eight nine ten eleven")
        self.assertEqual(fingerprint.minhash(s), fingerprint.minhash(set(s)))
        self.assertEqual(fingerprint.jaccard(fingerprint.minhash(s), fingerprint.minhash(s)), 1.0)


def _to_png(data: bytes) -> bytes:
    buf = io.BytesIO()
    Image.open(io.BytesIO(data)).save(buf, format="PNG")
    return buf.getvalue()


class SignatureTests(unittest.TestCase):
    def check(self, **kw):
        return {"intact": True, "valid": True, "covers_whole": True, "trusted": False, "signer": "CN=Big Label Ltd", **kw}

    def test_only_a_trusted_other_party_signature_is_an_issuer(self):
        sev = lambda checks, names: [(s.name, s.severity)  # noqa: E731
                                     for s in pdf_forensics.signature_signals(checks, names, "x.pdf")]
        self.assertEqual(sev([self.check()], ["Real Producer"]), [("signature_valid_not_issuer", "info")])
        self.assertEqual(sev([self.check(trusted=True)], ["Real Producer"]), [("valid_other_party_signature", "issuer")])
        self.assertEqual(sev([self.check(trusted=True)], []), [("signature_valid_not_issuer", "info")])
        self.assertEqual(sev([self.check(trusted=True, signer="CN=Real Producer")], ["Real Producer"]),
                         [("signature_valid_not_issuer", "info")])
        self.assertEqual(sev([{"error": "bad cms"}], ["Real Producer"]), [("signature_validation_failed", "error")])
        self.assertEqual(sev([self.check(intact=False)], ["Real Producer"]), [("signature_not_intact", "soft")])
        failed = pdf_forensics.signature_signals([{"error": "bad cms"}], ["Real Producer"], "x.pdf")
        self.assertEqual(verdict.decide(failed + [Signal("F5a", "isrc_matches_claim", "positive")], CTX)[0],
                         verdict.UNDETERMINED)

    def test_no_configured_trust_roots_means_no_trusted_chain(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(pdf_forensics, "TRUST_ROOTS_DIR", Path(d)):
            self.assertEqual(pdf_forensics._trust_roots(), [])


class VerdictTests(unittest.TestCase):
    def s(self, name, sev, check="F4a"):
        return Signal(check, name, sev)

    def test_order_and_combinations(self):
        linked = CTX
        self.assertEqual(verdict.decide([self.s("x", "hard")], linked)[0], verdict.FORGED_LIKELY)
        self.assertEqual(verdict.decide([self.s("after_creation_key_field_edit", "soft"),
                                         self.s("claimant_not_named", "mismatch", "F5b")], linked)[0],
                         verdict.FORGED_LIKELY)
        self.assertEqual(verdict.decide([self.s("key_field_unique_font", "soft", "F4b"),
                                         self.s("after_creation_key_field_edit", "soft")], linked)[0],
                         verdict.FORGED_LIKELY)
        self.assertEqual(verdict.decide([self.s("key_field_unique_font", "soft", "F4b"),
                                         self.s("after_creation_text_edit", "info")], linked)[0], verdict.SUSPECT)
        self.assertEqual(verdict.decide([self.s("claimant_not_named", "mismatch", "F5b")], linked)[0],
                         verdict.INCONSISTENT)
        self.assertEqual(verdict.decide([self.s("x", "soft")], linked)[0], verdict.SUSPECT)
        self.assertEqual(verdict.decide([self.s("dsp_artist_not_track_artist", "soft", "F5e"),
                                         self.s("editor_software_on_screenshot", "soft", "F3a")], linked)[0],
                         verdict.FORGED_LIKELY)

    def test_an_error_is_never_a_pass(self):
        sig = [self.s("ocr_unavailable", "error", "F3b"), self.s("isrc_matches_claim", "positive", "F5a")]
        self.assertEqual(verdict.decide(sig, CTX)[0], verdict.UNDETERMINED)

    def test_genuine_needs_content_and_verified_needs_an_issuer(self):
        self.assertEqual(verdict.decide([], CTX)[0], verdict.SUSPECT)
        self.assertEqual(verdict.decide([self.s("isrc_matches_claim", "positive", "F5a")], CTX)[0],
                         verdict.PLAUSIBLE)
        self.assertEqual(verdict.decide([self.s("claimant_named", "positive", "F5b")], CTX)[0], verdict.SUSPECT)
        pos = [self.s("isrc_matches_claim", "positive", "F5a"), self.s("claimant_named", "positive", "F5b")]
        self.assertEqual(verdict.decide(pos, CTX)[0], verdict.GENUINE)
        self.assertEqual(verdict.decide(pos + [self.s("valid_other_party_signature", "issuer", "F4d")], CTX)[0],
                         verdict.VERIFIED)
        self.assertEqual(verdict.decide([], ClaimContext())[0], verdict.CLEAN_UNLINKED)
        capped = pos + [self.s("valid_other_party_signature", "issuer", "F4d"),
                        self.s("claimed_role_not_expressible", "info", "F5b")]
        self.assertEqual(verdict.decide(capped, CTX)[0], verdict.PLAUSIBLE)


class ContentTests(unittest.TestCase):
    def test_check_digits(self):
        import re
        self.assertTrue(content.iswc_ok(re.match(content.ISWC, "T-034.524.680-1")))
        self.assertFalse(content.iswc_ok(re.match(content.ISWC, "T-034.524.680-2")))
        self.assertTrue(content.ean_ok("036000291452"))
        self.assertFalse(content.ean_ok("036000291453"))

    def test_featured_artist_segments_are_not_part_of_the_title(self):
        for t in ("Night Drive feat. Cee", "Night Drive ft Cee", "Night Drive featuring Cee & Dee",
                  "Night Drive (feat. Cee)", "Night Drive [with Cee]", "Night Drive with Cee"):
            self.assertEqual(content._title_key(t), "night drive", t)
            self.assertTrue(content.title_in("song title night drive isrc", t), t)
        self.assertEqual(content._title_key("Dance With Me"), "dance with me")
        self.assertEqual(content._title_key("Dance With Me feat. Cee"), "dance with me")
        self.assertEqual(content._title_key("Ride With Me ft Cee"), "ride with me")
        self.assertFalse(content.title_in("song title dance tonight", "Dance With Me feat. Cee"))

    def role_signals(self, text: str, roles: list[str]) -> list[str]:
        ctx = ClaimContext(track_title="Night Drive", claimed_roles=roles, claimant_names=["Bob Beta"], track_key="t-1")
        ext = Extracted(pages_text=[text], text_source="pdf_text")
        sig, ents = content.analyze(ext, ctx, "x.pdf")
        self.assertIn("claimant_named", [s.name for s in sig], text)
        roles_sig = content.role_signals(ext.kind, ents["roles"], roles, True, "x.pdf")
        return [s.name for s in roles_sig if s.name == "claimed_role_not_listed"]

    def test_claimed_role_is_compared_only_when_the_role_words_can_express_it(self):
        head = "AGREEMENT\nThis agreement covers the song below.\nSong Title: Night Drive\n"
        cases = (
            ("Dolby Atmos Mix Engineer: Bob Beta", ["Immersive Mixing"], []),
            ("Produced by Bob Beta\nMixing Engineer: Cee Dee", ["Producer"], []),
            ("Mixed by Bob Beta\nSongwriter: Cee Dee", ["Mixing"], []),
            ("Remastering: Bob Beta\nSongwriter: Cee Dee", ["Remastering"], []),
            ("Programming: Bob Beta\nSongwriter: Ann Alpha", ["Programming"], []),
            ("Assistant Engineer: Bob Beta\nProducer: Cee Dee", ["Assistant Engineer"], []),
            ("Guitar: Bob Beta\nProducer: Cee Dee", ["Guitar"], []),
            ("Featured Artist: Bob Beta\nProducer: Cee Dee", ["Featured Artist"], []),
            ("Bob Beta and Cee Dee", ["Producer"], []),
            ("Songwriter: Bob Beta\nSongwriter: Ann Alpha", ["Producer"], ["claimed_role_not_listed"]),
        )
        for body, roles, want in cases:
            self.assertEqual(self.role_signals(head + body, roles), want, (body, roles))
        self.assertEqual(self.role_signals(COWRITE, ["Producer"]), ["claimed_role_not_listed"])
        self.assertEqual(content.entities("Produced by A\nWritten by B\nMastered by C")["roles"],
                         ["master", "producer", "writer"])

    def test_kind(self):
        self.assertEqual(content.classify_kind(SPLIT), "split_sheet")
        self.assertEqual(content.classify_kind("INVOICE Bill to: Label. Amount due 300"), "invoice")


class SandboxTests(unittest.TestCase):
    @unittest.skipUnless(Image, "Pillow required")
    def test_rlimit_child_returns_json_without_inheriting_secrets(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.png")
            Path(p).write_bytes(png_bytes())
            with mock.patch.dict(os.environ, {"CREDIT_PROOF_SANDBOX": "rlimit", "OPENROUTER_API_KEY": "secret"}):
                res = sandbox.run(p, None, {})
        self.assertEqual(len(res.get("sha256", "")), 64)
        self.assertEqual(res.get("mime"), "image/png")

    def test_systemd_unit_has_no_network_and_no_capabilities(self):
        argv = sandbox.systemd_argv("/usr/bin/python3")
        props = [argv[i + 1] for i, a in enumerate(argv) if a == "-p"]
        for want in ("PrivateNetwork=yes", "NoNewPrivileges=yes", "CapabilityBoundingSet=", "ProtectSystem=strict",
                     "PrivateTmp=yes"):
            self.assertIn(want, props)
        self.assertTrue(any(p.startswith("RuntimeMaxSec=") for p in props))
        self.assertIn("-I", argv)

    def test_systemd_unit_is_unprivileged_sees_no_home_and_only_the_code_dir(self):
        argv = sandbox.systemd_argv("/usr/bin/python3")
        props = [argv[i + 1] for i, a in enumerate(argv) if a == "-p"]
        self.assertIn("DynamicUser=yes", props)      # not root: root-only host files are unreadable
        self.assertIn("ProtectHome=yes", props)      # /root, /home, /run/user are empty
        self.assertFalse(any(p.startswith(("User=", "Group=")) for p in props))
        binds = [p.split("=", 1)[1] for p in props if p.startswith(("BindPaths=", "BindReadOnlyPaths="))]
        self.assertEqual(binds, [f"{sandbox.SCRIPTS}:{sandbox.CODE_DIR}"])
        hidden = {p.split("=", 1)[1].lstrip("-") for p in props if p.startswith("InaccessiblePaths=")}
        self.assertTrue({"/etc/openclaw", "/etc/hydra"} <= hidden)

    @unittest.skipUnless(Image, "Pillow required")
    def test_child_reads_the_bytes_it_is_given_never_the_host_path(self):
        # The child cites the host path but never opens it: a path the
        # sandboxed user could not read still analyses, from the passed bytes.
        data = png_bytes()
        label = "/root/.openclaw-edge/media/does-not-exist/1.png"
        req = json.dumps({"path": label, "data": base64.b64encode(data).decode(), "declared": None, "context": {}})
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.run([sys.executable, "-m", "credit_verify.proof.analyze"], input=req, capture_output=True,
                               text=True, cwd=d, env={"PATH": os.environ.get("PATH", ""), "PYTHONPATH": sandbox.SCRIPTS,
                                                      "HOME": d}, check=True)
        res = json.loads(p.stdout)
        self.assertNotIn("fatal", res)
        self.assertEqual(res["sha256"], fingerprint.sha256(data))
        self.assertEqual(res["mime"], "image/png")
        cited = {s["evidence"]["file"] for s in res["signals"] if s.get("evidence")}
        self.assertEqual(cited, {label})

    def test_an_unreadable_input_is_a_sandbox_error_not_a_pass(self):
        with self.assertRaises(sandbox.SandboxError):
            sandbox.run("/nonexistent/cvproof/1.png", None, {})

    @unittest.skipUnless(os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0
                         and shutil.which("systemd-run") and os.path.isdir("/run/systemd/system"),
                         "needs root + systemd (node-8)")
    def test_live_systemd_unit_cannot_read_root_only_or_home_files(self):
        with tempfile.TemporaryDirectory(dir="/var/tmp") as d:
            canary = os.path.join(d, "secret")
            Path(canary).write_text("x")
            os.chmod(canary, 0o600)
            os.chmod(d, 0o755)
            base = sandbox.systemd_argv(sys.executable)[:-4]
            for target in (canary, "/root/.bashrc", "/root/.openclaw-main"):
                r = subprocess.run(base + ["/bin/cat", target], capture_output=True, text=True, timeout=60, check=False)
                self.assertNotEqual(r.returncode, 0, target)
        if Image:
            with tempfile.TemporaryDirectory() as d:
                p = os.path.join(d, "x.png")
                Path(p).write_bytes(png_bytes())
                os.chmod(p, 0o600)
                with mock.patch.dict(os.environ, {"CREDIT_PROOF_SANDBOX": "systemd"}):
                    self.assertEqual(sandbox.run(p, None, {}).get("mime"), "image/png")


def fake_box(text: str, token: str) -> list:
    return next(w["box"] for w in words_for(text) if w["text"] == token)


def failing_runner(path, declared, ctx):
    raise sandbox.SandboxError("analysis timed out after 420s")


def fake_runner(path, declared, ctx):
    data = Path(path).read_bytes()
    return {"sha256": fingerprint.sha256(data), "mime": "image/png", "bytes": len(data), "signals": [],
            "kind": "unknown", "phash": None, "minhash": [], "n_shingles": 0, "entities": {}}


def eml(frm: str, auth: str | None, attach: bytes | None = b"\x89PNG\r\n\x1a\nxx", inline_logo=False) -> bytes:
    from email.message import EmailMessage
    m = EmailMessage()
    m["From"] = frm
    m["To"] = "verify@muso.ai"
    m["Subject"] = "Approve my credit on Bad Guy, I am user 42"
    m["Message-ID"] = "<abc@example.com>"
    if auth:
        m["Authentication-Results"] = auth
    m.set_content("Here is my split sheet")
    if attach:
        m.add_attachment(attach, maintype="image", subtype="png", filename="split.png")
    if inline_logo:
        m.add_attachment(b"\x89PNG logo", maintype="image", subtype="png", disposition="inline")
    return bytes(m)


class EmailChannelTests(Base):
    PASS = "mx.cloudflare.net; dkim=pass header.d=example.com; spf=pass; dmarc=pass header.from=example.com"

    def users(self, addr):
        return [{"id": 42, "email": "Artist@Example.com", "emailConfirmed": True}] if "artist@" in addr else []

    def maildir(self, files):
        md = os.path.join(self.tmp.name, "mail")
        os.makedirs(os.path.join(md, "new"))
        for name, data in files.items():
            Path(md, "new", name).write_bytes(data)
        return md

    def test_authentication_is_read_only_from_the_trusted_mta(self):
        import email
        import email.policy
        from credit_verify.proof import email_in
        parse = lambda b: email.message_from_bytes(b, policy=email.policy.default)  # noqa: E731
        self.assertEqual(email_in.authenticated_sender(parse(eml("artist@example.com", self.PASS)))[1], "dmarc=pass")
        forged = "evil.example; dmarc=pass header.from=example.com"
        self.assertIsNone(email_in.authenticated_sender(parse(eml("artist@example.com", forged)))[0])
        lookalike = "mx.cloudflare.net.attacker; dmarc=pass header.from=example.com"
        self.assertEqual(email_in.authenticated_sender(parse(eml("victim@example.com", lookalike))),
                         (None, "no_trusted_authentication_results"))
        versioned = "mx.cloudflare.net 1; dmarc=pass header.from=example.com"
        self.assertEqual(email_in.authenticated_sender(parse(eml("artist@example.com", versioned)))[1], "dmarc=pass")
        dkim_other = "mx.cloudflare.net; dkim=pass header.d=attacker.net; dmarc=fail"
        self.assertIsNone(email_in.authenticated_sender(parse(eml("artist@example.com", dkim_other)))[0])
        dkim_ok = "mx.cloudflare.net; dkim=pass header.d=mail.example.com; dmarc=none"
        self.assertEqual(email_in.authenticated_sender(parse(eml("artist@example.com", dkim_ok)))[1], "dkim=pass aligned")

    def test_matched_by_account_never_by_text_and_spoofs_attach_nothing(self):
        from credit_verify.proof import email_in
        md = self.maildir({"1": eml("artist@example.com", self.PASS, inline_logo=True),
                           "2": eml("artist@example.com", None),
                           "3": eml("stranger@example.com", self.PASS)})
        st = email_in.run(self.store, self.users, maildir=md, runner=fake_runner)
        self.assertEqual((st.messages, st.accepted, st.files), (3, 1, 1))     # the inline logo is skipped
        self.assertEqual(st.rejected, {"no_trusted_authentication_results": 1, "no_account_with_this_email": 1})
        self.assertEqual(sorted(os.listdir(os.path.join(md, "cur"))), ["1"])
        row = self.store.db.execute("SELECT source, source_ref, contact_h FROM proofs").fetchone()
        self.assertEqual(row["source"], "email")
        self.assertEqual(row["contact_h"], email_in.user_hash(42))
        self.assertEqual(os.listdir(os.path.join(md, "new")), [])

    def test_ambiguous_or_unconfirmed_accounts_are_refused(self):
        from credit_verify.proof import email_in
        two = lambda a: [{"id": 1, "email": a}, {"id": 2, "email": a.upper()}]  # noqa: E731
        self.assertEqual(email_in.match_account("x@y.z", two)[1], "several_accounts_with_this_email")
        unconf = lambda a: [{"id": 1, "email": a, "emailConfirmed": False}]  # noqa: E731
        self.assertEqual(email_in.match_account("x@y.z", unconf)[1], "account_email_not_confirmed")
        unknown = lambda a: [{"id": 1, "email": a}]  # noqa: E731
        self.assertEqual(email_in.match_account("x@y.z", unknown)[1], "account_email_not_confirmed")
        null = lambda a: [{"id": 1, "email": a, "emailConfirmed": None}]  # noqa: E731
        self.assertEqual(email_in.match_account("x@y.z", null)[1], "account_email_not_confirmed")
        partial = lambda a: [{"id": 1, "email": "notx@y.z"}]  # noqa: E731
        self.assertEqual(email_in.match_account("x@y.z", partial)[1], "no_account_with_this_email")


    def test_account_search_reads_every_page(self):
        from credit_verify.proof import email_in
        pages = {1: [{"id": i, "email": f"x{i}@y.z"} for i in range(email_in.LOOKUP_PAGE_SIZE)],
                 2: [{"id": 7, "email": "x@y.z", "emailConfirmed": True}, {"id": 8, "email": "X@y.z"}]}

        class Admin:
            def get(self, path, params):
                return {"items": pages.get(params["page"], [])}
        acct, why = email_in.match_account("x@y.z", email_in.admin_user_lookup(Admin()))
        self.assertEqual((acct, why), (None, "several_accounts_with_this_email"))

    def test_unexhausted_or_malformed_account_search_fails_closed(self):
        from credit_review.admin import AdminError
        from credit_verify.proof import email_in

        class Endless:
            def get(self, path, params):
                return {"items": [{"id": params["page"], "email": "z@y.z"}] * email_in.LOOKUP_PAGE_SIZE}

        class Odd:
            def get(self, path, params):
                return {"rows": []}
        for admin in (Endless(), Odd()):
            with self.assertRaises(AdminError):
                email_in.admin_user_lookup(admin)("x@y.z")

    def test_lookup_failure_leaves_the_message_for_the_next_run(self):
        from credit_review.admin import AdminError
        from credit_verify.proof import email_in
        md = self.maildir({"1": eml("artist@example.com", self.PASS)})

        def down(addr):
            raise AdminError("admin GET timed out")
        st = email_in.run(self.store, down, maildir=md, runner=fake_runner)
        self.assertEqual((st.retry, st.rejected, st.files), (1, {}, 0))
        self.assertEqual(os.listdir(os.path.join(md, "new")), ["1"])
        self.assertFalse(os.path.exists(os.path.join(md, "rejected")))

    def test_undetermined_attachment_keeps_the_message_until_analysed(self):
        from credit_verify.proof import email_in
        md = self.maildir({"1": eml("artist@example.com", self.PASS)})
        st = email_in.run(self.store, self.users, maildir=md, runner=failing_runner)
        self.assertEqual((st.retry, st.verdicts), (1, {verdict.UNDETERMINED: 1}))
        self.assertEqual(os.listdir(os.path.join(md, "new")), ["1"])
        st = email_in.run(self.store, self.users, maildir=md, runner=fake_runner)
        self.assertEqual((st.retry, st.verdicts), (0, {verdict.CLEAN_UNLINKED: 1}))
        self.assertEqual(os.listdir(os.path.join(md, "cur")), ["1"])


class IntercomChannelTests(Base):
    def ask_then_file(self, asked_at: float) -> dict:
        return {"created_at": asked_at - 500, "source": {"body": "hi", "author": {"type": "user"}},
                "contacts": {"contacts": [{"id": "c9"}]},
                "conversation_parts": {"conversation_parts": [
                    {"body": "Please send a split sheet", "author": {"type": "admin"}, "created_at": asked_at},
                    {"body": "", "author": {"type": "user"}, "attachments": [{"name": "1.pdf"}],
                     "created_at": asked_at + 60}]}}

    def test_only_files_sent_after_the_ask_are_analysed(self):
        from credit_verify.proof import intercom
        root = os.path.join(self.tmp.name, "ic")
        asked_at = 1_760_000_000.0
        for notif, when in (("notif_before", asked_at - 300), ("notif_after", asked_at + 61)):
            d = os.path.join(root, "333", notif)
            os.makedirs(d)
            f = Path(d, "1.png")
            f.write_bytes(b"\x89PNG" + notif.encode())
            os.utime(f, (when, when))
        stats = intercom.run(self.store, days=3, fetch=lambda c: self.ask_then_file(asked_at), root=root,
                             runner=fake_runner, now=asked_at + 3600)
        self.assertEqual((stats["files_analysed"], stats["files_before_ask"]), (1, 1))
        refs = [r["source_ref"] for r in self.store.db.execute("SELECT source_ref FROM proofs")]
        self.assertEqual(refs, ["333/notif_after/1.png"])

    def test_undetermined_files_are_retried_a_bounded_number_of_times(self):
        from credit_verify.proof import intercom, store as store_mod
        root = os.path.join(self.tmp.name, "ic")
        d = os.path.join(root, "444", "notif_a")
        os.makedirs(d)
        Path(d, "1.png").write_bytes(b"\x89PNG444")
        doc = self.ask_then_file(0)
        run = lambda runner: intercom.run(self.store, days=3, fetch=lambda c: doc, root=root,  # noqa: E731
                                          runner=runner)
        first = run(failing_runner)
        self.assertEqual(first["verdicts"], {verdict.UNDETERMINED: 1})
        second = run(fake_runner)
        self.assertEqual(second["verdicts"], {verdict.CLEAN_UNLINKED: 1})
        self.assertEqual(run(fake_runner)["files_skipped_done"], 1)

        Path(d, "1.png").write_bytes(b"\x89PNG444-other")
        analysed = [run(failing_runner)["files_analysed"] for _ in range(store_mod.MAX_ATTEMPTS + 1)]
        self.assertEqual(analysed, [1] * store_mod.MAX_ATTEMPTS + [0])

    def test_only_files_after_a_proof_ask_count_and_renders_are_skipped(self):
        from credit_verify.proof import intercom
        root = os.path.join(self.tmp.name, "ic")
        for conv in ("111", "222"):
            d = os.path.join(root, conv, "notif_a")
            os.makedirs(d)
            Path(d, "1.png").write_bytes(b"\x89PNG" + conv.encode())
            Path(d, "2-p-1.png").write_bytes(b"render")
        docs = {
            "111": {"source": {"body": "hi", "author": {"type": "user"}}, "contacts": {"contacts": [{"id": "c1"}]},
                    "conversation_parts": {"conversation_parts": [
                        {"body": "Could you send supporting documents for this credit?", "author": {"type": "admin"}},
                        {"body": "", "author": {"type": "user"}, "attachments": [{"name": "1.png"}]}]}},
            "222": {"source": {"body": "my logo", "author": {"type": "user"}, "attachments": [{"name": "1.png"}]},
                    "contacts": {"contacts": [{"id": "c2"}]}, "conversation_parts": {"conversation_parts": []}},
        }
        stats = intercom.run(self.store, days=3, fetch=lambda c: docs[c], root=root, runner=fake_runner)
        self.assertEqual((stats["proof_conversations"], stats["files_analysed"]), (1, 1))
        again = intercom.run(self.store, days=3, fetch=lambda c: docs[c], root=root, runner=fake_runner)
        self.assertEqual((again["files_analysed"], again["files_skipped_done"]), (0, 1))
        refs = [r["source_ref"] for r in self.store.db.execute("SELECT source_ref FROM proofs")]
        self.assertEqual(refs, ["111/notif_a/1.png"])


@unittest.skipUnless(shutil.which("tesseract") and HAVE_PDF, "real tesseract + PyMuPDF (node-8 CI)")
class RealOcrTests(Base):
    def test_real_ocr_reads_a_rendered_split_sheet(self):
        path = self.write("real.pdf", pdf_bytes(SPLIT))
        [res] = analyze_proof(self.store, path, contact_h="c", source="test", source_ref="real", ctx=CTX,
                              runner=lambda p, d, c: analyze.extract(p, d, ClaimContext.from_dict(c)))
        self.assertNotIn("ocr_unavailable", {s.name for s in res.signals})
        self.assertIn(res.verdict, (verdict.GENUINE, verdict.SUSPECT), json.dumps(res.reasons))


class CronContractTests(unittest.TestCase):
    def test_proof_crons_are_shadow_commands_and_email_is_dark(self):
        jobs = json.loads((Path(__file__).resolve().parents[2] / "cron-jobs.json").read_text())["jobs"]
        mine = {j["name"]: j for j in jobs if "credit-proof.py" in " ".join(j.get("payload", {}).get("argv", []))}
        self.assertEqual(set(mine), {"credit-verify-proof-intercom", "credit-verify-proof-email"})
        for j in mine.values():
            self.assertEqual(j["payload"]["kind"], "command")
            self.assertEqual(j["delivery"], {"mode": "none"})
            self.assertTrue(all(isinstance(a, str) and a for a in j["payload"]["argv"]))
        self.assertEqual(mine["credit-verify-proof-intercom"]["payload"]["argv"][2], "intercom")
        self.assertFalse(mine["credit-verify-proof-email"]["enabled"])


class CliTests(unittest.TestCase):
    def test_kill_switch_stops_before_any_read(self):
        import importlib.util
        import io as _io
        from contextlib import redirect_stdout
        spec = importlib.util.spec_from_file_location("credit_proof_cli",
                                                      Path(__file__).resolve().parents[1] / "credit-proof.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        with tempfile.TemporaryDirectory() as d:
            ks = Path(d) / "off"
            ks.write_text("")
            cli.KILL_SWITCH = str(ks)
            buf = _io.StringIO()
            with mock.patch("credit_verify.proof.intercom.intercom_token", side_effect=AssertionError("no reads")), \
                    redirect_stdout(buf):
                rc = cli.main(["--store", str(Path(d) / "s.sqlite"), "intercom"])
        self.assertEqual((rc, buf.getvalue().strip()), (0, "NO_REPLY"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
