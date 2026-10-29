"""Image text (OCR) and F3b pixel forensics.

  * OCR of the image (tesseract) feeds the content checks (F5) and the portal
    template checks (F3c).
  * F3b error-level analysis, JPEG only: re-save at quality 90 and compare the
    error level of the KEY-FIELD word boxes (numbers, %, ISRCs) with the other
    text on the same image. A key field whose error level stands far above the
    rest was likely pasted in -> soft (never decisive alone).
  * F3b copy-move, photos only (camera EXIF): screenshots repeat UI elements by
    design, so keypoint self-matches there are noise and are not run.
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import tempfile
from typing import Any

from . import ocr
from .pdf_forensics import KEY_TOKEN, key_field_class
from .signals import ERROR, SOFT, Evidence, Extracted, Signal

TOOL = "opencv"
ELA_QUALITY = 90
ELA_Z = 4.0
OCR_MAX_SIDE = 1800     # phone photos are 4032 px; tesseract timed out on them in the replay


def ocr_ready(png: bytes) -> tuple[bytes, float]:
    """A copy no larger than OCR_MAX_SIDE, and the factor that maps its boxes
    back to original pixels."""
    from PIL import Image
    with Image.open(io.BytesIO(png)) as im:
        w, h = im.size
        if max(w, h) <= OCR_MAX_SIDE:
            return png, 1.0
        f = OCR_MAX_SIDE / max(w, h)
        buf = io.BytesIO()
        im.convert("RGB").resize((int(w * f), int(h * f))).save(buf, format="PNG")
        return buf.getvalue(), 1 / f


def heic_to_jpeg(data: bytes) -> bytes:
    """HEIC -> JPEG with heif-convert (keeps EXIF), for metadata and OCR."""
    exe = shutil.which("heif-convert")
    if not exe:
        raise RuntimeError("heif-convert not installed")
    with tempfile.TemporaryDirectory(prefix="cvheic-") as d:
        src, dst = os.path.join(d, "in.heic"), os.path.join(d, "out.jpg")
        with open(src, "wb") as fh:
            fh.write(data)
        subprocess.run([exe, "-q", "95", src, dst], capture_output=True, timeout=60, check=True)
        with open(dst, "rb") as fh:
            return fh.read()


def to_png(data: bytes, mime: str) -> bytes:
    """PNG bytes for OCR / analysis. HEIC goes through heif-convert."""
    if mime == "image/png":
        return data
    if mime == "image/heic":
        data = heic_to_jpeg(data)
    from PIL import Image
    with Image.open(io.BytesIO(data)) as im:
        buf = io.BytesIO()
        im.convert("RGB").save(buf, format="PNG")
        return buf.getvalue()


def _cv_version() -> str:
    try:
        import cv2
        return f"OpenCV {cv2.__version__}"
    except ImportError:
        return ""


def analyze(data: bytes, path: str, mime: str, camera: bool) -> tuple[list[Signal], Extracted]:
    ext = Extracted()
    sig: list[Signal] = []
    try:
        png = to_png(data, mime)
    except Exception as exc:  # noqa: BLE001
        return [Signal("F3b", "decode_failed", ERROR, value=str(exc)[:160], evidence=Evidence(file=path, tool="pillow"))], ext
    try:
        small, back = ocr_ready(png)
        ext.ocr_words = ocr.ocr_image_bytes(small, page=1, scale=back)
        ext.pages_text = [ocr.words_to_text(ext.ocr_words)]
        ext.text_source = "ocr"
    except ocr.OcrUnavailable as exc:
        sig.append(Signal("F3b", "ocr_unavailable", ERROR, value=str(exc)[:160], evidence=Evidence(file=path, tool=ocr.TOOL)))
    if mime == "image/jpeg" and ext.ocr_words:
        sig.extend(ela(data, path, ext.ocr_words))
    if camera:
        sig.extend(copy_move(png, path))
    return sig, ext


def ela(jpeg: bytes, path: str, words: list[dict[str, Any]]) -> list[Signal]:
    try:
        import numpy as np
        from PIL import Image
    except ImportError as exc:
        return [Signal("F3b", "ela_unavailable", ERROR, value=str(exc)[:160], evidence=Evidence(file=path, tool="pillow"))]
    try:
        with Image.open(io.BytesIO(jpeg)) as im:
            rgb = im.convert("RGB")
            buf = io.BytesIO()
            rgb.save(buf, format="JPEG", quality=ELA_QUALITY)
            with Image.open(io.BytesIO(buf.getvalue())) as re_im:
                diff = np.abs(np.asarray(rgb, dtype=np.int16)
                              - np.asarray(re_im.convert("RGB"), dtype=np.int16)).sum(axis=2)
    except Exception as exc:  # noqa: BLE001
        return [Signal("F3b", "ela_failed", ERROR, value=str(exc)[:160], evidence=Evidence(file=path, tool="pillow"))]

    def level(box: list[float]) -> float | None:
        x0, y0, x1, y1 = (int(v) for v in box)
        patch = diff[max(0, y0):max(0, y1), max(0, x0):max(0, x1)]
        return float(patch.mean()) if patch.size else None

    key, other = [], []
    for w in words:
        lv = level(w["box"])
        if lv is None:
            continue
        (key if KEY_TOKEN.search(w["text"]) else other).append((lv, w))
    if len(other) < 10 or not key:
        return []
    vals = np.array([lv for lv, _ in other])
    mu, sd = float(vals.mean()), float(vals.std()) or 1.0
    out = []
    for lv, w in key:
        z = (lv - mu) / sd
        if z >= ELA_Z:
            out.append(Signal("F3b", "ela_outlier_on_key_field", SOFT,
                              value={"z": round(z, 1), "field": key_field_class(w["text"], [])},
                              evidence=Evidence(file=path, tool="pillow-ela", tool_version=f"q{ELA_QUALITY}",
                                                region=w["box"])))
    return out[:3]


def copy_move(png: bytes, path: str, min_matches: int = 12) -> list[Signal]:
    try:
        import cv2
        import numpy as np
    except ImportError as exc:
        return [Signal("F3b", "copy_move_unavailable", ERROR, value=str(exc)[:160], evidence=Evidence(file=path, tool=TOOL))]
    img = cv2.imdecode(np.frombuffer(png, np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return [Signal("F3b", "copy_move_decode_failed", ERROR, evidence=Evidence(file=path, tool=TOOL,
                                                                                 tool_version=_cv_version()))]
    orb = cv2.ORB_create(nfeatures=3000)
    kps, des = orb.detectAndCompute(img, None)
    if des is None or len(kps) < 50:
        return []
    matches = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(des, des, k=3)
    shifts: dict[tuple[int, int], list[tuple[float, float]]] = {}
    for group in matches:
        for m in group[1:]:          # group[0] is the keypoint matching itself
            if m.distance > 20:
                continue
            p, q = kps[m.queryIdx].pt, kps[m.trainIdx].pt
            dx, dy = q[0] - p[0], q[1] - p[1]
            if (dx * dx + dy * dy) ** 0.5 < 40:
                continue
            shifts.setdefault((int(dx // 8), int(dy // 8)), []).append(p)
    if not shifts:
        return []
    best, pts = max(shifts.items(), key=lambda kv: len(kv[1]))
    if len(pts) < min_matches:
        return []
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return [Signal("F3b", "copy_move_region", SOFT, value={"matches": len(pts), "shift_px": [best[0] * 8, best[1] * 8]},
                   evidence=Evidence(file=path, tool=TOOL, tool_version=_cv_version(),
                                     region=[round(min(xs)), round(min(ys)), round(max(xs)), round(max(ys))]))]
