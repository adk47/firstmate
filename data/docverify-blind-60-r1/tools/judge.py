#!/usr/bin/env python3
"""The independent judge: an Opus model that sees the document and the claim, and nothing else.

    python3 judge.py --cases cases.json --docs DOCS_DIR --out judge.json

One question per document: does this document support this claim? `yes`, `no` or `cannot_tell`,
with one line of reasoning.

What the judge is given is decided in ONE place, `judge_claim()`, which copies an allow-list of
claim facts (`CLAIM_FIELDS`: the credited name and the account's other names, the role, the track
title and the track's artists) out of a case. `build_request()` refuses a claim carrying any other
key. The reader's verdict, its reason, its extraction, its gate detail, the H3 verdict and even the
document type the reader's extraction gave are never in a case's claim and could not pass the
allow-list if they were. The judge also gets no OCR text when it can see the document itself: an
image or a PDF goes in as the document. Only a file the model cannot open as an image or a PDF is
given as the text the sandbox read from the bytes (the reader's input, not its output).

It runs on ak47 (the reviewer box that reaches the model) through the local CLIProxyAPI. It is a
model call per document, 60 at most, no tools.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import sys
import time
import urllib.request

MODEL = "claude-opus-5-5"
PROXY = os.environ.get("DVB60_PROXY", "http://127.0.0.1:8317/v1/messages")
CLAIM_FIELDS = ("name", "other_names", "role", "track", "artists")
VERDICTS = ("yes", "no", "cannot_tell")
IMAGE_MIME = {"image/jpeg", "image/png", "image/gif", "image/webp"}
MAX_IMAGE_BYTES = 3_700_000      # the API's 5 MB image limit applies to the base64 form
MAX_TEXT = 60_000

SYSTEM = (
    "You check documents that people send as proof of a music credit. You are given one document and one "
    "claim. Decide from the document alone whether it supports the claim. Do not assume the claim is true "
    "and do not use outside knowledge about the people or the track.\n"
    "Answer yes when the document itself shows this person (by this name, or a clearly recognisable form of "
    "it) credited in the claimed role, or an equivalent role (for example a songwriter or composer share on a "
    "registration or split sheet supports a songwriter or composer claim), on this track.\n"
    "Answer no when the document is about something else, does not show this person, does not show this "
    "track, shows the person in a different role, or contradicts the claim.\n"
    "Answer cannot_tell only when the document cannot be read well enough to decide.\n"
    "Reply with one JSON object and nothing else: "
    '{"verdict": "yes" | "no" | "cannot_tell", "reason": "<one line, under 200 characters>"}'
)


def judge_claim(case: dict) -> dict:
    """The only facts of a case the judge may see. An allow-list, never a deny-list."""
    c = case.get("claim") or {}
    names = [n for n in (c.get("names") or []) if n]
    return {"name": names[0] if names else "", "other_names": names[1:], "role": c.get("role") or "",
            "track": c.get("title") or "", "artists": list(c.get("artists") or [])}


def claim_text(claim: dict) -> str:
    extra = f" (the claimant's account also uses: {', '.join(claim['other_names'])})" if claim["other_names"] else ""
    by = f" by {', '.join(claim['artists'])}" if claim["artists"] else ""
    return (f"CLAIM: {claim['name']}{extra} is credited as {claim['role']} on the track "
            f"\"{claim['track']}\"{by}.\n\nQUESTION: does this document support this claim?")


def _image_bytes(data: bytes) -> tuple[bytes, str]:
    if len(data) <= MAX_IMAGE_BYTES:
        return data, ""
    from PIL import Image
    img = Image.open(io.BytesIO(data)).convert("RGB")
    scale = 1.0
    while True:
        scale *= 0.8
        out = io.BytesIO()
        img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale)))).save(out, "JPEG", quality=85)
        if out.tell() <= MAX_IMAGE_BYTES:
            return out.getvalue(), "image/jpeg"


def document_block(doc_path: str | None, mime: str, text: str) -> tuple[dict, str]:
    """(content block, how the judge saw it). The document itself when the model can open it."""
    if doc_path and mime == "application/pdf":
        with open(doc_path, "rb") as fh:
            data = base64.b64encode(fh.read()).decode()
        return {"type": "document", "source": {"type": "base64", "media_type": mime, "data": data}}, "pdf"
    if doc_path and mime in IMAGE_MIME:
        with open(doc_path, "rb") as fh:
            raw, conv = _image_bytes(fh.read())
        return {"type": "image", "source": {"type": "base64", "media_type": conv or mime,
                                            "data": base64.b64encode(raw).decode()}}, "image"
    return {"type": "text", "text": "DOCUMENT TEXT (as read from the file):\n" + (text or "")[:MAX_TEXT]}, "text"


def build_request(doc_path: str | None, mime: str, text: str, claim: dict, model: str = MODEL) -> dict:
    """The whole request the judge sees. Refuses any claim key outside CLAIM_FIELDS."""
    extra = set(claim) - set(CLAIM_FIELDS)
    if extra:
        raise ValueError(f"judge refuses claim fields outside the allow-list: {sorted(extra)}")
    block, _ = document_block(doc_path, mime, text)
    return {"model": model, "max_tokens": 400, "system": SYSTEM,
            "messages": [{"role": "user", "content": [block, {"type": "text", "text": claim_text(claim)}]}]}


def parse(answer: str) -> tuple[str, str]:
    m = re.search(r"\{.*\}", answer or "", re.S)
    if not m:
        raise ValueError("judge answer carries no JSON object")
    d = json.loads(m.group(0))
    verdict = str(d.get("verdict") or "").strip().lower().replace(" ", "_").replace("'", "")
    if verdict not in VERDICTS:
        raise ValueError(f"judge verdict not one of {VERDICTS}: {verdict!r}")
    return verdict, " ".join(str(d.get("reason") or "").split())[:240]


def call(body: dict, key: str) -> str:  # pragma: no cover - network
    req = urllib.request.Request(PROXY, data=json.dumps(body).encode(), method="POST", headers={
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    return "".join(b.get("text", "") for b in d.get("content") or [] if b.get("type") == "text")


def proxy_key() -> str:  # pragma: no cover - local config
    import yaml
    return yaml.safe_load(open(os.path.expanduser("~/.config/cliproxyapi/config.yaml")))["api-keys"][0]


def main() -> int:  # pragma: no cover - network
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--docs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default=MODEL)
    a = ap.parse_args()
    cases = json.load(open(a.cases))["cases"]
    done = json.load(open(a.out)) if os.path.exists(a.out) else {}
    key = proxy_key()
    for case in cases:
        cid = case["case"]
        if cid in done and done[cid].get("verdict"):
            continue
        if not case.get("bytes") or not case.get("claim"):
            done[cid] = {"verdict": None, "not_judged": case.get("why") or "no document", "model": None}
            continue
        claim = judge_claim(case)
        path = os.path.join(a.docs, case["bytes"])
        tpath = os.path.join(a.docs, f"{cid}.text")
        text = open(tpath).read() if os.path.exists(tpath) else ""
        body = build_request(path, case.get("mime") or "", text, claim, a.model)
        seen = document_block(path, case.get("mime") or "", text)[1]
        err = None
        for attempt in range(3):
            try:
                verdict, reason = parse(call(body, key))
                break
            except Exception as exc:  # noqa: BLE001 - retried, then recorded as not judged
                err = f"{type(exc).__name__}: {str(exc)[:120]}"
                time.sleep(5 * (attempt + 1))
        else:
            done[cid] = {"verdict": None, "not_judged": f"judge call failed: {err}", "model": a.model, "saw": seen}
            continue
        done[cid] = {"verdict": verdict, "reason": reason, "model": a.model, "saw": seen}
        print(f"[judge] {cid} {seen} -> {verdict}", file=sys.stderr, flush=True)
        with open(a.out, "w") as fh:
            json.dump(done, fh, indent=1, sort_keys=True)
    with open(a.out, "w") as fh:
        json.dump(done, fh, indent=1, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
