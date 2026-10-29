"""D2: the reader takes the documents filed in `proof_intake` directly (proof-loop lead
[key=proof-loop-plan-1027]; Fable [key=doc-verify-go-live] Q4).

Stage 2 is not on this path. For every filed document with candidate credit requests that
has no outcome yet, the reader:
  * locates its bytes: the cache copy the filer recorded, else the customer's attachment in
    the conversation whose sha256 equals the filed `file_sha256` (read-only Intercom GET +
    download into a 0700 temp dir, deleted after);
  * builds the claim keys `<request_id>#<role>` from the candidate requests that are still
    open (role from the request row, via the same read-only Trino SELECT stage 2 uses);
  * runs H3 ITSELF against those claims, through `ShadowProofStore`: a READ-ONLY view of the
    H3 store (prior fingerprints for cross-account reuse are read; nothing is ever written to
    proof.sqlite), then reads each claim's verdict exactly as stage 2 does (claim_verdict);
  * records its outcomes in doc-verify.sqlite keyed by intake_id + request_id + role.

This path writes NO account hold (proof-loop lead: no live holds from it until the D1 bar 6
holds); a would-be hold is recorded in the outcome detail only.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import threading
from dataclasses import dataclass, field
from typing import Any, Callable

from credit_verify.proof.store import ProofStore

from .forensics import H3, signal_dict


@dataclass
class IntakeDoc:
    intake_id: str
    user_id: int
    sha: str
    conversation_id: str
    file_path: str | None
    contact_h: str
    candidate_ids: list[str] = field(default_factory=list)
    received_at: str = ""
    matched_by: str = ""


def intake_docs(proof_db: sqlite3.Connection, settled: Callable[[str, list[str]], bool],
                limit: int, *, keep: Callable[[str], bool] | None = None,
                paying: set[int] | frozenset[int] | None = None) -> list[IntakeDoc]:
    """Filed credit documents with candidate requests that are not settled yet (some claim
    unfinished, or the candidates changed): PAID accounts first when `paying` is given (proof-loop
    lead 2026-10-28), then oldest first. `keep(sha256)` restricts a parallel worker to its own
    shard. An older H3 store without the table yields nothing."""
    try:
        rows = proof_db.execute(
            "SELECT intake_id, user_id, file_sha256, conversation_id, file_path, contact_h, "
            "candidate_request_ids_json, received_at, matched_by FROM proof_intake "
            "WHERE subject = 'credit' AND candidate_request_ids_json != '[]' ORDER BY received_at, intake_id").fetchall()
    except sqlite3.OperationalError:
        return []
    if paying:
        rows = sorted(rows, key=lambda r: int(r[1]) not in paying)     # stable: oldest first within each
    out: list[IntakeDoc] = []
    for r in rows:
        if len(out) >= limit:
            break
        if keep is not None and not keep(r[2]):
            continue
        try:
            ids = [str(x) for x in json.loads(r[6] or "[]") if x]
        except ValueError:
            ids = []
        if ids and not settled(r[0], ids):
            out.append(IntakeDoc(r[0], int(r[1]), r[2], str(r[3]), r[4], r[5] or "", ids, r[7] or "", r[8] or ""))
    return out


class ShadowProofStore:
    """A read-only H3 store for the reader's own H3 run: `_prior`, `reuse_signals` and
    `remember` read the real proof.sqlite (so cross-account reuse still sees every stored
    document); `record` keeps the result in memory and writes nothing."""

    _prior = ProofStore._prior
    reuse_signals = ProofStore.reuse_signals
    remember = ProofStore.remember

    def __init__(self, db: sqlite3.Connection):
        self.db = db
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.recorded: list[dict[str, Any]] = []

    @classmethod
    def open(cls, path: str) -> "ShadowProofStore":
        return cls(sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60, check_same_thread=False))

    def record(self, **kw: Any) -> None:
        self.recorded.append({"verdict": kw.get("verdict"), "request_id": kw.get("request_id")})


def _sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def locate_intake(doc: IntakeDoc, tmp: str, *, fetch: Callable[[str], Any] | None,
                  dl: Callable[[str, str], int] | None, cache_root: str,
                  gmail_raw: Callable[[str], bytes] | None = None) -> tuple[str | None, str | None, list[str]]:
    """(path, source_ref, errors): the filer's cache copy when its sha256 still matches,
    else the conversation attachment whose bytes hash to the filed sha256. A `gmail:<id>`
    filing (support@ email) is re-read from Gmail and its attachment picked by sha256."""
    from credit_verify.proof.stage2 import customer_attachments
    errors: list[str] = []
    if doc.conversation_id.startswith("gmail:"):
        from credit_verify.proof.gmail_intake import message_attachment
        mid = doc.conversation_id.split(":", 1)[1]
        if gmail_raw is None:
            return None, None, ["no Gmail reader configured"]
        try:
            hit = message_attachment(gmail_raw(mid), doc.sha)
        except Exception as exc:  # noqa: BLE001 - recorded; the document is retried
            return None, None, [f"gmail {mid[-6:]}: {type(exc).__name__}Error"]
        if hit is None:
            return None, None, ["no attachment in the message has the filed sha256"]
        name, _ctype, data = hit
        dest = os.path.join(tmp, re.sub(r"[^A-Za-z0-9._-]", "_", name)[-60:] or "attachment")
        with open(dest, "wb") as fh:
            fh.write(data)
        return dest, doc.conversation_id, errors
    root = os.path.realpath(cache_root)
    if doc.file_path:
        p = os.path.realpath(doc.file_path)
        if p.startswith(root + os.sep) and os.path.isfile(p):
            try:
                if _sha(p) == doc.sha:
                    return p, os.path.relpath(p, root), errors
            except OSError as exc:
                errors.append(f"cache: {type(exc).__name__}")
        errors.append("cache: no copy with the filed sha256")
    if fetch is None or dl is None:
        return None, None, errors or ["no Intercom fetch configured"]
    try:
        conv = fetch(doc.conversation_id)
    except Exception as exc:  # noqa: BLE001 - recorded; the document is retried
        return None, None, errors + [f"intercom …{doc.conversation_id[-5:]}: {type(exc).__name__}Error"]
    for i, a in enumerate(customer_attachments(conv or {})):
        name = re.sub(r"[^A-Za-z0-9._-]", "_", str(a.get("name") or f"file{i}"))[-60:]
        dest = os.path.join(tmp, f"{doc.conversation_id}-{i}-{name}")
        try:
            dl(str(a["url"]), dest)
            if _sha(dest) == doc.sha:
                return dest, f"intercom:{doc.conversation_id}:{i}", errors
            os.remove(dest)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"attachment …{doc.conversation_id[-5:]}#{i}: {type(exc).__name__}Error")
    return None, None, errors + ["no attachment in the conversation has the filed sha256"]


def shadow_h3(shadow: ShadowProofStore, path: str, doc: IntakeDoc, requests: list[Any],
              runner: Callable[..., dict[str, Any]] | None = None) -> dict[str, H3]:
    """Run H3 on one filed document against its open candidate requests (stage 2's
    contexts: one per track and claimant-name set), reading every claim's verdict the way
    stage 2 does. Returns '<request_id>#<role>' -> H3."""
    from credit_verify.proof import stage2
    from credit_verify.proof.pipeline import _multi_sandbox, analyze_against
    out: dict[str, H3] = {}
    ctxs = stage2.contexts_for(requests)
    for group in stage2.name_groups(ctxs):
        res = analyze_against(shadow, path, contact_h=doc.contact_h or f"user:{doc.user_id}", source="intake",
                              source_ref=f"intake:{doc.intake_id}", contexts=group,
                              runner=runner or _multi_sandbox)
        for ctx, per_claim in zip(group, res):
            for pr in per_claim:
                v, reasons, sig = stage2.claim_verdict(pr, ctx)
                out[pr.request_id] = H3(verdict=v, reasons=list(reasons)[:6],
                                        signals=[signal_dict(s) for s in sig],
                                        kind=pr.kind)
    return out
