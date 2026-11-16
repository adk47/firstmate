#!/usr/bin/env python3
"""One claim per sampled document, chosen without reading anything the reader decided.

Read-only. Run on node-8 after `sample.json` is copied to WORK:

    ssh root@node-8 'nice -n 10 python3 - --emit' < build_cases.py > cases.json

For each of the 60 documents it lists the claims the reader was asked about that document as of
the draw's CUTOFF (the `(request, role)` keys of its standing `dv_outcomes` rows; the KEY only, the
outcome column is never selected), reads each claim's name, role and track from core, and picks one:

    tier 1  the document's text names the claimant AND the track title
    tier 2  the text names the track title
    tier 3  the text names the claimant
    tier 4  any claim on the document

the first non-empty tier, then the claim with the smallest sha256(SEED|proof|request|role). The
text is the sandbox's read of the stored bytes (the same input the reader gets); "names" is a
whole-token match on the folded text with the blind check's floors (5 folded characters for a name,
4 for a title). Most documents are paired with every open request of the filing account (16.6 per
document), so a uniform pick would mostly ask whether a split sheet supports an unrelated track; the
tiers ask about the claim the document is most plausibly about, and the judge, not this rule,
decides whether it supports it.

It also copies each document's bytes to WORK/docs/ so the judge can see the document itself. The bytes
are the stored blob, else a copy on node-8's disk whose sha256 is the proof id (the filer's cache path or
the reader's own cache refs, `runner.locate` with no network fetch). Nothing is fetched from Intercom
or Gmail: a document with no copy on disk is recorded as such and is not re-drawn.
Output carries names and titles: it is kept off git (the committed files are redacted).
"""
import hashlib
import json
import os
import shutil
import sqlite3
import sys

SEED = "docverify-blind-60-r1"
CUTOFF = "2026-11-15T01:23:59Z"
WORK = os.environ.get("DVB60_WORK", "/tmp/dvb60")
MIN_NAME, MIN_TITLE = 5, 4
EXT = {"application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
       "image/webp": "webp", "image/heic": "heic", "image/tiff": "tiff", "text/plain": "txt",
       "text/html": "html", "message/rfc822": "eml"}


def key_rank(proof_id, request_id, role):
    return hashlib.sha256(f"{SEED}|{proof_id}|{request_id}|{role}".encode()).hexdigest()


def contains(ftext, value, floor, fold):
    f = fold(value or "")
    return len(f) >= floor and f" {f} " in f" {ftext} "


def choose(proof_id, claims, ftext, fold):
    """claims: [{request_id, role, names, title}] -> (claim, tier). Pure; the tests call it."""
    def tier(c):
        name = any(contains(ftext, n, MIN_NAME, fold) for n in c["names"])
        title = contains(ftext, c["title"], MIN_TITLE, fold)
        return 1 if name and title else 2 if title else 3 if name else 4
    if not claims:
        return None, None
    ranked = sorted(claims, key=lambda c: (tier(c), key_rank(proof_id, c["request_id"], c["role"])))
    return ranked[0], tier(ranked[0])


def main():  # pragma: no cover - runs on node-8 only
    sys.path.insert(0, "/opt/hydra/scripts")
    from credit_review.roles import fold
    from credit_verify.docverify import VERSION
    from credit_verify.docverify.blobs import BlobStore
    from credit_verify.proof import sandbox, stage2

    sample = json.load(open(os.path.join(WORK, "sample.json")))
    dv = sqlite3.connect("file:/var/lib/hydra-credit-verify/doc-verify.sqlite?mode=ro", uri=True, timeout=120)
    from credit_verify.docverify import runner
    blobs = BlobStore()
    proof_db = sqlite3.connect("file:/var/lib/hydra-credit-verify/proof.sqlite?mode=ro", uri=True, timeout=120)

    def on_disk(pid):
        for (fp,) in proof_db.execute("SELECT file_path FROM proof_intake WHERE file_sha256=? AND "
                                      "file_path IS NOT NULL", (pid,)):
            try:
                if os.path.isfile(fp) and runner.sha256_file(fp) == pid:
                    return fp, "intake-file-path"
            except OSError:
                continue
        p, _ref, _errs = runner.locate(runner.source_refs(proof_db, pid), pid, WORK, fetch=None, dl=None)
        return (p, "reader-cache-ref") if p else (None, None)
    os.makedirs(os.path.join(WORK, "docs"), exist_ok=True)
    keys = {}
    for s in sample["sample"]:
        keys[s["proof_id"]] = sorted({(r[0], r[1]) for r in dv.execute(
            "SELECT DISTINCT request_id, role FROM dv_outcomes WHERE proof_id=? AND version=? AND at<=?",
            (s["proof_id"], VERSION, CUTOFF))})
    rids = sorted({rid for ks in keys.values() for rid, _ in ks})
    failures = []
    reqs = stage2.requests(rids, failures=failures)
    cases = []
    for s in sample["sample"]:
        pid = s["proof_id"]
        case = {"case": f"D{s['n']:02d}", "n": s["n"], "proof_id": pid, "doc_type": s["doc_type"],
                "stratum": s["stratum"], "candidate_claims": len(keys[pid])}
        path, where = blobs.get(pid), "blob"
        if not path:
            path, where = on_disk(pid)
        case["bytes_from"] = where
        raw, dst = {}, None
        if path:
            try:
                raw = sandbox.run(path, None, {}, want_text=True)
            except sandbox.SandboxError as exc:
                raw = {"fatal": str(exc)[:200]}
        text = str(raw.get("doc_text") or "")
        mime = raw.get("mime") or ""
        if path:
            dst = os.path.join(WORK, "docs", f"{case['case']}.{EXT.get(mime, 'bin')}")
            shutil.copyfile(path, dst)
            with open(os.path.join(WORK, "docs", f"{case['case']}.text"), "w") as fh:
                fh.write(text)
        claims = []
        for rid, role in keys[pid]:
            r = reqs.get(rid)
            if r is None:
                continue
            claims.append({"request_id": rid, "role": role, "names": r.names, "title": r.title,
                           "artists": r.artists, "track_id": r.track_id, "user_id": r.user_id,
                           "status_now": r.status})
        claim, tier = choose(pid, claims, fold(text), fold)
        why = None if claim else "no claim readable in core"
        if not path:
            why = "no copy of the document's bytes on node-8"
        case.update({"bytes": os.path.basename(dst) if dst else None, "mime": mime, "text_chars": len(text),
                     "text_source": raw.get("text_source"), "claims_readable_in_core": len(claims),
                     "claim": claim, "tier": tier, "why": why})
        cases.append(case)
        print(f"[build] {case['case']} {s['doc_type']} {mime} tier={tier} claims={len(claims)}", file=sys.stderr)
    json.dump({"seed": SEED, "cutoff": CUTOFF, "version": VERSION, "core_read_failures": failures[:5],
               "cases": cases}, sys.stdout, indent=1)
    print()


if __name__ == "__main__" and "--emit" in sys.argv:  # pragma: no cover
    main()
