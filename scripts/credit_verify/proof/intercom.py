"""Shadow input until core C1b links proofs to credit requests: the Intercom
attachments Caroline's edge plugin already caches on node-8.

`plugins/intercom/src/attachments.ts` downloads every customer attachment to
`/root/.openclaw-edge/media/intercom/<conversation>/notif_<id>/<n>.<ext>`
(plus `<n>-p-<page>.png` renders of PDFs, which are skipped here: the original
PDF is analysed). A conversation is a PROOF conversation when a teammate or
the bot asked for documentation/proof and the customer attached a file after
that ask (the credit-retro-hold-docfraud-f1 classification, §8). Only the
files the customer sent after the first ask are analysed: each `notif_<id>`
directory holds one webhook's downloads, written when that message arrived,
so a file written before the ask (an avatar, an app-error screenshot) is
skipped. The conversation is read with one Intercom API GET; nothing is
written to Intercom.

Every file is analysed in the sandbox with an EMPTY claim context (no request
link yet), so content cross-checks only extract entities; reuse detection and
the file forensics run in full. Nothing that identifies a person is stored:
the submitter is a hash of the Intercom contact id.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable

from .fingerprint import sha256
from .pipeline import Runner, extract, finalize
from .signals import ClaimContext
from . import sandbox
from .store import ProofStore

CACHE_ROOT = os.environ.get("CREDIT_PROOF_INTERCOM_CACHE", "/root/.openclaw-edge/media/intercom")
EDGE_ENV = os.environ.get("CREDIT_PROOF_EDGE_ENV", "/etc/openclaw/edge.env")
API = "https://api.intercom.io"
ORIGINAL = re.compile(r"^\d+\.(png|jpe?g|pdf|heic|webp)$", re.I)
ASK = re.compile(r"(share|send|provide|submit|attach|upload).{0,60}(documentation|proof|document|evidence|supporting)"
                 r"|supporting documents?|more info(rmation)? (is )?needed|split ?sheet|proof of (your )?(credit|work|role)",
                 re.I)


def intercom_token() -> str | None:
    tok = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if tok:
        return tok
    try:
        with open(EDGE_ENV, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MUSOAI_INTERCOM_TOKEN="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'") or None
    except OSError:
        return None
    return None


Fetch = Callable[[str], dict[str, Any] | None]


def make_fetch(token: str, timeout: int = 30) -> Fetch:
    def get(conv_id: str) -> dict[str, Any] | None:
        req = urllib.request.Request(f"{API}/conversations/{conv_id}", headers={
            "Authorization": f"Bearer {token}", "Intercom-Version": "2.11", "Accept": "application/json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return json.load(resp)
            except urllib.error.HTTPError as exc:
                if exc.code == 429:
                    time.sleep(5 * (attempt + 1))
                    continue
                if exc.code == 404:
                    return None
                raise
            except (urllib.error.URLError, TimeoutError, OSError):
                time.sleep(2)
        raise RuntimeError(f"intercom GET failed for conversation …{conv_id[-5:]}")
    return get


@dataclass
class Conversation:
    conv_id: str
    asked_at: float | None          # first documentation ask, when a customer file followed it
    contact_h: str
    files: list[str] = field(default_factory=list)

    @property
    def proof(self) -> bool:
        return self.asked_at is not None


def contact_hash(contact_id: str | None) -> str:
    return hashlib.sha256(f"intercom-contact:{contact_id or ''}".encode()).hexdigest()[:16] if contact_id else ""


def classify(conv_id: str, doc: dict[str, Any]) -> tuple[float | None, str]:
    """(time of the first documentation ask when the customer attached a file
    after it, else None; submitter hash)."""
    source = {"created_at": doc.get("created_at"), **(doc.get("source") or {})}
    parts = [source] + list(((doc.get("conversation_parts") or {}).get("conversation_parts")) or [])
    asked_at: float | None = None
    proof = False
    for p in parts:
        body = re.sub(r"<[^>]+>", " ", p.get("body") or "")
        author = (p.get("author") or {}).get("type")
        if asked_at is None and author in ("admin", "bot") and ASK.search(body):
            asked_at = float(p.get("created_at") or 0)
        if asked_at is not None and author in ("user", "lead", "contact") and p.get("attachments"):
            proof = True
    contacts = ((doc.get("contacts") or {}).get("contacts")) or [{}]
    return (asked_at if proof else None), contact_hash(contacts[0].get("id"))


def sent_after(files: list[str], asked_at: float) -> list[str]:
    out = []
    for f in files:
        try:
            if os.stat(f).st_mtime >= asked_at:
                out.append(f)
        except OSError:
            continue
    return out


def list_cache(root: str, since_epoch: float) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    if not os.path.isdir(root):
        return out
    for conv in sorted(os.listdir(root)):
        cdir = os.path.join(root, conv)
        if not conv.isdigit() or not os.path.isdir(cdir) or os.stat(cdir).st_mtime < since_epoch:
            continue
        files = []
        for dirpath, _dirs, names in os.walk(cdir):
            for n in sorted(names):
                if ORIGINAL.match(n):
                    files.append(os.path.join(dirpath, n))
        if files:
            out[conv] = files
    return out


def run(store: ProofStore, *, days: int, fetch: Fetch, root: str = CACHE_ROOT, workers: int = 4,
        max_files: int = 5000, runner: Runner = sandbox.run, now: float | None = None) -> dict[str, Any]:
    """Classify cached conversations, analyse every original file of the
    proof conversations not analysed yet by this FORENSICS_VERSION. Returns an
    aggregate (counts only, conversation ids shortened to 5 digits)."""
    now = now or time.time()
    cache = list_cache(root, now - days * 86400)
    stats: dict[str, Any] = {"conversations_cached": len(cache), "proof_conversations": 0, "classify_errors": 0,
                             "files_analysed": 0, "files_skipped_done": 0, "files_before_ask": 0,
                             "verdicts": Counter(), "signals": Counter(),
                             "hard_examples": [], "reuse_examples": []}
    convs: list[Conversation] = []

    def cls(conv: str) -> Conversation | None:
        try:
            doc = fetch(conv)
        except Exception:  # noqa: BLE001 - counted; a classify failure skips the conversation this run
            stats["classify_errors"] += 1
            return None
        if doc is None:
            return None
        asked_at, ch = classify(conv, doc)
        return Conversation(conv, asked_at, ch, sent_after(cache[conv], asked_at) if asked_at is not None else [])

    with ThreadPoolExecutor(max_workers=5) as pool:
        for c in pool.map(cls, list(cache)):
            if c and c.proof:
                convs.append(c)
                stats["files_before_ask"] += len(cache[c.conv_id]) - len(c.files)
    stats["proof_conversations"] = len(convs)
    todo = []
    for c in convs:
        for f in c.files:
            if len(todo) >= max_files:
                break
            try:
                with open(f, "rb") as fh:
                    digest = sha256(fh.read())
            except OSError:
                continue
            if store.analyzed(digest, c.contact_h, None):
                stats["files_skipped_done"] += 1
                continue
            todo.append((c, f))
    empty = ClaimContext()

    def one(item):
        c, f = item
        return c, f, extract(f, None, empty, runner)

    # Extraction (untrusted, sandboxed) runs in parallel; reuse matching and
    # recording run one file at a time, in order, so copies inside one batch
    # still find each other.
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        for c, f, raw in pool.map(one, todo):
            [res] = finalize(store, f, raw, contact_h=c.contact_h, source="intercom",
                             source_ref=f"{c.conv_id}/{os.path.relpath(f, os.path.join(root, c.conv_id))}", ctx=empty)
            stats["files_analysed"] += 1
            stats["verdicts"][res.verdict] += 1
            for s in res.signals:
                if s.severity in ("hard", "soft", "mismatch", "issuer", "error"):
                    stats["signals"][f"{s.severity}:{s.check}:{s.name}"] += 1
            if res.verdict == "FORGED_LIKELY" and len(stats["hard_examples"]) < 20:
                stats["hard_examples"].append({"conv": c.conv_id[-5:], "reasons": res.reasons[:3], "mime": res.mime})
            if any(s.name.startswith("reused_") for s in res.signals) and len(stats["reuse_examples"]) < 20:
                stats["reuse_examples"].append({"conv": c.conv_id[-5:], "how": [s.value for s in res.signals
                                                                               if s.name.startswith("reused_")][:1]})
    stats["verdicts"] = dict(stats["verdicts"])
    stats["signals"] = dict(stats["signals"].most_common())
    return stats


def to_markdown(stats: dict[str, Any]) -> str:
    lines = ["# Proof forensics - Intercom shadow replay", "",
             f"Cached conversations in window: {stats['conversations_cached']}; proof conversations: "
             f"{stats['proof_conversations']}; classify errors: {stats['classify_errors']}.",
             f"Files analysed: {stats['files_analysed']}; files sent before the ask (skipped): "
             f"{stats['files_before_ask']}.", "", "| verdict | files |", "|---|---|"]
    for k, v in sorted(stats["verdicts"].items(), key=lambda kv: -kv[1]):
        lines.append(f"| {k} | {v} |")
    lines += ["", "| severity:check:signal | files |", "|---|---|"]
    for k, v in list(stats["signals"].items())[:40]:
        lines.append(f"| {k} | {v} |")
    if stats["hard_examples"]:
        lines += ["", "FORGED_LIKELY examples (conversation last 5 digits):"]
        lines += [f"- …{e['conv']} {e['mime']}: {'; '.join(e['reasons'])}" for e in stats["hard_examples"]]
    if stats["reuse_examples"]:
        lines += ["", "Cross-account reuse examples:"]
        lines += [f"- …{e['conv']}: {e['how']}" for e in stats["reuse_examples"]]
    return "\n".join(lines)
