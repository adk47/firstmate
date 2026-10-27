"""F4: PDF structure, revisions, fonts, overlays and signatures (PyMuPDF).

  F4a  producer/creator (online editors), incremental updates, and what each
       later revision CHANGED: page text that differs from the first revision
       on key fields (names, %, ISRCs) is an edit after creation (soft); a
       change only in form-field values is a fill-in (info). Real data (§8):
       21/174 PDFs are incremental, many of them Preview fill-ins - telling
       the two apart is the point.
  F4b  a key field set in a font that appears nowhere else on the page (soft).
  F4c  overlays: a FreeText / filled-box / unapplied-redaction annotation over
       a key field (hard); key tokens in the text layer that the rendered page
       does not show, or the reverse (soft; needs OCR).
  F4d  signatures: the /ByteRange of each signature; bytes after the signed
       range with CHANGED page text = a post-signature content edit (hard).
       A signature counts as an issuer signal only when pyHanko validates it
       (intact, valid, covering the whole file) AND its chain is trusted
       against our explicit trust roots (TRUST_ROOTS_DIR: reviewed PEM/DER
       certificates in the repo; none today), AND the signer is not the
       claimant. A valid but untrusted (e.g. self-signed) signature is info.
       Without pyHanko or without trust roots nothing becomes A3.
Also extracts per-page text (text layer, or OCR for scans) for F5.
"""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path
from typing import Any

from . import ocr
from .signals import ERROR, HARD, INFO, ISSUER, SOFT, Evidence, Extracted, Signal

try:
    import pymupdf  # type: ignore
except ImportError:  # pragma: no cover - older PyMuPDF
    try:
        import fitz as pymupdf  # type: ignore
    except ImportError:
        pymupdf = None  # type: ignore

TOOL = "pymupdf"
OCR_DPI = 200
MAX_PAGES = 20
OCR_PAGES = 4          # pages OCR'd when the PDF has a text layer (overlay diff only)
SCAN_OCR_PAGES = 6     # pages OCR'd for a scan (replay: 10-76 page scans ran past the sandbox time limit)

ONLINE_EDITORS = re.compile(r"ilovepdf|smallpdf|sejda|pdfescape|pdffiller|pdfgear|pdf candy|pdf2go|sodapdf|"
                            r"pdfsimpli|dochub|formswift|pdf\.io|pdfzorro|lightpdf|hipdf|pdfbuddy|xodo|"
                            r"online2pdf|pdf24", re.I)
ESIGN_VENDORS = re.compile(rb"DocuSign|Adobe Sign|Adobe Acrobat Sign|EchoSign|HelloSign|Dropbox Sign|PandaDoc|"
                           rb"SignNow|SignRequest|Yousign|eversign|Zoho Sign|OneSpan|SignEasy")
BYTE_RANGE = re.compile(rb"/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]")

TRUST_ROOTS_DIR = Path(__file__).resolve().parent / "trust_roots"

KEY_TOKEN = re.compile(r"\b\d{1,3}(?:[.,]\d{1,2})?\s?%|\b[A-Z]{2}-?[A-Z0-9]{3}-?\d{2}-?\d{5}\b|\b\d{1,3}(?:,\d{3})+\b")


def available() -> bool:
    return pymupdf is not None


def tool_version() -> str:
    return f"PyMuPDF {getattr(pymupdf, 'VersionBind', '?')}" if pymupdf else ""


def _ev(path: str, **kw: Any) -> Evidence:
    return Evidence(**{"file": path, "tool": TOOL, "tool_version": tool_version(), **kw})


def _open(data: bytes):
    return pymupdf.open(stream=data, filetype="pdf")


def _page_texts(doc) -> list[str]:
    return [doc[i].get_text() for i in range(min(doc.page_count, MAX_PAGES))]


def _widget_values(doc) -> dict[str, str]:
    vals: dict[str, str] = {}
    for i in range(min(doc.page_count, MAX_PAGES)):
        for w in doc[i].widgets() or []:
            vals[f"{i}:{w.field_name}"] = str(w.field_value or "")
    return vals


def _words(text: str) -> Counter:
    return Counter(re.findall(r"[^\s]+", text))


def key_tokens(text: str) -> set[str]:
    return {re.sub(r"\s", "", m.group(0)) for m in KEY_TOKEN.finditer(text or "")}


def _key_like(tokens: set[str], names: list[str]) -> set[str]:
    folded = [n.lower() for n in names if n]
    out = set()
    for t in tokens:
        if KEY_TOKEN.fullmatch(t) or re.fullmatch(r"\d{1,3}(?:[.,]\d{1,2})?%", t):
            out.add(t)
        elif any(t.lower() in n.split() for n in folded if len(t) > 2):
            out.add(t)
    return out


def _first_rect(page, token: str) -> list[float] | None:
    try:
        hits = page.search_for(token)
    except Exception:  # noqa: BLE001
        return None
    if not hits:
        return None
    r = hits[0]
    return [round(r.x0, 1), round(r.y0, 1), round(r.x1, 1), round(r.y1, 1)]


def _revision_ends(data: bytes) -> list[int]:
    ends = [m.end() for m in re.finditer(rb"%%EOF", data)]
    if b"/Linearized" in data[:2048] and len(ends) >= 2:
        ends = ends[1:]          # the first %%EOF of a linearized file ends the hint section, not a revision
    return ends


def _compare_revision(old: bytes, final_doc, path: str, names: list[str], label: str,
                      severity_text: str) -> list[Signal]:
    """Signals for what changed between an earlier revision and the final file."""
    try:
        odoc = _open(old)
    except Exception as exc:  # noqa: BLE001
        return [Signal("F4a", f"{label}_revision_unreadable", ERROR, value=str(exc)[:160], evidence=_ev(path))]
    out: list[Signal] = []
    try:
        changed_pages = []
        pages = odoc.page_count if label == "signature" else final_doc.page_count
        for i in range(min(pages, final_doc.page_count, MAX_PAGES)):
            new_t = final_doc[i].get_text()
            old_t = odoc[i].get_text() if i < odoc.page_count else ""
            nw, ow = _words(new_t), _words(old_t)
            if nw != ow:
                added, removed = nw - ow, ow - nw
                keys = _key_like(set(added) | set(removed), names)
                changed_pages.append((i, sum(added.values()), sum(removed.values()), keys))
        widgets_changed = _widget_values(odoc) != _widget_values(final_doc)
    finally:
        odoc.close()
    for i, n_add, n_rem, keys in changed_pages:
        region = None
        for t in sorted(keys):
            region = _first_rect(final_doc[i], t)
            if region:
                break
        key = bool(keys)
        # After a signature ANY change to the signed pages' text is an edit of
        # a signed document (report §7.1 F4d); after creation only key fields
        # count, the rest is recorded.
        sev = HARD if label == "signature" else (severity_text if key else INFO)
        if label == "signature" and not key and n_rem == 0 and n_add <= 3:
            sev = SOFT        # a stamp or date added after signing (replay: an envelope id on one page)
        out.append(Signal("F4a" if label == "creation" else "F4d",
                          f"{'post_signature' if label == 'signature' else 'after_creation'}_"
                          f"{'key_field_edit' if key else 'text_edit'}",
                          sev, value={"page": i + 1, "words_added": n_add, "words_removed": n_rem,
                                      "key_fields_changed": len(keys)},
                          reason=("The document was changed after it was signed." if label == "signature" and key
                                  else ""),
                          evidence=_ev(path, page=i + 1, region=region)))
    if not changed_pages and widgets_changed:
        out.append(Signal("F4a" if label == "creation" else "F4d",
                          "form_fill_after_creation" if label == "creation" else "post_signature_form_fill",
                          INFO, evidence=_ev(path)))
    return out


def _trust_roots() -> list[Any]:
    paths = sorted(p for p in TRUST_ROOTS_DIR.glob("*") if p.suffix.lower() in (".pem", ".crt", ".cer", ".der"))
    if not paths:
        return []
    from pyhanko.keys import load_certs_from_pemder  # type: ignore
    return list(load_certs_from_pemder([str(p) for p in paths]))


def _validate_signatures(data: bytes) -> list[dict[str, Any]] | None:
    """pyHanko validation when installed:
    [{intact, valid, trusted, covers_whole, signer}]. `trusted` (pyHanko's
    bottom_line: intact, valid AND chained to a trust root) is only ever true
    against our explicit roots - with none configured, no chain is trusted
    (pyHanko would otherwise fall back to the host's TLS trust store)."""
    try:
        from pyhanko.pdf_utils.reader import PdfFileReader  # type: ignore
        from pyhanko.sign.validation import validate_pdf_signature  # type: ignore
        from pyhanko_certvalidator import ValidationContext  # type: ignore
    except ImportError:
        return None
    import io
    out = []
    try:
        roots = _trust_roots()
        r = PdfFileReader(io.BytesIO(data))
        for emb in r.embedded_signatures:
            vc = (ValidationContext(trust_roots=roots, allow_fetching=False) if roots
                  else ValidationContext(allow_fetching=False))
            st = validate_pdf_signature(emb, vc)
            out.append({"intact": bool(st.intact), "valid": bool(st.valid),
                        "trusted": bool(roots) and bool(getattr(st, "bottom_line", False)),
                        "covers_whole": str(getattr(st, "coverage", "")).endswith("ENTIRE_FILE"),
                        "signer": str(getattr(st.signing_cert, "subject", "").human_friendly)[:120]
                        if getattr(st, "signing_cert", None) else ""})
    except Exception as exc:  # noqa: BLE001
        return [{"error": str(exc)[:160]}]
    return out


def signature_signals(checks: list[dict[str, Any]], names: list[str], path: str) -> list[Signal]:
    """Issuer only for an intact, valid, TRUSTED signature over the whole file
    by someone other than the claimant (whose names must be known to tell)."""
    out = []
    for c in checks:
        if "error" in c:
            out.append(Signal("F4d", "signature_validation_failed", ERROR, value=c["error"],
                              evidence=Evidence(file=path, tool="pyhanko")))
            continue
        if not c.get("intact"):
            out.append(Signal("F4d", "signature_not_intact", SOFT, value=c, evidence=_ev(path)))
            continue
        if not (c.get("valid") and c.get("covers_whole")):
            continue
        signer = (c.get("signer") or "").lower()
        other_party = bool(names) and not any(n and n.lower() in signer for n in names)
        if c.get("trusted") and other_party:
            out.append(Signal("F4d", "valid_other_party_signature", ISSUER, value={"signer": c.get("signer")},
                              evidence=Evidence(file=path, tool="pyhanko")))
        else:
            out.append(Signal("F4d", "signature_valid_not_issuer", INFO,
                              value={"signer": c.get("signer"), "trusted": bool(c.get("trusted")),
                                     "other_party": other_party},
                              evidence=Evidence(file=path, tool="pyhanko")))
    return out


def analyze(data: bytes, path: str, names: list[str] | None = None) -> tuple[list[Signal], Extracted, dict[str, Any]]:
    names = names or []
    ext = Extracted()
    if pymupdf is None:
        return [Signal("F4a", "pdf_tool_unavailable", ERROR, evidence=Evidence(file=path, tool=TOOL))], ext, {}
    sig: list[Signal] = []
    try:
        doc = _open(data)
    except Exception as exc:  # noqa: BLE001
        return [Signal("F4a", "pdf_unreadable", ERROR, value=str(exc)[:160], evidence=_ev(path))], ext, {}
    try:
        if doc.needs_pass:
            return [Signal("F1", "reject_encrypted_pdf", SOFT, reason="The PDF is password-protected.",
                           evidence=_ev(path))], ext, {}
        meta = doc.metadata or {}
        producer, creator = meta.get("producer") or "", meta.get("creator") or ""
        facts: dict[str, Any] = {"pages": doc.page_count, "producer": producer[:120], "creator": creator[:120]}
        for field_name, val in (("Producer", producer), ("Creator", creator)):
            if ONLINE_EDITORS.search(val):
                sig.append(Signal("F4a", "online_editor_producer", SOFT, value=val[:120],
                                  evidence=_ev(path, excerpt=field_name)))
        sig.append(Signal("F4a", "pdf_producer", INFO, value={"producer": producer[:120], "creator": creator[:120]},
                          evidence=_ev(path)))
        cd, md = meta.get("creationDate") or "", meta.get("modDate") or ""
        facts["created"], facts["modified"] = cd[:24], md[:24]
        if cd and md and cd[:16] != md[:16]:
            sig.append(Signal("F4a", "modified_after_creation_date", INFO, value={"created": cd[:16], "modified": md[:16]},
                              evidence=_ev(path)))

        # -- signatures (F4d) -----------------------------------------------
        ranges = [tuple(int(x) for x in m.groups()) for m in BYTE_RANGE.finditer(data)]
        vendors = sorted({v.decode() for v in ESIGN_VENDORS.findall(data)})
        facts["signatures"] = len(ranges)
        if vendors:
            sig.append(Signal("F4d", "esign_vendor", INFO, value=vendors, evidence=_ev(path)))
        signed_end = 0
        valid_ranges = []
        for a, b, c, d in ranges:
            end = c + d
            # A real ByteRange brackets the signature's <hex> /Contents in THIS
            # file. A file re-saved or merged after signing (replay: a pypdf
            # merge of signed contracts) keeps the old /ByteRange numbers,
            # which then point at unrelated bytes: those signatures no longer
            # cover the file and cannot be checked.
            if not (a == 0 and b < c <= end <= len(data) and data[b:b + 1] == b"<" and data[c - 1:c] == b">"):
                sig.append(Signal("F4d", "signature_not_covering_this_file", INFO, value={"byte_range": [a, b, c, d]},
                                  evidence=_ev(path)))
                continue
            valid_ranges.append((a, b, c, d))
            signed_end = max(signed_end, end)
            sig.append(Signal("F4d", "signature_present", INFO, value={"byte_range": [a, b, c, d]},
                              evidence=_ev(path, byte_range=[a, end])))
        ranges = valid_ranges
        if ranges and len(data.rstrip()) > signed_end + 2:
            sig.extend(_compare_revision(data[:signed_end], doc, path, names, "signature", HARD))
        if ranges:
            checks = _validate_signatures(data)
            if checks is None:
                sig.append(Signal("F4d", "signature_unvalidated", INFO, value="pyHanko not installed",
                                  evidence=_ev(path)))
            else:
                sig.extend(signature_signals(checks, names, path))

        # -- revisions (F4a) ------------------------------------------------
        ends = _revision_ends(data)
        incremental = max(0, len(ends) - 1)
        facts["incremental_updates"] = incremental
        if incremental:
            sig.append(Signal("F4a", "incremental_update", INFO, value=incremental,
                              evidence=_ev(path, byte_range=[ends[0], len(data)])))
            first_end = ends[0]
            # Skip when the first revision IS the signed one (compared above).
            if not ranges or first_end < min(c + d for _a, _b, c, d in ranges) - 16:
                sig.extend(_compare_revision(data[:first_end], doc, path, names, "creation", SOFT))

        # -- text, fonts, overlays ------------------------------------------
        ext.pages_text = _page_texts(doc)
        ext.layer_words = _layer_words(doc)
        ext.text_source = "pdf_text"
        has_layer = sum(len(t.strip()) for t in ext.pages_text) >= 50
        inspected = min(doc.page_count, MAX_PAGES if has_layer else SCAN_OCR_PAGES)
        if doc.page_count > inspected:
            # Pages past the cap are never read, so they cannot be cleared:
            # an error (UNDETERMINED), never a clean verdict on part of a file.
            sig.append(Signal("F4a", "pages_not_inspected", ERROR,
                              value={"pages": doc.page_count, "inspected": inspected},
                              evidence=_ev(path, page=inspected + 1)))
        for i in range(min(doc.page_count, MAX_PAGES)):
            page = doc[i]
            sig.extend(_fonts(page, path, i, names))
            sig.extend(_annots(page, path, i))
        if doc.page_count:
            sig.extend(_ocr_pages(doc, path, ext, has_layer))
        facts["text_layer"] = has_layer
        return sig, ext, facts
    finally:
        doc.close()


def _layer_words(doc) -> list[dict[str, Any]]:
    out = []
    for i in range(min(doc.page_count, MAX_PAGES)):
        for w in doc[i].get_text("words"):
            out.append({"text": w[4], "page": i + 1, "box": [round(w[0], 1), round(w[1], 1), round(w[2], 1),
                                                             round(w[3], 1)]})
    return out


def _fonts(page, path: str, i: int, names: list[str]) -> list[Signal]:
    try:
        d = page.get_text("dict")
    except Exception as exc:  # noqa: BLE001
        return [Signal("F4b", "fonts_unreadable", ERROR, value=str(exc)[:160], evidence=_ev(path, page=i + 1))]
    spans = [s for b in d.get("blocks", []) for ln in b.get("lines", []) for s in ln.get("spans", [])
             if (s.get("text") or "").strip()]
    if len(spans) < 6:
        return []
    count: dict[str, int] = {}
    for s in spans:
        count[font_family(s.get("font", ""))] = count.get(font_family(s.get("font", "")), 0) + 1
    out = []
    for s in spans:
        t = s.get("text") or ""
        fam = font_family(s.get("font", ""))
        if not fam or fam.startswith("type3"):
            continue          # Type3 glyph fonts come from scanners/OCR and print drivers
        is_key = bool(KEY_TOKEN.search(t)) or any(n and len(n) > 3 and n.lower() in t.lower() for n in names)
        if is_key and count.get(fam, 0) == 1 and len(count) >= 2:
            bb = s.get("bbox") or [0, 0, 0, 0]
            out.append(Signal("F4b", "key_field_unique_font", SOFT, value={"font": (s.get("font") or "")[:60]},
                              evidence=_ev(path, page=i + 1, region=[round(v, 1) for v in bb])))
    return out[:5]


def font_family(font: str) -> str:
    """Family without subset prefix and style: 'ABCDEF+Arial-BoldItalicMT' ->
    'arial'. A bold total line is the same family as the body text."""
    f = re.sub(r"^[A-Z]{6}\+", "", font or "")
    f = re.split(r"[-,]", f)[0]
    f = re.sub(r"(MT|PS|Bold|Italic|Oblique|Regular|Light|Medium|Semibold|Black)+$", "", f, flags=re.I)
    return f.lower().strip()


OVERLAY_ANNOTS = {"FreeText": "freetext", "Square": "filled_box", "Redact": "unapplied_redaction", "Stamp": "stamp"}


def _annots(page, path: str, i: int) -> list[Signal]:
    out = []
    try:
        annots = list(page.annots() or [])
        if not annots:
            return out
        spans = [s for b in page.get_text("dict").get("blocks", []) for ln in b.get("lines", [])
                 for s in ln.get("spans", []) if KEY_TOKEN.search(s.get("text") or "")]
    except Exception as exc:  # noqa: BLE001
        return [Signal("F4c", "annotations_unreadable", ERROR, value=str(exc)[:160], evidence=_ev(path, page=i + 1))]
    for a in annots:
        kind = OVERLAY_ANNOTS.get(a.type[1] if isinstance(a.type, tuple) else str(a.type))
        if not kind:
            continue
        if kind == "filled_box" and not (a.colors or {}).get("fill"):
            continue
        r = a.rect
        over_key = any(pymupdf.Rect(s["bbox"]).intersects(r) for s in spans)
        out.append(Signal("F4c", f"overlay_{kind}_on_key_field" if over_key else f"annotation_{kind}",
                          HARD if over_key else INFO,
                          reason="Something was placed over a key field of the document." if over_key else "",
                          evidence=_ev(path, page=i + 1, region=[round(r.x0, 1), round(r.y0, 1), round(r.x1, 1), round(r.y1, 1)])))
    return out


def _ocr_pages(doc, path: str, ext: Extracted, has_layer: bool) -> list[Signal]:
    out: list[Signal] = []
    ocr_texts = []
    limit = OCR_PAGES if has_layer else SCAN_OCR_PAGES
    for i in range(min(doc.page_count, limit)):
        try:
            png = doc[i].get_pixmap(dpi=OCR_DPI).tobytes("png")
            words = ocr.ocr_image_bytes(png, page=i + 1, scale=72 / OCR_DPI)
        except ocr.OcrUnavailable as exc:
            out.append(Signal("F4c", "ocr_unavailable", ERROR, value=str(exc)[:160],
                              evidence=Evidence(file=path, tool=ocr.TOOL)))
            return out
        except Exception as exc:  # noqa: BLE001
            out.append(Signal("F4c", "render_failed", ERROR, value=str(exc)[:160], evidence=_ev(path, page=i + 1)))
            return out
        ext.ocr_words += words
        ocr_texts.append(ocr.words_to_text(words))
        if has_layer:
            layer = key_tokens(ext.pages_text[i])
            seen = key_tokens(" ".join(w["text"] for w in words))
            hidden = layer - seen
            pasted = seen - layer
            # INFO until calibrated: on the 2026-10-15 Intercom replay every
            # diff inspected was OCR noise (a struck-through "$1,200" read as
            # "4,200" on a pricing page). Overlays are caught by _annots.
            if hidden:
                out.append(Signal("F4c", "key_text_not_rendered", INFO, value={"tokens": len(hidden)},
                                  evidence=Evidence(file=path, tool=ocr.TOOL, tool_version=ocr.version(), page=i + 1,
                                                    region=_first_rect(doc[i], sorted(hidden)[0]))))
            if pasted:
                box = next((w["box"] for w in words if re.sub(r"\s", "", w["text"]) in pasted), None)
                out.append(Signal("F4c", "rendered_key_text_not_in_layer", INFO, value={"tokens": len(pasted)},
                                  evidence=Evidence(file=path, tool=ocr.TOOL, tool_version=ocr.version(), page=i + 1,
                                                    region=box)))
    if not has_layer:
        ext.pages_text = ocr_texts
        ext.text_source = "ocr"
    return out
