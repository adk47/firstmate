"""Per-file extraction: everything that touches the untrusted bytes.

Runs INSIDE the sandbox (sandbox.py) as `python3 -m credit_verify.proof.analyze`
reading one JSON request on stdin (the file's bytes plus the path it cites as
evidence) and printing one JSON result on stdout. It opens no host file,
writes only temp files, and needs no network, no credentials and no database. Store access, reuse matching and the verdict
happen in the parent (pipeline.py).
"""

from __future__ import annotations

import base64
import copy
import json
import os
import sys
from typing import Any

from . import FORENSICS_VERSION, content, fingerprint, image_forensics, image_meta, pdf_forensics
from .signals import ERROR, ClaimContext, Evidence, Extracted, Signal
from .sandbox import MAX_BYTES
from .sniff import sniff


# Doc-verify (credit_verify.docverify) asks for the document's text so its
# extraction step can read it; nothing else does. Bounded: the model reads at
# most this many characters, and the text never reaches a store.
TEXT_CAP = 16_000
FACT_KEYS = ("pages", "incremental_updates", "signatures", "text_layer", "camera", "width", "height", "producer",
             "creator", "created", "modified", "exif_datetime", "exif_datetime_original", "software")


def extract(path: str, declared: str | None, ctx: ClaimContext,
            contexts: list[ClaimContext] | None = None) -> dict[str, Any]:
    with open(path, "rb") as fh:
        return extract_bytes(fh.read(MAX_BYTES + 1), path, declared, ctx, contexts)


def extract_bytes(data: bytes, path: str, declared: str | None, ctx: ClaimContext,
                  contexts: list[ClaimContext] | None = None, want_text: bool = False) -> dict[str, Any]:
    """`path` is only the label cited as evidence (and its extension the
    declared type hint); the bytes are `data`.

    With `contexts` (stage 2: one document checked against several claimed
    tracks of the same account), the file forensics run ONCE and the content
    cross-checks run once per context: the top-level `signals` then carry the
    file forensics only and `per_context[i]` carries context i's content
    signals, kind, track_listed and entities. `ctx` supplies the claimant
    names for the PDF checks and must name the same account as every
    context."""
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
    per_context: list[dict[str, Any]] | None = None
    if contexts:
        per_context = []
        for c in contexts:
            e = copy.deepcopy(ext)
            sc, ec = content.analyze(e, c, path)
            per_context.append({"signals": [x.as_dict() for x in sc], "kind": e.kind,
                                "track_listed": e.track_listed, "entities": ec})
        first = per_context[0]
        ext.kind, ext.track_listed, ents = first["kind"], first["track_listed"], first["entities"]
    else:
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
        text_sha=fingerprint.text_sha(ext.text),
        n_shingles=len(sh),
        entities=ents,
        facts={k: v for k, v in facts.items() if k in FACT_KEYS},
    )
    if per_context is not None:
        out["per_context"] = per_context
    if want_text:
        out["doc_text"] = ext.text[:TEXT_CAP]
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
        contexts = req.get("contexts")
        res = extract_bytes(base64.b64decode(req["data"]), req["path"], req.get("declared"),
                            ClaimContext.from_dict(req.get("context")),
                            [ClaimContext.from_dict(c) for c in contexts] if contexts else None,
                            want_text=bool(req.get("want_text")))
    except Exception as exc:  # noqa: BLE001 - one bad file must yield a recorded error, not a traceback
        res = {"version": FORENSICS_VERSION, "fatal": f"{type(exc).__name__}: {exc}"[:300]}
    json.dump(res, answer, default=str)
    answer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
