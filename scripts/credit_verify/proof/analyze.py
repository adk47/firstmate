"""Per-file extraction: everything that touches the untrusted bytes.

Runs INSIDE the sandbox (sandbox.py) as `python3 -m credit_verify.proof.analyze`
reading one JSON request on stdin (the file's bytes plus the path it cites as
evidence) and printing one JSON result on stdout. It opens no host file,
writes only temp files, and needs no network, no credentials and no database. Store access, reuse matching and the verdict
happen in the parent (pipeline.py).
"""

from __future__ import annotations

import base64
import json
import os
import sys
from typing import Any

from . import FORENSICS_VERSION, content, fingerprint, image_forensics, image_meta, pdf_forensics
from .signals import ERROR, ClaimContext, Evidence, Extracted, Signal
from .sandbox import MAX_BYTES
from .sniff import sniff


def extract(path: str, declared: str | None, ctx: ClaimContext) -> dict[str, Any]:
    with open(path, "rb") as fh:
        return extract_bytes(fh.read(MAX_BYTES + 1), path, declared, ctx)


def extract_bytes(data: bytes, path: str, declared: str | None, ctx: ClaimContext) -> dict[str, Any]:
    """`path` is only the label cited as evidence (and its extension the
    declared type hint); the bytes are `data`."""
    out: dict[str, Any] = {"version": FORENSICS_VERSION, "bytes": len(data), "sha256": fingerprint.sha256(data)}
    signals: list[Signal] = []
    if len(data) > MAX_BYTES:
        signals.append(Signal("F1", "reject_too_large", "soft", value=len(data),
                              reason="The file is too large to check."))
        out.update(signals=[s.as_dict() for s in signals], mime=None)
        return out
    sn = sniff(data, path, declared)
    signals += sn.signals
    out["mime"] = sn.mime
    if sn.rejected:
        out["signals"] = [s.as_dict() for s in signals]
        return out
    ext = Extracted()
    facts: dict[str, Any] = {}
    phash: int | None = None
    if sn.mime == "application/pdf":
        s, ext, facts = pdf_forensics.analyze(data, path, ctx.claimant_names)
        signals += s
    else:
        decoded = None
        if sn.mime == "image/heic":
            try:
                decoded = image_forensics.heic_to_jpeg(data)
            except Exception as exc:  # noqa: BLE001
                signals.append(Signal("F3a", "heic_decode_failed", ERROR, value=str(exc)[:160],
                                      evidence=Evidence(file=path, tool="heif-convert")))
        s, facts = image_meta.analyze(data, path, sn.mime or "", decoded)
        signals += s
        s2, ext = image_forensics.analyze(data, path, sn.mime or "", bool(facts.get("camera")))
        signals += s2
        try:
            phash = fingerprint.phash64(image_forensics.to_png(data, sn.mime or ""))
        except Exception as exc:  # noqa: BLE001
            signals.append(Signal("F2", "phash_unavailable", ERROR, value=f"{type(exc).__name__}: {exc}"[:160],
                                  evidence=Evidence(file=path, tool="credit_verify.fingerprint")))
    s3, ents = content.analyze(ext, ctx, path)
    signals += s3
    sh = fingerprint.shingles(ext.text)
    out.update(
        signals=[s.as_dict() for s in signals],
        kind=ext.kind,
        track_listed=ext.track_listed,
        text_source=ext.text_source,
        phash=phash,
        minhash=fingerprint.minhash(sh),
        n_shingles=len(sh),
        entities=ents,
        facts={k: v for k, v in facts.items() if k in ("pages", "incremental_updates", "signatures", "text_layer",
                                                      "camera", "width", "height", "producer")},
    )
    return out


def main() -> int:
    req = json.load(sys.stdin)
    # MuPDF and tesseract print diagnostics on fd 1 ("MuPDF error: format
    # error ..."), which corrupted the JSON answer for 2 of ~2,800 replay
    # files. Point fd 1 at stderr while working; answer on the saved fd.
    sys.stdout.flush()
    answer = os.fdopen(os.dup(1), "w")
    os.dup2(2, 1)
    try:
        res = extract_bytes(base64.b64decode(req["data"]), req["path"], req.get("declared"),
                            ClaimContext.from_dict(req.get("context")))
    except Exception as exc:  # noqa: BLE001 - one bad file must yield a recorded error, not a traceback
        res = {"version": FORENSICS_VERSION, "fatal": f"{type(exc).__name__}: {exc}"[:300]}
    json.dump(res, answer, default=str)
    answer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
