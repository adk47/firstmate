"""F1: what the bytes really are, and whether the file is safe to inspect.

The declared type (extension / Content-Type) is never trusted. A file that is
not an image or PDF we accept, carries an executable payload (PDF JavaScript,
launch actions, embedded files) or hides a second format (a polyglot) is
REJECTED as a file: it is not inspected further and does not count as proof.
That is a statement about the file, not the claim.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .signals import ERROR, INFO, SOFT, Evidence, Signal

TOOL = "credit_verify.sniff"
MAX_PIXELS = 60_000_000      # ~ 7746 x 7746; larger is a decompression bomb, not a screenshot

ACCEPTED = ("image/png", "image/jpeg", "image/webp", "image/heic", "application/pdf")


@dataclass
class Sniffed:
    mime: str | None
    declared: str | None
    signals: list[Signal]

    @property
    def rejected(self) -> bool:
        return any(s.name.startswith("reject_") for s in self.signals)


def magic(head: bytes) -> str | None:
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    if head[4:8] == b"ftyp" and head[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"heim", b"heis", b"hevc"):
        return "image/heic"
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if b"%PDF-" in head[:1024]:
        return "application/pdf"
    if head.startswith(b"PK\x03\x04"):
        return "application/zip"
    if head.startswith((b"MZ", b"\x7fELF")) or head[:2] == b"#!":
        return "application/x-executable"
    lowered = head[:512].lstrip().lower()
    if lowered.startswith((b"<!doctype html", b"<html", b"<svg", b"<?xml")):
        return "text/markup"
    return None


DECLARED_BY_EXT = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
                   ".heic": "image/heic", ".heif": "image/heic", ".pdf": "application/pdf"}

# PDF names that launch programs or carry other files: the file is rejected.
PDF_ACTIVE = {
    b"/Launch": "pdf_launch_action", b"/EmbeddedFile": "pdf_embedded_file", b"/RichMedia": "pdf_rich_media",
    b"/ImportData": "pdf_import_data",
}
# Form scripting is common in genuine fillable split sheets and contracts
# (Intercom replay 2026-10-15: 11 of ~300 proof PDFs carry /JS, all form
# calculations), and nothing here executes it (MuPDF runs no JavaScript), so
# it is recorded, not rejected.
PDF_SCRIPTED = {b"/JavaScript": "pdf_javascript", b"/JS": "pdf_javascript", b"/XFA": "pdf_xfa_form",
                b"/SubmitForm": "pdf_submit_form"}


def sniff(data: bytes, path: str, declared: str | None = None) -> Sniffed:
    ev = Evidence(file=path, tool=TOOL)
    sig: list[Signal] = []
    if not data:
        return Sniffed(None, declared, [Signal("F1", "reject_empty_file", SOFT, reason="The file is empty.", evidence=ev)])
    mime = magic(data[:4096])
    ext = re.search(r"\.[A-Za-z0-9]{2,5}$", path)
    declared = declared or (DECLARED_BY_EXT.get(ext.group(0).lower()) if ext else None)
    if mime not in ACCEPTED:
        sig.append(Signal("F1", "reject_unaccepted_type", SOFT, value=mime or "unknown",
                          reason="This file type can't be checked; please send a PDF or an image.", evidence=ev))
        return Sniffed(mime, declared, sig)
    if declared and declared != mime:
        sig.append(Signal("F1", "declared_type_differs", INFO, value={"declared": declared, "actual": mime}, evidence=ev))

    if mime == "application/pdf":
        pdf_at = data.find(b"%PDF-")
        if pdf_at > 0:
            sig.append(Signal("F1", "reject_polyglot", SOFT, value={"pdf_header_offset": pdf_at},
                              evidence=Evidence(file=path, tool=TOOL, byte_range=[0, pdf_at])))
        for token, name in PDF_ACTIVE.items():
            for m in re.finditer(re.escape(token) + rb"(?![A-Za-z])", data):
                sig.append(Signal("F1", f"reject_{name}", SOFT, value=token.decode(),
                                  reason="The PDF contains active content, so it can't be checked safely.",
                                  evidence=Evidence(file=path, tool=TOOL, byte_range=[m.start(), m.end()])))
                break
        for token, name in PDF_SCRIPTED.items():
            m = re.search(re.escape(token) + rb"(?![A-Za-z])", data)
            if m:
                sig.append(Signal("F1", name, INFO, value=token.decode(),
                                  evidence=Evidence(file=path, tool=TOOL, byte_range=[m.start(), m.end()])))
    else:
        for marker, name in ((b"%PDF-", "pdf"), (b"PK\x03\x04", "zip"), (b"<script", "script")):
            at = data.find(marker, 16)
            if at > 0:
                sig.append(Signal("F1", "reject_polyglot", SOFT, value={"embedded": name, "offset": at},
                                  evidence=Evidence(file=path, tool=TOOL, byte_range=[at, at + len(marker)])))
                break
        trail = _trailing_bytes(data, mime)
        if trail > 1024:
            sig.append(Signal("F1", "trailing_data", INFO, value=trail,
                              evidence=Evidence(file=path, tool=TOOL, byte_range=[len(data) - trail, len(data)])))
        dims = _dimensions(data, mime)
        if dims is None and mime in ("image/png", "image/jpeg"):
            sig.append(Signal("F1", "dimensions_unreadable", ERROR, evidence=ev))
        elif dims is not None:
            w, h = dims
            if w <= 0 or h <= 0 or w * h > MAX_PIXELS:
                sig.append(Signal("F1", "reject_pixel_bounds", SOFT, value={"width": w, "height": h},
                                  reason="The image size is not one we can check.", evidence=ev))
    return Sniffed(mime, declared, sig)


def _trailing_bytes(data: bytes, mime: str) -> int:
    if mime == "image/png":
        end = data.rfind(b"IEND")
        return max(0, len(data) - (end + 8)) if end >= 0 else 0
    if mime == "image/jpeg":
        end = data.rfind(b"\xff\xd9")
        return max(0, len(data) - (end + 2)) if end >= 0 else 0
    return 0


def _dimensions(data: bytes, mime: str) -> tuple[int, int] | None:
    """Header-only dimensions, read before any decoder touches the pixels."""
    if mime == "image/png" and len(data) >= 24 and data[12:16] == b"IHDR":
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if mime == "image/jpeg":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg = int.from_bytes(data[i + 2:i + 4], "big")
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
            i += 2 + seg
        return None
    return None
