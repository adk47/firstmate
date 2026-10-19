"""Local OCR (tesseract CLI, TSV word boxes). No network, no model.

Raises OcrUnavailable when tesseract is not installed or fails, so the caller
records an error signal (never a silent "no text").
"""

from __future__ import annotations

import csv
import io
import os
import shutil
import subprocess
import tempfile
from typing import Any

TOOL = "tesseract"
OCR_TIMEOUT_S = int(os.environ.get("CREDIT_PROOF_OCR_TIMEOUT_S", "90"))


class OcrUnavailable(RuntimeError):
    pass


def version() -> str:
    exe = shutil.which("tesseract")
    if not exe:
        return ""
    try:
        p = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=10, check=False)
        return (p.stdout or p.stderr).splitlines()[0].strip()
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return ""


def ocr_image_bytes(png: bytes, *, page: int = 1, scale: float = 1.0) -> list[dict[str, Any]]:
    """Word boxes for one image. `scale` converts pixel boxes into the caller's
    coordinate space (e.g. 72/dpi for a rendered PDF page -> PDF points)."""
    exe = shutil.which("tesseract")
    if not exe:
        raise OcrUnavailable("tesseract is not installed")
    with tempfile.TemporaryDirectory(prefix="cvocr-") as d:
        src = os.path.join(d, "in.png")
        with open(src, "wb") as fh:
            fh.write(png)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "OMP_THREAD_LIMIT": "1", "HOME": d}
        try:
            p = subprocess.run([exe, src, "stdout", "-l", "eng", "--psm", "3", "tsv"], capture_output=True,
                               text=True, timeout=OCR_TIMEOUT_S, check=False, env=env, cwd=d)
        except subprocess.TimeoutExpired as exc:
            raise OcrUnavailable("tesseract timed out") from exc
        except OSError as exc:
            raise OcrUnavailable(str(exc)) from exc
        if p.returncode != 0:
            raise OcrUnavailable(f"tesseract rc={p.returncode}: {p.stderr.strip()[:200]}")
    words = []
    for row in csv.DictReader(io.StringIO(p.stdout), delimiter="\t", quoting=csv.QUOTE_NONE):
        if row.get("level") != "5":
            continue
        text = (row.get("text") or "").strip()
        try:
            conf = float(row.get("conf") or -1)
            x, y, w, h = (int(row[k]) for k in ("left", "top", "width", "height"))
        except (TypeError, ValueError):
            continue
        if not text or conf < 0:
            continue
        words.append({"text": text, "page": page, "conf": conf,
                      "box": [round(x * scale, 1), round(y * scale, 1), round((x + w) * scale, 1), round((y + h) * scale, 1)],
                      "line": (row.get("block_num"), row.get("par_num"), row.get("line_num"))})
    return words


def words_to_text(words: list[dict[str, Any]]) -> str:
    lines: dict[Any, list[str]] = {}
    for w in words:
        lines.setdefault((w["page"],) + tuple(w.get("line") or ()), []).append(w["text"])
    return "\n".join(" ".join(v) for v in lines.values())
